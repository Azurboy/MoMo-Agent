import Foundation

/// Transport only. The caller persists operation/session IDs before submitting.
/// Cancelling a local Task detaches that request; stopping remote work is explicit.
public struct AgentClient: Sendable {
    private let baseURL: URL
    private let credential: String
    private let assistantID: UUID
    private let managedSession: ManagedURLSession
    private var session: URLSession { managedSession.session }
    private let transport: (any AgentTransport)?

    public init(
        baseURL: URL,
        credential: String,
        assistantID: UUID,
        configuration: URLSessionConfiguration? = nil,
        transport: (any AgentTransport)? = nil
    ) throws {
        let host = baseURL.host?.lowercased() ?? ""
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        let privateRoute = transport?.requiresExclusiveRouting == true && TailnetEndpoint.accepts(baseURL)
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && loopback) || privateRoute,
              !host.isEmpty, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw AgentClientError.invalidEndpoint
        }
        guard !credential.isEmpty,
              !credential.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentClientError.invalidCredential
        }
        self.baseURL = baseURL
        self.credential = credential
        self.assistantID = assistantID
        self.transport = transport
        self.managedSession = ManagedURLSession(configuration: configuration)
    }

    public func capabilities() async throws -> AgentCapabilities {
        try JSONDecoder().decode(AgentCapabilities.self, from: await request(path: ["v1", "capabilities"]))
    }

    public func desktopFrames() -> AsyncThrowingStream<DesktopPicture, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task {
                do {
                    var request = try makeRequest(path: ["desktop", "v1", "frames"])
                    request.setValue("multipart/x-mixed-replace", forHTTPHeaderField: "Accept")
                    let stream: AgentByteStream
                    if let routed = try await transport?.open(request) { stream = routed }
                    else {
                        guard transport?.requiresExclusiveRouting != true else { throw URLError(.notConnectedToInternet) }
                        stream = try await AgentHTTPStream.open(request, configuration: session.configuration)
                    }
                    defer { stream.cancel() }
                    guard stream.status == 200 else { throw AgentClientError.http(status: stream.status, code: nil, message: nil, retryAfter: nil) }
                    guard stream.contentType == "multipart/x-mixed-replace" else { throw AgentClientError.invalidResponse }
                    var parser = DesktopJPEGParser()
                    for try await chunk in stream.chunks {
                        try Task.checkCancellation()
                        for picture in try parser.append(chunk) { continuation.yield(picture) }
                    }
                    throw URLError(.networkConnectionLost)
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    func warmSubmission() async throws {
        var request = try makeRequest(path: ["v1", "capabilities"])
        request.networkServiceType = .responsiveData
        request.timeoutInterval = 5
        if let stream = try await transport?.open(request) {
            var size = 0
            for try await chunk in stream.chunks {
                try Task.checkCancellation(); size += chunk.count
                guard size <= 256 * 1024 else { throw AgentClientError.responseTooLarge }
            }
        } else {
            guard transport?.requiresExclusiveRouting != true else { throw URLError(.notConnectedToInternet) }
            _ = try await session.data(for: request, delegate: NoRedirects.shared)
        }
    }

    public func submit(input: String, sessionID: String, operationID: UUID) async throws -> AgentRun {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sessionID.isEmpty else { throw AgentClientError.invalidInput }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Submission(input: input, sessionID: sessionID))
        return try JSONDecoder().decode(AgentRun.self, from: await request(
            path: ["v1", "runs"], method: "POST", body: body, operationID: operationID
        ))
    }

    public func run(id: String) async throws -> AgentRun {
        try JSONDecoder().decode(AgentRun.self, from: await request(path: ["v1", "runs", id]))
    }

    /// Acknowledges the request only. Poll the run to confirm a terminal state.
    public func requestStop(runID: String) async throws {
        _ = try await request(path: ["v1", "runs", runID, "stop"], method: "POST", body: Data("{}".utf8))
    }

    func request(
        path: [String], method: String = "GET", body: Data? = nil, operationID: UUID? = nil, query: [URLQueryItem] = []
    ) async throws -> Data {
        let request = try makeRequest(path: path, method: method, body: body, operationID: operationID, query: query)
        let data: Data
        let status: Int
        let retryAfter: String?
        if let stream = try await transport?.open(request) {
            var received = Data()
            for try await chunk in stream.chunks {
                try Task.checkCancellation()
                guard received.count + chunk.count <= 8 * 1024 * 1024 else { throw AgentClientError.responseTooLarge }
                received.append(chunk)
            }
            data = received; status = stream.status; retryAfter = stream.retryAfter
        } else {
            guard transport?.requiresExclusiveRouting != true else { throw URLError(.notConnectedToInternet) }
            defer { _ = managedSession }
            let result = try await session.data(for: request, delegate: NoRedirects.shared)
            guard let response = result.1 as? HTTPURLResponse else { throw AgentClientError.invalidResponse }
            data = result.0; status = response.statusCode; retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        }
        guard (200..<300).contains(status) else {
            let failure = try? JSONDecoder().decode(FailureEnvelope.self, from: data)
            throw AgentClientError.http(status: status, code: failure?.error.code,
                                        message: failure?.error.message, retryAfter: Self.retryDelay(retryAfter))
        }
        return data
    }

    struct SubmissionFeed: Sendable {
        let receipt: AgentRun
        let events: AsyncThrowingStream<AgentRunEvent, Error>
    }

    func submitMessageFeed(input: String, operationID: UUID, targetRunID: String?, generation: Int?, workID: String?, attachments: [AgentAttachment]? = nil) async throws -> SubmissionFeed {
        let body = try messageBody(input: input, operationID: operationID, targetRunID: targetRunID, generation: generation, workID: workID, attachments: attachments)
        let request = try makeRequest(path: ["momo", "v1", "conversation", "messages"], method: "POST", body: body)
        let feed = events(for: request)
        // Consume only the receipt. The same bounded feed retains subsequent frames,
        // including a reply coalesced with the receipt in one network read.
        for try await event in feed {
            guard event.event == "run.accepted", let receipt = event.receipt,
                  !receipt.runID.isEmpty, receipt.runID == event.runID else { throw AgentClientError.invalidResponse }
            return SubmissionFeed(receipt: receipt, events: feed)
        }
        throw AgentClientError.invalidResponse
    }

    public func observe(runID: String, after sequence: Int?, receive: @Sendable (AgentRunEvent) async throws -> Void) async throws {
        var request = try makeRequest(path: ["v1", "runs", runID, "events"])
        if let sequence { request.setValue(String(sequence), forHTTPHeaderField: "Last-Event-ID") }
        for try await event in events(for: request) {
            guard event.runID == runID else { throw AgentClientError.invalidResponse }
            try await receive(event)
        }
    }

    func conversationEvents(after cursor: Int, idleTimeout: TimeInterval = 30) throws -> AsyncThrowingStream<ConversationEvent, Error> {
        var request = try makeRequest(path: ["momo", "v1", "conversation", "subscribe"], query: [.init(name: "after", value: String(cursor))])
        request.networkServiceType = .responsiveData
        request.timeoutInterval = idleTimeout
        return decodedEvents(for: request, idleTimeout: idleTimeout, frameLimit: 8 * 1024 * 1024)
    }

    private func events(for request: URLRequest) -> AsyncThrowingStream<AgentRunEvent, Error> {
        decodedEvents(for: request)
    }

    private func decodedEvents<Event: Decodable & Sendable>(for original: URLRequest, idleTimeout: TimeInterval = 45, frameLimit: Int = 512 * 1024) -> AsyncThrowingStream<Event, Error> {
        var request = original
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let eventRequest = request
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let worker = Task {
                do {
                    let activity = StreamActivity()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            var parser = SSEFrameParser(maximumBytes: frameLimit)
                            func consume(_ byte: UInt8) throws {
                                try Task.checkCancellation()
                                if let data = try parser.append(byte) {
                                    let event = try JSONDecoder().decode(Event.self, from: data)
                                    if case .dropped = continuation.yield(event) { throw AgentClientError.responseTooLarge }
                                }
                            }
                            if let stream = try await transport?.open(eventRequest) {
                                guard stream.status == 200 else { throw AgentClientError.http(status: stream.status, code: nil, message: nil, retryAfter: Self.retryDelay(stream.retryAfter)) }
                                guard stream.contentType == "text/event-stream" else { throw AgentClientError.invalidResponse }
                                for try await chunk in stream.chunks {
                                    activity.touch()
                                    for byte in chunk { try consume(byte) }
                                }
                            } else {
                                guard transport?.requiresExclusiveRouting != true else { throw URLError(.notConnectedToInternet) }
                                defer { _ = managedSession }
                                let (bytes, response) = try await session.bytes(for: eventRequest, delegate: NoRedirects.shared)
                                guard let response = response as? HTTPURLResponse else { throw AgentClientError.invalidResponse }
                                guard response.statusCode == 200 else {
                                    throw AgentClientError.http(status: response.statusCode, code: nil, message: nil, retryAfter: Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After")))
                                }
                                guard response.mimeType == "text/event-stream" else { throw AgentClientError.invalidResponse }
                                for try await byte in bytes {
                                    if byte == 10 { activity.touch() }
                                    try consume(byte)
                                }
                            }
                        }
                    group.addTask {
                        while !Task.isCancelled {
                            let remaining = idleTimeout - activity.idle
                            if remaining <= 0 { throw URLError(.timedOut) }
                            try await Task.sleep(for: .seconds(max(1.0, remaining)))
                            if activity.idle >= idleTimeout { throw URLError(.timedOut) }
                        }
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    public static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return min(3600, max(0, seconds)) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return format.date(from: value).map { min(3600, max(0, $0.timeIntervalSince(now))) }
    }

    private func makeRequest(path: [String], method: String = "GET", body: Data? = nil,
                             operationID: UUID? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentClientError.invalidInput
        }
        let suffix = path.map { $0.addingPercentEncoding(withAllowedCharacters: safe)! }.joined(separator: "/")
        let prefix = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        guard let url = URL(string: prefix + suffix) else { throw AgentClientError.invalidEndpoint }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let endpoint = components.url else { throw AgentClientError.invalidEndpoint }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        if method == "POST" && (path == ["momo", "v1", "conversation", "messages"] || path == ["v1", "runs"]) || path.last == "events" {
            request.networkServiceType = .responsiveData
        }
        request.timeoutInterval = 30
        if path.first == "desktop" {
            request.timeoutInterval = path.starts(with: ["desktop", "v2"]) ? 12 : 8
            request.networkServiceType = path.last == "frames" || path.last == "frame" ? .responsiveAV : .responsiveData
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("momo:\(assistantID.uuidString.lowercased())", forHTTPHeaderField: "X-MoMo-Session-Key")
        if let operationID {
            request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }
        return request
    }
}

private struct Submission: Encodable {
    let input: String
    let sessionID: String
    enum CodingKeys: String, CodingKey { case input; case sessionID = "session_id" }
}

private struct FailureEnvelope: Decodable {
    struct Failure: Decodable { let code: String?; let message: String? }
    let error: Failure
}

final class ManagedURLSession: Sendable {
    static let sharedEphemeral = URLSession(configuration: .ephemeral)
    let session: URLSession
    private let ownsSession: Bool

    init(configuration: URLSessionConfiguration?) {
        if let configuration {
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        } else {
            self.session = Self.sharedEphemeral
            self.ownsSession = false
        }
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirects()
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class StreamActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    func touch() { lock.withLock { last = ContinuousClock.now } }
    var idle: TimeInterval {
        let elapsed = lock.withLock { last.duration(to: ContinuousClock.now) }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
