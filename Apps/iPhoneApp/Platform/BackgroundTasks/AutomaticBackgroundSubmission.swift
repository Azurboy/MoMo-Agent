import Foundation

/// Serializes the fixed task identifier so a late submit cannot undo a user's cancellation.
@MainActor
final class AutomaticBackgroundSubmission {
    private let eligible: @MainActor () async throws -> Bool
    private let submit: @Sendable () async throws -> Void
    private let cancel: @MainActor () -> Void
    private let failure: @MainActor () -> Void
    private let uptime: @MainActor () -> Double
    private var running = false
    private var requested = false
    private var generation: UInt64 = 0
    private var pending = false
    private var pendingVerifiedUptime: Double = -.infinity
    private var deliveryRevision: UInt64 = 0

    init(eligible: @escaping @MainActor () async throws -> Bool,
         submit: @escaping @Sendable () async throws -> Void,
         cancel: @escaping @MainActor () -> Void, failure: @escaping @MainActor () -> Void,
         uptime: @escaping @MainActor () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) * 1e-9 }) {
        self.eligible = eligible
        self.submit = submit
        self.cancel = cancel
        self.failure = failure
        self.uptime = uptime
    }

    func request() async {
        if pending, uptime() - pendingVerifiedUptime < 60 { return }
        requested = true
        guard !running else { return }
        running = true
        defer { running = false }
        while requested {
            requested = false
            if pending, uptime() - pendingVerifiedUptime < 60 { continue }
            let submittedGeneration = generation, submittedDelivery = deliveryRevision
            do {
                guard try await eligible(), submittedGeneration == generation else { continue }
                try await submit()
                if submittedGeneration != generation { cancel() }
                else if submittedDelivery == deliveryRevision {
                    pending = true
                    pendingVerifiedUptime = uptime()
                }
            } catch {
                if submittedGeneration == generation { failure() }
            }
        }
    }

    func cancelByUser() {
        generation &+= 1
        requested = false
        pending = false
        pendingVerifiedUptime = -.infinity
        cancel()
    }

    func delivered() {
        deliveryRevision &+= 1
        pending = false
        pendingVerifiedUptime = -.infinity
    }
}
