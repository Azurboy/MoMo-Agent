import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct RecordingFileRecoveryTests {
    @Test func uniqueMovedDirectoryReassociatesEvenAfterReadsWereBlocked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let old = try await store.transcriptFileURL(sessionID: fixture.sessionID)
        let moved = try move(old.deletingLastPathComponent(), inside: store.rootURL, name: "renamed/nested/我的资料")
        await #expect(throws: ArchiveError.projectionConflict) { try await store.transcriptFileURL(sessionID: fixture.sessionID) }
        let query = try #require(await store.recordingFileIssues().first)
        #expect(query.kind == .missingDirectory)
        #expect(query.candidateDirectories.count == 1)
        #expect(query.availableActions.isEmpty)
        #expect(try await store.transcriptDirectory(sessionID: fixture.sessionID).path == old.deletingLastPathComponent().path)
        let results = try await store.reconcileDocumentFiles()
        #expect(results.count == 1)
        #expect(results[0].issue == nil)
        #expect(!results[0].didRevise)
        #expect(try results[0].result.get() == original.version)
        #expect(try await store.transcriptFileURL(sessionID: fixture.sessionID).deletingLastPathComponent().path == moved.path)
        try await store.validateSources([original.source(for: original.spans[0])])
        let reopened = try fixture.store()
        #expect(try await reopened.recordingFileIssues().isEmpty)
        let lease = try await reopened.acquireAudioLease(chunkID: original.spans[0].chunkID)
        #expect(lease.audioURL.path.hasPrefix(moved.path + "/audio/"))
        #expect(try Data(contentsOf: lease.audioURL) == fixture.audio)
        await reopened.releaseAudioLease(id: lease.id)
    }

    @Test(arguments: [false, true]) func expiredAudioDoesNotOwnDocumentLocation(expireAll: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope(), second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [first, second] {
            guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else { Issue.record("Expected received chunk"); return }
            try await store.applyReceipt(ReceiptApplied(receipt: receipt))
            let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
            _ = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        }
        try await store.projectPendingDocuments()
        let original = try await store.readTranscript(sessionID: fixture.sessionID)
        let old = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let expired = try await store.expireAudio(olderThan: Date().addingTimeInterval(60), replayFloors: [fixture.epochID: expireAll ? 3200 : 1600])
        #expect(expired.count == (expireAll ? 2 : 1))
        let moved = try move(old, inside: store.rootURL, name: "已归档/移动")
        let reopened = try fixture.store()
        let results = try await reopened.reconcileDocumentFiles()
        #expect(results.first?.issue == nil)
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans == original.spans)
        #expect(try await reopened.transcriptDirectory(sessionID: fixture.sessionID).path == moved.path)
        #expect(try await reopened.recordings().first?.audioState == (expireAll ? .expired : .partiallyExpired))
        if !expireAll {
            let lease = try await reopened.acquireAudioLease(chunkID: second.manifest.chunkID)
            #expect(lease.audioURL.path.hasPrefix(moved.path + "/audio/"))
            await reopened.releaseAudioLease(id: lease.id)
        }
        let third = try fixture.envelope(startFrame: 3200, sequence: 2)
        _ = try await reopened.commitReceivedChunk(fixture.deliver(third, to: reopened))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let newest = try await reopened.acquireAudioLease(chunkID: third.manifest.chunkID)
        #expect(newest.audioURL.path.hasPrefix(moved.path + "/audio/"))
        await reopened.releaseAudioLease(id: newest.id)
    }

    @Test(arguments: ["transcript.json", "transcript.md", "manifest.json"]) func missingProjectionNeedsExplicitConfirmation(filename: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let removed = directory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: removed)
        let issue = try #require(await store.recordingFileIssues().first)
        #expect(issue.kind == .missingFiles)
        #expect(issue.missingFiles == [filename])
        try await store.projectPendingDocuments()
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        let preview = try await store.recordingRecoveryPreview(issue, choosing: .restoreDatabase)
        #expect(preview.spans == original.spans)
        guard case .restored(let version) = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase) else { Issue.record("Expected restore"); return }
        #expect(version == original.version)
        #expect(try await store.recordingFileIssues().isEmpty)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).generation == original.generation)
        #expect(FileManager.default.fileExists(atPath: removed.path))
    }

    @Test func deletedDirectoryDoesNotReappearFromProjectionOrNewAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        try FileManager.default.removeItem(at: directory)
        let issue = try #require(await store.recordingFileIssues().first)
        #expect(issue.kind == .missingDirectory)
        try await store.projectPendingDocuments()
        let later = try fixture.envelope(startFrame: 1600, sequence: 1)
        let item = try fixture.deliver(later, to: store)
        await #expect(throws: ArchiveError.projectionConflict) { try await store.commitReceivedChunk(item) }
        #expect(FileManager.default.fileExists(atPath: item.directoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        _ = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans == original.spans)
        #expect(try await store.recordings().first?.audioState == .missingUnexpected)
        guard case .accepted = try await store.commitReceivedChunk(item) else { Issue.record("Expected new chunk after explicit recovery"); return }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio/\(original.spans[0].chunkID).wav").path))
    }

    @Test func conflictingEditsRejectStaleChoicesAndInvalidateOldSources() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let oldSpan = original.spans[0]
        let agent = UUID()
        try await store.registerAgentSources(agentSessionID: agent, sources: [original.source(for: oldSpan)])
        try writeJSON(original, text: "选择JSON修订。", directory: directory)
        try writeMarkdown(replacing: oldSpan.text, with: "选择Markdown修订。", directory: directory)
        let results = try await store.reconcileDocumentFiles()
        let issue = try #require(results.first?.issue)
        #expect(issue.kind == .conflictingEdits)
        #expect(issue.availableActions.contains(.useJSON) && issue.availableActions.contains(.useMarkdown))
        #expect(try await store.pendingAgentCleanups().contains(agent))
        #expect(try await store.recordingRecoveryPreview(issue, choosing: .useMarkdown).spans.first?.text == "选择Markdown修订。")
        try writeJSON(original, text: "确认窗口打开后又修改。", directory: directory)
        await #expect(throws: ArchiveError.staleSource) { try await store.resolveRecordingFiles(issue, choosing: .useMarkdown) }
        #expect(try WireJSON.decode(TranscriptDocument.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json"))).spans.first?.text == "确认窗口打开后又修改。")
        let current = try #require(await store.recordingFileIssues().first)
        guard case .revised(let version) = try await store.resolveRecordingFiles(current, choosing: .useMarkdown) else { Issue.record("Expected revision"); return }
        #expect(version == original.version + 1)
        let revised = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(revised.spans.first?.text == "选择Markdown修订。")
        #expect(revised.generation == original.generation + 1)
        await #expect(throws: ArchiveError.staleSource) { try await store.validateSources([original.source(for: oldSpan)]) }
        #expect(try await store.recordingFileIssues().isEmpty)
    }

    @Test func readOnlyIssuesDoNotImportEditsAndBatchFailureDoesNotBlockHealthyRecording() async throws {
        let fixture = try Fixture(), other = try Fixture()
        defer { fixture.remove(); other.remove() }
        let store = try fixture.store()
        let blocked = try await fixture.transcribe(store), healthy = try await other.transcribe(store)
        try await store.projectPendingDocuments()
        let blockedDirectory = try await store.transcriptDirectory(sessionID: blocked.sessionID)
        let healthyDirectory = try await store.transcriptDirectory(sessionID: healthy.sessionID)
        try FileManager.default.removeItem(at: blockedDirectory.appendingPathComponent("transcript.md"))
        try writeJSON(healthy, text: "健康资料仍然导入修订。", directory: healthyDirectory)
        let issues = try await store.recordingFileIssues()
        #expect(issues.map(\.sessionID) == [blocked.sessionID])
        #expect(try await store.readTranscript(sessionID: healthy.sessionID).version == healthy.version)
        let results = try await store.reconcileDocumentFiles()
        #expect(results.first(where: { $0.sessionID == blocked.sessionID })?.issue?.kind == .missingFiles)
        #expect(results.first(where: { $0.sessionID == healthy.sessionID })?.didRevise == true)
        #expect(try await store.readTranscript(sessionID: healthy.sessionID).spans.first?.text == "健康资料仍然导入修订。")
    }

    @Test func ambiguousMovesAndSymbolicLinksAreNotFollowedOrOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let first = try move(directory, inside: store.rootURL, name: "copies/one")
        let second = first.deletingLastPathComponent().appendingPathComponent("two")
        try FileManager.default.copyItem(at: first, to: second)
        let ambiguous = try #require(await store.reconcileDocumentFiles().first?.issue)
        #expect(ambiguous.kind == .ambiguousLocation)
        #expect(ambiguous.candidateDirectories.count == 2)
        #expect(ambiguous.availableActions.isEmpty)
        try FileManager.default.moveItem(at: first, to: directory)
        try FileManager.default.removeItem(at: second)
        let external = fixture.root.appendingPathComponent("outside.md")
        let bytes = Data("外部文件，不得读取或改写。".utf8)
        try bytes.write(to: external)
        let markdown = directory.appendingPathComponent("transcript.md")
        try FileManager.default.removeItem(at: markdown)
        try FileManager.default.createSymbolicLink(at: markdown, withDestinationURL: external)
        let reopened = try fixture.store()
        let unsafe = try #require(await reopened.reconcileDocumentFiles().first?.issue)
        #expect(unsafe.kind == .unsafePath)
        #expect(unsafe.availableActions.isEmpty)
        try await reopened.projectPendingDocuments()
        #expect(try Data(contentsOf: external) == bytes)
        // URL resource values can be cached from before the regular file was replaced by a link.
        let attributes = try FileManager.default.attributesOfItem(atPath: markdown.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func recoveryBeforeTranscriptionAndConfirmedDeletionHaveExplicitOutcomes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        // Sidecars suffice to identify a move before either text projection exists.
        let moved = try move(directory, inside: store.rootURL, name: "未转写/移动")
        #expect(try await store.reconcileDocumentFiles().first?.issue == nil)
        #expect(try await store.transcriptDirectory(sessionID: fixture.sessionID).path == moved.path)
        try FileManager.default.removeItem(at: moved)
        let issue = try #require(await store.recordingFileIssues().first)
        let preview = try await store.recordingRecoveryPreview(issue, choosing: .restoreDatabase)
        #expect(preview.version == 0 && preview.spans.isEmpty)
        guard case .restored(let version) = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase) else { Issue.record("Expected empty restoration"); return }
        #expect(version == 0)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("transcript.json").path))
        try FileManager.default.removeItem(at: moved)
        let deletionIssue = try #require(await store.recordingFileIssues().first)
        guard case .deleted(let deletion) = try await store.resolveRecordingFiles(deletionIssue, choosing: .deleteRecording) else { Issue.record("Expected deletion"); return }
        #expect(deletion.sessionID == fixture.sessionID)
        #expect(try await store.recordings().isEmpty)
        let reopened = try fixture.store()
        guard case .deleted = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened)) else { Issue.record("Deletion must reject late delivery"); return }
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func schemaFiveBackfillsStableDirectoryOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        try await store.makeSchemaFiveFixture()
        let reopened = try fixture.store()
        #expect(try await reopened.transcriptDirectory(sessionID: fixture.sessionID).path == directory.path)
        #expect(try await reopened.recordingFileIssues().isEmpty)
        _ = try move(directory, inside: reopened.rootURL, name: "迁移后/移动")
        #expect(try await reopened.reconcileDocumentFiles().first?.issue == nil)
    }

    @Test func legacyMarkersAndMatchingProjectionHashSelfHealBlockedSessions() async throws {
        let legacy = try Fixture(), corruptedHistory = try Fixture()
        defer { legacy.remove(); corruptedHistory.remove() }
        let store = try legacy.store()

        // 1. Pre-rebrand WatchMyLife markdown comment + WMLH1 history envelope self-heal.
        let v1 = try await legacy.transcribe(store)
        try await store.projectPendingDocuments()
        let secondChunk = try legacy.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(legacy.deliver(secondChunk, to: store))
        let secondTicket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        let v2 = try await store.commitTranscript(ticket: secondTicket, spans: legacy.spans(secondTicket))
        try await store.projectPendingDocuments()
        let legacyDir = try await store.transcriptDirectory(sessionID: legacy.sessionID)
        try await store.simulateLegacyWatchMyLifeProjectionAndHistory(sessionID: legacy.sessionID, directory: legacyDir)

        let healedLegacy = try await store.reconcileDocumentFiles()
        let legacyResult = try #require(healedLegacy.first(where: { $0.sessionID == legacy.sessionID }))
        #expect(legacyResult.issue == nil)
        #expect(legacyResult.didUnblock)
        #expect(try await store.transcriptFileURL(sessionID: legacy.sessionID, markdown: true).lastPathComponent == "transcript.md")
        #expect(try await store.transcriptSnapshot(sessionID: legacy.sessionID, version: v1.version).document.spans == v1.spans)
        #expect(try await store.readTranscript(sessionID: legacy.sessionID).spans == v2.spans)

        // 2. Corrupted historical projection_version row self-heals when disk files match projection_hash.
        let c1 = try await corruptedHistory.transcribe(store)
        try await store.projectPendingDocuments(sessionID: corruptedHistory.sessionID)
        let extraChunk = try corruptedHistory.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(corruptedHistory.deliver(extraChunk, to: store))
        let extraTicket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        let c2 = try await store.commitTranscript(ticket: extraTicket, spans: corruptedHistory.spans(extraTicket))
        try await store.simulateCorruptedHistoricalProjectionRow(sessionID: corruptedHistory.sessionID, projectedVersion: c1.version)

        let healedCorrupted = try await store.reconcileDocumentFiles()
        let corruptedResult = try #require(healedCorrupted.first(where: { $0.sessionID == corruptedHistory.sessionID }))
        #expect(corruptedResult.issue == nil)
        #expect(corruptedResult.didUnblock)
        try await store.projectPendingDocuments(sessionID: corruptedHistory.sessionID, includeUnchanged: false)
        #expect(try await store.recordingFileIssues(sessionID: corruptedHistory.sessionID).isEmpty)
        #expect(try await store.readTranscript(sessionID: corruptedHistory.sessionID).version == c2.version)
        let projectedJSONURL = try await store.transcriptFileURL(sessionID: corruptedHistory.sessionID, markdown: false)
        let projectedJSON = try WireJSON.decode(
            TranscriptDocument.self,
            from: Data(contentsOf: projectedJSONURL)
        )
        #expect(projectedJSON.version == c2.version)
    }

    @Test func targetedReconciliationAndNullHashFallbackAndCancellationPreserveHealthySessions() async throws {
        let blockedNullHash = try Fixture(), unrelated = try Fixture()
        defer { blockedNullHash.remove(); unrelated.remove() }
        let store = try blockedNullHash.store()

        // 1. Null projection_hash + broken historical block reference self-heals via self-consistent disk snapshot.
        let v1 = try await blockedNullHash.transcribe(store)
        _ = try await unrelated.transcribe(store)
        try await store.projectPendingDocuments()

        let unrelatedURL = try await store.transcriptFileURL(sessionID: unrelated.sessionID)
        try Data("外部临时编辑".utf8).write(to: unrelatedURL)

        let secondChunk = try blockedNullHash.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(blockedNullHash.deliver(secondChunk, to: store))
        let secondTicket = try #require(try await store.claimAnalysisJob(configurationHash: "model-v1"))
        let v2 = try await store.commitTranscript(ticket: secondTicket, spans: blockedNullHash.spans(secondTicket))
        try await store.simulateUnreadableHistoryWithNullProjectionHash(
            sessionID: blockedNullHash.sessionID,
            projectedVersion: v1.version
        )

        // Targeted reconciliation heals `blockedNullHash` without touching `unrelated`.
        let targeted = try await store.reconcileDocumentFiles(onlyBlockedOrChanged: true)
        #expect(targeted.map(\.sessionID) == [blockedNullHash.sessionID])
        #expect(targeted.first?.issue == nil)
        #expect(targeted.first?.didUnblock == true)
        try await store.projectPendingDocuments(includeUnchanged: false)
        #expect(try await store.readTranscript(sessionID: blockedNullHash.sessionID).version == v2.version)
        #expect(try await store.isSessionProjectionBlocked(unrelated.sessionID) == false)

        // 2. Cancelled tasks must rethrow CancellationError and never poison projection_blocked = 1.
        let cancelledProject = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.projectPendingDocuments()
        }
        await #expect(throws: CancellationError.self) { try await cancelledProject.value }
        #expect(try await store.isSessionProjectionBlocked(blockedNullHash.sessionID) == false)

        let cancelledReconcile = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await store.reconcileDocumentFiles()
        }
        await #expect(throws: CancellationError.self) { try await cancelledReconcile.value }
        #expect(try await store.isSessionProjectionBlocked(blockedNullHash.sessionID) == false)
    }

    private func move(_ directory: URL, inside root: URL, name: String) throws -> URL {
        let destination = root.appendingPathComponent("Documents/recordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: destination)
        return destination
    }

    private func writeJSON(_ original: TranscriptDocument, text: String, directory: URL) throws {
        let span = original.spans[0]
        let revised = TranscriptDocument(sessionID: original.sessionID, version: original.version, generation: original.generation,
            spans: [TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames, text: text, speaker: span.speaker, sourceRanges: span.sourceRanges)], updatedAt: original.updatedAt)
        try WireJSON.encode(revised).write(to: directory.appendingPathComponent("transcript.json"))
    }

    private func writeMarkdown(replacing old: String, with text: String, directory: URL) throws {
        let url = directory.appendingPathComponent("transcript.md")
        let markdown = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: old, with: text)
        try Data(markdown.utf8).write(to: url)
    }
}

extension ArchiveStore {
    func makeSchemaFiveFixture() throws {
        try database.transaction {
            try restoreLegacyHistoryForTests()
            try database.execute("ALTER TABLE sessions DROP COLUMN transcript_preview")
            try database.execute("DROP TABLE analysis_range_inputs")
            try database.execute("DROP TABLE processing_turns")
            try database.execute("DROP INDEX analysis_windows_pending")
            try database.execute("DROP INDEX chunks_epoch_frames")
            try database.execute("DROP INDEX chunks_epoch_ends")
            try database.execute("ALTER TABLE analysis_epochs DROP COLUMN has_pending")
            try database.execute("DROP TABLE processing_failures")
            try database.execute("DROP TABLE reconcile_requests")
            try database.execute("DROP TABLE watch_status")
            try database.execute("DROP TABLE transcription_batch_executions")
            try database.execute("DROP TABLE transcription_batch_ranges")
            try database.execute("DROP TABLE transcription_batch_windows")
            try database.execute("DROP TABLE transcription_batches")
            try database.execute("ALTER TABLE plans DROP COLUMN projection_hash")
            try database.execute("ALTER TABLE plans DROP COLUMN revision")
            try database.execute("DROP INDEX session_document_directory")
            try database.execute("ALTER TABLE sessions DROP COLUMN document_directory")
            try database.execute("ALTER TABLE sessions DROP COLUMN manifest_projected")
            try database.execute("PRAGMA user_version=5")
        }
    }

    func simulateLegacyWatchMyLifeProjectionAndHistory(sessionID: UUID, directory: URL) throws {
        let mdURL = directory.appendingPathComponent("transcript.md")
        let jsonURL = directory.appendingPathComponent("transcript.json")
        let legacyMD = try String(contentsOf: mdURL, encoding: .utf8)
            .replacingOccurrences(of: "<!-- momoagent session=", with: "<!-- watchmylife session=")
        let mdBytes = Data(legacyMD.utf8)
        try mdBytes.write(to: mdURL)
        let jsonBytes = try Data(contentsOf: jsonURL)
        let hash = ContentHash.sha256(jsonBytes + mdBytes)
        database.compactingTranscriptHistory = true
        defer { database.compactingTranscriptHistory = false }
        for row in try database.rows("SELECT version,document FROM transcript_versions WHERE session_id=? AND storage_format=1", [.text(sessionID.uuidString)]) {
            let doc = try row.requireData(1)
            if doc.starts(with: Data("MoMoH1\n".utf8)) {
                let rewritten = Data("WMLH1\n".utf8) + doc.dropFirst(7)
                try database.execute("UPDATE transcript_versions SET document=? WHERE session_id=? AND version=?",
                    [.blob(rewritten), .text(sessionID.uuidString), .integer(try row.requireInt(0))])
            }
        }
        try database.execute("UPDATE sessions SET projection_hash=?,projection_blocked=1 WHERE id=?",
            [.text(hash), .text(sessionID.uuidString)])
        verifiedRecordingFilesCache.removeValue(forKey: sessionID)
    }

    func simulateCorruptedHistoricalProjectionRow(sessionID: UUID, projectedVersion: Int64) throws {
        database.compactingTranscriptHistory = true
        defer { database.compactingTranscriptHistory = false }
        let bogus = TranscriptDocument(sessionID: sessionID, version: projectedVersion, generation: 0, spans: [], updatedAt: Date(timeIntervalSince1970: 0))
        try database.execute("UPDATE transcript_versions SET document=?,storage_format=0 WHERE session_id=? AND version=?",
            [.blob(try WireJSON.encode(bogus)), .text(sessionID.uuidString), .integer(projectedVersion)])
        try database.execute("UPDATE sessions SET projection_blocked=1 WHERE id=?", [.text(sessionID.uuidString)])
        verifiedRecordingFilesCache.removeValue(forKey: sessionID)
    }

    func simulateUnreadableHistoryWithNullProjectionHash(sessionID: UUID, projectedVersion: Int64) throws {
        database.compactingTranscriptHistory = true
        defer { database.compactingTranscriptHistory = false }
        let corruptEnvelope = Data("MoMoH1\n{\"broken\":true}".utf8)
        try database.execute("UPDATE transcript_versions SET document=?,storage_format=1 WHERE session_id=? AND version=?",
            [.blob(corruptEnvelope), .text(sessionID.uuidString), .integer(projectedVersion)])
        try database.execute("UPDATE sessions SET projection_hash=NULL,projection_blocked=1 WHERE id=?",
            [.text(sessionID.uuidString)])
        verifiedRecordingFilesCache.removeValue(forKey: sessionID)
    }

    func isSessionProjectionBlocked(_ sessionID: UUID) throws -> Bool {
        try database.rows("SELECT projection_blocked FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.integer(0) == 1
    }
}
