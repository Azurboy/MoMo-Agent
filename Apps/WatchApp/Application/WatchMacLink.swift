import Foundation
import MoMoContracts
import MoMoLink
import MoMoRecording
import Observation
import WatchKit

/// The watch owns its outbox. A paired Mac becomes the receiver only after the wearer
/// explicitly selects it. A new local pairing ID invalidates callbacks from previous grants.
@MainActor @Observable
final class WatchMacLink {
    struct Grant: Codable, Sendable, Equatable {
        let id: UUID
        let origin: URL
        let token: String
        let receiver: UUID
        let library: UUID
    }

    enum Failure: LocalizedError {
        case address, code, credentials, response, pairing, service(Int), invalidReceipt
        var errorDescription: String? {
            switch self {
            case .address: String(localized: "请输入 Mac 显示的 HTTPS 地址。")
            case .code: String(localized: "请输入 Mac 显示的 8 位配对码。")
            case .credentials: String(localized: "Mac 授权已失效，请用新配对码重新连接。")
            case .pairing: String(localized: "配对码已失效或不正确，请在 Mac 上重新生成。")
            case .response: String(localized: "Mac 返回了无法读取的响应。")
            case .service(let status): String(localized: "Mac 服务返回 \(status)，原音已保留。")
            case .invalidReceipt: String(localized: "Mac 回执和手表录音不符，原音已保留。")
            }
        }
    }

    private struct PairReply: Decodable {
        let token: String
        let receiver_id: UUID
        let library_id: UUID
    }

    private(set) var grant: Grant?
    private(set) var switching = false
    private(set) var transferring = 0
    private(set) var problem: String?
    private(set) var requiresPairing = false
    var isScheduling: Bool { pumping }
    var ownsRoute: Bool { grant != nil || switching }
    @ObservationIgnored private var observedAt: TimeInterval = -.infinity
    var sessionID: String { (Bundle.main.bundleIdentifier ?? "MoMoAgent.watch") + ".mac-upload" }
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let requests: URLSession
    @ObservationIgnored private var background: URLSession?
    @ObservationIgnored private let delegate = MacUploadDelegate()
    @ObservationIgnored private let refreshTasks = LinkRefreshTasks<ObjectIdentifier>()
    @ObservationIgnored private var responseBytes: [Int: Data] = [:]
    @ObservationIgnored private var processing: Set<Int> = []
    @ObservationIgnored private var accepted = false
    @ObservationIgnored private var finishedEvents = false
    @ObservationIgnored private var nextAttempt: TimeInterval = 0
    @ObservationIgnored private var backoff = LinkRetryBackoff()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastReport: (recording: Bool, pending: Int, sent: TimeInterval)?
    @ObservationIgnored private var reportAgain = false
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var pumpAgain = false
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored var beforeSwitch: (@MainActor () async throws -> Void)?
    @ObservationIgnored var queueChanged: (@MainActor (RecordingQueueSummary) -> Void)?
    @ObservationIgnored var recording: (@MainActor () -> Bool)?
    @ObservationIgnored var currentSession: (@MainActor () -> UUID?)?
    @ObservationIgnored var retryNeeded: (@MainActor () -> Void)?

    init(store: RecordingStore, directory: URL, deviceID: UUID, saved: Grant?) {
        self.store = store
        self.file = directory.appendingPathComponent("mac-receiver.json")
        self.deviceID = deviceID
        self.grant = saved
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.httpCookieStorage = nil
        requests = URLSession(configuration: config, delegate: MacUploadDelegate(), delegateQueue: .main)
        delegate.link = self
    }

    static func saved(in directory: URL) throws -> Grant? {
        do { return try JSONDecoder().decode(Grant.self, from: Data(contentsOf: directory.appendingPathComponent("mac-receiver.json"))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    static func origin(for input: String) throws -> URL {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: raw), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path), let url = parts.url else { throw Failure.address }
        #if targetEnvironment(simulator)
        if parts.scheme?.lowercased() == "http", ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) { return url }
        #endif
        guard parts.scheme?.lowercased() == "https" else { throw Failure.address }
        return url
    }

    func pair(address: String, code: String) async throws {
        guard !switching else { throw WatchRuntimeError.busy }
        let origin = try Self.origin(for: address)
        guard code.utf8.count == 8, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.code }
        switching = true
        defer { switching = false; wake() }
        var request = URLRequest(url: origin.appendingPathComponent("api/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "role": "watch", "code": code, "device_id": deviceID.uuidString.lowercased()])
        let (data, response) = try await requests.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.response }
        if [400, 401, 403, 404, 410].contains(http.statusCode) { throw Failure.pairing }
        guard (200..<300).contains(http.statusCode) else { throw Failure.service(http.statusCode) }
        let reply = try JSONDecoder().decode(PairReply.self, from: data)
        guard !reply.token.isEmpty, reply.token.utf8.count <= 2048,
              reply.token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure.response }
        let next = Grant(id: UUID(), origin: origin, token: reply.token, receiver: reply.receiver_id, library: reply.library_id)
        try await beforeSwitch?()
        cancelRecovery()
        // Persist the selected destination first. After a crash, restoring it completes
        // the same receiver change before any uploader is allowed to clean an original.
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        grant = next
        accepted = false
        requiresPairing = false
        problem = nil
        cursor = 0
        lastReport = nil
        for task in await session().allTasks { task.cancel() }
        try await accept(next)
    }

    func returnToPhone() async throws {
        guard !switching, grant != nil else { return }
        switching = true
        defer { switching = false; wake() }
        cancelRecovery()
        for task in await session().allTasks { task.cancel() }
        try FileManager.default.removeItem(at: file)
        grant = nil
        accepted = false
        requiresPairing = false
        transferring = 0
        problem = nil
        lastReport = nil
        // The ledger retains the old identity until the existing phone confirmation
        // flow accepts its new receiver; stale phone receipts cannot clear the queue.
    }

    func restoreReceiver() async throws {
        if let grant, !accepted { try await accept(grant) }
    }

    private func accept(_ grant: Grant) async throws {
        try await store.replaceReceiverAfterUserConfirmation(deviceID: grant.receiver, libraryInstanceID: grant.library)
        if self.grant == grant { accepted = true }
    }

    private func session() -> URLSession {
        if let background { return background }
        let config = URLSessionConfiguration.background(withIdentifier: sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.httpCookieStorage = nil
        config.httpMaximumConnectionsPerHost = 3
        let created = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        background = created
        return created
    }

    /// Capture advances several times per second. One observation per minute is enough
    /// when nothing else changed; sealing, foreground and receipt events wake immediately.
    func observeCapture() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - observedAt >= 60 else { return }
        observedAt = now
        wake()
    }

    func wake(manually: Bool = false) {
        guard grant != nil, !switching else { return }
        if manually {
            clearBackoff()
            lastReport = nil
        }
        if pumping { pumpAgain = true; return }
        pumping = true
        Task { @MainActor in
            defer {
                pumping = false
                let again = pumpAgain; pumpAgain = false
                if again { wake() }
                completeRefreshIfReady()
            }
            guard let grant else { return }
            do {
                if !accepted { try await accept(grant) }
                guard self.grant == grant, !switching else { return }
                _ = try await store.cleanupAcknowledgedChunks(limit: 16)
                let summary = try await store.queueSummary(sessionID: currentSession?())
                guard self.grant == grant, !switching else { return }
                queueChanged?(summary)
                guard !requiresPairing, ProcessInfo.processInfo.systemUptime >= nextAttempt else { return }
                report(grant, pending: summary.pendingChunkCount)
                let outstanding = await session().allTasks
                guard self.grant == grant, !switching else { return }
                let live = outstanding.compactMap { Self.identity($0.taskDescription) }
                let active = Set(live.filter { $0.grant == grant.id }.map(\.chunk))
                transferring = active.count
                guard active.count < 3, summary.pendingChunkCount > 0 else { return }
                let page = try await store.pendingChunkPage(after: cursor, limit: 8)
                guard self.grant == grant, !switching else { return }
                if page.isEmpty {
                    let wrapped = cursor > 0
                    cursor = 0
                    if wrapped && active.isEmpty { pumpAgain = true }
                    return
                }
                for entry in page {
                    cursor = entry.sequence
                    let chunk = entry.chunk
                    let id = chunk.envelope.manifest.chunkID
                    guard !active.contains(id) else { continue }
                    let request = Self.uploadRequest(for: grant, envelope: chunk.envelope)
                    let task = session().uploadTask(with: request, fromFile: chunk.audioURL)
                    task.taskDescription = grant.id.uuidString + "/" + id.uuidString
                    task.resume()
                    transferring += 1
                    if transferring == 3 { break }
                }
            } catch {
                if self.grant == grant { failed(error) }
            }
        }
    }

    static func uploadRequest(for grant: Grant, envelope: ManifestEnvelope) -> URLRequest {
        var request = request(grant, path: "api/watch/chunks/" + envelope.manifest.chunkID.uuidString.lowercased())
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(envelope.manifestData.base64EncodedString(), forHTTPHeaderField: "X-MoMo-Manifest")
        return request
    }

    private static func request(_ grant: Grant, path: String) -> URLRequest {
        var request = URLRequest(url: grant.origin.appendingPathComponent(path))
        request.setValue("Bearer " + grant.token, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func identity(_ value: String?) -> (grant: UUID, chunk: UUID)? {
        guard let pieces = value?.split(separator: "/"), pieces.count == 2,
              let grant = UUID(uuidString: String(pieces[0])), let chunk = UUID(uuidString: String(pieces[1])) else { return nil }
        return (grant, chunk)
    }

    private func report(_ grant: Grant, pending: Int) {
        let active = recording?() ?? false
        let now = ProcessInfo.processInfo.systemUptime
        if let old = lastReport, active == old.recording, (pending == 0) == (old.pending == 0), now - old.sent < 60 { return }
        guard heartbeat == nil else { reportAgain = true; return }
        lastReport = (active, pending, now)
        heartbeat = Task {
            defer {
                heartbeat = nil
                if reportAgain { reportAgain = false; wake() }
            }
            var request = Self.request(grant, path: "api/watch/status")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: ["recording": active, "pending": pending])
                let (_, response) = try await requests.data(for: request)
                try Self.check(response, for: request)
                if self.grant == grant, transferring == 0, pending == 0 { problem = nil }
            } catch {
                if self.grant == grant && !Task.isCancelled { failed(error) }
            }
        }
    }

    private static func check(_ response: URLResponse?, for request: URLRequest) throws {
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw Failure.response }
        if [401, 403].contains(http.statusCode) { throw Failure.credentials }
        guard (200..<300).contains(http.statusCode) else { throw Failure.service(http.statusCode) }
    }

    fileprivate func received(_ data: Data, task: URLSessionDataTask) {
        // A receipt is small. Never buffer a server error page without a bound.
        if responseBytes[task.taskIdentifier, default: Data()].count + data.count > 32_768 {
            task.cancel()
        } else { responseBytes[task.taskIdentifier, default: Data()].append(data) }
    }

    fileprivate func completed(_ task: URLSessionTask, error: (any Error)?) {
        let data = responseBytes.removeValue(forKey: task.taskIdentifier) ?? Data()
        guard let grant, !switching, let identity = Self.identity(task.taskDescription), identity.grant == grant.id else { return }
        transferring = max(0, transferring - 1)
        let id = task.taskIdentifier
        processing.insert(id)
        Task {
            defer { processing.remove(id); wake(); completeRefreshIfReady() }
            do {
                if let error { throw error }
                guard let original = task.originalRequest else { throw Failure.response }
                try Self.check(task.response, for: original)
                try await acknowledge(data, for: identity.chunk, grant: grant)
                if self.grant == grant, !switching { clearBackoff(); problem = nil }
            } catch {
                if self.grant == grant && !switching { failed(error) }
            }
        }
    }

    func acknowledge(_ data: Data, for chunk: UUID, grant: Grant) async throws {
        guard self.grant == grant, !switching else { throw Failure.invalidReceipt }
        let receipt = try WireJSON.decode(Receipt.self, from: data)
        guard receipt.chunkID == chunk, receipt.receiverDeviceID == grant.receiver,
              receipt.libraryInstanceID == grant.library else { throw Failure.invalidReceipt }
        try await restoreReceiver()
        guard self.grant == grant, !switching else { throw Failure.invalidReceipt }
        // The ledger verifies both hashes and representation before any cleanup. This
        // receiver already has its copy and needs no echo via the iPhone control queue.
        let applied = try await store.applyReceipt(receipt)
        try await store.markControlPreserved(.receiptApplied(applied), receiverDeviceID: grant.receiver, libraryInstanceID: grant.library)
    }

    private func clearBackoff() {
        timer?.cancel()
        timer = nil
        backoff.reset()
        nextAttempt = 0
    }

    private func cancelRecovery() {
        clearBackoff()
        heartbeat?.cancel()
        reportAgain = false
    }

    private func failed(_ error: any Error) {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(urlError.code) {
            problem = String(localized: "暂时连不上 Mac。录音保存在手表上，连接恢复后会自动补传。")
        } else {
            problem = error.localizedDescription
        }
        if case Failure.credentials = error { requiresPairing = true; return }
        guard timer == nil else { return }
        let delay = backoff.nextDelay()
        nextAttempt = ProcessInfo.processInfo.systemUptime + delay
        retryNeeded?()
        timer = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            timer = nil; wake()
        }
    }

    func handleRefresh(_ task: WKURLSessionRefreshBackgroundTask) {
        let id = ObjectIdentifier(task)
        refreshTasks.insert(id) {
            task.expirationHandler = nil
            task.setTaskCompletedWithSnapshot(false)
        }
        task.expirationHandler = { [weak self] in Task { @MainActor in self?.refreshTasks.complete(id) } }
        _ = session()
        completeRefreshIfReady()
    }

    fileprivate func finishedBackgroundEvents() {
        finishedEvents = true
        completeRefreshIfReady()
    }

    private func completeRefreshIfReady() {
        guard finishedEvents, !refreshTasks.isEmpty, processing.isEmpty, !pumping else { return }
        finishedEvents = false
        refreshTasks.completeAll()
    }
}

// URLSession calls this serially on OperationQueue.main, including events delivered
// after a watchOS relaunch. Handle them in order before completing the WatchKit wake.
private final class MacUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    @MainActor weak var link: WatchMacLink?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { link?.received(data, task: dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated { link?.completed(task, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { link?.finishedBackgroundEvents() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
