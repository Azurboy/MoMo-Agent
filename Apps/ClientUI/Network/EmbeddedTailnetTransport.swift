import Foundation
import MoMoAgentClient

struct EmbeddedTailnetTransport: AgentTransport {
    let network: EmbeddedTailnet
    let endpoint: URL
    let requiresExclusiveRouting = true

    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        guard TailnetEndpoint.isOrigin(endpoint), let url = request.url, TailnetEndpoint.accepts(url),
              url.host == endpoint.host, url.port == endpoint.port else { throw TailnetError.invalidEndpoint }
        await network.diagnostics.observePeer(endpoint.host)
        let desktop = url.path.hasPrefix("/desktop/")
        let media = desktop && ["frame", "frames"].contains(url.lastPathComponent)
        do {
            return try await openOnce(request, url: url, desktop: desktop, media: media)
        } catch {
            guard Self.canRetryBeforeResponse(request, after: error) else { throw error }
            try await Task.sleep(for: .milliseconds(250))
            return try await openOnce(request, url: url, desktop: desktop, media: media)
        }
    }

    private func openOnce(_ request: URLRequest, url: URL, desktop: Bool, media: Bool) async throws -> AgentByteStream {
        let session = try await network.connectedSession(peer: endpoint.host, interactive: request.networkServiceType == .responsiveData,
                                                          desktopControl: desktop && !media, media: media)
        do {
            if url.path == "/desktop/v1/frames" {
                let diagnostics = await network.diagnostics
                return try await AgentHTTPStream.open(request, configuration: session.configuration) { metrics in
                    diagnostics.record(metrics, request: request)
                }
            }
            if desktop {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw URLError(.networkConnectionLost) }
                guard data.count <= 3 * 1024 * 1024 else { throw AgentClientError.responseTooLarge }
                return AgentByteStream(status: response.statusCode, contentType: response.mimeType, chunks: AsyncThrowingStream { continuation in
                    continuation.yield(data); continuation.finish()
                })
            }
            let diagnostics = await network.diagnostics
            return try await TailnetChunkStream.open(request: request, session: session, diagnostics: diagnostics) { error in
                guard !AgentTransportFailure.isCancelled(error), !(error is AgentClientError) else { return }
                Task { @MainActor in network.failedRequest(error, session: session) }
            }
        } catch {
            if !AgentTransportFailure.isCancelled(error), !(error is AgentClientError) {
                await network.failedRequest(error, session: session)
            }
            throw error
        }
    }

    private static func canRetryBeforeResponse(_ request: URLRequest, after error: Error) -> Bool {
        guard !AgentTransportFailure.isCancelled(error), !(error is AgentClientError) else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        let idempotent = ["GET", "HEAD"].contains(method) || request.value(forHTTPHeaderField: "Idempotency-Key") != nil
        guard idempotent, request.httpBodyStream == nil else { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            return [.badURL, .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(code)
        }
        return AgentTransportFailure.isSocketOrLinkFailure(error)
    }
}

private final class TailnetChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBufferedBytes = 16 * 1024 * 1024

    private let lock = NSLock()
    private let diagnostics: TailnetDiagnostics
    private let onTransportFailure: @Sendable (Error) -> Void
    private var head: CheckedContinuation<AgentByteStream, Error>?
    private var task: URLSessionDataTask?
    private var pendingChunks: [Data] = []
    private var headIndex = 0
    private var bufferedBytes = 0
    private var consumer: CheckedContinuation<Data?, Error>?
    private var completion: Result<Void, Error>?
    private var cancelled = false

    private init(diagnostics: TailnetDiagnostics, onTransportFailure: @escaping @Sendable (Error) -> Void) {
        self.diagnostics = diagnostics
        self.onTransportFailure = onTransportFailure
    }

    static func open(
        request: URLRequest,
        session: URLSession,
        diagnostics: TailnetDiagnostics,
        onTransportFailure: @escaping @Sendable (Error) -> Void
    ) async throws -> AgentByteStream {
        let owner = TailnetChunkStream(diagnostics: diagnostics, onTransportFailure: onTransportFailure)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                owner.lock.withLock {
                    if owner.cancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    owner.head = continuation
                    let task = session.dataTask(with: request)
                    task.delegate = owner
                    owner.task = task
                    task.resume()
                }
            }
        } onCancel: {
            owner.cancelConsumer()
        }
    }

    private func nextChunk() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<Data?, Error>?
                lock.withLock {
                    if cancelled {
                        immediate = .failure(CancellationError())
                    } else if headIndex < pendingChunks.count {
                        let chunk = pendingChunks[headIndex]
                        pendingChunks[headIndex] = Data()
                        headIndex += 1
                        bufferedBytes -= chunk.count
                        if headIndex == pendingChunks.count {
                            pendingChunks.removeAll(keepingCapacity: true)
                            headIndex = 0
                        }
                        immediate = .success(chunk)
                    } else if let completion {
                        switch completion {
                        case .success: immediate = .success(nil)
                        case .failure(let error): immediate = .failure(error)
                        }
                    } else {
                        consumer = continuation
                    }
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            self.cancelConsumer()
        }
    }

    private func cancelConsumer() {
        let (head, consumer, task) = lock.withLock { () -> (CheckedContinuation<AgentByteStream, Error>?, CheckedContinuation<Data?, Error>?, URLSessionDataTask?) in
            cancelled = true
            if completion == nil { completion = .failure(CancellationError()) }
            pendingChunks.removeAll()
            headIndex = 0
            bufferedBytes = 0
            let current = (self.head, self.consumer, self.task)
            self.head = nil
            self.consumer = nil
            self.task = nil
            return current
        }
        task?.cancel()
        head?.resume(throwing: CancellationError())
        consumer?.resume(throwing: CancellationError())
    }

    private func failOverflow() {
        let (consumer, task) = lock.withLock { () -> (CheckedContinuation<Data?, Error>?, URLSessionDataTask?) in
            cancelled = true
            completion = .failure(AgentClientError.responseTooLarge)
            pendingChunks.removeAll()
            headIndex = 0
            bufferedBytes = 0
            let current = (self.consumer, self.task)
            self.consumer = nil
            self.task = nil
            return current
        }
        task?.cancel()
        consumer?.resume(throwing: AgentClientError.responseTooLarge)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let head = lock.withLock { () -> CheckedContinuation<AgentByteStream, Error>? in
            let current = self.head
            self.head = nil
            return current
        }
        guard let response = response as? HTTPURLResponse else {
            lock.withLock { completion = .failure(AgentClientError.invalidResponse); task = nil }
            head?.resume(throwing: AgentClientError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        let lifetime = TailnetStreamLifetime { self.cancelConsumer() }
        let chunks = AsyncThrowingStream<Data, Error>(unfolding: {
            _ = lifetime
            return try await self.nextChunk()
        })
        head?.resume(returning: AgentByteStream(
            status: response.statusCode,
            contentType: response.mimeType,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            chunks: chunks,
            cancel: { self.cancelConsumer() }
        ))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        var waiter: CheckedContinuation<Data?, Error>?
        var overflowed = false
        lock.withLock {
            guard !cancelled, completion == nil else { return }
            if let current = consumer {
                consumer = nil
                waiter = current
            } else if bufferedBytes + data.count > Self.maximumBufferedBytes {
                overflowed = true
            } else {
                pendingChunks.append(data)
                bufferedBytes += data.count
            }
        }
        if let waiter {
            waiter.resume(returning: data)
        } else if overflowed {
            failOverflow()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var headWaiter: CheckedContinuation<AgentByteStream, Error>?
        var chunkWaiter: CheckedContinuation<Data?, Error>?
        var reportTransportError: Error?
        lock.withLock {
            self.task = nil
            let wasCancelled = cancelled
            if let error {
                if !wasCancelled {
                    completion = .failure(error)
                    reportTransportError = error
                }
            } else if completion == nil {
                completion = .success(())
            }
            headWaiter = head
            head = nil
            if headIndex >= pendingChunks.count {
                chunkWaiter = consumer
                consumer = nil
            }
        }
        if let error = reportTransportError {
            diagnostics.recordFailure(error, request: task.originalRequest)
            onTransportFailure(error)
        }
        if let headWaiter {
            headWaiter.resume(throwing: error ?? URLError(.networkConnectionLost))
        }
        if let chunkWaiter {
            if let error = reportTransportError {
                chunkWaiter.resume(throwing: error)
            } else {
                chunkWaiter.resume(returning: nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        diagnostics.record(metrics, request: task.originalRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class TailnetStreamLifetime: Sendable {
    private let onDeinit: @Sendable () -> Void
    init(_ onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}
