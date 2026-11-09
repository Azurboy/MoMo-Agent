import AVFoundation
import Observation
import XCTest
@testable import MoMoArchive
import MoMoContracts
@testable import MoMoAgent

/// Actual AVAudioPlayer/AVAudioFile with the public speech fixture. Notification tests exercise
/// app handling only; they do not certify physical phone calls or headphone-route behavior.
extension AudioPlaybackIntegrationTests {
    func testLaterSeekKeepsPlayingIntentWhileTheEarlierSeekAwaitsValidation() async throws {
        let fixture = try await makeRecording()
        let player = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await player.stop() }
        try await player.play(fixture.source)
        let entered = expectation(description: "Archive validation held")
        let busy = Task.detached { await fixture.archive.occupyForPlaybackClockRegression { entered.fulfill() } }
        await fulfillment(of: [entered], timeout: 2)
        let earlier = Task { try await player.seek(to: 1) }
        try await waitForPlayer(player, state: .paused)
        XCTAssertTrue(player.playbackRequested, "Native preparation is distinct from the user's playback intent.")
        try await player.seek(to: 2)
        await busy.value
        do { try await earlier.value; XCTFail("The earlier command must be superseded.") }
        catch is CancellationError { }
        XCTAssertEqual(player.snapshot?.state, .playing)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(player.snapshot?.position), 2)
    }

    func testPauseDuringSeekCannotRestartAudioWhenValidationReturns() async throws {
        let fixture = try await makeRecording()
        let player = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await player.stop() }
        try await player.play(fixture.source)
        let entered = expectation(description: "Archive validation held")
        let busy = Task.detached { await fixture.archive.occupyForPlaybackClockRegression { entered.fulfill() } }
        await fulfillment(of: [entered], timeout: 2)
        let earlier = Task { try await player.seek(to: 1) }
        try await waitForPlayer(player, state: .paused)
        await player.pause()
        await busy.value
        do { try await earlier.value; XCTFail("Pause must supersede the in-flight seek.") }
        catch is CancellationError { }
        XCTAssertEqual(player.snapshot?.state, .paused)
        XCTAssertFalse(player.playbackRequested)
    }

    func testPauseBeforeTimelineLoadsCancelsThePendingPlay() async throws {
        let fixture = try await makeRecording()
        let player = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await player.stop() }
        let entered = expectation(description: "Timeline load held")
        let busy = Task.detached { await fixture.archive.occupyForPlaybackClockRegression { entered.fulfill() } }
        await fulfillment(of: [entered], timeout: 2)
        let requested = expectation(description: "Play requested before timeline returns")
        withObservationTracking { _ = player.playbackRequested } onChange: { requested.fulfill() }
        let earlier = Task { try await player.play(fixture.source) }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertTrue(player.playbackRequested)
        await player.pause()
        await busy.value
        do { try await earlier.value; XCTFail("Pause must cancel a pending initial play.") }
        catch is CancellationError { }
        XCTAssertNotEqual(player.snapshot?.state, .playing)
        XCTAssertFalse(player.playbackRequested)
    }

    func testPlaybackClockDoesNotInvalidateTranscriptTransportObservers() async throws {
        let fixture = try await makeRecording()
        let player = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await player.stop() }
        try await player.play(fixture.source)
        let clockOnly = expectation(description: "Progress must not invalidate transcript rows")
        clockOnly.isInverted = true
        withObservationTracking {
            _ = player.activeTarget
            _ = player.playbackState
            _ = player.playingSpanID
        } onChange: { clockOnly.fulfill() }
        let position = try XCTUnwrap(player.snapshot?.position)
        await fulfillment(of: [clockOnly], timeout: 0.3)
        XCTAssertGreaterThan(try XCTUnwrap(player.snapshot?.position) - position, 0.1)
        let paused = expectation(description: "Pause still invalidates transport controls")
        withObservationTracking { _ = player.playbackState } onChange: { paused.fulfill() }
        await player.pause()
        await fulfillment(of: [paused], timeout: 1)
        XCTAssertEqual(player.playbackState, .paused)
        XCTAssertNil(player.playingSpanID)
        XCTAssertEqual(player.activeTarget, .transcript(fixture.source))
    }

    func testPlaybackClockKeepsAdvancingWhileArchiveIsBusyAndDeletionStillStopsAudio() async throws {
        let fixture = try await makeRecording()
        let player = AudioPlaybackController(archive: fixture.archive)
        try await player.play(fixture.source)
        let entered = expectation(description: "Archive occupied by other recording work")
        let busy = Task.detached {
            await fixture.archive.occupyForPlaybackClockRegression { entered.fulfill() }
        }
        await fulfillment(of: [entered], timeout: 2)
        let before = try XCTUnwrap(player.snapshot?.position)
        try await Task.sleep(for: .milliseconds(650))
        let advanced = try XCTUnwrap(player.snapshot?.position) - before
        print("WAVEFORM_BENCHMARK archiveBusy=0.9s clockAdvanceAfter650ms=\(advanced)")
        XCTAssertGreaterThan(advanced, 0.4, "A pending archive validation must not freeze the native playback cursor.")
        await busy.value
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while player.snapshot != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(player.snapshot, "The independent identity check must still stop deleted audio.")
        await player.stop()
    }

    func testLongRecordingWaveformUsesLinearFileValidationWork() async throws {
        let fixture = try await makeFixedTimelineRecording()
        let original = fixture.manifest
        let partCount = 32
        for sequence in 1..<partCount {
            let manifest = try ChunkManifest(sessionID: original.sessionID, epochID: original.epochID,
                sourceDeviceID: original.sourceDeviceID, sourceBuild: original.sourceBuild,
                sequence: Int64(sequence),
                frames: FrameRange(start: original.frames.count * Int64(sequence), count: original.frames.count),
                timebaseHz: original.timebaseHz, wallClockAnchor: original.wallClockAnchor,
                timezoneOffset: original.timezoneOffset, codec: original.codec, sampleRate: original.sampleRate,
                channels: original.channels, decodedFrameCount: original.decodedFrameCount,
                byteCount: original.byteCount, audioSHA256: original.audioSHA256, sourceKind: .fixture)
            try await deliverPlaybackCopy(ManifestEnvelope(manifest: manifest), audio: fixture.audioURL, archive: fixture.archive)
        }
        let archived = try await fixture.archive.playbackTimeline(sessionID: original.sessionID,
            expectedGeneration: fixture.source.generation)
        let timeline = PlaybackTimeline(archived)
        XCTAssertEqual(timeline.segments.count, partCount)
        let cache = PlaybackWaveformCache()
        let before = await fixture.archive.playbackPreviewStampReadCount
        let started = ContinuousClock.now
        let cold = try await cache.waveform(for: timeline, archive: fixture.archive)
        let coldReads = await fixture.archive.playbackPreviewStampReadCount - before
        print("WAVEFORM_BENCHMARK cold parts=\(partCount) stampReads=\(coldReads) elapsed=\(started.duration(to: .now))")
        XCTAssertEqual(cold.count, 512)
        XCTAssertLessThanOrEqual(coldReads, partCount * 3, "Each original needs one initial, one decoded-part and one final check; no whole-recording scan per part.")
        let warmStarted = ContinuousClock.now
        let warm = try await cache.waveform(for: timeline, archive: fixture.archive)
        let warmReads = await fixture.archive.playbackPreviewStampReadCount - before - coldReads
        print("WAVEFORM_BENCHMARK warm parts=\(partCount) stampReads=\(warmReads) elapsed=\(warmStarted.duration(to: .now))")
        XCTAssertEqual(warm, cold)
        XCTAssertEqual(warmReads, partCount * 2)
    }

    func testPreviewPublishesMetadataBeforeWaveformAndDiskCacheSurvivesControllerRecreation() async throws {
        let fixture = try await makeRecording()
        let target = AudioPlaybackTarget.transcript(fixture.source)
        let playback = AudioPlaybackController(archive: fixture.archive)
        var metadata: AudioPlaybackSnapshot?
        var updates = 0
        let complete = try await playback.preview(for: target) { value in
            if updates == 0 { XCTAssertTrue(value.waveform.isEmpty) }
            else { XCTAssertFalse(value.waveform.isEmpty) }
            updates += 1
            XCTAssertNil(playback.snapshot)
            metadata = value
        }
        XCTAssertGreaterThan(updates, 1)
        XCTAssertEqual(complete.waveformProgress, 1)
        XCTAssertEqual(metadata?.duration, complete.duration)
        XCTAssertEqual(complete.waveform.count, 512)
        let archived = try await fixture.archive.playbackTimeline(sessionID: fixture.source.sessionID, expectedGeneration: fixture.source.generation, source: fixture.source)
        let timeline = PlaybackTimeline(archived)
        let directory = fixture.archive.rootURL.appendingPathComponent("Library/Caches/MoMoAgent/waveforms-v2")
        let reopened = PlaybackWaveformCache(directory: directory)
        let validationsBefore = await fixture.archive.audioContentValidationCount
        let cached = try await reopened.waveform(for: timeline, archive: fixture.archive)
        let validationsAfter = await fixture.archive.audioContentValidationCount
        let decodes = await reopened.decodedPartCount
        XCTAssertEqual(cached, complete.waveform)
        XCTAssertEqual(decodes, 0, "A new controller must reuse disk RMS bins without decoding PCM again.")
        XCTAssertEqual(validationsAfter, validationsBefore, "Cached display must not scan original audio bytes again.")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertEqual(file.pathExtension, "wfm")
            XCTAssertEqual(try Data(contentsOf: file).count, 1_028)
        }
        for file in files { try Data("broken derived cache".utf8).write(to: file) }
        let repaired = PlaybackWaveformCache(directory: directory)
        let regenerated = try await repaired.waveform(for: timeline, archive: fixture.archive)
        let repairedDecodes = await repaired.decodedPartCount
        XCTAssertEqual(regenerated, complete.waveform)
        XCTAssertGreaterThan(repairedDecodes, 0)
        try Data("corrupt original".utf8).write(to: fixture.audioURL)
        do {
            _ = try await PlaybackWaveformCache(directory: directory).waveform(for: timeline, archive: fixture.archive)
            XCTFail("Disk cache must not conceal original audio corruption")
        } catch ArchiveError.missingRecording { }
    }

    func testBackgroundPreparationMakesUnopenedRecordingReadyAndPreservesPlaybackValidation() async throws {
        let fixture = try await makeRecording()
        let preparing = AudioPlaybackController(archive: fixture.archive)
        preparing.requestWaveformPreparation()
        await preparing.waveformPreparation?.value
        XCTAssertNil(preparing.snapshot)
        let before = await fixture.archive.audioContentValidationCount
        let checkedFiles = await fixture.archive.playbackPreviewStampReadCount
        let controller = AudioPlaybackController(archive: fixture.archive)
        controller.requestWaveformPreparation()
        await controller.waveformPreparation?.value
        let checkedAfterRestart = await fixture.archive.playbackPreviewStampReadCount
        XCTAssertEqual(checkedFiles, checkedAfterRestart, "A new controller must skip completed historical previews without restatting audio.")
        let target = AudioPlaybackTarget.recording(fixture.source.sessionID, fixture.source.generation)
        let clock = ContinuousClock.now
        let value = try await controller.preview(for: target)
        let elapsed = clock.duration(to: .now)
        let after = await fixture.archive.audioContentValidationCount
        XCTAssertEqual(after, before, "First open after background preparation reads only metadata and saved peaks.")
        XCTAssertEqual(value.waveform.count, 512)
        XCTAssertGreaterThan(value.waveform.max() ?? 0, 0.01)
        print("Prepared waveform first open: \(elapsed)")
        addTeardownBlock { await controller.stop() }
        try await controller.play(target)
        let played = await fixture.archive.audioContentValidationCount
        XCTAssertGreaterThan(played, after, "Actual playback still validates the complete original hash.")
        await controller.stop()

        var bytes = try Data(contentsOf: fixture.audioURL)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: fixture.audioURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: fixture.audioURL.path)
        do { _ = try await controller.preview(for: target); XCTFail("A same-length changed original must invalidate prepared peaks.") }
        catch ArchiveError.missingRecording { }
    }

    func testExactCitationWaveformCanBePreparedBeforeItsFirstOpen() async throws {
        let fixture = try await makeRecording(frames: FrameRange(start: 8_000, count: 16_000))
        let target = AudioPlaybackTarget.transcript(fixture.source)
        let preparing = AudioPlaybackController(archive: fixture.archive)
        preparing.requestWaveformPreparation(for: [target])
        await preparing.waveformPreparation?.value
        let validations = await fixture.archive.audioContentValidationCount
        let preview = try await AudioPlaybackController(archive: fixture.archive).preview(for: target)
        XCTAssertEqual(preview.duration, 1)
        XCTAssertEqual(preview.waveform.count, 512)
        let after = await fixture.archive.audioContentValidationCount
        XCTAssertEqual(after, validations, "Visible timeline/citation ranges must reuse their own prepared peaks.")
        XCTAssertNil(preparing.snapshot)
    }

    func testWaveformPublishesFirstPartBeforeReadingTheNextAndCancellationReleasesLease() async throws {
        let fixture = try await makeFixedTimelineRecording()
        let original = fixture.manifest
        let next = try ManifestEnvelope(manifest: ChunkManifest(sessionID: original.sessionID, epochID: original.epochID,
            sourceDeviceID: original.sourceDeviceID, sourceBuild: "progressive-waveform", sequence: 1,
            frames: FrameRange(start: original.frames.end, count: original.frames.count), timebaseHz: original.timebaseHz,
            wallClockAnchor: original.wallClockAnchor, timezoneOffset: original.timezoneOffset, codec: original.codec,
            sampleRate: original.sampleRate, channels: original.channels, decodedFrameCount: original.decodedFrameCount,
            byteCount: original.byteCount, audioSHA256: original.audioSHA256, sourceKind: .fixture))
        try await deliverPlaybackCopy(next, audio: fixture.audioURL, archive: fixture.archive)
        let target = AudioPlaybackTarget.recording(original.sessionID, fixture.source.generation)
        let controller = AudioPlaybackController(archive: fixture.archive)
        var progress: [Double] = []
        let result = try await controller.preview(for: target) { update in
            if let value = update.waveformProgress { progress.append(value) }
        }
        XCTAssertEqual(progress.first, 0)
        XCTAssertTrue(progress.contains(0.5), "Publish the first chunk before scanning the rest of a recording.")
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(result.waveformLoadedThrough, result.duration)
        let frozen = try await fixture.archive.playbackTimeline(sessionID: original.sessionID, expectedGeneration: fixture.source.generation)
        let leased = try await fixture.archive.acquirePlaybackPart(frozen.parts[0], in: frozen)
        let originalURL = leased.lease.audioURL
        await fixture.archive.releaseAudioLease(id: leased.lease.id)
        let cache = PlaybackWaveformCache()
        let work = Task {
            try await cache.waveform(for: PlaybackTimeline(frozen), archive: fixture.archive) { _ in
                // Cancellation at the first publication must not read or decode the remaining chunk.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await work.value; XCTFail("Cancellation must stop progressive decoding") }
        catch is CancellationError { }
        let count = await cache.decodedPartCount
        XCTAssertEqual(count, 1)
        _ = try await fixture.archive.deleteSession(id: original.sessionID)
        try await fixture.archive.cleanDeletedFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path), "The waveform callback must not retain an audio lease.")
    }

    func testAccessibleAdjustmentCrossesLongMissingRangesWithoutPlayingThem() async throws {
        let fixture = try await makeRecording()
        let lease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let first = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        let nextStart = first.frames.end + Int64(first.timebaseHz * 60)
        let next = try ManifestEnvelope(manifest: ChunkManifest(sessionID: first.sessionID, epochID: first.epochID,
            sourceDeviceID: first.sourceDeviceID, sourceBuild: "accessible-playback-fixture", sequence: 1,
            frames: FrameRange(start: nextStart, count: first.frames.count), timebaseHz: first.timebaseHz,
            wallClockAnchor: first.wallClockAnchor, timezoneOffset: first.timezoneOffset,
            codec: first.codec, sampleRate: first.sampleRate, channels: first.channels,
            decodedFrameCount: first.decodedFrameCount, byteCount: first.byteCount,
            audioSHA256: first.audioSHA256, sourceKind: .fixture))
        try await deliverPlaybackCopy(next, audio: fixture.audioURL, archive: fixture.archive)
        let playback = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await playback.stop() }
        try await playback.playRecording(sessionID: first.sessionID, generation: fixture.source.generation)
        await playback.pause()
        try await playback.seek(to: max(0, Double(first.frames.count) / first.timebaseHz - 0.1))
        let before = try XCTUnwrap(playback.snapshot)
        XCTAssertEqual(before.seekableRanges.count, 2)
        let forward = try XCTUnwrap(before.adjustedSeekPosition(forward: true))
        let secondStart = Double(nextStart) / first.timebaseHz
        XCTAssertEqual(forward, secondStart, accuracy: 0.0001)
        try await playback.seek(to: forward)
        XCTAssertEqual(playback.snapshot?.state, .paused)
        let backwards = try XCTUnwrap(playback.snapshot?.adjustedSeekPosition(forward: false))
        XCTAssertLessThan(backwards, Double(first.frames.end) / first.timebaseHz)
        try await playback.seek(to: backwards)
        XCTAssertEqual(playback.snapshot?.state, .paused)
        XCTAssertNil(playback.failure)
        await playback.stop()
    }

    func testPauseResumeAndBothSeekModesUseTheNativeClock() async throws {
        let fixture = try await makeRecording()
        let playback = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await playback.stop() }
        try await playback.play(fixture.source)
        try await Task.sleep(for: .milliseconds(240))
        await playback.pause()
        let paused = try XCTUnwrap(playback.snapshot)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertGreaterThan(paused.position, 0.1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(playback.snapshot?.position, paused.position)
        try await playback.seek(to: 1.25)
        XCTAssertEqual(playback.snapshot?.state, .paused)
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.position), 1.25, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.position), 1.25, accuracy: 0.001)
        try await playback.resume()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(try XCTUnwrap(playback.snapshot?.position), 1.3)
        try await playback.seek(to: 2.25)
        XCTAssertEqual(playback.snapshot?.state, .playing)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(try XCTUnwrap(playback.snapshot?.position), 2.3)
    }

    func testCitationNativeClipEndsAtItsFramesAndReplaysFromItsBeginning() async throws {
        let fixture = try await makeRecording(frames: FrameRange(start: 16_000, count: 4_000))
        let source = fixture.source
        let frozen = try await fixture.archive.playbackTimeline(sessionID: source.sessionID, expectedGeneration: source.generation, source: source)
        let part = try await fixture.archive.acquirePlaybackPart(frozen.parts[0], in: frozen)
        let clip = fixture.archive.rootURL.appendingPathComponent("exact-citation.caf")
        try PlaybackPCMReader(part: part).writeClip(to: clip, check: {})
        let actual = try AVAudioFile(forReading: clip)
        XCTAssertEqual(actual.length, 4_000, "The native file itself cannot play the following source frames.")
        await fixture.archive.releaseAudioLease(id: part.lease.id)
        try FileManager.default.removeItem(at: clip)
        let playback = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await playback.stop() }
        try await playback.play(source)
        try await waitForPlayer(playback, state: .ended)
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.duration), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.position), 0.25, accuracy: 0.0001)
        try await playback.resume()
        XCTAssertEqual(playback.snapshot?.state, .playing)
        XCTAssertLessThan(try XCTUnwrap(playback.snapshot?.position), 0.2)
        try await waitForPlayer(playback, state: .ended)
    }

    func testUnannouncedNativeStopPausesAfterBoundedCompletionHandoffWithoutClaimingSuccess() async throws {
        let fixture = try await makeRecording()
        // Prepare a real file but suppress native start, simulating a stop with no delegate completion.
        let owner = PlaybackAudioSession(start: { _ in true })
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: owner)
        addTeardownBlock { await playback.stop() }
        try await playback.play(fixture.source)
        XCTAssertEqual(playback.snapshot?.state, .playing)
        try await waitForPlayer(playback, state: .paused)
        XCTAssertEqual(playback.snapshot?.position, 0)
        XCTAssertNil(playback.failure)
    }

    func testFrozenTimelineCrossChunkPrimingAndMissingGapSeek() async throws {
        let fixture = try await makeRecording()
        let lease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let original = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        let firstDuration = Double(original.frames.count) / original.timebaseHz
        let playback = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await playback.stop() }
        try await playback.playRecording(sessionID: original.sessionID, generation: fixture.source.generation)
        await playback.pause()
        // Same epoch, a real one-second missing interval, and decoded priming/padding.
        let nextStart = original.frames.end + Int64(original.timebaseHz)
        let next = try ManifestEnvelope(manifest: ChunkManifest(sessionID: original.sessionID, epochID: original.epochID,
            sourceDeviceID: original.sourceDeviceID, sourceBuild: "playback-priming-fixture", sequence: 1,
            frames: FrameRange(start: nextStart, count: original.decodedFrameCount - 2_400), timebaseHz: original.timebaseHz,
            wallClockAnchor: original.wallClockAnchor, timezoneOffset: original.timezoneOffset,
            codec: original.codec, sampleRate: original.sampleRate, channels: original.channels,
            decodedFrameCount: original.decodedFrameCount, primingFrames: 1_600, paddingFrames: 800,
            byteCount: original.byteCount, audioSHA256: original.audioSHA256, sourceKind: .fixture))
        try await deliverPlaybackCopy(next, audio: fixture.audioURL, archive: fixture.archive)
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.duration), firstDuration, accuracy: 0.0001)
        let target = AudioPlaybackTarget.recording(original.sessionID, fixture.source.generation)
        let preview = try await playback.preview(for: target)
        XCTAssertGreaterThan(try XCTUnwrap(preview.duration), firstDuration + 1)
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.duration), firstDuration, accuracy: 0.0001,
                       "Previewing newly received audio must not replace the active frozen range.")
        await playback.stop()
        try await playback.play(target)
        await playback.pause()
        XCTAssertTrue(try XCTUnwrap(playback.snapshot).gaps.contains { $0.contains(firstDuration + 0.5) })
        let before = try XCTUnwrap(playback.snapshot?.position)
        do { try await playback.seek(to: firstDuration + 0.5); XCTFail("Missing frames must not be seekable.") }
        catch PlaybackError.unavailable {}
        XCTAssertEqual(playback.snapshot?.position, before)
        try await playback.seek(to: firstDuration + 1.5)
        XCTAssertEqual(playback.snapshot?.state, .paused)
        try await playback.resume()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(try XCTUnwrap(playback.snapshot?.position), firstDuration + 1.55)
        let timeline = try await fixture.archive.playbackTimeline(sessionID: original.sessionID, expectedGeneration: fixture.source.generation)
        let part = try await fixture.archive.acquirePlaybackPart(timeline.parts[1], in: timeline)
        let clip = fixture.archive.rootURL.appendingPathComponent("priming-clipped.caf")
        try PlaybackPCMReader(part: part).writeClip(to: clip, check: {})
        XCTAssertEqual(try AVAudioFile(forReading: clip).length, original.decodedFrameCount - 2_400)
        await fixture.archive.releaseAudioLease(id: part.lease.id)
        try FileManager.default.removeItem(at: clip)
    }

    func testSystemNotificationsPauseWithoutAutoResumeAndDeletedTargetCannotRevive() async throws {
        let fixture = try await makeRecording()
        let playback = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await playback.stop() }
        let notifications: [(Notification.Name, [String: Any])] = [
            (AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]),
            (AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]),
            (AVAudioSession.mediaServicesWereResetNotification, [:])
        ]
        for (name, info) in notifications {
            try await playback.play(fixture.source)
            try await Task.sleep(for: .milliseconds(120))
            NotificationCenter.default.post(name: name, object: AVAudioSession.sharedInstance(), userInfo: info)
            try await waitForPlayer(playback, state: .paused)
            let position = try XCTUnwrap(playback.snapshot?.position)
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                           AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(playback.snapshot?.state, .paused)
            XCTAssertEqual(playback.snapshot?.position, position)
        }
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path), "Paused playback must release its file lease.")
        do { try await playback.resume(); XCTFail("Deleted audio must not resume.") }
        catch ArchiveError.sessionDeleted(let id) { XCTAssertEqual(id, fixture.source.sessionID) }
        XCTAssertNil(playback.snapshot)
    }

    func testMissingTailEndsAtLastActuallyPlayedPositionAndCannotSeekIntoTail() async throws {
        let fixture = try await makeRecording()
        let lease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let original = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        let next = try ManifestEnvelope(manifest: ChunkManifest(sessionID: original.sessionID, epochID: original.epochID,
            sourceDeviceID: original.sourceDeviceID, sourceBuild: "playback-missing-tail", sequence: 1,
            frames: FrameRange(start: original.frames.end, count: original.frames.count), timebaseHz: original.timebaseHz,
            wallClockAnchor: original.wallClockAnchor, timezoneOffset: original.timezoneOffset,
            codec: original.codec, sampleRate: original.sampleRate, channels: original.channels,
            decodedFrameCount: original.decodedFrameCount, byteCount: original.byteCount,
            audioSHA256: original.audioSHA256, sourceKind: .fixture))
        try await deliverPlaybackCopy(next, audio: fixture.audioURL, archive: fixture.archive)
        let missing = try await fixture.archive.acquireAudioLease(chunkID: next.manifest.chunkID)
        await fixture.archive.releaseAudioLease(id: missing.id)
        try FileManager.default.removeItem(at: missing.audioURL)
        let duration = Double(original.frames.count) / original.timebaseHz
        let playback = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await playback.stop() }
        try await playback.playRecording(sessionID: original.sessionID, generation: fixture.source.generation)
        try await playback.seek(to: duration - 0.2)
        try await waitForPlayer(playback, state: .ended)
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.position), duration, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.duration), duration * 2, accuracy: 0.001)
        do { try await playback.seek(to: duration * 2); XCTFail("Missing tail must not be seekable, including its endpoint.") }
        catch PlaybackError.unavailable {}
        XCTAssertEqual(try XCTUnwrap(playback.snapshot?.position), duration, accuracy: 0.001)
    }

    func testDifferentTimebaseMapsToDecodedSamplesAndExcludesPriming() async throws {
        let fixture = try await makeRecording()
        let lease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let original = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        let next = try ManifestEnvelope(manifest: ChunkManifest(sessionID: original.sessionID, epochID: UUID(),
            sourceDeviceID: original.sourceDeviceID, sourceBuild: "playback-timebase-fixture", sequence: 0,
            frames: FrameRange(start: 3_200, count: (original.decodedFrameCount - 2_400) * 2), timebaseHz: original.sampleRate * 2,
            wallClockAnchor: original.wallClockAnchor.addingTimeInterval(60), timezoneOffset: original.timezoneOffset,
            codec: original.codec, sampleRate: original.sampleRate, channels: original.channels,
            decodedFrameCount: original.decodedFrameCount, primingFrames: 1_600, paddingFrames: 800,
            byteCount: original.byteCount, audioSHA256: original.audioSHA256, sourceKind: .fixture))
        try await deliverPlaybackCopy(next, audio: fixture.audioURL, archive: fixture.archive)
        let archived = try await fixture.archive.playbackTimeline(sessionID: original.sessionID, expectedGeneration: fixture.source.generation)
        let part = try await fixture.archive.acquirePlaybackPart(archived.parts[1], in: archived)
        let output = fixture.archive.rootURL.appendingPathComponent("timebase-exact.caf")
        try PlaybackPCMReader(part: part).writeClip(to: output, check: {})
        let clip = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(clip.length, original.decodedFrameCount - 2_400)
        let originalFile = try AVAudioFile(forReading: fixture.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        originalFile.framePosition = 1_600
        let actual = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: clip.processingFormat, frameCapacity: 512))
        let expected = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: originalFile.processingFormat, frameCapacity: 512))
        try clip.read(into: actual, frameCount: 512)
        try originalFile.read(into: expected, frameCount: 512)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: try XCTUnwrap(actual.floatChannelData)[0], count: 512)),
                       Array(UnsafeBufferPointer(start: try XCTUnwrap(expected.floatChannelData)[0], count: 512)))
        await fixture.archive.releaseAudioLease(id: part.lease.id)
        try FileManager.default.removeItem(at: output)
        let timeline = PlaybackTimeline(archived)
        XCTAssertEqual(timeline.segments[1].end - timeline.segments[1].start,
                       Double(original.decodedFrameCount - 2_400) / original.sampleRate, accuracy: 0.0001)
    }

    func testWaveformIsDecodedFromTheExactRangeAndCacheDoesNotMaskMissingAudio() async throws {
        let fixture = try await makeRecording()
        let playback = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await playback.stop() }
        let target = AudioPlaybackTarget.transcript(fixture.source)
        let first = try await playback.preview(for: target)
        let second = try await playback.preview(for: target)
        XCTAssertNil(playback.snapshot, "Previews must never start or replace playback.")
        XCTAssertEqual(first.waveform, second.waveform)
        XCTAssertEqual(first.waveform.count, 512)
        XCTAssertGreaterThan(first.waveform.max() ?? 0, 0.01)
        XCTAssertGreaterThan((first.waveform.max() ?? 0) - (first.waveform.min() ?? 0), 0.01)
        let file = try AVAudioFile(forReading: fixture.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024))
        var squares = 0.0
        var count = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in 0..<Int(buffer.frameLength) { squares += Double(samples[index]) * Double(samples[index]); count += 1 }
        }
        let actualRMS = sqrt(squares / Double(count))
        let renderedRMS = sqrt(first.waveform.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(first.waveform.count))
        XCTAssertEqual(renderedRMS, actualRMS, accuracy: 0.002)
        try Data("external corruption".utf8).write(to: fixture.audioURL)
        do { _ = try await playback.preview(for: target); XCTFail("A cache hit must not conceal a corrupted original.") }
        catch ArchiveError.missingRecording {}
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    func testTimelineAcrossSessionsUsesNativeSeekAndValidatesEverySource() async throws {
        let fixture = try await makeRecording()
        let lease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let original = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        let base = floor(original.wallClockAnchor.timeIntervalSince1970 / 1_800) * 1_800 - 3_600
        var ids: [UUID] = []
        for index in 0..<2 {
            let id = UUID(); ids.append(id)
            let manifest = try ChunkManifest(sessionID: id, epochID: UUID(), sourceDeviceID: original.sourceDeviceID,
                sourceBuild: "timeline-playback-fixture", sequence: 0, frames: original.frames,
                timebaseHz: original.timebaseHz, wallClockAnchor: Date(timeIntervalSince1970: base + 60 + Double(index) * 60),
                timezoneOffset: original.timezoneOffset, codec: original.codec, sampleRate: original.sampleRate,
                channels: original.channels, decodedFrameCount: original.decodedFrameCount, byteCount: original.byteCount,
                audioSHA256: original.audioSHA256, sourceKind: .fixture)
            try await deliverPlaybackCopy(ManifestEnvelope(manifest: manifest), audio: fixture.audioURL, archive: fixture.archive)
        }
        let day = TimelineDay(Date(timeIntervalSince1970: base + Double(original.timezoneOffset)), calendar: TimelineDay.calendar)
        let windows = try await fixture.archive.timelineDay(day)
        let window = try XCTUnwrap(windows.first { Set($0.sources.map(\.sessionID)) == Set(ids) })
        let target = AudioPlaybackTarget.window(window.id, window.sources)
        let controller = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await controller.stop() }
        let preview = try await controller.preview(for: target)
        let memberDuration = Double(original.frames.count) / original.timebaseHz
        XCTAssertEqual(try XCTUnwrap(preview.duration), memberDuration * 2, accuracy: 0.001)
        XCTAssertEqual(preview.waveform.count, 512)
        XCTAssertTrue(preview.gaps.isEmpty, "Unrecorded wall-clock intervals are omitted, rather than fabricated as audio.")
        try await controller.play(target)
        await controller.pause()
        try await controller.seek(to: memberDuration + 1)
        XCTAssertEqual(controller.snapshot?.state, .paused)
        XCTAssertEqual(try XCTUnwrap(controller.snapshot?.position), memberDuration + 1, accuracy: 0.001)
        try await controller.resume()
        XCTAssertEqual(controller.snapshot?.state, .playing)
        _ = try await fixture.archive.deleteSession(id: ids[0])
        do { try await controller.seek(to: memberDuration + 2); XCTFail("A deleted member must invalidate the frozen target.") }
        catch ArchiveError.sessionDeleted {}
        XCTAssertNil(controller.snapshot)
    }

    func testWindowMissingUnreceivedTailRejectsItsEndpointWithoutChangingPosition() async throws {
        let fixture = try await makeFixedTimelineRecording()
        let manifest = fixture.manifest
        try await fixture.archive.markEpochClosed(epochID: manifest.epochID, endFrame: manifest.frames.end * 2)
        let windowValue = try await fixture.archive.timelineWindow(containing: fixture.source)
        let window = try XCTUnwrap(windowValue)
        XCTAssertEqual(window.state, .waitingForSync)
        let controller = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await controller.stop() }
        let target = try XCTUnwrap(controller.target(for: window))
        try await controller.play(target)
        await controller.pause()
        try await controller.seek(to: 1)
        let before = try XCTUnwrap(controller.snapshot)
        let duration = try XCTUnwrap(before.duration)
        let available = Double(manifest.frames.count) / manifest.timebaseHz
        XCTAssertEqual(duration, available * 2, accuracy: 0.0001)
        XCTAssertEqual(before.seekableRanges.last?.upperBound, available)
        XCTAssertTrue(before.gaps.contains { $0.lowerBound == available && $0.upperBound == duration })
        do { try await controller.seek(to: duration); XCTFail("An unreceived tail endpoint cannot be treated as available audio.") }
        catch PlaybackError.unavailable { }
        XCTAssertEqual(controller.snapshot?.position, before.position)
        XCTAssertEqual(controller.snapshot?.state, .paused)
        await controller.stop()
    }

    func testTimelineParagraphToggleResumesTheSameExactClipInsteadOfRestarting() async throws {
        let fixture = try await makeRecording(frames: FrameRange(start: 16_000, count: 32_000))
        let controller = AudioPlaybackController(archive: fixture.archive)
        addTeardownBlock { await controller.stop() }
        try await controller.playRecording(sessionID: fixture.source.sessionID, generation: fixture.source.generation)
        try await controller.toggle(fixture.source)
        XCTAssertEqual(controller.snapshot?.target, .transcript(fixture.source))
        XCTAssertEqual(try XCTUnwrap(controller.snapshot?.duration), 2, accuracy: 0.0001)
        try await controller.toggle(fixture.source)
        XCTAssertEqual(controller.snapshot?.state, .paused)
        try await controller.seek(to: 0.8)
        try await controller.toggle(fixture.source)
        XCTAssertEqual(controller.snapshot?.state, .playing)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(controller.snapshot?.position), 0.8,
                                    "The paragraph's second play action must continue from its actual paused position.")
        XCTAssertEqual(try XCTUnwrap(controller.snapshot?.duration), 2, accuracy: 0.0001)
        try await controller.toggle(fixture.source)
        XCTAssertEqual(controller.snapshot?.state, .paused)
        await controller.stop()
    }

    func testWindowTargetStaysFrozenOnAppendAndRefreshesOnlyAfterStaleFailureAndExplicitPlay() async throws {
        let fixture = try await makeFixedTimelineRecording()
        let archive = fixture.archive, manifest = fixture.manifest
        let initialValue = try await archive.timelineWindow(containing: fixture.source)
        let initial = try XCTUnwrap(initialValue)
        let controller = AudioPlaybackController(archive: archive)
        addTeardownBlock { await controller.stop() }
        let originalTarget = try XCTUnwrap(controller.target(for: initial))
        try await controller.play(originalTarget)
        await controller.pause()
        let originalDuration = try XCTUnwrap(controller.snapshot?.duration)
        let appended = try ManifestEnvelope(manifest: ChunkManifest(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "timeline-frozen-append", sequence: 1,
            frames: FrameRange(start: manifest.frames.end, count: manifest.frames.count), timebaseHz: manifest.timebaseHz,
            wallClockAnchor: manifest.wallClockAnchor, timezoneOffset: manifest.timezoneOffset,
            codec: manifest.codec, sampleRate: manifest.sampleRate, channels: manifest.channels,
            decodedFrameCount: manifest.decodedFrameCount, byteCount: manifest.byteCount,
            audioSHA256: manifest.audioSHA256, sourceKind: .fixture))
        try await deliverPlaybackCopy(appended, audio: fixture.audioURL, archive: archive)
        let grownValue = try await archive.timelineWindow(initial.id)
        let grown = try XCTUnwrap(grownValue)
        XCTAssertNotEqual(grown.sources, initial.sources)
        XCTAssertEqual(controller.target(for: grown), originalTarget)
        XCTAssertEqual(controller.snapshot?.duration, originalDuration)

        let old = try await archive.readTranscript(sessionID: manifest.sessionID)
        _ = try await archive.reviseTranscript(sessionID: old.sessionID, expectedVersion: old.version, spans: old.spans)
        do { try await controller.resume(); XCTFail("The frozen target cannot survive a member's generation change.") }
        catch ArchiveError.staleSource { }
        XCTAssertEqual(controller.snapshot?.state, .failed)
        XCTAssertFalse(controller.snapshot?.canSeek ?? true)
        let revisedValue = try await archive.timelineWindow(initial.id)
        let revised = try XCTUnwrap(revisedValue)
        let freshTarget = try XCTUnwrap(controller.target(for: revised))
        XCTAssertEqual(freshTarget, .window(revised.id, revised.sources))
        XCTAssertNotEqual(freshTarget, originalTarget)
        XCTAssertEqual(controller.snapshot?.target, originalTarget, "Choosing a refreshed card target must not start audio.")
        XCTAssertEqual(controller.snapshot?.state, .failed)
        try await controller.play(freshTarget)
        XCTAssertEqual(controller.snapshot?.state, .playing)
        XCTAssertEqual(controller.snapshot?.target, freshTarget)
        XCTAssertEqual(try XCTUnwrap(controller.snapshot?.duration), originalDuration * 2, accuracy: 0.0001)
        await controller.stop()
    }

    func testDetailKeepsIntermediateFrozenWindowAfterTwoRegroupingsWithoutBindingOtherRoutes() async throws {
        let fixture = try await makeFixedTimelineRecording()
        let archive = fixture.archive, manifest = fixture.manifest
        let initialValue = try await archive.timelineWindow(containing: fixture.source)
        let initial = try XCTUnwrap(initialValue)
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        let controller = AudioPlaybackController(archive: archive)
        addTeardownBlock { await controller.stop() }
        var scope = TimelineDetailPlaybackScope()
        let route = initial.id
        scope.admit(initial.id, for: route)

        func receiveEarlier(_ seconds: TimeInterval) async throws {
            let earlier = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: manifest.sourceDeviceID,
                sourceBuild: "timeline-detail-regroup", sequence: 0, frames: manifest.frames,
                timebaseHz: manifest.timebaseHz, wallClockAnchor: manifest.wallClockAnchor.addingTimeInterval(-seconds),
                timezoneOffset: manifest.timezoneOffset, codec: manifest.codec, sampleRate: manifest.sampleRate,
                channels: manifest.channels, decodedFrameCount: manifest.decodedFrameCount,
                byteCount: manifest.byteCount, audioSHA256: manifest.audioSHA256, sourceKind: .fixture)
            try await deliverPlaybackCopy(ManifestEnvelope(manifest: earlier), audio: fixture.audioURL, archive: archive)
        }
        try await receiveEarlier(60)
        let secondValue = try await model.loadWindow(route, previous: initial)
        let second = try XCTUnwrap(secondValue).window
        XCTAssertNotEqual(second.id, route)
        scope.admit(second.id, for: route)
        let frozen = try XCTUnwrap(controller.target(for: second))
        try await controller.play(frozen)
        XCTAssertEqual(controller.snapshot?.state, .playing)
        let frozenDuration = try XCTUnwrap(controller.snapshot?.duration)

        try await receiveEarlier(120)
        let thirdValue = try await model.loadWindow(route, previous: second)
        let third = try XCTUnwrap(thirdValue).window
        XCTAssertNotEqual(third.id, route)
        XCTAssertNotEqual(third.id, second.id)
        scope.admit(third.id, for: route)
        XCTAssertEqual(scope.frozenTarget(controller.activeTarget, state: controller.playbackState, for: route), frozen,
                       "The detail must still address B's playing card after its route A has regrouped again to C.")
        XCTAssertEqual(controller.snapshot?.duration, frozenDuration)
        await controller.pause()
        XCTAssertEqual(controller.snapshot?.state, .paused)
        XCTAssertEqual(scope.frozenTarget(controller.activeTarget, state: controller.playbackState, for: route), frozen)
        try await controller.resume()
        XCTAssertEqual(controller.snapshot?.state, .playing)
        XCTAssertEqual(controller.snapshot?.target, frozen)

        var independent = TimelineDetailPlaybackScope()
        independent.admit(third.id, for: third.id)
        XCTAssertTrue(third.sharesSource(with: second.sources))
        XCTAssertNil(independent.frozenTarget(controller.activeTarget, state: controller.playbackState, for: third.id),
                     "Overlapping sources do not bind an independently opened C detail to B's player.")
        XCTAssertNil(scope.frozenTarget(controller.activeTarget, state: controller.playbackState, for: third.id), "Changing the route cannot reuse its old aliases.")

        await controller.pause()
        let old = try await archive.readTranscript(sessionID: manifest.sessionID)
        let revised = try await archive.reviseTranscript(sessionID: old.sessionID, expectedVersion: old.version, spans: old.spans)
        do { try await controller.resume(); XCTFail("B's frozen member generation must still be validated.") }
        catch ArchiveError.staleSource { }
        XCTAssertEqual(controller.snapshot?.state, .failed)
        XCTAssertNil(scope.frozenTarget(controller.activeTarget, state: controller.playbackState, for: route))
        let freshValue = try await archive.timelineWindow(third.id)
        let fresh = try XCTUnwrap(freshValue)
        let freshTarget = try XCTUnwrap(controller.target(for: fresh))
        XCTAssertEqual(freshTarget, .window(fresh.id, fresh.sources))
        XCTAssertEqual(controller.snapshot?.target, frozen, "Resolving a fresh card must not restart audio.")
        try await controller.play(freshTarget)
        XCTAssertEqual(controller.snapshot?.state, .playing)
        XCTAssertEqual(scope.frozenTarget(controller.activeTarget, state: controller.playbackState, for: route), freshTarget)

        try await controller.playRecording(sessionID: manifest.sessionID, generation: revised.generation)
        XCTAssertNil(scope.frozenTarget(controller.activeTarget, state: controller.playbackState, for: route),
                     "An explicit switch to the full recording must not be rebound to the old window card.")
        await controller.stop()
    }

    private func makeFixedTimelineRecording() async throws -> (archive: ArchiveStore, source: SourceReference, audioURL: URL, manifest: ChunkManifest) {
        let fixture = try await makeRecording()
        let lease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let original = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        // Fixed well inside a half-hour avoids making the regression depend on the wall-clock run time.
        let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: original.sourceDeviceID,
            sourceBuild: "timeline-playback-fixed", sequence: 0, frames: original.frames,
            timebaseHz: original.timebaseHz, wallClockAnchor: Date(timeIntervalSince1970: 1_792_023_100),
            timezoneOffset: original.timezoneOffset, codec: original.codec, sampleRate: original.sampleRate,
            channels: original.channels, decodedFrameCount: original.decodedFrameCount,
            byteCount: original.byteCount, audioSHA256: original.audioSHA256, sourceKind: .fixture)
        try await deliverPlaybackCopy(ManifestEnvelope(manifest: manifest), audio: fixture.audioURL, archive: fixture.archive)
        let claimed = try await fixture.archive.claimAnalysisJob(configurationHash: "timeline-playback-fixed")
        let ticket = try XCTUnwrap(claimed)
        XCTAssertEqual(ticket.sessionID, manifest.sessionID)
        let document = try await fixture.archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: manifest.chunkID, frames: manifest.frames, text: "时间窗播放器的公开音频测试夹具。")
        ])
        return (fixture.archive, document.source(for: try XCTUnwrap(document.spans.first)), fixture.audioURL, manifest)
    }

    private func waitForPlayer(_ player: AudioPlaybackController, state: AudioPlaybackState,
                               timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while player.snapshot?.state != state && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.snapshot?.state, state)
    }

    private func deliverPlaybackCopy(_ envelope: ManifestEnvelope, audio: URL, archive: ArchiveStore) async throws {
        let upload = archive.rootURL.appendingPathComponent("playback-upload-\(UUID()).wav")
        try FileManager.default.copyItem(at: audio, to: upload)
        let item = try archive.inbox.preserve(fileURL: upload, envelope: envelope)
        _ = try await archive.commitReceivedChunk(item)
    }
}

private extension ArchiveStore {
    func occupyForPlaybackClockRegression(entered: @Sendable () -> Void) {
        entered()
        Thread.sleep(forTimeInterval: 0.9)
    }
}
