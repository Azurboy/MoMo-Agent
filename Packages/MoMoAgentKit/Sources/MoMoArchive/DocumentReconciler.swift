import Foundation
import MoMoContracts

public struct DocumentReconciliation: Sendable {
    public let sessionID: UUID
    public let didRevise: Bool
    public let didUnblock: Bool
    public let issue: RecordingFileIssue?
    public let result: Result<Int64, Error>
}

extension ArchiveStore {
    /// Reconcile each session independently so one conflicting edit does not hide other changes.
    public func reconcileDocumentFiles(onlyBlockedOrChanged: Bool = false) async throws -> [DocumentReconciliation] {
        let ids: [UUID]
        if onlyBlockedOrChanged {
            ids = try database.rows("""
                SELECT id FROM sessions
                WHERE deleted=0 AND document_directory IS NOT NULL
                  AND (projection_blocked!=0 OR transcript_version>projection_version OR manifest_projected=0
                       OR EXISTS (SELECT 1 FROM metadata m WHERE m.key='recording_projection_pending/'||sessions.id))
                """).map { try $0.requireUUID(0) }
        } else {
            ids = try database.rows("SELECT id FROM sessions WHERE deleted=0 AND document_directory IS NOT NULL").map { try $0.requireUUID(0) }
        }
        var results: [DocumentReconciliation] = []
        for id in ids {
            try Task.checkCancellation()
            guard let row = try database.rows("SELECT id,transcript_version,projection_blocked FROM sessions WHERE id=? AND deleted=0 AND document_directory IS NOT NULL", [.text(id.uuidString)]).first else { continue }
            let previousVersion = try row.requireInt(1)
            let wasBlocked = row.integer(2) == 1
            do {
                let inspection = try inspectRecordingFiles(sessionID: id)
                if let issue = inspection.issue {
                    try blockProjection(sessionID: id)
                    results.append(DocumentReconciliation(sessionID: id, didRevise: false, didUnblock: false, issue: issue, result: .failure(ArchiveError.projectionConflict)))
                    await Task.yield()
                    continue
                }
                if let edit = inspection.automaticEdit {
                    _ = try reviseTranscript(sessionID: id, expectedVersion: previousVersion, spans: edit)
                    try database.execute("UPDATE sessions SET projection_version=0,projection_blocked=0 WHERE id=?", [.text(id.uuidString)])
                    try projectTranscript(sessionID: id)
                    cacheVerifiedRecordingFiles(sessionID: id)
                } else {
                    try database.execute("UPDATE sessions SET projection_blocked=0 WHERE id=? AND projection_blocked!=0", [.text(id.uuidString)])
                }
                let version = try sessionTranscriptVersion(id)
                results.append(DocumentReconciliation(sessionID: id, didRevise: version > previousVersion, didUnblock: wasBlocked, issue: nil, result: .success(version)))
            } catch let error as CancellationError {
                throw error
            } catch {
                try blockProjection(sessionID: id)
                // A revision may already be committed when writing its file projection fails.
                guard let current = try database.rows("SELECT transcript_version FROM sessions WHERE id=?", [.text(id.uuidString)]).first else {
                    throw ArchiveError.missingTranscript(id)
                }
                let issue = try unreadableRecordingIssue(sessionID: id, error: error)
                results.append(DocumentReconciliation(sessionID: id, didRevise: try current.requireInt(0) > previousVersion, didUnblock: false, issue: issue, result: .failure(error)))
            }
            // Each recording is atomic; queued UI reads can run before the next one.
            await Task.yield()
        }
        return results
    }

    public func relocateRecording(sessionID: UUID, to directory: URL) throws {
        guard try !sessionIsDeleted(sessionID) else { throw ArchiveError.sessionDeleted(sessionID) }
        let destination = directory.standardizedFileURL
        try validateRecordingPath(destination)
        let original = try transcriptDirectory(sessionID: sessionID)
        guard original.standardizedFileURL.path == destination.path || !files.fileExists(atPath: original.path) else { throw ArchiveError.projectionConflict }
        guard try directoryIdentity(destination) == sessionID else { throw ArchiveError.projectionConflict }
        let relativeDirectory = relativeRecordingPath(destination)
        guard try database.rows("SELECT id FROM sessions WHERE document_directory=? AND id!=?", [.text(relativeDirectory), .text(sessionID.uuidString)]).isEmpty else { throw ArchiveError.projectionConflict }
        let chunks = try database.rows("SELECT id,relative_path,manifest,manifest_hash,retention FROM chunks WHERE session_id=?", [.text(sessionID.uuidString)])
        var changes: [(String, UUID)] = []
        for chunk in chunks {
            let filename = URL(fileURLWithPath: try chunk.requireString(1)).lastPathComponent
            let audio = destination.appendingPathComponent("audio").appendingPathComponent(filename)
            try validateRecordingPath(audio)
            let envelope = try ManifestEnvelope(manifestData: chunk.requireData(2), manifestSHA256: chunk.requireString(3))
            if chunk.string(4) == "present" {
                guard try validStoredAudio(audio, envelope: envelope) else { throw ArchiveError.projectionConflict }
            }
            let relative = String(audio.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
            changes.append((relative, try chunk.requireUUID(0)))
        }
        guard !changes.isEmpty else { throw ArchiveError.projectionConflict }
        try database.transaction {
            for (path, id) in changes { try database.execute("UPDATE chunks SET relative_path=? WHERE id=?", [.text(path), .text(id.uuidString)]) }
            try database.execute("UPDATE sessions SET document_directory=? WHERE id=?", [.text(relativeDirectory), .text(sessionID.uuidString)])
        }
        verifiedRecordingFilesCache.removeValue(forKey: sessionID)
    }

    func parseMarkdownEdit(_ text: String, original: TranscriptDocument) throws -> [TranscriptSpan] {
        let marker = "<!-- momoagent session=\(original.sessionID.uuidString) version=\(original.version) generation=\(original.generation) -->"
        let legacyMarker = "<!-- watchmylife session=\(original.sessionID.uuidString) version=\(original.version) generation=\(original.generation) -->"
        guard text.contains(marker) || text.contains(legacyMarker) else { throw ArchiveError.projectionConflict }
        let pattern = #"(?m)^<!-- span=([0-9A-Fa-f-]{36}) chunk=([0-9A-Fa-f-]{36}) start=([0-9]+) count=([0-9]+) -->$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty || original.spans.isEmpty else { throw ArchiveError.projectionConflict }
        let originals = Dictionary(uniqueKeysWithValues: original.spans.map { ($0.id, $0) })
        return try matches.enumerated().map { offset, match in
            guard let id = UUID(uuidString: ns.substring(with: match.range(at: 1))),
                  let old = originals[id],
                  old.chunkID.uuidString.lowercased() == ns.substring(with: match.range(at: 2)).lowercased(),
                  old.frames.start == Int64(ns.substring(with: match.range(at: 3))),
                  old.frames.count == Int64(ns.substring(with: match.range(at: 4))) else { throw ArchiveError.projectionConflict }
            let start = NSMaxRange(match.range)
            let end = offset + 1 < matches.count ? matches[offset + 1].range.location : ns.length
            let content = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptSpan(id: old.id, chunkID: old.chunkID, frames: old.frames, text: content, speaker: old.speaker, sourceRanges: old.sourceRanges, attribution: old.attribution, startsNewSpeakerTurn: old.startsNewSpeakerTurn)
        }
    }
}
