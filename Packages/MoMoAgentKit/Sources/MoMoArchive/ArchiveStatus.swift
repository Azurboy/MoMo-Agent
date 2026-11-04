import Foundation
import MoMoContracts

public enum ArchiveStatusError: Error, Equatable, Sendable {
    case wrongRole, receiverMismatch, sourceMismatch, conflictingRevision, invalidClock, revisionExhausted
}

public struct WatchStatusObservation: Sendable {
    public let snapshot: StatusSnapshot
    /// Nil when the first observation came from the system's cached application context.
    public let observedAt: Date?
    public let restored: Bool

    public init(snapshot: StatusSnapshot, observedAt: Date?, restored: Bool) {
        self.snapshot = snapshot
        self.observedAt = restored ? nil : observedAt
        self.restored = restored
    }
}

extension ArchiveStore {
    /// Status is informational. A matching snapshot cannot acknowledge a file or authorize deletion.
    @discardableResult
    public func receiveWatchStatus(_ snapshot: StatusSnapshot, restored: Bool, observedAt: Date = Date()) throws -> Bool {
        try storeWatchStatus(snapshot, restored: restored, observedAt: observedAt).changed
    }

    /// Returns the accepted report, including pre-audio/idle status, without granting any receipt authority.
    public func receiveWatchStatusReport(_ snapshot: StatusSnapshot, restored: Bool,
                                        observedAt: Date = Date()) throws -> (changed: Bool, observation: WatchStatusObservation?) {
        try storeWatchStatus(snapshot, restored: restored, observedAt: observedAt)
    }

    private func storeWatchStatus(_ snapshot: StatusSnapshot, restored: Bool, observedAt: Date)
        throws -> (changed: Bool, observation: WatchStatusObservation?) {
        try snapshot.validate()
        guard observedAt.timeIntervalSince1970.isFinite else { throw ArchiveStatusError.invalidClock }
        guard case .watch(let watch) = snapshot.payload else { throw ArchiveStatusError.wrongRole }
        guard watch.receiverLibraryInstanceID == libraryInstanceID else { throw ArchiveStatusError.receiverMismatch }
        let observation = WatchStatusObservation(snapshot: snapshot, observedAt: observedAt, restored: restored)
        guard let sessionID = watch.sessionID else { return (false, observation) }
        guard try !sessionIsDeleted(sessionID) else { return (false, nil) }
        let key: [SQLValue] = [.text(sessionID.uuidString)]
        if let session = try database.rows("SELECT source_device,source_kind FROM sessions WHERE id=?", key).first {
            guard session.string(0) == snapshot.sourceDeviceID.uuidString, session.string(1) == SourceKind.watch.rawValue else {
                throw ArchiveStatusError.sourceMismatch
            }
        }
        let sources = try database.rows("SELECT DISTINCT source_device FROM capture_events WHERE session_id=?", key)
        guard sources.allSatisfy({ $0.string(0) == snapshot.sourceDeviceID.uuidString }) else {
            throw ArchiveStatusError.sourceMismatch
        }
        let data = try WireJSON.encode(snapshot)
        if let known = try database.rows("SELECT source_device,source_store,revision,payload,observed_at,restored FROM watch_status WHERE session_id=?", key).first {
            // A recording belongs to one store. A different store can report its own new recording, not replace this one.
            guard known.string(0) == snapshot.sourceDeviceID.uuidString,
                  known.string(1) == snapshot.sourceStoreInstanceID.uuidString else { throw ArchiveStatusError.sourceMismatch }
            let revision = try known.requireInt(2)
            if snapshot.revision <= revision {
                let stored = try known.requireData(3)
                if snapshot.revision == revision, stored != data { throw ArchiveStatusError.conflictingRevision }
                return (false, WatchStatusObservation(snapshot: try WireJSON.decode(StatusSnapshot.self, from: stored),
                    observedAt: known.double(4).map(Date.init(timeIntervalSince1970:)), restored: known.integer(5) == 1))
            }
        }
        try database.execute("""
            INSERT INTO watch_status(session_id,source_device,source_store,revision,payload,observed_at,restored)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET
            revision=excluded.revision,payload=excluded.payload,observed_at=excluded.observed_at,restored=excluded.restored
            """, key + [.text(snapshot.sourceDeviceID.uuidString), .text(snapshot.sourceStoreInstanceID.uuidString),
                         .integer(snapshot.revision), .blob(data), restored ? .null : .double(observedAt.timeIntervalSince1970),
                         .integer(restored ? 1 : 0)])
        return (true, observation)
    }

    public func watchStatus(sessionID: UUID) throws -> WatchStatusObservation? {
        guard try !sessionIsDeleted(sessionID) else { return nil }
        let key: [SQLValue] = [.text(sessionID.uuidString)]
        guard let row = try database.rows("""
            SELECT w.payload,w.observed_at,w.restored,w.source_device,w.source_store,w.revision
            FROM watch_status w JOIN sessions s ON s.id=w.session_id
            WHERE w.session_id=? AND s.deleted=0 AND s.source_kind='watch' AND s.source_device=w.source_device
            """, key).first else { return nil }
        let snapshot = try WireJSON.decode(StatusSnapshot.self, from: row.requireData(0))
        guard case .watch(let watch) = snapshot.payload, watch.sessionID == sessionID,
              watch.receiverLibraryInstanceID == libraryInstanceID,
              row.string(3) == snapshot.sourceDeviceID.uuidString, row.string(4) == snapshot.sourceStoreInstanceID.uuidString,
              row.integer(5) == snapshot.revision else { throw ArchiveStatusError.sourceMismatch }
        return WatchStatusObservation(snapshot: snapshot, observedAt: row.double(1).map(Date.init(timeIntervalSince1970:)), restored: row.integer(2) == 1)
    }

    /// Includes status that arrived before the first audio file; never creates a recording.
    public func latestWatchStatus() throws -> WatchStatusObservation? {
        guard let row = try database.rows("""
            SELECT w.payload,w.observed_at,w.restored,w.source_device,w.source_store,w.revision,w.session_id
            FROM watch_status w LEFT JOIN sessions s ON s.id=w.session_id
            WHERE s.id IS NULL OR (s.deleted=0 AND s.source_kind='watch' AND s.source_device=w.source_device)
            ORDER BY julianday(json_extract(CAST(w.payload AS TEXT),'$.sampledAt')) DESC,
                     w.observed_at DESC,w.session_id DESC LIMIT 1
            """).first else { return nil }
        let snapshot = try WireJSON.decode(StatusSnapshot.self, from: row.requireData(0))
        guard case .watch(let watch) = snapshot.payload,
              watch.sessionID?.uuidString == row.string(6), watch.receiverLibraryInstanceID == libraryInstanceID,
              row.string(3) == snapshot.sourceDeviceID.uuidString, row.string(4) == snapshot.sourceStoreInstanceID.uuidString,
              row.integer(5) == snapshot.revision else { throw ArchiveStatusError.sourceMismatch }
        return WatchStatusObservation(snapshot: snapshot, observedAt: row.double(1).map(Date.init(timeIntervalSince1970:)), restored: row.integer(2) == 1)
    }

    /// Stable across relaunch and unchanged summaries. The remote library identity remains a separate control message.
    public func phoneStatus(sourceBuild: String, sampledAt: Date = Date(), sourceDeviceID: UUID? = nil,
                            refreshObservation: Bool = false) throws -> StatusSnapshot {
        let recordingCount = Int(try database.rows("SELECT COUNT(*) FROM sessions WHERE deleted=0").first?.integer(0) ?? 0)
        let pendingAnalysisCount = Int(try database.rows("SELECT COUNT(*) FROM transcription_jobs WHERE state IN ('pending','running')").first?.integer(0) ?? 0)
        let payload = StatusPayload.phone(try PhoneArchiveStatus(libraryInstanceID: libraryInstanceID,
            recordingCount: recordingCount, pendingAnalysisCount: pendingAnalysisCount,
            pendingReceiptCount: pendingReceiptCount(sourceDeviceID: sourceDeviceID), audioBlockVersion: AudioBlock.version))
        var revision: Int64 = 1
        if let row = try database.rows("SELECT value FROM metadata WHERE key='phone_status_snapshot'").first {
            let previous = try WireJSON.decode(StatusSnapshot.self, from: Data(row.requireString(0).utf8))
            guard previous.sourceDeviceID == receiverDeviceID, previous.sourceStoreInstanceID == libraryInstanceID,
                  previous.sourceRole == .phone else { throw ArchiveStatusError.sourceMismatch }
            if !refreshObservation, previous.sourceBuild == sourceBuild, previous.payload == payload { return previous }
            guard previous.revision < Int64.max else { throw ArchiveStatusError.revisionExhausted }
            revision = previous.revision + 1
        }
        let snapshot = try StatusSnapshot(sourceDeviceID: receiverDeviceID, sourceBuild: sourceBuild,
            sourceStoreInstanceID: libraryInstanceID, revision: revision, sampledAt: sampledAt, payload: payload)
        let data = try WireJSON.encode(snapshot)
        try database.execute("INSERT INTO metadata(key,value) VALUES('phone_status_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                             [.text(String(decoding: data, as: UTF8.self))])
        return snapshot
    }
}
