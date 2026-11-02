import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchivePerformanceAndBatchTests {
    private let fingerprint = ContentHash.sha256(Data("perf-batch-model".utf8))
    private let eresRevision = ContentHash.sha256(Data("momo-speakers-2/pyannote-seg3+3dspeaker-eres2netv2/v1".utf8))

    private func unit192(_ a: Float, _ b: Float = 0, _ c: Float = 0) -> [Float] {
        let norm = sqrt(a * a + b * b + c * c)
        return [a / norm, b / norm, c / norm] + Array(repeating: 0, count: 189)
    }

    @Test func deferredSpeakerRematchPropagatesInBoundedBatches() async throws {
        let current = try Fixture(), h1 = try Fixture(), h2 = try Fixture(), h3 = try Fixture()
        defer { current.remove(); h1.remove(); h2.remove(); h3.remove() }
        let store = try current.store()

        let doc1 = try await appendSpeakerWindow(unit192(0.96, 0.28, 0), fixture: h1, store: store)
        let doc2 = try await appendSpeakerWindow(unit192(0.95, 0.31, 0), fixture: h2, store: store)
        let doc3 = try await appendSpeakerWindow(unit192(0.97, 0.24, 0), fixture: h3, store: store)
        let currentBefore = try await appendSpeakerWindow(unit192(1, 0, 0), fixture: current, store: store)

        let citation: TranscriptCitationSource = currentBefore.source(for: currentBefore.spans[0])
        try await store.correctSpeakers([citation], feedback: .person("小陈"), deferGlobalRematch: true)

        let updatedCurrent = try await store.readTranscript(sessionID: current.sessionID)
        #expect(updatedCurrent.spans[0].speaker == "小陈")
        #expect(updatedCurrent.spans[0].attribution?.confirmed == true)

        // Historical sessions remain untouched until background rematch batches run.
        #expect(try await store.readTranscript(sessionID: h1.sessionID).version == doc1.version)
        #expect(try await store.readTranscript(sessionID: h2.sessionID).version == doc2.version)
        #expect(try await store.readTranscript(sessionID: h3.sessionID).version == doc3.version)
        #expect(await store.pendingSpeakerRematchSessionIDs == Set([h1.sessionID, h2.sessionID, h3.sessionID]))

        let firstBatch = try await store.rematchPendingSpeakerSessionsBatch(limit: 2)
        #expect(firstBatch.updatedSessions == 2)
        #expect(firstBatch.hasMore == true)
        #expect(await store.pendingSpeakerRematchSessionIDs.count == 1)

        let secondBatch = try await store.rematchPendingSpeakerSessionsBatch(limit: 2)
        #expect(secondBatch.updatedSessions == 1)
        #expect(secondBatch.hasMore == false)
        #expect(await store.pendingSpeakerRematchSessionIDs.isEmpty)

        let idleBatch = try await store.rematchPendingSpeakerSessionsBatch(limit: 2)
        #expect(idleBatch.updatedSessions == 0)
        #expect(idleBatch.hasMore == false)

        for historical in [h1, h2, h3] {
            let rematched = try await store.readTranscript(sessionID: historical.sessionID)
            #expect(rematched.spans[0].speaker == "小陈")
            #expect(rematched.spans[0].attribution?.confirmed == false)
        }

        // Streaming full-rematch plan + per-batch step reports accurate counts and preserves matches.
        let plan = try await store.prepareFullSpeakerRematch()
        #expect(plan.sessionIDs.count == 4)
        #expect(plan.totalObservationCount == 4)
        for id in plan.sessionIDs {
            _ = try await store.rematchSpeakerSessionsStep([id])
        }
        #expect(try await store.matchedSpeakerObservationCount() == 4)
    }

    @Test func sameGenerationSourceResolutionAndBlockHistoryValidation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()

        var firstSpanSource: SourceReference?
        var twentiethSpanSource: SourceReference?
        // Append 21 spans so transcript history exercises multiple 16-span LZFSE blocks.
        for i in 0..<21 {
            let doc = try await appendSpeakerWindow(unit192(1, Float(i) * 0.02, 0), fixture: fixture, store: store, index: i)
            if i == 0 { firstSpanSource = doc.source(for: doc.spans[0]) }
            if i == 19 { twentiethSpanSource = doc.source(for: doc.spans[19]) }
        }
        let staleFirst = try #require(firstSpanSource)
        let staleTwentieth = try #require(twentiethSpanSource)

        // Unchanged historical spans across multi-block LZFSE history validate cleanly via single-block lookup.
        try await store.validateSources([staleFirst, staleTwentieth])

        // Once speaker attribution changes on those spans, direct validation rejects the old version as staleSource,
        // while resolveCurrentSpeakerSources upgrades same-generation citations to the latest version.
        try await store.correctSpeakers([staleFirst, staleTwentieth], feedback: .owner, scope: .selection, deferGlobalRematch: true)
        let afterOwner = try await store.readTranscript(sessionID: fixture.sessionID)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.validateSources([staleFirst])
        }
        await #expect(throws: ArchiveError.staleSource) {
            try await store.validateSources([staleTwentieth])
        }

        let refreshed = try await store.resolveCurrentSpeakerSources([staleFirst, staleTwentieth])
        #expect(refreshed.allSatisfy { $0.transcriptVersion == afterOwner.version })
        try await store.correctSpeakers([refreshed[1]], feedback: .person("小明"), scope: .selection, deferGlobalRematch: true)
        let updated = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(updated.spans[0].speaker == "我")
        #expect(updated.spans[19].speaker == "小明")
    }

    @Test func seedCandidateCompletionDefersCrossSessionRematchToBatches() async throws {
        let seededSession = try Fixture(), h1 = try Fixture(), h2 = try Fixture()
        defer { seededSession.remove(); h1.remove(); h2.remove() }
        let store = try seededSession.store()

        let legacyRev = ContentHash.sha256(Data("legacy-speaker-256".utf8))
        let legacyVec: [Float] = [1] + Array(repeating: 0, count: 255)
        let seededDoc = try await appendSpeakerWindow(legacyVec, fixture: seededSession, store: store, revision: legacyRev)
        try await store.correctSpeaker(seededDoc.source(for: seededDoc.spans[0]), feedback: .person("林老师"))

        // Unrelated historical sessions already carry 192-dim observations awaiting a 192-dim seed.
        let h1Before = try await appendSpeakerWindow(unit192(0.96, 0.28, 0), fixture: h1, store: store, revision: eresRevision)
        let h2Before = try await appendSpeakerWindow(unit192(0.95, 0.31, 0), fixture: h2, store: store, revision: eresRevision)
        #expect(h1Before.spans[0].speaker != "林老师")
        #expect(h2Before.spans[0].speaker != "林老师")

        let candidate = try #require(await store.claimNextVoiceprintSeedCandidate(modelRevision: eresRevision))
        #expect(candidate.sessionID == seededSession.sessionID)
        try await store.completeVoiceprintSeedCandidate(
            candidate,
            modelRevision: eresRevision,
            extracted: (embedding: unit192(1, 0, 0), cleanSeconds: 3.4)
        )

        // Seed completion does not synchronously rewrite unrelated sessions.
        #expect(try await store.readTranscript(sessionID: h1.sessionID).version == h1Before.version)
        #expect(try await store.readTranscript(sessionID: h2.sessionID).version == h2Before.version)
        #expect(await store.pendingSpeakerRematchSessionIDs.isSuperset(of: [h1.sessionID, h2.sessionID]))

        let result = try await store.rematchPendingSpeakerSessionsBatch(limit: 6)
        #expect(result.updatedSessions == 2)
        #expect(result.hasMore == false)
        #expect(try await store.readTranscript(sessionID: h1.sessionID).spans[0].speaker == "林老师")
        #expect(try await store.readTranscript(sessionID: h2.sessionID).spans[0].speaker == "林老师")
    }

    @Test func deferUnclaimableBatchItemsUnblocksCompletionWhenMembersLoseAudioOrProjection() async throws {
        let healthy = try Fixture(), blocked = try Fixture(), missingAudio = try Fixture()
        defer { healthy.remove(); blocked.remove(); missingAudio.remove() }
        let store = try healthy.store()

        // Make `blocked` a projected session first, then prepare a new window for it in the batch.
        let initialBlocked = try await receiveChunk(blocked, store: store, sequence: 0)
        _ = try await prepareWindow(initialBlocked, store: store)
        let initTicket = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            sessionID: blocked.sessionID,
            expectedGeneration: 0
        ))
        _ = try await store.commitWindowTranscript(ticket: initTicket, text: "已投影内容。", rawResult: Data("{}".utf8))
        try await store.projectPendingDocuments()

        let nextBlocked = try await receiveChunk(blocked, store: store, sequence: 1)
        _ = try await prepareWindow(nextBlocked, store: store)
        let missingEnv = try await receiveChunk(missingAudio, store: store, sequence: 0)
        _ = try await prepareWindow(missingEnv, store: store)
        let healthyEnv = try await receiveChunk(healthy, store: store, sequence: 0)
        _ = try await prepareWindow(healthyEnv, store: store)

        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        #expect(batch.windowIDs.count == 3)
        let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)

        // Break projection on `blocked` so `projection_blocked` becomes 1, and delete audio on `missingAudio`.
        let blockedMarkdown = try await store.transcriptFileURL(sessionID: blocked.sessionID)
        try FileManager.default.removeItem(at: blockedMarkdown)
        try await store.projectPendingDocuments()

        let missingLease = try await store.acquireAudioLease(chunkID: missingEnv.manifest.chunkID)
        await store.releaseAudioLease(id: missingLease.id)
        try FileManager.default.removeItem(at: missingLease.audioURL)

        // Claim and complete the healthy session; the damaged/blocked sessions cannot be claimed.
        let claimed = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            batchExecution: execution,
            isolateLocalFailures: true
        ))
        #expect(claimed.window.sessionID == healthy.sessionID)
        _ = try await store.commitWindowTranscript(ticket: claimed, text: "健康会话顺利完成。", rawResult: Data("{}".utf8))

        #expect(try await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            batchExecution: execution,
            isolateLocalFailures: true
        ) == nil)

        // Note: `claimTranscriptionWindow(..., isolateLocalFailures: true)` already deferred `missingAudio` when it detected missing audio,
        // while `blocked` (`projection_blocked = 1`) was skipped by SQL and still holds the batch open!
        await #expect(throws: TranscriptionBatchError.incomplete) {
            try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        }

        let deferredCount = try await store.deferUnclaimableBatchItems(
            execution: execution,
            configurationFingerprint: fingerprint
        )
        #expect(deferredCount >= 1)

        let completed = try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        #expect(completed.state == .completed)
        #expect(abs(completed.completedDuration + completed.removedDuration - completed.totalDuration) < 0.000001)
        #expect(completed.removedDuration > 0)
    }

    @Test func residualAnalyzedBoundaryGapsAndLivePriorityWorkNeverWedgeBatches() async throws {
        let batchMember = try Fixture()
        let liveSession = try Fixture()
        defer { batchMember.remove(); liveSession.remove() }
        let store = try batchMember.store()

        let rawEnv = try await receiveChunk(batchMember, store: store, sequence: 0)
        let batch = try #require(await store.freezeTranscriptionBatch(
            configurationFingerprint: fingerprint,
            includingUnpreparedAudio: true
        ))
        let fixtureToday = Date(timeIntervalSince1970: 1_790_000_100)
        // While all existing work is reserved by `batch`, there is no unreserved priority-0 work.
        #expect(try await store.hasUnreservedPriorityWork(configurationFingerprint: fingerprint, now: fixtureToday) == false)

        // When a brand-new live Watch chunk arrives outside the frozen batch, priority-0 work is immediately detected.
        _ = try await receiveChunk(liveSession, store: store, sequence: 0)
        #expect(try await store.hasUnreservedPriorityWork(configurationFingerprint: fingerprint, now: fixtureToday) == true)

        // Analyze `batchMember` with sub-window boundary gaps ([350..<400] and [1200..<1250] analyzed, neither window nor no_speech).
        let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        let analysisTicket = try #require(await store.claimTranscriptionBatchAnalysis(
            execution: execution,
            configurationFingerprint: fingerprint
        ))
        let manifest = rawEnv.manifest
        let core = try FrameRange(start: 400, count: 800)
        let window = ArchiveAnalysisWindow(
            id: ContentHash.sha256(Data((rawEnv.manifestSHA256 + fingerprint + "-gap").utf8)),
            sessionID: manifest.sessionID,
            epochID: manifest.epochID,
            analysisAnchor: 0,
            coreFrames: core,
            contextFrames: manifest.frames,
            modelCoreFrames: core,
            modelContextFrames: manifest.frames,
            sources: [ArchiveWindowSource(
                chunkID: manifest.chunkID,
                manifestSHA256: rawEnv.manifestSHA256,
                audioSHA256: manifest.audioSHA256,
                sourceFrames: manifest.frames
            )],
            configurationFingerprint: fingerprint
        )
        try await store.commitAnalysisBatch(
            ticket: analysisTicket,
            windows: [window],
            analyzedCoverage: [manifest.frames],
            noSpeechCoverage: [FrameRange(start: 0, count: 350), FrameRange(start: 1_250, count: 350)],
            checkpoint: ArchiveCheckpoint(
                sessionID: manifest.sessionID,
                epochID: manifest.epochID,
                sourceFrame: manifest.frames.end,
                configurationFingerprint: fingerprint
            ),
            waitingForMoreAudio: false
        )
        let claimed = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            batchExecution: execution,
            isolateLocalFailures: true
        ))
        _ = try await store.commitWindowTranscript(ticket: claimed, text: "批次内识别完成。", rawResult: Data("{}".utf8))

        let deferredCount = try await store.deferUnclaimableBatchItems(
            execution: execution,
            configurationFingerprint: fingerprint
        )
        #expect(deferredCount >= 1)
        let finished = try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        #expect(finished.state == .completed)
    }

    @Test func processingWaitStatePrioritizesRunnableAndContextWorkAcrossSessions() async throws {
        let damaged = try Fixture(), gap = try Fixture(), waiting = try Fixture(), runnable = try Fixture()
        defer { damaged.remove(); gap.remove(); waiting.remove(); runnable.remove() }
        let store = try damaged.store()

        // 1. Damaged session -> unavailableAudio
        let badEnv = try damaged.envelope()
        _ = try await store.commitReceivedChunk(damaged.deliver(badEnv, to: store))
        let lease = try await store.acquireAudioLease(chunkID: badEnv.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        _ = try await store.claimEpochAnalysis(
            configurationFingerprint: fingerprint,
            sessionID: damaged.sessionID,
            expectedGeneration: 0,
            isolateLocalFailures: true
        )
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint, sessionID: damaged.sessionID) == .unavailableAudio)

        // 2. Gap session -> awaitingAudio (sequence 1 without sequence 0)
        _ = try await store.commitReceivedChunk(gap.deliver(gap.envelope(startFrame: 1_600, sequence: 1), to: store))
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint, sessionID: gap.sessionID) == .awaitingAudio)

        // 3. Waiting session -> awaitingContext
        _ = try await store.commitReceivedChunk(waiting.deliver(waiting.envelope(), to: store))
        let waitTicket = try #require(await store.claimEpochAnalysis(
            configurationFingerprint: fingerprint,
            sessionID: waiting.sessionID,
            expectedGeneration: 0
        ))
        try await store.commitAnalysisBatch(
            ticket: waitTicket,
            windows: [],
            analyzedCoverage: [],
            noSpeechCoverage: [],
            checkpoint: nil,
            waitingForMoreAudio: true
        )
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint, sessionID: waiting.sessionID) == .awaitingContext)
        // Global state must report awaitingContext rather than being masked by damaged/gap sessions.
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint) == .awaitingContext)

        // 4. Runnable session -> global state reports queued ahead of awaitingContext / unavailableAudio / awaitingAudio.
        _ = try await store.commitReceivedChunk(runnable.deliver(runnable.envelope(), to: store))
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint) == .queued)
    }

    @Test func verifiedRecordingFilesCacheInvalidatesOnExternalEditAndDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()

        let initialDoc = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()

        #expect(try await store.recordingFileIssues().isEmpty)
        #expect(await store.verifiedRecordingFilesCache[fixture.sessionID] != nil)
        // Second call exercises the stat-stamp fast path.
        #expect(try await store.recordingFileIssues().isEmpty)

        // 1. Valid external edit to transcript.md invalidates the cache and is auto-imported on reconcile.
        let markdownURL = try await store.transcriptFileURL(sessionID: fixture.sessionID)
        let originalMarkdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let editedMarkdown = originalMarkdown.replacingOccurrences(of: "整理下周安排", with: "更新下周计划")
        try Data(editedMarkdown.utf8).write(to: markdownURL)
        #expect(try await store.recordingFileIssues().isEmpty)
        #expect(await store.verifiedRecordingFilesCache[fixture.sessionID] == nil)
        let reconciled = try await store.reconcileDocumentFiles()
        #expect(reconciled.first?.didRevise == true)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).version == initialDoc.version + 1)
        #expect(await store.verifiedRecordingFilesCache[fixture.sessionID] != nil)

        // 2. Corrupt external edit to transcript.json must invalidate the cache and surface `.invalidEdit`.
        let jsonURL = markdownURL.deletingLastPathComponent().appendingPathComponent("transcript.json")
        try Data("not-valid-json".utf8).write(to: jsonURL)
        let editIssues = try await store.recordingFileIssues()
        #expect(editIssues.count == 1)
        #expect(editIssues.first?.sessionID == fixture.sessionID)
        #expect(editIssues.first?.kind == .invalidEdit)

        _ = try await store.resolveRecordingFiles(#require(editIssues.first), choosing: .restoreDatabase)
        #expect(try await store.recordingFileIssues().isEmpty)
        #expect(await store.verifiedRecordingFilesCache[fixture.sessionID] != nil)

        // 3. Deleting manifest.json must also be detected immediately.
        let manifestURL = markdownURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        let missingIssues = try await store.recordingFileIssues()
        #expect(missingIssues.count == 1)
        #expect(missingIssues.first?.kind == .missingFiles)
    }

    @Test func repairMarkerInboxLimitAndIncrementalHistoryReclaimBehaveIdempotently() async throws {
        let fixture = try Fixture(), inboxFixture = try Fixture()
        defer { fixture.remove(); inboxFixture.remove() }
        let store = try fixture.store()

        let markerURL = store.rootURL
            .appendingPathComponent("Library/Application Support/MoMoAgent/.file-protection-repaired-v1")
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        await store.repairFileProtectionIfNeeded()
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        await store.repairFileProtectionIfNeeded()
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        // Incremental transcript history reclaim without blocking full VACUUM
        let first = try await fixture.transcribe(store)
        let seeded = try await store.seedLegacyHistory(first: first, count: 30)
        while try await store.compactTranscriptHistoryBatch(limit: 16) > 0 {}
        #expect(await store.compactedBytesPendingVacuum > 0)

        try await store.reclaimCompactedTranscriptStorage(fullVacuum: false)
        #expect(await store.compactedBytesPendingVacuum == 0)
        #expect(try await store.checkHistoryIntegrity())
        let markerRows = try await store.database.rows("SELECT 1 FROM metadata WHERE key='transcript_history_reclaim'")
        #expect(markerRows.isEmpty)
        for doc in seeded {
            let historical = try await store.readHistoricalDocument(sessionID: doc.sessionID, version: doc.version)
            #expect(historical.spans == doc.spans)
        }

        // Bounded inbox listing
        for seq: Int64 in 0..<3 {
            _ = try inboxFixture.deliver(inboxFixture.envelope(startFrame: seq * 1_600, sequence: seq), to: store)
        }
        await #expect(throws: ArchiveError.invalidQuery) {
            _ = try await store.listPendingInboxItems(limit: -1)
        }
        #expect(try await store.listPendingInboxItems(limit: 0).isEmpty)
        let limited = try await store.listPendingInboxItems(limit: 2)
        let allItems = try await store.listPendingInboxItems()
        #expect(limited.count == 2)
        #expect(allItems.count == 3)
        #expect(limited.map(\.id) == Array(allItems.prefix(2).map(\.id)))
        _ = try await store.processInbox()
    }

    private func receiveChunk(_ fixture: Fixture, store: ArchiveStore, sequence: Int64) async throws -> ManifestEnvelope {
        let envelope = try fixture.envelope(startFrame: sequence * 1_600, sequence: sequence)
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        return envelope
    }

    private func prepareWindow(_ envelope: ManifestEnvelope, store: ArchiveStore) async throws -> ArchiveAnalysisWindow {
        let manifest = envelope.manifest
        let ticket = try #require(await store.claimEpochAnalysis(
            configurationFingerprint: fingerprint,
            sessionID: manifest.sessionID,
            expectedGeneration: 0
        ))
        let core = try FrameRange(start: manifest.frames.start + 400, count: 800)
        let window = try ArchiveAnalysisWindow(
            id: ContentHash.sha256(Data((envelope.manifestSHA256 + fingerprint).utf8)),
            sessionID: manifest.sessionID,
            epochID: manifest.epochID,
            analysisAnchor: manifest.frames.start,
            coreFrames: core,
            contextFrames: manifest.frames,
            modelCoreFrames: FrameRange(start: 400, count: 800),
            modelContextFrames: FrameRange(start: 0, count: 1_600),
            sources: [ArchiveWindowSource(
                chunkID: manifest.chunkID,
                manifestSHA256: envelope.manifestSHA256,
                audioSHA256: manifest.audioSHA256,
                sourceFrames: manifest.frames
            )],
            configurationFingerprint: fingerprint
        )
        try await store.commitAnalysisBatch(
            ticket: ticket,
            windows: [window],
            analyzedCoverage: [manifest.frames],
            noSpeechCoverage: [FrameRange(start: manifest.frames.start, count: 400), FrameRange(start: core.end, count: 400)],
            checkpoint: ArchiveCheckpoint(
                sessionID: manifest.sessionID,
                epochID: manifest.epochID,
                sourceFrame: manifest.frames.end,
                configurationFingerprint: fingerprint
            ),
            waitingForMoreAudio: true
        )
        return window
    }

    private func appendSpeakerWindow(_ embedding: [Float], fixture: Fixture, store: ArchiveStore,
                                     index: Int = 0, revision: String? = nil) async throws -> TranscriptDocument {
        let rev = revision ?? eresRevision
        let envelope = try fixture.envelope(startFrame: Int64(index) * 64_000, frameCount: 64_000, sequence: Int64(index))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(
            configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID,
            expectedGeneration: 0
        ))
        let manifest = envelope.manifest, frames = manifest.frames
        let window = ArchiveAnalysisWindow(
            id: ContentHash.sha256(Data("\(fixture.sessionID)-\(index)".utf8)),
            sessionID: fixture.sessionID,
            epochID: fixture.epochID,
            analysisAnchor: ticket.checkpoint?.sourceFrame ?? 0,
            coreFrames: frames,
            contextFrames: frames,
            modelCoreFrames: try FrameRange(start: frames.start - (ticket.checkpoint?.sourceFrame ?? 0), count: frames.count),
            modelContextFrames: try FrameRange(start: frames.start - (ticket.checkpoint?.sourceFrame ?? 0), count: frames.count),
            sources: [.init(
                chunkID: manifest.chunkID,
                manifestSHA256: envelope.manifestSHA256,
                audioSHA256: manifest.audioSHA256,
                sourceFrames: frames
            )],
            configurationFingerprint: fingerprint
        )
        try await store.commitAnalysisBatch(
            ticket: ticket,
            windows: [window],
            analyzedCoverage: [frames],
            noSpeechCoverage: [],
            checkpoint: ArchiveCheckpoint(
                sessionID: fixture.sessionID,
                epochID: fixture.epochID,
                sourceFrame: frames.end,
                configurationFingerprint: fingerprint
            ),
            waitingForMoreAudio: true
        )
        let recognition = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            sessionID: fixture.sessionID,
            expectedGeneration: 0
        ))
        let parts = [SpeakerTranscriptPart(
            text: "测试语音 \(index)",
            frames: frames,
            evidence: .init(start: 0, end: 4, localSpeaker: 1, embedding: embedding, cleanSeconds: 3.5, modelRevision: rev)
        )]
        return try await store.commitWindowTranscript(
            ticket: recognition,
            text: "测试语音 \(index)",
            rawResult: Data(),
            speakerParts: parts
        )
    }
}
