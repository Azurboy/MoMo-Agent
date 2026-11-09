import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TranscriptHistoryTests {
    @Test func receiptCursorsSurvivePhysicalRowRelocationAndNewInserts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        for index in 0..<3 {
            _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(startFrame: Int64(index * 1600), sequence: Int64(index)), to: store))
        }
        let first = try await store.pendingReceiptPage(limit: 1)
        let remaining = try await store.pendingReceiptPage(after: first.scannedThrough)
        try await store.relocateRowsForVacuumTest()
        let resumed = try await store.pendingReceiptPage(after: first.scannedThrough)
        #expect(resumed.entries.map(\.receipt) == remaining.entries.map(\.receipt))
        #expect(resumed.entries.map(\.sequence) == remaining.entries.map(\.sequence))
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(startFrame: 4800, sequence: 3), to: store))
        let appended = try await store.pendingReceiptPage(after: resumed.scannedThrough)
        #expect(appended.entries.count == 1)
        #expect(appended.scannedThrough == resumed.scannedThrough + 1)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOMO_STORAGE_AUDIT_SOURCE"] != nil))
    func copiedDeviceArchivePreservesAllSnapshotsAndReclaimsPages() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["MOMO_STORAGE_AUDIT_SOURCE"])
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("Library")
        let databaseURL = root.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: databaseURL)
        let store = try fixture.store()
        let expected = try await store.snapshotHashes()
        let before = try await store.historyPayloadBytes()
        let start = Date()
        var count = 0
        while true {
            let processed = try await store.compactTranscriptHistoryBatch(limit: 8)
            count += processed
            if processed == 0 { break }
        }
        let seconds = Date().timeIntervalSince(start)
        let after = try await store.historyPayloadBytes()
        #expect(try await store.snapshotHashes() == expected)
        #expect(after < before / 5)
        try await store.reclaimCompactedTranscriptStorage(fullVacuum: true)
        #expect(try await store.checkHistoryIntegrity())
        let bytes = try databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("STORAGE_AUDIT versions=\(expected.count) migrated=\(count) payloadBefore=\(before) payloadAfter=\(after) databaseAfter=\(bytes) migrationSeconds=\(seconds)")
    }
    @Test func legacyMigrationResumesAndPreservesEveryVersionAndCurrentJSON() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await fixture.transcribe(store)
        let documents = try await store.seedLegacyHistory(first: first, count: 80)
        let original = try await store.historyPayloadBytes()
        #expect(try await store.compactTranscriptHistoryBatch(limit: 3) == 3)
        let reopened = try fixture.store()
        while try await reopened.compactTranscriptHistoryBatch(limit: 8) > 0 { }
        #expect(try await reopened.compactTranscriptHistoryBatch() == 0)
        for document in documents {
            let snapshot = try await reopened.transcriptSnapshot(sessionID: fixture.sessionID, version: document.version)
            #expect(try WireJSON.encode(snapshot.document) == WireJSON.encode(document))
        }
        #expect(try await reopened.historyPayloadBytes() < original / 5)
        #expect(try await reopened.currentHistoryFormat(sessionID: fixture.sessionID) == 0)
        let last = try #require(documents.last)
        let changed = TranscriptSpan(id: last.spans[0].id, chunkID: last.spans[0].chunkID,
            frames: last.spans[0].frames, text: "修改后的正文")
        let revised = try await reopened.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: last.version, spans: [changed])
        #expect(revised.spans == [changed])
        #expect(try await reopened.readHistoricalDocument(sessionID: fixture.sessionID, version: last.version).spans == last.spans)
        _ = try await reopened.deleteSession(id: fixture.sessionID)
        #expect(try await reopened.historyBlockCount() == 0)
    }

    @Test func interruptedTransactionKeepsOriginalSnapshotsAndNoOrphanBlocks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await fixture.transcribe(store)
        let documents = try await store.seedLegacyHistory(first: first, count: 3)
        try await store.failHistoryUpdate()
        await #expect(throws: (any Error).self) { try await store.compactTranscriptHistoryBatch() }
        #expect(try await store.historyBlockCount() == 0)
        for document in documents {
            #expect(try await store.readHistoricalDocument(sessionID: fixture.sessionID, version: document.version).spans == document.spans)
        }
        try await store.clearHistoryUpdateFailure()
        #expect(try await store.compactTranscriptHistoryBatch(limit: 8) == 2)
    }
}

extension ArchiveStore {
    func relocateRowsForVacuumTest() throws {
        for table in ["sessions", "chunks", "receipt_outbox"] {
            try database.execute("UPDATE \(table) SET rowid=-rowid")
        }
        try database.execute("VACUUM")
        database.invalidateRowLocationsAfterVacuum()
    }
    func snapshotHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for key in try database.rows("SELECT session_id,version FROM transcript_versions ORDER BY session_id,version") {
            try Task.checkCancellation()
            let id = try key.requireUUID(0), version = try key.requireInt(1)
            hashes["\(id)/\(version)"] = try ContentHash.sha256(WireJSON.encode(readHistoricalDocument(sessionID: id, version: version)))
        }
        return hashes
    }
    func checkHistoryIntegrity() throws -> Bool {
        try database.rows("PRAGMA quick_check").first?.string(0) == "ok" && database.rows("PRAGMA foreign_key_check").isEmpty
    }
    func restoreLegacyHistoryForTests() throws {
        try database.execute("DROP TABLE IF EXISTS waveform_preparations")
        for index in [
            "analysis_windows_core_ends",
            "epochs_session",
            "epochs_wall_clock",
            "analysis_windows_session",
            "analysis_windows_epoch_state",
            "analysis_windows_epoch_config_core",
            "analysis_windows_epoch_core_end",
            "analysis_windows_companion",
            "chunks_epoch_start",
            "chunks_epoch_end",
            "chunks_retention_sealed",
            "transcription_batch_ranges_session",
            "transcription_batch_windows_session",
            "sessions_active_recorded",
            "sessions_projection_pending",
            "receipt_outbox_pending",
            "deletions_pending_clean",
            "plans_state",
            "plans_pending_clean"
        ] {
            try database.execute("DROP INDEX IF EXISTS \(index)")
        }
        for col in ["start_frame", "end_frame", "byte_count", "sealed_at", "wall_clock_anchor", "timezone_offset", "timebase_hz"] {
            try database.execute("ALTER TABLE chunks DROP COLUMN \(col)")
        }
        for col in ["min_chunk_rowid", "max_received_end_frame", "wall_clock_anchor", "timezone_offset"] {
            try database.execute("ALTER TABLE epochs DROP COLUMN \(col)")
        }
        for col in ["core_start", "core_end", "context_start", "context_end", "analysis_anchor", "model_core_start"] {
            try database.execute("ALTER TABLE analysis_windows DROP COLUMN \(col)")
        }
        try database.execute("ALTER TABLE plans DROP COLUMN files_cleaned")
        try database.execute("DROP TABLE IF EXISTS voice_profile_seeds")
        try database.execute("DROP TABLE IF EXISTS speaker_feedback_anchors")
        try database.execute("DROP TABLE speaker_cluster_conflicts")
        try database.execute("DROP TABLE voice_rejections")
        try database.execute("DROP TABLE speaker_observations")
        try database.execute("DROP TABLE speaker_clusters")
        try database.execute("DROP TABLE voice_profiles")
        for table in ["sessions", "chunks", "receipt_outbox"] {
            try database.execute("DROP TRIGGER \(table)_assign_sequence")
            try database.execute("DROP INDEX \(table)_storage_sequence")
            try database.execute("ALTER TABLE \(table) DROP COLUMN storage_sequence")
        }
        for row in try database.rows("SELECT session_id,version,document FROM transcript_versions WHERE storage_format=1") {
            let bytes = try WireJSON.encode(decodeStoredTranscript(row.requireData(2)))
            try database.execute("UPDATE transcript_versions SET document=? WHERE session_id=? AND version=?",
                [.blob(bytes), .text(try row.requireString(0)), .integer(try row.requireInt(1))])
        }
        try database.execute("DROP TABLE transcript_blocks")
        try database.execute("DROP INDEX transcript_uncompacted")
        try database.execute("ALTER TABLE transcript_versions DROP COLUMN storage_format")
    }
    func seedLegacyHistory(first: TranscriptDocument, count: Int) throws -> [TranscriptDocument] {
        var documents = [first]
        try database.transaction {
            for version in 2...count {
                let span = TranscriptSpan(chunkID: first.spans[0].chunkID, frames: first.spans[0].frames,
                    text: "第\(version)段：" + String(repeating: "保留转录原文与引用。", count: 20))
                let document = TranscriptDocument(sessionID: first.sessionID, version: Int64(version), generation: first.generation,
                    spans: documents.last!.spans + [span], updatedAt: Date(timeIntervalSince1970: Double(version)))
                try database.execute("INSERT INTO transcript_versions(session_id,version,document) VALUES(?,?,?)",
                    [.text(first.sessionID.uuidString), .integer(document.version), .blob(try WireJSON.encode(document))])
                documents.append(document)
            }
            try database.execute("UPDATE sessions SET transcript_version=? WHERE id=?", [.integer(Int64(count)), .text(first.sessionID.uuidString)])
        }
        return documents
    }
    func historyPayloadBytes() throws -> Int64 {
        try database.rows("SELECT COALESCE((SELECT sum(length(document)) FROM transcript_versions),0)+COALESCE((SELECT sum(length(document)) FROM transcript_blocks),0)")[0].requireInt(0)
    }
    func historyBlockCount() throws -> Int64 { try database.rows("SELECT count(*) FROM transcript_blocks")[0].requireInt(0) }
    func currentHistoryFormat(sessionID: UUID) throws -> Int64 {
        try database.rows("SELECT storage_format FROM transcript_versions v JOIN sessions s ON s.id=v.session_id AND s.transcript_version=v.version WHERE s.id=?", [.text(sessionID.uuidString)])[0].requireInt(0)
    }
    func readHistoricalDocument(sessionID: UUID, version: Int64) throws -> TranscriptDocument {
        try decodeStoredTranscript(database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=?",
            [.text(sessionID.uuidString), .integer(version)])[0].requireData(0))
    }
    func failHistoryUpdate() throws {
        try database.execute("CREATE TRIGGER fail_history BEFORE UPDATE ON transcript_versions BEGIN SELECT RAISE(ABORT,'test interruption'); END")
    }
    func clearHistoryUpdateFailure() throws { try database.execute("DROP TRIGGER fail_history") }
}
