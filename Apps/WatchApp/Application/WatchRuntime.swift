import Foundation
import Darwin
import Observation
import os
import WatchKit
import MoMoContracts
import MoMoLink
import MoMoRecording

enum WatchRuntimeError: Error { case busy, noActiveSession, unexpectedControlMessage }
typealias WatchBackgroundDrainResult = LinkBackgroundDrainResult

enum WatchArchiveState: Equatable {
    case idle, ledger, encodedAudio, capture, ready, failed
    var isRecovering: Bool { self == .ledger || self == .encodedAudio || self == .capture }
    var description: String {
        switch self {
        case .idle: String(localized: "准备读取录音资料")
        case .ledger: String(localized: "检查已保存的片段")
        case .encodedAudio: String(localized: "恢复上次未保存的录音")
        case .capture: String(localized: "恢复录音记录")
        case .ready: String(localized: "录音资料已就绪")
        case .failed: String(localized: "录音资料恢复失败")
        }
    }
}

enum WatchSynchronizationState {
    case waitingForConnection, receiverConfirmation, waitingForBatch, transferring, awaitingConfirmation, retrying, caughtUp
    var description: String {
        switch self {
        case .waitingForConnection: String(localized: "同步等待连接 iPhone")
        case .receiverConfirmation: String(localized: "等待确认手机资料库")
        case .waitingForBatch: String(localized: "录音已保存，等待分批同步")
        case .transferring: String(localized: "系统正在传送")
        case .awaitingConfirmation: String(localized: "等待手机接收确认")
        case .retrying: String(localized: "稍后自动重试")
        case .caughtUp: String(localized: "没有待确认片段")
        }
    }
}

@MainActor @Observable
final class WatchRuntime {
    let captureMeter = CaptureMeter()
    let macLink: WatchMacLink
    private(set) var captureState = CaptureState() {
        didSet {
            if captureActivity != captureState.activity { captureActivity = captureState.activity }
            if captureIntent != captureState.intent { captureIntent = captureState.intent }
        }
    }
    // Phase-only projections keep frame counters from invalidating the entire recording screen.
    private(set) var captureActivity = CaptureActivity.idle
    private(set) var captureIntent = CaptureIntent.stopped
    private(set) var sessionID: UUID?
    private(set) var epochID: UUID?
    private(set) var pendingChunkCount = 0
    private(set) var pendingDuration: TimeInterval = 0
    private(set) var queuedFileCount = 0
    private(set) var synchronizationState = WatchSynchronizationState.waitingForConnection
    private(set) var phoneStatus: StatusSnapshot?
    private(set) var failure: String?
    private(set) var syncFailure: String?
    private(set) var archiveFailure: String?
    private(set) var archiveState = WatchArchiveState.idle
    private(set) var captureReady = false
    private(set) var requiresStartTap = true
    var ready: Bool { archiveState == .ready }
    var isRecoveringArchive: Bool { archiveState.isRecovering }
    var isFinalizingCapture: Bool { finalizing || startupFailureCleanup }
    private(set) var pendingReceiver: ReceiverIdentity?
    private(set) var inputLevel: Float = 0
    private(set) var diagnostic: CaptureDiagnostic?
    var elapsedSeconds: Double { completedSeconds + (epochID == nil ? 0 : Double(observedFrames) / 16_000) }
    private var observedFrames: Int64 {
        max(captureState.capturedFrames, progressDelivery?.latest?.frames ?? 0)
    }
    private var observedSampleUptime: TimeInterval? {
        if let progress = progressDelivery?.latest, progress.frames > 0 { return progress.uptime }
        return captureState.lastSampleUptime
    }
    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private let encoderDirectory: URL
    @ObservationIgnored private let sourceDeviceID: UUID
    @ObservationIgnored private let sourceBuild: String
    @ObservationIgnored private let controls: ControlInbox
    @ObservationIgnored private let transport: WatchConnectivityTransport
    @ObservationIgnored private let capacityReader: CaptureCapacityReader
    @ObservationIgnored private let archiveRecovery: @Sendable (RecordingStore) async throws -> RecordingRecoveryReport
    @ObservationIgnored private var inputSampleRate: Double?
    @ObservationIgnored private var engine = AudioCaptureEngine()
    @ObservationIgnored private let audioSession: WatchAudioSession
    @ObservationIgnored private var startup: Task<Void, any Error>?
    @ObservationIgnored private var startupGeneration: UInt64?
    @ObservationIgnored private let diagnosticRunID = UUID()
    @ObservationIgnored private var diagnosticSequence: UInt64 = 0
    @ObservationIgnored private var progressDelivery: CaptureProgressDelivery?
    @ObservationIgnored private var levelDelivery: CaptureLevelDelivery?
    @ObservationIgnored private var levelConsumer: Task<Void, Never>?
    @ObservationIgnored private var presentationActive = false
    @ObservationIgnored private var presentationBeganAt: TimeInterval?
    @ObservationIgnored private var presentationSeconds: TimeInterval = 0
    @ObservationIgnored private let energyLog: CaptureEnergyLog
    @ObservationIgnored private var lastEnergySampleAt: TimeInterval = -.infinity
    @ObservationIgnored private var energyCounters = CaptureEnergyCounters()
    @ObservationIgnored private var progressConsumer: Task<Void, Never>?
    private var encoderProgressObservedAt: TimeInterval? { progressDelivery?.lastReceivedAt }
    @ObservationIgnored private var audioInterruptionActive = false
    @ObservationIgnored private let captureRecovery = CaptureRecoveryScheduler()
    @ObservationIgnored private var resumingGeneration: UInt64?
    @ObservationIgnored private var worker: Task<Int64, any Error>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    private var finalizing = false
    private var startupFailureCleanup = false
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private var connectivityGrant = false
    @ObservationIgnored private var grantID: UUID?
    @ObservationIgnored private var lastActiveDrainID: UUID?
    @ObservationIgnored private var grantControlsRemaining = 0
    @ObservationIgnored private var grantSubmitted = false
    @ObservationIgnored private var grantCleaned = false
    @ObservationIgnored private var grantLeaseChecked = false
    @ObservationIgnored private var grantReconciliationAttempted = false
    @ObservationIgnored private var grantLocalWorkChecked = false
    @ObservationIgnored private var grantStatusPublished = false
    @ObservationIgnored private var grantStatusAttempted = false
    @ObservationIgnored private var statusBindingGeneration: UInt64 = 0
    @ObservationIgnored private var fileCursorLoaded = false
    @ObservationIgnored private var pendingLocalSyncWork = false
    @ObservationIgnored private var linkActivated = false
    @ObservationIgnored private var synchronizationTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.momoagent.ios.watchkitapp", category: "ArchiveRecovery")
    @ObservationIgnored private var completedSeconds: Double = 0
    @ObservationIgnored private var deferredInterruptionResume: UInt64?
    @ObservationIgnored private var resetEngineAfterFinalization = false
    @ObservationIgnored private var controlCursors: [RecordingControlKind: Int64] = [:]
    @ObservationIgnored private var controlReceivers: [UUID: (deviceID: UUID, libraryInstanceID: UUID)] = [:]
    @ObservationIgnored private var fileCursor: Int64 = 0
    @ObservationIgnored private var audioBlockCursor: Int64 = 0
    @ObservationIgnored private var needsPostActivationWrap = false
    @ObservationIgnored private var interruptedEpochsRecovered = false
    @ObservationIgnored private var flushAudioBatch = false
    @ObservationIgnored private var waitingForAudioBatch = false
    @ObservationIgnored private var audioBatchRetryDelay: TimeInterval?
    @ObservationIgnored private var invalidAudioBlockSources: Set<UUID> = []
    @ObservationIgnored private let localSyncClient = LocalSyncClient()
    @ObservationIgnored private var localBulkSyncTask: Task<Void, Never>?
    @ObservationIgnored private var localSyncInFlightChunkIDs: Set<UUID> = []
    @ObservationIgnored private var localSyncRetryAt: TimeInterval = 0
    @ObservationIgnored private var lastObservedLocalSyncEndpoint: LocalSyncEndpoint?
    @ObservationIgnored private var reconciliationRequested = true
    @ObservationIgnored private var lastReconciliationRoundAt: TimeInterval = -.infinity
    @ObservationIgnored private var inboxSyncFailure: String?
    @ObservationIgnored private var transportSyncFailure: String?
    @ObservationIgnored private var pendingReceiverControl: ControlMessage?
    @ObservationIgnored private var sealedSeconds: TimeInterval = 0
    @ObservationIgnored private var pendingBytes: Int64 = 0
    @ObservationIgnored private var statusBudget = StatusPublicationBudget()
    @ObservationIgnored private var statusDirty = false
    @ObservationIgnored private var publishingStatus = false
    @ObservationIgnored private var statusPublicationRequested = false
    @ObservationIgnored private var statusPublicationTask: Task<Void, Never>?
    @ObservationIgnored private var queuedStatusForce = false
    @ObservationIgnored private var lastPublishedStatusSnapshot: StatusSnapshot?
    @ObservationIgnored private var lastPassiveRecordingStatusAt: TimeInterval = -.infinity
    @ObservationIgnored private var currentArchiveIssueSignature: Set<String> = []
    @ObservationIgnored var statusPublisher: (StatusSnapshot) async throws -> Void
    @ObservationIgnored private var phoneStatuses = ReceiverStatusCache()
    @ObservationIgnored var onBackgroundRetryNeeded: () -> Void = {}
    @ObservationIgnored private let recoverySleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTaskID: UUID?
    @ObservationIgnored private var recoveryBackoff = LinkRetryBackoff()
    @ObservationIgnored private var replayReconciliationRequest = false
    @ObservationIgnored var widgetPublisher: (@Sendable (WatchWidgetSnapshot) async -> Void)?
    @ObservationIgnored private var lastWidgetSnapshot: WatchWidgetSnapshot?
    @ObservationIgnored private var lastWidgetPublication: TimeInterval = -.infinity
    @ObservationIgnored private var widgetRevision: UInt64 = 0
    @ObservationIgnored private var widgetHasQueueObservation = false
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private var simulatorTestCapture = false

    func configureSimulatorTestCapture() {
        precondition(!ready && !isRecoveringArchive && sessionID == nil)
        simulatorTestCapture = true
        setPresentationActive(true)
    }
    #endif

    init(store: RecordingStore, encoderDirectory: URL, sourceDeviceID: UUID, sourceBuild: String,
         controls: ControlInbox, transport: WatchConnectivityTransport, capacityReader: CaptureCapacityReader = .live,
         audioSession: WatchAudioSession = WatchAudioSession(), macGrant: WatchMacLink.Grant? = nil,
         archiveRecovery: @escaping @Sendable (RecordingStore) async throws -> RecordingRecoveryReport = { try await $0.recover() },
         recoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store; self.encoderDirectory = encoderDirectory; self.sourceDeviceID = sourceDeviceID
        macLink = WatchMacLink(store: store, directory: encoderDirectory.deletingLastPathComponent(), deviceID: sourceDeviceID, saved: macGrant)
        self.sourceBuild = sourceBuild; self.controls = controls; self.transport = transport
        self.capacityReader = capacityReader
        energyLog = CaptureEnergyLog(url: encoderDirectory.deletingLastPathComponent().appendingPathComponent("energy-diagnostic.json"))
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        self.audioSession = audioSession
        self.statusPublisher = { snapshot in _ = try transport.updateStatus(snapshot) }
        self.archiveRecovery = archiveRecovery
        self.recoverySleep = recoverySleep
        macLink.beforeSwitch = { [weak self] in try await self?.stopPhoneTransfers() }
        macLink.recording = { [weak self] in self?.observedCaptureActivity == .recording }
        macLink.currentSession = { [weak self] in self?.sessionID }
        macLink.retryNeeded = { [weak self] in self?.onBackgroundRetryNeeded() }
        macLink.queueChanged = { [weak self] summary in
            guard let self else { return }
            pendingChunkCount = summary.pendingChunkCount
            pendingDuration = summary.pendingDuration
            pendingBytes = summary.pendingBytes
            sealedSeconds = summary.sealedDuration
            widgetHasQueueObservation = true
            publishWidgetStatus()
        }
        captureMeter.setVisible(false)
        audioSession.onEvent = { [weak self] event in await self?.handleAudioEvent(event) }
    }

    func bootstrap() async {
        guard !ready, !isRecoveringArchive else { return }
        archiveState = .capture
        archiveFailure = nil
        do {
            if !captureReady {
                failure = nil
                // A recording belongs to one process lifetime; old audio still recovers and synchronizes.
                _ = try await store.recoverInterruptedEpochs()
                interruptedEpochsRecovered = true
                let diagnostics = try await store.captureDiagnostics()
                diagnostic = diagnostics.first { $0.code != .finalized } ?? diagnostics.first
                captureReady = true
                publishWidgetStatus()
            }
            let queue = try await store.queueSummary(sessionID: sessionID)
            pendingChunkCount = queue.pendingChunkCount
            pendingDuration = queue.pendingDuration
            pendingBytes = queue.pendingBytes
            sealedSeconds = queue.sealedDuration
            widgetHasQueueObservation = true
            // Capture truth is available before the slower historical audio validation.
            activateConnectivity()
            requestStatusPublication(force: true)
            archiveState = .ledger
            try await macLink.restoreReceiver()
            let report = try await archiveRecovery(store)
            archiveState = .encodedAudio
            let spool = try await CaptureSpool.recover(directory: encoderDirectory, store: store, excludingOpenEpochs: true)
            archiveState = .capture
            if !macLink.ownsRoute {
                for deletion in try await store.pendingDeletions() where deletion.libraryInstanceID != nil {
                    guard !macLink.ownsRoute else { break }
                    try await applyDeletion(deletion)
                }
            }
            if let session = sessionID {
                let epoch = epochID
                let generation = captureState.generation
                let duration = try await store.sealedDuration(sessionID: session, excludingEpochID: epoch)
                if sessionID == session, epochID == epoch, captureState.generation == generation { completedSeconds = duration }
            }
            let currentIssues = computeArchiveIssueSignature(report: report, spool: spool)
            currentArchiveIssueSignature = currentIssues
            let acknowledged = pruneAcknowledgedArchiveIssues(validatingAgainst: currentIssues)
            if !currentIssues.subtracting(acknowledged).isEmpty {
                archiveFailure = String(localized: "上次录音有未完成或损坏的片段，请在手机检查。")
            }
            archiveState = .ready
            publishWidgetStatus()
            activateConnectivity()
            requestReconciliation(flushAudio: true)
            #if DEBUG && targetEnvironment(simulator)
            if simulatorTestCapture, ProcessInfo.processInfo.environment["MOMO_WATCH_TEST_SYNC_FAILURE"] == "1" {
                transportSyncFailure = String(localized: "连接暂时中断，原音已保留。")
                refreshSyncFailure()
            }
            #endif
        } catch is CancellationError { archiveState = .idle }
        catch {
            let stage = archiveState.description, native = error as NSError
            logger.error("Archive recovery failed at \(stage, privacy: .public): \(native.domain, privacy: .public) / \(native.code)")
            archiveState = .failed
            if captureReady { archiveFailure = String(localized: "\(stage)未完成：\(error.localizedDescription)") }
            else { failure = String(localized: "\(stage)未完成：\(error.localizedDescription)") }
            publishWidgetStatus()
        }
    }

    /// Cold launches and stale controls open the recorder for confirmation instead of replaying old actions.
    func performWidgetRequest(_ request: WatchWidgetRequest) async throws -> Bool {
        guard request.action != .open else { return true }
        guard captureReady else { return false }
        if (request.action == .start || request.action == .resume),
           request.runtimeID == diagnosticRunID,
           request.sessionID == sessionID,
           request.generation.map({ $0 <= captureState.generation }) ?? true,
           captureState.intent == .recording,
           (captureState.activity == .starting || captureState.activity == .recording) {
            return true
        }
        guard request.matches(runtimeID: diagnosticRunID, generation: captureState.generation, sessionID: sessionID) else {
            return false
        }
        switch request.action {
        case .open: break
        case .start:
            guard requiresStartTap, captureState.activity != .starting, captureState.activity != .recording else { return false }
            try await start()
        case .pause:
            guard captureState.intent == .recording else { return false }
            try await pause()
        case .resume:
            guard captureState.intent != .stopped,
                  captureState.activity != .recording, captureState.activity != .starting else { return false }
            try await resume()
        }
        return true
    }

    func setPresentationActive(_ active: Bool) {
        guard active != presentationActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let began = presentationBeganAt { presentationSeconds += max(0, now - began) }
        presentationBeganAt = active ? now : nil
        presentationActive = active
        captureMeter.setVisible(active)
        progressDelivery?.setPresentationActive(active)
    }

    func foreground() async {
        if connectivityGrant { endConnectivityGrant() }
        if !macLink.ownsRoute {
            transport.allowControlReplay()
            transport.allowAudioBlockReplay()
        }
        localSyncRetryAt = 0
        controlCursors.removeAll()
        resetAutomaticRecovery()
        statusDirty = true
        let gateInterrupted = audioInterruptionActive || audioSession.microphoneGate.interruptionActive
        if captureReady, !requiresStartTap, captureState.intent == .recording,
           (captureState.activity == .interrupted || captureState.activity == .failed || gateInterrupted) {
            audioInterruptionActive = false
            captureRecovery.cancel(resetBudget: true)
            if captureState.activity == .failed { captureState.interrupt() }
            if finalizing || startupFailureCleanup || startup != nil || worker != nil {
                deferredInterruptionResume = captureState.generation
            } else if captureState.activity == .interrupted {
                await recoverCapture(generation: captureState.generation, recoverInterruptedSession: gateInterrupted)
            }
        }
        await resumeSynchronization()
    }

    /// Reconcile durable receipts first; completed transfers also retry after a bounded acknowledgement wait.
    func resumeSynchronization(flushAudio: Bool = true) async {
        if macLink.ownsRoute {
            macLink.wake()
            if !captureReady && !connectivityGrant { await bootstrap() }
            return
        }
        flushAudioBatch = flushAudioBatch || flushAudio
        if flushAudio || transport.isReachable {
            replayReconciliationRequest = true
        }
        if flushAudio {
            reconciliationRequested = true
        }
        beginBackgroundConnectivity()
        if flushAudio, !connectivityGrant { transport.requestPeerStatus() }
        if captureReady || connectivityGrant { await reconcile() } else { await bootstrap() }
    }

    private func resetAutomaticRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryTaskID = nil
        recoveryBackoff.reset()
    }

    private func scheduleAutomaticRecovery() {
        guard !macLink.ownsRoute else { return }
        // A delegate can preserve an Inbox message just after a cold grant expires.
        // Request another OS opportunity even when historical capture recovery has not run.
        if pendingLocalSyncWork, !captureReady, !connectivityGrant { onBackgroundRetryNeeded() }
        if connectivityGrant {
            if statusDirty || pendingLocalSyncWork || (pendingChunkCount > 0 && !waitingForAudioBatch) || transport.hasRetryableControls { onBackgroundRetryNeeded() }
            return
        }
        let hasActiveWork = statusDirty || pendingLocalSyncWork || (pendingChunkCount > 0 && !waitingForAudioBatch) || transport.hasRetryableControls
        guard captureReady, hasActiveWork || (pendingChunkCount > 0 && waitingForAudioBatch), pendingReceiver == nil else {
            resetAutomaticRecovery()
            return
        }
        if hasActiveWork {
            onBackgroundRetryNeeded()
        }
        guard recoveryTask == nil else { return }
        let id = UUID()
        var delay: Double
        if !hasActiveWork, let batchDelay = audioBatchRetryDelay, batchDelay > 0 {
            delay = max(1, batchDelay.rounded(.up))
        } else {
            delay = Double(recoveryBackoff.nextDelay())
            if let hint = transport.nextRetryDelay(), hint > 0 {
                delay = min(delay, max(1, hint.rounded(.up)))
            }
            if waitingForAudioBatch, let batchDelay = audioBatchRetryDelay, batchDelay > 0 {
                delay = min(delay, max(1, batchDelay.rounded(.up)))
            }
        }
        recoveryTaskID = id
        recoveryTask = Task { @MainActor [weak self, recoverySleep] in
            do { try await recoverySleep(.seconds(delay)) }
            catch is CancellationError { return }
            catch {
                guard let self, self.recoveryTaskID == id else { return }
                self.recoveryTask = nil; self.recoveryTaskID = nil
                self.reportBackgroundFailure(error.localizedDescription)
                return
            }
            guard !Task.isCancelled, let self, self.recoveryTaskID == id else { return }
            self.recoveryTask = nil; self.recoveryTaskID = nil
            await self.resumeSynchronization(flushAudio: false)
        }
    }

    var isInConnectivityGrant: Bool { connectivityGrant }
    var requiresConstrainedConnectivityGrant: Bool {
        !presentationActive && captureState.activity != .recording && startup == nil && worker == nil
    }

    func beginBackgroundConnectivity() {
        guard !macLink.ownsRoute else { return }
        if transport.activation == .failed || transport.activation == .inactive { activateConnectivity() }
    }

    func beginConnectivityGrant() {
        energyCounters.connectivityGrants += 1
        connectivityGrant = true
        flushAudioBatch = true
        grantID = UUID()
        grantControlsRemaining = 4
        grantSubmitted = false
        grantCleaned = false
        grantLeaseChecked = false
        grantReconciliationAttempted = false
        grantLocalWorkChecked = false
        grantStatusPublished = false
        grantStatusAttempted = false
        beginBackgroundConnectivity()
    }

    func endConnectivityGrant() {
        guard connectivityGrant else { return }
        connectivityGrant = false
        grantID = nil
        if macLink.ownsRoute {
            if pendingChunkCount > 0 { onBackgroundRetryNeeded() }
            return
        }
        if !grantLocalWorkChecked || !grantStatusPublished || statusDirty || pendingLocalSyncWork || (pendingChunkCount > 0 && !waitingForAudioBatch) || transport.hasRetryableControls {
            onBackgroundRetryNeeded()
        }
    }

    private func activateConnectivity() {
        guard !macLink.ownsRoute else { return }
        #if DEBUG && targetEnvironment(simulator)
        if simulatorTestCapture { return }
        #endif
        guard transport.activation == .inactive || transport.activation == .failed else { return }
        transport.activate()
    }

    func drainBackgroundConnectivity() async -> WatchBackgroundDrainResult {
        guard !Task.isCancelled else { return .failed }
        if macLink.ownsRoute {
            if !grantReconciliationAttempted { grantReconciliationAttempted = true; macLink.wake() }
            return macLink.isScheduling ? .pending : .completed
        }
        // A WC wake has a tiny CPU grant. The already-open ledger owns sealed files;
        // historical capture/audio recovery belongs to the active recording UI.
        // Poll only the OS completion flags after the first pass. WC events reconcile new work.
        if !connectivityGrant || !grantReconciliationAttempted { await reconcile() }
        // Inbox preservation is synchronous in the WC delegate. Failed business processing
        // stays in that durable inbox and will be retried; it does not lose incoming data.
        return LinkBackgroundDrain.result(activation: transport.activation,
            hasPendingContent: transport.hasPendingContent,
            processing: reconciling || publishingStatus || (connectivityGrant && (!grantLocalWorkChecked || !linkActivated || !grantStatusAttempted)))
    }

    func drainActiveConnectivity(for drainID: UUID) async -> WatchBackgroundDrainResult {
        guard !Task.isCancelled else { return .failed }
        if macLink.ownsRoute {
            if lastActiveDrainID != drainID { lastActiveDrainID = drainID; macLink.wake() }
            return macLink.isScheduling ? .pending : .completed
        }
        // Link events and the recovery timer handle new work between OS completion checks.
        if lastActiveDrainID != drainID, captureReady, !reconciling {
            lastActiveDrainID = drainID
            if pendingLocalSyncWork || !linkActivated { await reconcile() }
        }
        return LinkBackgroundDrain.result(activation: transport.activation,
            hasPendingContent: transport.hasPendingContent,
            processing: reconciling || publishingStatus)
    }

    func reportBackgroundFailure(_ message: String) {
        transportSyncFailure = String(localized: "后台同步未完成：\(message)")
        refreshSyncFailure()
    }

    func dismissFailure() {
        if archiveFailure != nil, !currentArchiveIssueSignature.isEmpty {
            acknowledgeArchiveIssues(currentArchiveIssueSignature)
        }
        failure = nil
        inboxSyncFailure = nil
        transportSyncFailure = nil
        syncFailure = nil
        archiveFailure = nil
    }

    private var acknowledgedArchiveIssuesURL: URL {
        encoderDirectory.deletingLastPathComponent().appendingPathComponent("acknowledged-archive-issues.json")
    }

    private func computeArchiveIssueSignature(report: RecordingRecoveryReport, spool: CaptureSpoolRecovery) -> Set<String> {
        var signature = Set<String>()
        for id in report.damaged { signature.insert("ledger.damaged:\(id.uuidString)") }
        for id in report.missing { signature.insert("ledger.missing:\(id.uuidString)") }
        for item in report.unfinished {
            if item.hasPrefix("CaptureRepair/") {
                let container = encoderDirectory.deletingLastPathComponent().appendingPathComponent(item)
                for leaf in relativeLeafPaths(in: container) {
                    signature.insert("ledger.repair:\(item)/\(leaf)")
                }
            } else {
                signature.insert("ledger.unfinished:\(item)")
            }
        }
        for damaged in spool.damagedFiles { signature.insert("spool.damaged:\(damaged)") }
        let repairRoot = encoderDirectory.appendingPathComponent("Repair")
        let repairLeaves = spool.incompleteFiles.isEmpty ? [] : relativeLeafPaths(in: repairRoot)
        for leaf in repairLeaves {
            signature.insert("spool.repair:\(leaf)")
        }
        for incomplete in spool.incompleteFiles {
            if incomplete == "Repair" {
                if repairLeaves.isEmpty {
                    signature.insert("spool.repair:Repair")
                }
            } else {
                let matchedInRepair = repairLeaves.contains {
                    $0.contains("/\(incomplete)@") || $0.hasPrefix("\(incomplete)@")
                }
                if !matchedInRepair {
                    signature.insert("spool.incomplete:\(incomplete)")
                }
            }
        }
        return signature
    }

    private func relativeLeafPaths(in root: URL) -> [String] {
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else { return [] }
        if (rootStat.st_mode & mode_t(S_IFMT)) != mode_t(S_IFDIR) {
            return [root.lastPathComponent]
        }
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var results: [String] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var childStat = stat()
            guard lstat(child.path, &childStat) == 0 else { continue }
            if (childStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                let nested = relativeLeafPaths(in: child)
                if nested.isEmpty {
                    results.append(child.lastPathComponent)
                } else {
                    results += nested.map { "\(child.lastPathComponent)/\($0)" }
                }
            } else {
                let mtime = Int64(childStat.st_mtimespec.tv_sec)
                results.append("\(child.lastPathComponent)@\(childStat.st_size):\(mtime)")
            }
        }
        return results
    }

    private func loadAcknowledgedArchiveIssues() -> Set<String> {
        guard FileManager.default.fileExists(atPath: acknowledgedArchiveIssuesURL.path),
              let data = try? Data(contentsOf: acknowledgedArchiveIssuesURL),
              data.count <= 262_144,
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    private func pruneAcknowledgedArchiveIssues(validatingAgainst current: Set<String>) -> Set<String> {
        let saved = loadAcknowledgedArchiveIssues()
        let active = saved.intersection(current)
        if active != saved {
            if active.isEmpty {
                try? FileManager.default.removeItem(at: acknowledgedArchiveIssuesURL)
            } else {
                saveAcknowledgedArchiveIssues(active)
            }
        }
        return active
    }

    private func acknowledgeArchiveIssues(_ issues: Set<String>) {
        saveAcknowledgedArchiveIssues(loadAcknowledgedArchiveIssues().union(issues))
    }

    private func saveAcknowledgedArchiveIssues(_ issues: Set<String>) {
        let sorted = Array(issues).sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? data.write(to: acknowledgedArchiveIssuesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #if os(iOS) || os(watchOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: acknowledgedArchiveIssuesURL.path
        )
        #endif
    }

    private func refreshSyncFailure() {
        syncFailure = inboxSyncFailure ?? transportSyncFailure
    }

    func captureDiagnosticHistory(sessionID: UUID) async throws -> [CaptureDiagnostic] {
        try await store.captureDiagnostics().filter { $0.sessionID == sessionID }
    }

    func start() async throws {
        guard captureReady, startup == nil, worker == nil, !finalizing, !startupFailureCleanup else { throw WatchRuntimeError.busy }
        if sessionID != nil, captureState.intent != .stopped { try await resume(); return }
        sessionID = UUID(); completedSeconds = 0; sealedSeconds = 0
        captureMeter.reset()
        captureRecovery.cancel(resetBudget: true)
        audioInterruptionActive = false
        requiresStartTap = false
        try await launchEpoch()
    }

    func resume() async throws {
        guard captureReady, startup == nil, worker == nil, !finalizing, !startupFailureCleanup else { throw WatchRuntimeError.busy }
        guard sessionID != nil, captureState.intent != .stopped else { throw WatchRuntimeError.noActiveSession }
        captureRecovery.cancel(resetBudget: true)
        audioInterruptionActive = false
        requiresStartTap = false
        try await launchEpoch(resuming: true)
    }

    func pause() async throws {
        guard let sessionID else { throw WatchRuntimeError.noActiveSession }
        let event = makeDiagnostic(.paused, trigger: .user)
        captureState.pause()
        captureRecovery.cancel()
        requiresStartTap = true
        deferredInterruptionResume = nil
        inputLevel = 0
        var firstError: (any Error)?
        do { try await saveDiagnostic(event) } catch { firstError = error }
        do { try await store.saveIntent(.paused, sessionID: sessionID) } catch { if firstError == nil { firstError = error } }
        do { if !finalizing { try await finishEpoch(reason: .paused) } } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    func stop() async throws {
        guard let sessionID else { throw WatchRuntimeError.noActiveSession }
        let event = makeDiagnostic(.stopped, trigger: .user)
        captureState.stop()
        captureRecovery.cancel()
        requiresStartTap = true
        deferredInterruptionResume = nil
        inputLevel = 0
        var firstError: (any Error)?
        do { try await saveDiagnostic(event) } catch { firstError = error }
        do { try await store.saveIntent(.stopped, sessionID: sessionID) } catch { if firstError == nil { firstError = error } }
        do { if !finalizing { try await finishEpoch(reason: .stopped) } } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    func mark() async throws {
        guard let sessionID, let epochID, captureState.activity == .recording else { throw WatchRuntimeError.noActiveSession }
        try await store.recordMark(CaptureMark(sessionID: sessionID, epochID: epochID, sourceDeviceID: sourceDeviceID,
                                               sourceFrame: observedFrames))
        requestReconciliation(flushAudio: true)
    }

    func connectMac(address: String, code: String) async throws {
        defer { if !macLink.ownsRoute { requestReconciliation(flushAudio: true) } }
        try await macLink.pair(address: address, code: code)
    }

    private func stopPhoneTransfers() async throws {
        resetAutomaticRecovery()
        statusPublicationTask?.cancel()
        synchronizationTask?.cancel()
        let bulk = localBulkSyncTask
        bulk?.cancel()
        localSyncClient.closeConnections()
        await bulk?.value
        while reconciling { try await Task.sleep(for: .milliseconds(25)) }
        if transport.activation == .activated {
            try transport.cancelPeerTransfersForReceiverChange()
        }
        pendingReceiver = nil
        pendingReceiverControl = nil
        phoneStatus = nil
        inboxSyncFailure = nil
        transportSyncFailure = nil
        refreshSyncFailure()
    }

    func usePhoneReceiver() async throws {
        try await macLink.returnToPhone()
        phoneStatuses = ReceiverStatusCache()
        controlReceivers.removeAll()
        fileCursorLoaded = false
        localSyncRetryAt = 0
        waitingForAudioBatch = false
        needsPostActivationWrap = true
        linkActivated = transport.activation == .activated
        activateConnectivity()
        await resumeSynchronization()
    }

    func confirmReceiverChange() async throws {
        guard !macLink.ownsRoute, let identity = pendingReceiver else { return }
        localBulkSyncTask?.cancel()
        localBulkSyncTask = nil
        localSyncInFlightChunkIDs.removeAll()
        localSyncClient.closeConnections()
        localSyncRetryAt = 0
        lastObservedLocalSyncEndpoint = nil
        transport.cancelAudioBlockTransfer()
        try transport.resetPeerControlState()
        try await store.replaceReceiverAfterUserConfirmation(deviceID: identity.receiverDeviceID, libraryInstanceID: identity.libraryInstanceID)
        try controls.remove(pendingReceiverControl ?? .receiverIdentity(identity))
        pendingReceiver = nil
        pendingReceiverControl = nil
        controlReceivers.removeAll()
        phoneStatus = nil
        acceptPhoneStatus(deviceID: identity.receiverDeviceID, libraryInstanceID: identity.libraryInstanceID)
        statusDirty = true
        transport.allowFileReplay()
        controlCursors.removeAll()
        fileCursor = 0
        fileCursorLoaded = true
        audioBlockCursor = 0
        needsPostActivationWrap = false
        try await store.saveFileTransferPosition(0)
        reconciliationRequested = true
        await reconcile()
    }

    func handleLinkEvent(_ event: LinkEvent) async {
        guard !macLink.ownsRoute else { return }
        switch event {
        case .statusRefreshRequested:
            requestStatusPublication(force: true)
            return
        case .activationChanged(let activation):
            linkActivated = activation == .activated
            if linkActivated {
                controlCursors.removeAll()
                needsPostActivationWrap = true
                reconciliationRequested = true
                statusDirty = true
                requestStatusPublication(force: true)
                transport.requestPeerStatus()
            }
        case .failed(let error):
            energyCounters.transferFailures += 1
            if !WatchConnectivityTransport.isTransientChannelFailure(error) {
                transportSyncFailure = String(localized: "传输失败：\(error.diagnosticDescription)")
                refreshSyncFailure()
            }
        case .fileTransportFinished(let chunkID, let error):
            energyCounters.fileCompletions += 1
            if let error {
                energyCounters.transferFailures += 1
                if !WatchConnectivityTransport.isTransientChannelFailure(error) {
                    transportSyncFailure = String(localized: "传输未完成：\(error.diagnosticDescription)")
                    refreshSyncFailure()
                }
            } else {
                transportSyncFailure = nil
                refreshSyncFailure()
            }
            do {
                if error == nil, try await store.receiptRequiresReconciliation(chunkID: chunkID) { reconciliationRequested = true }
            }
            catch {
                transportSyncFailure = String(localized: "待重传片段尚未读取：\(error.localizedDescription)")
                refreshSyncFailure()
            }
        case .audioBlockSourceInvalid(let chunkID):
            invalidAudioBlockSources.insert(chunkID)
            if let chunk = try? await store.chunk(id: chunkID) {
                _ = try? await store.originalAvailableForTransferRetry(chunk.envelope, maximumValidationBytes: Int64.max)
            }
        case .controlTransportFinished(let message, let error):
            energyCounters.controlCompletions += 1
            if error != nil { energyCounters.transferFailures += 1 }
            do {
                if try transport.controlDeliveryIsConfirmed(message), let receiver = controlReceivers[message.messageID] {
                    try await store.markControlPreserved(message, receiverDeviceID: receiver.deviceID,
                        libraryInstanceID: receiver.libraryInstanceID)
                    controlReceivers.removeValue(forKey: message.messageID)
                }
            } catch {
                transportSyncFailure = String(localized: "同步收件证明尚未保存：\(error.localizedDescription)")
                refreshSyncFailure()
            }
            if let error {
                if !WatchConnectivityTransport.isTransientChannelFailure(error) {
                    transportSyncFailure = String(localized: "同步指令暂未送达，将自动重试：\(error.diagnosticDescription)")
                    refreshSyncFailure()
                }
            } else {
                transportSyncFailure = nil
                refreshSyncFailure()
            }
        case .controlPreserved, .filePreserved, .audioBlockCommitted:
            if case .audioBlockCommitted = event {
                transportSyncFailure = nil
                refreshSyncFailure()
            }
            pendingLocalSyncWork = true
            scheduleAutomaticRecovery()
        case .controlSubmissionChanged: break
        case .selectedWatchChanged, .selectedWatchStatusReceived, .selectedWatchStatusFailed: return // iPhone-local selection events.
        case .statusReceived(let snapshot, _):
            guard case .phone = snapshot.payload else { return }
            var unlockedAudioBlockRecovery = false
            do {
                if let receiver = try await store.boundReceiver() {
                    phoneStatuses.bind(deviceID: receiver.deviceID, libraryInstanceID: receiver.libraryInstanceID)
                }
                if let pendingReceiver {
                    phoneStatuses.expectReceiver(deviceID: pendingReceiver.receiverDeviceID, libraryInstanceID: pendingReceiver.libraryInstanceID)
                }
                let hadAudioBlockSupport: Bool = {
                    guard case .phone(let payload) = phoneStatus?.payload else { return false }
                    return payload.audioBlockVersion == AudioBlock.version
                }()
                try phoneStatuses.receive(snapshot)
                phoneStatus = phoneStatuses.boundStatus
                if case .phone(let currentPayload) = phoneStatus?.payload,
                   currentPayload.localSync != lastObservedLocalSyncEndpoint {
                    lastObservedLocalSyncEndpoint = currentPayload.localSync
                    localSyncRetryAt = 0
                }
                let hasAudioBlockSupport: Bool = {
                    guard case .phone(let payload) = phoneStatus?.payload else { return false }
                    return payload.audioBlockVersion == AudioBlock.version
                }()
                unlockedAudioBlockRecovery = !hadAudioBlockSupport && hasAudioBlockSupport
                    && !connectivityGrant && pendingReceiver == nil
                    && transport.isReachable && (transport.outstandingFileCount > 0 || pendingChunkCount > 0)
                if !connectivityGrant, pendingReceiver == nil {
                    startLocalBulkSyncIfPossible()
                    if !unlockedAudioBlockRecovery {
                        try await submitAudioBlockCopy()
                    }
                }
            } catch {
                transportSyncFailure = String(localized: "无法核对手机状态：\(error.localizedDescription)")
                refreshSyncFailure()
                return
            }
            if !unlockedAudioBlockRecovery {
                return // Replaceable observations never trigger a response or another reconciliation pass.
            }
        }
        await reconcile()
    }

    private func launchEpoch(resuming: Bool = false, trigger: CaptureDiagnosticTrigger = .user,
                             recoverInterruptedSession: Bool = false) async throws {
        guard let sessionID else { throw WatchRuntimeError.noActiveSession }
        if connectivityGrant { endConnectivityGrant() }
        let generation = captureState.start()
        let epoch = UUID()
        epochID = nil; failure = nil; inputSampleRate = nil
        progressDelivery = nil
        levelDelivery?.finish(); levelDelivery = nil
        levelConsumer?.cancel(); levelConsumer = nil
        resumingGeneration = resuming ? generation : nil
        let task = Task { @MainActor [self] in
            try await remember(resuming ? .resumeRequested : .startRequested, trigger: trigger)
            _ = try await store.checkCaptureCapacity(reader: capacityReader)
            try checkGeneration(generation)
            try await store.saveIntent(.recording, sessionID: sessionID)
            try checkGeneration(generation)
            try await store.beginEpoch(sessionID: sessionID, epochID: epoch, sourceDeviceID: sourceDeviceID)
            epochID = epoch
            try checkGeneration(generation)
            try await audioSession.activate(recoverInterruptedSession: trigger == .user || recoverInterruptedSession)
            try checkGeneration(generation)
            let gate = audioSession.microphoneGate
            let levelGate = captureMeter.deliveryGate
            let levels = CaptureLevelDelivery()
            let input = try engine.start(inputAllowed: { gate.allowsInput() },
                levelDeliveryAllowed: { levelGate.isEnabled }, onLevel: { rms, uptime in
                levels.send(rms: rms, at: uptime)
            })
            levelDelivery = levels
            levelConsumer = Task { @MainActor [weak self] in
                for await _ in levels.notifications {
                    guard let sample = levels.takeLatest(),
                          let self, self.captureState.generation == generation,
                          self.captureState.intent == .recording, gate.allowsInput() else { continue }
                    self.captureMeter.record(rms: sample.rms, at: sample.uptime)
                }
            }
            inputSampleRate = input.sampleRate
            let directory = encoderDirectory.appendingPathComponent(sessionID.uuidString).appendingPathComponent(epoch.uuidString)
            let store = self.store; let device = sourceDeviceID; let build = sourceBuild
            let capacityReader = self.capacityReader
            #if DEBUG && targetEnvironment(simulator)
            let sourceKind: SourceKind = simulatorTestCapture ? .fixture : .watch
            #else
            let sourceKind: SourceKind = .watch
            #endif
            let delivery = CaptureProgressDelivery(presentationActive: presentationActive)
            progressDelivery = delivery
            let consumer = Task { @MainActor [weak self] in
                for await _ in delivery.updates {
                    guard let update = delivery.take() else { continue }
                    await self?.received(update.progress, generation: generation, hasSealedChunk: update.hasSealedChunk)
                }
            }
            progressConsumer = consumer
            let worker = Task.detached(priority: .userInitiated) {
                defer { delivery.finish() }
                return try await CaptureEncoder.run(input: input, directory: directory, sessionID: sessionID,
                                             epochID: epoch, sourceDeviceID: device, sourceBuild: build,
                                             sourceKind: sourceKind, store: store, capacityReader: capacityReader, progress: { progress in
                    _ = delivery.receive(progress)
                })
            }
            self.worker = worker
            Task { @MainActor [weak self] in
                let result = await worker.result
                await consumer.value
                await self?.workerFinished(result, generation: generation)
            }
            startWatchdog(generation: generation)
            try await remember(.started, trigger: trigger)
        }
        startup = task
        startupGeneration = generation
        do {
            try await task.value
            if startupGeneration == generation { startup = nil; startupGeneration = nil }
        }
        catch {
            let ownsFailedAttempt = captureState.generation == generation
            // Hold admission across every diagnostic/cleanup await, including automatic recovery failures.
            if ownsFailedAttempt { startupFailureCleanup = true }
            defer { if ownsFailedAttempt { startupFailureCleanup = false } }
            if startupGeneration == generation { startup = nil; startupGeneration = nil }
            if captureState.generation == generation, audioSession.microphoneGate.interruptionActive {
                // The synchronous gate can observe a call before its ordered MainActor event arrives.
                // Preserve recording intent so the later interruption-ended event can recover it.
                let event = makeDiagnostic(.systemInterruption, trigger: .audioSession)
                captureState.interrupt()
                var firstError: (any Error)?
                do { try await saveDiagnostic(event) } catch { firstError = error }
                do { try await finishEpoch(reason: .interrupted, allowInputRouteChange: true) }
                catch { if firstError == nil { firstError = error } }
                if let firstError { failure = String(localized: "录音中断清理失败：\(firstError.localizedDescription)"); throw firstError }
                if ownsFailedAttempt { startupFailureCleanup = false }
                if deferredInterruptionResume == captureState.generation {
                    deferredInterruptionResume = nil
                    await recoverCapture(generation: captureState.generation,
                                         recoverInterruptedSession: audioSession.microphoneGate.interruptionActive)
                }
                throw CancellationError()
            }
            if captureState.generation == generation {
                let event = makeDiagnostic(resuming ? .resumeFailed : .startupFailed, trigger: trigger,
                                           safeError: safeCaptureError(error, starting: true))
                captureState.fail()
                var diagnosticError: (any Error)?
                do { try await saveDiagnostic(event) } catch { diagnosticError = error }
                do { try await finishAfterFailure(error, starting: true) }
                catch { failure = String(localized: "录音启动及清理失败：\(error.localizedDescription)"); throw error }
                if let diagnosticError { failure = String(localized: "采集诊断未保存：\(diagnosticError.localizedDescription)"); throw diagnosticError }
                failure = String(localized: "无法开始录音：\(error.localizedDescription)")
            }
            throw error
        }
    }

    private func checkGeneration(_ generation: UInt64) throws {
        guard captureState.generation == generation, captureState.intent == .recording else { throw CancellationError() }
    }

    private func received(_ progress: CaptureProgress, generation: UInt64, hasSealedChunk: Bool) async {
        energyCounters.progressDeliveries += 1
        defer { recordEnergyIfDue() }
        let previousActivity = captureState.activity
        let delta = progress.frames - captureState.capturedFrames
        if captureState.receivedSamples(frames: delta, uptime: progress.uptime, generation: generation) {
            if previousActivity == .starting {
                do {
                    try await remember(.firstSamples, trigger: .engine)
                    if resumingGeneration == generation {
                        resumingGeneration = nil
                        try await remember(.resumeSucceeded, trigger: .recovery)
                    }
                } catch { failure = String(localized: "采集诊断未保存：\(error.localizedDescription)") }
            }
            guard captureState.generation == generation, captureState.intent == .recording,
                  captureState.activity == .recording else { return }
            inputLevel = progress.normalizedLevel
        }
        if hasSealedChunk {
            requestReconciliation(flushAudio: true)
        }
        else { requestStatusPublication(force: previousActivity != captureState.activity) }
    }

    private func finishEpoch(reason: CaptureEndReason, deletingSession: UUID? = nil,
                             allowInputRouteChange: Bool = false,
                             allowRecoverableStreamEnd: Bool = false) async throws {
        guard !finalizing else { throw WatchRuntimeError.busy }
        finalizing = true
        let beganFinalizing = ProcessInfo.processInfo.systemUptime
        let ending = makeDiagnostic(.finalized, trigger: .lifecycle)
        inputLevel = 0
        defer {
            if resetEngineAfterFinalization { engine = AudioCaptureEngine(); resetEngineAfterFinalization = false }
            finalizing = false
            recordEnergyIfDue(force: true)
        }
        watchdog?.cancel(); watchdog = nil
        if let startup {
            let generation = startupGeneration
            _ = await startup.result
            if startupGeneration == generation { self.startup = nil; startupGeneration = nil }
        }
        engine.stop()
        levelDelivery?.finish(); levelDelivery = nil
        levelConsumer?.cancel(); levelConsumer = nil
        let result = await worker?.result
        await progressConsumer?.value
        progressConsumer = nil
        worker = nil
        var encodingError: (any Error)?
        var inputRouteEnded = false
        var recoverableStreamEnded = false
        var frames: Int64 = 0
        if let result {
            switch result {
            case .success(let count):
                frames = count
                if allowRecoverableStreamEnd { recoverableStreamEnded = true }
            case .failure(let error):
                if allowInputRouteChange, error as? AudioCaptureError == .unexpectedInputRoute {
                    inputRouteEnded = true
                    break
                }
                if allowRecoverableStreamEnd,
                   let captureError = error as? AudioCaptureError,
                   [.discontinuousInput, .bufferOverflow, .notRunning].contains(captureError) {
                    recoverableStreamEnded = true
                    break
                }
                if let deletingSession, case RecordingError.deletedSession(let id) = error, id == deletingSession { break }
                encodingError = error
            }
        }
        var persistenceError: (any Error)?
        if let capacityError = encodingError as? CaptureCapacityError,
           diagnostic?.epochID != epochID || (diagnostic?.code != .lowSpace && diagnostic?.code != .capacityUnavailable) {
            // Pause/stop can win the generation race before workerFinished observes the same refusal.
            do { try await rememberFailure(capacityError, starting: false) }
            catch { persistenceError = error }
        }
        do {
            if let sessionID, let epochID {
                if encodingError != nil || inputRouteEnded || recoverableStreamEnded {
                    try await store.recordEpochInterruption(sessionID: sessionID, epochID: epochID,
                        sourceDeviceID: sourceDeviceID, lastObservedFrame: max(observedFrames, frames),
                        reason: encodingError == nil ? reason : .failed)
                } else {
                    try await store.recordEpochEnded(CaptureEpochEnded(sessionID: sessionID, epochID: epochID,
                        sourceDeviceID: sourceDeviceID, endFrame: frames, reason: reason))
                }
                completedSeconds = try await store.sealedDuration(sessionID: sessionID)
            }
            epochID = nil
        } catch { if persistenceError == nil { persistenceError = error } }
        let keepAudioSessionActive = (reason == .interrupted || reason == .failed)
            && captureState.intent == .recording && !requiresStartTap
        if keepAudioSessionActive {
            audioSession.microphoneGate.deactivate()
        } else {
            do { try await audioSession.deactivate() }
            catch {
                try await saveDiagnostic(completing: ending, code: .cleanupFailed,
                                         duration: ProcessInfo.processInfo.systemUptime - beganFinalizing,
                                         error: safeCaptureError(error, starting: false))
                if let persistenceError { failure = String(localized: "录音结束记录未保存：\(persistenceError.localizedDescription)；音频会话关闭失败：\(error.localizedDescription)") }
                throw error
            }
        }
        let endError = persistenceError ?? encodingError
        // Refusing a new chunk for capacity is the stop reason, not a failed cleanup.
        let cleanupError = persistenceError ?? (encodingError is CaptureCapacityError ? nil : encodingError)
        try await saveDiagnostic(completing: ending, code: cleanupError == nil ? .finalized : .cleanupFailed,
                                 duration: ProcessInfo.processInfo.systemUptime - beganFinalizing,
                                 error: cleanupError.map { safeCaptureError($0, starting: false) })
        if let endError { throw endError }
        requestReconciliation(flushAudio: true)
    }

    private func workerFinished(_ result: Result<Int64, any Error>, generation: UInt64) async {
        guard captureState.generation == generation, !finalizing else { return }
        if case .failure(let error) = result, error as? AudioCaptureError == .unexpectedInputRoute {
            // An actual system interruption closes the same gate. Wait for its end in that case.
            let builtIn = audioSession.microphoneGate.builtInMicrophoneSelected
            await captureDisrupted(code: builtIn ? .systemInterruption : .routeChanged,
                                   trigger: .engine, recover: !builtIn, allowInputRouteChange: true)
            return
        }
        if !requiresStartTap, captureState.intent == .recording,
           (captureState.activity == .recording || captureState.activity == .starting) {
            switch result {
            case .failure(let error) where error as? AudioCaptureError == .discontinuousInput:
                await captureDisrupted(code: .discontinuousInput, trigger: .worker, recover: true,
                                       replaceEngine: true, allowRecoverableStreamEnd: true)
                return
            case .failure(let error) where error as? AudioCaptureError == .bufferOverflow:
                await captureDisrupted(code: .inputOverflow, trigger: .worker, recover: true,
                                       replaceEngine: true, allowRecoverableStreamEnd: true)
                return
            case .failure(let error) where error as? AudioCaptureError == .notRunning:
                await captureDisrupted(code: .inputEnded, trigger: .worker, recover: true,
                                       replaceEngine: true, allowRecoverableStreamEnd: true)
                return
            case .success:
                await captureDisrupted(code: .inputEnded, trigger: .worker, recover: true,
                                       replaceEngine: true, allowRecoverableStreamEnd: true)
                return
            default:
                break
            }
        }
        let error: any Error
        switch result {
        case .failure(let failure): error = failure
        case .success:
            do { try await remember(.inputEnded, trigger: .worker) }
            catch { failure = String(localized: "采集诊断未保存：\(error.localizedDescription)") }
            error = AudioCaptureError.notRunning
        }
        captureState.fail()
        do { try await finishAfterFailure(error, starting: false) }
        catch { failure = String(localized: "录音已停止：\(error.localizedDescription)"); return }
        failure = String(localized: "录音已停止：\(error.localizedDescription)")
    }

    private func startWatchdog(generation: UInt64) {
        let started = ProcessInfo.processInfo.systemUptime
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.captureState.generation == generation else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let tap = self.engine.healthSnapshot
                if now - (tap.lastTapUptime ?? started) > 5 {
                    await self.captureDisrupted(code: .inputStalled, trigger: .watchdog, recover: true)
                    return
                }
                if now - (self.encoderProgressObservedAt ?? started) > 5 {
                    // A live tap with no consumer progress is an encoder/storage failure, not a microphone interruption.
                    await self.captureDisrupted(code: .encoderStalled, trigger: .watchdog, recover: false)
                    return
                }
            }
        }
    }

    func handleAudioEvent(_ event: WatchAudioEvent) async {
        switch event {
        case .interruptionBegan:
            captureRecovery.cancel()
            deferredInterruptionResume = nil
            audioInterruptionActive = true
            await captureDisrupted(code: .systemInterruption, trigger: .audioSession, recover: false,
                                   allowInputRouteChange: true)
        case .interruptionEnded(let shouldResume):
            audioInterruptionActive = false
            guard !requiresStartTap, captureState.intent == .recording, captureState.activity == .interrupted else { return }
            // The tap can begin finalization before this ordered notification reaches MainActor.
            // Keep the request even while diagnostic persistence is suspended before finalizing=true.
            deferredInterruptionResume = captureState.generation
            do { try await remember(.systemInterruption, trigger: .audioSession, shouldResume: shouldResume) }
            catch { failure = String(localized: "采集诊断未保存：\(error.localizedDescription)"); return }
            // shouldResume is a playback hint, not the user's continuous-recording intent.
            // Only an ended interruption may get here; setActive still owns admission.
            if finalizing || startupFailureCleanup || startup != nil || worker != nil { return }
            deferredInterruptionResume = nil
            await recoverCapture(generation: captureState.generation)
        case .routeChanged(let reason, let builtIn):
            // Activation/deactivation and headphone OUTPUT changes also emit notifications.
            // A still-valid built-in input must not cancel the first start or pause a live recording.
            guard !builtIn, !audioSession.microphoneGate.builtInMicrophoneSelected else { return }
            await captureDisrupted(code: .routeChanged, trigger: .audioSession, recover: true,
                                   routeChangeReason: reason, allowInputRouteChange: true)
        case .mediaServicesReset:
            audioInterruptionActive = false
            if finalizing {
                resetEngineAfterFinalization = true
                if !requiresStartTap, captureState.intent == .recording {
                    deferredInterruptionResume = captureState.generation
                }
                return
            }
            if !requiresStartTap, captureState.activity == .interrupted {
                await recoverCapture(generation: captureState.generation)
                return
            }
            guard captureState.intent == .recording else { engine = AudioCaptureEngine(); return }
            await captureDisrupted(code: .mediaServicesReset, trigger: .audioSession, recover: true,
                                   replaceEngine: true, allowInputRouteChange: true)
        }
    }

    private func captureDisrupted(code: CaptureDiagnosticCode, trigger: CaptureDiagnosticTrigger, recover: Bool,
                                  routeChangeReason: UInt? = nil, replaceEngine: Bool = false,
                                  allowInputRouteChange: Bool = false,
                                  allowRecoverableStreamEnd: Bool = false) async {
        guard captureState.intent == .recording, !finalizing,
              captureState.activity == .recording || captureState.activity == .starting else { return }
        let event = makeDiagnostic(code, trigger: trigger, routeChangeReason: routeChangeReason)
        captureState.interrupt()
        let generation = captureState.generation
        var firstError: (any Error)?
        do { try await saveDiagnostic(event) } catch { firstError = error }
        guard captureState.generation == generation, captureState.intent == .recording else { return }
        do {
            do {
                try await finishEpoch(reason: .interrupted,
                                      allowInputRouteChange: allowInputRouteChange,
                                      allowRecoverableStreamEnd: allowRecoverableStreamEnd)
            }
            catch { if firstError == nil { firstError = error } }
            if let firstError { throw firstError }
            if replaceEngine { engine = AudioCaptureEngine() }
            let deferred = deferredInterruptionResume == generation
            deferredInterruptionResume = nil
            if (recover || deferred), !audioInterruptionActive {
                await recoverCapture(generation: generation,
                                     recoverInterruptedSession: deferred && audioSession.microphoneGate.interruptionActive)
            } else if !audioInterruptionActive {
                failure = code == .encoderStalled ? String(localized: "录音处理未能继续，已保留封口原音。请重试录音。") : String(localized: "录音已中断，请继续录音。")
            }
        } catch {
            deferredInterruptionResume = nil
            failure = String(localized: "录音中断：\(error.localizedDescription)")
        }
    }

    private func recoverCapture(generation: UInt64, recoverInterruptedSession: Bool = false) async {
        guard !requiresStartTap, captureState.generation == generation, captureState.intent == .recording,
              captureState.activity == .interrupted,
              !audioInterruptionActive, (recoverInterruptedSession || !audioSession.microphoneGate.interruptionActive),
              !finalizing, !startupFailureCleanup, startup == nil, worker == nil else { return }
        await captureRecovery.request { [weak self] in
            guard let self, !self.requiresStartTap, self.captureState.generation == generation,
                  self.captureState.intent == .recording, self.captureState.activity == .interrupted,
                  !self.audioInterruptionActive, (recoverInterruptedSession || !self.audioSession.microphoneGate.interruptionActive),
                  !self.finalizing, !self.startupFailureCleanup, self.startup == nil, self.worker == nil else { return }
            self.engine = AudioCaptureEngine()
            do {
                try await self.launchEpoch(resuming: true, trigger: .recovery,
                                           recoverInterruptedSession: recoverInterruptedSession)
            }
            catch is CancellationError {
                if recoverInterruptedSession, !self.requiresStartTap,
                   self.captureState.intent == .recording, self.captureState.activity == .interrupted,
                   self.audioSession.microphoneGate.interruptionActive {
                    self.failure = String(localized: "麦克风暂时被占用，稍后自动恢复。")
                    self.requestStatusPublication(force: true)
                    await self.recoverCapture(generation: self.captureState.generation, recoverInterruptedSession: true)
                }
                return
            }
            catch {
                self.failure = String(localized: "未能恢复手表麦克风：\(error.localizedDescription)")
                // Retry only the OS's explicit priority refusal, after normal epoch cleanup.
                // Storage, permission and encoder errors keep their original failure semantics.
                if WatchAudioSession.microphoneIsOccupied(error), !self.requiresStartTap,
                   self.captureState.intent == .recording, self.captureState.activity == .failed {
                    self.captureState.interrupt()
                    self.failure = String(localized: "麦克风暂时被占用，稍后自动恢复。")
                    self.requestStatusPublication(force: true)
                    await self.recoverCapture(generation: self.captureState.generation,
                                              recoverInterruptedSession: recoverInterruptedSession)
                }
            }
        }
    }

    private func makeDiagnostic(_ code: CaptureDiagnosticCode, trigger: CaptureDiagnosticTrigger,
                                routeChangeReason: UInt? = nil, shouldResume: Bool? = nil,
                                safeError: CaptureDiagnosticSafeError? = nil) -> CaptureDiagnostic? {
        guard let sessionID else { return nil }
        diagnosticSequence += 1
        return CaptureDiagnostic(code: code, sessionID: sessionID, epochID: epochID,
            observedFrames: observedFrames, inputSampleRate: inputSampleRate,
            lastSampleUptime: observedSampleUptime,
            context: CaptureDiagnosticContext(runID: diagnosticRunID, sequence: diagnosticSequence,
                sourceBuild: sourceBuild, uptime: ProcessInfo.processInfo.systemUptime,
                intent: captureState.intent, activity: captureState.activity, generation: captureState.generation,
                trigger: trigger, routeChangeReason: routeChangeReason, shouldResume: shouldResume,
                builtInMicrophoneSelected: audioSession.microphoneGate.builtInMicrophoneSelected,
                tap: engine.healthSnapshot, encoderProgressObservedAtUptime: encoderProgressObservedAt,
                safeError: safeError))
    }

    private func saveDiagnostic(_ event: CaptureDiagnostic?) async throws {
        guard let event else { return }
        // Successful cleanup is history, not a replacement for the reason capture stopped.
        if event.code != .finalized { diagnostic = event }
        try await store.recordDiagnostic(event)
        requestStatusPublication(force: true)
    }

    private func saveDiagnostic(completing event: CaptureDiagnostic?, code: CaptureDiagnosticCode,
                                duration: TimeInterval, error: CaptureDiagnosticSafeError?) async throws {
        guard let event, let c = event.context else { return }
        let completed = CaptureDiagnostic(code: code, sessionID: event.sessionID, epochID: event.epochID,
            observedFrames: event.observedFrames, inputSampleRate: event.inputSampleRate,
            lastSampleUptime: event.lastSampleUptime,
            context: CaptureDiagnosticContext(runID: c.runID, sequence: c.sequence, sourceBuild: c.sourceBuild,
                uptime: c.uptime, intent: c.intent, activity: c.activity, generation: c.generation, trigger: c.trigger,
                builtInMicrophoneSelected: c.builtInMicrophoneSelected, tap: c.tap,
                encoderProgressObservedAtUptime: c.encoderProgressObservedAtUptime,
                finalizationDuration: duration, safeError: error))
        try await saveDiagnostic(completed)
    }

    private func remember(_ code: CaptureDiagnosticCode, trigger: CaptureDiagnosticTrigger = .user,
                          shouldResume: Bool? = nil, safeError: CaptureDiagnosticSafeError? = nil) async throws {
        try await saveDiagnostic(makeDiagnostic(code, trigger: trigger, shouldResume: shouldResume, safeError: safeError))
    }

    private func safeCaptureError(_ error: any Error, starting: Bool) -> CaptureDiagnosticSafeError {
        let family: CaptureDiagnosticErrorFamily
        if error is CaptureCapacityError { family = .capacity }
        else if let session = error as? WatchAudioSessionError {
            family = session == .permissionDenied ? .permission : .audioInput
        } else if error is AudioCaptureError { family = .audioInput }
        else { family = starting ? .audioSession : .encoder }
        return CaptureDiagnosticSafeError(error: error, family: family)
    }

    private func rememberFailure(_ error: any Error, starting: Bool) async throws {
        guard let sessionID else { return }
        engine.stop()
        if let capacityError = error as? CaptureCapacityError {
            if captureState.intent != .stopped { captureState.pause() }
            captureState.fail()
            captureRecovery.cancel()
            deferredInterruptionResume = nil
            inputLevel = 0
            let snapshot: CaptureCapacitySnapshot?
            if case .insufficient(let value) = capacityError { snapshot = value } else { snapshot = nil }
            let event = CaptureDiagnostic(code: snapshot == nil ? .capacityUnavailable : .lowSpace,
                sessionID: sessionID, epochID: epochID, observedFrames: observedFrames,
                inputSampleRate: inputSampleRate, lastSampleUptime: observedSampleUptime, capacity: snapshot,
                context: makeDiagnostic(snapshot == nil ? .capacityUnavailable : .lowSpace, trigger: .worker,
                                        safeError: safeCaptureError(error, starting: starting))?.context)
            diagnostic = event
            try await store.recordCapacityStop(event)
            requestStatusPublication(force: true)
        } else {
            let code: CaptureDiagnosticCode
            switch error {
            case AudioCaptureError.bufferOverflow: code = .inputOverflow
            case AudioCaptureError.discontinuousInput: code = .discontinuousInput
            default: code = starting ? .startupFailed : .writerFailed
            }
            try await remember(code, trigger: starting ? .engine : .worker, safeError: safeCaptureError(error, starting: starting))
        }
    }

    private func finishAfterFailure(_ error: any Error, starting: Bool) async throws {
        var firstFailure: (any Error)?
        do { try await rememberFailure(error, starting: starting) }
        catch { firstFailure = error }
        do { try await finishEpoch(reason: .failed) }
        catch { if firstFailure == nil { firstFailure = error } }
        if let firstFailure { throw firstFailure }
    }

    private func requestReconciliation(flushAudio: Bool = false) {
        if macLink.ownsRoute { macLink.wake(); return }
        flushAudioBatch = flushAudioBatch || flushAudio
        guard synchronizationTask == nil else { reconcileAgain = true; return }
        synchronizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.synchronizationTask = nil }
            await self.reconcile()
        }
    }

    private func reconcile() async {
        guard !macLink.ownsRoute else { return }
        // The ledger is ready before historical audio validation. Its durable outbox can sync immediately.
        guard captureReady || connectivityGrant, !Task.isCancelled else { return }
        guard !reconciling else { reconcileAgain = true; return }
        let startingGrant = grantID
        if connectivityGrant { grantReconciliationAttempted = true }
        var checkedLocalWork = false
        reconciling = true
        defer {
            reconciling = false
            // Expiration can interrupt an actor call after it has created a durable outbox item.
            // A later grant must finish this local check even if no transport retry exists yet.
            if !checkedLocalWork { pendingLocalSyncWork = true }
            if connectivityGrant, grantID == startingGrant, checkedLocalWork { grantLocalWorkChecked = true }
            scheduleAutomaticRecovery()
            updateSynchronizationState()
        }
        repeat {
            reconcileAgain = false
            energyCounters.reconciliationPasses += 1
            checkedLocalWork = false
            do {
                var nextSyncFailure: String?
                if connectivityGrant, !captureReady, !interruptedEpochsRecovered {
                    _ = try await store.recoverInterruptedEpochs()
                    interruptedEpochsRecovered = true
                }
                let batch: ControlInboxBatch
                if connectivityGrant {
                    batch = grantControlsRemaining > 0 ? try controls.loadBackgroundPage(limit: grantControlsRemaining)
                        : ControlInboxBatch(messages: [], failures: [])
                    grantControlsRemaining -= batch.messages.count + batch.failures.count
                } else { batch = try controls.loadBackgroundPage(limit: 32) }
                if !batch.messages.isEmpty || !batch.failures.isEmpty { pendingLocalSyncWork = true }
                if batch.hasMore { reconcileAgain = true }
                if let issue = batch.failures.first { nextSyncFailure = String(localized: "收到的同步指令无法读取：\(issue)") }
                let pending = batch.messages.sorted { Self.controlPriority($0) < Self.controlPriority($1) }
                for control in pending {
                    guard !Task.isCancelled else { return }
                    guard !macLink.ownsRoute, grantID == startingGrant else { return }
                    do {
                        switch control {
                        case .receiverIdentity(let identity):
                            do { try await store.bindReceiver(deviceID: identity.receiverDeviceID, libraryInstanceID: identity.libraryInstanceID) }
                            catch RecordingError.receiverMismatch {
                                transport.cancelAudioBlockTransfer()
                                pendingReceiver = identity; pendingReceiverControl = control
                                phoneStatuses.expectReceiver(deviceID: identity.receiverDeviceID, libraryInstanceID: identity.libraryInstanceID)
                                continue
                            }
                            acceptPhoneStatus(deviceID: identity.receiverDeviceID, libraryInstanceID: identity.libraryInstanceID)
                            // The first identity must refresh cached status even when no recording timer is running.
                            statusDirty = true
                        case .receipt(let receipt):
                            // WC can deliver a receipt before the separately queued identity. Retain it until bound.
                            guard try await store.boundReceiver() != nil, pendingReceiver == nil else { continue }
                            // Old Watch deliveries cannot be applied without a locally owned manifest.
                            guard try await store.chunk(id: receipt.chunkID) != nil else { break }
                            do {
                                let applied = try await store.applyReceipt(receipt)
                                invalidAudioBlockSources.remove(receipt.chunkID)
                                try transport.confirmFileDelivery(applied.receipt)
                                try transport.allowControlReplay(.receiptApplied(applied))
                                controlCursors.removeValue(forKey: .receipt)
                            }
                            catch RecordingError.receiptNeedsReconciliation, RecordingError.receiptMismatch { reconciliationRequested = true }
                            catch RecordingError.missingChunk, RecordingError.deletedSession, RecordingError.receiverMismatch { break }
                        case .deleteSession(let deletion):
                            // Delayed legacy/foreign commands cannot inherit authority from a new binding.
                            guard deletion.libraryInstanceID != nil else {
                                reconciliationRequested = true
                                try controls.remove(control)
                                continue
                            }
                            do { try await applyDeletion(deletion) }
                            catch RecordingError.receiverMismatch { try controls.remove(control); continue }
                        case .reconcileResponse(let response):
                            guard try await store.boundReceiver() != nil, pendingReceiver == nil else { continue }
                            do {
                                let outcome = try await store.applyReconciliationResponse(response)
                                if outcome.requiresFreshRequest { reconciliationRequested = true }
                                for deletion in outcome.deletions { try await applyDeletion(deletion) }
                                for applied in outcome.receiptApplications {
                                    try transport.confirmFileDelivery(applied.receipt)
                                }
                                if !outcome.unconfirmedReceiptApplications.isEmpty {
                                    for applied in outcome.unconfirmedReceiptApplications {
                                        try transport.allowControlReplay(.receiptApplied(applied))
                                    }
                                    controlCursors.removeValue(forKey: .receipt)
                                }
                                if !outcome.conflictingChunkIDs.isEmpty { nextSyncFailure = String(localized: "部分片段与手机资料冲突，手表原音已保留。") }
                                else if !outcome.unavailableChunkIDs.isEmpty { nextSyncFailure = String(localized: "对账发现部分原音已不可用，请在手机检查。") }
                            } catch RecordingReconciliationError.unknownRequest,
                                    RecordingReconciliationError.responseMismatch,
                                    RecordingError.missingChunk,
                                    RecordingError.deletedSession {
                                reconciliationRequested = true
                            }
                        case .receiptApplied, .deleteApplied, .epochEnded, .epochInterrupted, .captureMark, .reconcileRequest:
                            throw WatchRuntimeError.unexpectedControlMessage
                        }
                        try controls.remove(control)
                    } catch {
                        nextSyncFailure = String(localized: "收到的录音同步指令尚未完成：\(error.localizedDescription)")
                    }
                }
                // An old SDK transfer can outlive its durable receipt and an app restart.
                // Free those copies before admitting newer audio; never use status/transport success as proof.
                if transport.activation == .activated {
                    for envelope in try transport.outstandingFileEnvelopes() {
                        if let receipt = try await store.confirmedReceipt(chunkID: envelope.manifest.chunkID) {
                            try transport.confirmFileDelivery(receipt)
                        }
                    }
                    if !connectivityGrant || !grantLeaseChecked {
                        if connectivityGrant { grantLeaseChecked = true }
                        let maximumBytes: Int64 = connectivityGrant ? 1_048_576 : 64 * 1_048_576
                        let boundReceiver = try await store.boundReceiver()
                        let audioBlockRecoveryAvailable: Bool = {
                            guard !connectivityGrant,
                                  let receiver = boundReceiver, let status = phoneStatus,
                                  status.sourceDeviceID == receiver.deviceID,
                                  case .phone(let payload) = status.payload,
                                  payload.libraryInstanceID == receiver.libraryInstanceID else { return false }
                            return payload.audioBlockVersion == AudioBlock.version
                        }()
                        let interactiveFastPath = audioBlockRecoveryAvailable
                            && (presentationActive || statusBudget.isPeerViewing(now: ProcessInfo.processInfo.systemUptime))
                        let maxRetirements = connectivityGrant ? 1 : LinkSubmissionState.maximumOutstandingFiles
                        var retirements = 0
                        let candidates = try transport.stalledFileAttempts(
                            maximumValidationBytes: maximumBytes,
                            allowAudioBlockRecovery: audioBlockRecoveryAvailable,
                            allowInteractiveFastPath: interactiveFastPath)
                        for (attempt, envelope) in candidates {
                            let valid = try await store.originalAvailableForTransferRetry(envelope,
                                maximumValidationBytes: maximumBytes)
                            guard !macLink.ownsRoute, grantID == startingGrant else { return }
                            // Its SDK copy may be the last healthy copy. Keep it and inspect the next original.
                            guard valid else { continue }
                            try transport.retireStalledFileAttempt(
                                attempt,
                                allowAudioBlockRecovery: audioBlockRecoveryAvailable,
                                allowInteractiveFastPath: interactiveFastPath)
                            retirements += 1
                            if retirements == maxRetirements { break }
                        }
                    }
                }
                // A processed response can outlive a failed platform stop; its durable deletion remains pending.
                guard !macLink.ownsRoute, grantID == startingGrant else { return }
                if connectivityGrant {
                    // No archive-wide JSON decoding, hashing or bulk file removal under a WC grant.
                    if !grantCleaned {
                        let cleaned = try await store.cleanupAcknowledgedChunks(limit: 1)
                        if !cleaned.isEmpty { grantCleaned = true }
                    }
                    pendingChunkCount = try await store.pendingChunkCount()
                } else {
                    for deletion in try await store.pendingDeletions() where deletion.libraryInstanceID != nil { try await applyDeletion(deletion) }
                    _ = try await store.cleanupAcknowledgedChunks()
                    let summary = try await store.queueSummary(sessionID: sessionID)
                    if summary.pendingChunkCount < pendingChunkCount { resetAutomaticRecovery() }
                    pendingChunkCount = summary.pendingChunkCount
                    pendingDuration = summary.pendingDuration
                    pendingBytes = summary.pendingBytes
                    sealedSeconds = summary.sealedDuration
                    widgetHasQueueObservation = true
                }
                guard !Task.isCancelled else { return }
                let pendingControls = try await store.hasPendingControlMessages()
                pendingLocalSyncWork = try controls.hasPending() || pendingControls
                checkedLocalWork = true
                guard !macLink.ownsRoute, grantID == startingGrant else { return }
                if linkActivated, pendingReceiver == nil, !connectivityGrant || !grantSubmitted {
                    if connectivityGrant { grantSubmitted = true }
                    if !connectivityGrant, transport.isReachable, phoneStatus == nil, pendingChunkCount > 0 {
                        transport.requestPeerStatus()
                    }
                    let replay = try await store.pendingFileReplays()
                    transport.allowFileReplay(chunkIDs: replay)
                    if !replay.isEmpty {
                        try transport.refreshFileQueue()
                        var scheduled: [UUID] = []
                        for id in replay {
                            guard !macLink.ownsRoute, grantID == startingGrant else { return }
                            guard let chunk = try await store.chunk(id: id), chunk.state == .ready else {
                                scheduled.append(id)
                                continue
                            }
                            let result = try transport.transferFileResult(
                                at: chunk.audioURL,
                                envelope: chunk.envelope,
                                refreshQueue: false)
                            if result == .submitted || result == .alreadySubmitted {
                                scheduled.append(id)
                            }
                            if result == .deferred { break }
                        }
                        if !scheduled.isEmpty {
                            try await store.fileReplaysScheduled(scheduled)
                        }
                    }
                    // Hand sealed files to the OS even if the interactive channel goes away.
                    var fileSubmissionError: Error?
                    do {
                        try await submitFileBatch(maximumScanned: connectivityGrant ? 256 : 512)
                    } catch {
                        fileSubmissionError = error
                    }
                    guard !macLink.ownsRoute, grantID == startingGrant else { return }
                    try await submitControlBatch(maximumCount: connectivityGrant ? 4 : LinkControlBudget.maximumCount)
                    guard !macLink.ownsRoute, grantID == startingGrant else { return }
                    if !connectivityGrant {
                        startLocalBulkSyncIfPossible()
                        try await submitAudioBlockCopy()
                    }
                    if let fileSubmissionError { throw fileSubmissionError }
                }
                if pendingChunkCount == 0, !pendingLocalSyncWork, !transport.hasRetryableControls, !transport.hasRetryableFiles {
                    transportSyncFailure = nil
                }
                inboxSyncFailure = nextSyncFailure
                refreshSyncFailure()
                await publishStatus()
            } catch is CancellationError { return }
            catch {
                if connectivityGrant { grantStatusAttempted = true }
                inboxSyncFailure = String(localized: "录音同步未完成：\(error.localizedDescription)")
                refreshSyncFailure()
            }
        } while !macLink.ownsRoute && reconcileAgain && (!connectivityGrant || grantControlsRemaining > 0 || (linkActivated && (!grantSubmitted || !grantStatusAttempted))) && grantID == startingGrant
    }

    private func updateSynchronizationState() {
        guard !macLink.ownsRoute else { return }
        queuedFileCount = transport.outstandingFileCount
            + (transport.hasActiveAudioBlockTransfer ? 1 : 0)
            + localSyncInFlightChunkIDs.count
        if pendingReceiver != nil { synchronizationState = .receiverConfirmation }
        else if !linkActivated || transport.peerState != .available { synchronizationState = .waitingForConnection }
        else if queuedFileCount > 0 { synchronizationState = .transferring }
        else if syncFailure != nil || transport.hasRetryableControls || transport.hasRetryableFiles { synchronizationState = .retrying }
        else if waitingForAudioBatch, pendingChunkCount > 0 { synchronizationState = .waitingForBatch }
        else if pendingChunkCount > 0 { synchronizationState = .awaitingConfirmation }
        else { synchronizationState = .caughtUp }
    }

    private func submitControlBatch(maximumCount: Int = LinkControlBudget.maximumCount) async throws {
        guard maximumCount > 0 else { return }
        let startingGrant = grantID
        var budget = LinkControlBudget()
        let receiver = try await store.boundReceiver()
        var channelDeferred = false
        let startingRound = try await store.reconciliationRoundIsComplete()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let roundInterval: TimeInterval = transport.isReachable ? 30 : 120
        if pendingChunkCount > 0, nowUptime - lastReconciliationRoundAt >= roundInterval {
            reconciliationRequested = true
            replayReconciliationRequest = true
            if !startingRound {
                lastReconciliationRoundAt = nowUptime
            }
        }
        let admittedThrough = try await admitAudioBatch()
        if let request = try await store.nextReconciliationRequest(
            sourceDeviceID: sourceDeviceID,
            beginNewRound: reconciliationRequested,
            through: admittedThrough,
            preferPending: true,
            allowHistoricalAudit: pendingChunkCount == 0) {
            guard !macLink.ownsRoute, grantID == startingGrant else { return }
            if startingRound {
                reconciliationRequested = false
                lastReconciliationRoundAt = nowUptime
            }
            let message = ControlMessage.reconcileRequest(request)
            if replayReconciliationRequest {
                try transport.allowControlReplay(message)
            }
            let routes = try transport.transferControlRoutes(message)
            if routes.background == .deferred && routes.interactive != .submitted && routes.interactive != .alreadySubmitted {
                channelDeferred = true
            } else {
                replayReconciliationRequest = false
                if routes.background == .submitted || routes.interactive == .submitted {
                    _ = try budget.include(message)
                }
            }
        } else if reconciliationRequested && !startingRound {
            // Skipping deleted tail rows can finish the old round without starting the requested fresh one.
            reconcileAgain = true
        } else {
            reconciliationRequested = false
        }
        guard !channelDeferred, budget.count < maximumCount else { return }
        let rewindDueRetries = transport.hasDueControlRetries
        if rewindDueRetries { controlCursors.removeAll() }
        // Prioritize deletions and capture boundaries ahead of per-receipt acknowledgements.
        for kind in [RecordingControlKind.deletion, .capture, .receipt] {
            try Task.checkCancellation()
            let position: Int64
            if rewindDueRetries { position = 0 }
            else if let saved = controlCursors[kind] { position = saved }
            else { position = try await store.controlPosition(kind: kind) }
            let count = connectivityGrant ? 1 : min(8, maximumCount - budget.count)
            guard count > 0 else { break }
            let entries = try await store.controlBatch(kind: kind, after: position, limit: count)
            guard !macLink.ownsRoute, grantID == startingGrant else { return }
            if entries.isEmpty {
                if position != 0 {
                    controlCursors[kind] = 0
                    try await store.saveControlPosition(0, kind: kind)
                }
                continue
            }
            var nextCursor = position
            var submittedInKind = false
            var exhaustedEntries = true
            for entry in entries {
                if let receiver { controlReceivers[entry.message.messageID] = receiver }
                guard !macLink.ownsRoute, grantID == startingGrant else { return }
                let routes = try transport.transferControlRoutes(entry.message)
                if routes.background == .deferred && routes.interactive != .submitted && routes.interactive != .alreadySubmitted {
                    channelDeferred = true
                    exhaustedEntries = false
                    break
                }
                if routes.background == .submitted || routes.interactive == .submitted {
                    guard try budget.include(entry.message) else {
                        exhaustedEntries = false
                        break
                    }
                    submittedInKind = true
                }
                nextCursor = entry.sequence
            }
            if nextCursor != position {
                controlCursors[kind] = nextCursor
                try await store.saveControlPosition(nextCursor, kind: kind)
            }
            if channelDeferred { break }
            if !connectivityGrant, entries.count == count, exhaustedEntries, submittedInKind {
                reconcileAgain = true
            }
        }
    }

    private func admitAudioBatch() async throws -> Int64 {
        let hasLocalSyncEndpoint: Bool = {
            guard case .phone(let payload) = phoneStatus?.payload else { return false }
            return payload.localSync != nil
        }()
        let interactiveFlush = !connectivityGrant
            && (transport.isReachable || presentationActive || statusBudget.isPeerViewing(now: ProcessInfo.processInfo.systemUptime) || hasLocalSyncEndpoint)
        let flush = flushAudioBatch || interactiveFlush
        flushAudioBatch = false
        do {
            let end = try await store.audioTransferBatchEnd(force: flush)
            let ready = try await store.pendingChunkBatch(after: 0, through: end, limit: 1)
            waitingForAudioBatch = pendingChunkCount > 0 && ready.isEmpty
            audioBatchRetryDelay = waitingForAudioBatch ? try await store.nextAudioBatchDelay() : nil
            return end
        }
        catch { flushAudioBatch = flushAudioBatch || flush; throw error }
    }

    private func submitFileBatch(maximumScanned: Int = 512) async throws {
        let startingGrant = grantID
        let admittedThrough = try await admitAudioBatch()
        if !fileCursorLoaded {
            fileCursor = try await store.fileTransferPosition()
            fileCursorLoaded = true
        }
        try transport.refreshFileQueue()
        let startingCursor = fileCursor
        let pageSize = connectivityGrant ? 16 : 32
        guard let outcome = try await scanFileBatch(
            after: startingCursor,
            maximumScanned: maximumScanned,
            pageSize: pageSize,
            hasDueRetries: {
                let due = transport.hasDueFileRetries || needsPostActivationWrap
                needsPostActivationWrap = false
                return due
            },
            sequenceOf: \.sequence,
            loadPage: { cursor in
                let entries = try await store.pendingChunkPage(after: cursor, through: admittedThrough, limit: pageSize)
                return grantID == startingGrant ? entries : nil
            },
            submit: { entry in
                guard !macLink.ownsRoute, grantID == startingGrant else { return nil }
                let id = entry.chunk.envelope.manifest.chunkID
                if transport.activeAudioBlockChunk == id || localSyncInFlightChunkIDs.contains(id) {
                    return .alreadySubmitted
                }
                let result = try transport.transferFileResult(
                    at: entry.chunk.audioURL,
                    envelope: entry.chunk.envelope,
                    refreshQueue: false)
                if result == .submitted {
                    try await store.fileReplaysScheduled([id])
                }
                return result
            }
        ) else { return }
        fileCursor = outcome.cursor
        if fileCursor != startingCursor {
            try await store.saveFileTransferPosition(fileCursor)
        }
        if outcome.scanned == maximumScanned, !outcome.deferred,
           outcome.submittedAny || (!outcome.wrapped && transport.outstandingFileCount < LinkSubmissionState.bulkMaximumOutstandingFiles) {
            reconcileAgain = true
        }
    }

    private func submitAudioBlockCopy() async throws {
        guard !macLink.ownsRoute else { return }
        guard localSyncInFlightChunkIDs.isEmpty,
              transport.canTransferAudioBlocks,
              let receiver = try await store.boundReceiver(),
              let status = phoneStatus, status.sourceDeviceID == receiver.deviceID,
              case .phone(let payload) = status.payload, payload.libraryInstanceID == receiver.libraryInstanceID,
              payload.audioBlockVersion == AudioBlock.version else { return }
        var orderedCandidates: [(id: UUID, sequence: Int64?)] = []
        var seen = Set<UUID>()
        func appendCandidate(_ id: UUID, sequence: Int64? = nil) {
            if !invalidAudioBlockSources.contains(id), seen.insert(id).inserted {
                orderedCandidates.append((id, sequence))
            }
        }
        if let resumable = transport.resumableAudioBlockChunk {
            appendCandidate(resumable)
        }
        for id in try transport.audioBlockRecoveryCandidates() {
            appendCandidate(id)
        }
        if orderedCandidates.count < LinkSubmissionState.maximumOutstandingFiles {
            let admittedThrough = try await admitAudioBatch()
            var cursor: Int64 = 0
            var pages = 0
            let pageSize = 32
            while pages < 8, orderedCandidates.count < LinkSubmissionState.maximumOutstandingFiles {
                pages += 1
                let batch = try await store.pendingChunkPage(
                    after: cursor,
                    through: admittedThrough,
                    limit: pageSize)
                if batch.isEmpty { break }
                for entry in batch {
                    cursor = entry.sequence
                    let id = entry.chunk.envelope.manifest.chunkID
                    guard !localSyncInFlightChunkIDs.contains(id),
                          !invalidAudioBlockSources.contains(id) else { continue }
                    appendCandidate(id, sequence: entry.sequence)
                    if orderedCandidates.count >= LinkSubmissionState.maximumOutstandingFiles { break }
                }
                if batch.count < pageSize { break }
            }
        }
        for candidate in orderedCandidates {
            guard let chunk = try await store.chunk(id: candidate.id), chunk.state == .ready else { continue }
            guard try await store.originalAvailableForTransferRetry(
                chunk.envelope,
                maximumValidationBytes: AudioBlock.maximumFileBytes) else {
                invalidAudioBlockSources.insert(candidate.id)
                continue
            }
            if try transport.transferAudioBlocks(at: chunk.audioURL, envelope: chunk.envelope,
                receiverDeviceID: receiver.deviceID, libraryInstanceID: receiver.libraryInstanceID,
                binaryFraming: payload.binaryAudioBlocks == true) {
                if let sequence = candidate.sequence { audioBlockCursor = sequence }
                return
            }
        }
    }

    private func startLocalBulkSyncIfPossible() {
        guard !macLink.ownsRoute, !connectivityGrant,
              pendingReceiver == nil,
              localBulkSyncTask == nil,
              ProcessInfo.processInfo.systemUptime >= localSyncRetryAt,
              let status = phoneStatus,
              case .phone(let payload) = status.payload,
              let endpoint = payload.localSync,
              (pendingChunkCount > 0 || pendingLocalSyncWork || payload.pendingReceiptCount > 0) else {
            return
        }
        let expectedDeviceID = status.sourceDeviceID
        localBulkSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.localSyncInFlightChunkIDs.removeAll()
                self.localBulkSyncTask = nil
                self.updateSynchronizationState()
            }
            await self.runLocalBulkSync(endpoint: endpoint, expectedDeviceID: expectedDeviceID, expectedLibraryID: payload.libraryInstanceID)
        }
    }

    private func runLocalBulkSync(
        endpoint: LocalSyncEndpoint,
        expectedDeviceID: UUID,
        expectedLibraryID: UUID
    ) async {
        guard let bound = try? await store.boundReceiver(),
              bound.deviceID == expectedDeviceID,
              bound.libraryInstanceID == expectedLibraryID else {
            return
        }
        do {
            guard try await store.hasLocalSyncPayload(excluding: invalidAudioBlockSources) else { return }
        } catch is CancellationError { return }
        catch {
            // A failed preflight must still let the sender try audio and receipts independently.
            logger.error("Local sync queue check failed: \(error.localizedDescription, privacy: .private)")
        }
        guard !Task.isCancelled, !macLink.ownsRoute, !connectivityGrant, pendingReceiver == nil else { return }
        let client = localSyncClient
        guard let route = await client.probe(
            endpoint: endpoint,
            expectedReceiverDeviceID: expectedDeviceID,
            expectedLibraryInstanceID: expectedLibraryID
        ) else {
            localSyncRetryAt = ProcessInfo.processInfo.systemUptime + 12
            if pendingChunkCount > 0 {
                if transport.isReachable {
                    transport.requestPeerStatus()
                }
                reconciliationRequested = true
                replayReconciliationRequest = true
                await reconcile()
            }
            return
        }
        logger.notice("Local bulk sync connected via \(route.transport.rawValue, privacy: .public)")
        localSyncRetryAt = 0
        var cursor: Int64 = 0
        var encounteredNetworkError = false

        while !Task.isCancelled, !macLink.ownsRoute, !connectivityGrant, pendingReceiver == nil {
            let admittedThrough: Int64
            do {
                admittedThrough = try await store.audioTransferBatchEnd(force: true)
            } catch {
                break
            }
            let page: [RecordingChunkEntry]
            do {
                page = try await store.pendingChunkPage(after: cursor, through: admittedThrough, limit: 16)
            } catch {
                break
            }
            guard let last = page.last else { break }
            cursor = last.sequence
            await uploadLocalBulkPage(page, route: route, receiver: bound, networkFailed: &encounteredNetworkError)
            if encounteredNetworkError { break }
        }

        if !encounteredNetworkError, !Task.isCancelled {
            await flushLocalReceiptsApplied(route: route, receiver: bound)
        }
        if encounteredNetworkError {
            localSyncRetryAt = ProcessInfo.processInfo.systemUptime + 10
        }
        await reconcile()
    }

    private func uploadLocalBulkPage(
        _ page: [RecordingChunkEntry],
        route: LocalSyncRoute,
        receiver: (deviceID: UUID, libraryInstanceID: UUID),
        networkFailed: inout Bool
    ) async {
        let client = localSyncClient
        var appliedItems: [ReceiptApplied] = []
        for entry in page {
            guard !Task.isCancelled, !macLink.ownsRoute, !connectivityGrant, pendingReceiver == nil else { break }
            let chunk = entry.chunk
            let chunkID = chunk.envelope.manifest.chunkID
            guard !invalidAudioBlockSources.contains(chunkID) else { continue }

            // Reserve only the active upload. Other files can use WatchConnectivity.
            localSyncInFlightChunkIDs.insert(chunkID)
            updateSynchronizationState()
            defer { localSyncInFlightChunkIDs.remove(chunkID) }
            let receipt: Receipt
            do {
                receipt = try await client.uploadChunk(route: route, envelope: chunk.envelope, audioURL: chunk.audioURL)
            } catch LocalSyncError.invalidSource {
                invalidAudioBlockSources.insert(chunkID)
                _ = try? await store.originalAvailableForTransferRetry(chunk.envelope, maximumValidationBytes: Int64.max)
                continue
            } catch {
                networkFailed = true
                break
            }
            do {
                guard !Task.isCancelled, !macLink.ownsRoute else { break }
                let applied = try await store.applyReceipt(receipt)
                invalidAudioBlockSources.remove(chunkID)
                try? transport.confirmFileDelivery(applied.receipt)
                appliedItems.append(applied)
            } catch {
                reconciliationRequested = true
            }
        }
        updateSynchronizationState()

        if !appliedItems.isEmpty {
            if !networkFailed, !Task.isCancelled, !connectivityGrant,
               (try? await client.sendReceiptsApplied(route: route, items: appliedItems)) != nil {
                for item in appliedItems {
                    try? await store.markControlPreserved(
                        .receiptApplied(item),
                        receiverDeviceID: receiver.deviceID,
                        libraryInstanceID: receiver.libraryInstanceID)
                }
            }
            _ = try? await store.cleanupAcknowledgedChunks()
            if let summary = try? await store.queueSummary(sessionID: sessionID) {
                if summary.pendingChunkCount < pendingChunkCount { resetAutomaticRecovery() }
                pendingChunkCount = summary.pendingChunkCount
                pendingDuration = summary.pendingDuration
                pendingBytes = summary.pendingBytes
                sealedSeconds = summary.sealedDuration
                widgetHasQueueObservation = true
                statusDirty = true
                requestStatusPublication()
            }
        }
    }

    private func flushLocalReceiptsApplied(
        route: LocalSyncRoute,
        receiver: (deviceID: UUID, libraryInstanceID: UUID)
    ) async {
        let client = localSyncClient
        var cursor: Int64 = 0
        for _ in 0..<128 {
            guard !Task.isCancelled else { return }
            guard let entries = try? await store.controlBatch(kind: .receipt, after: cursor, limit: 32),
                  !entries.isEmpty else {
                return
            }
            var batch: [ReceiptApplied] = []
            for entry in entries {
                cursor = entry.sequence
                if case .receiptApplied(let applied) = entry.message {
                    batch.append(applied)
                }
            }
            guard !batch.isEmpty else { continue }
            guard (try? await client.sendReceiptsApplied(route: route, items: batch)) != nil else {
                return
            }
            for item in batch {
                try? await store.markControlPreserved(
                    .receiptApplied(item),
                    receiverDeviceID: receiver.deviceID,
                    libraryInstanceID: receiver.libraryInstanceID)
            }
        }
    }

    /// Replaceable observations cannot backpressure the encoder or diagnostic persistence.
    private func requestStatusPublication(force: Bool = false) {
        guard !connectivityGrant else { return }
        publishWidgetStatus() // Local complications must remain independent of phone delivery/backoff.
        if macLink.ownsRoute {
            if force { macLink.wake() } else { macLink.observeCapture() }
            return
        }
        if publishingStatus {
            if force { statusPublicationRequested = true }
            return
        }
        queuedStatusForce = queuedStatusForce || force
        guard captureReady, linkActivated,
              statusBudget.isDue(now: ProcessInfo.processInfo.systemUptime, urgent: queuedStatusForce || statusDirty),
              statusPublicationTask == nil else { return }
        statusPublicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.statusPublicationTask = nil }
            repeat {
                let force = self.queuedStatusForce
                self.queuedStatusForce = false
                await self.publishStatus(force: force)
            } while self.queuedStatusForce && !Task.isCancelled
        }
    }

    private func publishStatus(force: Bool = false) async {
        guard !macLink.ownsRoute else { return }
        if connectivityGrant { guard !grantStatusAttempted else { return } }
        else { publishWidgetStatus() }
        let now = ProcessInfo.processInfo.systemUptime
        guard captureReady || connectivityGrant, linkActivated else { return }
        if publishingStatus {
            if force || connectivityGrant { statusPublicationRequested = true }
            return
        }
        statusDirty = statusDirty || force
        guard statusBudget.isDue(now: now, urgent: connectivityGrant || statusDirty) else {
            if connectivityGrant { grantStatusAttempted = true }
            return
        }
        publishingStatus = true
        defer { publishingStatus = false }
        var currentForce = force
        repeat {
            let loopUptime = ProcessInfo.processInfo.systemUptime
            let shouldRefresh = currentForce || statusDirty || connectivityGrant
                || statusBudget.isPeerViewing(now: loopUptime) || statusPublicationRequested
            currentForce = false
            statusPublicationRequested = false
            statusDirty = false
            if !shouldRefresh, !presentationActive, epochID != nil,
               let previous = lastPublishedStatusSnapshot,
               case .watch(let prevStatus) = previous.payload,
               prevStatus.sessionID == sessionID,
               prevStatus.epochID == epochID,
               prevStatus.activity == observedCaptureActivity,
               prevStatus.pendingChunkCount == pendingChunkCount,
               prevStatus.pendingBytes == pendingBytes,
               loopUptime - lastPassiveRecordingStatusAt < 300 {
                statusBudget.beganAttempt(now: loopUptime)
                statusBudget.succeeded()
                continue
            }
            statusBudget.beganAttempt(now: loopUptime)
            do {
                let startingGrant = grantID
                let bindingGeneration = statusBindingGeneration
                if connectivityGrant { grantStatusAttempted = true }
                let snapshot = try await statusSnapshot(refreshObservation: shouldRefresh || epochID != nil)
                guard !macLink.ownsRoute, startingGrant == grantID, !Task.isCancelled else { return }
                if !shouldRefresh, snapshot == lastPublishedStatusSnapshot {
                    statusBudget.succeeded()
                    continue
                }
                energyCounters.statusPublications += 1
                try await statusPublisher(snapshot)
                lastPublishedStatusSnapshot = snapshot
                if epochID != nil { lastPassiveRecordingStatusAt = loopUptime }
                if connectivityGrant, startingGrant == grantID, bindingGeneration == statusBindingGeneration { grantStatusPublished = true }
                statusBudget.succeeded()
            } catch {
                statusDirty = true
                statusBudget.failed(now: ProcessInfo.processInfo.systemUptime)
                let failure = TransportFailure(error)
                if !WatchConnectivityTransport.isTransientChannelFailure(failure) {
                    transportSyncFailure = String(localized: "状态摘要尚未同步：\(error.localizedDescription)")
                    refreshSyncFailure()
                }
                scheduleAutomaticRecovery()
            }
        } while statusPublicationRequested && statusBudget.isDue(now: ProcessInfo.processInfo.systemUptime, urgent: true) && (!connectivityGrant || !grantStatusAttempted) && linkActivated && !Task.isCancelled
    }

    func requestedStatusSnapshot(viewing: Bool = false) async throws -> StatusSnapshot {
        guard !macLink.ownsRoute else { throw WatchRuntimeError.unexpectedControlMessage }
        energyCounters.statusRequests += 1
        let beganViewing = statusBudget.peerRequestedStatus(now: ProcessInfo.processInfo.systemUptime, viewing: viewing)
        if beganViewing || (viewing && waitingForAudioBatch) {
            requestReconciliation(flushAudio: true)
        }
        return try await statusSnapshot(refreshObservation: true)
    }

    func statusSnapshot(refreshObservation: Bool = true) async throws -> StatusSnapshot {
        if !captureReady { return try await store.coldStatus(sourceDeviceID: sourceDeviceID, sourceBuild: sourceBuild) }
        let receiver = try await store.boundReceiver()
        let sampledAtUptime = ProcessInfo.processInfo.systemUptime
        let sampleUptime = observedSampleUptime
        let sampled = epochID != nil && sampleUptime != nil
        let payload = try WatchCaptureStatus(receiverLibraryInstanceID: receiver?.libraryInstanceID,
            sessionID: sessionID, epochID: epochID, activity: observedCaptureActivity,
            capturedDuration: sessionID == nil ? 0 : max(elapsedSeconds, sealedSeconds),
            sealedDuration: sessionID == nil ? 0 : sealedSeconds, pendingChunkCount: pendingChunkCount, pendingBytes: pendingBytes,
            lastSampleFrame: sampled ? observedFrames : nil, timebaseHz: sampled ? 16_000 : nil,
            lastSampleAge: sampled ? sampleUptime.map { max(0, sampledAtUptime - $0) } : nil,
            audioBatchVersion: 1)
        return try await store.saveStatus(sourceDeviceID: sourceDeviceID, sourceBuild: sourceBuild, payload: payload,
            refreshObservation: refreshObservation)
    }

    private var observedCaptureActivity: WatchCaptureActivity {
        if !captureReady { return archiveState == .failed ? .failed : .preparing }
        if sessionID == nil { return .idle }
        if requiresStartTap, epochID == nil, captureState.activity == .interrupted { return .idle }
        return switch captureState.activity {
            case .idle: .idle
            case .starting: .preparing
            case .recording: .recording
            case .interrupted: .interrupted
            case .stopped: captureState.intent == .paused ? .paused : .stopped
            case .failed: .failed
        }
    }

    private func publishWidgetStatus() {
        guard let widgetPublisher else { return }
        let uptime = ProcessInfo.processInfo.systemUptime, date = Date()
        let sampleAt = epochID == nil ? nil : observedSampleUptime.map { date.addingTimeInterval(-max(0, uptime - $0)) }
        let snapshot = WatchWidgetSnapshot(runtimeID: diagnosticRunID, generation: captureState.generation,
            observedAt: date, sessionID: sessionID, activity: observedCaptureActivity,
            capturedDuration: sessionID == nil ? 0 : max(elapsedSeconds, sealedSeconds),
            pendingChunkCount: widgetHasQueueObservation ? pendingChunkCount : nil,
            lastSampleAt: sampleAt, revision: widgetRevision + 1)
        // Heartbeats reuse capture callbacks; no widget timer, waveform, or phone connection is needed.
        let elapsed = uptime - lastWidgetPublication
        let captureChanged = lastWidgetSnapshot.map({ !snapshot.hasSameCaptureState(as: $0) }) ?? true
        let queueChanged = lastWidgetSnapshot?.pendingChunkCount != snapshot.pendingChunkCount
        let queueDue = queueChanged && (lastWidgetSnapshot?.pendingChunkCount == nil || elapsed >= 10 || snapshot.pendingChunkCount == 0)
        guard captureChanged || queueDue || elapsed >= 120 else { return }
        widgetRevision += 1
        lastWidgetSnapshot = snapshot
        lastWidgetPublication = uptime
        // Snapshot I/O must not hold up the encoder's progress callback or its bounded PCM queue.
        Task { await widgetPublisher(snapshot) }
    }

    private func recordEnergyIfDue(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEnergySampleAt >= CaptureEnergyLog.interval else { return }
        lastEnergySampleAt = now
        var usage = rusage()
        let cpu: Double? = getrusage(RUSAGE_SELF, &usage) == 0
            ? Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000 : nil
        let device = WKInterfaceDevice.current(), tap = engine.healthSnapshot
        let battery = device.batteryLevel
        let sample = CaptureEnergySample(runID: diagnosticRunID, build: sourceBuild, uptime: now,
            cpuSeconds: cpu, batteryLevel: battery >= 0 ? battery : nil,
            batteryState: device.batteryState.rawValue, thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            presentationSeconds: presentationSeconds + (presentationBeganAt.map { max(0, now - $0) } ?? 0),
            activity: captureState.activity, generation: captureState.generation,
            capturedFrames: observedFrames, tapBlocks: tap.receivedBlocks, droppedBlocks: tap.droppedBlocks,
            pendingChunks: pendingChunkCount, outstandingFiles: transport.outstandingFileCount, counters: energyCounters)
        let log = energyLog, logger = logger
        Task(priority: .utility) {
            do { try await log.append(sample) }
            catch { logger.error("Energy diagnostic write failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func acceptPhoneStatus(deviceID: UUID, libraryInstanceID: UUID) {
        statusBindingGeneration &+= 1
        grantStatusPublished = false
        grantStatusAttempted = false
        phoneStatuses.bind(deviceID: deviceID, libraryInstanceID: libraryInstanceID)
        phoneStatus = phoneStatuses.boundStatus
    }

    private static func controlPriority(_ message: ControlMessage) -> Int {
        switch message {
        case .deleteSession: 0
        case .receiverIdentity: 1
        default: 2
        }
    }

    private func applyDeletion(_ deletion: DeleteSession) async throws {
        guard !macLink.ownsRoute else { return }
        try await store.validateDeletionReceiver(deletion)
        guard !macLink.ownsRoute else { return }
        try await store.prepareDeletion(deletion, deviceID: sourceDeviceID)
        guard !macLink.ownsRoute else { return }
        try transport.cancelTransfers(sessionID: deletion.sessionID)
        if sessionID == deletion.sessionID {
            captureState.stop()
            captureRecovery.cancel()
            try await finishEpoch(reason: .stopped, deletingSession: deletion.sessionID)
            sessionID = nil
        }
        // The deletion and capture stop are durable; bulk file cleanup can wait for foreground recovery.
        guard !connectivityGrant else { return }
        let scratch = encoderDirectory.appendingPathComponent(deletion.sessionID.uuidString)
        if FileManager.default.fileExists(atPath: scratch.path) { try FileManager.default.removeItem(at: scratch) }
        try CaptureSpool.removeConfirmedRepairFiles(sessionID: deletion.sessionID, directory: encoderDirectory)
        _ = try await store.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
        // Earlier deletion rows can finish after later rows; replay their stable IDs safely.
        controlCursors[.deletion] = 0
    }
}
