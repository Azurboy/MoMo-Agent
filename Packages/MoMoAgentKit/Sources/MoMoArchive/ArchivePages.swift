import Foundation
import MoMoContracts

public struct RecordingPage: Codable, Sendable {
    public let items: [RecordingSummary]
    public let nextCursor: String?
}

public struct TranscriptSearchPage: Codable, Sendable {
    public let items: [TranscriptSearchHit]
    public let nextCursor: String?
}

extension ArchiveStore {
    /// Resolves a search destination without changing the caller's paginated library window.
    public func recordingSummary(sessionID: UUID) throws -> RecordingSummary {
        guard try !sessionIsDeleted(sessionID) else { throw ArchiveError.sessionDeleted(sessionID) }
        guard let row = try database.rows("SELECT s.id,s.recorded_at,COUNT(c.id),s.transcript_version,s.generation,s.source_kind,s.keep_audio FROM sessions s LEFT JOIN chunks c ON c.session_id=s.id WHERE s.id=? AND s.deleted=0 GROUP BY s.id", [.text(sessionID.uuidString)]).first else {
            throw ArchiveError.missingRecording(sessionID)
        }
        return try recordingSummary(row: row)
    }

    private func recordingSummary(row: SQLRow) throws -> RecordingSummary {
        guard let date = row.double(1), let kind = SourceKind(rawValue: try row.requireString(5)) else { throw ArchiveError.database(11) }
        let id = try row.requireUUID(0)
        return RecordingSummary(sessionID: id, recordedAt: Date(timeIntervalSince1970: date),
            chunkCount: Int(try row.requireInt(2)), transcriptVersion: try row.requireInt(3),
            generation: try row.requireInt(4), sourceKind: kind,
            transcriptionState: try transcriptionState(sessionID: id), keepAudio: try row.requireInt(6) == 1,
            audioState: try recordingAudioState(sessionID: id))
    }

    public func recordingsPage(limit: Int = 50, cursor: String? = nil,
                               from: Date? = nil, before: Date? = nil) throws -> RecordingPage {
        let startedMs = APIPerformanceMonitor.uptimeMilliseconds()
        do {
            let page = try recordingsPageImpl(limit: limit, cursor: cursor, from: from, before: before)
            performanceMonitor.record(.recordingsPage, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: page.items.count)
            return page
        } catch {
            performanceMonitor.record(.recordingsPage, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: 0, failed: true)
            throw error
        }
    }

    private func recordingsPageImpl(limit: Int = 50, cursor: String? = nil,
                                    from: Date? = nil, before: Date? = nil) throws -> RecordingPage {
        guard (1...200).contains(limit) else { throw ArchiveError.invalidQuery }
        let scope = try pageScope(kind: "recordings", query: nil, from: from, before: before)
        let position = try pagePosition(cursor, scope: scope, search: false)
        let ceiling = try position?.sessionCeiling ?? maximumSessionRowID()
        var values = pageFilterValues(ceiling: ceiling, from: from, before: before)
        var condition = ""
        if let position {
            condition = " AND (s.recorded_at<? OR (s.recorded_at=? AND s.id>?))"
            values += [.double(position.recordedAt), .double(position.recordedAt), .text(position.sessionID.uuidString)]
        }
        values.append(.integer(Int64(limit + 1)))
        let rows = try database.rows("SELECT s.id,s.recorded_at,COUNT(c.id),s.transcript_version,s.generation,s.source_kind,s.keep_audio FROM sessions s LEFT JOIN chunks c ON c.session_id=s.id WHERE \(Self.pageFilter)\(condition) GROUP BY s.id ORDER BY s.recorded_at DESC,s.id LIMIT ?", values)
        let pageRows = Array(rows.prefix(limit))
        let sessionIDs = try pageRows.map { try $0.requireUUID(0) }
        let states = try batchSessionStates(sessionIDs: sessionIDs)
        let items = try pageRows.map { row -> RecordingSummary in
            guard let date = row.double(1), let kind = SourceKind(rawValue: try row.requireString(5)) else { throw ArchiveError.database(11) }
            let id = try row.requireUUID(0)
            return RecordingSummary(sessionID: id, recordedAt: Date(timeIntervalSince1970: date),
                chunkCount: Int(try row.requireInt(2)), transcriptVersion: try row.requireInt(3),
                generation: try row.requireInt(4), sourceKind: kind,
                transcriptionState: states.transcription[id] ?? .pending, keepAudio: try row.requireInt(6) == 1,
                audioState: states.audio[id] ?? .unavailable)
        }
        let next: String?
        if rows.count > limit, let last = items.last {
            next = try PagePosition(scope: scope, sessionCeiling: ceiling, recordedAt: last.recordedAt.timeIntervalSince1970,
                                    sessionID: last.sessionID, spanID: nil).encoded()
        } else { next = nil }
        return RecordingPage(items: items, nextCursor: next)
    }

    public func searchTranscriptsPage(query: String, limit: Int = 20, cursor: String? = nil,
                                     from: Date? = nil, before: Date? = nil) throws -> TranscriptSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 256, (1...100).contains(limit) else { throw ArchiveError.invalidQuery }
        let scope = try pageScope(kind: "search", query: query, from: from, before: before)
        let position = try pagePosition(cursor, scope: scope, search: true)
        let ceiling = try position?.sessionCeiling ?? maximumSessionRowID()
        var values = pageFilterValues(ceiling: ceiling, from: from, before: before) + [.text(query)]
        var condition = ""
        if let position, let spanID = position.spanID {
            condition = " AND (s.recorded_at<? OR (s.recorded_at=? AND (s.id>? OR (s.id=? AND t.span_id>?))))"
            values += [.double(position.recordedAt), .double(position.recordedAt), .text(position.sessionID.uuidString),
                       .text(position.sessionID.uuidString), .text(spanID.uuidString)]
        }
        values.append(.integer(Int64(limit + 1)))
        let rows = try database.rows("SELECT t.session_id,t.span_id,s.recorded_at FROM transcript_search t JOIN sessions s ON s.id=t.session_id WHERE \(Self.pageFilter) AND s.projection_blocked=0 AND instr(lower(t.text),lower(?))>0\(condition) ORDER BY s.recorded_at DESC,s.id,t.span_id LIMIT ?", values)
        let items = try rows.prefix(limit).map { row in
            let document = try readTranscript(sessionID: row.requireUUID(0))
            let id = try row.requireUUID(1)
            guard let span = document.spans.first(where: { $0.id == id }) else { throw ArchiveError.database(11) }
            return TranscriptSearchHit(source: document.source(for: span), text: span.text, frames: span.frames)
        }
        let next: String?
        if rows.count > limit, let last = items.last, let date = rows[limit - 1].double(2) {
            next = try PagePosition(scope: scope, sessionCeiling: ceiling, recordedAt: date,
                                    sessionID: last.source.sessionID, spanID: last.source.spanID).encoded()
        } else { next = nil }
        return TranscriptSearchPage(items: items, nextCursor: next)
    }

    private static let pageFilter = "s.deleted=0 AND s.storage_sequence<=? AND (? IS NULL OR s.recorded_at>=?) AND (? IS NULL OR s.recorded_at<?)"

    private func maximumSessionRowID() throws -> Int64 {
        try database.rows("SELECT COALESCE(MAX(storage_sequence),0) FROM sessions").first?.requireInt(0) ?? 0
    }

    private func pageScope(kind: String, query: String?, from: Date?, before: Date?) throws -> String {
        guard from?.timeIntervalSince1970.isFinite != false, before?.timeIntervalSince1970.isFinite != false else { throw ArchiveError.invalidQuery }
        if let from, let before, from >= before { throw ArchiveError.invalidQuery }
        return ContentHash.sha256(try WireJSON.encode(PageScope(libraryID: libraryInstanceID, kind: kind, query: query,
            from: from?.timeIntervalSince1970, before: before?.timeIntervalSince1970)))
    }

    private func pagePosition(_ cursor: String?, scope: String, search: Bool) throws -> PagePosition? {
        guard let cursor else { return nil }
        guard cursor.utf8.count <= 2_048, let data = Data(base64Encoded: cursor) else { throw ArchiveError.invalidQuery }
        let position: PagePosition
        do { position = try WireJSON.decode(PagePosition.self, from: data) }
        catch is DecodingError { throw ArchiveError.invalidQuery }
        guard position.version == 1, position.scope == scope, position.recordedAt.isFinite,
              position.sessionCeiling >= 0, (position.spanID != nil) == search else { throw ArchiveError.invalidQuery }
        return position
    }

    private func pageFilterValues(ceiling: Int64, from: Date?, before: Date?) -> [SQLValue] {
        let lower = from.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null
        let upper = before.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null
        return [.integer(ceiling), lower, lower, upper, upper]
    }

    private func batchSessionStates(sessionIDs: [UUID]) throws -> (audio: [UUID: RecordingAudioState], transcription: [UUID: RecordingTranscriptionState]) {
        guard !sessionIDs.isEmpty else { return ([:], [:]) }
        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        let idValues = sessionIDs.map { SQLValue.text($0.uuidString) }

        var retentionsBySession: [UUID: Set<String>] = [:]
        for row in try database.rows("SELECT session_id, retention FROM chunks WHERE session_id IN (\(placeholders)) GROUP BY session_id, retention", idValues) {
            retentionsBySession[try row.requireUUID(0), default: []].insert(try row.requireString(1))
        }
        let validRetentions: Set<String> = ["present", "expired", "expiry_pending", "missing_unexpected"]
        var audioStates: [UUID: RecordingAudioState] = [:]
        for id in sessionIDs {
            let values = retentionsBySession[id] ?? []
            if values.isEmpty {
                audioStates[id] = .unavailable
            } else {
                guard values.isSubset(of: validRetentions) else { throw ArchiveError.database(11) }
                if values.contains("missing_unexpected") { audioStates[id] = .missingUnexpected }
                else if values.contains("expiry_pending") { audioStates[id] = .expiryPending }
                else if values.contains("expired") { audioStates[id] = values.contains("present") ? .partiallyExpired : .expired }
                else { audioStates[id] = .available }
            }
        }

        struct JobFlags {
            var count = 0
            var failed = false
            var running = false
            var pending = false
        }
        var jobFlags: [UUID: JobFlags] = [:]
        for row in try database.rows("""
            SELECT c.session_id, j.state, c.retention, COUNT(*)
            FROM transcription_jobs j JOIN chunks c ON c.id=j.chunk_id
            WHERE c.session_id IN (\(placeholders))
            GROUP BY c.session_id, j.state, c.retention
            """, idValues) {
            let sid = try row.requireUUID(0)
            let state = row.string(1) ?? ""
            let retention = row.string(2) ?? ""
            let n = Int(row.integer(3) ?? 0)
            var flags = jobFlags[sid, default: JobFlags()]
            flags.count += n
            if state == "failed" || retention == "missing_unexpected" { flags.failed = true }
            if state == "running" { flags.running = true }
            if state == "pending" { flags.pending = true }
            jobFlags[sid] = flags
        }

        var activeAnalysis: Set<UUID> = []
        for row in try database.rows("""
            SELECT DISTINCT e.session_id FROM analysis_epochs a JOIN epochs e ON e.id=a.epoch_id
            WHERE e.session_id IN (\(placeholders)) AND a.attempt_id IS NOT NULL
            """, idValues) {
            activeAnalysis.insert(try row.requireUUID(0))
        }

        var windowStatesBySession: [UUID: Set<String>] = [:]
        for row in try database.rows("SELECT session_id, state FROM analysis_windows WHERE session_id IN (\(placeholders)) GROUP BY session_id, state", idValues) {
            windowStatesBySession[try row.requireUUID(0), default: []].insert(try row.requireString(1))
        }

        var transcriptionStates: [UUID: RecordingTranscriptionState] = [:]
        var unresolved: [UUID] = []
        for id in sessionIDs {
            let jobs = jobFlags[id, default: JobFlags()]
            let wStates = windowStatesBySession[id] ?? []
            if jobs.failed {
                transcriptionStates[id] = .failed
            } else if activeAnalysis.contains(id) || jobs.running || wStates.contains("running") {
                transcriptionStates[id] = .processing
            } else if jobs.count == 0 || jobs.pending || wStates.contains("pending") {
                transcriptionStates[id] = .pending
            } else {
                unresolved.append(id)
            }
        }

        if !unresolved.isEmpty {
            let subPlaceholders = Array(repeating: "?", count: unresolved.count).joined(separator: ",")
            let subValues = unresolved.map { SQLValue.text($0.uuidString) }
            var withText: Set<UUID> = []
            for row in try database.rows("SELECT DISTINCT session_id FROM transcript_search WHERE session_id IN (\(subPlaceholders))", subValues) {
                withText.insert(try row.requireUUID(0))
            }
            var withVersion: Set<UUID> = []
            for row in try database.rows("SELECT DISTINCT session_id FROM transcript_versions WHERE session_id IN (\(subPlaceholders))", subValues) {
                withVersion.insert(try row.requireUUID(0))
            }
            for id in unresolved {
                if withText.contains(id) {
                    transcriptionStates[id] = .transcribed
                } else if withVersion.contains(id) || (windowStatesBySession[id]?.contains("complete") == true) {
                    transcriptionStates[id] = .completedWithoutText
                } else {
                    transcriptionStates[id] = try receivedAudioHasExplicitNoSpeech(sessionID: id) ? .noSpeech : .completedWithoutText
                }
            }
        }

        return (audioStates, transcriptionStates)
    }
}

private struct PageScope: Encodable {
    let libraryID: UUID
    let kind: String
    let query: String?
    let from: Double?
    let before: Double?
}

private struct PagePosition: Codable {
    var version = 1
    let scope: String
    let sessionCeiling: Int64
    let recordedAt: Double
    let sessionID: UUID
    let spanID: UUID?

    func encoded() throws -> String { try WireJSON.encode(self).base64EncodedString() }
}
