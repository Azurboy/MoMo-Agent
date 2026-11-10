import CSQLite
import Foundation
import MoMoContracts

public enum RecordingReconciliationError: Error, Equatable {
    case unknownRequest, responseMismatch, invalidCursor
}

public struct RecordingChunkEntry: Sendable {
    public let sequence: Int64
    public let chunk: RecordedChunk
}

public struct RecordingReconciliationOutcome: Sendable {
    public var receiptApplications: [ReceiptApplied] = []
    public var unconfirmedReceiptApplications: [ReceiptApplied] = []
    public var retryChunkIDs: [UUID] = []
    public var unavailableChunkIDs: [UUID] = []
    public var conflictingChunkIDs: [UUID] = []
    public var deletions: [DeleteSession] = []
    public var ignored = false
    public var requiresFreshRequest = false
}

extension RecordingStore {
    public func reconciliationRoundIsComplete() throws -> Bool {
        guard let round = try reconciliationRound() else { return true }
        return round.requestID == nil && round.cursor >= round.highWater
    }

    /// Routine sync checks unresolved chunks. A completed full audit remains fresh for one day.
    /// The round's persisted scope and request survive interruption, even if the next caller changes modes.
    public func nextReconciliationRequest(sourceDeviceID: UUID, beginNewRound: Bool = false, through: Int64 = .max,
                                         preferPending: Bool = false, allowHistoricalAudit: Bool = true,
                                         now: Date = Date()) throws -> ReconcileRequest? {
        guard through >= 0, now.timeIntervalSince1970.isFinite else { throw RecordingReconciliationError.invalidCursor }
        guard let receiver = try boundReceiver() else { return nil }
        return try database.transaction {
            var round = try reconciliationRound()
            if let value = round {
                guard value.source == sourceDeviceID, value.receiver == receiver.deviceID,
                      value.library == receiver.libraryInstanceID else { throw RecordingError.receiverMismatch }
                if let requestID = value.requestID { return try reconciliationRequest(id: requestID).request }
                if value.cursor >= value.highWater, !beginNewRound, !(preferPending && !allowHistoricalAudit && value.fullHistory) {
                    return nil
                }
            }
            let preemptHistoricalForPending = round.map {
                preferPending && !allowHistoricalAudit && $0.fullHistory && $0.requestID == nil
            } ?? false
            if preemptHistoricalForPending || (round.map({ $0.cursor >= $0.highWater && beginNewRound }) ?? true) {
                let highWater = min(through, try database.rows("SELECT COALESCE(MAX(rowid),0) FROM chunks") { sqlite3_column_int64($0, 0) }.first ?? 0)
                let auditAge = round?.historyAuditedAt.map { now.timeIntervalSince1970 - $0 }
                let fullHistory = !preferPending || (allowHistoricalAudit && (auditAge.map { $0 < 0 || $0 >= 86_400 } ?? true))
                try database.execute("INSERT INTO reconciliation_round(id,source_id,receiver_id,library_id,high_water,cursor,request_id,full_history) VALUES(1,?,?,?,?,0,NULL,?) ON CONFLICT(id) DO UPDATE SET source_id=excluded.source_id,receiver_id=excluded.receiver_id,library_id=excluded.library_id,high_water=excluded.high_water,cursor=0,request_id=NULL,full_history=excluded.full_history", [.text(sourceDeviceID.uuidString), .text(receiver.deviceID.uuidString), .text(receiver.libraryInstanceID.uuidString), .integer(highWater), .integer(fullHistory ? 1 : 0)])
                round = try reconciliationRound()
            }
            guard let round else { throw RecordingReconciliationError.unknownRequest }
            let scope = round.fullHistory ? "" : " AND (state NOT IN ('acknowledged','removed') OR id IN (SELECT chunk_id FROM reconciliation_receipt_holds))"
            let entries = try database.rows("SELECT rowid,envelope FROM chunks WHERE rowid>? AND rowid<=? AND state!='deleted'\(scope) ORDER BY rowid LIMIT ?", [.integer(round.cursor), .integer(round.highWater), .integer(Int64(ReconciliationLimits.maximumItems))]) {
                (sqlite3_column_int64($0, 0), try WireJSON.decode(ManifestEnvelope.self, from: RecordingDatabase.data($0, 1)))
            }
            guard let last = entries.last else {
                try database.execute("UPDATE reconciliation_round SET cursor=high_water WHERE id=1")
                try finishHistoryAuditIfComplete(at: now)
                return nil
            }
            for (_, envelope) in entries where envelope.manifest.sourceDeviceID != sourceDeviceID {
                throw RecordingError.contentConflict(envelope.manifest.chunkID)
            }
            let request = try ReconcileRequest(sourceDeviceID: sourceDeviceID, receiverDeviceID: receiver.deviceID,
                libraryInstanceID: receiver.libraryInstanceID, items: entries.map { try ReconcileChunkIdentity(envelope: $0.1) })
            try database.execute("INSERT INTO reconciliation_requests(id,payload,end_sequence) VALUES(?,?,?)", [.text(request.messageID.uuidString), .blob(try WireJSON.encode(request)), .integer(last.0)])
            try database.execute("UPDATE reconciliation_round SET request_id=? WHERE id=1", [.text(request.messageID.uuidString)])
            return request
        }
    }

    /// Each item is recoverable independently. The page advances only after all item effects are durable.
    public func applyReconciliationResponse(_ response: ReconcileResponse, now: Date = Date()) throws -> RecordingReconciliationOutcome {
        guard now.timeIntervalSince1970.isFinite else { throw RecordingReconciliationError.invalidCursor }
        let saved: (request: ReconcileRequest, endSequence: Int64, processed: Bool)
        do {
            saved = try reconciliationRequest(id: response.requestID)
        } catch RecordingReconciliationError.unknownRequest {
            guard try boundReceiver() != nil else { throw RecordingError.receiverNotBound }
            // Pruned historical or superseded request responses are never the active round's request
            // (pruneHistoricalLedger always preserves reconciliation_round.request_id). Ignore cleanly
            // so duplicate WatchConnectivity transferUserInfo replies never poison ControlInbox.
            var result = RecordingReconciliationOutcome(); result.ignored = true; return result
        }
        guard try response.matches(saved.request) else { throw RecordingReconciliationError.responseMismatch }
        guard let receiver = try boundReceiver() else { throw RecordingError.receiverNotBound }
        // A reply addressed to a previously confirmed library has no authority in the new binding.
        guard receiver.deviceID == response.receiverDeviceID, receiver.libraryInstanceID == response.libraryInstanceID else {
            var result = RecordingReconciliationOutcome(); result.ignored = true; return result
        }
        if saved.processed { var result = RecordingReconciliationOutcome(); result.ignored = true; return result }
        guard try reconciliationRound()?.requestID == response.requestID else {
            try database.execute("UPDATE reconciliation_requests SET processed=1 WHERE id=?", [.text(response.requestID.uuidString)])
            var result = RecordingReconciliationOutcome(); result.ignored = true; return result
        }
        var outcome = RecordingReconciliationOutcome()
        var deletedSessions: Set<UUID> = []
        for result in response.results {
            if case .deleted(let deletion) = result.state, deletedSessions.insert(deletion.sessionID).inserted {
                let scoped = try deletion.scoped(receiverDeviceID: receiver.deviceID, libraryInstanceID: receiver.libraryInstanceID)
                try validateDeletionReceiver(scoped)
                try prepareDeletion(scoped, deviceID: saved.request.sourceDeviceID)
                outcome.deletions.append(scoped)
            }
        }
        for result in response.results {
            guard let chunk = try chunk(id: result.chunkID) else { continue }
            if chunk.state == .deleted || deletedSessions.contains(chunk.envelope.manifest.sessionID) { continue }
            switch result.state {
            case .received(let receipt):
                do {
                    let applied = try applyReconciledReceipt(receipt, requestID: response.requestID)
                    outcome.receiptApplications.append(applied.application)
                    if applied.pendingDelivery {
                        outcome.unconfirmedReceiptApplications.append(applied.application)
                    }
                }
                catch RecordingError.receiptNeedsReconciliation { outcome.requiresFreshRequest = true }
                catch RecordingError.deletedSession, RecordingError.missingChunk { continue }
            case .unknown:
                if try chunk.state != .ready || hasPersistedReceipt(chunkID: result.chunkID) {
                    try holdReceipts(chunkID: result.chunkID, requestID: response.requestID)
                }
                if try originalIsAvailable(chunk) {
                    try retainForReconciliation(chunkID: result.chunkID, action: "retry")
                    outcome.retryChunkIDs.append(result.chunkID)
                } else { outcome.unavailableChunkIDs.append(result.chunkID) }
            case .missing:
                try holdReceipts(chunkID: result.chunkID, requestID: response.requestID)
                if try originalIsAvailable(chunk) {
                    try retainForReconciliation(chunkID: result.chunkID, action: "retry")
                    outcome.retryChunkIDs.append(result.chunkID)
                } else { outcome.unavailableChunkIDs.append(result.chunkID) }
            case .conflict:
                try holdReceipts(chunkID: result.chunkID, requestID: response.requestID)
                if chunk.state != .removed { try retainForReconciliation(chunkID: result.chunkID, action: "conflict") }
                outcome.conflictingChunkIDs.append(result.chunkID)
            case .expired:
                try holdReceipts(chunkID: result.chunkID, requestID: response.requestID)
                if chunk.state != .removed { try retainForReconciliation(chunkID: result.chunkID, action: "expired") }
                outcome.unavailableChunkIDs.append(result.chunkID)
            case .deleted: break
            }
        }
        try database.transaction {
            try database.execute("UPDATE reconciliation_requests SET processed=1 WHERE id=?", [.text(response.requestID.uuidString)])
            try database.execute("UPDATE reconciliation_round SET cursor=?,request_id=NULL WHERE id=1 AND request_id=?", [.integer(saved.endSequence), .text(response.requestID.uuidString)])
            try finishHistoryAuditIfComplete(at: now)
        }
        try pruneHistoricalLedger(now: now)
        return outcome
    }

    /// Fair rowid paging; a blocked or unconfirmed first file does not starve newer sealed files.
    public func pendingChunkBatch(after sequence: Int64, through: Int64 = .max, limit: Int = 4) throws -> [RecordingChunkEntry] {
        guard sequence >= 0, through >= 0, (1...4).contains(limit) else { throw RecordingReconciliationError.invalidCursor }
        return try pendingChunkPage(after: sequence, through: through, limit: limit)
    }

    public func pendingChunkPage(after sequence: Int64, through: Int64 = .max, limit: Int = 32) throws -> [RecordingChunkEntry] {
        guard sequence >= 0, through >= 0, (1...64).contains(limit) else { throw RecordingReconciliationError.invalidCursor }
        return try database.rows("SELECT rowid,envelope FROM chunks WHERE rowid>? AND rowid<=? AND state='ready' AND id NOT IN (SELECT chunk_id FROM reconciliation_file_actions WHERE action!='retry') ORDER BY rowid LIMIT ?", [.integer(sequence), .integer(through), .integer(Int64(limit))]) { row in
            let envelope = try WireJSON.decode(ManifestEnvelope.self, from: RecordingDatabase.data(row, 1))
            let chunk = RecordedChunk(envelope: envelope,
                audioURL: rootURL.appendingPathComponent("CaptureReady/\(envelope.manifest.chunkID.uuidString)/audio"), state: .ready)
            return RecordingChunkEntry(sequence: sqlite3_column_int64(row, 0), chunk: chunk)
        }
    }

    /// Admission survives restart; a released batch keeps draining while newer chunks wait.
    public func audioTransferBatchEnd(now: Date = Date(), force: Bool = false) throws -> Int64 {
        let admitted = try database.rows("SELECT position FROM control_positions WHERE kind='audio_batch'", read: {
            sqlite3_column_int64($0, 0)
        }).first ?? 0
        guard let first = try pendingChunkBatch(after: admitted, limit: 1).first else { return admitted }
        let manifest = first.chunk.envelope.manifest
        let duration = Double(manifest.frames.count) / manifest.timebaseHz
        let deadline = manifest.sealedAt.addingTimeInterval(max(0, 300 - duration))
        let ended = try database.rows("SELECT ended FROM capture_epochs WHERE id=?", [.text(manifest.epochID.uuidString)], read: {
            sqlite3_column_int64($0, 0)
        }).first == 1
        var marked = false
        if let message = try database.rows("SELECT payload FROM capture_events WHERE rowid=(SELECT position FROM control_positions WHERE kind='audio_mark')", read: {
            try WireJSON.decode(ControlMessage.self, from: RecordingDatabase.data($0, 0))
        }).first, case .captureMark(let mark) = message {
            if let latest = try database.rows("SELECT envelope FROM chunks WHERE session_id=? AND state!='deleted' ORDER BY rowid DESC LIMIT 1", [.text(mark.sessionID.uuidString)], read: {
                try WireJSON.decode(ManifestEnvelope.self, from: RecordingDatabase.data($0, 0)).manifest
            }).first {
                marked = latest.epochID == mark.epochID && latest.frames.end > mark.sourceFrame
            }
            if !marked {
                marked = try database.rows("SELECT ended FROM capture_epochs WHERE id=?", [.text(mark.epochID.uuidString)], read: { sqlite3_column_int64($0, 0) }).first == 1
            }
        }
        guard force || ended || marked || now >= deadline || now.timeIntervalSince(manifest.sealedAt) < -5 else { return admitted }
        let end = try database.rows("SELECT COALESCE(MAX(rowid),0) FROM chunks", read: { sqlite3_column_int64($0, 0) }).first ?? 0
        try database.transaction {
            try database.execute("INSERT INTO control_positions(kind,position) VALUES('audio_batch',?) ON CONFLICT(kind) DO UPDATE SET position=excluded.position", [.integer(end)])
            if marked { try database.execute("DELETE FROM control_positions WHERE kind='audio_mark'") }
        }
        return end
    }

    public func nextAudioBatchDelay(now: Date = Date()) throws -> TimeInterval? {
        let admitted = try database.rows("SELECT position FROM control_positions WHERE kind='audio_batch'", read: {
            sqlite3_column_int64($0, 0)
        }).first ?? 0
        guard let first = try pendingChunkBatch(after: admitted, limit: 1).first else { return nil }
        let manifest = first.chunk.envelope.manifest
        let duration = Double(manifest.frames.count) / manifest.timebaseHz
        let deadline = manifest.sealedAt.addingTimeInterval(max(0, 300 - duration))
        return max(1, deadline.timeIntervalSince(now))
    }

    public func pendingFileReplays(limit: Int = 16) throws -> [UUID] {
        guard (1...ReconciliationLimits.maximumItems).contains(limit) else { throw RecordingReconciliationError.invalidCursor }
        return try database.rows("SELECT chunk_id FROM reconciliation_file_actions WHERE action='retry' ORDER BY rowid LIMIT ?", [.integer(Int64(limit))]) {
            guard let id = UUID(uuidString: RecordingDatabase.text($0, 0)) else { throw RecordingReconciliationError.responseMismatch }
            return id
        }
    }

    public func fileReplaysScheduled(_ ids: [UUID]) throws {
        guard ids.count <= ReconciliationLimits.maximumItems else { throw RecordingReconciliationError.invalidCursor }
        try database.transaction {
            for id in ids { try database.execute("DELETE FROM reconciliation_file_actions WHERE chunk_id=? AND action='retry'", [.text(id.uuidString)]) }
        }
    }

    public func receiptRequiresReconciliation(chunkID: UUID) throws -> Bool {
        try !database.rows("SELECT 1 FROM reconciliation_receipt_holds WHERE chunk_id=?", [.text(chunkID.uuidString)]) { _ in true }.isEmpty
    }

    private func hasPersistedReceipt(chunkID: UUID) throws -> Bool {
        try !database.rows("SELECT 1 FROM receipts WHERE chunk_id=? LIMIT 1", [.text(chunkID.uuidString)]) { _ in true }.isEmpty
    }

    private func holdReceipts(chunkID: UUID, requestID: UUID) throws {
        try database.transaction {
            try database.execute("INSERT INTO reconciliation_receipt_holds(chunk_id,request_id) VALUES(?,?) ON CONFLICT(chunk_id) DO UPDATE SET request_id=excluded.request_id", [.text(chunkID.uuidString), .text(requestID.uuidString)])
            try database.execute("UPDATE chunks SET state='ready' WHERE id=? AND state='acknowledged'", [.text(chunkID.uuidString)])
        }
    }

    private func retainForReconciliation(chunkID: UUID, action: String) throws {
        try database.transaction {
            try database.execute("UPDATE chunks SET state='ready' WHERE id=? AND state IN ('ready','acknowledged')", [.text(chunkID.uuidString)])
            try database.execute("INSERT INTO reconciliation_file_actions(chunk_id,action) VALUES(?,?) ON CONFLICT(chunk_id) DO UPDATE SET action=excluded.action", [.text(chunkID.uuidString), .text(action)])
        }
    }

    /// Validate at most one sealed original before retiring its stalled SDK copy.
    /// Short Watch grants pass a byte ceiling and leave larger candidates untouched.
    public func originalAvailableForTransferRetry(_ envelope: ManifestEnvelope, maximumValidationBytes: Int64) throws -> Bool {
        guard let chunk = try chunk(id: envelope.manifest.chunkID), chunk.state == .ready,
              chunk.envelope == envelope, envelope.manifest.byteCount <= maximumValidationBytes else { return false }
        return try originalIsAvailable(chunk)
    }

    private func originalIsAvailable(_ chunk: RecordedChunk) throws -> Bool {
        guard chunk.state == .ready || chunk.state == .acknowledged else { return false }
        guard FileManager.default.fileExists(atPath: chunk.audioURL.path) else {
            try markUnavailable(chunkID: chunk.envelope.manifest.chunkID, state: .missing)
            return false
        }
        let directory = try chunk.audioURL.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let properties = try chunk.audioURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true,
              properties.isRegularFile == true, properties.isSymbolicLink != true,
              properties.fileSize.map(Int64.init) == chunk.envelope.manifest.byteCount,
              try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256 else {
            try markUnavailable(chunkID: chunk.envelope.manifest.chunkID, state: .damaged)
            return false
        }
        return true
    }

    private func markUnavailable(chunkID: UUID, state: RecordedChunkState) throws {
        try database.transaction {
            try database.execute("UPDATE chunks SET state=? WHERE id=?", [.text(state.rawValue), .text(chunkID.uuidString)])
            try database.execute("DELETE FROM reconciliation_file_actions WHERE chunk_id=?", [.text(chunkID.uuidString)])
        }
    }

    private func reconciliationRequest(id: UUID) throws -> (request: ReconcileRequest, endSequence: Int64, processed: Bool) {
        guard let row = try database.rows("SELECT payload,end_sequence,processed FROM reconciliation_requests WHERE id=?", [.text(id.uuidString)], read: {
            (try WireJSON.decode(ReconcileRequest.self, from: RecordingDatabase.data($0, 0)), sqlite3_column_int64($0, 1), sqlite3_column_int($0, 2) != 0)
        }).first else { throw RecordingReconciliationError.unknownRequest }
        return row
    }

    private func finishHistoryAuditIfComplete(at date: Date) throws {
        try database.execute("UPDATE reconciliation_round SET history_audited_at=? WHERE id=1 AND full_history=1 AND request_id IS NULL AND cursor>=high_water", [.real(date.timeIntervalSince1970)])
    }

    private func reconciliationRound() throws -> ReconciliationRound? {
        try database.rows("SELECT source_id,receiver_id,library_id,high_water,cursor,request_id,full_history,history_audited_at FROM reconciliation_round WHERE id=1") { row in
            guard let source = UUID(uuidString: RecordingDatabase.text(row, 0)),
                  let receiver = UUID(uuidString: RecordingDatabase.text(row, 1)),
                  let library = UUID(uuidString: RecordingDatabase.text(row, 2)) else { throw RecordingReconciliationError.responseMismatch }
            let rawRequest = RecordingDatabase.text(row, 5)
            let request = UUID(uuidString: rawRequest)
            guard rawRequest.isEmpty || request != nil else { throw RecordingReconciliationError.responseMismatch }
            return ReconciliationRound(source: source, receiver: receiver, library: library,
                highWater: sqlite3_column_int64(row, 3), cursor: sqlite3_column_int64(row, 4), requestID: request,
                fullHistory: sqlite3_column_int(row, 6) != 0,
                historyAuditedAt: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : sqlite3_column_double(row, 7))
        }.first
    }

    /// Reclaims terminal ledger metadata while preserving unconfirmed deliveries, active cursors, and recent history.
    @discardableResult
    public func pruneHistoricalLedger(
        now: Date = Date(),
        retentionInterval: TimeInterval = 14 * 86_400,
        minimumRetainedChunks: Int = 512,
        retainedProcessedRequests: Int = 128,
        batchLimit: Int = 128
    ) throws -> Int {
        guard now.timeIntervalSince1970.isFinite, retentionInterval >= 0,
              minimumRetainedChunks >= 1, retainedProcessedRequests >= 0, batchLimit >= 1 else {
            throw RecordingReconciliationError.invalidCursor
        }
        return try database.transaction {
            try database.execute("""
                DELETE FROM reconciliation_requests
                WHERE (processed = 1 AND rowid NOT IN (
                    SELECT rowid FROM reconciliation_requests WHERE processed = 1 ORDER BY rowid DESC LIMIT ?
                ))
                OR (processed = 0 AND id != COALESCE((SELECT request_id FROM reconciliation_round WHERE id = 1), ''))
                """, [.integer(Int64(retainedProcessedRequests))])

            let finishedOwners = try database.rows("""
                SELECT w.chunk_id FROM working_owners w
                LEFT JOIN chunks c ON c.id = w.chunk_id
                WHERE c.state IN ('removed', 'deleted')
                   OR (c.id IS NULL AND w.session_id IN (SELECT session_id FROM deletions))
                LIMIT ?
                """, [.integer(Int64(batchLimit))]) { RecordingDatabase.text($0, 0) }
            let workingRoot = rootURL.appendingPathComponent("CaptureWorking")
            for chunkID in finishedOwners where !FileManager.default.fileExists(atPath: workingRoot.appendingPathComponent(chunkID).path) {
                try database.execute("DELETE FROM working_owners WHERE chunk_id=?", [.text(chunkID)])
            }

            let totalChunks = try database.rows("SELECT COUNT(*) FROM chunks") { sqlite3_column_int64($0, 0) }.first ?? 0
            var prunedChunks = 0
            if totalChunks > Int64(minimumRetainedChunks),
               let protectedFloor = try database.rows(
                   "SELECT MIN(rowid) FROM (SELECT rowid FROM chunks ORDER BY rowid DESC LIMIT ?)",
                   [.integer(Int64(minimumRetainedChunks))],
                   read: { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 0) }
               ).first ?? nil {
                let round = try reconciliationRound()
                let candidates = try database.rows("""
                    SELECT c.rowid, c.id, c.session_id, c.envelope, c.state
                    FROM chunks c
                    WHERE c.rowid < ?
                      AND c.state IN ('removed', 'deleted')
                      AND c.id NOT IN (SELECT chunk_id FROM reconciliation_file_actions)
                      AND c.id NOT IN (SELECT chunk_id FROM reconciliation_receipt_holds)
                      AND c.session_id NOT IN (SELECT id FROM sessions WHERE intent != 'stopped')
                      AND c.session_id NOT IN (SELECT session_id FROM capture_epochs WHERE ended = 0)
                    ORDER BY c.rowid ASC
                    LIMIT ?
                    """, [.integer(protectedFloor), .integer(Int64(batchLimit))]) { row in
                    (
                        rowID: sqlite3_column_int64(row, 0),
                        id: RecordingDatabase.text(row, 1),
                        sessionID: RecordingDatabase.text(row, 2),
                        envelopeData: RecordingDatabase.data(row, 3),
                        state: RecordingDatabase.text(row, 4)
                    )
                }

                for candidate in candidates {
                    guard let envelope = try? WireJSON.decode(ManifestEnvelope.self, from: candidate.envelopeData),
                          now.timeIntervalSince(envelope.manifest.sealedAt) >= retentionInterval else {
                        continue
                    }
                    if candidate.state == "removed" {
                        guard let round, candidate.rowID <= round.cursor else { continue }
                        let receiptApps = try database.rows(
                            "SELECT application FROM receipts WHERE chunk_id=?",
                            [.text(candidate.id)]
                        ) { RecordingDatabase.data($0, 0) }
                        guard !receiptApps.isEmpty else { continue }
                        var deliveryIDs: [String] = []
                        var allConfirmed = true
                        for appData in receiptApps {
                            guard let applied = try? WireJSON.decode(ReceiptApplied.self, from: appData) else {
                                allConfirmed = false
                                break
                            }
                            let delivered = try !database.rows(
                                "SELECT 1 FROM control_deliveries WHERE id=? LIMIT 1",
                                [.text(applied.messageID.uuidString)]
                            ) { _ in true }.isEmpty
                            if !delivered {
                                allConfirmed = false
                                break
                            }
                            deliveryIDs.append(applied.messageID.uuidString)
                        }
                        guard allConfirmed else { continue }
                        for deliveryID in deliveryIDs {
                            try database.execute("DELETE FROM control_deliveries WHERE id=?", [.text(deliveryID)])
                        }
                    } else if candidate.state == "deleted" {
                        guard try isDeleted(envelope.manifest.sessionID) else { continue }
                        let deletionApps = try database.rows(
                            "SELECT completed, application FROM deletion_applications WHERE json_extract(CAST(payload AS TEXT),'$.sessionID')=?",
                            [.text(candidate.sessionID)]
                        ) { (sqlite3_column_int64($0, 0) != 0, RecordingDatabase.data($0, 1)) }
                        guard !deletionApps.isEmpty else { continue }
                        var allConfirmed = true
                        for (completed, appData) in deletionApps {
                            guard completed, let applied = try? WireJSON.decode(DeleteApplied.self, from: appData) else {
                                allConfirmed = false
                                break
                            }
                            let delivered = try !database.rows(
                                "SELECT 1 FROM control_deliveries WHERE id=? LIMIT 1",
                                [.text(applied.messageID.uuidString)]
                            ) { _ in true }.isEmpty
                            if !delivered {
                                allConfirmed = false
                                break
                            }
                        }
                        guard allConfirmed else { continue }
                    } else {
                        continue
                    }

                    guard !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("CaptureWorking").appendingPathComponent(candidate.id).path),
                          !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("CaptureReady").appendingPathComponent(candidate.id).path) else {
                        continue
                    }
                    try database.execute("DELETE FROM receipts WHERE chunk_id=?", [.text(candidate.id)])
                    try database.execute("DELETE FROM working_owners WHERE chunk_id=?", [.text(candidate.id)])
                    try database.execute("DELETE FROM chunks WHERE id=?", [.text(candidate.id)])
                    prunedChunks += 1
                }
            }

            let totalEvents = try database.rows("SELECT COUNT(*) FROM capture_events") { sqlite3_column_int64($0, 0) }.first ?? 0
            if totalEvents > 1,
               let eventFloor = try database.rows(
                   "SELECT MAX(rowid) FROM capture_events",
                   read: { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 0) }
               ).first ?? nil {
                let prunableEvents = try database.rows("""
                    SELECT ce.rowid, ce.id FROM capture_events ce
                    WHERE ce.rowid < ?
                      AND ce.rowid != COALESCE((SELECT position FROM control_positions WHERE kind = 'audio_mark'), -1)
                      AND ce.session_id NOT IN (SELECT DISTINCT session_id FROM chunks)
                      AND ce.session_id NOT IN (SELECT id FROM sessions WHERE intent != 'stopped')
                      AND ce.session_id NOT IN (SELECT session_id FROM capture_epochs WHERE ended = 0)
                      AND (ce.id IN (SELECT id FROM control_deliveries) OR ce.session_id IN (SELECT session_id FROM deletions))
                    ORDER BY ce.rowid ASC
                    LIMIT ?
                    """, [.integer(eventFloor), .integer(Int64(batchLimit))]) {
                    (sqlite3_column_int64($0, 0), RecordingDatabase.text($0, 1))
                }
                for (rowID, eventID) in prunableEvents {
                    try database.execute("DELETE FROM control_deliveries WHERE id=?", [.text(eventID)])
                    try database.execute("DELETE FROM capture_events WHERE rowid=?", [.integer(rowID)])
                }
            }

            try database.execute("""
                DELETE FROM capture_epochs
                WHERE ended = 1
                  AND session_id NOT IN (SELECT DISTINCT session_id FROM chunks)
                  AND session_id NOT IN (SELECT DISTINCT session_id FROM capture_events)
                  AND session_id NOT IN (SELECT id FROM sessions WHERE intent != 'stopped')
                  AND rowid NOT IN (SELECT rowid FROM capture_epochs ORDER BY rowid DESC LIMIT ?)
                """, [.integer(Int64(min(minimumRetainedChunks, 8)))])

            return prunedChunks
        }
    }
}

private struct ReconciliationRound {
    let source: UUID
    let receiver: UUID
    let library: UUID
    let highWater: Int64
    let cursor: Int64
    let requestID: UUID?
    let fullHistory: Bool
    let historyAuditedAt: TimeInterval?
}
