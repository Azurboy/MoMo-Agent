import BackgroundTasks
import Foundation
import OSLog
import UIKit
import MoMoArchive

enum TranscriptionBackgroundPolicy: Sendable, Equatable {
    case foregroundOnly, cpu
}

enum BackgroundTranscriptionError: Error, LocalizedError {
    case registrationFailed, runtimeUnavailable, alreadyRequested, unavailable, notForeground
    case blockedByFileIssues, waitingForSync, waitingForRetry, audioUnavailable, nothingToContinue
    var errorDescription: String? {
        switch self {
        case .registrationFailed: String(localized: "系统暂未接受后台整理申请，App 内仍可继续处理。")
        case .runtimeUnavailable: String(localized: "转录服务尚未就绪，请稍后再试。")
        case .alreadyRequested: String(localized: "已有后台整理任务正在申请或处理。")
        case .unavailable: String(localized: "当前系统或设备状态暂不支持持续后台整理。")
        case .notForeground: String(localized: "请在 App 内发起后台整理。")
        case .blockedByFileIssues: String(localized: "部分录音导出文件存在冲突待核对，请先恢复文件后再继续整理。")
        case .waitingForSync: String(localized: "剩余片段正在等待手表同步原音，传到手机后会自动整理。")
        case .waitingForRetry: String(localized: "剩余片段正在等待稍后自动重试，其余内容已整理完成。")
        case .audioUnavailable: String(localized: "剩余未完成片段的原音文件不可用，其余内容已整理完成。")
        case .nothingToContinue: String(localized: "当前可整理的内容已完成，最新结尾片段将在收到后续音频后自动整理。")
        }
    }
}

extension ReceivedAudioTranscription {
    convenience init(coordinator: TranscriptionCoordinator) {
        self.init(begin: { expiration in
            let id = UIApplication.shared.beginBackgroundTask(withName: "Transcribe received Watch audio",
                expirationHandler: expiration)
            guard id != .invalid else { return nil }
            return { UIApplication.shared.endBackgroundTask(id) }
        }, start: { try await coordinator.startBackgroundAutomatic(onFinished: $0) },
        stop: { try await coordinator.stop(execution: $0, reason: $1) })
    }
}

@MainActor
final class PhoneBackgroundTasks {
    nonisolated static let processingID = (Bundle.main.bundleIdentifier ?? "com.momoagent.ios") + ".transcription.processing"
    nonisolated static let continuedPrefix = (Bundle.main.bundleIdentifier ?? "com.momoagent.ios") + ".transcription.continued."
    nonisolated static let progressScale: Int64 = 10_000
    let policy: TranscriptionBackgroundPolicy
    var onFailure: ((String) -> Void)?
    var onMemoryWarning: (() -> Void)?
    var onResourceConditionsChanged: ((Bool) -> Void)?
    var onContinuedBatchFinished: ((UUID, Bool) -> Void)?
    var onSystemTaskStarting: (@MainActor () async -> Void)?
    var onSystemTasksFinished: (@MainActor () -> Void)?
    private var resourceObservers: [Task<Void, Never>] = []
    private let prepare: @MainActor () async throws -> TranscriptionCoordinator
    private var registered = false
    private var registrationSucceeded = false
    private var grants: [String: TranscriptionTaskGrant] = [:]
    private var systemTasks: [String: BGTask] = [:]
    private var progressHighWaterMark: [String: Int64] = [:]
    private var progressBaseAnchor: [String: Int64] = [:]
    private var progressHeartbeats: [String: Task<Void, Never>] = [:]
    private var latestSnapshot: TranscriptionSnapshot?
    private lazy var automatic = makeAutomaticSubmission()
    private lazy var continued = makeContinuedSubmission()

    init(policy: TranscriptionBackgroundPolicy = .cpu,
         prepare: @escaping @MainActor () async throws -> TranscriptionCoordinator) {
        self.policy = policy
        self.prepare = prepare
    }

    deinit {
        for observer in resourceObservers { observer.cancel() }
        for heartbeat in progressHeartbeats.values { heartbeat.cancel() }
    }

    static func allowsProcessing(lowPower: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        processingConstraint(lowPower: lowPower, thermalState: thermalState) == nil
    }

    static func processingConstraint(lowPower: Bool, thermalState: ProcessInfo.ThermalState) -> TranscriptionResourceConstraint? {
        if thermalState == .critical { return .thermalPressure }
        return lowPower ? .lowPower : nil
    }

    static var currentProcessingConstraint: TranscriptionResourceConstraint? {
        processingConstraint(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
    }

    static var resourcesAllowProcessing: Bool {
        currentProcessingConstraint == nil
    }

    private func resourcesChanged() {
        let allowed = Self.resourcesAllowProcessing
        onResourceConditionsChanged?(allowed)
        if !allowed {
            for grant in grants.values { grant.expire(reason: .interrupted) }
        }
        // Keep a future background request even when current resource conditions prevent work.
        Task { await scheduleAutomatic() }
    }

    private func makeAutomaticSubmission() -> AutomaticBackgroundSubmission {
        AutomaticBackgroundSubmission(eligible: { @MainActor [weak self] in
            guard let self else { return false }
            let coordinator = try await prepare()
            return !(await coordinator.snapshot()).userPaused
        }, submit: { try await Self.submit(.processing) }, cancel: {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
        }, failure: { [weak self] in self?.onFailure?(String(localized: "系统暂未接受后台转写安排，回到 App 后可继续。")) })
    }

    private func makeContinuedSubmission() -> ContinuedBackgroundSubmission {
        ContinuedBackgroundSubmission(prefix: Self.continuedPrefix, register: { [weak self] identifier in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self, task.identifier == identifier else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.receive(task, continued: true)
                }
            }
        }, submit: { try await Self.submitContinued(identifier: $0) }, cancel: {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0)
        }, failedAfterLaunch: { [weak self] identifier in
            self?.grants[identifier]?.expire(reason: .interrupted)
        })
    }

    /// Called from didFinishLaunching, before any UI task can submit work.
    func register() {
        guard !registered else { return }
        registered = true
        resourceObservers = [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification].map { name in
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                    guard !Task.isCancelled else { return }
                    self?.resourcesChanged()
                }
            }
        } + [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification).map({ _ in () }) {
                    guard !Task.isCancelled else { return }
                    self?.onMemoryWarning?()
                }
            }
        ]
        let processing = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { task.setTaskCompleted(success: false); return }
                self.receive(task, continued: false)
            }
        }
        // The plist wildcard permits concrete continued identifiers; it is not a launch-handler ID.
        // Register each concrete identifier only when a foreground user requests its batch.
        registrationSucceeded = processing
        if !registrationSucceeded { onFailure?(String(localized: "系统未接受后台任务注册，仍可在 App 内转写。")) }
    }

    func scheduleAutomatic() async {
        guard policy == .cpu, registrationSucceeded else { return }
        await automatic.request()
    }

    func requestBatch(id: UUID) async throws {
        guard policy == .cpu, Self.resourcesAllowProcessing, #available(iOS 26.0, *) else { throw BackgroundTranscriptionError.unavailable }
        guard registrationSucceeded else { throw BackgroundTranscriptionError.registrationFailed }
        guard UIApplication.shared.applicationState == .active else { throw BackgroundTranscriptionError.notForeground }
        guard grants.isEmpty else { throw BackgroundTranscriptionError.alreadyRequested }
        try await continued.request(batchID: id)
    }

    var hasActiveContinuedGrant: Bool {
        continued.hasActiveGrant
    }

    func cancelPendingContinuedIfFinished(batchID: UUID) {
        if continued.cancelPending(batchID: batchID) {
            onContinuedBatchFinished?(batchID, true)
        }
    }

    func cancelByUser() {
        automatic.cancelByUser()
        if let batchID = continued.cancelPending() { onContinuedBatchFinished?(batchID, false) }
        for grant in grants.values { grant.expire(reason: .userPaused) }
    }

    /// Clears a pending continued request if the system scheduler silently dropped it before launch.
    @discardableResult
    func reconcilePendingContinuedBatch() async -> UUID? {
        guard registrationSucceeded, let identifier = continued.pendingIdentifier, grants[identifier] == nil,
              let age = continued.pendingAge, age >= 15 else {
            return nil
        }
        let pending = await Task.detached(priority: .utility) {
            await BGTaskScheduler.shared.pendingTaskRequests().map(\.identifier)
        }.value
        guard !pending.contains(identifier), grants[identifier] == nil,
              continued.pendingIdentifier == identifier,
              (continued.pendingAge ?? 0) >= 15 else { return nil }
        guard let droppedBatchID = continued.cancelPending(identifier: identifier) else { return nil }
        onContinuedBatchFinished?(droppedBatchID, false)
        return droppedBatchID
    }

    static func computeContinuedProgressUnits(batch: TranscriptionBatch,
                                              activeWorkInFlight: Bool,
                                              advanceHeartbeat: Bool,
                                              previousHighWater: Int64,
                                              previousBaseAnchor: Int64) -> (completedUnits: Int64, baseAnchor: Int64) {
        let scale = Self.progressScale
        if batch.state == .completed {
            return (scale, scale)
        }
        let totalDuration = max(0.001, batch.totalDuration)
        let preparedFraction = min(1.0, max(0.0, (batch.preparedDuration + batch.removedDuration) / totalDuration))
        let completedFraction = min(1.0, max(0.0, (batch.completedDuration + batch.removedDuration) / totalDuration))
        let baseUnits = min(scale - 50, max(100, Int64(((preparedFraction * 0.15 + completedFraction * 0.85) * Double(scale)).rounded())))
        let baseAnchor = max(previousBaseAnchor, baseUnits)
        var next = max(previousHighWater, baseUnits)
        if advanceHeartbeat && activeWorkInFlight {
            let remainingDuration = max(0.0, totalDuration - batch.completedDuration - batch.removedDuration)
            let activeSliceSeconds = min(22.0, max(4.0, remainingDuration))
            let spanUnits = max(150, Int64(((activeSliceSeconds / totalDuration) * 0.80 * Double(scale)).rounded()))
            let ceiling = min(scale - 50, baseAnchor + spanUnits)
            if next < ceiling {
                let step = max(8, (ceiling - next) / 14)
                next = min(ceiling, next + step)
            }
        }
        return (min(scale - 1, next), baseAnchor)
    }

    func update(_ snapshot: TranscriptionSnapshot) {
        latestSnapshot = snapshot
        refreshAllContinuedProgress(advanceHeartbeat: false)
    }

    private func refreshAllContinuedProgress(advanceHeartbeat: Bool) {
        guard #available(iOS 26.0, *) else { return }
        for (identifier, grant) in grants {
            guard let task = systemTasks[identifier] as? BGContinuedProcessingTask else { continue }
            let matchedBatchID = grant.execution?.batchExecution?.batchID ?? continued.activeBatchID(for: identifier)
            guard let snapshot = latestSnapshot, let batch = snapshot.batch, batch.id == matchedBatchID else {
                if advanceHeartbeat {
                    let current = progressHighWaterMark[identifier] ?? 100
                    let bumped = min(250, current + 8)
                    progressHighWaterMark[identifier] = bumped
                    task.progress.totalUnitCount = Self.progressScale
                    task.progress.completedUnitCount = bumped
                }
                continue
            }
            let activeInFlight = snapshot.nativeInFlight || snapshot.phase == .preparing || snapshot.phase == .transcribing
            let previousHigh = progressHighWaterMark[identifier] ?? 100
            let previousAnchor = progressBaseAnchor[identifier] ?? 100
            let computed = Self.computeContinuedProgressUnits(
                batch: batch,
                activeWorkInFlight: activeInFlight,
                advanceHeartbeat: advanceHeartbeat,
                previousHighWater: previousHigh,
                previousBaseAnchor: previousAnchor
            )
            progressHighWaterMark[identifier] = computed.completedUnits
            progressBaseAnchor[identifier] = computed.baseAnchor
            task.progress.totalUnitCount = Self.progressScale
            task.progress.completedUnitCount = computed.completedUnits
            let processedSeconds = Int((batch.completedDuration + batch.removedDuration).rounded(.down))
            let totalSeconds = max(1, Int(batch.totalDuration.rounded(.up)))
            if snapshot.phase == .preparing && processedSeconds == 0 {
                let preparedSeconds = min(totalSeconds, Int((batch.preparedDuration + batch.removedDuration).rounded(.down)))
                task.updateTitle(String(localized: "本机转写"), subtitle: String(localized: "正在分析音频 \(preparedSeconds) / \(totalSeconds) 秒"))
            } else if activeInFlight && processedSeconds < totalSeconds {
                task.updateTitle(String(localized: "本机转写"), subtitle: String(localized: "正在转写 · 已完成 \(min(totalSeconds, processedSeconds)) / \(totalSeconds) 秒"))
            } else {
                task.updateTitle(String(localized: "本机转写"), subtitle: String(localized: "已处理 \(min(totalSeconds, processedSeconds)) / \(totalSeconds) 秒"))
            }
        }
    }

    private func startProgressHeartbeat(identifier: String, holder: BackgroundCoordinatorHolder) {
        progressHeartbeats[identifier]?.cancel()
        progressHeartbeats[identifier] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard let self, !Task.isCancelled, self.grants[identifier] != nil else { return }
                if let coordinator = await holder.coordinator {
                    self.latestSnapshot = await coordinator.snapshot()
                }
                self.refreshAllContinuedProgress(advanceHeartbeat: true)
            }
        }
    }

    private func stopProgressHeartbeat(identifier: String) {
        progressHeartbeats[identifier]?.cancel()
        progressHeartbeats[identifier] = nil
    }

    private func receive(_ task: BGTask, continued: Bool) {
        // Re-arm on delivery, before preparation can be interrupted by suspension.
        if !continued {
            automatic.delivered()
            Task { await scheduleAutomatic() }
        }
        guard policy == .cpu, Self.resourcesAllowProcessing else {
            let rejectedBatch = continued ? self.continued.cancelPending(identifier: task.identifier) : nil
            task.setTaskCompleted(success: false)
            if let rejectedBatch { onContinuedBatchFinished?(rejectedBatch, false) }
            if !continued { Task { await scheduleAutomatic() } }
            return
        }
        let id = task.identifier
        guard grants[id] == nil else { task.setTaskCompleted(success: false); return }
        let batchID: UUID?
        if continued {
            guard #available(iOS 26.0, *), task is BGContinuedProcessingTask else {
                let rejectedBatch = self.continued.cancelPending(identifier: id)
                task.setTaskCompleted(success: false)
                if let rejectedBatch { onContinuedBatchFinished?(rejectedBatch, false) }
                return
            }
            guard let pendingBatchID = self.continued.claim(identifier: id) else {
                let wasExplicitlyCancelled = self.continued.wasCancelled(identifier: id)
                if wasExplicitlyCancelled, let continuedTask = task as? BGContinuedProcessingTask {
                    continuedTask.progress.totalUnitCount = Self.progressScale
                    continuedTask.progress.completedUnitCount = Self.progressScale
                }
                task.setTaskCompleted(success: wasExplicitlyCancelled)
                return
            }
            if let continuedTask = task as? BGContinuedProcessingTask {
                continuedTask.progress.totalUnitCount = Self.progressScale
                continuedTask.progress.completedUnitCount = 100
                progressHighWaterMark[id] = 100
                progressBaseAnchor[id] = 100
            }
            batchID = pendingBatchID
        } else {
            guard task is BGProcessingTask else { task.setTaskCompleted(success: false); return }
            batchID = nil
        }
        let origin: TranscriptionBatchOrigin = continued ? .continuedProcessing : .backgroundProcessing
        // Install expiration before archive recovery or any async admission work.
        let holder = BackgroundCoordinatorHolder()
        let grant = TranscriptionTaskGrant(prepare: { @MainActor [weak self] in
            guard let self else { throw BackgroundTranscriptionError.runtimeUnavailable }
            let coordinator = try await self.prepare()
            guard self.systemTasks[id] === task else { throw CancellationError() }
            await self.onSystemTaskStarting?()
            await holder.set(coordinator)
        }, start: { finish in
            guard let coordinator = await holder.coordinator else { throw BackgroundTranscriptionError.runtimeUnavailable }
            if let batchID { return try await coordinator.startBatch(id: batchID, origin: origin, onFinished: finish) }
            if let resumedID = try await coordinator.resumeSystemEndedBatchForBackgroundProcessing() {
                return try await coordinator.startBatch(id: resumedID, origin: .backgroundProcessing, onFinished: finish)
            }
            return try await coordinator.startBackgroundAutomatic(onFinished: finish)
        }, stop: { execution, reason in
            guard let coordinator = await holder.coordinator else { throw BackgroundTranscriptionError.runtimeUnavailable }
            try await coordinator.stop(execution: execution, reason: reason)
        }, completion: { [weak self] success, failure in
            self?.stopProgressHeartbeat(identifier: id)
            let reason = self?.grants[id]?.endReason
            task.expirationHandler = nil
            let taskSucceeded = continued ? (failure == nil && (success || reason == .systemEndedUnknown || reason == .interrupted || reason == .userPaused)) : success
            if continued, taskSucceeded, #available(iOS 26.0, *), let continuedTask = task as? BGContinuedProcessingTask {
                let total = max(Self.progressScale, continuedTask.progress.totalUnitCount)
                continuedTask.progress.totalUnitCount = total
                continuedTask.progress.completedUnitCount = total
            }
            task.setTaskCompleted(success: taskSucceeded)
            self?.grants[id] = nil
            self?.systemTasks[id] = nil
            self?.progressHighWaterMark[id] = nil
            self?.progressBaseAnchor[id] = nil
            if self?.grants.isEmpty == true { self?.onSystemTasksFinished?() }
            if continued { self?.continued.complete(identifier: id) }
            if let batchID { self?.onContinuedBatchFinished?(batchID, success) }
            if failure != nil { self?.onFailure?(String(localized: "后台转写已停止，进度保存在本机。请回到转录页检查。")) }
            if failure == nil, (reason == .backgroundExpired || reason == .interrupted || (continued && reason == .systemEndedUnknown)) {
                Task { await self?.scheduleAutomatic() }
            }
        })
        grants[id] = grant
        systemTasks[id] = task
        if continued {
            startProgressHeartbeat(identifier: id, holder: holder)
        }
        task.expirationHandler = { [weak grant] in
            Task { @MainActor in grant?.expire(reason: continued ? .systemEndedUnknown : .backgroundExpired) }
        }
        Task {
            await grant.run()
            if let coordinator = await holder.coordinator { update(await coordinator.snapshot()) }
        }
    }

    private struct UncheckedTaskRequest: @unchecked Sendable {
        let value: BGTaskRequest
    }

    private enum Submission: Sendable { case processing }

    private static func submitContinued(identifier: String) async throws {
        guard #available(iOS 26.0, *) else { throw BackgroundTranscriptionError.unavailable }
        // BGContinuedProcessingTaskRequest associates with the foreground app at init time.
        let continued = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: String(localized: "本机转写"),
            subtitle: String(localized: "正在准备本次转写")
        )
        continued.strategy = .queue
        let box = UncheckedTaskRequest(value: continued)
        try await Task.detached(priority: .utility) {
            if #available(iOS 27.0, *) { try await BGTaskScheduler.shared.submitTaskRequest(box.value) }
            else { try BGTaskScheduler.shared.submit(box.value) }
        }.value
    }

    private nonisolated static func submit(_ submission: Submission) async throws {
        // Requests are submitted off the main thread, as the iOS 27 API requires.
        try await Task.detached(priority: .utility) {
            switch submission {
            case .processing:
                let pending = await BGTaskScheduler.shared.pendingTaskRequests()
                guard !pending.contains(where: { $0.identifier == processingID }) else { return }
                let processing = BGProcessingTaskRequest(identifier: processingID)
                processing.requiresExternalPower = false
                processing.requiresNetworkConnectivity = false
                if #available(iOS 27.0, *) { try await BGTaskScheduler.shared.submitTaskRequest(processing) }
                else { try BGTaskScheduler.shared.submit(processing) }
            }
        }.value
    }
}

/// A finite UIKit grant bridges foreground inference to scheduled background processing.
@MainActor
final class PhoneTranscriptionContinuation {
    typealias Begin = @MainActor (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let begin: Begin
    private let end: @MainActor (UIBackgroundTaskIdentifier) -> Void
    private let stop: @MainActor () async -> Void
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var expiring = false
    private var generation: UInt64 = 0
    var isActive: Bool { identifier != .invalid && !expiring }

    convenience init(stop: @escaping @MainActor () async -> Void) {
        self.init(begin: { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "Finish local transcription", expirationHandler: expiration)
        }, end: { UIApplication.shared.endBackgroundTask($0) }, stop: stop)
    }

    init(begin: @escaping Begin, end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void,
         stop: @escaping @MainActor () async -> Void) {
        self.begin = begin
        self.end = end
        self.stop = stop
    }

    func start() {
        guard identifier == .invalid, !expiring else { return }
        generation &+= 1
        let revision = generation
        identifier = begin { [weak self] in
            guard let self, self.generation == revision else { return }
            _ = self.beginExpiration()
        }
    }

    func finish() {
        guard identifier != .invalid, !expiring else { return }
        let completed = identifier
        identifier = .invalid
        generation &+= 1
        end(completed)
    }

    func expire() async {
        await beginExpiration()?.value
    }

    private func beginExpiration() -> Task<Void, Never>? {
        guard identifier != .invalid, !expiring else { return nil }
        expiring = true
        let completed = identifier
        identifier = .invalid
        generation &+= 1
        // UIKit must receive this before its expiration handler returns. Durable cancellation
        // may await inference or storage; it still fences a new run, but cannot retain OS time.
        end(completed)
        return Task {
            await stop()
            expiring = false
        }
    }
}

private actor BackgroundCoordinatorHolder {
    private(set) var coordinator: TranscriptionCoordinator?
    func set(_ coordinator: TranscriptionCoordinator) { self.coordinator = coordinator }
}
