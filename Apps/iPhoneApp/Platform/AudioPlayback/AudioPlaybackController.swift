import AVFoundation
import Observation
import OSLog
import MoMoArchive

@MainActor @Observable
final class AudioPlaybackController {
    private let logger = Logger(subsystem: "com.momoagent.ios", category: "playback")
    private(set) var snapshot: AudioPlaybackSnapshot? {
        didSet {
            if oldValue?.target != snapshot?.target { activeTarget = snapshot?.target }
            if oldValue?.state != snapshot?.state { playbackState = snapshot?.state }
        }
    }
    // Transcript rows observe transport changes, never the 25 Hz playback clock.
    private(set) var activeTarget: AudioPlaybackTarget?
    private(set) var playbackState: AudioPlaybackState?
    private(set) var failure: String?
    var playingSpanID: UUID? { playbackState == .playing ? activeTarget?.source?.spanID : nil }
    var playingRecordingID: UUID? {
        guard playbackState == .playing, case .recording(let id, _) = activeTarget else { return nil }
        return id
    }
    /// Another owner of the shared AVAudioSession, such as earphone capture, steps aside while playback runs.
    @ObservationIgnored var sessionWillActivate: () async -> Void = {}
    @ObservationIgnored var sessionDidDeactivate: () -> Void = {}
    @ObservationIgnored private let archive: ArchiveStore
    @ObservationIgnored private let audioSession: PlaybackAudioSession
    @ObservationIgnored private let waveformCache: PlaybackWaveformCache
    @ObservationIgnored private var timeline: PlaybackTimeline?
    @ObservationIgnored private var activePart: AudioPlaybackPart?
    @ObservationIgnored private var activeIndex: Int?
    @ObservationIgnored private var sessionAttempt: UInt64?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var waveformGeneration = UUID()
    @ObservationIgnored private var nativeCleanup: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var interruptions: PlaybackInterruptions?
    @ObservationIgnored private(set) var waveformPreparation: Task<Void, Never>?
    @ObservationIgnored private var pendingWaveformChunks: [UUID] = []
    @ObservationIgnored private var pendingWaveformTargets: [AudioPlaybackTarget] = []
    @ObservationIgnored private var preparedWindowTargets: [TimelineWindowID: AudioPlaybackTarget] = [:]
    @ObservationIgnored private var waveformBackfillCursor: Int64?
    @ObservationIgnored private var waveformBackfillComplete = false
    @ObservationIgnored private var waveformBackfillCount = 0
    @ObservationIgnored private var waveformBackfillPage: [WaveformPreparationEntry] = []
    @ObservationIgnored private var preparationGeneration = UUID()

    init(archive: ArchiveStore, audioSession: PlaybackAudioSession = PlaybackAudioSession()) {
        self.archive = archive
        self.audioSession = audioSession
        waveformCache = PlaybackWaveformCache(directory: archive.rootURL.appendingPathComponent("Library/Caches/MoMoAgent/waveforms-v2", isDirectory: true))
        interruptions = PlaybackInterruptions { [weak self] in
            Task { @MainActor in await self?.pauseForInterruption() }
        }
    }

    /// One background worker prepares received chunks before a player is opened. Fresh transfers
    /// jump ahead of the paged legacy backlog; neither reception nor playback waits for this task.
    func requestWaveformPreparation(for targets: [AudioPlaybackTarget], run: Bool = true) {
        for target in targets.prefix(16) where !pendingWaveformTargets.contains(target) {
            if let id = target.windowID, preparedWindowTargets[id] == target { continue }
            if let id = target.windowID { pendingWaveformTargets.removeAll { $0.windowID == id } }
            pendingWaveformTargets.append(target)
        }
        if pendingWaveformTargets.count > 64 { pendingWaveformTargets.removeFirst(pendingWaveformTargets.count - 64) }
        requestWaveformPreparation(run: run)
    }

    func requestWaveformPreparation(chunkID: UUID? = nil, run: Bool = true) {
        if let chunkID {
            if !pendingWaveformChunks.contains(chunkID) { pendingWaveformChunks.append(chunkID) }
            if pendingWaveformChunks.count > 128 {
                pendingWaveformChunks.removeFirst()
                waveformBackfillCursor = nil; waveformBackfillComplete = false
                waveformBackfillCount = 0
                waveformBackfillPage.removeAll()
            }
        }
        guard run, waveformPreparation == nil else { return }
        let attempt = UUID()
        preparationGeneration = attempt
        waveformPreparation = Task(priority: .background) { [weak self] in
            guard let self else { return }
            defer { if self.preparationGeneration == attempt { self.waveformPreparation = nil } }
            while !Task.isCancelled, self.preparationGeneration == attempt {
                var selectedEntry = false
                var selectedChunkID: UUID?
                var selectedTarget: AudioPlaybackTarget?
                do {
                    if !self.pendingWaveformTargets.isEmpty {
                        let target = self.pendingWaveformTargets.removeFirst()
                        selectedTarget = target; selectedEntry = true
                        let value = try await self.loadTimeline(target)
                        try Task.checkCancellation()
                        _ = try await self.waveformCache.waveform(for: value, archive: self.archive)
                        try Task.checkCancellation()
                        if let id = target.windowID {
                            self.preparedWindowTargets[id] = target
                            if self.preparedWindowTargets.count > 64, let evicted = self.preparedWindowTargets.keys.first {
                                self.preparedWindowTargets.removeValue(forKey: evicted)
                            }
                        }
                        await Task.yield()
                        continue
                    }
                    let entry: WaveformPreparationEntry
                    if !self.pendingWaveformChunks.isEmpty {
                        let id = self.pendingWaveformChunks.removeFirst()
                        guard let received = try await self.archive.waveformPreparationEntry(chunkID: id) else { continue }
                        entry = received
                    } else {
                        if self.waveformBackfillPage.isEmpty {
                            guard !self.waveformBackfillComplete, self.waveformBackfillCount < 16_384 else { return }
                            let page = try await self.archive.waveformPreparationPage(beforeRowID: self.waveformBackfillCursor, cacheGeneration: try await self.waveformCache.preparationIdentity())
                            try Task.checkCancellation()
                            if page.isEmpty { self.waveformBackfillComplete = true; return }
                            self.waveformBackfillPage = page
                            self.waveformBackfillCursor = page.last?.rowID
                        }
                        entry = self.waveformBackfillPage.removeFirst()
                        self.waveformBackfillCount += 1
                    }
                    selectedEntry = true
                    selectedChunkID = entry.timeline.parts.first?.manifest.chunkID
                    try Task.checkCancellation()
                    _ = try await self.waveformCache.waveform(for: PlaybackTimeline(entry.timeline), archive: self.archive, requirePersistence: true)
                    try Task.checkCancellation()
                    try await self.archive.completeWaveformPreparation(entry, cacheGeneration: self.waveformCache.preparationIdentity())
                    await Task.yield()
                } catch is CancellationError {
                    if let target = selectedTarget, !self.pendingWaveformTargets.contains(target), self.pendingWaveformTargets.count < 64 {
                        self.pendingWaveformTargets.append(target)
                    }
                    if let id = selectedChunkID, !self.pendingWaveformChunks.contains(id), self.pendingWaveformChunks.count < 128 {
                        self.pendingWaveformChunks.append(id)
                    }
                    return
                }
                catch {
                    self.logger.notice("Optional waveform preparation skipped: \((error as NSError).code)")
                    // A bad chunk must not stall preparation of the remaining recordings.
                    if !selectedEntry { return }
                }
            }
        }
    }

    func suspendWaveformPreparation() {
        preparationGeneration = UUID()
        waveformPreparation?.cancel(); waveformPreparation = nil
    }

    func play(_ source: SourceReference) async throws { try await play(.transcript(source)) }
    func playRecording(sessionID: UUID, generation: Int64) async throws {
        try await play(.recording(sessionID, generation))
    }

    /// A paragraph keeps its paused native position; choosing a different source starts its exact clip.
    func toggle(_ source: SourceReference) async throws {
        try await toggle(.transcript(source))
    }

    func toggle(_ target: AudioPlaybackTarget) async throws {
        if snapshot?.target == target {
            if snapshot?.state == .playing { await pause() }
            else { try await resume() }
        } else { try await play(target) }
    }

    /// Keep the ruler frozen while usable. An invalidated target may be replaced only by
    /// a later explicit play action; selecting fresh metadata never starts audio.
    func target(for window: TimelineWindow) -> AudioPlaybackTarget? {
        if let activeTarget, activeTarget.windowID == window.id, playbackState != .failed {
            return activeTarget
        }
        guard !window.sources.isEmpty else { return nil }
        return .window(window.id, window.sources)
    }

    /// A preview neither replaces the active target nor activates AVAudioSession.
    func preview(for target: AudioPlaybackTarget,
                 metadataReady: (@MainActor @Sendable (AudioPlaybackSnapshot) -> Void)? = nil) async throws -> AudioPlaybackSnapshot {
        let value = try await loadTimeline(target)
        try Task.checkCancellation()
        var preview = value.snapshot(target: target)
        metadataReady?(preview)
        let cache = waveformCache
        let archive = archive
        let metadata = preview
        let work = Task.detached(priority: .utility) {
            try await cache.waveform(for: value, archive: archive) { update in
                var partial = metadata
                partial.waveform = update.bins
                partial.waveformProgress = update.progress
                partial.waveformLoadedThrough = update.loadedThrough
                await metadataReady?(partial)
            }
        }
        preview.waveform = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        preview.waveformProgress = preview.waveform.isEmpty ? nil : 1
        preview.waveformLoadedThrough = preview.duration
        try Task.checkCancellation()
        return preview
    }

    func play(_ target: AudioPlaybackTarget, from requestedPosition: TimeInterval? = nil) async throws {
        suspendWaveformPreparation()
        generation &+= 1
        let attempt = generation
        snapshot = nil
        timeline = nil
        failure = nil
        waveformTask?.cancel()
        waveformGeneration = UUID()
        await clearNative()
        try require(attempt)
        do {
            let value = try await loadTimeline(target)
            try require(attempt)
            timeline = value
            snapshot = value.snapshot(target: target, state: .loading)
            let index: Int
            let position: TimeInterval
            if let requestedPosition {
                // A mark must start at its exact sample, never at the beginning or after a missing interval.
                guard requestedPosition.isFinite, let located = value.index(at: requestedPosition) else { throw PlaybackError.unavailable }
                index = located
                position = requestedPosition
            } else {
                guard let first = value.segments.firstIndex(where: { $0.part.audioAvailable }) else { throw PlaybackError.unavailable }
                index = first
                position = value.segments[first].start
            }
            // The logical starting point may follow a missing prefix. A system pause during
            // preparation must remain resumable there, rather than being stranded inside that gap.
            snapshot?.position = position
            try await start(index: index, position: position, attempt: attempt)
            try require(attempt)
            startWaveform(value, target: target)
        } catch {
            await handleFailure(error, attempt: attempt)
            throw error
        }
    }

    func pause() async {
        guard let current = snapshot, current.state == .playing || current.state == .loading else { return }
        generation &+= 1
        let operation = generation
        await pauseNative(operation: operation, wasPlaying: current.state == .playing)
    }

    func resume() async throws {
        suspendWaveformPreparation()
        guard let current = snapshot, let timeline else { throw PlaybackError.unavailable }
        if current.state == .playing { return }
        generation &+= 1
        let attempt = generation
        let requested = current.state == .ended ? timeline.segments.first(where: { $0.part.audioAvailable })?.start : current.position
        guard let requested, let index = timeline.index(at: requested) else { throw PlaybackError.unavailable }
        snapshot?.state = .loading
        failure = nil
        await clearNative()
        do {
            try require(attempt)
            try await start(index: index, position: requested, attempt: attempt)
        } catch {
            await handleFailure(error, attempt: attempt)
            throw error
        }
    }

    func seek(to position: Double) async throws {
        guard let current = snapshot, let timeline, current.canSeek,
              position.isFinite, position >= 0, let duration = timeline.duration, position <= duration else {
            throw PlaybackError.unavailable
        }
        // Reject a gap before touching the existing native player or its position.
        let availableEnd = position == duration && timeline.segments.last?.part.audioAvailable == true
            && timeline.segments.last?.end == duration
        guard availableEnd || timeline.index(at: position) != nil else {
            failure = String(localized: "这段原音尚未收到或已清理，无法定位到此处。")
            throw PlaybackError.unavailable
        }
        generation &+= 1
        let attempt = generation
        let wasPlaying = current.state == .playing
        await pauseNative(operation: attempt, wasPlaying: wasPlaying)
        try require(attempt)
        let previousPosition = snapshot?.position ?? current.position
        do {
            try await validateCurrentTimeline(active: false)
            try require(attempt)
            guard let timeline = self.timeline else { throw CancellationError() }
            if position == duration {
                snapshot?.position = duration
                snapshot?.state = .ended
            } else if let index = timeline.index(at: position) {
                if wasPlaying {
                    snapshot?.state = .loading
                    try await start(index: index, position: position, attempt: attempt)
                } else {
                    // Silent seek still checks the real file. It does not create/activate a native player.
                    let part = try await acquirePartWithSpeakerRefresh(index: index)
                    do { try await audioSession.validate(part) }
                    catch { await release(part); throw error }
                    await release(part)
                    try require(attempt)
                    snapshot?.position = position
                    snapshot?.state = .paused
                }
            }
            failure = nil
        } catch {
            if generation == attempt { snapshot?.position = previousPosition }
            await handleFailure(error, attempt: attempt)
            throw error
        }
    }

    func stop() async {
        await stop(deactivateImmediately: false)
    }

    func stop(deactivateImmediately: Bool) async {
        generation &+= 1
        let operation = generation
        snapshot = nil
        timeline = nil
        failure = nil
        let stoppedWaveform = waveformTask
        waveformGeneration = UUID()
        stoppedWaveform?.cancel()
        await clearNative()
        if deactivateImmediately {
            audioSession.deactivateHardwareImmediately()
        }
        // A canceled envelope reader must finish releasing its own file lease before close returns.
        // Keep it discoverable for another concurrent stop; never clear a newer target's reader.
        await stoppedWaveform?.value
        if generation == operation { waveformTask = nil }
    }

    func deactivateHardwareSessionImmediately() {
        audioSession.deactivateHardwareImmediately()
    }

    private func pauseForInterruption() async {
        guard snapshot?.state == .playing || snapshot?.state == .loading else { return }
        await pause()
        if snapshot?.state == .paused { failure = String(localized: "回听已被系统打断。确认播放设备后，点播放继续。") }
    }

    private func pauseNative(operation: UInt64, wasPlaying: Bool) async {
        playbackTask?.cancel()
        if wasPlaying, let attempt = sessionAttempt, let index = activeIndex, let timeline,
           let progress = try? await audioSession.pause(for: attempt), operation == generation {
            snapshot?.position = min(timeline.segments[index].end, timeline.segments[index].start + progress.currentTime)
        }
        guard operation == generation else { return }
        snapshot?.state = .paused
        // For loading/preparing, deactivate cancels the native attempt immediately; do not enqueue
        // a pause behind a blocked prepare and allow that prepare to start sound in the meantime.
        await clearNative()
    }

    private func loadTimeline(_ target: AudioPlaybackTarget) async throws -> PlaybackTimeline {
        if case .window(_, let sources) = target {
            guard !sources.isEmpty else { throw PlaybackError.unavailable }
            return PlaybackTimeline(windows: try await archive.playbackTimelines(sources: sources))
        }
        let additional: [SourceReference]
        if case .turn(_, let sources) = target { additional = sources } else { additional = [] }
        do {
            return PlaybackTimeline(try await archive.playbackTimeline(sessionID: target.sessionID,
                expectedGeneration: target.generation, source: target.source, additionalSources: additional))
        } catch ArchiveError.staleSource {
            guard let primary = target.source else { throw ArchiveError.staleSource }
            let resolved = try await archive.resolveAudioCompatibleSources([primary] + additional)
            guard let refreshedPrimary = resolved.first else { throw ArchiveError.staleSource }
            return PlaybackTimeline(try await archive.playbackTimeline(sessionID: target.sessionID,
                expectedGeneration: target.generation, source: refreshedPrimary,
                additionalSources: Array(resolved.dropFirst())))
        }
    }

    private func validate(_ timeline: PlaybackTimeline, active: Bool = false) async throws {
        for member in timeline.archives {
            if active { try await archive.validateActivePlaybackTimeline(member) }
            else { try await archive.validatePlaybackTimeline(member) }
        }
    }

    private func validateCurrentTimeline(active: Bool) async throws {
        guard let currentTimeline = timeline else { throw CancellationError() }
        do {
            try await validate(currentTimeline, active: active)
        } catch ArchiveError.staleSource where !active {
            guard let currentTarget = snapshot?.target else { throw ArchiveError.staleSource }
            let refreshed = try await loadTimeline(currentTarget)
            try await validate(refreshed, active: false)
            self.timeline = refreshed
        }
    }

    private func acquirePartWithSpeakerRefresh(index: Int) async throws -> AudioPlaybackPart {
        guard let currentTimeline = timeline, currentTimeline.segments.indices.contains(index) else {
            throw PlaybackError.unavailable
        }
        let segment = currentTimeline.segments[index]
        do {
            return try await archive.acquirePlaybackPart(segment.part, in: currentTimeline.archives[segment.archiveIndex])
        } catch ArchiveError.staleSource {
            guard let currentTarget = snapshot?.target else { throw ArchiveError.staleSource }
            let refreshed = try await loadTimeline(currentTarget)
            guard refreshed.segments.count == currentTimeline.segments.count,
                  refreshed.segments[index].part == segment.part else {
                throw ArchiveError.staleSource
            }
            let part = try await archive.acquirePlaybackPart(
                refreshed.segments[index].part,
                in: refreshed.archives[refreshed.segments[index].archiveIndex]
            )
            self.timeline = refreshed
            return part
        }
    }

    private func start(index: Int, position: Double, attempt: UInt64) async throws {
        try require(attempt)
        guard let initialTimeline = timeline, initialTimeline.segments.indices.contains(index) else { throw CancellationError() }
        let segment = initialTimeline.segments[index]
        let part = try await acquirePartWithSpeakerRefresh(index: index)
        guard attempt == generation, !Task.isCancelled else {
            await release(part)
            throw CancellationError()
        }
        activePart = part
        activeIndex = index
        sessionAttempt = attempt
        await sessionWillActivate()
        try require(attempt)
        try await audioSession.activate(for: attempt)
        try require(attempt)
        try await audioSession.prepare(part, offset: position - segment.start, for: attempt)
        try require(attempt)
        // A source changed during native preparation must not start playing stale audio.
        try await validateCurrentTimeline(active: false)
        try require(attempt)
        try await audioSession.startPrepared(for: attempt)
        try require(attempt)
        let progress = try await audioSession.progress(for: attempt)
        try require(attempt)
        snapshot?.position = segment.start + progress.currentTime
        snapshot?.state = .playing
        failure = nil
        playbackTask = Task { [weak self] in await self?.observe(attempt: attempt) }
        validationTask = Task { [weak self] in await self?.observeIdentity(attempt: attempt) }
    }

    private func observe(attempt: UInt64) async {
        do {
            while true {
                try require(attempt)
                guard let timeline, let index = activeIndex else { throw CancellationError() }
                let segment = timeline.segments[index]
                let progress = try await audioSession.progress(for: attempt)
                try require(attempt)
                if progress.isPlaying || progress.finished {
                    snapshot?.position = min(segment.end, segment.start + progress.currentTime)
                }
                if progress.finished {
                    snapshot?.position = segment.end
                    let nextIndex = timeline.segments.indices.first { $0 > index && timeline.segments[$0].part.audioAvailable }
                    guard let nextIndex else {
                        // A missing tail is visible on the frozen ruler, but was never played.
                        snapshot?.position = segment.end
                        snapshot?.state = .ended
                        await clearNative(cancelObservation: false)
                        return
                    }
                    // Stop old audio before releasing its lease; never pin all pages of a long recording.
                    await clearNative(cancelObservation: false)
                    try require(attempt)
                    try await start(index: nextIndex, position: timeline.segments[nextIndex].start, attempt: attempt)
                    return
                }
                if !progress.isPlaying && !progress.awaitingCompletion {
                    // An unannounced OS stop is resumable, never interpreted as successful completion.
                    snapshot?.state = .paused
                    await clearNative(cancelObservation: false)
                    return
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        } catch is CancellationError {
            // The replacing command owns the detached native resources and their cleanup.
        } catch { await handleFailure(error, attempt: attempt) }
    }

    /// Archive contention must not stall the native clock. Only one identity check is in flight.
    private func observeIdentity(attempt: UInt64) async {
        do {
            while true {
                try await Task.sleep(for: .milliseconds(250))
                try require(attempt)
                guard let timeline else { throw CancellationError() }
                try await validate(timeline, active: true)
                try require(attempt)
            }
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled { await handleFailure(error, attempt: attempt) }
        }
    }

    private func startWaveform(_ value: PlaybackTimeline, target: AudioPlaybackTarget) {
        waveformTask?.cancel()
        let cache = waveformCache
        let archive = archive
        let attempt = UUID()
        waveformGeneration = attempt
        waveformTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) { [weak self] in
                try await cache.waveform(for: value, archive: archive) { [weak self] update in
                    await self?.receiveWaveform(update, target: target, attempt: attempt)
                }
            }
            do {
                let bins = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self, self.waveformGeneration == attempt, self.snapshot?.target == target else { return }
                self.snapshot?.waveform = bins
                self.snapshot?.waveformProgress = bins.isEmpty ? nil : 1
                self.snapshot?.waveformLoadedThrough = value.duration
            } catch is CancellationError {} catch {
                // Waveform failure must not label an otherwise playing native stream as failed.
                guard let self, self.waveformGeneration == attempt else { return }
                self.snapshot?.waveform = []
                self.snapshot?.waveformProgress = nil
                self.snapshot?.waveformLoadedThrough = nil
                self.logger.error("Playback waveform unavailable")
            }
        }
    }

    private func receiveWaveform(_ update: PlaybackWaveformCache.Update, target: AudioPlaybackTarget, attempt: UUID) {
        guard !Task.isCancelled, waveformGeneration == attempt, snapshot?.target == target else { return }
        snapshot?.waveform = update.bins
        snapshot?.waveformProgress = update.progress
        snapshot?.waveformLoadedThrough = update.loadedThrough
    }

    private func require(_ attempt: UInt64) throws {
        try Task.checkCancellation()
        guard attempt == generation else { throw CancellationError() }
    }

    private func handleFailure(_ error: Error, attempt: UInt64) async {
        guard generation == attempt else { return }
        snapshot?.state = .failed
        waveformTask?.cancel()
        waveformGeneration = UUID()
        snapshot?.waveformProgress = nil
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .sessionDeleted:
                snapshot = nil
                timeline = nil
                waveformTask?.cancel()
            case .staleSource:
                snapshot?.canSeek = false
                snapshot?.waveform = []
                waveformTask?.cancel()
            case .missingRecording(let chunkID):
                if let segment = timeline?.segments.first(where: { $0.part.manifest.chunkID == chunkID }) {
                    let range = segment.start...segment.end
                    if snapshot?.gaps.contains(range) == false { snapshot?.gaps.append(range) }
                }
                snapshot?.waveform = []
                waveformTask?.cancel()
            default: break
            }
        }
        failure = error is CancellationError ? nil : String(localized: "原音回听未能完成：\(error.localizedDescription)")
        await clearNative()
    }

    /// Detach resources before suspension, but retain the cleanup until its lease is released.
    /// A concurrent stop/play must join cleanup already started by the observation task.
    private func clearNative(cancelObservation: Bool = true) async {
        if cancelObservation { playbackTask?.cancel() }
        playbackTask = nil
        validationTask?.cancel()
        validationTask = nil
        let part = activePart
        let attempt = sessionAttempt
        activePart = nil
        activeIndex = nil
        sessionAttempt = nil
        let previousCleanup = nativeCleanup?.task
        guard part != nil || attempt != nil else {
            await previousCleanup?.value
            return
        }
        let cleanupID = UUID()
        let cleanup = Task { [self] in
            await previousCleanup?.value
            if let attempt {
                do { try await audioSession.deactivate(for: attempt) }
                catch { logger.error("Playback audio session cleanup failed") }
                sessionDidDeactivate()
            }
            if let part { await release(part) }
        }
        nativeCleanup = (cleanupID, cleanup)
        await cleanup.value
        if nativeCleanup?.id == cleanupID { nativeCleanup = nil }
    }

    private func release(_ part: AudioPlaybackPart) async {
        await archive.releaseAudioLease(id: part.lease.id)
        do { try await archive.cleanDeletedFiles() }
        catch { logger.error("Playback file cleanup failed") }
    }
}

enum PlaybackError: Error { case unavailable }

private final class PlaybackInterruptions: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    init(stop: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { notification in
            if let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: value) == .began { stop() }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { notification in
            if let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable { stop() }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in stop() })
    }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
