import BackgroundTasks
import OSLog
import UIKit

/// One bounded upload owns the transport until its receipt, failure, or OS expiration.
@MainActor final class PhoneContextDelivery {
    typealias Begin = PhoneReplyContinuation.Begin
    private let begin: Begin
    private let end: @MainActor (UIBackgroundTaskIdentifier) -> Void
    private let needsDelivery: @MainActor () -> Bool
    private let deliver: @MainActor () async throws -> Void
    private let prepare: @MainActor () -> Void
    private let suspend: @MainActor () -> Void
    private let cancel: @MainActor () -> Void
    private let schedule: @MainActor (Bool) -> Void
    private let budget: Duration
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var requested = false
    private var systemCompletions: [UUID: (Bool) -> Void] = [:]
    private(set) var isActive = false

    init(needsDelivery: @escaping @MainActor () -> Bool,
         deliver: @escaping @MainActor () async throws -> Void,
         prepare: @escaping @MainActor () -> Void, suspend: @escaping @MainActor () -> Void,
         cancel: @escaping @MainActor () -> Void, schedule: @escaping @MainActor (Bool) -> Void,
         begin: @escaping Begin = { UIApplication.shared.beginBackgroundTask(withName: "Deliver recordings to Mac", expirationHandler: $0) },
         end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) },
         budget: Duration = .seconds(25)) {
        self.needsDelivery = needsDelivery; self.deliver = deliver
        self.prepare = prepare; self.suspend = suspend; self.cancel = cancel
        self.schedule = schedule; self.begin = begin; self.end = end; self.budget = budget
    }

    func request() { request(systemID: nil, completion: nil) }

    func runSystemTask(_ systemTask: BGTask) {
        let id = UUID()
        systemTask.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.expireSystemGrant(id: id)
            }
        }
        requestWithSystemGrant(id: id) { systemTask.setTaskCompleted(success: $0) }
    }

    func requestWithSystemGrant(id: UUID, completion: @escaping (Bool) -> Void) {
        request(systemID: id, completion: completion)
    }

    func expireSystemGrant(id: UUID) {
        guard systemCompletions[id] != nil else { return }
        expire()
    }

    private func request(systemID: UUID?, completion: ((Bool) -> Void)?) {
        guard needsDelivery() else { completion?(true); schedule(false); return }
        if let systemID, let completion { systemCompletions[systemID] = completion }
        requested = true
        guard !isActive else { return }
        let owner = UUID(); generation = owner; isActive = true
        if systemID == nil {
            let id = begin { [weak self] in
                guard let self, self.generation == owner else { return }
                self.expire()
            }
            guard isActive else { if id != .invalid { end(id) }; return }
            identifier = id
            guard id != .invalid else { finish(owner: owner, success: false); return }
        }
        // Persist a scheduler request before networking; suspension/crash must not strand the outbox.
        schedule(true)
        prepare()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                repeat {
                    try Task.checkCancellation()
                    self.requested = false
                    try await self.deliver()
                    try Task.checkCancellation()
                } while self.requested
                self.finish(owner: owner, success: true)
            } catch { self.finish(owner: owner, success: false) }
        }
        timeout = Task { [weak self, budget = self.budget] in
            do { try await Task.sleep(for: budget) } catch { return }
            guard let self, self.generation == owner else { return }
            self.expire()
        }
    }

    func expire() {
        guard isActive else { return }
        task?.cancel()
        // Release the OS grant synchronously; cancellation of network work may finish later.
        finish(owner: generation, success: false)
        cancel()
    }

    private func finish(owner: UUID, success: Bool) {
        guard isActive, generation == owner else { return }
        isActive = false
        task = nil; timeout?.cancel(); timeout = nil
        let id = identifier; identifier = .invalid
        if id != .invalid { end(id) }
        let completions = Array(systemCompletions.values)
        systemCompletions = [:]
        schedule(needsDelivery())
        suspend()
        // A successful pass may schedule future Mac results; that is not a failed OS task.
        for completion in completions { completion(success) }
    }
}

@MainActor enum PhoneContextDeliveryScheduler {
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.momoagent.ios") + ".context.delivery"
    private static let logger = Logger(subsystem: "com.momoagent.ios", category: "ContextDelivery")
    private static var scheduleRevision = 0

    static func register(bootstrap: PhoneBootstrap) {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Task { @MainActor in
                bootstrap.initialize()
                guard let agent = bootstrap.runtime?.remoteAgent else {
                    schedule(pending: true)
                    task.setTaskCompleted(success: false); return
                }
                agent.contextDelivery.runSystemTask(task)
            }
        }
        if !registered { logger.error("Background context delivery registration failed") }
    }

    static func schedule(pending: Bool, minimumDelay: TimeInterval = 5 * 60) {
        scheduleRevision += 1
        let revision = scheduleRevision
        guard pending else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let identifier = Self.identifier
        let earliest = Date().addingTimeInterval(minimumDelay)
        BGTaskScheduler.shared.getPendingTaskRequests { @Sendable requests in
            let existing = requests.first { $0.identifier == identifier }
            let hasExisting = existing != nil
            let existingDate = existing?.earliestBeginDate
            Task { @MainActor in
                guard revision == scheduleRevision else { return }
                // Continuous recording must not keep pushing an existing retry farther into the future.
                if hasExisting {
                    guard let existingDate, existingDate > earliest else { return }
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                }
                let request = BGProcessingTaskRequest(identifier: identifier)
                request.requiresNetworkConnectivity = true
                request.earliestBeginDate = earliest
                do { try BGTaskScheduler.shared.submit(request) }
                catch { logger.error("Background context delivery scheduling failed: \(String(describing: type(of: error)), privacy: .public)") }
            }
        }
    }
}
