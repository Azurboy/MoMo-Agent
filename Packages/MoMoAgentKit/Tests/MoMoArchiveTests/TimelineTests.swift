import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TimelineTests {
    private let anchor = Date(timeIntervalSince1970: 1_792_023_000)

    @Test func punctuationOnlyResultsAreOmittedButOriginalAudioAndPendingStateRemain() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        try await add(fixture, store: store, at: anchor, text: "……。 \n")
        let day = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let window = try #require(await store.timelineDay(day).first)
        #expect(window.omitsPunctuationOnlyResult)
        #expect(window.text.isEmpty)
        #expect(window.references.isEmpty)
        #expect(window.paragraphs.isEmpty)
        #expect(try await store.readTranscript(sessionID: window.sources[0].sessionID).spans.isEmpty)
        #expect(try await store.playbackTimelines(sources: window.sources).first?.parts.first?.audioAvailable == true)
        try await add(fixture, store: store, at: anchor.addingTimeInterval(1), text: "", finish: false)
        let pending = try #require(await store.timelineDay(day).first)
        #expect(!pending.omitsPunctuationOnlyResult)
        let job = try #require(await store.claimAnalysisJob(configurationHash: "timeline"))
        _ = try await store.commitTranscript(ticket: job, spans: [TranscriptSpan(chunkID: job.chunkID,
            frames: job.manifest.frames, text: "这段后来补齐的文字应正常展示，纯标点不进入预览或引用。")])
        let mixed = try #require(await store.timelineWindow(window.id))
        #expect(!mixed.omitsPunctuationOnlyResult)
        #expect(!mixed.text.contains("……"))
        #expect(mixed.references.count == 1)
        let paragraph = try #require(mixed.paragraphs.first)
        let blank = TimelineParagraph(source: paragraph.source, text: " \n\t", recordedAt: paragraph.recordedAt, audioAvailable: true)
        #expect(!blank.hasReadableText)
        let blankRecording = try await add(fixture, store: store, at: anchor.addingTimeInterval(3_600), text: " \n\t")
        #expect(try await store.readTranscript(sessionID: blankRecording.sessionID).spans.isEmpty)
    }

    @Test func existingPunctuationIsRevisedAwayOnceWithoutDeletingOriginalAudio() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let manifest = try await add(fixture, store: store, at: anchor, text: "原有文本")
        let old = try await store.readTranscript(sessionID: manifest.sessionID)
        let noise = TranscriptSpan(chunkID: manifest.chunkID, frames: manifest.frames, text: "。")
        let historical = TranscriptDocument(sessionID: old.sessionID, version: old.version + 1,
            generation: old.generation, spans: [noise], updatedAt: Date())
        try await store.storeDocument(historical)
        let reference = historical.source(for: noise)
        try await store.discardPunctuationOnlyTranscripts()
        try await store.projectPendingDocuments()
        let cleaned = try await store.readTranscript(sessionID: manifest.sessionID)
        #expect(cleaned.spans.isEmpty)
        #expect(cleaned.generation == old.generation + 1)
        await #expect(throws: ArchiveError.staleSource) { try await store.validateSources([reference]) }
        let day = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let window = try #require(await store.timelineDay(day).first)
        #expect(window.omitsPunctuationOnlyResult)
        #expect(try await store.playbackTimelines(sources: window.sources).first?.parts.first?.audioAvailable == true)
        try await store.discardPunctuationOnlyTranscripts()
        #expect(try await store.readTranscript(sessionID: manifest.sessionID).version == cleaned.version)
    }

    @Test func groupsAllSessionsBeforeFilteringIncludingBeyondListPage() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let day = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        for _ in 0..<51 { try await add(fixture, store: store, at: anchor, text: "简短文字") }
        let windows = try await store.timelineDay(day)
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.sources.count == 51)
        #expect(window.paragraphs.count == 51)
        #expect(!window.omitsPunctuationOnlyResult)
        #expect(window.state == .complete)
        #expect(window.isFinal)
        #expect(try await store.recordingsPage().items.count == 50)
    }

    @Test func halfHourDoesNotSplitAnActiveConversation() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let boundary = Date(timeIntervalSince1970: ceil(anchor.timeIntervalSince1970 / 1_800) * 1_800)
        try await add(fixture, store: store, at: boundary.addingTimeInterval(-0.05), text: "跨过半小时的一句完整转录，必须只保留一次，不能从中间截断。")
        let day = TimelineDay(boundary.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let windows = try await store.timelineDay(day)
        #expect(windows.count == 1)
        #expect(windows.flatMap(\.paragraphs).count == 1)
        #expect(windows.flatMap(\.sources).reduce(0) { $0 + $1.frames.count } == 1_600)
        let frozen = try await store.playbackTimelines(sources: windows.flatMap(\.sources))
        #expect(frozen.flatMap(\.parts).reduce(0) { $0 + $1.frames.count } == 1_600)
    }

    @Test func shortContentHasANormalTimeWindowAndPendingContentIsNeverHidden() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let day = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let received = try await add(fixture, store: store, at: anchor, text: "提醒", finish: false)
        let pending = try #require(await store.timelineDay(day).first)
        #expect(!pending.omitsPunctuationOnlyResult)
        #expect(pending.state == .waitingForTranscription)
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "timeline"))
        _ = try await store.commitTranscript(ticket: ticket, spans: [TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "提醒")])
        let short = try #require(await store.timelineDay(day).first)
        #expect(!short.omitsPunctuationOnlyResult)
        #expect(short.id.start == anchor)
        #expect(!short.canSummarize)
        #expect(short.text == "提醒")
        #expect(try await store.playbackTimelines(sources: short.sources).first?.parts.first?.audioAvailable == true)
        #expect(try await store.timelineWindow(containing: short.references[0])?.id == short.id)
        _ = try await store.deleteSession(id: received.sessionID)
        await #expect(throws: ArchiveError.staleSource) { try await store.validateTimelineWindow(short) }
    }

    @Test func nearbySpeechCrossesTheOldBoundaryAndLongInactivityStartsANewNode() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let boundary = Date(timeIntervalSince1970: ceil(anchor.timeIntervalSince1970 / 1_800) * 1_800)
        let first = try await add(fixture, store: store, at: boundary.addingTimeInterval(-60), text: "前一段交谈的内容需要跟后面短暂间歇的交谈放在一起。")
        let second = try await add(fixture, store: store, at: boundary.addingTimeInterval(60), text: "这次停止之后继续录音，不应该因为越过半小时边界而拆开。")
        try await add(fixture, store: store, at: boundary.addingTimeInterval(660), text: "相隔十分钟后的说话应成为一个新的节点。")
        let date = TimelineDay(boundary.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let windows = try await store.timelineDay(date)
        #expect(windows.count == 2)
        let combined = try #require(windows.last)
        #expect(Set(combined.sources.map(\.sessionID)) == Set([first.sessionID, second.sessionID]))
        #expect(combined.paragraphs.count == 2)
    }

    @Test func midnightStillClipsAudioByDateWithoutDuplicatingTheSentence() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let date = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let next = date.adding(days: 1)
        let boundary = next.startDate(calendar: TimelineDay.calendar).addingTimeInterval(-28_800)
        try await add(fixture, store: store, at: boundary.addingTimeInterval(-0.05), text: "跨午夜的完整一句文字应只归属一次，原音按日期裁切。")
        let before = try await store.timelineDay(date), after = try await store.timelineDay(next)
        #expect(before.count == 1 && after.count == 1)
        #expect((before + after).flatMap(\.paragraphs).count == 1)
        let frames: Int64 = (before + after).flatMap(\.sources).reduce(0) { $0 + $1.frames.count }
        #expect(frames == 1_600)
    }

    @Test func recordedTimezoneAndMidnightDetermineDayNotPhoneOrReceiptTime() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let utcDay = TimelineDay(anchor, calendar: TimelineDay.calendar)
        let dayStart = utcDay.startDate(calendar: TimelineDay.calendar)
        try await add(fixture, store: store, at: dayStart.addingTimeInterval(20 * 3_600), text: "第二天凌晨的内容")
        #expect(try await store.timelineDay(utcDay).isEmpty)
        let next = try await store.timelineDay(utcDay.adding(days: 1))
        #expect(next.count == 1)
        #expect(next[0].id.day == utcDay.adding(days: 1))
        #expect(try await store.earliestTimelineDay() == utcDay.adding(days: 1))
    }

    @Test func defaultEightAMDayBoundaryKeepsLateNightRecordingsOnPrecedingDay() async throws {
        #expect(TimelineDay.defaultStartHour == 8)
        #expect(TimelineDay.currentStartHour == 8)
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        // 2026-11-04 23:30:00 +08:00 -> 2026-11-04 15:30:00Z
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-11-04T15:30:00Z"))
        // 2026-11-05 01:30:00 +08:00 -> 2026-11-04 17:30:00Z (still belongs to 2026-11-04!)
        let afterMidnight = try #require(ISO8601DateFormatter().date(from: "2026-11-04T17:30:00Z"))
        // 2026-11-05 07:59:30 +08:00 -> 2026-11-04 23:59:30Z (still belongs to 2026-11-04!)
        let beforeEightAM = try #require(ISO8601DateFormatter().date(from: "2026-11-04T23:59:30Z"))
        // 2026-11-05 08:00:00 +08:00 -> 2026-11-05 00:00:00Z (starts 2026-11-05!)
        let atEightAM = try #require(ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))

        try await add(fixture, store: store, at: lateEvening, text: "深夜十一点半的讨论")
        try await add(fixture, store: store, at: afterMidnight, text: "凌晨一点半继续的讨论")
        try await add(fixture, store: store, at: beforeEightAM, text: "早上七点五十九分的补充")
        try await add(fixture, store: store, at: atEightAM, text: "早上八点新一天的开始")

        let nov4 = TimelineDay(lateEvening.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let nov5 = nov4.adding(days: 1)
        #expect(nov4.year == 2026 && nov4.month == 11 && nov4.day == 4)
        #expect(nov5.year == 2026 && nov5.month == 11 && nov5.day == 5)
        #expect(TimelineDay(afterMidnight.addingTimeInterval(28_800), calendar: TimelineDay.calendar) == nov4)
        #expect(TimelineDay(beforeEightAM.addingTimeInterval(28_800), calendar: TimelineDay.calendar) == nov4)
        #expect(TimelineDay(atEightAM.addingTimeInterval(28_800), calendar: TimelineDay.calendar) == nov5)
        // Literal calendar picker date never shifts backward even at 00:00.
        #expect(TimelineDay(calendarDate: nov5.date(calendar: TimelineDay.calendar), calendar: TimelineDay.calendar) == nov5)
        // Custom startHour (e.g. 0 or 4) shifts the boundary cleanly.
        #expect(TimelineDay(afterMidnight.addingTimeInterval(28_800), calendar: TimelineDay.calendar, startHour: 0) == nov5)
        #expect(TimelineDay(afterMidnight.addingTimeInterval(28_800), calendar: TimelineDay.calendar, startHour: 4) == nov4)

        let nov4Windows = try await store.timelineDay(nov4)
        let nov5Windows = try await store.timelineDay(nov5)
        let nov4Texts = nov4Windows.flatMap(\.paragraphs).map(\.text)
        let nov5Texts = nov5Windows.flatMap(\.paragraphs).map(\.text)
        #expect(nov4Texts.contains("深夜十一点半的讨论"))
        #expect(nov4Texts.contains("凌晨一点半继续的讨论"))
        #expect(nov4Texts.contains("早上七点五十九分的补充"))
        #expect(!nov4Texts.contains("早上八点新一天的开始"))
        #expect(nov5Texts == ["早上八点新一天的开始"])
    }

    @Test func oldWindowRevisionIsRejectedAfterNewTextAndPlaybackChecksEachSession() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let day = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let first = try await add(fixture, store: store, at: anchor, text: "一段较长的转录正文用于验证时间线中的版本校验和来源归属。")
        let old = try #require(await store.timelineDay(day).first)
        let second = try await add(fixture, store: store, at: anchor.addingTimeInterval(1), text: "另一段内容")
        await #expect(throws: ArchiveError.staleSource) { try await store.validateTimelineWindow(old) }
        let window = try #require(await store.timelineDay(day).first)
        let playback = try await store.playbackTimelines(sources: window.sources)
        #expect(Set(playback.map(\.sessionID)) == Set([first.sessionID, second.sessionID]))
        _ = try await store.deleteSession(id: second.sessionID)
        let member = try #require(playback.first { $0.sessionID == second.sessionID })
        await #expect(throws: ArchiveError.sessionDeleted(second.sessionID)) { try await store.validatePlaybackTimeline(member) }
        #expect(try await store.timelineDay(day).first?.sources.count == 1)
    }

    @Test func unrelatedAppendDoesNotRegenerateEarlierWindowSummary() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await add(fixture, store: store, at: anchor, text: "第一段的正文保持不变，不应该因为同一录音在别的时间产生文字就重复总结。")
        let day = TimelineDay(anchor.addingTimeInterval(28_800), calendar: TimelineDay.calendar)
        let original = try #require(await store.timelineDay(day).first)
        let next = try ChunkManifest(sessionID: first.sessionID, epochID: UUID(), sourceDeviceID: fixture.deviceID,
            sourceBuild: "timeline-test", sequence: 0, frames: FrameRange(start: 0, count: 1_600), timebaseHz: 16_000,
            wallClockAnchor: anchor.addingTimeInterval(3_600), timezoneOffset: 28_800, codec: .pcmInt16, sampleRate: 16_000,
            channels: 1, decodedFrameCount: 1_600, byteCount: Int64(fixture.audio.count), audioSHA256: ContentHash.sha256(fixture.audio), sourceKind: .fixture)
        _ = try await store.commitReceivedChunk(fixture.deliver(ManifestEnvelope(manifest: next), to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "timeline"))
        _ = try await store.commitTranscript(ticket: ticket, spans: [TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "另一个时段的新内容。")])
        let refreshed = try #require(await store.timelineWindow(original.id))
        #expect(refreshed.revision == original.revision)
        #expect(refreshed.paragraphs.first?.source.transcriptVersion != original.paragraphs.first?.source.transcriptVersion)
        try await store.validateTimelineWindow(original)
    }

    @discardableResult
    private func add(_ fixture: Fixture, store: ArchiveStore, at date: Date, text: String, finish: Bool = true) async throws -> ChunkManifest {
        let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: fixture.deviceID,
            sourceBuild: "timeline-test", sequence: 0, frames: FrameRange(start: 0, count: 1_600), timebaseHz: 16_000,
            wallClockAnchor: date, timezoneOffset: 28_800, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
            decodedFrameCount: 1_600, byteCount: Int64(fixture.audio.count), audioSHA256: ContentHash.sha256(fixture.audio), sourceKind: .fixture)
        let envelope = try ManifestEnvelope(manifest: manifest)
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        try await store.receiveEpochEnd(CaptureEpochEnded(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: fixture.deviceID, endFrame: 1_600, reason: .stopped))
        if finish {
            let ticket = try #require(await store.claimAnalysisJob(configurationHash: "timeline"))
            _ = try await store.commitTranscript(ticket: ticket, spans: [TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: text)])
        }
        return manifest
    }
}
