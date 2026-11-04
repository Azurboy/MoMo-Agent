import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct BacklogProcessingTests {
    let fingerprint = ContentHash.sha256(Data("bounded-backlog-tests".utf8))

    @Test func inactiveReceivedSnapshotFinishesWithoutForgingEndAndLateAudioContinues() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let old = Date().addingTimeInterval(-86_400)
        let first = try fixture.envelope(sealedAt: old)
        _ = try await store.commitReceivedChunk(fixture.deliver(first, to: store))
        let live = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(!live.epochClosed)
        try await store.commitAnalysisBatch(ticket: live, windows: [], analyzedCoverage: [], noSpeechCoverage: [],
            checkpoint: nil, waitingForMoreAudio: true)
        #expect(try await store.claimEpochAnalysis(configurationFingerprint: fingerprint) == nil)
        let snapshot = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
            finalizeAvailablePrefixBefore: Date().addingTimeInterval(-1_800)))
        #expect(snapshot.epochClosed)
        try await complete(snapshot, store: store)
        let coverage = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(coverage.processedDuration == 0.1)
        #expect(coverage.epochs.first?.closedAtFrame == nil)
        #expect(coverage.epochs.first?.unknownTailFromFrame == 1_600)
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint) == .idle,
                "A processed received prefix needs no capture-end event.")
        let day = TimelineDay(first.manifest.wallClockAnchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let progress = try await store.timelineDaySnapshot(day, configurationFingerprint: fingerprint).progress
        #expect(progress.received == 0.1 && progress.processed == 0.1 && progress.remaining == 0)
        let next = try fixture.envelope(startFrame: 1_600, sequence: 1, sealedAt: old)
        _ = try await store.commitReceivedChunk(fixture.deliver(next, to: store))
        let continuation = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
            finalizeAvailablePrefixBefore: Date().addingTimeInterval(-1_800)))
        #expect(continuation.checkpoint?.sourceFrame == 1_600)
        try await complete(continuation, store: store)
        #expect(try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).processedDuration == 0.2)
        try await store.receiveEpochEnd(CaptureEpochEnded(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, endFrame: 3_200, reason: .stopped))
        #expect(try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: nil).epochs.first?.closedAtFrame == 3_200)
    }

    @Test func longBacklogClaimsOnlyTheNextTwoMinutesAndCancellationReleasesItsLeases() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let audio = wav(frames: 960_000)
        for index in 0..<5 {
            let manifest = try ChunkManifest(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceDeviceID: fixture.deviceID,
                sourceBuild: "backlog-test", sequence: Int64(index), frames: FrameRange(start: Int64(index) * 960_000, count: 960_000),
                timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 28_800,
                codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 960_000,
                byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture)
            _ = try await store.commitReceivedChunk(fixture.deliver(ManifestEnvelope(manifest: manifest), to: store, audio: audio))
        }
        let before = await store.audioContentValidationCount
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
            finalizeAvailablePrefixBefore: .distantFuture))
        #expect(ticket.boundary == .open, "A two-minute read budget is not the end of the received recording.")
        #expect(ticket.inputs.count == 2)
        #expect(ticket.inputs.last?.envelope.manifest.frames.end == 1_920_000)
        #expect(await store.audioContentValidationCount - before == 2)
        #expect(await store.audioLeases.count == 2)
        try await store.cancelEpochAnalysis(ticket: ticket)
        #expect(await store.audioLeases.isEmpty)
        let retry = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let first = try #require(retry.inputs.first).envelope
        let core = try FrameRange(start: 0, count: 320_000)
        let window = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("bounded-window".utf8)),
            sessionID: fixture.sessionID, epochID: fixture.epochID, analysisAnchor: 0, coreFrames: core, contextFrames: core,
            modelCoreFrames: core, modelContextFrames: core, sources: [ArchiveWindowSource(chunkID: first.manifest.chunkID,
                manifestSHA256: first.manifestSHA256, audioSHA256: first.manifest.audioSHA256, sourceFrames: core)], configurationFingerprint: fingerprint)
        try await store.commitAnalysisBatch(ticket: retry, windows: [window],
            analyzedCoverage: [FrameRange(start: 0, count: 1_920_000)], noSpeechCoverage: [FrameRange(start: 320_000, count: 1_600_000)],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceFrame: 1_920_000,
                configurationFingerprint: fingerprint), waitingForMoreAudio: false)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let sequence = try await store.acquireTranscriptionInputLease(ticket: recognition)
        #expect(sequence.inputs.count == 2, "Recognition must not re-lease the rest of the day after bounded analysis.")
        try await store.releaseTranscriptionInputLease(sequence)
        try await store.cancelTranscriptionWindow(ticket: recognition)
        #expect(await store.audioLeases.isEmpty)
        let next = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
            finalizeAvailablePrefixBefore: .distantFuture))
        #expect(next.checkpoint?.sourceFrame == 1_920_000)
        #expect(next.boundary == .open)
        let validated = await store.audioContentValidationCount
        let replay = try await store.withAnalysisReplayPrefix(next)
        #expect(replay.replayOrigin == 960_000)
        #expect(replay.inputs.count == 3 && replay.leaseIDs.count == 3)
        #expect(replay.attemptID == next.attemptID && replay.checkpoint == next.checkpoint)
        #expect(await store.audioContentValidationCount == validated,
            "The archive actor must not synchronously hash the whole prefix.")
        try await store.cancelEpochAnalysis(ticket: replay)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func dailyProgressClipsMidnightAndCountsNoSpeechAsProcessed() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store(), audio = wav(frames: 1_920_000)
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-10-15T23:59:00Z"))
        let manifest = try ChunkManifest(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceDeviceID: fixture.deviceID,
            sourceBuild: "midnight-progress-test", sequence: 0, frames: FrameRange(start: 0, count: 1_920_000),
            timebaseHz: 16_000, wallClockAnchor: anchor, timezoneOffset: 28_800, codec: .pcmInt16, sampleRate: 16_000,
            channels: 1, decodedFrameCount: 1_920_000, byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture)
        _ = try await store.commitReceivedChunk(fixture.deliver(ManifestEnvelope(manifest: manifest), to: store, audio: audio))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let range = try FrameRange(start: 0, count: 960_000)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [range], noSpeechCoverage: [range],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceFrame: range.end, configurationFingerprint: fingerprint), waitingForMoreAudio: false)
        let firstDay = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let first = try await store.timelineDaySnapshot(firstDay, configurationFingerprint: fingerprint).progress
        let second = try await store.timelineDaySnapshot(firstDay.adding(days: 1), configurationFingerprint: fingerprint).progress
        #expect(first.received == 60 && first.processed == 60 && first.remaining == 0)
        #expect(second.received == 60 && second.processed == 0 && second.remaining == 60)
        #expect(first.awaitingSync == 0 && second.awaitingSync == 0)
    }

    private func complete(_ ticket: EpochAnalysisTicket, store: ArchiveStore) async throws {
        let start = ticket.checkpoint?.sourceFrame ?? 0
        let end = try #require(ticket.inputs.last).envelope.manifest.frames.end
        let range = try FrameRange(start: start, count: end - start)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [range], noSpeechCoverage: [range],
            checkpoint: ArchiveCheckpoint(sessionID: ticket.sessionID, epochID: ticket.epochID, sourceFrame: end, configurationFingerprint: fingerprint), waitingForMoreAudio: false)
    }

    private func wav(frames: Int) -> Data {
        var data = Fixture.audioData().prefix(44)
        func put(_ value: UInt32, at index: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.replaceSubrange(index..<(index + 4), with: $0) }
        }
        put(UInt32(36 + frames * 2), at: 4); put(UInt32(frames * 2), at: 40)
        data.append(Data(repeating: 0, count: frames * 2))
        return Data(data)
    }
}
