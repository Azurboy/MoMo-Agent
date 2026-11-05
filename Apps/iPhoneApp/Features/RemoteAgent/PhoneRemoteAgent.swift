import Foundation
import Network
import Observation
import Security
import MoMoAgentClient
import MoMoAgentRTC
import MoMoArchive

@MainActor @Observable
final class PhoneRemoteAgent {
    private(set) var context: PhoneContextSync?
    let lifeIllustrations: LifeIllustrationStore
    var transcriptionFingerprint: String? {
        didSet { context?.configurationFingerprint = transcriptionFingerprint }
    }
    @ObservationIgnored var onSummariesChanged: (() -> Void)?

    func summarizeRecordings(_ windows: [TimelineWindow]) async throws -> [String: String] {
        guard let summaries = context?.recordingSummaries else { return [:] }
        return try await summaries.summaries(for: windows)
    }
    private(set) var health: PhoneHealthSync?
    private(set) var sources: PhoneSourcesSync?
    private(set) var sourcesFailure: String?
    private(set) var network: AgentRTCTransport?
    @ObservationIgnored private let archive: ArchiveStore
    @ObservationIgnored private let deviceID: UUID
    private(set) var store: RemoteTaskStore?
    private(set) var desktopClient: AgentClient?
    private(set) var desktopClientID = UUID()
    private(set) var connection: AgentConnection?
    var failure: String?
    private(set) var readingPosition: ChatReadingPosition?
    private(set) var connecting = false
    let notifications = PhoneNotifications()
    let pairing: PhonePairing
    let tailnet: EmbeddedTailnet
    enum SetupStep: String, Codable { case welcome, connect, completed, deferred }
    private(set) var setupStep = SetupStep.welcome
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var active = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private lazy var replyContinuation = PhoneReplyContinuation(
        pending: { [weak self] in
            (self?.store.map { $0.hasActiveTask || $0.waitingForReply } ?? false) || (self?.context?.isSyncing == true)
        },
        suspend: { [weak self] in
            self?.context?.background(); self?.store?.background(); self?.network?.suspend()
            self?.tailnet.suspendSessions()
        })

    init(directory: URL, archive: ArchiveStore, deviceID: UUID) throws {
        self.archive = archive; self.deviceID = deviceID
        self.directory = directory
        lifeIllustrations = LifeIllustrationStore(directory: directory.appendingPathComponent("life-illustrations"))
        tailnet = EmbeddedTailnet(directory: directory.appendingPathComponent("tailscale"), device: "phone")
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try? FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
        pairing = try PhonePairing(directory: directory)
        notifications.agent = self
        let setupFile = directory.appendingPathComponent("onboarding.json")
        if FileManager.default.fileExists(atPath: setupFile.path) {
            setupStep = try JSONDecoder().decode(SetupStep.self, from: Data(contentsOf: setupFile))
            try? FileManager.default.setAttributes(protection, ofItemAtPath: setupFile.path)
        } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("connection.json").path) {
            setupStep = .completed
        }
        let readingFile = directory.appendingPathComponent("reading.json")
        if FileManager.default.fileExists(atPath: readingFile.path) {
            let value = try JSONDecoder().decode(ChatReadingPosition.self, from: Data(contentsOf: readingFile))
            try? FileManager.default.setAttributes(protection, ofItemAtPath: readingFile.path)
            if value.isValid { readingPosition = value }
        }
        let file = directory.appendingPathComponent("connection.json")
        if FileManager.default.fileExists(atPath: file.path) {
            // Invalid configuration is not permission to forget the journal or use a local Agent.
            connection = try JSONDecoder().decode(AgentConnection.self, from: Data(contentsOf: file))
            try? FileManager.default.setAttributes(protection, ofItemAtPath: file.path)
            do {
                if let connection {
                    let key = try Self.readKey(connection.instanceID)
                    let restored = try makeStore(connection, key: key)
                    store = restored.tasks; context = restored.sync; health = restored.health; sources = restored.sources; network = restored.network; desktopClient = restored.desktop
                    if let pending = pairing.pending, pending.invitation.canReuseCredential(from: connection), pending.credential == key {
                        try? pairing.clear()
                        if setupStep == .connect { advanceSetup(.completed) }
                    }
                }
            } catch { failure = error.localizedDescription }
        }
    }

    func connect(configuration: String, credential: String) async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            let proposed = try JSONDecoder().decode(AgentConnection.self, from: Data(configuration.utf8))
            guard connection == nil || connection?.hasSameIdentity(as: proposed) == true else { throw ConnectionError.identityChanged }
            let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            let route = try transport(for: proposed)
            let client = try AgentClient(baseURL: proposed.baseURL, credential: key, assistantID: proposed.assistantID, transport: route)
            let capabilities = try await client.capabilities()
            guard capabilities.features.runSubmission == true,
                  capabilities.features.runsIdempotency?.durable == true else { throw ConnectionError.unsupported }
            guard let dataURL = proposed.dataURL else { throw ConnectionError.unsupported }
            let contextClient = try AgentClient(baseURL: dataURL, credential: key, assistantID: proposed.assistantID, transport: route)
            let status = try await contextClient.contextStatus()
            guard status.workspaceId == proposed.workspaceID, status.sourceSync,
                  ["Hermes", "SuperAgent"].contains(status.memoryWriter) else { throw ConnectionError.identityChanged }
            let restored = try makeStore(proposed, key: key)
            let previousKey = try? Self.readKey(proposed.instanceID)
            try Self.writeKey(key, id: proposed.instanceID)
            do {
                try JSONEncoder().encode(proposed).write(
                    to: directory.appendingPathComponent("connection.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
            catch {
                if let previousKey { try Self.writeKey(previousKey, id: proposed.instanceID) }
                throw error
            }
            store?.background(); context?.background(); health?.background(); sources?.background(); network?.suspend()
            connection = proposed; store = restored.tasks; context = restored.sync; health = restored.health; sources = restored.sources; network = restored.network; desktopClient = restored.desktop; failure = nil
            desktopClientID = UUID()
            notifications.start(); notifications.foreground()
            if active { network?.resume(); context?.foreground(); health?.foreground(); sources?.foreground(); restored.tasks.foreground(); lifeIllustrations.startPolling() }
            onSummariesChanged?()
        } catch {
            failure = AgentTransportFailure.isTransient(error) ? String(localized: "暂时无法连接 Mac，请重试，无需重新扫码。") : error.localizedDescription
        }
    }

    func advanceSetup(_ step: SetupStep) {
        do {
            try JSONEncoder().encode(step).write(
                to: directory.appendingPathComponent("onboarding.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            setupStep = step
        } catch { failure = error.localizedDescription }
    }

    func pairingCredential(for invitation: PairingInvitation) throws -> String? {
        // A QR is untrusted: never send a saved secret to a different origin.
        guard let connection, invitation.canReuseCredential(from: connection) else { return nil }
        return try Self.readKey(connection.instanceID)
    }

    func reconnect() async {
        guard !connecting, let connection, let store, let client = desktopClient,
              store.canContactServer else { return }
        connecting = true; failure = nil
        defer { connecting = false }
        do {
            if connection.network == "tailscale" {
                tailnet.prepareForForeground()
                do {
                    try await Self.probeCapabilities(client, timeout: .seconds(12))
                } catch {
                    guard AgentTransportFailure.isSocketOrLinkFailure(error) else { throw error }
                    try Task.checkCancellation()
                    await tailnet.restartForRecovery()
                    try await Self.probeCapabilities(client, timeout: .seconds(15))
                }
            } else {
                network?.resume()
                try await Self.probeCapabilities(client, timeout: .seconds(12))
            }
            guard self.store === store else { return }
            await store.retryConnection()
            await context?.refresh()
            await lifeIllustrations.refresh()
        } catch is CancellationError { }
        catch {
            guard !AgentTransportFailure.isCancelled(error) else { return }
            store.recordConnectionFailure(error)
            failure = AgentTransportFailure.isTransient(error) ? String(localized: "暂时无法连接 Mac，请稍后重试。") : error.localizedDescription
        }
    }

    private nonisolated static func probeCapabilities(_ client: AgentClient, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await client.capabilities() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func foreground() {
        guard !active else { return }
        active = true
        replyContinuation.foreground()
        startPathMonitor()
        if connection?.network == "tailscale" { tailnet.prepareForForeground() }
        guard store?.canContactServer != false else { return }
        network?.resume(); context?.foreground(); health?.foreground(); sources?.foreground(); store?.foreground(); notifications.foreground()
        lifeIllustrations.startPolling()
        onSummariesChanged?()
    }
    func leavingForeground() {
        active = false
        stopPathMonitor()
        context?.stopPolling(); health?.background(); sources?.background(); notifications.background()
        lifeIllustrations.stopPolling()
        replyContinuation.leavingForeground()
    }
    func background() { replyContinuation.background() }
    func sourcesChanged() {
        guard active, store?.canContactServer != false, let context else { return }
        PhoneConnectivityTask.run { await context.refresh() }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
            let signature = "\(path.status):\(interfaces)"
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor, self.pathMonitor === monitor, self.active else { return }
                let previous = self.lastPathSignature
                self.lastPathSignature = signature
                guard path.status == .satisfied, previous != nil, previous != signature,
                      self.store?.canContactServer != false else { return }
                if self.connection?.network == "tailscale" { self.tailnet.prepareForForeground() }
                else { self.network?.resume() }
                await self.store?.retryConnection(ifNeeded: true)
                await self.context?.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.momoagent.remote.path"))
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel(); pathMonitor = nil; lastPathSignature = nil
    }

    func rememberReadingPosition(_ position: ChatReadingPosition) {
        guard position.isValid, position.sessionID == connection?.assistantID else { return }
        do {
            try JSONEncoder().encode(position).write(
                to: directory.appendingPathComponent("reading.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            readingPosition = position
            let visible = Set(position.visibleMessageIDs ?? [])
            notifications.rendered(messageIDs: visible, failedRunIDs: Set(visible.filter { $0.hasPrefix("run-status-") }.map { String($0.dropFirst(11)) }))
        } catch { failure = error.localizedDescription }
    }

    func selectSources(_ sources: [SourceReference]) {
        // Source selection is a draft, never permission to execute transcript instructions.
        let references = sources.map(\.citationURL).joined(separator: "\n")
        store?.setDraft(String(localized: "请根据这些录音稿帮我梳理要做的事：\n") + references)
    }

    private func transport(for connection: AgentConnection) throws -> (any AgentTransport)? {
        if connection.network == "relay" {
            guard let code = connection.relayCode else { throw ConnectionError.unsupported }
            return try RelayTransport(endpoint: connection.baseURL, code: code)
        }
        guard connection.network == nil || connection.network == "tailscale" else { throw ConnectionError.unsupported }
        return connection.network == "tailscale" ? EmbeddedTailnetTransport(network: tailnet, endpoint: connection.baseURL) : nil
    }

    private func makeStore(_ connection: AgentConnection, key: String) throws -> (tasks: RemoteTaskStore, sync: PhoneContextSync, health: PhoneHealthSync?, sources: PhoneSourcesSync?, network: AgentRTCTransport?, desktop: AgentClient) {
        let network = connection.network == nil ? try AgentRTCTransport(connection: connection, credential: key) : nil
        let route = try transport(for: connection) ?? network
        let client = try AgentClient(baseURL: connection.baseURL, credential: key, assistantID: connection.assistantID, transport: route)
        let sync = try PhoneContextSync(directory: directory, archive: archive, deviceID: deviceID, connection: connection, key: key, transport: route)
        sync.configurationFingerprint = transcriptionFingerprint
        let health = try? PhoneHealthSync(directory: directory, deviceID: deviceID, connection: connection, key: key, transport: route)
        let sources: PhoneSourcesSync?
        do {
            sources = try PhoneSourcesSync(directory: directory, deviceID: deviceID, connection: connection, key: key,
                                          transport: route, reader: PhoneSourcesReader(directory: directory))
            sourcesFailure = nil
        } catch {
            // A protected/unreadable source file must not disable chat or discard source consent/data.
            sources = nil; sourcesFailure = String(localized: "资料来源暂时无法读取，请解锁后重新打开 App。")
        }
        let tasks = try Self.openTaskStore(file: directory.appendingPathComponent("tasks.json"), connection: connection, client: client)
        tasks.onAuthenticationRequired = { [weak self, weak sync] in
            sync?.background(); self?.health?.background(); self?.sources?.background(); self?.network?.suspend(); self?.notifications.background()
            self?.lifeIllustrations.stopPolling()
            self?.lifeIllustrations.invalidateSupport()
        }
        tasks.onConnectionRestored = { [weak self] in
            self?.failure = nil
        }
        sync.onAuthenticationRequired = { [weak tasks] error in tasks?.recordConnectionFailure(error) }
        sync.recordingSummaries?.onAuthenticationRequired = { [weak tasks] error in tasks?.recordConnectionFailure(error) }
        sync.recordingSummaries?.onChanged = { [weak self] in self?.onSummariesChanged?() }
        health?.onAuthenticationRequired = { [weak tasks] error in tasks?.recordConnectionFailure(error) }
        sources?.onAuthenticationRequired = { [weak tasks] error in tasks?.recordConnectionFailure(error) }
        tasks.prepareSubmission = { task in try await sync.prepareSubmission(input: task.input) }
        if let endpoint = connection.dataURL {
            let dataClient = try AgentClient(baseURL: endpoint, credential: key, assistantID: connection.assistantID, transport: route)
            lifeIllustrations.configure(client: dataClient, scope: connection.workspaceID.uuidString)
        }
        return (tasks, sync, health, sources, network, client)
    }

    private static func openTaskStore(file: URL, connection: AgentConnection, client: AgentClient) throws -> RemoteTaskStore {
        do {
            return try RemoteTaskStore(file: file, connection: connection, client: client)
        } catch {
            struct Header: Decodable { let connection: AgentConnection }
            if let raw = try? Data(contentsOf: file),
               let header = try? JSONDecoder().decode(Header.self, from: raw),
               !header.connection.hasSameIdentity(as: connection) {
                throw error
            }
            let backup = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".corrupted.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: file, to: backup)
            return try RemoteTaskStore(file: file, connection: connection, client: client)
        }
    }

    private static func query(_ id: UUID, service: String = "MoMoAgent.MacConnection") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    private static func readKey(_ id: UUID) throws -> String {
        for service in ["MoMoAgent.MacConnection", "WatchMyLife.MacConnection"] {
            var request = query(id, service: service); request[kSecReturnData as String] = true
            var result: CFTypeRef?
            if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let key = String(data: data, encoding: .utf8) {
                if service != "MoMoAgent.MacConnection" { try? writeKey(key, id: id) }
                return key
            }
        }
        throw ConnectionError.credentialUnavailable
    }

    private static func writeKey(_ key: String, id: UUID) throws {
        let request = query(id), value = Data(key.utf8)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request; item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.credentialUnavailable }
        } else if status != errSecSuccess { throw ConnectionError.credentialUnavailable }
    }

    enum ConnectionError: Error, LocalizedError {
        case identityChanged, credentialUnavailable, unsupported
        var errorDescription: String? {
            switch self {
            case .identityChanged: String(localized: "这份任务记录属于原来的 Mac。当前版本不支持直接更换执行身份，请保留原连接核对任务。")
            case .credentialUnavailable: String(localized: "无法读取或保存 Mac 连接密钥，请重新连接。")
            case .unsupported: String(localized: "这台 Mac 尚未提供持久任务能力，请更新 Mac 运行程序。")
            }
        }
    }
}
