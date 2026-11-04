import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct AutomaticProcessingTests {
    let fingerprint = ContentHash.sha256(Data("automatic-priority".utf8))
    let now = Date(timeIntervalSince1970: 1_792_238_400) // 2026-10-17 12:00 UTC
    var calendar: Calendar { TimelineDay.calendar }

    @Test func noSpeechReviewPreservesTextAndReopensOnlyTheRequestedTimeRange() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store(), anchor = now.addingTimeInterval(-60)
        for index in 0..<3 {
            _ = try await ingest(fixture, into: store, anchor: anchor, start: Int64(index * 1_600), sequence: Int64(index))
        }
        let analysis = try await nextAnalysis(store), window = try makeWindow(analysis)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window],
            analyzedCoverage: [FrameRange(start: 0, count: 4_800)],
            noSpeechCoverage: [FrameRange(start: 1_600, count: 3_200)],
            checkpoint: checkpoint(analysis, end: 4_800), waitingForMoreAudio: false)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let original = try await store.commitWindowTranscript(ticket: recognition, text: "已保留的正文", rawResult: Data())
        let interval = DateInterval(start: anchor.addingTimeInterval(0.125), end: anchor.addingTimeInterval(0.25))
        #expect(try await store.reopenNoSpeech(in: interval, configurationFingerprint: fingerprint) == 0.125)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans == original.spans)
        #expect(try await store.pendingAnalysisRanges(epochID: fixture.epochID, fingerprint: fingerprint, retainedOnly: true)
            == [FrameRange(start: 2_000, count: 2_000)])
        #expect(try await store.reopenNoSpeech(in: interval, configurationFingerprint: fingerprint) == 0)
        let reopened = try fixture.store()
        let ticket = try await nextAnalysis(reopened)
        #expect(ticket.checkpoint?.sourceFrame == 2_000)
        #expect(ticket.boundary.endFrame == 4_000)
        let core = try FrameRange(start: 2_000, count: 2_000)
        let sources = try ticket.inputs.map { input in
            let m = input.envelope.manifest, start = max(core.start, m.frames.start), end = min(core.end, m.frames.end)
            return ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: input.envelope.manifestSHA256,
                audioSHA256: m.audioSHA256, sourceFrames: try FrameRange(start: start, count: end - start))
        }
        let recovered = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("recovered".utf8)), sessionID: fixture.sessionID,
            epochID: fixture.epochID, analysisAnchor: 2_000, coreFrames: core, contextFrames: core,
            modelCoreFrames: try FrameRange(start: 0, count: 2_000), modelContextFrames: try FrameRange(start: 0, count: 2_000),
            sources: sources, configurationFingerprint: fingerprint)
        try await reopened.commitAnalysisBatch(ticket: ticket, windows: [recovered], analyzedCoverage: [core], noSpeechCoverage: [],
            checkpoint: checkpoint(ticket, end: core.end), waitingForMoreAudio: false)
        let next = try #require(await reopened.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let result = try await reopened.commitWindowTranscript(ticket: next, text: "补查 KYC 测试", rawResult: Data())
        #expect(result.spans.count == 2)
        #expect(result.spans.first == original.spans.first)
        #expect(try await reopened.searchTranscripts(query: "kyc").count == 1)
        #expect(try await reopened.transcriptLocations(document: result)[result.spans[1].id]?.recordedAt
            == anchor.addingTimeInterval(0.125))
        #expect(try await reopened.reopenNoSpeech(in: interval, configurationFingerprint: fingerprint) == 0)
    }

    @Test func noSpeechReviewRejectsActiveAnalysisAndExcludesMissingOriginalAudio() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store(), anchor = now.addingTimeInterval(-60)
        _ = try await ingest(fixture, into: store, anchor: anchor)
        let ticket = try await nextAnalysis(store)
        let range = try FrameRange(start: 0, count: 800)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [range], noSpeechCoverage: [range],
            checkpoint: checkpoint(ticket, end: range.end), waitingForMoreAudio: false, continuing: true)
        let interval = DateInterval(start: anchor, duration: 1)
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.reopenNoSpeech(in: interval, configurationFingerprint: fingerprint)
        }
        try await store.cancelEpochAnalysis(ticket: ticket)
        try await store.markReviewAudioUnavailable(epochID: fixture.epochID)
        #expect(try await store.reopenNoSpeech(in: interval, configurationFingerprint: fingerprint) == 0)
    }

    @Test func noSpeechReviewUsesAudioDateAcrossMidnightInsteadOfSessionFolderDate() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let midnight = calendar.startOfDay(for: now), anchor = midnight.addingTimeInterval(-0.125)
        for index in 0..<3 {
            _ = try await ingest(fixture, into: store, anchor: anchor, start: Int64(index * 1_600), sequence: Int64(index))
        }
        while let ticket = try await store.claimEpochAnalysis(configurationFingerprint: fingerprint) {
            try await completeSilence(ticket, store: store)
        }
        let interval = DateInterval(start: midnight, duration: 86_400)
        #expect(try await store.reopenNoSpeech(in: interval, configurationFingerprint: fingerprint) == 0.175)
        #expect(try await store.pendingAnalysisRanges(epochID: fixture.epochID, fingerprint: fingerprint, retainedOnly: true)
            == [FrameRange(start: 2_000, count: 2_800)])
    }

    @Test func unchangedRetransmissionsPreserveCompletedAnalysisAndOnlyReissueTheReceipt() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60))
        let ticket = try await nextAnalysis(store)
        try await completeSilence(ticket, store: store)
        let receipt = try #require(await store.pendingReceipts().first)
        try await store.applyReceipt(ReceiptApplied(receipt: receipt))
        #expect(try await store.pendingAnalysisWakeCount(fingerprint: fingerprint) == 0)
        let coverage = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        let changesBefore = try await store.receiveTestChangeCount()
        for _ in 0..<50 {
            guard case .duplicate(let repeated) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
                Issue.record("Matching valid bytes must remain an idempotent duplicate"); return
            }
            #expect(repeated == receipt)
        }
        let pending = try await store.pendingAnalysisWakeCount(fingerprint: fingerprint)
        let changes = try await store.receiveTestChangeCount() - changesBefore
        print("RETRANSMISSION_BENCHMARK deliveries=50 sqliteRowChanges=\(changes) pendingEpochs=\(pending)")
        #expect(changes == 1, "Only the first replay needs to change the already-confirmed receipt back to pending.")
        #expect(pending == 0,
            "Re-sending confirmed bytes must not make completed analysis eligible again.")
        #expect(try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).processedDuration == coverage.processedDuration)
        #expect(try await store.pendingReceipts() == [receipt], "A lost acknowledgement must still be reissued.")
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now, calendar: calendar) == nil)
    }

    @Test func currentProducerBlocksHistoryBeforeItsFirstWindowAndAllowsHigherPriorityPreemption() async throws {
        let old = try Fixture(), current = try Fixture()
        defer { old.remove(); current.remove() }
        let store = try old.store()
        _ = try await ingest(old, into: store, anchor: now.addingTimeInterval(-86_400))
        let historical = try await nextAnalysis(store)
        _ = try await ingest(current, into: store, anchor: now.addingTimeInterval(-60))
        let work = try #require(await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now,
            calendar: calendar, activeAnalysis: historical))
        guard case .analysis(let today) = work else { Issue.record("Today's analysis must preempt history"); return }
        try await store.cancelEpochAnalysis(ticket: historical)
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now,
            calendar: calendar, activeAnalysis: today) == nil)
        try await store.cancelEpochAnalysis(ticket: today)
    }

    @Test func incrementalCommitRetainsAttemptAndLeasesAndReopenResumesOnlyTheTail() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60))
        let ticket = try await nextAnalysis(store)
        let prefix = try FrameRange(start: 0, count: 800)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [prefix], noSpeechCoverage: [prefix],
            checkpoint: checkpoint(ticket, end: prefix.end), waitingForMoreAudio: false, continuing: true)
        #expect(await store.audioLeases.count == ticket.leaseIDs.count)
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now, calendar: calendar) == nil)
        let reopened = try fixture.store()
        try await reopened.recoverInterruptedJobs()
        let resumed = try await nextAnalysis(reopened)
        #expect(resumed.checkpoint?.sourceFrame == 800)
        try await completeSilence(resumed, store: reopened)
        try await store.cancelEpochAnalysis(ticket: ticket)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func incrementalWindowCanRunBeforeProducerFinishesAndDeletionKeepsItsReadersLeased() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60))
        let analysis = try await nextAnalysis(store), window = try makeWindow(analysis)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window], analyzedCoverage: [window.coreFrames],
            noSpeechCoverage: [], checkpoint: checkpoint(analysis, end: window.coreFrames.end),
            waitingForMoreAudio: false, continuing: true)
        let work = try #require(await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now,
            calendar: calendar, activeAnalysis: analysis))
        guard case .transcription(let recognition) = work else { Issue.record("Published window must be runnable"); return }
        let audio = try #require(analysis.inputs.first).audioURL
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        try await store.cancelTranscriptionWindow(ticket: recognition)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.commitAnalysisBatch(ticket: analysis, windows: [], analyzedCoverage: [window.coreFrames],
                noSpeechCoverage: [], checkpoint: checkpoint(analysis, end: window.coreFrames.end), waitingForMoreAudio: false)
        }
        try await store.cancelEpochAnalysis(ticket: analysis)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test(arguments: [false, true])
    func incrementalOpenTailWaitsForChangedInputInsteadOfReplayingTheSameSnapshot(arrivesBeforeFinal: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60))
        let ticket = try await nextAnalysis(store)
        let prefix = try FrameRange(start: 0, count: 800)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [prefix], noSpeechCoverage: [prefix],
            checkpoint: checkpoint(ticket, end: prefix.end), waitingForMoreAudio: false, continuing: true)
        if arrivesBeforeFinal {
            _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60), start: 1_600, sequence: 1)
        }
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [], noSpeechCoverage: [],
            checkpoint: nil, waitingForMoreAudio: true)
        if !arrivesBeforeFinal {
            #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now, calendar: calendar) == nil)
            _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60), start: 1_600, sequence: 1)
        }
        let resumed = try await nextAnalysis(store)
        #expect(resumed.checkpoint?.sourceFrame == 800)
        try await store.cancelEpochAnalysis(ticket: resumed)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func todayAnalysisOutranksAnAlreadyRegisteredHistoricalWindow() async throws {
        let old = try Fixture(), today = try Fixture()
        defer { old.remove(); today.remove() }
        let store = try old.store()
        _ = try await ingest(old, into: store, anchor: now.addingTimeInterval(-86_400))
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let window = try makeWindow(analysis)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window], analyzedCoverage: [window.coreFrames],
            noSpeechCoverage: [], checkpoint: checkpoint(analysis, end: window.coreFrames.end), waitingForMoreAudio: false)
        _ = try await ingest(today, into: store, anchor: now.addingTimeInterval(-60))
        let work = try #require(await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now, calendar: calendar))
        guard case .analysis(let ticket) = work else { Issue.record("Historical ASR outranked today's VAD."); return }
        #expect(ticket.sessionID == today.sessionID)
        try await store.cancelEpochAnalysis(ticket: ticket)
    }

    @Test func aThousandHistoricalChunksDoNotGetLeasedBeforeTodaysInput() async throws {
        let old = try Fixture(), current = try Fixture()
        defer { old.remove(); current.remove() }
        let store = try old.store()
        for index in 0..<1_000 {
            _ = try await ingest(old, into: store, anchor: now.addingTimeInterval(-172_800),
                start: Int64(index) * 1_600, sequence: Int64(index))
        }
        _ = try await ingest(current, into: store, anchor: now.addingTimeInterval(-60))
        let before = await store.audioContentValidationCount
        let ticket = try await nextAnalysis(store)
        #expect(ticket.sessionID == current.sessionID)
        #expect(ticket.inputs.count == 1)
        #expect(await store.audioContentValidationCount - before == 1)
        try await store.cancelEpochAnalysis(ticket: ticket)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func sameEpochCanFinishTodayBeforeYesterdayAndPreservesReplayFloorAcrossReopen() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let midnight = calendar.startOfDay(for: now)
        let anchor = midnight.addingTimeInterval(-0.05)
        _ = try await ingest(fixture, into: store, anchor: anchor)
        let second = try await ingest(fixture, into: store, anchor: anchor, start: 1_600, sequence: 1)
        try await store.applyReceipt(ReceiptApplied(receipt: #require(await store.pendingReceipts().first { $0.chunkID == second.manifest.chunkID })))
        let current = try await nextAnalysis(store)
        #expect(current.checkpoint?.sourceFrame == 800)
        try await completeSilence(current, store: store)
        #expect(try await store.analysisReplayFloors(configurationFingerprint: fingerprint)[fixture.epochID] == nil)
        let floors = try await store.analysisReplayFloors(configurationFingerprint: fingerprint)
        #expect(try await store.expireAudio(olderThan: now.addingTimeInterval(86_400), replayFloors: floors).isEmpty)
        let reopened = try fixture.store()
        let historical = try await nextAnalysis(reopened)
        #expect(historical.checkpoint == nil)
        #expect(historical.boundary == .processingRange(800))
        try await completeSilence(historical, store: reopened)
        #expect(try await reopened.analysisReplayFloors(configurationFingerprint: fingerprint)[fixture.epochID] == 3_200)
        #expect(try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).processedDuration == 0.2)
        #expect(try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).epochs.first?.closedAtFrame == nil)
    }

    @Test func samePriorityEpochsRotateAndTheTurnSurvivesReopen() async throws {
        let fixtures = try (0..<3).map { _ in try Fixture() }
        defer { fixtures.forEach { $0.remove() } }
        let store = try fixtures[0].store()
        for fixture in fixtures { _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60)) }
        var sessions = Set<UUID>()
        for _ in fixtures {
            let reopened = try fixtures[0].store()
            let ticket = try await nextAnalysis(reopened)
            sessions.insert(ticket.sessionID)
            try await reopened.cancelEpochAnalysis(ticket: ticket)
        }
        #expect(sessions.count == 3)
    }

    @Test func historyWaitsForResourceEligibilityAndCurrentFailureDoesNotBlockIt() async throws {
        let current = try Fixture(), old = try Fixture()
        defer { current.remove(); old.remove() }
        let store = try current.store()
        _ = try await ingest(old, into: store, anchor: now.addingTimeInterval(-86_400))
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, allowHistorical: false, now: now, calendar: calendar) == nil)
        _ = try await ingest(current, into: store, anchor: now.addingTimeInterval(-60))
        let first = try await nextAnalysis(store)
        #expect(first.sessionID == current.sessionID)
        try await store.deferEpochAnalysis(ticket: first, code: .recognition, now: now)
        let next = try await nextAnalysis(store)
        #expect(next.sessionID == old.sessionID)
        try await store.cancelEpochAnalysis(ticket: next)
        let retry = try await nextAnalysis(store, at: now.addingTimeInterval(6))
        #expect(retry.sessionID == current.sessionID)
        try await store.cancelEpochAnalysis(ticket: retry)
    }

    @Test func aWaitingTailDoesNotSpinOrBlockAnIndependentReceivedRange() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60))
        let first = try await nextAnalysis(store)
        try await store.commitAnalysisBatch(ticket: first, windows: [], analyzedCoverage: [], noSpeechCoverage: [],
            checkpoint: nil, waitingForMoreAudio: true)
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now, calendar: calendar) == nil)
        _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60), start: 3_200, sequence: 2)
        let prefix = try await nextAnalysis(store)
        #expect(prefix.boundary == .processingRange(1_600))
        try await completeSilence(prefix, store: store)
        let later = try await nextAnalysis(store)
        #expect(later.checkpoint?.sourceFrame == 3_200)
        try await completeSilence(later, store: store)
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint) == .awaitingAudio)
    }

    @Test func currentRecognitionDoesNotPrefetchHistoryAndFrozenWindowsRemainReserved() async throws {
        let current = try Fixture(), old = try Fixture()
        defer { current.remove(); old.remove() }
        let store = try current.store()
        _ = try await ingest(current, into: store, anchor: now.addingTimeInterval(-60))
        let analysis = try await nextAnalysis(store), window = try makeWindow(analysis)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window], analyzedCoverage: [window.coreFrames],
            noSpeechCoverage: [], checkpoint: checkpoint(analysis, end: window.coreFrames.end), waitingForMoreAudio: false)
        _ = try await ingest(old, into: store, anchor: now.addingTimeInterval(-86_400))
        #expect(try await store.claimAutomaticAnalysis(configurationFingerprint: fingerprint, activeWindow: window, now: now, calendar: calendar) == nil)
        _ = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let next = try await nextAnalysis(store)
        #expect(next.sessionID == old.sessionID)
        try await store.cancelEpochAnalysis(ticket: next)
    }

    @Test func sparseLateResultCannotCommitAfterDeletion() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await ingest(fixture, into: store, anchor: calendar.startOfDay(for: now).addingTimeInterval(-0.05))
        let ticket = try await nextAnalysis(store)
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.staleAttempt) { try await completeSilence(ticket, store: store) }
        try await store.cancelEpochAnalysis(ticket: ticket)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func recordedTimezoneAndMidnightGraceDeterminePriority() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let envelope = try fixture.envelope(), frames = envelope.manifest.frames
        let midnight = calendar.startOfDay(for: now)
        let policy = ProcessingDatePolicy(now: midnight.addingTimeInterval(60), calendar: calendar)
        let recent = try manifest(fixture, anchor: midnight.addingTimeInterval(-60), offset: 0)
        #expect(policy.priority(frames, manifest: recent) == 0)
        let old = try manifest(fixture, anchor: midnight.addingTimeInterval(-3_600), offset: 0)
        #expect(policy.priority(frames, manifest: old) == 1)
        let localToday = try manifest(fixture, anchor: midnight.addingTimeInterval(-3_600), offset: 28_800)
        #expect(policy.priority(frames, manifest: localToday) == 0)
    }

    @Test func clockSkewDoesNotSplitReceivedAudioIntoMovingSubsecondTickets() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let audio = try manifest(fixture, anchor: now, offset: -50_400)
        let received = try FrameRange(start: 0, count: 960_000)
        for elapsed in [0.0001, 0.1234, 1.2345] {
            let policy = ProcessingDatePolicy(now: now.addingTimeInterval(elapsed), calendar: calendar)
            let ranges = try policy.split(received, manifest: audio)
            #expect(ranges.count == 1)
            #expect(ranges.first?.0 == received)
            #expect(ranges.first?.1 == 0)
        }
    }

    @Test func aKnownMissingTailRemainsWaitingAfterAllReceivedAudioFinishes() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await ingest(fixture, into: store, anchor: now.addingTimeInterval(-60))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 3_200)
        try await completeSilence(nextAnalysis(store), store: store)
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint) == .awaitingAudio)
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now, calendar: calendar) == nil)
    }

    @Test func liveHotWindowOutranksSameDayMorningBacklogAndSplitsLongOpenEpoch() async throws {
        let morning = try Fixture(), live = try Fixture()
        defer { morning.remove(); live.remove() }
        let store = try morning.store()
        _ = try await ingest(morning, into: store, anchor: now.addingTimeInterval(-10_800))
        _ = try await ingest(live, into: store, anchor: now.addingTimeInterval(-120))
        let summary = try await store.livePriorityWorkSummary(configurationFingerprint: fingerprint, now: now, calendar: calendar)
        #expect(summary.hasHotLiveWork)
        #expect(summary.hasUltraHotLiveWork)
        #expect(summary.hasTodayUnreservedWork)
        #expect(summary.hotPendingSeconds > 0 && summary.hotPendingSeconds < 1.0)
        let first = try await nextAnalysis(store)
        #expect(first.sessionID == live.sessionID)
        #expect(store.isHotLiveAnalysis(first, now: now, calendar: calendar))
        try await completeSilence(first, store: store)
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint, hotOnly: true, now: now, calendar: calendar) == nil)
        let second = try await nextAnalysis(store)
        #expect(second.sessionID == morning.sessionID)
        try await completeSilence(second, store: store)

        // Verify a continuous multi-hour 16 kHz open epoch splits cleanly at the quantized 5-minute hot cutoff.
        let longOpen = try Fixture(); defer { longOpen.remove() }
        let longManifest = try manifest(longOpen, anchor: now.addingTimeInterval(-7_200), offset: 0)
        let policy = ProcessingDatePolicy(now: now, calendar: calendar)
        let segments = try policy.splitForScheduling(FrameRange(start: 0, count: 7_200 * 16_000), manifest: longManifest)
        #expect(segments.count == 2)
        #expect(segments[0].tier == 2)
        #expect(segments[1].tier == 0)
    }

    @Test func focusedTimelineDayBoostsViewedHistoricalDayBehindLiveSpeechAheadOfMorningBacklog() async throws {
        let twoDaysAgo = try Fixture(), yesterday = try Fixture(), morning = try Fixture(), live = try Fixture()
        defer { twoDaysAgo.remove(); yesterday.remove(); morning.remove(); live.remove() }
        let store = try twoDaysAgo.store()
        _ = try await ingest(twoDaysAgo, into: store, anchor: now.addingTimeInterval(-172_800))
        _ = try await ingest(yesterday, into: store, anchor: now.addingTimeInterval(-86_400))
        _ = try await ingest(morning, into: store, anchor: now.addingTimeInterval(-10_800))
        _ = try await ingest(live, into: store, anchor: now.addingTimeInterval(-120))
        let focusedYesterday = TimelineDay(now.addingTimeInterval(-86_400), calendar: calendar)

        var claimedOrder: [UUID] = []
        while let work = try await store.claimAutomaticWork(
            configurationFingerprint: fingerprint,
            focusedDay: focusedYesterday,
            now: now,
            calendar: calendar
        ) {
            guard case .analysis(let ticket) = work else { Issue.record("Expected analysis ticket"); break }
            claimedOrder.append(ticket.sessionID)
            try await completeSilence(ticket, store: store)
        }
        #expect(claimedOrder == [live.sessionID, yesterday.sessionID, morning.sessionID, twoDaysAgo.sessionID])
    }

    @Test func focusedSessionAndMaxTierPrioritizeUnpreparedYesterdaySliceAheadOfPreparedTodayBatchWindows() async throws {
        let yesterday = try Fixture(), morning = try Fixture()
        defer { yesterday.remove(); morning.remove() }
        let store = try yesterday.store()
        // Ingest morning (today Tier 2) and prepare its window into `analysis_windows`, while leaving yesterday unprepared.
        _ = try await ingest(yesterday, into: store, anchor: now.addingTimeInterval(-86_400))
        _ = try await ingest(morning, into: store, anchor: now.addingTimeInterval(-10_800))

        let morningPrep = try #require(await store.claimAutomaticWork(
            configurationFingerprint: fingerprint,
            allowHistorical: false,
            now: now,
            calendar: calendar
        ))
        guard case .analysis(let morningTicket) = morningPrep else {
            Issue.record("Expected morning analysis ticket")
            return
        }
        let morningWindow = try makeWindow(morningTicket)
        try await store.commitAnalysisBatch(
            ticket: morningTicket,
            windows: [morningWindow],
            analyzedCoverage: [morningWindow.coreFrames],
            noSpeechCoverage: [],
            checkpoint: checkpoint(morningTicket, end: morningWindow.coreFrames.end),
            waitingForMoreAudio: false
        )

        let frozen = try #require(await store.freezeTranscriptionBatch(
            configurationFingerprint: fingerprint,
            includingUnpreparedAudio: true
        ))
        let execution = try await store.beginTranscriptionBatch(id: frozen.id, origin: .foreground)

        // Without Tier-1 cap or focus, morning's already-prepared Tier-2 window would be claimed first.
        // With `focusedSessionID: yesterday.sessionID` and `maxTier: 1`, morning's Tier-2 window does NOT starve yesterday:
        let tier1WindowBeforePrep = try await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            batchExecution: execution,
            focusedSessionID: yesterday.sessionID,
            maxTier: 1,
            now: now,
            calendar: calendar
        )
        #expect(tier1WindowBeforePrep == nil)

        let tier1Prep = try #require(await store.claimTranscriptionBatchAnalysis(
            execution: execution,
            configurationFingerprint: fingerprint,
            focusedSessionID: yesterday.sessionID,
            maxTier: 1,
            now: now,
            calendar: calendar
        ))
        #expect(tier1Prep.sessionID == yesterday.sessionID)
        let yesterdayWindow = try makeWindow(tier1Prep)
        try await store.commitAnalysisBatch(
            ticket: tier1Prep,
            windows: [yesterdayWindow],
            analyzedCoverage: [yesterdayWindow.coreFrames],
            noSpeechCoverage: [],
            checkpoint: checkpoint(tier1Prep, end: yesterdayWindow.coreFrames.end),
            waitingForMoreAudio: false
        )

        let tier1WindowAfterPrep = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            batchExecution: execution,
            focusedSessionID: yesterday.sessionID,
            maxTier: 1,
            now: now,
            calendar: calendar
        ))
        #expect(tier1WindowAfterPrep.window.sessionID == yesterday.sessionID)
        _ = try await store.commitWindowTranscript(ticket: tier1WindowAfterPrep, text: "昨天优先完成", rawResult: Data())

        // Once Tier 1 is drained, `maxTier: 1` yields nil and normal claim proceeds to morning's Tier-2 window.
        #expect(try await store.claimTranscriptionBatchAnalysis(
            execution: execution,
            configurationFingerprint: fingerprint,
            focusedSessionID: yesterday.sessionID,
            maxTier: 1,
            now: now,
            calendar: calendar
        ) == nil)
        let fallbackWindow = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            batchExecution: execution,
            focusedSessionID: yesterday.sessionID,
            now: now,
            calendar: calendar
        ))
        #expect(fallbackWindow.window.sessionID == morning.sessionID)
    }

    @Test func thirtyMinuteHotWindowAndNewestFirstWithinBacklogTier() async throws {
        let earlyMorning = try Fixture(), lateMorning = try Fixture(), twelveMinWatchBatch = try Fixture()
        defer { earlyMorning.remove(); lateMorning.remove(); twelveMinWatchBatch.remove() }
        let store = try earlyMorning.store()
        _ = try await ingest(earlyMorning, into: store, anchor: now.addingTimeInterval(-14_400))
        _ = try await ingest(lateMorning, into: store, anchor: now.addingTimeInterval(-7_200))
        _ = try await ingest(twelveMinWatchBatch, into: store, anchor: now.addingTimeInterval(-720))

        let summary = try await store.livePriorityWorkSummary(configurationFingerprint: fingerprint, now: now, calendar: calendar)
        #expect(summary.hasHotLiveWork)

        var claimedOrder: [UUID] = []
        while let work = try await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: now, calendar: calendar) {
            guard case .analysis(let ticket) = work else { Issue.record("Expected analysis ticket"); break }
            claimedOrder.append(ticket.sessionID)
            try await completeSilence(ticket, store: store)
        }
        #expect(claimedOrder == [twelveMinWatchBatch.sessionID, lateMorning.sessionID, earlyMorning.sessionID])
    }

    @Test func fractionalMillisecondAnchorSplitsCleanlyWithoutTierPreemptionLivelock() async throws {
        let yesterday = try Fixture(), openToday = try Fixture()
        defer { yesterday.remove(); openToday.remove() }

        let probeNow = Date(timeIntervalSince1970: 1_793_792_522.0) // 2026-11-04T11:42:02Z
        let probeAnchor = Date(timeIntervalSince1970: 1_793_784_570.783) // 2026-11-04T09:29:30.783Z
        let probeManifest = try manifest(openToday, anchor: probeAnchor, offset: 28_800)
        let probePolicy = ProcessingDatePolicy(now: probeNow, calendar: calendar)
        let unanalyzedRange = try FrameRange(start: 77_743_760, count: 111_360_000 - 77_743_760)
        let segments = try probePolicy.splitForScheduling(unanalyzedRange, manifest: probeManifest)
        #expect(segments.count == 2)
        #expect(segments[0].tier == 2)
        #expect(!probePolicy.isHotLive(segments[0].frames, manifest: probeManifest))
        #expect(segments[1].tier == 0)
        #expect(probePolicy.isHotLive(segments[1].frames, manifest: probeManifest))

        // End-to-end ArchiveStore check: a multi-chunk today epoch with `.783` subsecond anchor spanning
        // Tier 2 -> Tier 0 alongside a focused historical Tier-1 session must never ping-pong preempt.
        let store = try yesterday.store()
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = try #require(TimeZone(secondsFromGMT: 28_800))
        let focusedYesterday = TimelineDay(probeNow.addingTimeInterval(-86_400), calendar: cst)
        _ = try await ingest(yesterday, into: store, anchor: probeNow.addingTimeInterval(-86_400))

        let wavTemplate = try openToday.envelope(frameCount: 960_000).manifest
        let todayStartAnchor = Date(timeIntervalSince1970: probePolicy.quantizedHotCutoff.timeIntervalSince1970 - 150 + 0.783)
        // 6 x 60s chunks = 6 minutes: [0..2.5m] is Tier 2 (>30m ago), [2.5m..6m] is Tier 0 (<30m ago, >120s step).
        for seq in 0..<6 {
            let start = Int64(seq) * 960_000
            let chunkManifest = try ChunkManifest(
                sessionID: openToday.sessionID, epochID: openToday.epochID, sourceDeviceID: openToday.deviceID,
                sourceBuild: "priority-test", sequence: Int64(seq), frames: FrameRange(start: start, count: 960_000),
                timebaseHz: 16_000, wallClockAnchor: todayStartAnchor, timezoneOffset: 28_800, codec: .pcmInt16,
                sampleRate: 16_000, channels: 1, decodedFrameCount: 960_000, byteCount: wavTemplate.byteCount,
                audioSHA256: wavTemplate.audioSHA256,
                sealedAt: todayStartAnchor.addingTimeInterval(Double(start + 960_000) / 16_000), sourceKind: .fixture
            )
            let env = try ManifestEnvelope(manifest: chunkManifest)
            _ = try await store.commitReceivedChunk(openToday.deliver(env, to: store))
        }

        let firstWork = try #require(await store.claimAutomaticWork(
            configurationFingerprint: fingerprint, focusedDay: focusedYesterday, now: probeNow, calendar: cst
        ))
        guard case .analysis(let firstTicket) = firstWork else {
            Issue.record("Expected Tier-0 hot live analysis first")
            return
        }
        #expect(firstTicket.sessionID == openToday.sessionID)
        #expect((firstTicket.checkpoint?.sourceFrame ?? 0) > 0)
        #expect(store.isHotLiveAnalysis(firstTicket, now: probeNow, calendar: cst))

        // Next drain iteration (~1ms later) with `activeAnalysis: firstTicket` MUST return nil (no Tier-1 preemption!).
        #expect(try await store.claimAutomaticWork(
            configurationFingerprint: fingerprint, focusedDay: focusedYesterday,
            now: probeNow, calendar: cst, activeAnalysis: firstTicket
        ) == nil)

        // Drain all Tier-0 steps on `openToday`.
        var currentTicket: EpochAnalysisTicket? = firstTicket
        while let ticket = currentTicket {
            try await completeSilence(ticket, store: store)
            if let nextHot = try await store.claimAutomaticWork(
                configurationFingerprint: fingerprint, hotOnly: true,
                focusedDay: focusedYesterday, now: probeNow, calendar: cst
            ) {
                guard case .analysis(let hotTicket) = nextHot else { break }
                currentTicket = hotTicket
            } else {
                currentTicket = nil
            }
        }

        // Once Tier 0 is complete, focused yesterday (Tier 1) runs ahead of openToday's Tier-2 prefix and is NOT preempted!
        let yesterdayWork = try #require(await store.claimAutomaticWork(
            configurationFingerprint: fingerprint, focusedDay: focusedYesterday, now: probeNow, calendar: cst
        ))
        guard case .analysis(let yesterdayTicket) = yesterdayWork else {
            Issue.record("Expected focused yesterday Tier-1 analysis ahead of Tier-2 prefix")
            return
        }
        #expect(yesterdayTicket.sessionID == yesterday.sessionID)
        #expect(try await store.claimAutomaticWork(
            configurationFingerprint: fingerprint, focusedDay: focusedYesterday,
            now: probeNow, calendar: cst, activeAnalysis: yesterdayTicket
        ) == nil)
        try await completeSilence(yesterdayTicket, store: store)

        // Finally, openToday's Tier-2 prefix drains cleanly.
        let prefixWork = try #require(await store.claimAutomaticWork(
            configurationFingerprint: fingerprint, focusedDay: focusedYesterday, now: probeNow, calendar: cst
        ))
        guard case .analysis(let prefixTicket) = prefixWork else {
            Issue.record("Expected remaining Tier-2 prefix analysis")
            return
        }
        #expect(prefixTicket.sessionID == openToday.sessionID)
        #expect((prefixTicket.checkpoint?.sourceFrame ?? 0) == 0)
        try await store.cancelEpochAnalysis(ticket: prefixTicket)
    }

    private func nextAnalysis(_ store: ArchiveStore, at time: Date? = nil) async throws -> EpochAnalysisTicket {
        let work = try #require(await store.claimAutomaticWork(configurationFingerprint: fingerprint, now: time ?? now, calendar: calendar))
        guard case .analysis(let ticket) = work else { throw ArchiveError.invalidTranscript }
        return ticket
    }

    private func checkpoint(_ ticket: EpochAnalysisTicket, end: Int64) -> ArchiveCheckpoint {
        ArchiveCheckpoint(sessionID: ticket.sessionID, epochID: ticket.epochID, sourceFrame: end, configurationFingerprint: fingerprint)
    }

    private func completeSilence(_ ticket: EpochAnalysisTicket, store: ArchiveStore) async throws {
        let end = min(try #require(ticket.inputs.last).envelope.manifest.frames.end, ticket.boundary.endFrame ?? .max)
        let range = try FrameRange(start: ticket.checkpoint?.sourceFrame ?? 0, count: end - (ticket.checkpoint?.sourceFrame ?? 0))
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [range], noSpeechCoverage: [range],
            checkpoint: checkpoint(ticket, end: end), waitingForMoreAudio: false)
    }

    private func makeWindow(_ ticket: EpochAnalysisTicket) throws -> ArchiveAnalysisWindow {
        let input = try #require(ticket.inputs.first), m = input.envelope.manifest
        return ArchiveAnalysisWindow(id: ContentHash.sha256(Data(m.chunkID.uuidString.utf8)), sessionID: m.sessionID,
            epochID: m.epochID, analysisAnchor: m.frames.start, coreFrames: m.frames, contextFrames: m.frames,
            modelCoreFrames: m.frames, modelContextFrames: m.frames,
            sources: [ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: input.envelope.manifestSHA256,
                audioSHA256: m.audioSHA256, sourceFrames: m.frames)], configurationFingerprint: fingerprint)
    }

    @discardableResult private func ingest(_ fixture: Fixture, into store: ArchiveStore, anchor: Date,
                                           start: Int64 = 0, sequence: Int64 = 0) async throws -> ManifestEnvelope {
        let envelope = try ManifestEnvelope(manifest: manifest(fixture, anchor: anchor, start: start, sequence: sequence))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        return envelope
    }

    private func manifest(_ fixture: Fixture, anchor: Date, offset: Int = 0, start: Int64 = 0, sequence: Int64 = 0) throws -> ChunkManifest {
        try ChunkManifest(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceDeviceID: fixture.deviceID,
            sourceBuild: "priority-test", sequence: sequence, frames: FrameRange(start: start, count: 1_600), timebaseHz: 16_000,
            wallClockAnchor: anchor, timezoneOffset: offset, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
            decodedFrameCount: 1_600, byteCount: Int64(fixture.audio.count), audioSHA256: ContentHash.sha256(fixture.audio),
            sealedAt: anchor.addingTimeInterval(Double(start + 1_600) / 16_000), sourceKind: .fixture)
    }
}

private extension ArchiveStore {
    func markReviewAudioUnavailable(epochID: UUID) throws {
        try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE epoch_id=?", [.text(epochID.uuidString)])
    }
    func receiveTestChangeCount() throws -> Int64 {
        let row = try #require(database.rows("SELECT total_changes()").first)
        return try row.requireInt(0)
    }

    func pendingAnalysisWakeCount(fingerprint: String) throws -> Int64 {
        let row = try #require(database.rows("SELECT COUNT(*) FROM analysis_epochs WHERE configuration_hash=? AND has_pending=1",
            [.text(fingerprint)]).first)
        return try row.requireInt(0)
    }
}
