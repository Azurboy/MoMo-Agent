import AVFoundation
import Foundation
import XCTest
@testable import MoMoArchive
import MoMoContracts
@testable import MoMoAgent

@MainActor
final class AudioPlaybackIntegrationTests: XCTestCase {
    func testSelectingPositionBeforePlayValidatesAudioWithoutStartingSound() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe()
        let player = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await player.stop() }
        let target = AudioPlaybackTarget.recording(fixture.source.sessionID, fixture.source.generation)
        try await player.seek(to: 1.5, in: target)
        XCTAssertEqual(player.snapshot?.target, target)
        XCTAssertEqual(player.snapshot?.state, .paused)
        XCTAssertEqual(try XCTUnwrap(player.snapshot?.position), 1.5, accuracy: 0.001)
        XCTAssertFalse(player.playbackRequested)
        XCTAssertEqual(probe.playbackStarts, 0)
        XCTAssertTrue(probe.operations.isEmpty, "Selecting a position must not activate the audio session.")
        try await player.resume()
        XCTAssertEqual(player.snapshot?.state, .playing)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(player.snapshot?.position), 1.5)
    }

    func testExplicitMarkPositionIsAppliedBeforeNativeAudioStarts() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe()
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        try await playback.play(.transcript(fixture.source), from: 2.25)
        XCTAssertEqual(probe.playbackStarts, 1)
        XCTAssertEqual(try XCTUnwrap(probe.positionsAtStart.first), 2.25, accuracy: 1.0 / 16_000)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(playback.snapshot?.position), 2.25)
    }

    func testUnavailableMarkDoesNotSkipToTheNextAvailableAudio() async throws {
        let fixture = try await makeRecording()
        let lease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let original = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: original.sourceDeviceID,
            sourceBuild: "mark-gap", sequence: 1, frames: FrameRange(start: 16_000, count: original.frames.count),
            timebaseHz: 16_000, wallClockAnchor: original.wallClockAnchor, timezoneOffset: original.timezoneOffset,
            codec: original.codec, sampleRate: original.sampleRate, channels: original.channels,
            decodedFrameCount: original.decodedFrameCount, byteCount: original.byteCount,
            audioSHA256: original.audioSHA256, sourceKind: .fixture)
        let upload = fixture.archive.rootURL.appendingPathComponent("marked-gap.wav")
        try FileManager.default.copyItem(at: fixture.audioURL, to: upload)
        _ = try await fixture.archive.commitReceivedChunk(fixture.archive.inbox.preserve(fileURL: upload,
            envelope: ManifestEnvelope(manifest: manifest)))
        let probe = PlaybackSessionProbe()
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        do {
            try await playback.play(.recording(manifest.sessionID, 0), from: 0.5)
            XCTFail("Missing marked audio must not jump forward.")
        } catch PlaybackError.unavailable { }
        XCTAssertEqual(probe.playbackStarts, 0)
        XCTAssertTrue(probe.operations.isEmpty)
        XCTAssertEqual(playback.playbackState, .failed)
    }

    func testWholeRecordingWithoutTranscriptPagesNativePlaybackAndReleasesFinishedAudio() async throws {
        let fixture = try await makeRecording()
        let original = try await fixture.archive.readTranscript(sessionID: fixture.source.sessionID)
        let empty = try await fixture.archive.reviseTranscript(sessionID: original.sessionID,
            expectedVersion: original.version, spans: [])
        let lease = try await fixture.archive.acquireAudioLease(chunkID: original.spans[0].chunkID)
        let manifest = lease.manifest
        await fixture.archive.releaseAudioLease(id: lease.id)
        let next = try ManifestEnvelope(manifest: ChunkManifest(sessionID: manifest.sessionID, epochID: UUID(), chunkID: UUID(),
            sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "native-playback-fixture", sequence: 0,
            frames: manifest.frames, timebaseHz: manifest.timebaseHz,
            wallClockAnchor: manifest.wallClockAnchor.addingTimeInterval(60), timezoneOffset: manifest.timezoneOffset,
            codec: manifest.codec, sampleRate: manifest.sampleRate, channels: manifest.channels,
            decodedFrameCount: manifest.decodedFrameCount, byteCount: manifest.byteCount,
            audioSHA256: manifest.audioSHA256, sourceKind: .fixture))
        let upload = fixture.archive.rootURL.appendingPathComponent("second-playback-upload.wav")
        try FileManager.default.copyItem(at: fixture.audioURL, to: upload)
        let item = try fixture.archive.inbox.preserve(fileURL: upload, envelope: next)
        _ = try await fixture.archive.commitReceivedChunk(item)
        for receipt in try await fixture.archive.pendingReceipts() {
            try await fixture.archive.applyReceipt(ReceiptApplied(receipt: receipt))
        }
        let probe = PlaybackSessionProbe()
        probe.playbackStarted.expectedFulfillmentCount = 2
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        try await playback.playRecording(sessionID: manifest.sessionID, generation: empty.generation)
        XCTAssertEqual(playback.playingRecordingID, manifest.sessionID)
        XCTAssertNil(playback.playingSpanID, "Whole-recording playback must not manufacture a transcript source.")
        await fulfillment(of: [probe.playbackStarted], timeout: 15)
        XCTAssertEqual(probe.playbackStarts, 2)
        // The start callback and the old segment's archive cleanup use separate queues.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var released = false
        repeat {
            let leases = await fixture.archive.audioLeases
            released = !leases.values.contains(manifest.chunkID)
            if !released { try await Task.sleep(for: .milliseconds(20)) }
        } while !released && ContinuousClock.now < deadline
        XCTAssertTrue(released, "A finished segment must release its lease while the next segment plays.")
        // Automatic cleanup protects the entire playing recording, including future pages and seeking.
        let expired = try await fixture.archive.applyRetention(now: manifest.sealedAt.addingTimeInterval(8 * 86_400),
            replayFloors: [manifest.epochID: manifest.frames.end])
        XCTAssertTrue(expired.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertEqual(playback.playingRecordingID, manifest.sessionID)
        XCTAssertNil(playback.failure)
        let second = try await fixture.archive.acquireAudioLease(chunkID: next.manifest.chunkID)
        await fixture.archive.releaseAudioLease(id: second.id)
        _ = try await fixture.archive.deleteSession(id: manifest.sessionID)
        // Explicit deletion retains the directory until its final active reader finishes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.audioURL.path))
        await playback.stop()
        XCTAssertNil(playback.playingRecordingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.audioURL.path))
    }

    func testStopDuringPreparationWaitsForNativeCleanupBeforeReleasingLease() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockPreparation: true)
        defer { probe.releasePreparation() }
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        let starting = Task { try await playback.playRecording(sessionID: fixture.source.sessionID, generation: fixture.source.generation) }
        await fulfillment(of: [probe.preparationEntered], timeout: 5)
        let stopEntered = expectation(description: "Stop entered while native preparation is pending")
        let stopping = Task { stopEntered.fulfill(); await playback.stop() }
        await fulfillment(of: [stopEntered], timeout: 5)
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertNil(playback.playingSpanID)
        XCTAssertNil(playback.playingRecordingID)
        probe.releasePreparation()
        do { try await starting.value; XCTFail("Stopped preparation must not begin playback.") }
        catch is CancellationError {}
        await stopping.value
        XCTAssertEqual(probe.playbackStarts, 0)
        XCTAssertEqual(probe.operations, [.activate, .deactivate])
        XCTAssertFalse(probe.ranOnMainThread)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    func testCancellationDuringPreparationDoesNotStartThePlayerAndReleasesLease() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockPreparation: true)
        defer { probe.releasePreparation() }
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        let starting = Task { try await playback.play(fixture.source) }
        await fulfillment(of: [probe.preparationEntered], timeout: 5)
        starting.cancel()
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        probe.releasePreparation()
        do { try await starting.value; XCTFail("Cancelled preparation must not begin playback.") }
        catch is CancellationError {}
        XCTAssertNil(playback.playingSpanID)
        XCTAssertEqual(probe.playbackStarts, 0)
        XCTAssertEqual(probe.operations, [.activate, .deactivate])
        XCTAssertFalse(probe.ranOnMainThread)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    func testNewPlayDuringPreparationCannotBeStoppedByTheOldAttempt() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockPreparation: true)
        defer { probe.releasePreparation() }
        let owner = probe.owner()
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: owner)
        addTeardownBlock { await playback.stop() }
        let first = Task { try await playback.play(fixture.source) }
        await fulfillment(of: [probe.preparationEntered], timeout: 5)
        let replacementEntered = expectation(description: "Replacement entered while old preparation is pending")
        let second = Task { replacementEntered.fulfill(); try await playback.play(fixture.source) }
        await fulfillment(of: [replacementEntered], timeout: 5)
        probe.releasePreparation()
        do { try await first.value; XCTFail("Replaced preparation must not begin playback.") }
        catch is CancellationError {}
        try await second.value
        try await owner.deactivate(for: 1)
        let progress = try await owner.progress(for: 2)
        XCTAssertTrue(progress.isPlaying)
        XCTAssertEqual(playback.playingSpanID, fixture.source.spanID)
        XCTAssertEqual(probe.playbackStarts, 1)
        XCTAssertEqual(probe.preparations, 2)
        XCTAssertEqual(probe.operations, [.activate, .deactivate, .activate])
        XCTAssertFalse(probe.ranOnMainThread)
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        await playback.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    func testStopBeforeActivationCompletesReleasesItsLeaseWithoutStartingPlayback() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockActivation: true)
        defer { probe.releaseActivation() }
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        let starting = Task { try await playback.play(fixture.source) }
        await fulfillment(of: [probe.activationEntered], timeout: 5)
        let stopEntered = expectation(description: "Stop entered before activation completed")
        let stopping = Task { stopEntered.fulfill(); await playback.stop() }
        await fulfillment(of: [stopEntered], timeout: 5)
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        probe.releaseActivation()
        do { try await starting.value; XCTFail("A stopped activation must not begin playback.") }
        catch is CancellationError {}
        await stopping.value
        XCTAssertNil(playback.playingSpanID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertEqual(probe.operations, [.activate, .deactivate])
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testNewPlayDuringOldDeactivationKeepsTheNewPlayerAndLease() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockDeactivation: true)
        defer { probe.releaseDeactivation() }
        let owner = probe.owner()
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: owner)
        addTeardownBlock { await playback.stop() }
        try await playback.play(fixture.source)
        let stopping = Task { await playback.stop() }
        await fulfillment(of: [probe.deactivationEntered], timeout: 5)
        let secondPlayEntered = expectation(description: "Second play entered while old cleanup is pending")
        let starting = Task {
            secondPlayEntered.fulfill()
            try await playback.play(fixture.source)
        }
        await fulfillment(of: [secondPlayEntered], timeout: 5)
        probe.releaseDeactivation()
        try await starting.value
        await stopping.value
        // An old stop arriving after the new activation cannot deactivate the current owner.
        try await owner.deactivate(for: 1)
        XCTAssertEqual(probe.operations, [.activate, .deactivate, .activate])
        XCTAssertEqual(playback.playingSpanID, fixture.source.spanID)
        XCTAssertNil(playback.failure)
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        await playback.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertEqual(probe.operations, [.activate, .deactivate, .activate, .deactivate])
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testCancellationDuringActivationCleansTheSessionAndLease() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockActivation: true)
        defer { probe.releaseActivation() }
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        let starting = Task { try await playback.play(fixture.source) }
        await fulfillment(of: [probe.activationEntered], timeout: 5)
        starting.cancel()
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        probe.releaseActivation()
        do { try await starting.value; XCTFail("Cancelled activation must not begin playback.") }
        catch is CancellationError {}
        XCTAssertNil(playback.playingSpanID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertEqual(probe.operations, [.activate, .deactivate])
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testActivationFailureReleasesLeaseAndDeactivatesItsAttempt() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(failActivation: true)
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        do { try await playback.play(fixture.source); XCTFail("Expected injected activation failure.") }
        catch PlaybackSessionProbe.Failure.activation {}
        XCTAssertNil(playback.playingSpanID)
        XCTAssertEqual(probe.operations, [.activate, .deactivate])
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testPlayerCreationFailureAfterActivationReleasesLeaseAndSession() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockActivation: true)
        defer { probe.releaseActivation() }
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        let starting = Task { try await playback.play(fixture.source) }
        await fulfillment(of: [probe.activationEntered], timeout: 5)
        // The lease is already validated; simulate a Files edit before AVAudioPlayer opens its source.
        try Data("invalid audio".utf8).write(to: fixture.audioURL)
        probe.releaseActivation()
        let result = await starting.result
        if case .success = result { XCTFail("AVAudioPlayer must reject the damaged file.") }
        XCTAssertNil(playback.playingSpanID)
        XCTAssertEqual(probe.operations, [.activate, .deactivate])
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertFalse(probe.ranOnMainThread)
    }

    // This fixture supplies a transcript to test native playback and leases. It does not exercise ASR.
    func testDeletionStopsNativePlaybackAndExplicitStopWaitsForLeaseCleanup() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe(blockDeactivation: true)
        defer { probe.releaseDeactivation() }
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }

        try await playback.play(fixture.source)
        XCTAssertEqual(playback.playingSpanID, fixture.source.spanID)
        XCTAssertNil(playback.failure)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(playback.playingSpanID, fixture.source.spanID,
                       "The real audio must still be playing after one second.")
        XCTAssertNil(playback.failure)

        // With no other reader, deferred physical deletion proves the player owns an Archive lease.
        _ = try await fixture.archive.deleteSession(id: fixture.source.sessionID)
        let recordings = try await fixture.archive.recordings()
        XCTAssertTrue(recordings.isEmpty)
        // The live identity barrier stops a deleted target; native cleanup is deliberately held
        // after player.stop(), before session deactivation and Archive lease release complete.
        await fulfillment(of: [probe.deactivationEntered], timeout: 5)
        XCTAssertNil(playback.snapshot)
        XCTAssertNil(playback.playingSpanID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path),
                      "Deletion must preserve the file until native cleanup releases its lease.")

        let stopEntered = expectation(description: "Explicit stop entered during deletion cleanup")
        var stopReturned = false
        let stopping = Task {
            stopEntered.fulfill()
            await playback.stop()
            stopReturned = true
        }
        await fulfillment(of: [stopEntered], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(stopReturned, "Close must join the cleanup already started by the deletion barrier.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        probe.releaseDeactivation()
        await stopping.value
        XCTAssertTrue(stopReturned)
        XCTAssertNil(playback.playingSpanID)
        XCTAssertNil(playback.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path),
                       "Stopping must release the lease and finish pending audio deletion.")
        XCTAssertEqual(probe.operations, [.activate, .deactivate])
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testInterruptionDuringInitialPreparationAfterMissingPrefixCanResume() async throws {
        let fixture = try await makeRecording()
        let originalLease = try await fixture.archive.acquireAudioLease(source: fixture.source)
        let original = originalLease.manifest
        await fixture.archive.releaseAudioLease(id: originalLease.id)
        let sessionID = UUID()
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: sessionID, epochID: UUID(),
            sourceDeviceID: original.sourceDeviceID, sourceBuild: "missing-prefix-playback", sequence: 1,
            frames: FrameRange(start: 16_000, count: original.frames.count), timebaseHz: 16_000,
            wallClockAnchor: original.wallClockAnchor, timezoneOffset: original.timezoneOffset,
            codec: original.codec, sampleRate: original.sampleRate, channels: original.channels,
            decodedFrameCount: original.decodedFrameCount, byteCount: original.byteCount,
            audioSHA256: original.audioSHA256, sourceKind: .fixture))
        let upload = fixture.archive.rootURL.appendingPathComponent("missing-prefix-upload.wav")
        try FileManager.default.copyItem(at: fixture.audioURL, to: upload)
        _ = try await fixture.archive.commitReceivedChunk(fixture.archive.inbox.preserve(fileURL: upload, envelope: envelope))
        let probe = PlaybackSessionProbe(blockActivation: true)
        defer { probe.releaseActivation() }
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }
        let starting = Task { try await playback.playRecording(sessionID: sessionID, generation: 0) }
        await fulfillment(of: [probe.activationEntered], timeout: 5)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while playback.snapshot?.state != .paused && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(playback.snapshot?.state, .paused)
        XCTAssertEqual(playback.snapshot?.position, 1)
        probe.releaseActivation()
        do { try await starting.value; XCTFail("Interrupted preparation must not start sound.") }
        catch is CancellationError {}
        XCTAssertEqual(probe.playbackStarts, 0)
        try await playback.resume()
        XCTAssertEqual(playback.snapshot?.state, .playing)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(playback.snapshot?.position), 1)
    }

    func testSpeakerAttributionUpdateAllowsPlaybackAndResumeWhileTextEditInvalidates() async throws {
        let fixture = try await makeRecording()
        let probe = PlaybackSessionProbe()
        let playback = AudioPlaybackController(archive: fixture.archive, audioSession: probe.owner())
        addTeardownBlock { await playback.stop() }

        try await playback.play(.transcript(fixture.source))
        await playback.pause()
        XCTAssertEqual(playback.snapshot?.state, .paused)

        // Updating speaker attribution bumps transcriptVersion without altering audio frames or text.
        try await fixture.archive.correctSpeakers([fixture.source], feedback: .person("小李"), scope: .selection, deferGlobalRematch: true)

        try await playback.resume()
        XCTAssertEqual(playback.snapshot?.state, .playing)

        // Starting playback again from the older pre-speaker-edit citation also resolves cleanly.
        try await playback.play(.transcript(fixture.source), from: 0.5)
        await playback.pause()

        // Revising the actual transcript text must still reject resume with staleSource.
        let latest = try await fixture.archive.readTranscript(sessionID: fixture.source.sessionID)
        let latestSpan = try XCTUnwrap(latest.spans.first)
        let editedSpan = TranscriptSpan(
            id: latestSpan.id,
            chunkID: latestSpan.chunkID,
            frames: latestSpan.frames,
            text: "已被修改的文本内容",
            speaker: latestSpan.speaker,
            sourceRanges: latestSpan.sourceRanges,
            attribution: latestSpan.attribution,
            startsNewSpeakerTurn: latestSpan.startsNewSpeakerTurn
        )
        _ = try await fixture.archive.reviseTranscript(
            sessionID: latest.sessionID,
            expectedVersion: latest.version,
            spans: [editedSpan]
        )

        do {
            try await playback.resume()
            XCTFail("Expected staleSource after transcript text edit")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .staleSource)
        }
    }

    func makeRecording(frames: FrameRange? = nil) async throws -> (archive: ArchiveStore, source: SourceReference, audioURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoPlayback-\(UUID())", isDirectory: true)
        let runID = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let controls = try ControlInbox(directory: root.appendingPathComponent("Controls", isDirectory: true))
        let fixture = PhoneUITestConfiguration(runID: runID, rootURL: root, importFixture: true)
        let bundle = Bundle(for: AudioPlaybackIntegrationTests.self)
        try fixture.stage(in: archive, controls: controls, bundle: bundle)
        let received = try await archive.processInbox()
        XCTAssertEqual(received.count, 1)
        guard let result = received.first, case .accepted = try result.result.get() else {
            throw PlaybackFixtureError.notAccepted
        }
        let claimed = try await archive.claimAnalysisJob(configurationHash: "native-playback-fixture")
        let ticket = try XCTUnwrap(claimed)
        let audio = try AVAudioFile(forReading: ticket.audioURL)
        XCTAssertGreaterThan(Double(audio.length) / audio.processingFormat.sampleRate, 3)
        XCTAssertEqual(try ContentHash.sha256(fileAt: ticket.audioURL), PhoneTranscriptionFixture.officialWAVSHA256)
        let document = try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: frames ?? ticket.manifest.frames,
                           text: "回放测试夹具，不代表自动转写结果。")
        ])
        let span = try XCTUnwrap(document.spans.first)
        let location = XCTAttachment(string: "Playback-only fixture; no ASR. Evidence directory: \(root.path)")
        location.name = "playback-evidence-directory"
        location.lifetime = .keepAlways
        add(location)
        return (archive, document.source(for: span), ticket.audioURL)
    }
}

private enum PlaybackFixtureError: Error { case notAccepted }

/// Test gates wrap real AVAudioSession operations; successful activation is never faked.
private final class PlaybackSessionProbe: @unchecked Sendable {
    enum Operation: Equatable { case activate, deactivate }
    enum Failure: Error { case activation, gateTimedOut }
    let activationEntered = XCTestExpectation(description: "Blocking activation entered")
    let deactivationEntered = XCTestExpectation(description: "Blocking deactivation entered")
    let preparationEntered = XCTestExpectation(description: "Real player prepared before blocked completion")
    let playbackStarted = XCTestExpectation(description: "Native player started")
    private let activationGate = DispatchSemaphore(value: 0)
    private let deactivationGate = DispatchSemaphore(value: 0)
    private let preparationGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blockActivation: Bool
    private let blockDeactivation: Bool
    private let failActivation: Bool
    private let blockPreparation: Bool
    private var recorded: [Operation] = []
    private var mainThread = false
    private var preparedPlayers = 0
    private var startedPlayers = 0
    private var startPositions: [TimeInterval] = []

    init(blockActivation: Bool = false, blockDeactivation: Bool = false,
         failActivation: Bool = false, blockPreparation: Bool = false) {
        self.blockActivation = blockActivation
        self.blockDeactivation = blockDeactivation
        self.failActivation = failActivation
        self.blockPreparation = blockPreparation
        playbackStarted.assertForOverFulfill = false
    }

    var operations: [Operation] { lock.withLock { recorded } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }
    var preparations: Int { lock.withLock { preparedPlayers } }
    var playbackStarts: Int { lock.withLock { startedPlayers } }
    var positionsAtStart: [TimeInterval] { lock.withLock { startPositions } }
    func releaseActivation() { activationGate.signal() }
    func releaseDeactivation() { deactivationGate.signal() }
    func releasePreparation() { preparationGate.signal() }

    func owner() -> PlaybackAudioSession {
        PlaybackAudioSession(activate: { [self] in try activate() },
                             deactivate: { [self] in try deactivate() },
                             prepare: { [self] in try prepare($0) },
                             start: { [self] in start($0) })
    }

    private func record(_ operation: Operation) -> Bool {
        lock.withLock {
            let first = !recorded.contains(operation)
            recorded.append(operation)
            mainThread = mainThread || Thread.isMainThread
            return first
        }
    }

    private func activate() throws {
        let first = record(.activate)
        if first, blockActivation {
            activationEntered.fulfill()
            guard activationGate.wait(timeout: .now() + 5) == .success else { throw Failure.gateTimedOut }
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        if first, failActivation { throw Failure.activation }
    }

    private func deactivate() throws {
        let first = record(.deactivate)
        if first, blockDeactivation {
            deactivationEntered.fulfill()
            guard deactivationGate.wait(timeout: .now() + 5) == .success else { throw Failure.gateTimedOut }
        }
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func prepare(_ player: AVAudioPlayer) throws -> Bool {
        let first = lock.withLock {
            preparedPlayers += 1
            mainThread = mainThread || Thread.isMainThread
            return preparedPlayers == 1
        }
        let prepared = player.prepareToPlay()
        if first, blockPreparation {
            preparationEntered.fulfill()
            guard preparationGate.wait(timeout: .now() + 5) == .success else { throw Failure.gateTimedOut }
        }
        return prepared
    }

    private func start(_ player: AVAudioPlayer) -> Bool {
        lock.withLock {
            startedPlayers += 1
            startPositions.append(player.currentTime)
            mainThread = mainThread || Thread.isMainThread
        }
        let started = player.play()
        if started { playbackStarted.fulfill() }
        return started
    }
}
