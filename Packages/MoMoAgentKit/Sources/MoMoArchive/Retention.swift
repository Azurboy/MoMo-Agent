import Foundation
import MoMoContracts

public struct RecordingAudioPlaybackPage: Sendable {
    public let parts: [AudioPlaybackPart]
    public let nextCursor: String?
}

public enum AudioRetentionPolicy: Equatable, Sendable {
    case days(Int)
    case forever

    public var days: Int? {
        if case .days(let days) = self { return days }
        return nil
    }
}

extension ArchiveStore {
    public static let defaultStorageLimitBytes: Int64 = 20_000_000_000

    public func audioRetentionPolicy() throws -> AudioRetentionPolicy {
        guard let row = try database.rows("SELECT value FROM metadata WHERE key='retention_days'").first else { return .days(7) }
        let value = try row.requireString(0)
        if value == "forever" { return .forever }
        guard let days = Int(value), (1...365).contains(days) else { throw ArchiveError.database(11) }
        return .days(days)
    }

    public func setAudioRetentionPolicy(_ policy: AudioRetentionPolicy) throws {
        let value: String
        switch policy {
        case .days(let days):
            guard (1...365).contains(days) else { throw ArchiveError.invalidQuery }
            value = String(days)
        case .forever: value = "forever"
        }
        try database.execute("INSERT INTO metadata(key,value) VALUES('retention_days',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(value)])
    }

    public func storageLimitBytes() throws -> Int64 {
        guard let row = try database.rows("SELECT value FROM metadata WHERE key='audio_storage_limit_bytes'").first else { return Self.defaultStorageLimitBytes }
        guard let bytes = Int64(try row.requireString(0)), bytes > 0 else { throw ArchiveError.database(11) }
        return bytes
    }

    public func setStorageLimitBytes(_ bytes: Int64) throws {
        guard bytes > 0 else { throw ArchiveError.invalidQuery }
        try database.execute("INSERT INTO metadata(key,value) VALUES('audio_storage_limit_bytes',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(bytes))])
    }

    /// A bounded maintenance pass; protected audio can keep usage above the configured limit.
    public func applyRetention(now: Date = Date(), replayFloors: [UUID: Int64], limit: Int = 128) throws -> [UUID] {
        guard (1...256).contains(limit) else { throw ArchiveError.invalidQuery }
        let cutoff = try audioRetentionPolicy().days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        return try pruneAudio(olderThan: cutoff, maximumBytes: storageLimitBytes(), replayFloors: replayFloors, limit: limit)
    }

    public func setKeepAudio(sessionID: UUID, keep: Bool) throws {
        guard !((try sessionIsDeleted(sessionID))) else { throw ArchiveError.sessionDeleted(sessionID) }
        _ = try sessionGeneration(sessionID)
        try database.execute("UPDATE sessions SET keep_audio=? WHERE id=?", [.integer(keep ? 1 : 0), .text(sessionID.uuidString)])
    }

    func recordingAudioState(sessionID: UUID) throws -> RecordingAudioState {
        let values = try database.rows("SELECT DISTINCT retention FROM chunks WHERE session_id=?", [.text(sessionID.uuidString)]).map { try $0.requireString(0) }
        guard !values.isEmpty else { return .unavailable }
        guard values.allSatisfy({ ["present", "expired", "expiry_pending", "missing_unexpected"].contains($0) }) else { throw ArchiveError.database(11) }
        if values.contains("missing_unexpected") { return .missingUnexpected }
        if values.contains("expiry_pending") { return .expiryPending }
        if values.contains("expired") { return values.contains("present") ? .partiallyExpired : .expired }
        return .available
    }

    public func acquireAudioTimeline(source: SourceReference) throws -> [AudioPlaybackPart] {
        try validateSources([source])
        let document = try readTranscript(sessionID: source.sessionID)
        guard let span = document.spans.first(where: { $0.id == source.spanID }) else { throw ArchiveError.staleSource }
        var parts: [AudioPlaybackPart] = []
        do {
            for range in span.sourceRanges {
                parts.append(AudioPlaybackPart(lease: try acquireAudioLease(chunkID: range.chunkID), frames: range.frames))
            }
            return parts
        } catch {
            for part in parts { audioLeases.removeValue(forKey: part.lease.id) }
            throw error
        }
    }

    /// A frozen received prefix, independent of transcript spans. Each page owns only its own audio leases.
    public func acquireRecordingAudioPage(sessionID: UUID, expectedGeneration: Int64,
                                          cursor: String? = nil, limit: Int = 8) throws -> RecordingAudioPlaybackPage {
        guard (1...32).contains(limit) else { throw ArchiveError.invalidQuery }
        guard try !sessionIsDeleted(sessionID) else { throw ArchiveError.sessionDeleted(sessionID) }
        guard try sessionGeneration(sessionID) == expectedGeneration else { throw ArchiveError.staleSource }
        let position: RecordingAudioPosition
        if let cursor {
            guard cursor.utf8.count <= 2_048, let data = Data(base64Encoded: cursor) else { throw ArchiveError.invalidQuery }
            do { position = try WireJSON.decode(RecordingAudioPosition.self, from: data) }
            catch is DecodingError { throw ArchiveError.invalidQuery }
            guard position.libraryID == libraryInstanceID, position.sessionID == sessionID,
                  position.generation == expectedGeneration, position.ceiling >= 0,
                  position.offset >= 0, position.offset <= position.ceiling else { throw ArchiveError.invalidQuery }
        } else {
            let ceiling = try database.rows("SELECT COALESCE(MAX(storage_sequence),0) FROM chunks").first?.requireInt(0) ?? 0
            position = RecordingAudioPosition(libraryID: libraryInstanceID, sessionID: sessionID,
                                               generation: expectedGeneration, ceiling: ceiling, offset: 0)
        }
        // Sort validated manifests in SQLite so long recordings do not load all manifests or lease all files.
        let rows = try database.rows("""
            SELECT id FROM chunks WHERE session_id=? AND storage_sequence<=?
            ORDER BY wall_clock_anchor,epoch_id,start_frame,id LIMIT ? OFFSET ?
            """, [.text(sessionID.uuidString), .integer(position.ceiling), .integer(Int64(limit + 1)), .integer(position.offset)])
        var parts: [AudioPlaybackPart] = []
        do {
            for row in rows.prefix(limit) {
                let lease = try acquireAudioLease(chunkID: row.requireUUID(0))
                parts.append(AudioPlaybackPart(lease: lease, frames: lease.manifest.frames))
            }
            let next = rows.count > limit ? try RecordingAudioPosition(libraryID: libraryInstanceID, sessionID: sessionID,
                generation: expectedGeneration, ceiling: position.ceiling, offset: position.offset + Int64(parts.count)).encoded() : nil
            return RecordingAudioPlaybackPage(parts: parts, nextCursor: next)
        } catch {
            for part in parts { audioLeases.removeValue(forKey: part.lease.id) }
            throw error
        }
    }

    public func acquireAudioLease(source: SourceReference) throws -> AudioLease {
        try validateSources([source])
        let document = try readTranscript(sessionID: source.sessionID)
        guard let span = document.spans.first(where: { $0.id == source.spanID }) else { throw ArchiveError.staleSource }
        guard span.sourceRanges.count == 1 else { throw ArchiveError.invalidQuery }
        return try acquireAudioLease(chunkID: span.chunkID)
    }

    public func acquireAudioLease(chunkID: UUID) throws -> AudioLease {
        guard let row = try database.rows("SELECT c.manifest,c.relative_path,c.retention,s.deleted,c.manifest_hash FROM chunks c JOIN sessions s ON s.id=c.session_id WHERE c.id=?", [.text(chunkID.uuidString)]).first,
              row.string(2) == "present", row.integer(3) == 0 else { throw ArchiveError.missingRecording(chunkID) }
        let envelope = try ManifestEnvelope(manifestData: row.requireData(0), manifestSHA256: row.requireString(4))
        let url = rootURL.appendingPathComponent(try row.requireString(1))
        guard try validStoredAudio(url, envelope: envelope) else {
            try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE id=?", [.text(chunkID.uuidString)])
            throw ArchiveError.missingRecording(chunkID)
        }
        let lease = AudioLease(id: UUID(), chunkID: chunkID, audioURL: url, manifest: envelope.manifest)
        audioLeases[lease.id] = chunkID
        return lease
    }

    public func releaseAudioLease(id: UUID) { audioLeases.removeValue(forKey: id) }

    /// A replay floor is required for every epoch: absence means its original audio remains necessary.
    public func expireAudio(olderThan cutoff: Date, replayFloors: [UUID: Int64]) throws -> [UUID] {
        try pruneAudio(olderThan: cutoff, maximumBytes: nil, replayFloors: replayFloors, limit: .max)
    }

    private func pruneAudio(olderThan cutoff: Date?, maximumBytes: Int64?, replayFloors: [UUID: Int64], limit: Int) throws -> [UUID] {
        var bytes: Int64 = 0
        if maximumBytes != nil {
            guard let row = try database.rows("SELECT COALESCE(SUM(byte_count),0) FROM chunks WHERE retention='present'").first else { throw ArchiveError.database(11) }
            bytes = try row.requireInt(0)
        }
        guard cutoff != nil || bytes > (maximumBytes ?? .max) else { return [] }
        // A paged player may not have leased its next chunk yet. Protect the whole recording.
        let leasedSessions = try Set(Set(audioLeases.values).map { id in
            guard let row = try database.rows("SELECT session_id FROM chunks WHERE id=?", [.text(id.uuidString)]).first else { throw ArchiveError.database(11) }
            return try row.requireUUID(0)
        })
        var ageFilter = ""
        var values: [SQLValue] = []
        if bytes <= (maximumBytes ?? .max), let cutoff {
            ageFilter = " AND c.sealed_at < ?"
            values = [.double(cutoff.timeIntervalSince1970)]
        }
        var expired: [UUID] = []
        for row in try database.rows("""
            SELECT c.id,c.manifest,c.relative_path,c.session_id FROM chunks c
            JOIN sessions s ON s.id=c.session_id JOIN transcription_jobs j ON j.chunk_id=c.id
            WHERE c.retention='present' AND c.receipt_applied=1 AND s.deleted=0 AND s.keep_audio=0 AND j.state='complete'\(ageFilter)
            ORDER BY c.sealed_at,c.storage_sequence
            """, values) {
            try Task.checkCancellation()
            let chunkID = try row.requireUUID(0)
            let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(1))
            let overLimit = bytes > (maximumBytes ?? .max)
            guard cutoff.map({ manifest.sealedAt < $0 }) == true || overLimit else { break }
            guard let floor = replayFloors[manifest.epochID], floor >= manifest.frames.end,
                  !leasedSessions.contains(try row.requireUUID(3)), try !pendingWindowNeeds(manifest) else { continue }
            try database.execute("UPDATE chunks SET retention='expiry_pending' WHERE id=?", [.text(chunkID.uuidString)])
            try finishExpiry(chunkID: chunkID, relativePath: row.requireString(2))
            expired.append(chunkID)
            bytes -= manifest.byteCount
            if expired.count == limit { break }
            if cutoff == nil && bytes <= (maximumBytes ?? .max) { break }
        }
        return expired
    }

    public func recoverPendingExpirations() throws {
        for row in try database.rows("SELECT id,relative_path FROM chunks WHERE retention='expiry_pending'") {
            try finishExpiry(chunkID: row.requireUUID(0), relativePath: row.requireString(1))
        }
    }

    func finishExpiry(chunkID: UUID, relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try validateRecordingPath(url)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        verifiedChunkAudioStamps.removeValue(forKey: chunkID)
        try database.execute("UPDATE chunks SET retention='expired' WHERE id=?", [.text(chunkID.uuidString)])
    }
}

private struct RecordingAudioPosition: Codable {
    let libraryID: UUID
    let sessionID: UUID
    let generation: Int64
    let ceiling: Int64
    let offset: Int64

    func encoded() throws -> String { try WireJSON.encode(self).base64EncodedString() }
}
