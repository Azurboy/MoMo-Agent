import Foundation
#if canImport(Network)
import Network
#endif
import MoMoContracts

public enum LocalSyncError: Error, Equatable, Sendable {
    case unreachable
    case unauthorized
    case rejected
    case invalidResponse
    case invalidSource
}

public struct LocalSyncRoute: Equatable, Sendable {
    public enum TransportKind: String, Sendable {
        case directWiFi
        case urlSession
    }
    public let baseURL: URL
    public let host: String
    public let port: UInt16
    public let bearerToken: String
    public let transport: TransportKind
}

private struct LocalSyncPingPayload: Decodable {
    let receiverDeviceID: UUID
    let libraryInstanceID: UUID
}

private struct LocalSyncReceiptsAckPayload: Decodable {
    let applied: Int
}

public final class LocalSyncClient: @unchecked Sendable {
    private let session: URLSession
    #if canImport(Network)
    private let pool = DirectHTTPConnectionPool()
    #endif

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
        #if canImport(Network)
        pool.closeAll()
        #endif
    }

    public func closeConnections() {
        #if canImport(Network)
        pool.closeAll()
        #endif
    }

    public func probe(
        endpoint: LocalSyncEndpoint,
        expectedReceiverDeviceID: UUID,
        expectedLibraryInstanceID: UUID,
        preferDirectWiFi: Bool = true
    ) async -> LocalSyncRoute? {
        var candidates: [(url: URL, host: String, port: UInt16)] = []
        for raw in endpoint.baseURLs {
            guard let comps = URLComponents(string: raw),
                  let url = comps.url,
                  let host = comps.host,
                  let portInt = comps.port,
                  let port = UInt16(exactly: portInt) else { continue }
            candidates.append((url, host, port))
        }
        guard !candidates.isEmpty else { return nil }

        #if canImport(Network)
        if preferDirectWiFi {
            for candidate in candidates {
                let route = LocalSyncRoute(
                    baseURL: candidate.url,
                    host: candidate.host,
                    port: candidate.port,
                    bearerToken: endpoint.bearerToken,
                    transport: .directWiFi)
                if await probeDirectWiFi(route: route,
                                         expectedReceiver: expectedReceiverDeviceID,
                                         expectedLibrary: expectedLibraryInstanceID) {
                    return route
                }
            }
        }
        #endif

        for candidate in candidates {
            let route = LocalSyncRoute(
                baseURL: candidate.url,
                host: candidate.host,
                port: candidate.port,
                bearerToken: endpoint.bearerToken,
                transport: .urlSession)
            if await probeURLSession(route: route,
                                     expectedReceiver: expectedReceiverDeviceID,
                                     expectedLibrary: expectedLibraryInstanceID) {
                return route
            }
        }
        return nil
    }

    public func uploadChunk(
        route: LocalSyncRoute,
        envelope: ManifestEnvelope,
        audioURL: URL
    ) async throws -> Receipt {
        let attrs = try audioURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attrs.isRegularFile == true,
              attrs.fileSize.map(Int64.init) == envelope.manifest.byteCount else {
            throw LocalSyncError.invalidSource
        }
        let audioData = try Data(contentsOf: audioURL)
        guard Int64(audioData.count) == envelope.manifest.byteCount else {
            throw LocalSyncError.invalidSource
        }
        let encodedEnvelope = try WireJSON.encode(envelope).base64EncodedString()
        let responseData: Data
        switch route.transport {
        case .directWiFi:
            #if canImport(Network)
            responseData = try await pool.request(
                route: route,
                method: "POST",
                path: "/v1/chunks",
                extraHeaders: [("X-MoMo-Envelope", encodedEnvelope)],
                body: audioData,
                timeoutSeconds: 12)
            #else
            throw LocalSyncError.unreachable
            #endif
        case .urlSession:
            responseData = try await requestURLSession(
                route: route,
                method: "POST",
                path: "/v1/chunks",
                extraHeaders: [("X-MoMo-Envelope", encodedEnvelope)],
                body: audioData,
                timeoutSeconds: 12)
        }
        let receipt = try WireJSON.decode(Receipt.self, from: responseData)
        guard receipt.matches(envelope) else {
            throw LocalSyncError.invalidResponse
        }
        return receipt
    }

    @discardableResult
    public func sendReceiptsApplied(
        route: LocalSyncRoute,
        items: [ReceiptApplied]
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let body = try WireJSON.encode(items)
        let responseData: Data
        switch route.transport {
        case .directWiFi:
            #if canImport(Network)
            responseData = try await pool.request(
                route: route,
                method: "POST",
                path: "/v1/receipts-applied",
                extraHeaders: [],
                body: body,
                timeoutSeconds: 8)
            #else
            throw LocalSyncError.unreachable
            #endif
        case .urlSession:
            responseData = try await requestURLSession(
                route: route,
                method: "POST",
                path: "/v1/receipts-applied",
                extraHeaders: [],
                body: body,
                timeoutSeconds: 8)
        }
        return try WireJSON.decode(LocalSyncReceiptsAckPayload.self, from: responseData).applied
    }

    private func probeURLSession(
        route: LocalSyncRoute,
        expectedReceiver: UUID,
        expectedLibrary: UUID
    ) async -> Bool {
        do {
            let data = try await requestURLSession(
                route: route,
                method: "GET",
                path: "/v1/ping",
                extraHeaders: [],
                body: nil,
                timeoutSeconds: 2.5)
            let ping = try WireJSON.decode(LocalSyncPingPayload.self, from: data)
            return ping.receiverDeviceID == expectedReceiver && ping.libraryInstanceID == expectedLibrary
        } catch {
            return false
        }
    }

    private func requestURLSession(
        route: LocalSyncRoute,
        method: String,
        path: String,
        extraHeaders: [(String, String)],
        body: Data?,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: route.baseURL) else {
            throw LocalSyncError.unreachable
        }
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.httpMethod = method
        req.setValue("Bearer \(route.bearerToken)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response): (Data, URLResponse)
        if let body {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            (data, response) = try await session.upload(for: req, from: body)
        } else {
            (data, response) = try await session.data(for: req)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalSyncError.invalidResponse
        }
        switch http.statusCode {
        case 200: return data
        case 401: throw LocalSyncError.unauthorized
        case 400..<500: throw LocalSyncError.rejected
        default: throw LocalSyncError.unreachable
        }
    }

    #if canImport(Network)
    private func probeDirectWiFi(
        route: LocalSyncRoute,
        expectedReceiver: UUID,
        expectedLibrary: UUID
    ) async -> Bool {
        do {
            let data = try await pool.request(
                route: route,
                method: "GET",
                path: "/v1/ping",
                extraHeaders: [],
                body: Data(),
                timeoutSeconds: 2.5)
            let ping = try WireJSON.decode(LocalSyncPingPayload.self, from: data)
            return ping.receiverDeviceID == expectedReceiver && ping.libraryInstanceID == expectedLibrary
        } catch {
            return false
        }
    }
    #endif
}

#if canImport(Network)
private final class DirectHTTPConnectionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var idle: [String: [DirectHTTPConnection]] = [:]

    func closeAll() {
        lock.lock()
        let all = idle.values.flatMap { $0 }
        idle.removeAll()
        lock.unlock()
        for conn in all { conn.close() }
    }

    func request(
        route: LocalSyncRoute,
        method: String,
        path: String,
        extraHeaders: [(String, String)],
        body: Data,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        let key = "\(route.host):\(route.port)"
        if let reused = takeIdle(key: key) {
            do {
                let data = try await reused.execute(
                    route: route,
                    method: method,
                    path: path,
                    extraHeaders: extraHeaders,
                    body: body,
                    timeoutSeconds: timeoutSeconds)
                returnIdle(reused, key: key)
                return data
            } catch {
                reused.close()
                if let syncErr = error as? LocalSyncError,
                   syncErr == .unauthorized || syncErr == .rejected {
                    throw syncErr
                }
            }
        }
        let fresh = DirectHTTPConnection(host: route.host, port: route.port)
        do {
            try await fresh.connect(timeoutSeconds: min(3.0, timeoutSeconds))
            let data = try await fresh.execute(
                route: route,
                method: method,
                path: path,
                extraHeaders: extraHeaders,
                body: body,
                timeoutSeconds: timeoutSeconds)
            returnIdle(fresh, key: key)
            return data
        } catch {
            fresh.close()
            throw error
        }
    }

    private func takeIdle(key: String) -> DirectHTTPConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard var list = idle[key], !list.isEmpty else { return nil }
        let conn = list.removeLast()
        idle[key] = list
        return conn
    }

    private func returnIdle(_ conn: DirectHTTPConnection, key: String) {
        lock.lock()
        var list = idle[key] ?? []
        if list.count < 4 {
            list.append(conn)
            idle[key] = list
            lock.unlock()
        } else {
            lock.unlock()
            conn.close()
        }
    }
}

private final class DirectHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.momoagent.link.direct-wifi")
    private var readBuffer = Data()

    init(host: String, port: UInt16) {
        let params = NWParameters.tcp
        params.serviceClass = .responsiveData
        if host != "127.0.0.1" && host != "localhost" {
            params.requiredInterfaceType = .wifi
        }
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .http
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    func close() {
        connection.cancel()
    }

    func connect(timeoutSeconds: TimeInterval) async throws {
        let gate = OnceGate<Void>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, timeoutSeconds: timeoutSeconds, onTimeout: { [connection] in
                    connection.cancel()
                    return LocalSyncError.unreachable
                })
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        gate.finish(.success(()))
                    case .failed(let err):
                        connection.stateUpdateHandler = nil
                        gate.finish(.failure(err))
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        gate.finish(.failure(LocalSyncError.unreachable))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
            gate.finish(.failure(CancellationError()))
        }
    }

    func execute(
        route: LocalSyncRoute,
        method: String,
        path: String,
        extraHeaders: [(String, String)],
        body: Data,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        var headerLines = [
            "\(method) \(path) HTTP/1.1",
            "Host: \(route.host):\(route.port)",
            "Authorization: Bearer \(route.bearerToken)",
            "Content-Length: \(body.count)",
            "Connection: keep-alive"
        ]
        for (k, v) in extraHeaders {
            headerLines.append("\(k): \(v)")
        }
        let headerString = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var packet = Data(headerString.utf8)
        packet.append(body)

        try await sendAll(packet, timeoutSeconds: timeoutSeconds)
        return try await readResponse(timeoutSeconds: timeoutSeconds)
    }

    private func sendAll(_ data: Data, timeoutSeconds: TimeInterval) async throws {
        let gate = OnceGate<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, timeoutSeconds: timeoutSeconds, onTimeout: { [connection] in
                    connection.cancel()
                    return LocalSyncError.unreachable
                })
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { gate.finish(.failure(error)) }
                    else { gate.finish(.success(())) }
                })
            }
        } onCancel: {
            connection.cancel()
            gate.finish(.failure(CancellationError()))
        }
    }

    private func readResponse(timeoutSeconds: TimeInterval) async throws -> Data {
        let delimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
        while readBuffer.range(of: delimiter) == nil {
            if readBuffer.count > 32_768 { throw LocalSyncError.invalidResponse }
            let chunk = try await receiveOnce(maxBytes: 32_768, timeoutSeconds: timeoutSeconds)
            guard !chunk.isEmpty else { throw LocalSyncError.unreachable }
            readBuffer.append(chunk)
        }
        guard let headerEnd = readBuffer.range(of: delimiter) else {
            throw LocalSyncError.invalidResponse
        }
        let headerData = readBuffer.subdata(in: 0..<headerEnd.lowerBound)
        readBuffer.removeSubrange(0..<headerEnd.upperBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw LocalSyncError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw LocalSyncError.invalidResponse }
        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw LocalSyncError.invalidResponse
        }
        var contentLength = 0
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if k == "content-length", let n = Int(v), n >= 0 {
                contentLength = n
            }
        }
        guard contentLength <= 1_048_576 else { throw LocalSyncError.invalidResponse }
        while readBuffer.count < contentLength {
            let chunk = try await receiveOnce(maxBytes: max(4_096, contentLength - readBuffer.count),
                                              timeoutSeconds: timeoutSeconds)
            guard !chunk.isEmpty else { throw LocalSyncError.unreachable }
            readBuffer.append(chunk)
        }
        let body: Data
        if contentLength > 0 {
            body = readBuffer.subdata(in: 0..<contentLength)
            readBuffer.removeSubrange(0..<contentLength)
        } else {
            body = Data()
        }
        switch statusCode {
        case 200: return body
        case 401: throw LocalSyncError.unauthorized
        case 400..<500: throw LocalSyncError.rejected
        default: throw LocalSyncError.unreachable
        }
    }

    private func receiveOnce(maxBytes: Int, timeoutSeconds: TimeInterval) async throws -> Data {
        let gate = OnceGate<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, timeoutSeconds: timeoutSeconds, onTimeout: { [connection] in
                    connection.cancel()
                    return LocalSyncError.unreachable
                })
                connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { content, _, isComplete, error in
                    if let error {
                        gate.finish(.failure(error))
                    } else if let content, !content.isEmpty {
                        gate.finish(.success(content))
                    } else if isComplete {
                        gate.finish(.success(Data()))
                    } else {
                        gate.finish(.failure(LocalSyncError.unreachable))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
            gate.finish(.failure(CancellationError()))
        }
    }
}

private final class OnceGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var completed = false
    private var timeoutTask: Task<Void, Never>?

    func install(
        _ cont: CheckedContinuation<Value, any Error>,
        timeoutSeconds: TimeInterval,
        onTimeout: @escaping @Sendable () -> any Error
    ) {
        lock.lock()
        if completed {
            lock.unlock()
            cont.resume(throwing: CancellationError())
            return
        }
        continuation = cont
        let nanos = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
        timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.finish(.failure(onTimeout()))
        }
        lock.unlock()
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let cont = continuation
        let timer = timeoutTask
        continuation = nil
        timeoutTask = nil
        lock.unlock()
        timer?.cancel()
        cont?.resume(with: result)
    }
}
#endif
