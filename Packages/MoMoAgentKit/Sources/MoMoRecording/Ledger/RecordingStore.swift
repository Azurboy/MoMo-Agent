import CSQLite
import Darwin
import Foundation
import MoMoContracts

public enum RecordedChunkState: String, Codable, Sendable {
    case ready, acknowledged, removed, deleted, missing, damaged
}

public struct RecordedChunk: Sendable {
    public let envelope: ManifestEnvelope
    public let audioURL: URL
    public let state: RecordedChunkState
}

public enum RecordingError: Error, Equatable, LocalizedError {
    case missingChunk(UUID), contentConflict(UUID), deletedSession(UUID), invalidAudio(UUID)
    case receiptNeedsReconciliation(UUID)
    case receiverNotBound, receiverMismatch, receiptMismatch, invalidDirectory(String)
    case unsupportedSchema(Int64)

    public var errorDescription: String? {
        switch self {
        case .missingChunk: String(localized: "找不到对应的录音片段，其他原音仍会保留。", bundle: AppLanguage.resourceBundle)
        case .contentConflict: String(localized: "录音片段的内容记录不一致，原音已保留。", bundle: AppLanguage.resourceBundle)
        case .deletedSession: String(localized: "这次录音已被删除，不能继续写入。", bundle: AppLanguage.resourceBundle)
        case .invalidAudio: String(localized: "录音片段未通过完整性检查，原音已保留。", bundle: AppLanguage.resourceBundle)
        case .receiptNeedsReconciliation: String(localized: "需要先与手机核对片段，再确认接收。", bundle: AppLanguage.resourceBundle)
        case .receiverNotBound: String(localized: "正在等待手机资料库身份，原音已保留。", bundle: AppLanguage.resourceBundle)
        case .receiverMismatch: String(localized: "手机资料库身份已变化，请先确认接收方。", bundle: AppLanguage.resourceBundle)
        case .receiptMismatch: String(localized: "手机回执与录音片段不匹配，原音已保留。", bundle: AppLanguage.resourceBundle)
        case .invalidDirectory: String(localized: "录音目录异常，无法安全读取。", bundle: AppLanguage.resourceBundle)
        case .unsupportedSchema: String(localized: "录音资料由较新版本创建，请更新应用后重试。", bundle: AppLanguage.resourceBundle)
        }
    }
}

public struct RecordingRecoveryReport: Sendable, Equatable {
    public var registered: [UUID] = []
    public var missing: [UUID] = []
    public var damaged: [UUID] = []
    public var unfinished: [String] = []
    public var cleaned: [UUID] = []
    public init() {}
}

public actor RecordingStore {
    let rootURL: URL
    let database: RecordingDatabase
    private let files = FileManager.default
    var queueIndex: RecordingQueueIndex?
    var queueDataVersion: Int64?
    private(set) var queueDecodedRows = 0

    func noteQueueDecodedRows(_ count: Int) { queueDecodedRows += count }

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try RecordingFileProtection.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for name in ["CaptureWorking", "CaptureReady", "CaptureRepair"] {
            try RecordingFileProtection.createDirectory(at: rootURL.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let db = try RecordingDatabase(url: rootURL.appendingPathComponent("recording.sqlite"))
        let version = try db.rows("PRAGMA user_version") { sqlite3_column_int64($0, 0) }.first ?? 0
        guard version <= 7 else { throw RecordingError.unsupportedSchema(version) }
        if version == 0 {
            try db.transaction {
                try db.execute("CREATE TABLE chunks (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, envelope BLOB NOT NULL, manifest_hash TEXT NOT NULL, state TEXT NOT NULL)")
                try db.execute("CREATE TABLE receipts (receipt_id TEXT PRIMARY KEY, chunk_id TEXT NOT NULL REFERENCES chunks(id), payload BLOB NOT NULL, application BLOB NOT NULL)")
                try db.execute("CREATE TABLE receiver (id INTEGER PRIMARY KEY CHECK (id = 1), device_id TEXT NOT NULL, library_id TEXT NOT NULL)")
                try db.execute("CREATE TABLE deletions (session_id TEXT PRIMARY KEY, generation INTEGER NOT NULL, payload BLOB NOT NULL, application BLOB NOT NULL)")
                try db.execute("CREATE TABLE deletion_applications (deletion_id TEXT PRIMARY KEY, payload BLOB NOT NULL, application BLOB NOT NULL, completed INTEGER NOT NULL DEFAULT 0)")
                try db.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, intent TEXT NOT NULL)")
                try db.execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try db.transaction {
                try db.execute("CREATE TABLE capture_events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload BLOB NOT NULL)")
                try db.execute("CREATE TABLE capture_epochs (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, device_id TEXT NOT NULL, ended INTEGER NOT NULL DEFAULT 0)")
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try db.transaction {
                try db.execute("CREATE TABLE working_owners (chunk_id TEXT PRIMARY KEY, session_id TEXT NOT NULL)")
                try db.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try db.transaction {
                try db.execute("CREATE TABLE capture_diagnostics (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                try db.execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try db.transaction {
                try db.execute("CREATE TABLE reconciliation_requests(id TEXT PRIMARY KEY,payload BLOB NOT NULL,end_sequence INTEGER NOT NULL,processed INTEGER NOT NULL DEFAULT 0)")
                try db.execute("CREATE TABLE reconciliation_round(id INTEGER PRIMARY KEY CHECK(id=1),source_id TEXT NOT NULL,receiver_id TEXT NOT NULL,library_id TEXT NOT NULL,high_water INTEGER NOT NULL,cursor INTEGER NOT NULL DEFAULT 0,request_id TEXT)")
                try db.execute("CREATE TABLE reconciliation_file_actions(chunk_id TEXT PRIMARY KEY REFERENCES chunks(id),action TEXT NOT NULL)")
                try db.execute("CREATE TABLE reconciliation_receipt_holds(chunk_id TEXT PRIMARY KEY REFERENCES chunks(id),request_id TEXT NOT NULL)")
                try db.execute("CREATE TABLE recording_status(id INTEGER PRIMARY KEY CHECK(id=1),store_id TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,payload BLOB)")
                try db.execute("INSERT INTO recording_status(id,store_id) VALUES(1,?)", [.text(UUID().uuidString)])
                try db.execute("PRAGMA user_version = 5")
            }
        }
        if version < 6 {
            try db.transaction {
                try db.execute("CREATE TABLE control_deliveries(id TEXT PRIMARY KEY,payload_hash TEXT NOT NULL)")
                try db.execute("CREATE TABLE control_positions(kind TEXT PRIMARY KEY,position INTEGER NOT NULL)")
                try db.execute("PRAGMA user_version = 6")
            }
        }
        if version < 7 {
            try db.transaction {
                try db.execute("ALTER TABLE reconciliation_round ADD COLUMN full_history INTEGER NOT NULL DEFAULT 1")
                try db.execute("ALTER TABLE reconciliation_round ADD COLUMN history_audited_at REAL")
                try db.execute("PRAGMA user_version = 7")
            }
        }
        self.database = db
    }

    public func saveIntent(_ intent: CaptureIntent, sessionID: UUID) throws {
        guard try !isDeleted(sessionID) else { throw RecordingError.deletedSession(sessionID) }
        try database.execute("INSERT INTO sessions(id, intent) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET intent=excluded.intent", [.text(sessionID.uuidString), .text(intent.rawValue)])
    }

    public func intent(sessionID: UUID) throws -> CaptureIntent? {
        try database.rows("SELECT intent FROM sessions WHERE id = ?", [.text(sessionID.uuidString)]) { row in
            guard let value = CaptureIntent(rawValue: RecordingDatabase.text(row, 0)) else {
                throw RecordingDatabaseError(code: SQLITE_CORRUPT, message: "Unknown capture intent")
            }
            return value
        }.first
    }

    public func latestActiveSession() throws -> (sessionID: UUID, intent: CaptureIntent)? {
        try database.rows("SELECT id, intent FROM sessions WHERE intent!='stopped' AND id NOT IN (SELECT session_id FROM deletions) ORDER BY rowid DESC LIMIT 1") { row in
            guard let id = UUID(uuidString: RecordingDatabase.text(row, 0)), let intent = CaptureIntent(rawValue: RecordingDatabase.text(row, 1)) else {
                throw RecordingDatabaseError(code: SQLITE_CORRUPT, message: "Invalid capture session")
            }
            return (sessionID: id, intent: intent)
        }.first
    }

    public func sealedEndFrame(sessionID: UUID, epochID: UUID) throws -> Int64 {
        let manifests = try database.rows("SELECT envelope FROM chunks WHERE session_id=?", [.text(sessionID.uuidString)]) { try decode(ManifestEnvelope.self, RecordingDatabase.data($0, 0)).manifest }
        return manifests.filter { $0.epochID == epochID }.map(\.frames.end).max() ?? 0
    }

    /// Historical sealed coverage includes originals removed after a receipt, but never an unsealed tail.
    public func sealedDuration(sessionID: UUID, excludingEpochID: UUID? = nil) throws -> TimeInterval {
        guard try !isDeleted(sessionID) else { return 0 }
        let manifests = try database.rows("SELECT envelope FROM chunks WHERE session_id=? AND state!='deleted'", [.text(sessionID.uuidString)]) {
            try decode(ManifestEnvelope.self, RecordingDatabase.data($0, 0)).manifest
        }
        var seconds: TimeInterval = 0
        for chunks in Dictionary(grouping: manifests.filter { $0.epochID != excludingEpochID }, by: \.epochID).values {
            guard let first = chunks.first else { continue }
            var end: Int64 = 0
            for manifest in chunks.sorted(by: { $0.frames.start < $1.frames.start }) {
                guard manifest.timebaseHz == first.timebaseHz else { throw RecordingError.contentConflict(manifest.chunkID) }
                let start = max(end, manifest.frames.start)
                if manifest.frames.end > start { seconds += Double(manifest.frames.end - start) / manifest.timebaseHz }
                end = max(end, manifest.frames.end)
            }
        }
        return seconds
    }

    public func bindReceiver(deviceID: UUID, libraryInstanceID: UUID) throws {
        if let bound = try boundReceiver() {
            guard bound.0 == deviceID, bound.1 == libraryInstanceID else { throw RecordingError.receiverMismatch }
            return
        }
        try database.execute("INSERT INTO receiver(id, device_id, library_id) VALUES (1, ?, ?)", [.text(deviceID.uuidString), .text(libraryInstanceID.uuidString)])
    }

    /// Only a user-confirmed pairing change may replace the receiver. Old receipts cannot authorize cleanup.
    public func replaceReceiverAfterUserConfirmation(deviceID: UUID, libraryInstanceID: UUID) throws {
        if let bound = try boundReceiver(), bound.0 == deviceID, bound.1 == libraryInstanceID { return }
        try database.transaction {
            try database.execute("DELETE FROM receipts")
            try database.execute("DELETE FROM reconciliation_requests")
            try database.execute("DELETE FROM reconciliation_round")
            try database.execute("DELETE FROM reconciliation_file_actions")
            try database.execute("DELETE FROM reconciliation_receipt_holds")
            try database.execute("DELETE FROM control_deliveries")
            try database.execute("DELETE FROM control_positions")
            try database.execute("UPDATE chunks SET state='ready' WHERE state='acknowledged'")
            try database.execute("INSERT INTO receiver(id, device_id, library_id) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET device_id=excluded.device_id, library_id=excluded.library_id", [.text(deviceID.uuidString), .text(libraryInstanceID.uuidString)])
        }
    }

    public func boundReceiver() throws -> (deviceID: UUID, libraryInstanceID: UUID)? {
        try database.rows("SELECT device_id, library_id FROM receiver WHERE id=1") { row in
            guard let device = UUID(uuidString: RecordingDatabase.text(row, 0)),
                  let library = UUID(uuidString: RecordingDatabase.text(row, 1)) else {
                throw RecordingDatabaseError(code: SQLITE_CORRUPT, message: "Invalid receiver identity")
            }
            return (device, library)
        }.first
    }

    public func beginEpoch(sessionID: UUID, epochID: UUID, sourceDeviceID: UUID) throws {
        guard try !isDeleted(sessionID) else { throw RecordingError.deletedSession(sessionID) }
        try database.execute("INSERT INTO capture_epochs(id, session_id, device_id) VALUES (?, ?, ?)", [.text(epochID.uuidString), .text(sessionID.uuidString), .text(sourceDeviceID.uuidString)])
    }

    public func isCaptureEpochOpen(_ epochID: UUID) throws -> Bool {
        try database.rows("SELECT ended FROM capture_epochs WHERE id=?", [.text(epochID.uuidString)]) {
            sqlite3_column_int64($0, 0) == 0
        }.first == true
    }

    /// Called once after process exit, before admitting capture. Retire old recording/paused intent,
    /// while retaining audio and honest interruption bounds for recovery and synchronization.
    public func recoverInterruptedEpochs() throws -> [CaptureEpochInterrupted] {
        let epochs = try database.rows("SELECT id, session_id, device_id FROM capture_epochs WHERE ended=0") { row -> (UUID, UUID, UUID) in
            guard let epoch = UUID(uuidString: RecordingDatabase.text(row, 0)), let session = UUID(uuidString: RecordingDatabase.text(row, 1)), let device = UUID(uuidString: RecordingDatabase.text(row, 2)) else {
                throw RecordingDatabaseError(code: SQLITE_CORRUPT, message: "Invalid capture epoch")
            }
            return (epoch, session, device)
        }
        var result: [CaptureEpochInterrupted] = []
        for (epoch, session, device) in epochs {
            result.append(try recordEpochInterruption(sessionID: session, epochID: epoch, sourceDeviceID: device, reason: .interrupted))
        }
        // The process can die while muted, with no open epoch. Both cases start fresh next time.
        try database.execute("UPDATE sessions SET intent='stopped' WHERE intent!='stopped'")
        return result
    }

    @discardableResult public func recordEpochInterruption(sessionID: UUID, epochID: UUID, sourceDeviceID: UUID,
                                                           lastObservedFrame: Int64 = 0,
                                                           reason: CaptureEndReason) throws -> CaptureEpochInterrupted {
        guard lastObservedFrame >= 0, reason == .interrupted || reason == .failed else {
            throw ContractError.invalidField("epoch_interruption")
        }
        return try database.transaction {
            let events = try database.rows("SELECT payload FROM capture_events WHERE session_id=?", [.text(sessionID.uuidString)]) {
                try decode(ControlMessage.self, RecordingDatabase.data($0, 0))
            }
            var observed = lastObservedFrame
            for event in events {
                if case .epochInterrupted(let existing) = event, existing.epochID == epochID {
                    guard existing.sourceDeviceID == sourceDeviceID else { throw RecordingError.contentConflict(epochID) }
                    return existing
                }
                if case .captureMark(let mark) = event, mark.epochID == epochID { observed = max(observed, mark.sourceFrame) }
            }
            let sealed = try sealedEndFrame(sessionID: sessionID, epochID: epochID)
            let event = try CaptureEpochInterrupted(sessionID: sessionID, epochID: epochID, sourceDeviceID: sourceDeviceID,
                sealedThroughFrame: sealed, lastObservedFrame: max(sealed, observed), reason: reason)
            try persistCaptureEvent(.epochInterrupted(event), id: event.messageID, sessionID: sessionID)
            try database.execute("UPDATE capture_epochs SET ended=1 WHERE id=? AND session_id=?", [.text(epochID.uuidString), .text(sessionID.uuidString)])
            return event
        }
    }

    public func recordEpochEnded(_ event: CaptureEpochEnded) throws {
        try database.transaction {
            try persistCaptureEvent(.epochEnded(event), id: event.messageID, sessionID: event.sessionID)
            try database.execute("UPDATE capture_epochs SET ended=1 WHERE id=? AND session_id=?", [.text(event.epochID.uuidString), .text(event.sessionID.uuidString)])
        }
    }

    public func recordMark(_ event: CaptureMark) throws {
        guard try !isDeleted(event.sessionID) else { throw RecordingError.deletedSession(event.sessionID) }
        try database.transaction {
            try persistCaptureEvent(.captureMark(event), id: event.messageID, sessionID: event.sessionID)
            try database.execute("INSERT INTO control_positions(kind,position) SELECT 'audio_mark',rowid FROM capture_events WHERE id=? ON CONFLICT(kind) DO UPDATE SET position=excluded.position", [.text(event.messageID.uuidString)])
        }
    }

    /// Delivery is replayable. The receiver deduplicates by message identity.
    public func pendingCaptureEvents() throws -> [ControlMessage] {
        try database.rows("SELECT payload FROM capture_events WHERE session_id NOT IN (SELECT session_id FROM deletions) ORDER BY rowid") {
            try decode(ControlMessage.self, RecordingDatabase.data($0, 0))
        }
    }

    /// Cursors are transport-local. Restarting at zero replays the retained, stable message IDs.
    public func controlBatch(kind: RecordingControlKind, after sequence: Int64, limit: Int = 32) throws -> [RecordingControlEntry] {
        let query: String
        switch kind {
        case .capture: query = "SELECT rowid,payload FROM capture_events WHERE session_id NOT IN (SELECT session_id FROM deletions) AND id NOT IN (SELECT id FROM control_deliveries) AND rowid>? ORDER BY rowid LIMIT ?"
        case .receipt: query = "SELECT rowid,application FROM receipts WHERE rowid>? AND chunk_id NOT IN (SELECT chunk_id FROM reconciliation_receipt_holds) AND json_extract(CAST(application AS TEXT),'$.messageID') NOT IN (SELECT id FROM control_deliveries) ORDER BY rowid LIMIT ?"
        case .deletion: query = "SELECT rowid,application FROM deletion_applications WHERE completed=1 AND rowid>? AND json_extract(CAST(application AS TEXT),'$.messageID') NOT IN (SELECT id FROM control_deliveries) ORDER BY rowid LIMIT ?"
        }
        return try database.rows(query, [.integer(sequence), .integer(Int64(min(32, max(0, limit))))]) { row in
            let data = RecordingDatabase.data(row, 1)
            let message: ControlMessage
            switch kind {
            case .capture: message = try decode(ControlMessage.self, data)
            case .receipt: message = .receiptApplied(try decode(ReceiptApplied.self, data))
            case .deletion: message = .deleteApplied(try decode(DeleteApplied.self, data))
            }
            return RecordingControlEntry(sequence: sqlite3_column_int64(row, 0), message: message)
        }
    }

    /// Only the peer's persisted-Inbox reply is sufficient; SDK completion alone is not.
    public func markControlPreserved(_ message: ControlMessage, receiverDeviceID: UUID, libraryInstanceID: UUID) throws {
        guard let receiver = try boundReceiver(), receiver.deviceID == receiverDeviceID,
              receiver.libraryInstanceID == libraryInstanceID else { throw RecordingError.receiverMismatch }
        switch message {
        case .epochEnded, .epochInterrupted, .captureMark, .receiptApplied, .deleteApplied: break
        default: return
        }
        let hash = ContentHash.sha256(try WireJSON.encode(message))
        if let saved = try database.rows("SELECT payload_hash FROM control_deliveries WHERE id=?", [.text(message.messageID.uuidString)], read: { RecordingDatabase.text($0, 0) }).first {
            guard saved == hash else { throw RecordingError.contentConflict(message.messageID) }
        } else {
            try database.execute("INSERT INTO control_deliveries(id,payload_hash) VALUES(?,?)", [.text(message.messageID.uuidString), .text(hash)])
        }
    }

    public func controlPosition(kind: RecordingControlKind) throws -> Int64 {
        try database.rows("SELECT position FROM control_positions WHERE kind=?", [.text(kind.rawValue)]) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    public func saveControlPosition(_ position: Int64, kind: RecordingControlKind) throws {
        guard position >= 0 else { throw RecordingReconciliationError.invalidCursor }
        try database.execute("INSERT INTO control_positions(kind,position) VALUES(?,?) ON CONFLICT(kind) DO UPDATE SET position=excluded.position WHERE position!=excluded.position", [.text(kind.rawValue), .integer(position)])
    }

    public func fileTransferPosition() throws -> Int64 {
        try database.rows("SELECT position FROM control_positions WHERE kind='file'", read: { sqlite3_column_int64($0, 0) }).first ?? 0
    }

    public func saveFileTransferPosition(_ position: Int64) throws {
        guard position >= 0 else { throw RecordingReconciliationError.invalidCursor }
        try database.execute("INSERT INTO control_positions(kind,position) VALUES('file',?) ON CONFLICT(kind) DO UPDATE SET position=excluded.position WHERE position!=excluded.position", [.integer(position)])
    }

    public func hasPendingControlMessages() throws -> Bool {
        for kind in RecordingControlKind.allCases {
            if try !controlBatch(kind: kind, after: 0, limit: 1).isEmpty { return true }
        }
        return false
    }

    private func persistCaptureEvent(_ event: ControlMessage, id: UUID, sessionID: UUID) throws {
        let bytes = try encode(event)
        if let existing = try database.rows("SELECT payload FROM capture_events WHERE id=?", [.text(id.uuidString)], read: { RecordingDatabase.data($0, 0) }).first {
            guard bytes == existing else { throw RecordingError.contentConflict(id) }
            return
        }
        try database.execute("INSERT INTO capture_events(id, session_id, payload) VALUES (?, ?, ?)", [.text(id.uuidString), .text(sessionID.uuidString), .blob(bytes)])
    }

    /// The source must be a closed encoded file. Ownership remains with its caller.
    public func sealChunk(audioAt source: URL, envelope: ManifestEnvelope) throws -> RecordedChunk {
        let manifest = envelope.manifest
        guard try !isDeleted(manifest.sessionID) else { throw RecordingError.deletedSession(manifest.sessionID) }
        if let existing = try chunk(id: manifest.chunkID) {
            guard existing.envelope.manifestSHA256 == envelope.manifestSHA256 else { throw RecordingError.contentConflict(manifest.chunkID) }
            if existing.state == .ready || existing.state == .acknowledged { try validateAudio(existing.audioURL, manifest: manifest) }
            return existing
        }
        try validateAudio(source, manifest: manifest)
        try database.execute("INSERT INTO working_owners(chunk_id,session_id) VALUES(?,?) ON CONFLICT(chunk_id) DO NOTHING", [.text(manifest.chunkID.uuidString), .text(manifest.sessionID.uuidString)])
        guard try workingOwner(id: manifest.chunkID) == manifest.sessionID else { throw RecordingError.contentConflict(manifest.chunkID) }
        let working = directory("CaptureWorking", manifest.chunkID)
        let ready = directory("CaptureReady", manifest.chunkID)
        if files.fileExists(atPath: ready.path) {
            let stored = try readEnvelope(at: ready)
            guard stored.manifestSHA256 == envelope.manifestSHA256 else { throw RecordingError.contentConflict(manifest.chunkID) }
            try validateAudio(ready.appendingPathComponent("audio"), manifest: stored.manifest)
        } else {
            if files.fileExists(atPath: working.path) {
                let attributes = try working.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true,
                      !source.resolvingSymlinksInPath().path.hasPrefix(working.resolvingSymlinksInPath().path + "/") else {
                    throw RecordingError.invalidDirectory(working.lastPathComponent)
                }
                let entries = try files.contentsOfDirectory(at: working, includingPropertiesForKeys: [.isSymbolicLinkKey])
                if !entries.isEmpty {
                    let draft = try decode(ManifestEnvelope.self, Data(contentsOf: working.appendingPathComponent("draft.json")))
                    guard draft.manifestSHA256 == envelope.manifestSHA256 else { throw RecordingError.contentConflict(manifest.chunkID) }
                    for entry in entries {
                        guard ["draft.json", "audio", "manifest.json", "envelope.json"].contains(entry.lastPathComponent),
                              try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                            throw RecordingError.invalidDirectory(entry.lastPathComponent)
                        }
                    }
                }
                // The closed source was verified above; retrying a partial copy cannot lose its only valid audio.
                try files.removeItem(at: working)
            }
            try RecordingFileProtection.createDirectory(at: working, withIntermediateDirectories: false)
            try durableWrite(try encode(envelope), to: working.appendingPathComponent("draft.json"))
            let destination = working.appendingPathComponent("audio")
            try files.copyItem(at: source, to: destination)
            RecordingFileProtection.apply(to: destination)
            try synchronize(destination)
            try validateAudio(destination, manifest: manifest)
            try durableWrite(envelope.manifestData, to: working.appendingPathComponent("manifest.json"))
            try durableWrite(try encode(envelope), to: working.appendingPathComponent("envelope.json"))
            try synchronizeDirectory(working)
            try files.moveItem(at: working, to: ready)
            try synchronizeDirectory(ready.deletingLastPathComponent())
            try synchronizeDirectory(working.deletingLastPathComponent())
        }
        try register(envelope)
        return RecordedChunk(envelope: envelope, audioURL: ready.appendingPathComponent("audio"), state: .ready)
    }

    public func chunk(id: UUID) throws -> RecordedChunk? {
        try database.rows("SELECT envelope, state FROM chunks WHERE id = ?", [.text(id.uuidString)]) { row in
            let envelope = try decode(ManifestEnvelope.self, RecordingDatabase.data(row, 0))
            guard let state = RecordedChunkState(rawValue: RecordingDatabase.text(row, 1)) else {
                throw RecordingDatabaseError(code: SQLITE_CORRUPT, message: "Unknown chunk state")
            }
            return RecordedChunk(envelope: envelope, audioURL: directory("CaptureReady", id).appendingPathComponent("audio"), state: state)
        }.first
    }

    public func pendingChunkCount() throws -> Int {
        Int(try database.rows("SELECT COUNT(*) FROM chunks WHERE state='ready'") { sqlite3_column_int64($0, 0) }.first ?? 0)
    }

    public func pendingChunks(limit: Int? = nil) throws -> [RecordedChunk] {
        try database.rows("SELECT envelope FROM chunks WHERE state = 'ready' AND id NOT IN (SELECT chunk_id FROM reconciliation_file_actions WHERE action!='retry') ORDER BY rowid LIMIT ?", [.integer(Int64(max(0, limit ?? Int.max)))]) { row in
            let envelope = try decode(ManifestEnvelope.self, RecordingDatabase.data(row, 0))
            return RecordedChunk(envelope: envelope, audioURL: directory("CaptureReady", envelope.manifest.chunkID).appendingPathComponent("audio"), state: .ready)
        }
    }

    /// Receipt and ReceiptApplied become durable together. File removal is a separate recoverable step.
    public func applyReceipt(_ receipt: Receipt) throws -> ReceiptApplied {
        try persistReceipt(receipt, reconciliationRequestID: nil).application
    }

    func applyReconciledReceipt(_ receipt: Receipt, requestID: UUID) throws -> (application: ReceiptApplied, pendingDelivery: Bool) {
        try persistReceipt(receipt, reconciliationRequestID: requestID)
    }

    private func persistReceipt(_ receipt: Receipt, reconciliationRequestID: UUID?) throws -> (application: ReceiptApplied, pendingDelivery: Bool) {
        try database.transaction {
            guard let receiver = try database.rows("SELECT device_id, library_id FROM receiver WHERE id=1", read: { (RecordingDatabase.text($0, 0), RecordingDatabase.text($0, 1)) }).first else {
                throw RecordingError.receiverNotBound
            }
            guard receiver.0 == receipt.receiverDeviceID.uuidString, receiver.1 == receipt.libraryInstanceID.uuidString else { throw RecordingError.receiverMismatch }
            guard let chunk = try chunk(id: receipt.chunkID) else { throw RecordingError.missingChunk(receipt.chunkID) }
            guard chunk.state != .deleted, try !isDeleted(chunk.envelope.manifest.sessionID) else { throw RecordingError.deletedSession(chunk.envelope.manifest.sessionID) }
            guard receipt.audioSHA256 == chunk.envelope.manifest.audioSHA256,
                  receipt.manifestSHA256 == chunk.envelope.manifestSHA256,
                  receipt.representation == chunk.envelope.manifest.representation else { throw RecordingError.receiptMismatch }
            let existingHold = try database.rows("SELECT request_id FROM reconciliation_receipt_holds WHERE chunk_id=?", [.text(receipt.chunkID.uuidString)], read: { RecordingDatabase.text($0, 0) }).first
            if let heldBy = existingHold {
                guard let reconciliationRequestID, heldBy != reconciliationRequestID.uuidString else {
                    throw RecordingError.receiptNeedsReconciliation(receipt.chunkID)
                }
            }
            let saved = try database.rows("SELECT payload, application FROM receipts WHERE receipt_id = ?", [.text(receipt.receiptID.uuidString)], read: { (RecordingDatabase.data($0, 0), RecordingDatabase.data($0, 1)) }).first
            let application: ReceiptApplied
            if let saved {
                guard saved.0 == (try encode(receipt)) else { throw RecordingError.receiptMismatch }
                application = try decode(ReceiptApplied.self, saved.1)
            } else {
                application = ReceiptApplied(receipt: receipt)
                try database.execute("INSERT INTO receipts(receipt_id, chunk_id, payload, application) VALUES (?, ?, ?, ?)", [.text(receipt.receiptID.uuidString), .text(receipt.chunkID.uuidString), .blob(try encode(receipt)), .blob(try encode(application))])
            }
            try database.execute("DELETE FROM reconciliation_file_actions WHERE chunk_id=?", [.text(receipt.chunkID.uuidString)])
            try database.execute("DELETE FROM reconciliation_receipt_holds WHERE chunk_id=?", [.text(receipt.chunkID.uuidString)])
            if chunk.state != .removed {
                try database.execute("UPDATE chunks SET state='acknowledged' WHERE id=?", [.text(receipt.chunkID.uuidString)])
            }
            let shouldRequeueDelivery = reconciliationRequestID == nil || saved == nil || existingHold != nil || (chunk.state != .acknowledged && chunk.state != .removed)
            if shouldRequeueDelivery {
                try database.execute("DELETE FROM control_deliveries WHERE id=?", [.text(application.messageID.uuidString)])
            }
            let alreadyDelivered = try !shouldRequeueDelivery && !database.rows("SELECT 1 FROM control_deliveries WHERE id=? LIMIT 1", [.text(application.messageID.uuidString)], read: { _ in true }).isEmpty
            if !alreadyDelivered, saved != nil {
                try database.execute("UPDATE control_positions SET position=0 WHERE kind='receipt' AND position!=0")
            }
            return (application, !alreadyDelivered)
        }
    }

    /// Retained after transmission for reconciliation; this does not add another acknowledgment layer.
    public func pendingReceiptApplications() throws -> [ReceiptApplied] {
        try database.rows("SELECT application FROM receipts WHERE chunk_id NOT IN (SELECT chunk_id FROM reconciliation_receipt_holds) ORDER BY rowid") { try decode(ReceiptApplied.self, RecordingDatabase.data($0, 0)) }
    }

    /// Reuse only a durable, still-authoritative receipt. A missing/expired/conflicting
    /// reconciliation result holds old receipts until a new result has been applied.
    public func confirmedReceipt(chunkID: UUID) throws -> Receipt? {
        try database.rows("""
            SELECT r.payload FROM receipts r JOIN chunks c ON c.id=r.chunk_id
            WHERE r.chunk_id=? AND c.state IN ('acknowledged','removed')
            AND r.chunk_id NOT IN (SELECT chunk_id FROM reconciliation_receipt_holds)
            AND c.session_id NOT IN (SELECT session_id FROM deletions)
            ORDER BY r.rowid DESC LIMIT 1
            """, [.text(chunkID.uuidString)]) { try decode(Receipt.self, RecordingDatabase.data($0, 0)) }.first
    }

    @discardableResult public func cleanupAcknowledgedChunks(limit: Int = .max) throws -> [UUID] {
        // Deletion cleanup requires the platform's explicit capture-stopped barrier.
        try cleanup(states: ["acknowledged"], limit: max(0, limit))
    }

    public func prepareDeletion(_ deletion: DeleteSession, deviceID: UUID) throws {
        if deletion.receiverDeviceID != nil { try validateDeletionReceiver(deletion) }
        try database.transaction {
            guard deletion.generation > 0 else { throw RecordingError.deletedSession(deletion.sessionID) }
            if let existing = try database.rows("SELECT payload, application FROM deletion_applications WHERE deletion_id=?", [.text(deletion.deletionID.uuidString)], read: { (RecordingDatabase.data($0, 0), RecordingDatabase.data($0, 1)) }).first {
                if existing.0 != (try encode(deletion)) {
                    let previous = try decode(DeleteSession.self, existing.0)
                    guard previous.receiverDeviceID == nil, previous.libraryInstanceID == nil,
                          previous.deletionID == deletion.deletionID, previous.sessionID == deletion.sessionID,
                          previous.generation == deletion.generation else { throw RecordingError.contentConflict(deletion.deletionID) }
                    try validateDeletionReceiver(deletion)
                    try database.execute("UPDATE deletion_applications SET payload=? WHERE deletion_id=?", [.blob(try encode(deletion)), .text(deletion.deletionID.uuidString)])
                }
                return
            }
            let applied = DeleteApplied(deletionID: deletion.deletionID, deviceID: deviceID)
            try database.execute("INSERT INTO deletion_applications(deletion_id,payload,application) VALUES(?,?,?)", [.text(deletion.deletionID.uuidString), .blob(try encode(deletion)), .blob(try encode(applied))])
            if let existing = try database.rows("SELECT generation, application FROM deletions WHERE session_id=?", [.text(deletion.sessionID.uuidString)], read: { (sqlite3_column_int64($0, 0), RecordingDatabase.data($0, 1)) }).first,
               existing.0 >= deletion.generation {
                return
            }
            try database.execute("INSERT INTO deletions(session_id,generation,payload,application) VALUES(?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET generation=excluded.generation,payload=excluded.payload,application=excluded.application", [.text(deletion.sessionID.uuidString), .integer(deletion.generation), .blob(try encode(deletion)), .blob(try encode(applied))])
            try database.execute("UPDATE chunks SET state='deleted' WHERE session_id=?", [.text(deletion.sessionID.uuidString)])
            try database.execute("UPDATE sessions SET intent='stopped' WHERE id=?", [.text(deletion.sessionID.uuidString)])
        }
    }

    /// Call only after the platform has stopped the affected capture and released its writer.
    public func completeDeletionAfterCaptureStopped(deletionID: UUID) throws -> DeleteApplied {
        guard let entry = try database.rows("SELECT payload, application FROM deletion_applications WHERE deletion_id=?", [.text(deletionID.uuidString)], read: { (RecordingDatabase.data($0, 0), RecordingDatabase.data($0, 1)) }).first else {
            throw RecordingError.missingChunk(deletionID)
        }
        let deletion = try decode(DeleteSession.self, entry.0)
        _ = try cleanup(states: ["deleted"], sessionID: deletion.sessionID)
        for directory in try files.contentsOfDirectory(at: rootURL.appendingPathComponent("CaptureWorking"), includingPropertiesForKeys: nil) {
            let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if attributes.isDirectory == true, attributes.isSymbolicLink != true,
               try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty {
                try files.removeItem(at: directory)
                continue
            }
            if let owner = try workingOwner(at: directory) {
                if owner == deletion.sessionID { try files.removeItem(at: directory) }
            } else {
                try quarantineWorking(directory)
            }
        }
        try synchronizeDirectory(rootURL.appendingPathComponent("CaptureWorking"))
        try database.execute("UPDATE deletion_applications SET completed=1 WHERE deletion_id=?", [.text(deletionID.uuidString)])
        let applied = try decode(DeleteApplied.self, entry.1)
        try database.execute("DELETE FROM control_deliveries WHERE id=?", [.text(applied.messageID.uuidString)])
        return applied
    }

    public func pendingDeletions() throws -> [DeleteSession] {
        try database.rows("SELECT payload FROM deletion_applications WHERE completed=0 ORDER BY rowid") { try decode(DeleteSession.self, RecordingDatabase.data($0, 0)) }
    }

    public func validateDeletionReceiver(_ deletion: DeleteSession) throws {
        guard let receiver = try boundReceiver() else { throw RecordingError.receiverNotBound }
        guard deletion.receiverDeviceID == receiver.deviceID, deletion.libraryInstanceID == receiver.libraryInstanceID else {
            throw RecordingError.receiverMismatch
        }
    }

    public func pendingDeletionApplications() throws -> [DeleteApplied] {
        try database.rows("SELECT application FROM deletion_applications WHERE completed=1 ORDER BY rowid") { try decode(DeleteApplied.self, RecordingDatabase.data($0, 0)) }
    }

    public func recover(now: Date = Date(), repairRetentionInterval: TimeInterval = 14 * 86_400) async throws -> RecordingRecoveryReport {
        var report = RecordingRecoveryReport()
        try pruneExpiredRepairEntries(
            in: rootURL.appendingPathComponent("CaptureRepair"),
            now: now,
            retentionInterval: repairRetentionInterval
        )
        report.unfinished += try files.contentsOfDirectory(at: rootURL.appendingPathComponent("CaptureRepair"), includingPropertiesForKeys: nil)
            .map { "CaptureRepair/" + $0.lastPathComponent }
        for entry in try files.contentsOfDirectory(at: rootURL.appendingPathComponent("CaptureWorking"), includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            await Task.yield()
            try Task.checkCancellation()
            let attributes = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attributes.isSymbolicLink != true, attributes.isDirectory == true else {
                if try workingOwner(at: entry) == nil { try quarantineWorking(entry) }
                report.unfinished.append(entry.lastPathComponent)
                continue
            }
            if try files.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil).isEmpty {
                try files.removeItem(at: entry)
                continue
            }
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  files.fileExists(atPath: entry.appendingPathComponent("envelope.json").path),
                  files.fileExists(atPath: entry.appendingPathComponent("manifest.json").path) else {
                report.unfinished.append(entry.lastPathComponent)
                if try workingOwner(at: entry) == nil { try quarantineWorking(entry) }
                continue
            }
            do {
                let envelope = try readEnvelope(at: entry)
                guard envelope.manifest.chunkID == id else { throw RecordingError.contentConflict(id) }
                if try isDeleted(envelope.manifest.sessionID) {
                    try files.removeItem(at: entry)
                    report.cleaned.append(id)
                    continue
                }
                try validateAudio(entry.appendingPathComponent("audio"), manifest: envelope.manifest)
                let ready = directory("CaptureReady", id)
                if files.fileExists(atPath: ready.path) {
                    let existing = try readEnvelope(at: ready)
                    guard existing.manifestSHA256 == envelope.manifestSHA256 else { throw RecordingError.contentConflict(id) }
                    try validateAudio(ready.appendingPathComponent("audio"), manifest: existing.manifest)
                    try files.removeItem(at: entry)
                } else {
                    try files.moveItem(at: entry, to: ready)
                }
            } catch let error as RecordingError {
                switch error {
                case .invalidAudio, .contentConflict:
                    try quarantineWorking(entry)
                    report.damaged.append(id)
                default: throw error
                }
            } catch is DecodingError {
                try quarantineWorking(entry)
                report.damaged.append(id)
            } catch is ContractError {
                try quarantineWorking(entry)
                report.damaged.append(id)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                report.unfinished.append(entry.lastPathComponent)
            }
        }
        for entry in try files.contentsOfDirectory(at: rootURL.appendingPathComponent("CaptureReady"), includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            await Task.yield()
            try Task.checkCancellation()
            guard let id = UUID(uuidString: entry.lastPathComponent) else { report.unfinished.append(entry.lastPathComponent); continue }
            // A receipt can remove a later directory while recovery yields between entries.
            let known = try chunk(id: id)
            if known?.state == .acknowledged || known?.state == .removed { continue }
            do {
                let resource = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard resource.isSymbolicLink != true, resource.isDirectory == true else { throw RecordingError.invalidDirectory(entry.lastPathComponent) }
                let envelope = try readEnvelope(at: entry)
                guard envelope.manifest.chunkID == id else { throw RecordingError.contentConflict(id) }
                if try isDeleted(envelope.manifest.sessionID) {
                    try files.removeItem(at: entry)
                    report.cleaned.append(id)
                    continue
                }
                try validateAudio(entry.appendingPathComponent("audio"), manifest: envelope.manifest)
                try register(envelope)
                report.registered.append(id)
            } catch let error as RecordingError {
                switch error {
                case .invalidAudio, .contentConflict, .invalidDirectory:
                    try database.execute("UPDATE chunks SET state='damaged' WHERE id=?", [.text(id.uuidString)])
                    report.damaged.append(id)
                default: throw error
                }
            } catch is DecodingError {
                try database.execute("UPDATE chunks SET state='damaged' WHERE id=?", [.text(id.uuidString)])
                report.damaged.append(id)
            } catch is ContractError {
                try database.execute("UPDATE chunks SET state='damaged' WHERE id=?", [.text(id.uuidString)])
                report.damaged.append(id)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                try database.execute("UPDATE chunks SET state='missing' WHERE id=?", [.text(id.uuidString)])
                report.missing.append(id)
            }
        }
        for chunk in try pendingChunks() where !files.fileExists(atPath: chunk.audioURL.path) {
            try database.execute("UPDATE chunks SET state='missing' WHERE id=?", [.text(chunk.envelope.manifest.chunkID.uuidString)])
            report.missing.append(chunk.envelope.manifest.chunkID)
        }
        while true {
            await Task.yield()
            try Task.checkCancellation()
            let cleaned = try cleanup(states: ["acknowledged"], limit: 8)
            report.cleaned += cleaned
            if cleaned.count < 8 { break }
        }
        try pruneHistoricalLedger(now: now)
        return report
    }

    private func register(_ envelope: ManifestEnvelope) throws {
        if let existing = try chunk(id: envelope.manifest.chunkID) {
            guard existing.envelope.manifestSHA256 == envelope.manifestSHA256 else { throw RecordingError.contentConflict(envelope.manifest.chunkID) }
            return
        }
        guard try !isDeleted(envelope.manifest.sessionID) else { throw RecordingError.deletedSession(envelope.manifest.sessionID) }
        try database.execute("INSERT INTO chunks(id,session_id,envelope,manifest_hash,state) VALUES(?,?,?,?,'ready')", [.text(envelope.manifest.chunkID.uuidString), .text(envelope.manifest.sessionID.uuidString), .blob(try encode(envelope)), .text(envelope.manifestSHA256)])
    }

    private func cleanup(states: [String], sessionID: UUID? = nil, limit: Int = .max) throws -> [UUID] {
        var cleaned: [UUID] = []
        for state in states {
            let ids = try database.rows("SELECT id FROM chunks WHERE state=? AND (? IS NULL OR session_id=?) LIMIT ?", [.text(state), sessionID.map { .text($0.uuidString) } ?? .null, sessionID.map { .text($0.uuidString) } ?? .null, .integer(Int64(limit))]) { row in
                guard let id = UUID(uuidString: RecordingDatabase.text(row, 0)) else { throw RecordingDatabaseError(code: SQLITE_CORRUPT, message: "Invalid persisted chunk ID") }
                return id
            }
            for id in ids {
                let url = directory("CaptureReady", id)
                if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
                try synchronizeDirectory(url.deletingLastPathComponent())
                if state == "acknowledged" { try database.execute("UPDATE chunks SET state='removed' WHERE id=?", [.text(id.uuidString)]) }
                cleaned.append(id)
            }
        }
        if !cleaned.isEmpty {
            try pruneHistoricalLedger()
        }
        return cleaned
    }

    private func workingOwner(id: UUID) throws -> UUID? {
        let owners = try database.rows("SELECT session_id FROM working_owners WHERE chunk_id=? UNION SELECT session_id FROM chunks WHERE id=?", [.text(id.uuidString), .text(id.uuidString)]) { row in
            guard let id = UUID(uuidString: RecordingDatabase.text(row, 0)) else {
                throw RecordingDatabaseError(code: SQLITE_CORRUPT, message: "Invalid working directory owner")
            }
            return id
        }
        guard owners.count <= 1 else { throw RecordingError.contentConflict(id) }
        return owners.first
    }

    private func workingOwner(at directory: URL) throws -> UUID? {
        guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
        if let owner = try workingOwner(id: id) { return owner }
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { return nil }
        // Version 2 directories have no ownership row. Recover only from a validated manifest.
        do {
            let draft = try decode(ManifestEnvelope.self, Data(contentsOf: directory.appendingPathComponent("draft.json")))
            guard draft.manifest.chunkID == id else { return nil }
            try database.execute("INSERT INTO working_owners(chunk_id,session_id) VALUES(?,?)", [.text(id.uuidString), .text(draft.manifest.sessionID.uuidString)])
            return draft.manifest.sessionID
        } catch is DecodingError { return nil }
        catch is ContractError { return nil }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
    }

    private func quarantineWorking(_ entry: URL) throws {
        let repair = rootURL.appendingPathComponent("CaptureRepair").appendingPathComponent(UUID().uuidString)
        try RecordingFileProtection.createDirectory(at: repair, withIntermediateDirectories: false)
        let destination = repair.appendingPathComponent(entry.lastPathComponent)
        try files.moveItem(at: entry, to: destination)
        RecordingFileProtection.apply(to: destination)
        try synchronizeDirectory(repair)
        try synchronizeDirectory(repair.deletingLastPathComponent())
        try synchronizeDirectory(entry.deletingLastPathComponent())
    }

    private func pruneExpiredRepairEntries(in directory: URL, now: Date, retentionInterval: TimeInterval) throws {
        guard retentionInterval >= 0, now.timeIntervalSince1970.isFinite else { return }
        var rootStat = stat()
        guard lstat(directory.path, &rootStat) == 0, (rootStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return }
        RecordingFileProtection.apply(to: directory)
        for child in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(child.path, &info) == 0 else { continue }
            let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                try pruneExpiredRepairEntries(in: child, now: now, retentionInterval: retentionInterval)
                if try files.contentsOfDirectory(at: child, includingPropertiesForKeys: nil).isEmpty {
                    try files.removeItem(at: child)
                }
            } else if modified > 0, now.timeIntervalSince1970 - modified > retentionInterval {
                try files.removeItem(at: child)
            }
        }
    }

    func isDeleted(_ sessionID: UUID) throws -> Bool {
        try !database.rows("SELECT 1 FROM deletions WHERE session_id=?", [.text(sessionID.uuidString)], read: { _ in true }).isEmpty
    }

    private func directory(_ name: String, _ id: UUID) -> URL { rootURL.appendingPathComponent(name).appendingPathComponent(id.uuidString) }

    private func readEnvelope(at directory: URL) throws -> ManifestEnvelope {
        let stored = try decode(ManifestEnvelope.self, Data(contentsOf: directory.appendingPathComponent("envelope.json")))
        let raw = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard raw == stored.manifestData else { throw RecordingError.contentConflict(stored.manifest.chunkID) }
        return try ManifestEnvelope(manifestData: raw, manifestSHA256: stored.manifestSHA256, protocolVersion: stored.protocolVersion)
    }

    private func validateAudio(_ url: URL, manifest: ChunkManifest) throws {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == manifest.byteCount,
              try ContentHash.sha256(fileAt: url) == manifest.audioSHA256 else { throw RecordingError.invalidAudio(manifest.chunkID) }
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: RecordingFileProtection.atomicWriteOptions)
        RecordingFileProtection.apply(to: url)
        try synchronize(url)
    }

    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() }
        catch { let original = error; do { try handle.close() } catch { throw error }; throw original }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let status = fsync(descriptor)
        let syncError = errno
        let closeStatus = close(descriptor)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO) }
        guard closeStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
