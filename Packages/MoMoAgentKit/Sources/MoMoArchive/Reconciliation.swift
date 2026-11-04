import Foundation
import MoMoContracts

public enum ArchiveReconciliationError: Error, Sendable, Equatable {
    case receiverMismatch
    case libraryMismatch
    case conflictingRequest(UUID)
}

public enum ReconcileResponseRequeueResult: Sendable, Equatable {
    case requeued, superseded, unknown
}

extension ArchiveStore {
    /// Each request and its replayable response survive transport submission and process restart.
    public func receiveReconcileRequest(_ request: ReconcileRequest) throws -> ReconcileResponse {
        try refreshReconcileResponse(request)
    }

    public func pendingReconcileResponses(limit: Int = 32) throws -> [ReconcileResponse] {
        guard (1...32).contains(limit) else { throw ArchiveError.invalidQuery }
        let rows = try database.rows("SELECT request FROM reconcile_requests WHERE pending=1 ORDER BY rowid LIMIT ?", [.integer(Int64(limit))])
        // A cached success is not evidence that the original audio still exists at replay time.
        return try rows.map { try refreshReconcileResponse(WireJSON.decode(ReconcileRequest.self, from: $0.requireData(0))) }
    }

    /// Transport admission is not delivery. A duplicate request re-enqueues its retained response.
    public func markReconcileResponseSubmitted(messageID: UUID) throws {
        try database.execute("UPDATE reconcile_requests SET pending=0 WHERE response_id=?", [.text(messageID.uuidString)])
    }

    /// The owned request and its canonical response decide which transport attempt can still be retried.
    @discardableResult public func requeueReconcileResponse(_ response: ReconcileResponse) throws -> ReconcileResponseRequeueResult {
        guard response.receiverDeviceID == receiverDeviceID else { throw ArchiveReconciliationError.receiverMismatch }
        guard response.libraryInstanceID == libraryInstanceID else { throw ArchiveReconciliationError.libraryMismatch }
        guard let row = try database.rows("SELECT request,response FROM reconcile_requests WHERE id=?", [.text(response.requestID.uuidString)]).first else {
            return .unknown
        }
        let request = try WireJSON.decode(ReconcileRequest.self, from: row.requireData(0))
        guard try response.matches(request) else { return .unknown }
        let current = try WireJSON.decode(ReconcileResponse.self, from: row.requireData(1))
        guard try current.matches(request) else { throw ArchiveReconciliationError.conflictingRequest(request.messageID) }
        if current == response {
            try database.execute("UPDATE reconcile_requests SET pending=1 WHERE response_id=?", [.text(response.messageID.uuidString)])
            return .requeued
        }
        return current.messageID != response.messageID ? .superseded : .unknown
    }

    private func refreshReconcileResponse(_ request: ReconcileRequest) throws -> ReconcileResponse {
        guard request.receiverDeviceID == receiverDeviceID else { throw ArchiveReconciliationError.receiverMismatch }
        guard request.libraryInstanceID == libraryInstanceID else { throw ArchiveReconciliationError.libraryMismatch }
        let requestHash = try request.requestSHA256
        let previous = try database.rows("SELECT request_hash,response FROM reconcile_requests WHERE id=?", [.text(request.messageID.uuidString)]).first
        if let previous, previous.string(0) != requestHash {
            throw ArchiveReconciliationError.conflictingRequest(request.messageID)
        }
        let results = try request.items.map { item in
            try ReconcileResult(chunkID: item.chunkID, state: reconcileState(item, sourceDeviceID: request.sourceDeviceID))
        }
        let response: ReconcileResponse
        if let previous {
            let saved = try WireJSON.decode(ReconcileResponse.self, from: previous.requireData(1))
            if saved.results == results { response = saved }
            else { response = try makeReconcileResponse(request: request, requestHash: requestHash, results: results) }
        } else { response = try makeReconcileResponse(request: request, requestHash: requestHash, results: results) }
        let requestData = try WireJSON.encode(request), responseData = try WireJSON.encode(response)
        // Hashing happens before this short transaction; no file or SQLite cursor crosses an await.
        try database.transaction {
            try database.execute("INSERT INTO reconcile_requests(id,source_device,request_hash,request,response,response_id,pending) VALUES(?,?,?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET response=excluded.response,response_id=excluded.response_id,pending=1", [
                .text(request.messageID.uuidString), .text(request.sourceDeviceID.uuidString), .text(requestHash),
                .blob(requestData), .blob(responseData), .text(response.messageID.uuidString)
            ])
            for result in results where result.state == .missing {
                try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE id=? AND retention='present'", [.text(result.chunkID.uuidString)])
            }
        }
        return response
    }

    private func makeReconcileResponse(request: ReconcileRequest, requestHash: String, results: [ReconcileResult]) throws -> ReconcileResponse {
        try ReconcileResponse(requestID: request.messageID, requestSHA256: requestHash,
            sourceDeviceID: request.sourceDeviceID, receiverDeviceID: receiverDeviceID,
            libraryInstanceID: libraryInstanceID, results: results)
    }

    private func reconcileState(_ item: ReconcileChunkIdentity, sourceDeviceID: UUID) throws -> ReconcileItemState {
        let session = try database.rows("SELECT source_device,deleted FROM sessions WHERE id=?", [.text(item.sessionID.uuidString)]).first
        if let session, session.string(0) != sourceDeviceID.uuidString { return .conflict }
        var chunk = try database.rows("SELECT session_id,manifest,manifest_hash,audio_hash,relative_path,retention FROM chunks WHERE id=?", [.text(item.chunkID.uuidString)]).first
        if chunk == nil, session?.integer(1) != 1,
           let pending = inbox.pendingItem(chunkID: item.chunkID) ?? inbox.pendingItem(manifestSHA256: item.manifestSHA256) {
            _ = try? commitReceivedChunk(pending)
            chunk = try database.rows("SELECT session_id,manifest,manifest_hash,audio_hash,relative_path,retention FROM chunks WHERE id=?", [.text(item.chunkID.uuidString)]).first
        }
        if let chunk {
            guard chunk.string(0) == item.sessionID.uuidString,
                  chunk.string(2) == item.manifestSHA256, chunk.string(3) == item.audioSHA256 else { return .conflict }
            let envelope = try ManifestEnvelope(manifestData: chunk.requireData(1), manifestSHA256: chunk.requireString(2))
            guard envelope.manifest.sourceDeviceID == sourceDeviceID,
                  envelope.manifest.sessionID == item.sessionID,
                  envelope.manifest.chunkID == item.chunkID,
                  envelope.manifest.representation == item.representation else { return .conflict }
            if session?.integer(1) == 1 { return try reconciliationDeletion(sessionID: item.sessionID) }
            switch try chunk.requireString(5) {
            case "expired", "expiry_pending": return .expired
            case "missing_unexpected": return .missing
            case "present":
                let url = rootURL.appendingPathComponent(try chunk.requireString(4))
                let valid: Bool
                do { valid = try validStoredAudio(url, envelope: envelope) }
                catch ArchiveError.invalidQuery { return .missing } // Unsafe paths are never followed for confirmation.
                catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return .missing }
                guard valid else { return .missing }
                let receipt = try receiptForChunk(item.chunkID)
                guard receipt.receiverDeviceID == receiverDeviceID, receipt.libraryInstanceID == libraryInstanceID,
                      receipt.matches(envelope) else { throw ArchiveError.staleSource }
                return .received(receipt)
            default: throw ArchiveError.database(11)
            }
        }
        if session?.integer(1) == 1 { return try reconciliationDeletion(sessionID: item.sessionID) }
        // Control events can establish ownership before the first audio file arrives.
        let sources = try database.rows("SELECT DISTINCT source_device FROM capture_events WHERE session_id=?", [.text(item.sessionID.uuidString)])
        guard sources.allSatisfy({ $0.string(0) == sourceDeviceID.uuidString }) else { return .conflict }
        return .unknown
    }

    private func reconciliationDeletion(sessionID: UUID) throws -> ReconcileItemState {
        guard let row = try database.rows("SELECT message FROM deletions WHERE session_id=?", [.text(sessionID.uuidString)]).first else { throw ArchiveError.database(11) }
        return .deleted(try scopedDeletion(WireJSON.decode(DeleteSession.self, from: row.requireData(0))))
    }
}
