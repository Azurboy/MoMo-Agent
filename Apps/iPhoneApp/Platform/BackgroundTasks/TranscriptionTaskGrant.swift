import Foundation
import MoMoArchive

/// The system grant ends after the persistent stop barrier, without waiting for native inference.
@MainActor
final class TranscriptionTaskGrant {
    typealias Start = @Sendable (@escaping @Sendable (TranscriptionExecutionCompletion) -> Void) async throws -> TranscriptionExecutionHandle
    typealias FollowUpStart = @Sendable (@escaping @Sendable (TranscriptionExecutionCompletion) -> Void) async throws -> TranscriptionExecutionHandle?
    typealias Stop = @Sendable (TranscriptionExecutionHandle, TranscriptionBatchEndReason) async throws -> Void

    private let start: Start
    private var followUp: FollowUpStart?
    private let prepare: @Sendable () async throws -> Void
    private let stop: Stop
    private let completion: @MainActor (Bool, String?) -> Void
    private(set) var execution: TranscriptionExecutionHandle?
    private(set) var finished = false
    private(set) var endReason: TranscriptionBatchEndReason?
    private(set) var completedProactively = false
    private var expiration: TranscriptionBatchEndReason?
    private var started = false
    private var admissionStarted = false

    init(prepare: @escaping @Sendable () async throws -> Void = {}, start: @escaping Start,
         followUp: FollowUpStart? = nil, stop: @escaping Stop,
         completion: @escaping @MainActor (Bool, String?) -> Void) {
        self.prepare = prepare
        self.start = start
        self.followUp = followUp
        self.stop = stop
        self.completion = completion
    }

    func run() async {
        guard !finished, !started else { return }
        started = true
        if let expiration { finish(success: completedProactively, failure: nil, reason: expiration); return }
        do {
            try await prepare()
            guard !finished else { return }
            admissionStarted = true
            let handle = try await start { [weak self] result in
                Task { @MainActor in self?.completed(result) }
            }
            execution = handle
            if let expiration { await stopAndFinish(handle, reason: expiration) }
        } catch {
            completedProactively = false
            finish(success: false, failure: "background_start_failed", reason: expiration ?? .interrupted)
        }
    }

    func completeSlice(reason: TranscriptionBatchEndReason = .systemEndedUnknown) {
        guard !finished, expiration == nil else { return }
        completedProactively = true
        expiration = reason
        if !admissionStarted { finish(success: true, failure: nil, reason: reason); return }
        if let execution { Task { await stopAndFinish(execution, reason: reason) } }
    }

    func expire(reason: TranscriptionBatchEndReason) {
        guard !finished else { return }
        if completedProactively {
            completedProactively = false
            if reason != .systemEndedUnknown { expiration = reason }
            return
        }
        guard expiration == nil else { return }
        expiration = reason
        if !admissionStarted { finish(success: false, failure: nil, reason: reason); return }
        if let execution { Task { await stopAndFinish(execution, reason: reason) } }
    }

    private func completed(_ result: TranscriptionExecutionCompletion) {
        // An expiration or proactive slice completion already owns completion; wait for its durable stop barrier.
        guard expiration == nil else { return }
        if result.reason == .completed, result.failureCode == nil, let nextStage = followUp {
            followUp = nil
            execution = nil
            Task { @MainActor [weak self] in
                await self?.runFollowUp(nextStage)
            }
            return
        }
        finish(success: result.reason == .completed && result.failureCode == nil, failure: result.failureCode, reason: result.reason)
    }

    private func runFollowUp(_ nextStage: FollowUpStart) async {
        guard !finished else { return }
        if let expiration {
            finish(success: completedProactively, failure: nil, reason: expiration)
            return
        }
        do {
            guard let handle = try await nextStage({ [weak self] nextResult in
                Task { @MainActor in self?.completed(nextResult) }
            }) else {
                finish(success: true, failure: nil, reason: .completed)
                return
            }
            execution = handle
            if let expiration { await stopAndFinish(handle, reason: expiration) }
        } catch is TranscriptionExecutionError {
            finish(success: completedProactively || expiration == nil, failure: nil, reason: expiration ?? .completed)
        } catch is CancellationError {
            finish(success: completedProactively || expiration == nil, failure: nil, reason: expiration ?? .completed)
        } catch {
            completedProactively = false
            finish(success: false, failure: "background_start_failed", reason: expiration ?? .interrupted)
        }
    }

    private func stopAndFinish(_ execution: TranscriptionExecutionHandle, reason: TranscriptionBatchEndReason) async {
        do {
            try await stop(execution, reason)
            finish(success: completedProactively, failure: nil, reason: expiration ?? reason)
        } catch {
            completedProactively = false
            finish(success: false, failure: "archive_cancel_barrier_failed", reason: expiration ?? reason)
        }
    }

    private func finish(success: Bool, failure: String?, reason: TranscriptionBatchEndReason) {
        guard !finished else { return }
        finished = true
        endReason = reason
        completion(success, failure)
    }
}

/// Use the finite execution time of a new audio delivery without waiting for a scheduled BGTask.
@MainActor
final class ReceivedAudioTranscription {
    typealias Release = @MainActor () -> Void
    typealias Begin = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Release?
    private let begin: Begin
    private let start: TranscriptionTaskGrant.Start
    private let followUp: TranscriptionTaskGrant.FollowUpStart?
    private let stop: TranscriptionTaskGrant.Stop
    var onActivityChanged: (@MainActor () -> Void)?
    private var grant: TranscriptionTaskGrant? {
        didSet {
            if (oldValue != nil) != (grant != nil) {
                onActivityChanged?()
            }
        }
    }
    var isActive: Bool { grant != nil }
    private var release: Release?
    private var generation: UInt64 = 0
    private var receivedWhileRunning = false
    private var receivedAfterExpiration = false
    private var expirationReason: TranscriptionBatchEndReason?
    private var systemTaskActive = false
    private var handoffWaiters: [CheckedContinuation<Void, Never>] = []

    init(begin: @escaping Begin, start: @escaping TranscriptionTaskGrant.Start,
         followUp: TranscriptionTaskGrant.FollowUpStart? = nil,
         stop: @escaping TranscriptionTaskGrant.Stop) {
        self.begin = begin; self.start = start; self.followUp = followUp; self.stop = stop
    }

    deinit {
        let release = release, grant = grant
        Task { @MainActor in
            release?()
            grant?.expire(reason: .interrupted)
        }
    }

    func request() {
        guard !systemTaskActive else { return }
        guard grant == nil else {
            if expirationReason == .backgroundExpired { receivedAfterExpiration = true }
            else { receivedWhileRunning = true }
            return
        }
        generation &+= 1
        let revision = generation
        let grant = makeGrant(revision: revision)
        self.grant = grant
        let release = begin { [weak self] in
            guard let self, self.generation == revision else { return }
            self.expire()
        }
        guard self.grant === grant, !grant.finished else { release?(); return }
        guard let release else { grant.expire(reason: .backgroundExpired); return }
        self.release = release
        Task { await grant.run() }
    }

    private func makeGrant(revision: UInt64) -> TranscriptionTaskGrant {
        receivedWhileRunning = false
        receivedAfterExpiration = false
        expirationReason = nil
        return TranscriptionTaskGrant(start: start, followUp: followUp, stop: stop) { [weak self] success, failure in
            guard let self, self.generation == revision else { return }
            self.grant = nil
            // An arrival can race the worker's final empty-queue check. Recheck within the same OS grant.
            if success, self.receivedWhileRunning, self.release != nil, !self.systemTaskActive {
                let next = self.makeGrant(revision: revision)
                self.grant = next
                Task { await next.run() }
                return
            }
            // Only a new delivery after expiration may request new OS time, after the old stop succeeds.
            let resumeDelivery = self.receivedAfterExpiration && self.expirationReason == .backgroundExpired
                && failure == nil && !self.systemTaskActive
            self.receivedWhileRunning = false
            self.receivedAfterExpiration = false
            self.expirationReason = nil
            self.releaseTime()
            let waiters = self.handoffWaiters
            self.handoffWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if resumeDelivery { self.request() }
        }
    }

    func handOffToSystemTask() async {
        systemTaskActive = true
        expire(reason: .interrupted)
        guard grant != nil else { return }
        await withCheckedContinuation { handoffWaiters.append($0) }
    }

    func systemTaskFinished() { systemTaskActive = false }

    func expire(reason: TranscriptionBatchEndReason = .backgroundExpired) {
        if expirationReason == nil || reason != .backgroundExpired { expirationReason = reason }
        if reason != .backgroundExpired { receivedAfterExpiration = false }
        // UIKit expiration must release OS time synchronously, before the durable stop awaits.
        releaseTime()
        grant?.expire(reason: reason)
    }

    private func releaseTime() {
        let completed = release
        release = nil
        completed?()
    }
}
