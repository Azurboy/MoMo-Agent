import Foundation

/// Owns only scheduler identity and admission. The grant owns execution and its durable stop barrier.
@MainActor
final class ContinuedBackgroundSubmission {
    private struct Request {
        let identifier: String
        let batchID: UUID
        let requestedAt: Date
    }
    private enum State {
        case pending(Request), active(Request)
        var request: Request {
            switch self { case .pending(let request), .active(let request): return request }
        }
    }

    private let prefix: String
    private let register: @MainActor (String) -> Bool
    private let submit: @Sendable (String) async throws -> Void
    private let cancel: @MainActor (String) -> Void
    private let failedAfterLaunch: @MainActor (String) -> Void
    private let now: @MainActor () -> Date
    private var state: State?
    private var cancelledIdentifiers: [String] = []

    init(prefix: String, register: @escaping @MainActor (String) -> Bool,
         submit: @escaping @Sendable (String) async throws -> Void,
         cancel: @escaping @MainActor (String) -> Void,
         failedAfterLaunch: @escaping @MainActor (String) -> Void,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.prefix = prefix
        self.register = register
        self.submit = submit
        self.cancel = cancel
        self.failedAfterLaunch = failedAfterLaunch
        self.now = now
    }

    func request(batchID: UUID) async throws {
        guard state == nil else { throw BackgroundTranscriptionError.alreadyRequested }
        // There is no public unregister API. Never reuse an identifier: registering it twice kills the app.
        let request = Request(identifier: prefix + UUID().uuidString, batchID: batchID, requestedAt: now())
        state = .pending(request)
        guard register(request.identifier) else {
            state = nil
            throw BackgroundTranscriptionError.registrationFailed
        }
        do {
            try await submit(request.identifier)
        } catch {
            cancel(request.identifier)
            switch state {
            case .pending(let current) where current.identifier == request.identifier:
                state = nil
            case .active(let current) where current.identifier == request.identifier:
                // iOS 27 can finish submission after delivery. Keep admission closed until the grant stops.
                failedAfterLaunch(request.identifier)
            default: break
            }
            throw error
        }
        // Cancellation or completion may precede the asynchronous scheduler reply. An old reply must
        // only cancel its own identifier, never clear or cancel a subsequent user's request.
        if state?.request.identifier != request.identifier { cancel(request.identifier) }
    }

    func claim(identifier: String) -> UUID? {
        guard case .pending(let request) = state, request.identifier == identifier else { return nil }
        state = .active(request)
        return request.batchID
    }

    func activeBatchID(for identifier: String) -> UUID? {
        guard case .active(let request) = state, request.identifier == identifier else { return nil }
        return request.batchID
    }

    var pendingIdentifier: String? {
        guard case .pending(let request) = state else { return nil }
        return request.identifier
    }

    var pendingAge: TimeInterval? {
        guard case .pending(let request) = state else { return nil }
        return max(0, now().timeIntervalSince(request.requestedAt))
    }

    var hasActiveGrant: Bool {
        if case .active = state { return true }
        return false
    }

    func wasCancelled(identifier: String) -> Bool {
        cancelledIdentifiers.contains(identifier)
    }

    private func recordCancelled(_ identifier: String) {
        guard !cancelledIdentifiers.contains(identifier) else { return }
        cancelledIdentifiers.append(identifier)
        if cancelledIdentifiers.count > 32 {
            cancelledIdentifiers.removeFirst(cancelledIdentifiers.count - 32)
        }
    }

    func complete(identifier: String) {
        guard case .active(let request) = state, request.identifier == identifier else { return }
        state = nil
    }

    @discardableResult
    func cancelPending(batchID: UUID) -> Bool {
        guard case .pending(let request) = state, request.batchID == batchID else { return false }
        state = nil
        recordCancelled(request.identifier)
        cancel(request.identifier)
        return true
    }

    @discardableResult
    func cancelPending(identifier: String? = nil) -> UUID? {
        guard case .pending(let request) = state,
              identifier == nil || identifier == request.identifier else { return nil }
        state = nil
        recordCancelled(request.identifier)
        cancel(request.identifier)
        return request.batchID
    }
}
