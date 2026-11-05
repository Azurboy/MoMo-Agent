import Foundation
import MoMoContracts

extension ArchiveStore {
    public func receiveEpochEnd(_ event: CaptureEpochEnded) throws {
        if try sessionIsDeleted(event.sessionID) { return }
        try database.transaction {
            try validateCaptureIdentity(sessionID: event.sessionID, epochID: event.epochID, sourceDeviceID: event.sourceDeviceID)
            if let maxEnd = try database.rows("SELECT MAX(end_frame) FROM chunks WHERE epoch_id=?", [.text(event.epochID.uuidString)]).first?.integer(0),
               maxEnd > event.endFrame {
                throw ArchiveError.conflictingEpoch(event.epochID)
            }
            for row in try database.rows("SELECT payload FROM capture_events WHERE epoch_id=? AND kind='mark'", [.text(event.epochID.uuidString)]) {
                let mark = try WireJSON.decode(CaptureMark.self, from: row.requireData(0))
                guard mark.sourceFrame <= event.endFrame else { throw ArchiveError.conflictingEpoch(event.epochID) }
            }
            if let bounds = try interruptedEpochBounds(epochID: event.epochID), bounds.observed > event.endFrame {
                throw ArchiveError.conflictingEpoch(event.epochID)
            }
            try insertCaptureEvent(id: event.messageID, sessionID: event.sessionID, epochID: event.epochID,
                                   deviceID: event.sourceDeviceID, kind: "epoch_ended", payload: WireJSON.encode(event))
            try markEpochClosed(epochID: event.epochID, endFrame: event.endFrame)
        }
    }

    public func receiveEpochInterruption(_ event: CaptureEpochInterrupted) throws {
        if try sessionIsDeleted(event.sessionID) { return }
        try database.transaction {
            try validateCaptureIdentity(sessionID: event.sessionID, epochID: event.epochID, sourceDeviceID: event.sourceDeviceID)
            if let closure = try database.rows("SELECT end_frame FROM epoch_closures WHERE epoch_id=?", [.text(event.epochID.uuidString)]).first {
                guard event.lastObservedFrame <= (try closure.requireInt(0)) else { throw ArchiveError.conflictingEpoch(event.epochID) }
            }
            try insertCaptureEvent(id: event.messageID, sessionID: event.sessionID, epochID: event.epochID,
                deviceID: event.sourceDeviceID, kind: "epoch_interrupted", payload: WireJSON.encode(event))
        }
    }

    func interruptedEpochBounds(epochID: UUID) throws -> (sealed: Int64, observed: Int64)? {
        let events = try database.rows("SELECT payload FROM capture_events WHERE epoch_id=? AND kind='epoch_interrupted'", [.text(epochID.uuidString)]).map {
            try WireJSON.decode(CaptureEpochInterrupted.self, from: $0.requireData(0))
        }
        guard let first = events.first else { return nil }
        return events.dropFirst().reduce((sealed: first.sealedThroughFrame, observed: first.lastObservedFrame)) {
            (max($0.sealed, $1.sealedThroughFrame), max($0.observed, $1.lastObservedFrame))
        }
    }

    /// Flush only the available sealed prefix; coverage still reports the unknown source tail.
    func analysisClosedFrame(epochID: UUID) throws -> Int64? {
        if let closure = try database.rows("SELECT end_frame FROM epoch_closures WHERE epoch_id=?", [.text(epochID.uuidString)]).first {
            return try closure.requireInt(0)
        }
        guard let bounds = try interruptedEpochBounds(epochID: epochID) else { return nil }
        let maxReceivedEnd = try database.rows("SELECT COALESCE(MAX(end_frame), 0) FROM chunks WHERE epoch_id=?", [.text(epochID.uuidString)]).first?.integer(0) ?? 0
        // A subsequently recovered tail extends available input without inventing a precise capture end.
        return max(bounds.sealed, maxReceivedEnd)
    }

    public func receiveMark(_ event: CaptureMark) throws {
        if try sessionIsDeleted(event.sessionID) { return }
        try database.transaction {
            try validateCaptureIdentity(sessionID: event.sessionID, epochID: event.epochID, sourceDeviceID: event.sourceDeviceID)
            if let closure = try database.rows("SELECT end_frame FROM epoch_closures WHERE epoch_id=?", [.text(event.epochID.uuidString)]).first {
                guard event.sourceFrame <= (try closure.requireInt(0)) else { throw ArchiveError.conflictingEpoch(event.epochID) }
            }
            try insertCaptureEvent(id: event.markID, sessionID: event.sessionID, epochID: event.epochID,
                                   deviceID: event.sourceDeviceID, kind: "mark", payload: WireJSON.encode(event))
        }
    }

    public func marks(sessionID: UUID) throws -> [CaptureMark] {
        guard try !sessionIsDeleted(sessionID) else { throw ArchiveError.sessionDeleted(sessionID) }
        return try database.rows("SELECT payload FROM capture_events WHERE session_id=? AND kind='mark' ORDER BY rowid",
                                 [.text(sessionID.uuidString)]).map {
            try WireJSON.decode(CaptureMark.self, from: $0.requireData(0))
        }
    }

    func validateCaptureEvents(for manifest: ChunkManifest) throws {
        try validateCaptureIdentity(sessionID: manifest.sessionID, epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID)
        if let closure = try database.rows("SELECT end_frame FROM epoch_closures WHERE epoch_id=?", [.text(manifest.epochID.uuidString)]).first {
            guard manifest.frames.end <= (try closure.requireInt(0)) else { throw ArchiveError.conflictingEpoch(manifest.epochID) }
        }
    }

    private func validateCaptureIdentity(sessionID: UUID, epochID: UUID, sourceDeviceID: UUID) throws {
        if let session = try database.rows("SELECT source_device FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first {
            guard session.string(0) == sourceDeviceID.uuidString else { throw ArchiveError.conflictingEpoch(epochID) }
        }
        if let epoch = try database.rows("SELECT session_id FROM epochs WHERE id=?", [.text(epochID.uuidString)]).first {
            guard epoch.string(0) == sessionID.uuidString else { throw ArchiveError.conflictingEpoch(epochID) }
        }
        for row in try database.rows("SELECT session_id,source_device FROM capture_events WHERE epoch_id=? OR session_id=?",
                                     [.text(epochID.uuidString), .text(sessionID.uuidString)]) {
            guard row.string(0) == sessionID.uuidString, row.string(1) == sourceDeviceID.uuidString else {
                throw ArchiveError.conflictingEpoch(epochID)
            }
        }
    }

    private func insertCaptureEvent(id: UUID, sessionID: UUID, epochID: UUID,
                                    deviceID: UUID, kind: String, payload: Data) throws {
        if let row = try database.rows("SELECT payload FROM capture_events WHERE id=?", [.text(id.uuidString)]).first {
            guard try row.requireData(0) == payload else { throw ArchiveError.invalidTranscript }
            return
        }
        try database.execute("INSERT INTO capture_events(id,session_id,epoch_id,source_device,kind,payload) VALUES(?,?,?,?,?,?)",
                             [.text(id.uuidString), .text(sessionID.uuidString), .text(epochID.uuidString),
                              .text(deviceID.uuidString), .text(kind), .blob(payload)])
    }
}
