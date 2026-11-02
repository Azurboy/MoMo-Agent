import Foundation
import Observation
import MoMoArchive
import MoMoContracts
import MoMoRecording

enum EarphoneCaptureStatus: Equatable {
    case off, starting, recording, otherAudioPlaying, headsetUnavailable, interrupted
    case failed(String)
}

/// Continuous capture through a Bluetooth earphone. Only earphone (HFP) audio is saved: while another
/// app plays audio, or the earphone is gone, the built-in microphone runs unsaved so the background
/// audio session survives and capture can resume without the app returning to the foreground.
@MainActor @Observable
final class EarphoneCaptureRuntime {
    private static let pollInterval: TimeInterval = 0.25
    private static let latePoll: TimeInterval = 0.5
    /// Pauses shorter than this, such as a track change, do not switch the earphone to HFP.
    private static let quietDelay: TimeInterval = 1
    /// A failed switch retries after 1 s, then backs off up to a minute, so a stuck route is not churned.
    private static let retryDelays: [TimeInterval] = [1, 3, 6, 12, 24, 48, 60]
    /// A switch can fail once while the earphone is still changing profile, for example when playback
    /// starts right after HFP comes up. Only repeated failures are shown as an error.
    private static let failuresBeforeError = 3

    private enum Target: Equatable { case headset, standby(EarphoneCaptureStatus) }

    private struct Epoch {
        let sessionID: UUID
        let id: UUID
        let worker: Task<Int64, any Error>
    }

    let settings: CaptureDeviceSettings
    private(set) var status: EarphoneCaptureStatus = .off
    private(set) var headsetName: String?
    /// Saved earphone audio in the current recording session.
    private(set) var savedSeconds: TimeInterval = 0
    private(set) var deliveryFailure: String?
    var isActive: Bool { sessionID != nil }
    @ObservationIgnored var onWillClaimAudioSession: (@MainActor () async -> Void)?
    @ObservationIgnored var onDelivered: (@MainActor ([UUID]) async -> Void)?

    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private let delivery: EarphoneLocalDelivery
    @ObservationIgnored private let route = EarphoneAudioRoute()
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let sourceBuild: String
    @ObservationIgnored private let encoderDirectory: URL
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var engine: AudioCaptureEngine?
    @ObservationIgnored private var keepAliveDrain: Task<Void, Never>?
    @ObservationIgnored private var epoch: Epoch?
    @ObservationIgnored private var epochFrames: Int64 = 0
    @ObservationIgnored private var sealedSeconds: TimeInterval = 0
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var retryAfter: TimeInterval = 0
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private let log: EarphoneCaptureLog
    @ObservationIgnored private var lastOtherAudio: TimeInterval = -.infinity
    @ObservationIgnored private var otherAudioSeen = false
    @ObservationIgnored private var lastPoll: TimeInterval?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var pendingOperations = 0
    @ObservationIgnored private var yielded = false
    @ObservationIgnored private var delivering = false
    @ObservationIgnored private var deliveryRequested = false

    init(store: RecordingStore, archive: ArchiveStore, deviceID: UUID, sourceBuild: String,
         directory: URL, settings: CaptureDeviceSettings) {
        self.store = store
        self.deviceID = deviceID
        self.sourceBuild = sourceBuild
        self.settings = settings
        encoderDirectory = directory.appendingPathComponent("Encoding", isDirectory: true)
        log = EarphoneCaptureLog(directory: directory)
        delivery = EarphoneLocalDelivery(store: store, archive: archive, deviceID: deviceID,
                                         stagingURL: directory.appendingPathComponent("Staging", isDirectory: true))
        route.onEvent = { [weak self] event in self?.handle(event) }
        route.onHint = { [weak self] in self?.evaluate(trigger: "hint") }
    }

    // MARK: Lifecycle

    /// iOS only lets an app start recording in the foreground, so automatic start happens here.
    func foreground() async {
        await prepare()
        headsetName = route.connectedHeadsetName
        guard settings.device == .earphone, !settings.earphoneStoppedByUser else { return }
        if sessionID == nil { await begin() }
        else {
            // An interruption is not guaranteed to deliver its end; returning to the app retries.
            if route.gate.interruptionActive {
                route.resetInterruption()
                target = nil
            }
            evaluate(trigger: "foreground")
        }
        requestDelivery()
    }

    func start() async {
        settings.setEarphoneStoppedByUser(false)
        await prepare()
        await begin()
    }

    func stop() async {
        settings.setEarphoneStoppedByUser(true)
        await end()
    }

    func select(_ device: CaptureDevice) async {
        settings.select(device)
        if device == .earphone { await start() } else { await end() }
    }

    /// A process exit leaves epochs open; record them as interrupted and deliver what was sealed.
    private func prepare() async {
        guard !prepared else { return }
        do {
            _ = try await store.recoverInterruptedEpochs()
            _ = try await store.recover()
            try await delivery.bindReceiver()
            prepared = true
        } catch {
            status = .failed(String(localized: "耳机录音记录恢复失败：\(error.localizedDescription)"))
            return
        }
        requestDelivery()
    }

    private func begin() async {
        guard prepared, sessionID == nil else { return }
        status = .starting
        await onWillClaimAudioSession?()
        do {
            try await route.requestPermission()
            let id = UUID()
            try await store.saveIntent(.recording, sessionID: id)
            sessionID = id
        } catch {
            status = .failed(Self.describe(error))
            return
        }
        sealedSeconds = 0; savedSeconds = 0; target = nil; retryAfter = 0; consecutiveFailures = 0
        lastPoll = nil; otherAudioSeen = false
        log.record("start", ["route": route.routeDescription])
        poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate(trigger: "start")
    }

    private func end() async {
        guard let sessionID else { return }
        poll?.invalidate(); poll = nil
        log.record("stop")
        await perform(waiting: { [self] in
            await finishEpoch(reason: .stopped)
            stopEngine()
            target = nil
            self.sessionID = nil
            status = .off
            do {
                try await store.saveIntent(.stopped, sessionID: sessionID)
                try await route.deactivate()
            } catch { status = .failed(String(localized: "停止耳机录音时出错：\(error.localizedDescription)")) }
        })
        requestDelivery()
    }

    // MARK: In-app audio

    /// Recording playback and chat dictation reconfigure the shared session; capture steps aside until they end.
    /// Idempotent, because one playback may activate the session once per part.
    func yieldAudioSession() async {
        guard !yielded else { return }
        yielded = true
        guard sessionID != nil else { return }
        await perform(waiting: { [self] in
            await finishEpoch(reason: .paused)
            stopEngine()
            target = nil
        })
    }

    func reclaimAudioSession() {
        guard yielded else { return }
        yielded = false
        evaluate(trigger: "reclaim")
    }

    // MARK: Switching

    /// Polled while recording. Decides the target; switches run one at a time through `perform`.
    private func evaluate(trigger: String = "poll") {
        guard sessionID != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Other audio plays at call quality until it is noticed, so a late poll is worth recording.
        if trigger == "poll" {
            if let lastPoll, now - lastPoll > Self.latePoll {
                log.record("poll.late", ["gapMs": "\(Int((now - lastPoll) * 1000))"])
            }
            lastPoll = now
        }
        let otherAudio = route.otherAudioPlaying
        if otherAudio { lastOtherAudio = now }
        if otherAudio != otherAudioSeen {
            otherAudioSeen = otherAudio
            log.record(otherAudio ? "otherAudio.started" : "otherAudio.stopped",
                       ["trigger": trigger, "busy": "\(pendingOperations > 0 || yielded)"])
        }
        guard !yielded, pendingOperations == 0 else { return }
        if route.gate.interruptionActive {
            status = .interrupted
            return
        }
        headsetName = route.connectedHeadsetName
        if target != nil, engine?.isRunning != true {
            // A route or configuration change stopped the engine without ending the stream.
            log.record("engine.stopped", ["route": route.routeDescription])
            perform { [self] in
                await finishEpoch(reason: .interrupted)
                stopEngine()
                target = nil
            }
            return
        }
        guard now >= retryAfter else { return }
        let desired: Target
        if now - lastOtherAudio < Self.quietDelay { desired = .standby(.otherAudioPlaying) }
        else if headsetName == nil { desired = .standby(.headsetUnavailable) }
        else { desired = .headset }
        guard desired != target else { return }
        perform { [self] in await apply(desired) }
    }

    private func apply(_ desired: Target) async {
        guard sessionID != nil else { return }
        if case .standby(let reason) = desired, case .standby = target, route.mode == .standby {
            target = desired; status = reason
            return
        }
        let began = ProcessInfo.processInfo.systemUptime
        log.record("switch.begin", ["to": "\(desired)", "route": route.routeDescription])
        // Input stops now; the encoder seals its last chunk while the route switches. Other audio
        // plays at call quality until A2DP returns, so the switch must not wait for the seal.
        let ending = endEpoch(reason: .paused)
        stopEngine()
        target = nil
        let standbyStatus: EarphoneCaptureStatus
        switch desired {
        case .standby(let reason): standbyStatus = reason
        case .headset:
            await ending?.value
            do {
                try await route.configure(.headset)
                try await launchEpoch()
                target = .headset; status = .recording
                consecutiveFailures = 0
                switched(to: desired, since: began)
                return
            } catch {
                stopEngine()
                scheduleRetry(after: error, to: desired)
                standbyStatus = error as? EarphoneRouteError == .headsetUnavailable
                    ? .headsetUnavailable : failureStatus(error, pending: .starting)
            }
        }
        // Standby, or a failed headset switch: keep an unsaved input alive so the app is not suspended.
        do {
            try await route.configure(.standby)
            try startKeepAlive()
            target = .standby(standbyStatus)
            status = standbyStatus
            switched(to: .standby(standbyStatus), since: began)
            // Every switch still finishes its epoch before the next operation runs.
            await ending?.value
        } catch {
            await ending?.value
            stopEngine()
            scheduleRetry(after: error, to: .standby(standbyStatus))
            status = failureStatus(error, pending: standbyStatus)
        }
    }

    /// Keeps showing the state being switched to until the failure has repeated.
    private func failureStatus(_ error: any Error, pending: EarphoneCaptureStatus) -> EarphoneCaptureStatus {
        consecutiveFailures < Self.failuresBeforeError ? pending : .failed(Self.describe(error))
    }

    private func switched(to target: Target, since began: TimeInterval) {
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
        log.record("switch.done", ["to": "\(target)", "ms": "\(elapsed)", "route": route.routeDescription])
    }

    private func scheduleRetry(after error: any Error, to target: Target) {
        let delay = Self.retryDelays[min(consecutiveFailures, Self.retryDelays.count - 1)]
        consecutiveFailures += 1
        retryAfter = ProcessInfo.processInfo.systemUptime + delay
        log.record("switch.failed", ["to": "\(target)", "error": EarphoneCaptureLog.describe(error),
                                     "retryIn": "\(Int(delay))", "route": route.routeDescription])
    }

    private func handle(_ event: EarphoneRouteEvent) {
        guard sessionID != nil else { return }
        log.record("audio.event", ["kind": "\(event)"])
        switch event {
        case .interruptionBegan: status = .interrupted
        case .interruptionEnded, .mediaServicesReset: break
        }
        perform { [self] in
            await finishEpoch(reason: .interrupted)
            stopEngine()
            target = nil
        }
    }

    /// Serializes every session and engine change; the poll skips while one is pending.
    private func perform(_ body: @escaping @MainActor () async -> Void) {
        let previous = operation
        pendingOperations += 1
        operation = Task { @MainActor [weak self] in
            await previous?.value
            await body()
            self?.pendingOperations -= 1
        }
    }

    private func perform(waiting body: @escaping @MainActor () async -> Void) async {
        perform(body)
        await operation?.value
    }

    // MARK: Capture

    private func launchEpoch() async throws {
        guard let sessionID else { throw CancellationError() }
        let epochID = UUID()
        try await store.beginEpoch(sessionID: sessionID, epochID: epochID, sourceDeviceID: deviceID)
        let engine = AudioCaptureEngine()
        let gate = route.gate
        let input: AudioCaptureInput
        do { input = try engine.start(inputAllowed: { gate.allowsInput() }) }
        catch {
            try await store.recordEpochInterruption(sessionID: sessionID, epochID: epochID,
                                                    sourceDeviceID: deviceID, reason: .failed)
            throw error
        }
        self.engine = engine
        epochFrames = 0
        let directory = encoderDirectory.appendingPathComponent(sessionID.uuidString).appendingPathComponent(epochID.uuidString)
        let store = store, device = deviceID, build = sourceBuild
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try await CaptureEncoder.run(input: input, directory: directory, sessionID: sessionID,
                                         epochID: epochID, sourceDeviceID: device, sourceBuild: build,
                                         sourceKind: .phone, store: store) { progress in
                // Never make the encoder wait for the main actor.
                Task { @MainActor in self?.received(progress, epochID: epochID) }
            }
        }
        epoch = Epoch(sessionID: sessionID, id: epochID, worker: worker)
        Task { @MainActor [weak self] in
            let result = await worker.result
            self?.workerFinished(result, epochID: epochID)
        }
    }

    private func received(_ progress: CaptureProgress, epochID: UUID) {
        guard epoch?.id == epochID else { return }
        epochFrames = max(epochFrames, progress.frames)
        savedSeconds = sealedSeconds + Double(epochFrames) / AACSegmentWriter.sampleRate
        if progress.sealedChunkID != nil { requestDelivery() }
    }

    /// The stream ended on its own: the earphone left, a call took the session, or encoding failed.
    private func workerFinished(_ result: Result<Int64, any Error>, epochID: UUID) {
        guard let epoch, epoch.id == epochID else { return }
        perform { [self] in
            guard self.epoch?.id == epochID else { return }
            self.epoch = nil
            stopEngine()
            target = nil
            await recordEnd(of: epoch, result: result, reason: .interrupted, observedFrames: epochFrames)
        }
    }

    private func finishEpoch(reason: CaptureEndReason) async {
        await endEpoch(reason: reason)?.value
    }

    /// Stops input at once; the returned task seals the last chunk and records the epoch end.
    private func endEpoch(reason: CaptureEndReason) -> Task<Void, Never>? {
        guard let epoch else { return nil }
        self.epoch = nil
        engine?.stop()
        let frames = epochFrames
        return Task { @MainActor [self] in
            let result = await epoch.worker.result
            await recordEnd(of: epoch, result: result, reason: reason, observedFrames: frames)
        }
    }

    private func recordEnd(of epoch: Epoch, result: Result<Int64, any Error>, reason: CaptureEndReason,
                           observedFrames: Int64) async {
        do {
            switch result {
            case .success(let frames):
                try await store.recordEpochEnded(CaptureEpochEnded(sessionID: epoch.sessionID, epochID: epoch.id,
                    sourceDeviceID: deviceID, endFrame: frames, reason: reason))
            case .failure(let error):
                if case RecordingError.deletedSession(let id) = error, id == epoch.sessionID { break }
                let routeEnded = error as? AudioCaptureError == .unexpectedInputRoute
                try await store.recordEpochInterruption(sessionID: epoch.sessionID, epochID: epoch.id,
                    sourceDeviceID: deviceID, lastObservedFrame: observedFrames, reason: routeEnded ? .interrupted : .failed)
                log.record("epoch.ended", ["error": EarphoneCaptureLog.describe(error), "frames": "\(observedFrames)"])
                if !routeEnded {
                    status = .failed(Self.describe(error))
                    scheduleRetry(after: error, to: .headset)
                }
            }
            sealedSeconds = try await store.sealedDuration(sessionID: epoch.sessionID)
            savedSeconds = sealedSeconds
        } catch RecordingError.deletedSession(let id) where id == epoch.sessionID {
        } catch { status = .failed(String(localized: "耳机录音结束记录未保存：\(error.localizedDescription)")) }
        requestDelivery()
    }

    private func startKeepAlive() throws {
        let engine = AudioCaptureEngine()
        let input = try engine.start()
        self.engine = engine
        // Samples are discarded by design. If the engine stops, the poll sees it and switches again.
        keepAliveDrain = Task.detached {
            do { for try await _ in input.blocks {} } catch {}
        }
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        keepAliveDrain = nil
    }

    // MARK: Delivery

    func requestDelivery() {
        deliveryRequested = true
        guard prepared, !delivering else { return }
        delivering = true
        Task { @MainActor in
            defer { delivering = false }
            while deliveryRequested {
                deliveryRequested = false
                do {
                    let result = try await delivery.deliver(capturingSessionID: sessionID)
                    deliveryFailure = nil
                    if let deleted = result.deletionAwaitingStop { restartSession(afterDeleting: deleted) }
                    if result.changed { await onDelivered?(result.chunkIDs) }
                } catch {
                    // The ledger keeps everything; the next sealed chunk or foreground retries.
                    deliveryFailure = String(localized: "耳机录音尚未存入资料库：\(error.localizedDescription)")
                    log.record("delivery.failed", ["error": EarphoneCaptureLog.describe(error)])
                    return
                }
            }
        }
    }

    /// Deleting the session being recorded stops it first, then recording continues in a new session.
    private func restartSession(afterDeleting deleted: UUID) {
        perform { [self] in
            guard sessionID == deleted else { return }
            await finishEpoch(reason: .stopped)
            stopEngine()
            target = nil
            let next = UUID()
            do {
                try await store.saveIntent(.recording, sessionID: next)
                sessionID = next
                sealedSeconds = 0; savedSeconds = 0
            } catch {
                sessionID = nil
                poll?.invalidate(); poll = nil
                status = .failed(Self.describe(error))
            }
            requestDelivery()
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
