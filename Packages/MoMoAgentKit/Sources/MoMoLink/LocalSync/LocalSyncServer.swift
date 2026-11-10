#if canImport(Network) && (os(iOS) || os(macOS))
import Darwin
import Foundation
import Network
import Security
import MoMoContracts

public struct LocalSyncHandlers: Sendable {
    public let receiverDeviceID: UUID
    public let libraryInstanceID: UUID
    public let receiveChunk: @Sendable (ManifestEnvelope, Data) async throws -> Receipt
    public let applyReceipts: @Sendable ([ReceiptApplied]) async throws -> Int

    public init(
        receiverDeviceID: UUID,
        libraryInstanceID: UUID,
        receiveChunk: @escaping @Sendable (ManifestEnvelope, Data) async throws -> Receipt,
        applyReceipts: @escaping @Sendable ([ReceiptApplied]) async throws -> Int
    ) {
        self.receiverDeviceID = receiverDeviceID
        self.libraryInstanceID = libraryInstanceID
        self.receiveChunk = receiveChunk
        self.applyReceipts = applyReceipts
    }
}

struct LocalSyncPingResponse: Codable, Sendable {
    let receiverDeviceID: UUID
    let libraryInstanceID: UUID
}

struct LocalSyncReceiptsAckResponse: Codable, Sendable {
    let applied: Int
}

public final class LocalSyncServer: @unchecked Sendable {
    private let handlers: LocalSyncHandlers
    private let includeLoopback: Bool
    private let bearerToken: String
    private let queue = DispatchQueue(label: "com.momoagent.link.local-sync-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var pathMonitor: NWPathMonitor?
    private var listeningPort: UInt16?
    private var activeConnections = 0
    private var stopped = false
    private var lastPublishedURLs: [String] = []

    public init(handlers: LocalSyncHandlers, includeLoopback: Bool = false) throws {
        var tokenBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes) == errSecSuccess else {
            throw LinkError.unsupported
        }
        self.handlers = handlers
        self.includeLoopback = includeLoopback
        self.bearerToken = tokenBytes.map { String(format: "%02x", $0) }.joined()
    }

    deinit {
        stop()
    }

    public func start(onEndpointChanged: (@Sendable () -> Void)? = nil) throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let nwListener = try NWListener(using: params, on: .any)
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            var changed = false
            self.lock.lock()
            switch state {
            case .ready:
                let newPort = nwListener.port?.rawValue
                if self.listeningPort != newPort {
                    self.listeningPort = newPort
                    changed = true
                }
            case .failed, .cancelled:
                if self.listeningPort != nil {
                    self.listeningPort = nil
                    changed = true
                }
            default:
                break
            }
            self.lock.unlock()
            if changed { onEndpointChanged?() }
        }
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            let urls = self.currentEndpoint()?.baseURLs ?? []
            var changed = false
            self.lock.lock()
            if urls != self.lastPublishedURLs {
                self.lastPublishedURLs = urls
                changed = true
            }
            self.lock.unlock()
            if changed { onEndpointChanged?() }
        }
        lock.lock()
        listener = nwListener
        pathMonitor = monitor
        stopped = false
        lock.unlock()
        monitor.start(queue: queue)
        nwListener.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        stopped = true
        listeningPort = nil
        let currentListener = listener
        let currentMonitor = pathMonitor
        listener = nil
        pathMonitor = nil
        lock.unlock()
        currentMonitor?.cancel()
        currentListener?.cancel()
    }

    public func currentEndpoint() -> LocalSyncEndpoint? {
        lock.lock()
        let port = listeningPort
        let isStopped = stopped
        lock.unlock()
        guard !isStopped, let port, port > 0 else { return nil }
        var urls = Self.activeLANAddresses().prefix(4).map { "http://\($0):\(port)" }
        if includeLoopback {
            urls.insert("http://127.0.0.1:\(port)", at: 0)
        }
        guard !urls.isEmpty else { return nil }
        return try? LocalSyncEndpoint(baseURLs: Array(urls.prefix(8)), bearerToken: bearerToken)
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if stopped || activeConnections >= 12 {
            lock.unlock()
            connection.cancel()
            return
        }
        activeConnections += 1
        lock.unlock()
        connection.start(queue: queue)
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                connection.cancel()
                self?.releaseActiveConnection()
            }
            guard let self else { return }
            await self.serveHTTPConnection(connection)
        }
    }

    private func releaseActiveConnection() {
        lock.withLock {
            activeConnections = max(0, activeConnections - 1)
        }
    }

    private func serveHTTPConnection(_ connection: NWConnection) async {
        var buffer = Data()
        while !Task.isCancelled {
            do {
                guard let request = try await readHTTPRequest(from: connection, buffer: &buffer) else { return }
                let (status, body, keepAlive) = await handleRequest(request)
                try await writeHTTPResponse(to: connection, status: status, body: body, keepAlive: keepAlive)
                if !keepAlive { return }
            } catch {
                return
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func readHTTPRequest(from connection: NWConnection, buffer: inout Data) async throws -> HTTPRequest? {
        let delimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
        while buffer.range(of: delimiter) == nil {
            if buffer.count > 32_768 { throw LinkError.invalidMetadata }
            guard let chunk = try await receiveChunkData(from: connection, maxBytes: 32_768) else {
                return nil
            }
            buffer.append(chunk)
        }
        guard let headerEnd = buffer.range(of: delimiter) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        buffer.removeSubrange(0..<headerEnd.upperBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { throw LinkError.invalidMetadata }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw LinkError.invalidMetadata }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw LinkError.invalidMetadata }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, Int64(contentLength) <= AudioBlock.maximumFileBytes else {
            throw LinkError.invalidMetadata
        }
        while buffer.count < contentLength {
            let needed = min(262_144, contentLength - buffer.count)
            guard let chunk = try await receiveChunkData(from: connection, maxBytes: max(4_096, needed)) else {
                throw LinkError.invalidMetadata
            }
            buffer.append(chunk)
        }
        let body: Data
        if contentLength > 0 {
            body = buffer.subdata(in: 0..<contentLength)
            buffer.removeSubrange(0..<contentLength)
        } else {
            body = Data()
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func handleRequest(_ request: HTTPRequest) async -> (status: String, body: Data, keepAlive: Bool) {
        let expectedAuth = "Bearer \(bearerToken)"
        guard let auth = request.headers["authorization"], Self.constantTimeEquals(auth, expectedAuth) else {
            return ("401 Unauthorized", Data("{\"error\":\"unauthorized\"}".utf8), false)
        }
        let wantsClose = request.headers["connection"]?.lowercased() == "close"
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/ping"):
                let payload = try WireJSON.encode(LocalSyncPingResponse(
                    receiverDeviceID: handlers.receiverDeviceID,
                    libraryInstanceID: handlers.libraryInstanceID))
                return ("200 OK", payload, !wantsClose)
            case ("POST", "/v1/chunks"):
                guard let encodedEnvelope = request.headers["x-momo-envelope"],
                      let envelopeData = Data(base64Encoded: encodedEnvelope) else {
                    return ("400 Bad Request", Data("{\"error\":\"missing_envelope\"}".utf8), false)
                }
                let envelope = try WireJSON.decode(ManifestEnvelope.self, from: envelopeData)
                let receipt = try await handlers.receiveChunk(envelope, request.body)
                return ("200 OK", try WireJSON.encode(receipt), !wantsClose)
            case ("POST", "/v1/receipts-applied"):
                let items = try WireJSON.decode([ReceiptApplied].self, from: request.body)
                guard items.count <= 128 else {
                    return ("400 Bad Request", Data("{\"error\":\"batch_too_large\"}".utf8), false)
                }
                let applied = try await handlers.applyReceipts(items)
                return ("200 OK", try WireJSON.encode(LocalSyncReceiptsAckResponse(applied: applied)), !wantsClose)
            default:
                return ("404 Not Found", Data("{\"error\":\"not_found\"}".utf8), false)
            }
        } catch {
            return ("422 Unprocessable Entity", Data("{\"error\":\"rejected\"}".utf8), !wantsClose)
        }
    }

    private func receiveChunkData(from connection: NWConnection, maxBytes: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func writeHTTPResponse(to connection: NWConnection, status: String, body: Data, keepAlive: Bool) async throws {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }

    private static func activeLANAddresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var preferred: [String] = []
        var secondary: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostBuffer)
            guard !ip.hasPrefix("169.254."), !ip.hasPrefix("127.") else { continue }
            if name == "en0" {
                if !preferred.contains(ip) { preferred.append(ip) }
            } else if !secondary.contains(ip) && !preferred.contains(ip) {
                secondary.append(ip)
            }
        }
        return preferred + secondary
    }
}
#endif
