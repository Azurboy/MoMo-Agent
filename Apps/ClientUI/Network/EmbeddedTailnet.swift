import Foundation
import Observation
import Network
import TailscaleKit
import MoMoAgentClient

/// One application node. Login state persists separately from MoMo device authorization.
@MainActor @Observable
final class EmbeddedTailnet {
    private(set) var state = "stopped"
    private(set) var message: String?
    private(set) var authURL: URL?
    private(set) var address: String?
    private(set) var generation = UUID()
    private(set) var node: TailscaleNode?
    private(set) var proxySettings = TailnetProxySettings()
    private(set) var proxySettingsError: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let hostname: String
    @ObservationIgnored private let controlURL: String
    @ObservationIgnored let diagnostics: TailnetDiagnostics
    @ObservationIgnored private var startup: Task<TailscaleNode, Error>?
    @ObservationIgnored private var mappedAddresses = Set<String>()
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var up: Task<Void, Never>?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var interactiveSession: URLSession?
    @ObservationIgnored private var desktopControlSession: URLSession?
    @ObservationIgnored private var desktopMediaSession: URLSession?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var needsRestart = false
    @ObservationIgnored private var needsProxyCheck = false
    @ObservationIgnored private var proxyCheck: Task<Void, Never>?
    @ObservationIgnored private var needsPeerWarmup = true
    @ObservationIgnored private var lastPeerWarmupAt: ContinuousClock.Instant?
    @ObservationIgnored private var peerWarmup: Task<Void, Never>?
    @ObservationIgnored private var signingOut = false
    @ObservationIgnored private var signedOut = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored var startupTimeout: Duration = .seconds(15)
    @ObservationIgnored var peerMapTimeout: Duration = .seconds(12)
    @ObservationIgnored var peerWarmupTimeout: Duration = .seconds(4)

    private static let startupStates: Set<String> = ["starting", "Starting", "NoState", "Stopped", "stopped"]

    init(directory: URL, device: String, controlURL: String = kDefaultControlURL) {
        self.directory = directory
        self.controlURL = controlURL
        do { proxySettings = try TailnetProxySettings.read(from: directory) }
        catch { proxySettingsError = String(localized: "无法读取网络代理设置，请在设置中重新保存。") }
        diagnostics = TailnetDiagnostics(directory: directory)
        hostname = "momo-" + device + "-" + String(directory.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }.suffix(8))
    }

    func start() async throws {
        guard proxySettingsError == nil else { throw TailnetError.unavailable }
        let checkedProxy = needsProxyCheck
        await checkProxyIfNeeded()
        if let closing { await closing.value }
        try Task.checkCancellation()
        guard !signingOut, !signedOut else { throw TailnetError.loginRequired }
        if needsRestart { await close(); return try await start() }
        if let existing = node {
            let attempt = generation
            if checkedProxy || state != "Running" {
                await refreshStatus()
                try Task.checkCancellation()
                guard attempt == generation else { throw CancellationError() }
                if needsRestart { await close(); return try await start() }
            }
            if Self.startupStates.contains(state) {
                ensureNodeUp(existing, attempt: attempt)
            }
            return
        }
        let attempt = generation
        let task: Task<TailscaleNode, Error>
        if let startup { task = startup }
        else {
            state = "starting"; message = nil
            let directory = directory, hostname = hostname, controlURL = controlURL, proxySettings = proxySettings
            task = Task.detached {
                try TailscaleNode.configureProxy(mode: proxySettings.mode.rawValue, address: proxySettings.address)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var protected = directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protected.setResourceValues(values)
                let nameFile = directory.appendingPathComponent("node-name")
                let name: String
                if FileManager.default.fileExists(atPath: nameFile.path) { name = try String(contentsOf: nameFile, encoding: .utf8) }
                else {
                    name = hostname + "-" + UUID().uuidString.prefix(6).lowercased()
                    try Data(name.utf8).write(to: nameFile, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nameFile.path)
                }
                let config = Configuration(hostName: name, path: directory.path, authKey: nil,
                    controlURL: controlURL, ephemeral: false)
                return try TailscaleNode(config: config, logger: nil)
            }
            startup = task
        }
        do {
            let created = try await task.value
            // close() owns cleanup of any startup it supersedes.
            guard attempt == generation else { throw CancellationError() }
            if node != nil { return }
            node = created; startup = nil
            ensureNodeUp(created, attempt: attempt)
            ensureWatchRunning(attempt: attempt)
            startPathMonitor(attempt: attempt)
            await refreshStatus()
        } catch {
            if attempt == generation { startup = nil; state = "failed"; message = String(localized: "无法启动 Tailscale，请重试。") }
            throw error
        }
    }

    private func ensureNodeUp(_ target: TailscaleNode, attempt: UUID) {
        guard up == nil, !signingOut, !signedOut, generation == attempt else { return }
        up = Task { [weak self] in
            defer {
                if let self, self.generation == attempt {
                    self.up = nil
                }
            }
            do { try await target.up() }
            catch {
                guard !Task.isCancelled, let self, self.generation == attempt else { return }
                self.needsRestart = true
                self.state = "failed"
                self.message = String(localized: "Tailscale 暂未连接，请重试。")
            }
        }
    }

    func updateProxy(_ settings: TailnetProxySettings) async throws {
        let validated = try settings.validated()
        try validated.save(to: directory)
        proxySettings = validated; proxySettingsError = nil
        // Close only the network node; its saved identity and device pairing stay.
        // The Mac service refresh starts it again if remote access is enabled.
        await close()
    }

    private struct ParsedTailnetStatus: Sendable {
        let backendState: String
        let address: String?
        let authURL: URL?
        let mappedAddresses: Set<String>
    }

    nonisolated private static func parseStatusJSON(_ data: Data) throws -> ParsedTailnetStatus {
        let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let peers = status["Peer"] as? [String: [String: Any]]
        let mapped = Set((peers ?? [:]).values.filter { $0["InNetworkMap"] as? Bool == true }
            .flatMap { $0["TailscaleIPs"] as? [String] ?? [] })
        let backendState = status["BackendState"] as? String ?? "starting"
        let resolvedAddress = (status["TailscaleIPs"] as? [String] ?? []).first(where: TailnetEndpoint.isAddress)
        let resolvedAuthURL: URL?
        if let raw = status["AuthURL"] as? String, let url = URL(string: raw),
           url.scheme == "https", url.host == "login.tailscale.com" {
            resolvedAuthURL = url
        } else {
            resolvedAuthURL = nil
        }
        return ParsedTailnetStatus(
            backendState: backendState,
            address: resolvedAddress,
            authURL: resolvedAuthURL,
            mappedAddresses: mapped
        )
    }

    func refreshStatus() async {
        guard let node, !(needsRestart && state == "failed") else { return }
        let attempt = generation
        do {
            let data = try await node.statusJSON()
            let parsed = try await Task.detached(priority: .utility) {
                try Self.parseStatusJSON(data)
            }.value
            guard attempt == generation else { return }
            let stateChanged = state != parsed.backendState || address != parsed.address
            mappedAddresses = parsed.mappedAddresses
            if stateChanged {
                diagnostics.recordStatus(data)
            }
            if state != parsed.backendState { state = parsed.backendState }
            if address != parsed.address { address = parsed.address }
            if authURL != parsed.authURL { authURL = parsed.authURL }
            if state == "Running", !needsRestart, message != nil { message = nil }
            if state == "NeedsMachineAuth" {
                let approvalMessage = String(localized: "请在 Tailscale 管理页面允许这台设备加入。")
                if message != approvalMessage { message = approvalMessage }
            }
        } catch {
            if attempt == generation {
                if state != "failed" { state = "failed" }
                let failedMessage = String(localized: "无法读取连接状态，请重试。")
                if message != failedMessage { message = failedMessage }
                needsRestart = true
            }
        }
    }

    func loginURL(timeout: Duration = .seconds(60)) async throws -> URL? {
        guard !signingOut else { throw TailnetError.unavailable }
        signedOut = false
        try await start()
        let attempt = generation
        try Task.checkCancellation()
        guard let node else { throw TailnetError.unavailable }
        await refreshStatus()
        for _ in 0..<12 where Self.startupStates.contains(state) && authURL == nil {
            ensureNodeUp(node, attempt: attempt)
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
            await refreshStatus()
        }
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        if state == "Running" { return nil }
        if state == "NeedsMachineAuth" { throw TailnetError.approvalRequired }
        // Reopening the sheet must reuse an already issued login URL.
        if let authURL { return authURL }
        try? await LocalAPIClient(localNode: node, logger: nil).startLoginInteractive()
        // The request only starts login; network fallback and the auth URL arrive
        // asynchronously. A 4.5-second UI deadline used to reject valid logins.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            await refreshStatus()
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            if state == "Running" { return nil }
            if state == "NeedsMachineAuth" { throw TailnetError.approvalRequired }
            if state == "failed" { throw TailnetError.unavailable }
            if let authURL { return authURL }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining > .zero { try await Task.sleep(for: min(.milliseconds(300), remaining)) }
        }
        throw TailnetError.loginTimedOut
    }

    func connectedSession(peer: String? = nil, interactive: Bool = false, desktopControl: Bool = false, media: Bool = false) async throws -> URLSession {
        try await start()
        ensureWatchRunning(attempt: generation)
        let attempt = generation
        if Self.startupStates.contains(state) {
            if let node { ensureNodeUp(node, attempt: attempt) }
            let startupDeadline = ContinuousClock.now.advanced(by: startupTimeout)
            while Self.startupStates.contains(state), ContinuousClock.now < startupDeadline {
                if let node { ensureNodeUp(node, attempt: attempt) }
                try await Task.sleep(for: .milliseconds(200))
                await refreshStatus()
                guard attempt == generation else { throw CancellationError() }
            }
        }
        guard attempt == generation else { throw CancellationError() }
        guard state == "Running", let node else {
            if state == "NeedsLogin" { throw TailnetError.loginRequired }
            if state == "NeedsMachineAuth" { throw TailnetError.approvalRequired }
            // A node wedged in Stopped/Starting/NoState/failed after startup wait
            // must be recycled on the next attempt instead of trapping reconnect forever.
            needsRestart = true
            throw URLError(.notConnectedToInternet)
        }
        // Running describes the local node. Its first netmap can still omit the
        // paired Mac. Dialing then can select a route outside the peer tunnel.
        if let peer, !mappedAddresses.contains(peer) {
            await refreshStatus()
            guard attempt == generation else { throw CancellationError() }
            if !mappedAddresses.contains(peer) {
                let deadline = ContinuousClock.now.advanced(by: peerMapTimeout)
                while !mappedAddresses.contains(peer) {
                    guard attempt == generation else { throw CancellationError() }
                    guard state == "Running", ContinuousClock.now < deadline else {
                        // A missing remote peer is not evidence that the local listener failed.
                        needsProxyCheck = true
                        throw URLError(.notConnectedToInternet)
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    await refreshStatus()
                }
                guard attempt == generation else { throw CancellationError() }
            }
        }
        if let peer {
            await warmPeerIfNeeded(peer, node: node)
            guard attempt == generation else { throw CancellationError() }
        }
        func cached() -> URLSession? { media ? desktopMediaSession : desktopControl ? desktopControlSession : interactive ? interactiveSession : session }
        if let cached = cached() { return cached }
        let (configuration, _) = try await URLSessionConfiguration.tailscaleSession(node)
        guard attempt == generation else { throw CancellationError() }
        // History and uploads must not occupy the chat connection pool.
        if let cached = cached() { return cached }
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        var proxies = configuration.proxyConfigurations
        for i in proxies.indices { proxies[i].allowFailover = false }
        configuration.proxyConfigurations = proxies
        let created = URLSession(configuration: configuration, delegate: TailnetNoRedirects(diagnostics: diagnostics), delegateQueue: nil)
        if media { desktopMediaSession = created }
        else if desktopControl { desktopControlSession = created }
        else if interactive { interactiveSession = created } else { session = created }
        return created
    }

    private func ensureWatchRunning(attempt: UUID) {
        guard watch == nil, node != nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == attempt else { return }
                await self.refreshStatus()
                let interval: Duration = self.state == "Running" ? .seconds(6) : .seconds(2)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func startPathMonitor(attempt: UUID) {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
            let signature = "\(path.status):\(interfaces)"
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                let previous = self.lastPathSignature
                self.lastPathSignature = signature
                guard previous != nil, previous != signature else { return }
                self.invalidateCachedSessions(finishTasks: true)
                if self.node != nil {
                    self.needsProxyCheck = true
                    self.needsPeerWarmup = true
                    self.lastPeerWarmupAt = nil
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.momoagent.tailnet.path"))
    }

    private func invalidateCachedSessions(finishTasks: Bool) {
        let existing = [session, interactiveSession, desktopControlSession, desktopMediaSession].compactMap { $0 }
        session = nil; interactiveSession = nil; desktopControlSession = nil; desktopMediaSession = nil
        for item in existing {
            if finishTasks { item.finishTasksAndInvalidate() }
            else { item.invalidateAndCancel() }
        }
    }

    func suspendSessions() {
        watch?.cancel(); watch = nil
        peerWarmup?.cancel(); peerWarmup = nil
        invalidateCachedSessions(finishTasks: false)
        if node != nil {
            needsProxyCheck = true
            needsPeerWarmup = true
            lastPeerWarmupAt = nil
        }
    }

    func prewarm(peer: String?) {
        guard !signingOut, !signedOut, proxySettingsError == nil else { return }
        Task { [weak self] in
            _ = try? await self?.connectedSession(peer: peer, interactive: true)
        }
    }

    func prepareForForeground(peer: String? = nil) {
        // iOS can reclaim the SOCKS listener while suspended even if LocalAPI says Running.
        // A brief inactive scene does not mean that listener was reclaimed.
        if let existing = node {
            needsProxyCheck = true
            needsPeerWarmup = true
            lastPeerWarmupAt = nil
            if Self.startupStates.contains(state) {
                ensureNodeUp(existing, attempt: generation)
            }
            ensureWatchRunning(attempt: generation)
            if let peer, TailnetEndpoint.isAddress(peer) {
                let attempt = generation
                Task { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    await self.checkProxyIfNeeded()
                    guard self.generation == attempt, self.state == "Running",
                          let currentNode = self.node, self.mappedAddresses.contains(peer) else { return }
                    await self.warmPeerIfNeeded(peer, node: currentNode)
                }
            }
        }
    }

    func restartForRecovery() async {
        guard !signingOut, !signedOut else { return }
        await close()
    }

    private func owns(_ pool: URLSession) -> Bool {
        pool === session || pool === interactiveSession || pool === desktopControlSession || pool === desktopMediaSession
    }

    func dataTask(for request: URLRequest, using pool: URLSession) throws -> URLSessionDataTask {
        // Foundation raises an Objective-C exception if a task is created after invalidation.
        // Check ownership and create the task together on the same actor that retires pools.
        guard owns(pool) else { throw URLError(.networkConnectionLost) }
        return pool.dataTask(with: request)
    }

    func failedRequest(_ error: Error, session failedSession: URLSession) {
        guard owns(failedSession) else { return }
        guard !AgentTransportFailure.isCancelled(error) else { return }
        let nsError = error as NSError
        let shouldInvalidate: Bool
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            shouldInvalidate = [.badURL, .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(code)
        } else {
            shouldInvalidate = AgentTransportFailure.isSocketOrLinkFailure(error)
        }
        guard shouldInvalidate else { return }
        if failedSession === session { session = nil }
        if failedSession === interactiveSession { interactiveSession = nil }
        if failedSession === desktopControlSession { desktopControlSession = nil }
        if failedSession === desktopMediaSession { desktopMediaSession = nil }
        failedSession.finishTasksAndInvalidate()
        needsProxyCheck = true
        needsPeerWarmup = true
    }

    private enum PeerPingOutcome: Sendable {
        case reachable
        case retryableFailure
        case unsupported
    }

    private func warmPeerIfNeeded(_ peer: String, node: TailscaleNode) async {
        if let peerWarmup {
            await peerWarmup.value
            return
        }
        guard needsPeerWarmup, TailnetEndpoint.isAddress(peer) else { return }
        if let last = lastPeerWarmupAt, last.duration(to: .now) < .seconds(5) {
            needsPeerWarmup = false
            return
        }
        needsPeerWarmup = false
        lastPeerWarmupAt = .now
        let timeout = peerWarmupTimeout
        let attempt = generation
        let task = Task { [weak self] in
            do {
                let (configuration, loopback) = try await URLSessionConfiguration.tailscaleSession(node)
                var proxies = configuration.proxyConfigurations
                for i in proxies.indices { proxies[i].allowFailover = false }
                configuration.proxyConfigurations = proxies
                configuration.urlCache = nil
                let probe = URLSession(configuration: configuration, delegate: TailnetNoRedirects(), delegateQueue: nil)
                defer { probe.invalidateAndCancel() }
                let loopbackAddress = loopback.address
                let auth = "Basic " + Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString()
                let encodedPeer = peer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? peer
                @Sendable func ping(_ kind: String, limit: TimeInterval) async -> PeerPingOutcome {
                    guard let url = URL(string: "http://\(loopbackAddress)/localapi/v0/ping?ip=\(encodedPeer)&type=\(kind)") else {
                        return .unsupported
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = limit
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue(auth, forHTTPHeaderField: "Authorization")
                    request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
                    guard let (data, response) = try? await probe.data(for: request),
                          let http = response as? HTTPURLResponse else {
                        return .unsupported
                    }
                    guard http.statusCode == 200,
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .unsupported
                    }
                    let err = payload["Err"] as? String ?? ""
                    return err.isEmpty ? .reachable : .retryableFailure
                }
                let seconds = max(0.2, Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
                // Wake magicsock DERP + direct UDP discovery and confirm WireGuard tunnel readiness
                // via LocalAPI before dialing through tsnet's 5-second SOCKS5 connect cutoff.
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        _ = await ping("disco", limit: min(2.5, seconds))
                        return false
                    }
                    group.addTask {
                        switch await ping("TSMP", limit: max(0.2, seconds * 0.65)) {
                        case .reachable, .unsupported:
                            return true
                        case .retryableFailure:
                            guard !Task.isCancelled else { return true }
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled else { return true }
                            _ = await ping("TSMP", limit: max(0.2, seconds * 0.45))
                            return true
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: timeout)
                        return true
                    }
                    while let finished = await group.next() {
                        if finished {
                            group.cancelAll()
                            break
                        }
                    }
                }
            } catch {}
            _ = self
            _ = attempt
        }
        peerWarmup = task
        await task.value
        if generation == attempt { peerWarmup = nil }
    }

    private func checkProxyIfNeeded() async {
        if let proxyCheck { await proxyCheck.value; return }
        guard needsProxyCheck, let node else { return }
        needsProxyCheck = false
        let attempt = generation
        let task = Task { [weak self] in
            do {
                let (configuration, loopback) = try await URLSessionConfiguration.tailscaleSession(node)
                var proxies = configuration.proxyConfigurations
                for i in proxies.indices { proxies[i].allowFailover = false }
                configuration.proxyConfigurations = proxies
                configuration.urlCache = nil
                let probe = URLSession(configuration: configuration, delegate: TailnetNoRedirects(), delegateQueue: nil)
                defer { probe.invalidateAndCancel() }
                var request = URLRequest(url: URL(string: "http://\(loopback.address)/localapi/v0/status")!)
                request.timeoutInterval = 3
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Basic " + Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
                let (data, response) = try await probe.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.cannotConnectToHost) }
                if let self, self.generation == attempt,
                   let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let backendState = status["BackendState"] as? String {
                    self.state = backendState
                    if Self.startupStates.contains(backendState) {
                        self.ensureNodeUp(node, attempt: attempt)
                    }
                }
            } catch {
                if self?.generation == attempt { self?.needsRestart = true }
            }
        }
        proxyCheck = task
        await task.value
        if generation == attempt { proxyCheck = nil }
    }

    func close() async {
        if let closing { await closing.value; return }
        generation = UUID(); watch?.cancel(); watch = nil; up?.cancel(); up = nil
        pathMonitor?.cancel(); pathMonitor = nil; lastPathSignature = nil
        needsRestart = false; needsProxyCheck = false; proxyCheck = nil
        peerWarmup?.cancel(); peerWarmup = nil; needsPeerWarmup = true; lastPeerWarmupAt = nil
        invalidateCachedSessions(finishTasks: false)
        let pending = startup
        let old = node; node = nil; startup = nil
        state = "stopped"; authURL = nil; address = nil; mappedAddresses.removeAll()
        let cleanup = Task {
            if let old { try? await old.close() }
            else if let pending, let created = try? await pending.value { try? await created.close() }
        }
        closing = cleanup
        await cleanup.value
        if closing == cleanup { closing = nil }
    }

    func logout() async throws {
        guard !signingOut else { return }
        try await start()
        signingOut = true
        defer { signingOut = false }
        session?.invalidateAndCancel(); session = nil
        interactiveSession?.invalidateAndCancel(); interactiveSession = nil
        desktopControlSession?.invalidateAndCancel(); desktopControlSession = nil
        desktopMediaSession?.invalidateAndCancel(); desktopMediaSession = nil
        if let node { try await node.logout() }
        signedOut = true
        await close(); message = nil
    }

}

enum TailnetError: LocalizedError, TransientTransportError {
    case unavailable, loginRequired, loginUnavailable, loginTimedOut, approvalRequired, invalidEndpoint
    var isTransientTransportFailure: Bool {
        switch self {
        case .unavailable, .loginTimedOut: true
        case .loginRequired, .loginUnavailable, .approvalRequired, .invalidEndpoint: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "连接暂不可用，请重试。")
        case .loginRequired: String(localized: "请先在 MoMo Agent 中登录 Tailscale。")
        case .loginUnavailable: String(localized: "无法打开登录窗口，请重试。")
        case .loginTimedOut: String(localized: "连接 Tailscale 超时，请稍后重试。")
        case .approvalRequired: String(localized: "请在 Tailscale 管理页面允许这台设备加入。")
        case .invalidEndpoint: String(localized: "连接地址已失效，请在 Mac 重新扫码配对。")
        }
    }
}

private final class TailnetNoRedirects: NSObject, URLSessionTaskDelegate {
    private let diagnostics: TailnetDiagnostics?
    init(diagnostics: TailnetDiagnostics? = nil) { self.diagnostics = diagnostics }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        diagnostics?.record(metrics, request: task.originalRequest)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { diagnostics?.recordFailure(error, request: task.originalRequest) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
