import Foundation
import MoMoContracts

extension ArchiveStore {
    public func projectPendingDocuments(sessionID: UUID? = nil, includeUnchanged: Bool = true) async throws {
        var firstFailure: (any Error)?
        let ids: [UUID]
        if let sessionID {
            let pending = includeUnchanged ? "" : " AND (transcript_version>projection_version OR manifest_projected=0 OR EXISTS (SELECT 1 FROM metadata m WHERE m.key='recording_projection_pending/'||sessions.id))"
            ids = try database.rows("SELECT id FROM sessions WHERE deleted=0 AND projection_blocked=0 AND document_directory IS NOT NULL\(pending) AND id=?", [.text(sessionID.uuidString)]).map { try $0.requireUUID(0) }
        } else if includeUnchanged {
            ids = try database.rows("SELECT id FROM sessions WHERE deleted=0 AND projection_blocked=0 AND document_directory IS NOT NULL").map { try $0.requireUUID(0) }
        } else {
            ids = try database.rows("""
                SELECT id FROM sessions
                WHERE deleted=0 AND projection_blocked=0 AND document_directory IS NOT NULL
                  AND (transcript_version>projection_version OR manifest_projected=0)
                UNION
                SELECT s.id FROM metadata m
                JOIN sessions s ON m.key = 'recording_projection_pending/' || s.id
                WHERE m.key >= 'recording_projection_pending/' AND m.key < 'recording_projection_pending0'
                  AND s.deleted=0 AND s.projection_blocked=0 AND s.document_directory IS NOT NULL
                """).map { try $0.requireUUID(0) }
        }
        for id in ids {
            try Task.checkCancellation()
            guard let row = try database.rows("SELECT id,transcript_version,projection_version FROM sessions WHERE id=? AND deleted=0 AND projection_blocked=0 AND document_directory IS NOT NULL", [.text(id.uuidString)]).first else { continue }
            do {
                let inspection = try inspectRecordingFiles(sessionID: id, allowRelocation: false)
                // Only Runtime reconciliation imports edits and reports revisions to its consumers.
                guard inspection.issue == nil, inspection.automaticEdit == nil else {
                    try blockProjection(sessionID: id)
                    await Task.yield()
                    continue
                }
                try projectRecordingManifest(sessionID: id)
                if try row.requireInt(1) > row.requireInt(2) { try projectTranscript(sessionID: id) }
                try database.execute("DELETE FROM metadata WHERE key=?", [.text("recording_projection_pending/" + id.uuidString)])
                cacheVerifiedRecordingFiles(sessionID: id)
            } catch let error as CancellationError {
                throw error
            } catch {
                try blockProjection(sessionID: id)
                if firstFailure == nil { firstFailure = error }
            }
            await Task.yield()
        }
        if sessionID == nil {
            for row in try database.rows("SELECT document FROM plans WHERE state='pending'") {
                try Task.checkCancellation()
                do { try projectPlan(try WireJSON.decode(PlanDocument.self, from: row.requireData(0))) }
                catch let error as CancellationError { throw error }
                catch { if firstFailure == nil { firstFailure = error } }
            }
            do { try cleanDeletedPlanFiles() }
            catch let error as CancellationError { throw error }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }

    public func transcriptFileURL(sessionID: UUID, markdown: Bool = true) throws -> URL {
        let document = try readTranscript(sessionID: sessionID)
        guard let row = try database.rows("SELECT projection_version,projection_blocked FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first,
              row.integer(0) == document.version, row.integer(1) == 0 else { throw ArchiveError.projectionPending }
        let directory = try transcriptDirectory(sessionID: sessionID)
        let url = directory.appendingPathComponent(markdown ? "transcript.md" : "transcript.json")
        try validateRecordingPath(url)
        let expected = try markdown ? Data(transcriptMarkdown(document).utf8) : WireJSON.encode(document)
        guard files.fileExists(atPath: url.path) else {
            try blockProjection(sessionID: sessionID)
            throw ArchiveError.projectionConflict
        }
        let actual = try Data(contentsOf: url)
        let matches = actual == expected || (markdown && actual == Data(legacyTranscriptMarkdown(document).utf8))
        guard matches else {
            try blockProjection(sessionID: sessionID)
            throw ArchiveError.projectionConflict
        }
        return url
    }

    /// Accept an explicitly reconciled edit only against the version shown to its author.
    public func reconcileTranscriptFile(sessionID: UUID, fileURL: URL) throws -> TranscriptDocument {
        let directory = try transcriptDirectory(sessionID: sessionID)
        guard fileURL.standardizedFileURL == directory.appendingPathComponent("transcript.json").standardizedFileURL else { throw ArchiveError.invalidQuery }
        try validateRecordingPath(fileURL)
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalidTranscript }
        let edited = try WireJSON.decode(TranscriptDocument.self, from: data)
        guard edited.sessionID == sessionID else { throw ArchiveError.invalidTranscript }
        let document = try reviseTranscript(sessionID: sessionID, expectedVersion: edited.version, spans: edited.spans)
        // The edit has become a new authoritative version; replace both projections together with their version gate closed.
        try database.execute("UPDATE sessions SET projection_version=0,projection_blocked=0 WHERE id=?", [.text(sessionID.uuidString)])
        try projectTranscript(sessionID: sessionID)
        cacheVerifiedRecordingFiles(sessionID: sessionID)
        return document
    }

    func projectRecordingManifest(sessionID: UUID) throws {
        let url = try transcriptDirectory(sessionID: sessionID).appendingPathComponent("manifest.json")
        try validateRecordingPath(url)
        if !database.isInTransaction,
           let cached = verifiedManifestProjectionStamps[sessionID],
           cached.directoryPath == url.deletingLastPathComponent().standardizedFileURL.path,
           let row = try? database.rows(
               "SELECT manifest_projected,(SELECT COUNT(*) FROM chunks WHERE session_id=sessions.id) FROM sessions WHERE id=? AND deleted=0",
               [.text(sessionID.uuidString)]
           ).first,
           row.integer(0) == 1,
           (row.integer(1) ?? 0) == cached.chunkCount,
           let stamp = FileStatStamp.read(at: url),
           (stamp.mode & UInt16(S_IFMT)) == UInt16(S_IFREG),
           stamp == cached.manifestStamp {
            return
        }
        let chunks = try database.rows("SELECT manifest FROM chunks WHERE session_id=? ORDER BY rowid", [.text(sessionID.uuidString)]).map {
            try WireJSON.decode(ChunkManifest.self, from: $0.requireData(0))
        }
        guard !chunks.isEmpty else { return }
        let data = try WireJSON.encode(RecordingManifest(sessionID: sessionID, chunks: chunks))
        if !files.fileExists(atPath: url.path),
           try database.rows("SELECT manifest_projected FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.integer(0) == 1 {
            try blockProjection(sessionID: sessionID)
            throw ArchiveError.projectionConflict
        }
        if files.fileExists(atPath: url.path), try Data(contentsOf: url) == data {
            try database.execute("UPDATE sessions SET manifest_projected=1 WHERE id=? AND manifest_projected!=1", [.text(sessionID.uuidString)])
            recordVerifiedManifestProjection(sessionID: sessionID, manifestURL: url, chunkCount: Int64(chunks.count))
            return
        }
        try ArchiveFilePolicy.write(data, to: url)
        try database.execute("UPDATE sessions SET manifest_projected=1 WHERE id=?", [.text(sessionID.uuidString)])
        recordVerifiedManifestProjection(sessionID: sessionID, manifestURL: url, chunkCount: Int64(chunks.count))
    }

    func projectTranscript(sessionID: UUID) throws {
        let document = try readTranscript(sessionID: sessionID)
        guard let row = try database.rows("SELECT projection_version,projection_blocked,projection_hash FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first,
              row.integer(1) == 0 else { throw ArchiveError.projectionConflict }
        let version = try row.requireInt(0)
        let projectionHash = row.string(2)
        let directory = try transcriptDirectory(sessionID: sessionID)
        let jsonURL = directory.appendingPathComponent("transcript.json")
        let markdownURL = directory.appendingPathComponent("transcript.md")
        try validateRecordingPath(jsonURL)
        try validateRecordingPath(markdownURL)
        let json = try WireJSON.encode(document)
        let markdown = Data(transcriptMarkdown(document).utf8)
        if version > 0 {
            guard files.fileExists(atPath: jsonURL.path), files.fileExists(atPath: markdownURL.path) else {
                try blockProjection(sessionID: sessionID)
                throw ArchiveError.projectionConflict
            }
            let existingJSON = try Data(contentsOf: jsonURL)
            let existingMarkdown = try Data(contentsOf: markdownURL)
            let matchesLastProjection = projectionHash != nil && ContentHash.sha256(existingJSON + existingMarkdown) == projectionHash
            let matchesCurrentProjection = existingJSON == json
                && (existingMarkdown == markdown || existingMarkdown == Data(legacyTranscriptMarkdown(document).utf8))
            if !matchesLastProjection && !matchesCurrentProjection {
                var verifiedAgainstHistory = false
                var decodedHistoryVersion = false
                if let previous = try database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=?", [.text(sessionID.uuidString), .integer(version)]).first,
                   let old = try? decodeStoredTranscript(previous.requireData(0)),
                   let oldJSON = try? WireJSON.encode(old) {
                    decodedHistoryVersion = true
                    let oldMarkdown = Data(transcriptMarkdown(old).utf8)
                    let legacyOldMarkdown = Data(legacyTranscriptMarkdown(old).utf8)
                    verifiedAgainstHistory = (existingJSON == oldJSON || existingJSON == json)
                        && (existingMarkdown == oldMarkdown || existingMarkdown == legacyOldMarkdown || existingMarkdown == markdown)
                }
                let matchesLegacyUnindexedSnapshot = projectionHash == nil
                    && !decodedHistoryVersion
                    && matchesUneditedPriorProjection(existingJSON: existingJSON, existingMarkdown: existingMarkdown,
                                                      projectedVersion: version, current: document)
                if !verifiedAgainstHistory && !matchesLegacyUnindexedSnapshot {
                    try blockProjection(sessionID: sessionID)
                    throw ArchiveError.projectionConflict
                }
            }
        }
        try validateRecordingPath(directory)
        guard files.fileExists(atPath: directory.path) else { try blockProjection(sessionID: sessionID); throw ArchiveError.projectionConflict }
        try ArchiveFilePolicy.write(json, to: jsonURL)
        try ArchiveFilePolicy.write(markdown, to: markdownURL)
        try database.execute("UPDATE sessions SET projection_version=?,projection_hash=? WHERE id=?", [.integer(document.version), .text(ContentHash.sha256(json + markdown)), .text(sessionID.uuidString)])
    }

    func blockProjection(sessionID: UUID) throws {
        verifiedRecordingFilesCache.removeValue(forKey: sessionID)
        verifiedManifestProjectionStamps.removeValue(forKey: sessionID)
        try database.transaction {
            try database.execute("UPDATE sessions SET projection_blocked=1 WHERE id=?", [.text(sessionID.uuidString)])
            try invalidateAgentSources(sessionID: sessionID)
        }
    }

    func transcriptDirectory(sessionID: UUID) throws -> URL {
        guard let row = try database.rows("SELECT document_directory FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first,
              let directory = row.string(0) else { throw ArchiveError.missingRecording(sessionID) }
        let url = rootURL.appendingPathComponent(directory, isDirectory: true)
        try validateRecordingPath(url)
        return url
    }

    func transcriptMarkdown(_ document: TranscriptDocument) -> String {
        formattedTranscriptMarkdown(document, productTag: "momoagent")
    }

    func legacyTranscriptMarkdown(_ document: TranscriptDocument) -> String {
        formattedTranscriptMarkdown(document, productTag: "watchmylife")
    }

    /// Fallback when `projection_hash` is absent (pre-migration rows) and historical `transcript_versions`
    /// cannot be decoded: verifies that disk JSON + Markdown are a self-consistent, unedited prior snapshot
    /// whose spans all match the current authoritative transcript.
    func matchesUneditedPriorProjection(existingJSON: Data, existingMarkdown: Data,
                                        projectedVersion: Int64, current: TranscriptDocument) -> Bool {
        guard existingJSON.count <= 8 * 1024 * 1024,
              let prior = try? WireJSON.decode(TranscriptDocument.self, from: existingJSON),
              prior.sessionID == current.sessionID,
              prior.version == projectedVersion,
              prior.generation == current.generation,
              (try? WireJSON.encode(prior)) == existingJSON else {
            return false
        }
        let expectedMarkdown = Data(transcriptMarkdown(prior).utf8)
        let expectedLegacyMarkdown = Data(legacyTranscriptMarkdown(prior).utf8)
        guard existingMarkdown == expectedMarkdown || existingMarkdown == expectedLegacyMarkdown else {
            return false
        }
        let currentByID = Dictionary(uniqueKeysWithValues: current.spans.map { ($0.id, $0) })
        return prior.spans.allSatisfy { span in
            guard let authoritative = currentByID[span.id] else { return false }
            return authoritative.chunkID == span.chunkID
                && authoritative.frames == span.frames
                && authoritative.sourceRanges == span.sourceRanges
                && authoritative.text == span.text
        }
    }

    private func formattedTranscriptMarkdown(_ document: TranscriptDocument, productTag: String) -> String {
        var lines = ["# 转录", "", "<!-- \(productTag) session=\(document.sessionID.uuidString) version=\(document.version) generation=\(document.generation) -->", ""]
        for span in document.spans {
            lines += ["<!-- span=\(span.id.uuidString) chunk=\(span.chunkID.uuidString) start=\(span.frames.start) count=\(span.frames.count) -->", span.text, ""]
        }
        return lines.joined(separator: "\n")
    }


}


struct RecordingManifest: Codable { let sessionID: UUID; let chunks: [ChunkManifest] }
