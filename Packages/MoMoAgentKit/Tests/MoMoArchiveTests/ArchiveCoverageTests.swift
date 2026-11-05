import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchiveCoverageTests {
    private let fingerprint = ContentHash.sha256(Data("coverage-configuration".utf8))

    @Test func pendingIllustrationRangesUseReceivedFramesAndExcludeOpenCaptureTail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let later = try fixture.envelope(startFrame: 3200, sequence: 2)
        for envelope in [first, later] {
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        let anchor = first.manifest.wallClockAnchor
        let before = try await store.pendingTranscriptionIntervals(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(before == [DateInterval(start: anchor, duration: 0.1), DateInterval(start: anchor.addingTimeInterval(0.2), duration: 0.1)])
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [first.manifest.frames],
            noSpeechCoverage: [first.manifest.frames], checkpoint: nil, waitingForMoreAudio: true)
        let pending = try await store.pendingTranscriptionIntervals(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(pending == [DateInterval(start: anchor.addingTimeInterval(0.2), duration: 0.1)])
        let unknown = try await store.pendingTranscriptionIntervals(sessionID: fixture.sessionID, configurationFingerprint: nil)
        #expect(unknown == before)
        let coverage = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(coverage.epochs.first?.closedAtFrame == nil)
    }

    @Test func duplicateAndOverlappingAnalysisUseFrameUnionWithoutFillingMissingAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let third = try fixture.envelope(startFrame: 3200, sequence: 2)
        for envelope in [first, third, first] {
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        let overlapping = try fixture.envelope(startFrame: 800, sequence: 3)
        await #expect(throws: ArchiveError.conflictingChunk(overlapping.manifest.chunkID)) {
            try await store.commitReceivedChunk(fixture.deliver(overlapping, to: store))
        }
        try await store.receiveEpochEnd(CaptureEpochEnded(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, endFrame: 6400, reason: .stopped))
        let gapMark = try CaptureMark(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 2000)
        try await store.receiveMark(gapMark)
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let window = try makeWindow([first], core: FrameRange(start: 600, count: 600))
        try await store.commitAnalysisBatch(ticket: ticket, windows: [window],
            analyzedCoverage: [FrameRange(start: 0, count: 600), FrameRange(start: 400, count: 800), FrameRange(start: 0, count: 600)],
            noSpeechCoverage: [FrameRange(start: 0, count: 400), FrameRange(start: 200, count: 400)],
            checkpoint: nil, waitingForMoreAudio: true)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: recognition, text: "确认下周安排", rawResult: Data("{}".utf8))
        let reopened = try fixture.store()
        let result = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        let epoch = try #require(result.epochs.first)
        #expect(epoch.received == [first.manifest.frames, third.manifest.frames])
        #expect(epoch.analyzed == [try FrameRange(start: 0, count: 1200)])
        #expect(epoch.noSpeech == [try FrameRange(start: 0, count: 600)])
        #expect(epoch.transcribed == [window.coreFrames])
        #expect(epoch.processed == epoch.analyzed)
        #expect(epoch.notReceived == (try [FrameRange(start: 1600, count: 1600), FrameRange(start: 4800, count: 1600)]))
        #expect(epoch.pending == [try FrameRange(start: 1200, count: 400), third.manifest.frames])
        #expect(epoch.pendingAnalysis == epoch.pending)
        #expect(epoch.pendingTranscription.isEmpty)
        #expect(epoch.unknownTailFromFrame == nil)
        #expect(epoch.closedAtFrame == 6400)
        #expect(epoch.marks.first?.location == .notReceived)
        #expect(epoch.marks.first?.chunkIDs.isEmpty == true)
        #expect(result.receivedDuration == 0.2)
        #expect(result.processedDuration == 0.075)
        #expect(result.watchCapturedDuration == nil)
        #expect(result.watchStatusUpdatedAt == nil)
        let other = try await reopened.recordingCoverage(sessionID: fixture.sessionID,
            configurationFingerprint: ContentHash.sha256(Data("another-model".utf8)))
        #expect(other.analyzedDuration == 0)
        #expect(other.processedDuration == 0)
    }

    @Test func closedAndOpenEpochsKeepSeparateFramesAndAnUnknownTail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let second = try differentEpoch(fixture, epochID: UUID())
        for envelope in [first, second] {
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 1600)
        for _ in 0..<2 {
            let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
            let range = try #require(ticket.inputs.first?.envelope.manifest.frames)
            try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [range], noSpeechCoverage: [range],
                checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: ticket.epochID,
                    sourceFrame: 1600, configurationFingerprint: fingerprint), waitingForMoreAudio: !ticket.epochClosed)
        }
        let result = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(result.epochs.count == 2)
        #expect(result.receivedDuration == 0.2)
        #expect(result.processedDuration == 0.2)
        #expect(result.transcribedDuration == 0)
        let closed = try #require(result.epochs.first { $0.epochID == fixture.epochID })
        let open = try #require(result.epochs.first { $0.epochID == second.manifest.epochID })
        #expect(closed.unknownTailFromFrame == nil)
        #expect(open.unknownTailFromFrame == 1600)
        #expect(open.notReceived.isEmpty)
        #expect(open.noSpeech == [second.manifest.frames])
        #expect(open.pending.isEmpty)
        #expect(result.watchCapturedDuration == nil)
    }

    @Test func marksResolveToTheCorrectChunkAndCurrentTranscriptAcrossFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [first, second] {
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 3200)
        for frame in [Int64(1500), 1600, 3200] {
            let mark = try CaptureMark(sessionID: fixture.sessionID, epochID: fixture.epochID,
                sourceDeviceID: fixture.deviceID, sourceFrame: frame)
            try await store.receiveMark(mark)
            try await store.receiveMark(mark)
        }
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let window = try makeWindow([first, second], core: FrameRange(start: 1400, count: 400))
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window],
            analyzedCoverage: [FrameRange(start: 0, count: 3200)], noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let original = try await store.commitWindowTranscript(ticket: recognition, text: "周一确认", rawResult: Data("{}".utf8))
        let span = try #require(original.spans.first)
        let revision = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: original.version,
            spans: [TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames, text: "周二确认", sourceRanges: span.sourceRanges)])
        let reopened = try fixture.store()
        let result = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        let epoch = try #require(result.epochs.first)
        #expect(epoch.marks.count == 3)
        #expect(epoch.marks[0].chunkIDs == [first.manifest.chunkID])
        #expect(epoch.marks[1].chunkIDs == [second.manifest.chunkID])
        #expect(epoch.marks[0].sources == [revision.source(for: span)])
        #expect(epoch.marks[1].sources == epoch.marks[0].sources)
        #expect(epoch.marks[2].location == .epochEnd)
        #expect(epoch.marks[2].sources.isEmpty)
        #expect(epoch.transcribed == [window.coreFrames])
        try await reopened.validateSources(epoch.marks[1].sources)
        _ = try await reopened.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        }
    }

    @Test func controlOnlyEpochHasUnknownTimebaseAndMissingAudioWithoutInventedSilence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let mark = try CaptureMark(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 100)
        try await store.receiveMark(mark)
        let open = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(open.epochs.first?.unknownTailFromFrame == 100)
        #expect(open.epochs.first?.marks.first?.location == .unknownTail)
        try await store.receiveEpochEnd(CaptureEpochEnded(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, endFrame: 4000, reason: .stopped))
        let reopened = try fixture.store()
        let epoch = try #require(await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).epochs.first)
        #expect(epoch.timebaseHz == nil)
        #expect(epoch.notReceived == [try FrameRange(start: 0, count: 4000)])
        #expect(epoch.noSpeech.isEmpty)
        #expect(epoch.received.isEmpty)
        #expect(epoch.processed.isEmpty)
        #expect(epoch.marks.first?.location == .notReceived)
        _ = try await reopened.deleteSession(id: fixture.sessionID)
        try await reopened.receiveMark(mark)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        }
    }

    @Test func persistedTerminalFailureIsDistinctFromPendingAndNoSpeech() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(first, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: fingerprint))
        try await store.failAnalysis(ticket: ticket, errorCode: "invalid-model", retryable: false)
        let reopened = try fixture.store()
        let epoch = try #require(await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).epochs.first)
        #expect(epoch.failed == [first.manifest.frames])
        #expect(epoch.failures.first?.errorCode == "invalid-model")
        #expect(epoch.pending.isEmpty)
        #expect(epoch.processed.isEmpty)
        #expect(epoch.noSpeech.isEmpty)
    }

    @Test func missingLocalOriginalPreservesReceiptHistoryWithoutBecomingSilence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        await #expect(throws: ArchiveError.missingRecording(envelope.manifest.chunkID)) {
            try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        }
        let epoch = try #require(await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).epochs.first)
        #expect(epoch.received == [envelope.manifest.frames])
        #expect(epoch.unavailableAudio == epoch.received)
        #expect(epoch.notReceived.isEmpty)
        #expect(epoch.noSpeech.isEmpty)
        #expect(epoch.pending.isEmpty)
    }

    @Test func missingModelPreservesReceivedAudioAndMarkSourcesWithoutReportingZeroProgress() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 3200)
        let mark = try CaptureMark(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 800)
        try await store.receiveMark(mark)
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let window = try makeWindow([envelope], core: envelope.manifest.frames)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window], analyzedCoverage: [envelope.manifest.frames],
            noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: true)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let document = try await store.commitWindowTranscript(ticket: recognition, text: "准备下周的评审", rawResult: Data("{}".utf8))
        let span = try #require(document.spans.first)
        let reopened = try fixture.store()
        let configured = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(configured.processedDuration == 0.1)
        let result = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: nil)
        let epoch = try #require(result.epochs.first)
        #expect(result.configurationFingerprint == nil)
        #expect(result.receivedDuration == 0.1)
        #expect(result.analyzedDuration == nil)
        #expect(result.transcribedDuration == nil)
        #expect(result.processedDuration == nil)
        #expect(epoch.received == [envelope.manifest.frames])
        #expect(epoch.notReceived == [try FrameRange(start: 1600, count: 1600)])
        #expect(epoch.closedAtFrame == 3200)
        #expect(epoch.unknownTailFromFrame == nil)
        #expect(epoch.marks.first?.mark == mark)
        #expect(epoch.marks.first?.sources == [document.source(for: span)])
        #expect(epoch.analyzed.isEmpty && epoch.transcribed.isEmpty && epoch.processed.isEmpty && epoch.noSpeech.isEmpty)
        #expect(epoch.pending.isEmpty && epoch.pendingAnalysis.isEmpty && epoch.pendingTranscription.isEmpty)
        #expect(epoch.failed.isEmpty && epoch.failures.isEmpty)
        await #expect(throws: ArchiveError.invalidQuery) {
            try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: "invalid")
        }
    }

    @Test func scopedRetryPreservesCompletedWindowAndRejectsChangedGeneration() async throws {
        let fixture = try Fixture()
        let unrelated = try Fixture()
        defer { fixture.remove(); unrelated.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        _ = try await store.commitReceivedChunk(unrelated.deliver(unrelated.envelope(), to: store))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 1600)
        let summary = try await store.recordingSummary(sessionID: fixture.sessionID)
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID, expectedGeneration: summary.generation))
        #expect(analysis.sessionID == fixture.sessionID)
        let first = try makeWindow([envelope], core: FrameRange(start: 0, count: 800))
        let second = try makeWindow([envelope], core: FrameRange(start: 800, count: 800))
        try await store.commitAnalysisBatch(ticket: analysis, windows: [first, second],
            analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        let completed = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID, expectedGeneration: summary.generation))
        let document = try await store.commitWindowTranscript(ticket: completed, text: "已经完成的正文", rawResult: Data())
        let failed = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID, expectedGeneration: summary.generation))
        try await store.cancelTranscriptionWindow(ticket: failed)
        let completedRange = TimelineAudioSource(sessionID: fixture.sessionID, generation: summary.generation,
            epochID: fixture.epochID, frames: completed.window.coreFrames, timebaseHz: envelope.manifest.timebaseHz,
            wallClockAnchor: envelope.manifest.wallClockAnchor)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID, expectedGeneration: summary.generation, sources: [completedRange]) == nil,
            "A retry of one time range must not claim pending work elsewhere in the same session.")
        let failedRange = TimelineAudioSource(sessionID: fixture.sessionID, generation: summary.generation,
            epochID: fixture.epochID, frames: failed.window.coreFrames, timebaseHz: envelope.manifest.timebaseHz,
            wallClockAnchor: envelope.manifest.wallClockAnchor)
        try await store.prepareTranscriptionRetry(sessionID: fixture.sessionID, expectedGeneration: summary.generation, sources: [failedRange])
        let retry = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID, expectedGeneration: summary.generation, sources: [failedRange]))
        #expect(retry.window.id == failed.window.id)
        #expect(retry.window.id != completed.window.id)
        try await store.cancelTranscriptionWindow(ticket: retry)
        let unchanged = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(unchanged.version == document.version)
        #expect(unchanged.spans == document.spans)
        #expect(try await store.recordingSummary(sessionID: unrelated.sessionID).transcriptVersion == 0)
        let revised = try await store.reviseTranscript(sessionID: fixture.sessionID,
            expectedVersion: document.version, spans: document.spans)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
                sessionID: fixture.sessionID, expectedGeneration: summary.generation)
        }
        await #expect(throws: ArchiveError.staleSource) {
            try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint,
                sessionID: fixture.sessionID, expectedGeneration: summary.generation)
        }
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            try await store.prepareTranscriptionRetry(sessionID: fixture.sessionID, expectedGeneration: revised.generation)
        }
    }

    @Test(arguments: [false, true])
    func punctuationMigrationKeepsLegacyFailureStoppedUntilExplicitCurrentGenerationRetry(scoped: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope(), second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [first, second] {
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        let completed = try #require(await store.claimAnalysisJob(configurationHash: fingerprint))
        #expect(completed.chunkID == first.manifest.chunkID)
        let valid = TranscriptSpan(chunkID: completed.chunkID, frames: try FrameRange(start: 0, count: 800),
            text: "保留这段有效正文与原音。")
        let original = try await store.commitTranscript(ticket: completed, spans: [valid])
        // Seed a pre-filter transcript version; new recognition commits already discard punctuation.
        let noise = TranscriptSpan(chunkID: completed.chunkID, frames: try FrameRange(start: 800, count: 800), text: "……。")
        let historical = TranscriptDocument(sessionID: original.sessionID, version: original.version + 1,
            generation: original.generation, spans: [valid, noise], updatedAt: Date())
        try await store.storeDocument(historical)
        let failed = try #require(await store.claimAnalysisJob(configurationHash: fingerprint))
        #expect(failed.chunkID == second.manifest.chunkID)
        try await store.failAnalysis(ticket: failed, errorCode: "legacy_decode_failed", retryable: false)
        try await store.projectPendingDocuments()

        let reopened = try fixture.store()
        try await reopened.recoverInterruptedJobs()
        _ = try await reopened.reconcileDocumentFiles()
        try await reopened.discardPunctuationOnlyTranscripts()
        try await reopened.projectPendingDocuments()
        let migrated = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(migrated.spans == [valid])
        #expect(migrated.version == historical.version + 1 && migrated.generation == historical.generation + 1)
        #expect(try await reopened.recordingSummary(sessionID: fixture.sessionID).transcriptionState == .failed)
        let coverage = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        let failure = try #require(coverage.epochs.first?.failures.first)
        #expect(failure.chunkID == second.manifest.chunkID && failure.errorCode == "legacy_decode_failed")
        #expect(try await reopened.claimAnalysisJob(configurationHash: fingerprint) == nil,
            "A text migration must not automatically retry a failed job.")
        await #expect(throws: ArchiveError.staleSource) {
            try await reopened.validateSources([historical.source(for: valid)])
        }
        await #expect(throws: ArchiveError.staleSource) {
            try await reopened.prepareTranscriptionRetry(sessionID: fixture.sessionID, expectedGeneration: historical.generation)
        }
        await #expect(throws: ArchiveError.staleAttempt) {
            try await reopened.commitTranscript(ticket: failed, spans: fixture.spans(failed))
        }
        for envelope in [first, second] {
            let lease = try await reopened.acquireAudioLease(chunkID: envelope.manifest.chunkID)
            let hash = try ContentHash.sha256(Data(contentsOf: lease.audioURL))
            await reopened.releaseAudioLease(id: lease.id)
            #expect(hash == envelope.manifest.audioSHA256)
        }
        if scoped {
            let completedRange = TimelineAudioSource(sessionID: fixture.sessionID, generation: migrated.generation,
                epochID: fixture.epochID, frames: first.manifest.frames, timebaseHz: first.manifest.timebaseHz,
                wallClockAnchor: first.manifest.wallClockAnchor)
            try await reopened.prepareTranscriptionRetry(sessionID: fixture.sessionID,
                expectedGeneration: migrated.generation, sources: [completedRange])
            #expect(try await reopened.claimAnalysisJob(configurationHash: fingerprint) == nil,
                "Selecting the completed range must not requeue a failed chunk outside it.")
        }
        let failedRange = TimelineAudioSource(sessionID: fixture.sessionID, generation: migrated.generation,
            epochID: fixture.epochID, frames: second.manifest.frames, timebaseHz: second.manifest.timebaseHz,
            wallClockAnchor: second.manifest.wallClockAnchor)
        try await reopened.prepareTranscriptionRetry(sessionID: fixture.sessionID,
            expectedGeneration: migrated.generation, sources: scoped ? [failedRange] : nil)
        let retry = try #require(await reopened.claimAnalysisJob(configurationHash: fingerprint))
        #expect(retry.jobID == failed.jobID && retry.chunkID == failed.chunkID)
        #expect(retry.attemptID != failed.attemptID && retry.expectedGeneration == migrated.generation)
        let retriedSpans = fixture.spans(retry)
        let recovered = try await reopened.commitTranscript(ticket: retry, spans: retriedSpans)
        #expect(recovered.spans == [valid] + retriedSpans)
        #expect(recovered.generation == migrated.generation && recovered.version == migrated.version + 1)
        #expect(try await reopened.claimAnalysisJob(configurationHash: fingerprint) == nil)
        try await reopened.discardPunctuationOnlyTranscripts()
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).version == recovered.version)
        _ = try await reopened.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            try await reopened.prepareTranscriptionRetry(sessionID: fixture.sessionID, expectedGeneration: recovered.generation)
        }
    }

    @Test func punctuationOnlyWindowCompletesWithoutTextSearchOrCitation() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: envelope.manifest.frames.end)
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let window = try makeWindow([envelope], core: envelope.manifest.frames)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window],
            analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let document = try await store.commitWindowTranscript(ticket: ticket, text: "。", rawResult: Data("raw punctuation output".utf8))
        #expect(document.spans.isEmpty)
        let day = TimelineDay(envelope.manifest.wallClockAnchor.addingTimeInterval(Double(envelope.manifest.timezoneOffset)), calendar: TimelineDay.calendar)
        let projected = try #require(await store.timelineDay(day, configurationFingerprint: fingerprint).first)
        #expect(projected.state == .complete)
        #expect(projected.omitsPunctuationOnlyResult)
        #expect(projected.references.isEmpty)
        #expect(try await store.playbackTimelines(sources: projected.sources).first?.parts.first?.audioAvailable == true)
    }

    private func makeWindow(_ envelopes: [ManifestEnvelope], core: FrameRange) throws -> ArchiveAnalysisWindow {
        let first = try #require(envelopes.first)
        let sources = try envelopes.compactMap { envelope -> ArchiveWindowSource? in
            let start = max(core.start, envelope.manifest.frames.start), end = min(core.end, envelope.manifest.frames.end)
            guard end > start else { return nil }
            return ArchiveWindowSource(chunkID: envelope.manifest.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: envelope.manifest.audioSHA256, sourceFrames: try FrameRange(start: start, count: end - start))
        }
        return ArchiveAnalysisWindow(id: ContentHash.sha256(try WireJSON.encode(core)),
            sessionID: first.manifest.sessionID, epochID: first.manifest.epochID, analysisAnchor: 0,
            coreFrames: core, contextFrames: core, modelCoreFrames: core, modelContextFrames: core,
            sources: sources, replayInputManifestHashes: envelopes.map(\.manifestSHA256), configurationFingerprint: fingerprint)
    }

    private func differentEpoch(_ fixture: Fixture, epochID: UUID) throws -> ManifestEnvelope {
        try ManifestEnvelope(manifest: ChunkManifest(sessionID: fixture.sessionID, epochID: epochID,
            sourceDeviceID: fixture.deviceID, sourceBuild: "coverage-tests", sequence: 0,
            frames: FrameRange(start: 0, count: 1600), timebaseHz: 16000,
            wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_010), timezoneOffset: 28800,
            codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: 1600,
            byteCount: Int64(fixture.audio.count), audioSHA256: ContentHash.sha256(fixture.audio), sourceKind: .fixture))
    }
}
