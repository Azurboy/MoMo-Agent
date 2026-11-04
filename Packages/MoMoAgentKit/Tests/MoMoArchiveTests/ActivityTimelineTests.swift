import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ActivityTimelineTests {
    private let fingerprint = ContentHash.sha256(Data("activity-test".utf8))
    private let anchor = Date(timeIntervalSince1970: 1_792_023_000)
    private var day: TimelineDay { TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar) }

    @Test func summaryBatchBuildsEachDayOnceAndStillRejectsRevisedAndDeletedContent() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        try await analyze(store, manifest: manifest, speech: [
            FrameRange(start: 10 * 16_000, count: 10 * 16_000),
            FrameRange(start: 580 * 16_000, count: 10 * 16_000)
        ])
        while let ticket = try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint) {
            _ = try await store.commitWindowTranscript(ticket: ticket,
                text: "周五核对设计与来源，下一步安排需要保留在本次讨论的总结里。", rawResult: Data())
        }
        let windows = try await store.timelineDay(day, configurationFingerprint: fingerprint)
        #expect(windows.count == 2)
        let before = await store.timelineDayBuildCount
        let valid = try await store.validTimelineSummaryRevisions(windows + windows)
        #expect(valid == Set(windows.map(\.summaryRevision)))
        #expect(await store.timelineDayBuildCount == before + 1)

        let document = try await store.readTranscript(sessionID: manifest.sessionID)
        var spans = document.spans
        let old = spans[0]
        spans[0] = TranscriptSpan(id: old.id, chunkID: old.chunkID, frames: old.frames,
            text: "更正后的安排是周四核对设计，原来的总结已经不再有效。",
            speaker: old.speaker, sourceRanges: old.sourceRanges)
        _ = try await store.reviseTranscript(sessionID: manifest.sessionID, expectedVersion: document.version, spans: spans)
        let remaining = try await store.validTimelineSummaryRevisions(windows)
        // Both windows reference the revised session's transcript version.
        #expect(remaining.isEmpty)
        let stale = try #require(windows.first { $0.paragraphs.contains { $0.id == old.id } })
        #expect(!remaining.contains(stale.summaryRevision))
        let revised = try await store.timelineDay(day, configurationFingerprint: fingerprint)
        #expect(try await store.validTimelineSummaryRevisions(revised) == Set(revised.map(\.summaryRevision)))
        _ = try await store.deleteSession(id: manifest.sessionID)
        #expect(try await store.validTimelineSummaryRevisions(windows).isEmpty)
    }

    @Test func shortSpeechAndPunctuationStayInTheirTimeWindowWithoutNoiseInTextOrSearch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        let speech = try [10, 30, 50].map { try FrameRange(start: Int64($0) * 16_000, count: 10 * 16_000) }
        try await analyze(store, manifest: manifest, speech: speech)
        for text in ["嗯", "……。 \n", "提醒"] {
            let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
            _ = try await store.commitWindowTranscript(ticket: ticket, text: text, rawResult: Data())
        }
        let windows = try await store.timelineDay(day, configurationFingerprint: fingerprint)
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.id.start == anchor.addingTimeInterval(10))
        #expect(window.end == anchor.addingTimeInterval(60))
        #expect(window.paragraphs.map(\.text) == ["嗯", "提醒"])
        #expect(window.references.count == 2)
        #expect(!window.omitsPunctuationOnlyResult)
        #expect(!window.canSummarize)
        #expect(window.state == .complete)
        #expect(try await store.searchTranscripts(query: "……").isEmpty)
        #expect(try await store.searchTranscripts(query: "提醒").count == 1)
        #expect(try await store.timelineWindow(containing: window.references[0], configurationFingerprint: fingerprint)?.id == window.id)
        #expect(try await store.playbackTimelines(sources: window.sources).first?.parts.first?.audioAvailable == true)
    }

    @Test func summaryUsesAvailableSpeechAndInvalidatesWhenMoreTextArrives() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        try await analyze(store, manifest: manifest, speech: [FrameRange(start: 10 * 16_000, count: 10 * 16_000),
            FrameRange(start: 90 * 16_000, count: 10 * 16_000)])
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: first,
            text: "前半段确认周五核对设计，同一段交谈的后半段还没识别。", rawResult: Data())
        let partial = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(partial.state == .waitingForTranscription)
        #expect(partial.canSummarize)
        try await store.validateTimelineSummary(partial)
        let second = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: second,
            text: "后半段现在也转录完成，总结必须包含整段交谈的两部分内容。", rawResult: Data())
        let complete = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(complete.canSummarize)
        #expect(complete.summaryRevision != partial.summaryRevision)
        await #expect(throws: ArchiveError.staleSource) { try await store.validateTimelineSummary(partial) }
        try await store.validateTimelineSummary(complete)
        #expect(complete.paragraphs.count == 2)
        #expect(complete.text.contains("前半段") && complete.text.contains("后半段"))
    }

    @Test func summaryDoesNotRequireCaptureEndAndSurvivesAProcessingFailure() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store, closed: false)
        try await analyze(store, manifest: manifest, speech: [FrameRange(start: 510 * 16_000, count: 10 * 16_000),
            FrameRange(start: 580 * 16_000, count: 10 * 16_000)])
        let empty = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(!empty.canSummarize)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: first,
            text: "周五下午核对设计，周末确认上线时间，由小林负责。", rawResult: Data())
        let partial = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(!partial.isFinal)
        #expect(partial.canSummarize)
        try await store.validateTimelineSummary(partial)
        let second = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        try await store.deferTranscriptionWindow(ticket: second, code: .recognition)
        let failed = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(failed.state == .failed)
        #expect(failed.canSummarize)
        #expect(failed.summaryRevision == partial.summaryRevision)
        try await store.validateTimelineSummary(partial)
    }

    @Test func longQuietGapSplitsOneCaptureAndPlaybackKeepsOnlySpeechWithContext() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        let before = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(before.state == .waitingForTranscription)
        #expect(!before.omitsPunctuationOnlyResult)
        let ranges = try [FrameRange(start: 10 * 16_000, count: 10 * 16_000), FrameRange(start: 580 * 16_000, count: 10 * 16_000)]
        try await analyze(store, manifest: manifest, speech: ranges)
        let pending = try await store.timelineDay(day, configurationFingerprint: fingerprint)
        #expect(pending.count == 2)
        #expect(pending.allSatisfy { $0.state == .waitingForTranscription && !$0.omitsPunctuationOnlyResult })
        while let ticket = try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint) {
            _ = try await store.commitWindowTranscript(ticket: ticket,
                text: "这段实际说话的文字应按活动聚合，中间长时间没有说话的部分不会占据时间线。", rawResult: Data())
        }
        let windows = try await store.timelineDay(day, configurationFingerprint: fingerprint)
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.speechDuration == 10 && $0.end.timeIntervalSince($0.id.start) == 10 })
        #expect(windows.flatMap(\.paragraphs).count == 2)
        #expect(windows.flatMap(\.sources).allSatisfy { $0.frames.count == 12 * 16_000 })
        #expect(windows.allSatisfy { $0.sharesSource(with: before.sources) })
        let frozen = try await store.playbackTimelines(sources: windows.flatMap(\.sources))
        let playbackFrames: Int64 = frozen.flatMap(\.parts).reduce(0) { $0 + $1.frames.count }
        #expect(playbackFrames == 384_000)
        #expect(try await store.timelineWindow(containing: windows[0].references[0], configurationFingerprint: fingerprint)?.id == windows[0].id)
    }

    @Test func confirmedSilenceHasNoNodeButAMarkAndTheOriginalAudioSurvive() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        try await analyze(store, manifest: manifest, speech: [])
        #expect(try await store.timelineDay(day, configurationFingerprint: fingerprint).isEmpty)
        let summary = try await store.recordingSummary(sessionID: manifest.sessionID)
        #expect(try await store.playbackTimeline(sessionID: manifest.sessionID, expectedGeneration: summary.generation).parts.first?.audioAvailable == true)
        try await store.receiveMark(CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 300 * 16_000))
        let marked = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(marked.isMarked && !marked.omitsPunctuationOnlyResult)
        #expect(marked.speechDuration == 0)
    }

    @Test func aMissingTailIsUnknownRatherThanSilence() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store, capturedSeconds: 720)
        try await analyze(store, manifest: manifest, speech: [])
        let window = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(window.state == .waitingForSync)
        #expect(!window.omitsPunctuationOnlyResult)
        #expect(window.speechDuration == 0)
        #expect(window.id.start == anchor.addingTimeInterval(600))
    }

    @Test func marksLocateNearestTextAndPlayTheExactFrameAcrossQuietGaps() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        try await analyze(store, manifest: manifest, speech: [FrameRange(start: 10 * 16_000, count: 10 * 16_000),
            FrameRange(start: 90 * 16_000, count: 10 * 16_000)])
        for text in ["前面讨论设计", "后面确认时间"] {
            let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
            _ = try await store.commitWindowTranscript(ticket: ticket, text: text, rawResult: Data())
        }
        let firstMark = try CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 19 * 16_000)
        try await store.receiveMark(firstMark)
        let first = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        // The second mark is in silence, nearer the end of the first paragraph than the next start.
        let secondMark = try CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 40 * 16_000 + 123)
        try await store.receiveMark(secondMark)
        let second = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        try await store.receiveMark(secondMark)
        let replay = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(replay.marks.count == 2)
        #expect(replay.revision == second.revision)
        #expect(second.revision != first.revision)
        #expect(second.summaryRevision == first.summaryRevision)
        #expect(second.marks.map(\.id) == [firstMark.markID, secondMark.markID])
        #expect(second.marks.allSatisfy { $0.nearbyParagraphID == second.paragraphs[0].id && $0.audioAvailable })
        let selected = try #require(second.marks.last)
        #expect(selected.recordedAt == anchor.addingTimeInterval(40 + 123.0 / 16_000))
        // First speech source is [9,21); second marked source starts at 38 + 123/16000.
        #expect(selected.playbackPosition(in: second.sources) == 14)
        let clips = try await store.playbackTimelines(sources: second.sources)
        #expect(clips[1].parts[0].frames.start == 38 * 16_000 + 123)
    }

    @Test func marksRemainWhenTextOrAudioIsUnavailableAndAtTheEpochEnd() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        for frame in [300 * 16_000, 600 * 16_000] {
            try await store.receiveMark(CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
                sourceDeviceID: fixture.deviceID, sourceFrame: Int64(frame)))
        }
        let pending = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(pending.marks.count == 2)
        #expect(pending.marks.allSatisfy { $0.nearbyParagraphID == nil })
        #expect(pending.marks[0].audioAvailable)
        #expect(!pending.marks[1].audioAvailable)
        #expect(pending.marks[1].playbackPosition(in: pending.sources) == nil)
        let lease = try await store.acquireAudioLease(chunkID: manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        let missing = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(missing.marks.map(\.id) == pending.marks.map(\.id))
        #expect(missing.marks.allSatisfy { !$0.audioAvailable })
    }

    @Test func markNeverResolvesTextFromAnotherSessionInTheSameWindow() async throws {
        let first = try Fixture(); defer { first.remove() }
        let second = try Fixture(); defer { second.remove() }
        let store = try first.store()
        let original = try await receive(first, store: store)
        _ = try await receive(second, store: store)
        while let ticket = try await store.claimAnalysisJob(configurationHash: "marks") {
            _ = try await store.commitTranscript(ticket: ticket, spans: [TranscriptSpan(chunkID: ticket.chunkID,
                frames: FrameRange(start: ticket.manifest.sessionID == original.sessionID ? 10 * 16_000 : 50 * 16_000,
                    count: 10 * 16_000), text: ticket.manifest.sessionID == original.sessionID ? "标记自己的录音" : "另一轮录音")])
        }
        try await store.receiveMark(CaptureMark(sessionID: original.sessionID, epochID: original.epochID,
            sourceDeviceID: first.deviceID, sourceFrame: 55 * 16_000))
        let window = try #require(await store.timelineDay(day).first)
        #expect(window.sources.contains { $0.sessionID == second.sessionID })
        let mark = try #require(window.marks.first)
        let paragraph = try #require(window.paragraphs.first { $0.id == mark.nearbyParagraphID })
        #expect(paragraph.source.sessionID == original.sessionID)
    }

    @Test func midnightMarkAppearsOnceAndUsesTheFollowingRecordingDay() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let boundary = day.adding(days: 1).startDate(calendar: TimelineDay.calendar).addingTimeInterval(-28_800)
        let manifest = try await receive(fixture, store: store, at: boundary.addingTimeInterval(-300))
        try await store.receiveMark(CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 300 * 16_000))
        let before = try await store.timelineDay(day)
        let after = try await store.timelineDay(day.adding(days: 1))
        #expect(before.flatMap(\.marks).isEmpty)
        #expect(after.flatMap(\.marks).count == 1)
        #expect(after.flatMap(\.marks).first?.recordedAt == boundary)
        #expect(after.flatMap(\.marks).first?.playbackPosition(in: after.flatMap(\.sources)) == 0)
    }

    @Test func shortNaturalPauseStaysInPlaybackButDoesNotCountAsSpeech() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        try await analyze(store, manifest: manifest, speech: [FrameRange(start: 10 * 16_000, count: 10 * 16_000),
            FrameRange(start: 28 * 16_000, count: 10 * 16_000)])
        let window = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(window.speechDuration == 20)
        #expect(window.end.timeIntervalSince(window.id.start) == 28)
        #expect(window.sources.count == 1)
        #expect(window.sources[0].frames.count == 30 * 16_000)
    }

    @Test func fractionalAudioEndCannotCreateAPhantomMissingFrame() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store, exactFrames: 89_472)
        let window = try #require(await store.timelineDay(day).first)
        #expect(window.sources[0].frames.end == manifest.frames.end)
        #expect(window.sources[0].frames.count == manifest.frames.count)
    }

    @Test func unexpectedlyMissingSilentAudioStillSurfacesAProblem() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await receive(fixture, store: store)
        try await analyze(store, manifest: manifest, speech: [])
        let lease = try await store.acquireAudioLease(chunkID: manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        await #expect(throws: ArchiveError.missingRecording(manifest.chunkID)) { try await store.acquireAudioLease(chunkID: manifest.chunkID) }
        let window = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(window.state == .failed && !window.omitsPunctuationOnlyResult)
        #expect(window.speechDuration == 0)
    }

    private func receive(_ fixture: Fixture, store: ArchiveStore, capturedSeconds: Int64 = 600, exactFrames: Int64? = nil, closed: Bool = true, at: Date? = nil) async throws -> ChunkManifest {
        let frames: Int64 = exactFrames ?? (600 * 16_000)
        var audio = Data(Fixture.audioData().prefix(44))
        var riffBytes = UInt32(frames * 2 + 36).littleEndian
        var pcmBytes = UInt32(frames * 2).littleEndian
        withUnsafeBytes(of: &riffBytes) { audio.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: &pcmBytes) { audio.replaceSubrange(40..<44, with: $0) }
        audio.append(Data(repeating: 0, count: Int(frames * 2)))
        let manifest = try ChunkManifest(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, sourceBuild: "activity-test", sequence: 0,
            frames: FrameRange(start: 0, count: frames), timebaseHz: 16_000, wallClockAnchor: at ?? anchor,
            timezoneOffset: 28_800, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
            decodedFrameCount: frames, byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture)
        _ = try await store.commitReceivedChunk(fixture.deliver(ManifestEnvelope(manifest: manifest), to: store, audio: audio))
        if closed { try await store.markEpochClosed(epochID: manifest.epochID, endFrame: exactFrames ?? (capturedSeconds * 16_000)) }
        return manifest
    }

    private func analyze(_ store: ArchiveStore, manifest: ChunkManifest, speech: [FrameRange]) async throws {
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let envelope = try ManifestEnvelope(manifest: manifest)
        let windows = speech.map { frames in
            ArchiveAnalysisWindow(id: ContentHash.sha256(Data("speech-\(frames.start)".utf8)),
                sessionID: manifest.sessionID, epochID: manifest.epochID, analysisAnchor: 0,
                coreFrames: frames, contextFrames: frames, modelCoreFrames: frames, modelContextFrames: frames,
                sources: [ArchiveWindowSource(chunkID: manifest.chunkID, manifestSHA256: envelope.manifestSHA256,
                    audioSHA256: manifest.audioSHA256, sourceFrames: frames)], configurationFingerprint: fingerprint)
        }
        try await store.commitAnalysisBatch(ticket: ticket, windows: windows, analyzedCoverage: [manifest.frames],
            noSpeechCoverage: CoverageRanges.subtract([manifest.frames], speech), checkpoint: nil, waitingForMoreAudio: false)
    }
}
