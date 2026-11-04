import Darwin
import Foundation
import MoMoContracts

struct VerifiedChunkFileStamps: Sendable, Equatable {
    let audio: FileStatStamp
    let manifest: FileStatStamp
}

struct VerifiedChunkAudioStamp: Equatable {
    let audio: FileStatStamp
    let manifest: FileStatStamp
    let audioSHA256: String
    let manifestSHA256: String
}

@frozen
public struct AcceptedChunkID: Sendable, Equatable {
    public let highBits: UInt64
    public let lowBits: UInt64

    public init(_ uuid: UUID) {
        let u = uuid.uuid
        self.highBits = (UInt64(u.0) << 56) | (UInt64(u.1) << 48) | (UInt64(u.2) << 40) | (UInt64(u.3) << 32)
            | (UInt64(u.4) << 24) | (UInt64(u.5) << 16) | (UInt64(u.6) << 8) | UInt64(u.7)
        self.lowBits = (UInt64(u.8) << 56) | (UInt64(u.9) << 48) | (UInt64(u.10) << 40) | (UInt64(u.11) << 32)
            | (UInt64(u.12) << 24) | (UInt64(u.13) << 16) | (UInt64(u.14) << 8) | UInt64(u.15)
    }

    public var uuidValue: UUID {
        UUID(uuid: (
            UInt8(truncatingIfNeeded: highBits >> 56), UInt8(truncatingIfNeeded: highBits >> 48),
            UInt8(truncatingIfNeeded: highBits >> 40), UInt8(truncatingIfNeeded: highBits >> 32),
            UInt8(truncatingIfNeeded: highBits >> 24), UInt8(truncatingIfNeeded: highBits >> 16),
            UInt8(truncatingIfNeeded: highBits >> 8), UInt8(truncatingIfNeeded: highBits),
            UInt8(truncatingIfNeeded: lowBits >> 56), UInt8(truncatingIfNeeded: lowBits >> 48),
            UInt8(truncatingIfNeeded: lowBits >> 40), UInt8(truncatingIfNeeded: lowBits >> 32),
            UInt8(truncatingIfNeeded: lowBits >> 24), UInt8(truncatingIfNeeded: lowBits >> 16),
            UInt8(truncatingIfNeeded: lowBits >> 8), UInt8(truncatingIfNeeded: lowBits)
        ))
    }
}

@frozen
public enum InboxCommitOutcome: Sendable, Equatable {
    case accepted(AcceptedChunkID)
    case missing
    case ignored
}

public struct ReceiptOutboxEntry: Sendable {
    public let sequence: Int64
    public let receipt: Receipt
}

public struct ReceiptOutboxPage: Sendable {
    public let entries: [ReceiptOutboxEntry]
    public let scannedThrough: Int64
    public let hasMore: Bool
}

public actor ArchiveStore {
    public nonisolated let rootURL: URL
    public nonisolated let inbox: InboxCustodian
    public nonisolated let libraryInstanceID: UUID
    let database: ArchiveDatabase
    let receiverDeviceID: UUID
    let files = FileManager.default
    var audioLeases: [UUID: UUID] = [:]
    var transcriptReadCache: [UUID: (document: TranscriptDocument, cost: Int)] = [:]
    var transcriptReadRecency: [UUID] = []
    var transcriptReadCacheCost = 0
    var transcriptReadDataVersion: Int64 = -1
    var transcriptBlockPrefixCache: [UUID: (version: Int64, generation: Int64, fullSpanCount: Int, blockIDs: [Int64])] = [:]
    var speakerObservationEvidenceCache: [UUID: [UUID: (byteCount: Int, checksum: UInt64, evidence: SpeakerEvidence?)]] = [:]
    var speakerObservationSessionOrder: [UUID] = []
    var lastSyncDiagnosticAt: Date?
    var insightCatalogCache: InsightCatalogCache?
    var hasPendingFileDeletions = false
    var compactedBytesPendingVacuum: Int64 = 0
    var verifiedRecordingFilesCache: [UUID: VerifiedRecordingFilesEntry] = [:]
    var verifiedDirectoryIdentityCache: [UUID: VerifiedDirectoryIdentityEntry] = [:]
    var verifiedManifestProjectionStamps: [UUID: VerifiedManifestProjectionStamp] = [:]
    var verifiedRecordingFilesDataVersion: Int64 = -1
    var verifiedChunkAudioStamps: [UUID: VerifiedChunkAudioStamp] = [:]
    var voiceprintBankCache: VoiceprintBankCache?
    var pendingSpeakerRematchSessionIDs: Set<UUID> = []
    #if DEBUG
    var insightCatalogSessionBuildCount = 0
    var timelineDayBuildCount = 0
    var transcriptReadDecodeCount = 0
    var audioContentValidationCount = 0
    var playbackPreviewStampReadCount = 0
    #endif
    #if DEBUG && os(macOS)
    var receiveBoundaryObserver: (@Sendable (ArchiveReceiveBoundary) -> Void)?
    var planBoundaryObserver: (@Sendable (ArchivePlanBoundary) -> Void)?
    #endif

    public init(rootURL: URL, receiverDeviceID: UUID) throws {
        self.rootURL = rootURL
        self.receiverDeviceID = receiverDeviceID
        let support = rootURL.appendingPathComponent("Library/Application Support/MoMoAgent", isDirectory: true)
        for name in ["Library", "Documents", "tmp"] {
            try ArchiveFilePolicy.prepareDirectory(rootURL.appendingPathComponent(name, isDirectory: true))
        }
        // Only prepare top-level app-owned root directories synchronously at launch;
        // repairFileProtectionIfNeeded() walks historical children off-actor in the background.
        for directory in [support, rootURL.appendingPathComponent("Documents/recordings", isDirectory: true),
                          rootURL.appendingPathComponent("Documents/workspace", isDirectory: true),
                          rootURL.appendingPathComponent("tmp/Exports", isDirectory: true)] {
            try ArchiveFilePolicy.prepareDirectory(directory)
        }
        inbox = try InboxCustodian(rootURL: support.appendingPathComponent("Inbox", isDirectory: true))
        let database = try ArchiveDatabase(url: support.appendingPathComponent("archive.sqlite"))
        self.database = database
        if let row = try database.rows("SELECT value FROM metadata WHERE key = 'library_instance_id'").first {
            guard let value = row.string(0), let id = UUID(uuidString: value) else { throw ArchiveError.invalidInbox }
            libraryInstanceID = id
        } else {
            let id = UUID()
            try database.execute("INSERT INTO metadata(key,value) VALUES('library_instance_id',?)", [.text(id.uuidString)])
            libraryInstanceID = id
        }
        hasPendingFileDeletions = try !database.rows(
            "SELECT 1 FROM deletions WHERE files_cleaned=0 LIMIT 1"
        ).isEmpty || !database.rows(
            "SELECT 1 FROM plans WHERE state IN ('invalidated','deleted') AND files_cleaned=0 LIMIT 1"
        ).isEmpty
        if try !database.rows("SELECT 1 FROM metadata WHERE key='transcript_history_reclaim' LIMIT 1").isEmpty {
            let free = try database.rows("PRAGMA freelist_count").first?.integer(0) ?? 0
            let pageSize = try database.rows("PRAGMA page_size").first?.integer(0) ?? 4096
            compactedBytesPendingVacuum = max(1, free * pageSize)
        }
    }

    public nonisolated func repairFileProtectionIfNeeded() async {
        let root = rootURL
        let support = root.appendingPathComponent("Library/Application Support/MoMoAgent", isDirectory: true)
        let marker = support.appendingPathComponent(".file-protection-repaired-v1")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        let worker = Task.detached(priority: .utility) {
            var skippedPermissionErrors = 0
            let directories = [
                support,
                root.appendingPathComponent("Documents/recordings", isDirectory: true),
                root.appendingPathComponent("Documents/workspace", isDirectory: true),
                root.appendingPathComponent("tmp/Exports", isDirectory: true)
            ]
            for directory in directories {
                try Task.checkCancellation()
                skippedPermissionErrors += try ArchiveFilePolicy.repairTree(directory)
            }
            try Task.checkCancellation()
            if skippedPermissionErrors == 0 {
                try ArchiveFilePolicy.write(Data("1".utf8), to: marker)
            }
        }
        try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func listPendingInboxItems(limit: Int? = nil) throws -> [InboxItem] {
        if let limit { guard limit >= 0 else { throw ArchiveError.invalidQuery } }
        let items = try inbox.pendingItems()
        if let limit { return Array(items.prefix(limit)) }
        return items
    }

    public func processInbox() throws -> [InboxProcessingResult] {
        try inbox.pendingItems().map { item in
            do { return InboxProcessingResult(itemID: item.id, result: .success(try commitReceivedChunk(item))) }
            catch { return InboxProcessingResult(itemID: item.id, result: .failure(error)) }
        }
    }

    public func hasCommittedPresentChunk(id: UUID) -> Bool {
        ((try? database.rows("SELECT 1 FROM chunks WHERE id=? AND retention='present' LIMIT 1", [.text(id.uuidString)]).isEmpty) == false)
    }

    public nonisolated static func quickInboxChunkIdentity(_ item: InboxItem) -> UUID? {
        try? loadEnvelopeFromDisk(item).manifest.chunkID
    }

    private nonisolated static func verifyInboxDirectoryAtPath(
        _ directoryPath: String,
        expectedAudio: FileStatStamp,
        expectedManifest: FileStatStamp,
        expectedHash: FileStatStamp
    ) -> Bool {
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let audioURL = directoryURL.appendingPathComponent("audio")
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let hashURL = directoryURL.appendingPathComponent("manifest.sha256")
        guard let beforeAudio = FileStatStamp.read(at: audioURL),
              let beforeManifest = FileStatStamp.read(at: manifestURL),
              let beforeHash = FileStatStamp.read(at: hashURL),
              beforeAudio == expectedAudio,
              beforeManifest == expectedManifest,
              beforeHash == expectedHash,
              let hash = try? String(contentsOf: hashURL, encoding: .utf8),
              let manifestData = try? Data(contentsOf: manifestURL),
              let envelope = try? ManifestEnvelope(manifestData: manifestData, manifestSHA256: hash) else {
            return false
        }
        let manifest = envelope.manifest
        guard manifest.representation == .full,
              expectedAudio.size == manifest.byteCount,
              (try? ContentHash.sha256(fileAt: audioURL)) == manifest.audioSHA256,
              (try? validateAudio(at: audioURL, manifest: manifest)) != nil,
              let afterAudio = FileStatStamp.read(at: audioURL),
              let afterManifest = FileStatStamp.read(at: manifestURL),
              let afterHash = FileStatStamp.read(at: hashURL),
              afterAudio == expectedAudio,
              afterManifest == expectedManifest,
              afterHash == expectedHash else {
            return false
        }
        return true
    }

    public func commitInboxItemForCoordinator(_ item: InboxItem) async throws -> InboxCommitOutcome {
        let directoryPath = item.directoryURL.path
        let audioURL = item.directoryURL.appendingPathComponent("audio")
        let manifestURL = item.directoryURL.appendingPathComponent("manifest.json")
        let hashURL = item.directoryURL.appendingPathComponent("manifest.sha256")
        let preAudio = FileStatStamp.read(at: audioURL)
        let preManifest = FileStatStamp.read(at: manifestURL)
        let preHash = FileStatStamp.read(at: hashURL)
        let verifiedOffActor: Bool
        if let preAudio, let preManifest, let preHash,
           (preAudio.mode & UInt16(S_IFMT)) == UInt16(S_IFREG),
           (preManifest.mode & UInt16(S_IFMT)) == UInt16(S_IFREG),
           (preHash.mode & UInt16(S_IFMT)) == UInt16(S_IFREG),
           let candidateID = Self.quickInboxChunkIdentity(item),
           !hasCommittedPresentChunk(id: candidateID) {
            verifiedOffActor = await Task.detached(priority: .userInitiated) {
                Self.verifyInboxDirectoryAtPath(
                    directoryPath,
                    expectedAudio: preAudio,
                    expectedManifest: preManifest,
                    expectedHash: preHash
                )
            }.value
        } else {
            verifiedOffActor = false
        }
        let skipVerifiedSourceAudio: Bool
        if verifiedOffActor,
           let preAudio, let preManifest, let preHash,
           FileStatStamp.read(at: audioURL) == preAudio,
           FileStatStamp.read(at: manifestURL) == preManifest,
           FileStatStamp.read(at: hashURL) == preHash {
            skipVerifiedSourceAudio = true
        } else {
            skipVerifiedSourceAudio = false
        }
        let result = try commitReceivedChunk(item, skipVerifiedSourceAudio: skipVerifiedSourceAudio)
        switch result {
        case .missing:
            return .missing
        case .accepted(let receipt):
            return .accepted(AcceptedChunkID(receipt.chunkID))
        case .restored(let receipt):
            return .accepted(AcceptedChunkID(receipt.chunkID))
        case .duplicate, .deleted, .expired, .noLongerPending:
            return .ignored
        }
    }

    public func commitReceivedChunk(
        _ item: InboxItem,
        preverifiedAudioSHA256: String? = nil,
        skipVerifiedSourceAudio: Bool = false
    ) throws -> ReceiveResult {
        guard item.directoryURL.deletingLastPathComponent().standardizedFileURL.path == inbox.rootURL.standardizedFileURL.path,
              item.directoryURL.lastPathComponent == item.id.uuidString else {
            throw ArchiveError.invalidInbox
        }
        do { _ = try files.attributesOfItem(atPath: item.directoryURL.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return .noLongerPending
        }
        let envelope = try Self.loadEnvelopeFromDisk(item)
        let manifest = envelope.manifest
        guard manifest.representation == .full else { throw ArchiveError.invalidInbox }
        if try sessionIsDeleted(manifest.sessionID) { try removeInbox(item); return .deleted }
        try validateCaptureEvents(for: manifest)
        if let existing = try database.rows("SELECT audio_hash,manifest_hash,relative_path,retention,session_id,manifest FROM chunks WHERE id=?", [.text(manifest.chunkID.uuidString)]).first {
            guard existing.string(0) == manifest.audioSHA256, existing.string(1) == envelope.manifestSHA256,
                  existing.string(4) == manifest.sessionID.uuidString, existing.data(5) == envelope.manifestData else {
                throw ArchiveError.conflictingChunk(manifest.chunkID)
            }
            if existing.string(3) == "expired" || existing.string(3) == "expiry_pending" { try removeInbox(item); return .expired }
            if let path = try database.rows("SELECT document_directory FROM sessions WHERE id=?", [.text(manifest.sessionID.uuidString)]).first?.string(0),
               !files.fileExists(atPath: rootURL.appendingPathComponent(path).path) {
                let inspection = try inspectRecordingFiles(sessionID: manifest.sessionID)
                if inspection.issue != nil { try blockProjection(sessionID: manifest.sessionID); return .missing }
            }
            guard let stored = try database.rows("SELECT relative_path FROM chunks WHERE id=?", [.text(manifest.chunkID.uuidString)]).first else { throw ArchiveError.invalidInbox }
            let audio = rootURL.appendingPathComponent(try stored.requireString(0))
            var restored = existing.string(3) != "present"
            if try !validStoredAudio(audio, envelope: envelope) {
                try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE id=?", [.text(manifest.chunkID.uuidString)])
                guard try restoreMissingAudio(from: item, envelope: envelope, target: audio) else { return .missing }
                restored = true
            }
            let receipt = try receiptForChunk(manifest.chunkID)
            try database.transaction {
                if restored {
                    try database.execute("UPDATE chunks SET retention='present' WHERE id=?", [.text(manifest.chunkID.uuidString)])
                    try database.execute("UPDATE analysis_epochs SET has_pending=1 WHERE epoch_id=?", [.text(manifest.epochID.uuidString)])
                    try recordReceiveCommit(chunkID: manifest.chunkID)
                }
                try database.execute("UPDATE receipt_outbox SET sent=0 WHERE chunk_id=? AND sent!=0", [.text(manifest.chunkID.uuidString)])
            }
            if restored { verifiedRecordingFilesCache.removeValue(forKey: manifest.sessionID) }
            try removeInbox(item)
            return restored ? .restored(receipt) : .duplicate(receipt)
        }
        var existingDirectory = try database.rows("SELECT document_directory FROM sessions WHERE id=?", [.text(manifest.sessionID.uuidString)]).first?.string(0)
        if let existingDirectory, !files.fileExists(atPath: rootURL.appendingPathComponent(existingDirectory).path) {
            let inspection = try inspectRecordingFiles(sessionID: manifest.sessionID)
            guard inspection.issue == nil else { try blockProjection(sessionID: manifest.sessionID); throw ArchiveError.projectionConflict }
        }
        existingDirectory = try database.rows("SELECT document_directory FROM sessions WHERE id=?", [.text(manifest.sessionID.uuidString)]).first?.string(0)
        let directory: String
        if let existingDirectory { directory = existingDirectory }
        else { directory = recordingDirectory(manifest: manifest) }
        let relative = directory + "/audio/" + manifest.chunkID.uuidString + audioExtension(manifest.codec)
        let target = rootURL.appendingPathComponent(relative)
        try validateRecordingPath(target)
        if existingDirectory != nil, !files.fileExists(atPath: target.deletingLastPathComponent().path) {
            try blockProjection(sessionID: manifest.sessionID)
            throw ArchiveError.projectionConflict
        }
        try Self.stageVerifiedChunkFiles(
            item: item,
            envelope: envelope,
            target: target,
            skipSourceAudioValidation: (skipVerifiedSourceAudio || preverifiedAudioSHA256 == manifest.audioSHA256)
                && files.fileExists(atPath: item.directoryURL.appendingPathComponent("audio").path)
        )
        recordVerifiedChunkAudioStamp(
            chunkID: manifest.chunkID,
            audioURL: target,
            manifestURL: target.appendingPathExtension("manifest.json"),
            audioSHA256: manifest.audioSHA256,
            manifestSHA256: envelope.manifestSHA256
        )
        #if DEBUG && os(macOS)
        receiveBoundaryObserver?(.originalsStoredBeforeCommit)
        #endif
        let receipt = try Receipt(receiverDeviceID: receiverDeviceID, libraryInstanceID: libraryInstanceID,
                                  chunkID: manifest.chunkID, audioSHA256: manifest.audioSHA256,
                                  manifestSHA256: envelope.manifestSHA256)
        let wallClockSeconds = manifest.wallClockAnchor.timeIntervalSince1970
        let sealedAtSeconds = manifest.sealedAt.timeIntervalSince1970
        try database.transaction {
            if try sessionIsDeleted(manifest.sessionID) { throw ArchiveError.sessionDeleted(manifest.sessionID) }
            try validateCaptureEvents(for: manifest)
            try database.execute("INSERT OR IGNORE INTO sessions(id,source_device,recorded_at,source_kind,document_directory) VALUES(?,?,?,?,?)", [
                .text(manifest.sessionID.uuidString), .text(manifest.sourceDeviceID.uuidString),
                .double(wallClockSeconds), .text(manifest.sourceKind.rawValue), .text(directory)
            ])
            try database.execute("UPDATE sessions SET document_directory=? WHERE id=? AND document_directory IS NULL", [.text(directory), .text(manifest.sessionID.uuidString)])
            if let session = try database.rows("SELECT source_device,source_kind FROM sessions WHERE id=?", [.text(manifest.sessionID.uuidString)]).first {
                guard session.string(0) == manifest.sourceDeviceID.uuidString, session.string(1) == manifest.sourceKind.rawValue else { throw ArchiveError.conflictingChunk(manifest.chunkID) }
            }
            if let epoch = try database.rows("SELECT session_id,timebase FROM epochs WHERE id=?", [.text(manifest.epochID.uuidString)]).first {
                guard epoch.string(0) == manifest.sessionID.uuidString, epoch.double(1) == manifest.timebaseHz else { throw ArchiveError.conflictingEpoch(manifest.epochID) }
            } else {
                try database.execute("""
                    INSERT INTO epochs(id,session_id,timebase,max_received_end_frame,wall_clock_anchor,timezone_offset)
                    VALUES(?,?,?,?,?,?)
                    """, [
                        .text(manifest.epochID.uuidString), .text(manifest.sessionID.uuidString),
                        .double(manifest.timebaseHz), .integer(manifest.frames.end),
                        .double(wallClockSeconds), .integer(Int64(manifest.timezoneOffset))
                    ])
            }
            let overlapping = try database.rows("""
                SELECT 1 FROM chunks WHERE epoch_id=? AND start_frame < ? AND end_frame > ? LIMIT 1
                """, [.text(manifest.epochID.uuidString), .integer(manifest.frames.end), .integer(manifest.frames.start)])
            guard overlapping.isEmpty else {
                throw ArchiveError.conflictingChunk(manifest.chunkID)
            }
            let generation = try sessionGeneration(manifest.sessionID)
            try database.execute("""
                INSERT INTO chunks(
                  id,session_id,epoch_id,manifest,manifest_hash,audio_hash,relative_path,
                  start_frame,end_frame,byte_count,sealed_at,wall_clock_anchor,timezone_offset,timebase_hz
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                    .text(manifest.chunkID.uuidString), .text(manifest.sessionID.uuidString), .text(manifest.epochID.uuidString),
                    .blob(envelope.manifestData), .text(envelope.manifestSHA256), .text(manifest.audioSHA256), .text(relative),
                    .integer(manifest.frames.start), .integer(manifest.frames.end), .integer(manifest.byteCount),
                    .double(sealedAtSeconds), .double(wallClockSeconds),
                    .integer(Int64(manifest.timezoneOffset)), .double(manifest.timebaseHz)
                ])
            try database.execute("""
                UPDATE epochs SET
                  min_chunk_rowid = COALESCE(min_chunk_rowid, (SELECT MIN(rowid) FROM chunks WHERE epoch_id=?)),
                  max_received_end_frame = MAX(max_received_end_frame, ?),
                  wall_clock_anchor = COALESCE(wall_clock_anchor, ?),
                  timezone_offset = COALESCE(timezone_offset, ?)
                WHERE id=?
                """, [
                    .text(manifest.epochID.uuidString), .integer(manifest.frames.end),
                    .double(wallClockSeconds), .integer(Int64(manifest.timezoneOffset)),
                    .text(manifest.epochID.uuidString)
                ])
            try database.execute("INSERT INTO metadata(key,value) VALUES(?, '1') ON CONFLICT(key) DO UPDATE SET value='1'", [.text("recording_projection_pending/" + manifest.sessionID.uuidString)])
            try database.execute("INSERT INTO transcription_jobs(id,chunk_id,generation) VALUES(?,?,?)", [.text(manifest.chunkID.uuidString), .text(manifest.chunkID.uuidString), .integer(generation)])
            try database.execute("UPDATE analysis_epochs SET has_pending=1 WHERE epoch_id=?", [.text(manifest.epochID.uuidString)])
            try database.execute("INSERT INTO receipt_outbox(id,chunk_id,payload) VALUES(?,?,?)", [.text(receipt.receiptID.uuidString), .text(manifest.chunkID.uuidString), .blob(try WireJSON.encode(receipt))])
            try recordReceiveCommit(chunkID: manifest.chunkID)
        }
        verifiedManifestProjectionStamps.removeValue(forKey: manifest.sessionID)
        refreshVerifiedRecordingFilesAfterChunkCommit(sessionID: manifest.sessionID)
        #if DEBUG && os(macOS)
        receiveBoundaryObserver?(.receiveCommitted)
        #endif
        try removeInbox(item)
        return .accepted(receipt)
    }

    /// Explicit retries and retransmissions share the same non-overwriting repair checks.
    public func repairMissingChunk(_ item: InboxItem) throws -> ReceiveResult {
        guard item.directoryURL.standardizedFileURL.path == inbox.rootURL.appendingPathComponent(item.id.uuidString).standardizedFileURL.path else { throw ArchiveError.invalidInbox }
        let envelope = try loadEnvelope(item)
        guard try !database.rows("SELECT id FROM chunks WHERE id=?", [.text(envelope.manifest.chunkID.uuidString)]).isEmpty else { throw ArchiveError.invalidInbox }
        return try commitReceivedChunk(item)
    }

    public func pendingReceiptCount(sourceDeviceID: UUID? = nil) throws -> Int {
        let source = sourceDeviceID.map { SQLValue.text($0.uuidString) } ?? .null
        guard let row = try database.rows("SELECT COUNT(*) FROM receipt_outbox r JOIN chunks c ON c.id=r.chunk_id JOIN sessions s ON s.id=c.session_id WHERE r.sent=0 AND s.deleted=0 AND c.retention='present' AND (? IS NULL OR s.source_device=?)", [source, source]).first else { throw ArchiveError.database(11) }
        return Int(try row.requireInt(0))
    }

    /// Hash only one bounded page and release the archive between files for foreground reads.
    public func pendingReceiptPage(after sequence: Int64 = 0, limit: Int = 32, sourceDeviceID: UUID? = nil) async throws -> ReceiptOutboxPage {
        guard sequence >= 0, (1...32).contains(limit) else { throw ArchiveError.invalidQuery }
        let source = sourceDeviceID.map { SQLValue.text($0.uuidString) } ?? .null
        let rows = try database.rows("SELECT r.storage_sequence,r.payload,c.manifest,c.manifest_hash,c.relative_path FROM receipt_outbox r JOIN chunks c ON c.id=r.chunk_id JOIN sessions s ON s.id=c.session_id WHERE r.storage_sequence>? AND r.sent=0 AND s.deleted=0 AND c.retention='present' AND (? IS NULL OR s.source_device=?) ORDER BY r.storage_sequence LIMIT ?", [.integer(sequence), source, source, .integer(Int64(limit + 1))])
        var entries: [ReceiptOutboxEntry] = []
        var scannedThrough = sequence
        for row in rows.prefix(limit) {
            try Task.checkCancellation()
            let rowSequence = try row.requireInt(0)
            let payloadData = try row.requireData(1)
            let envelope = try ManifestEnvelope(manifestData: row.requireData(2), manifestSHA256: row.requireString(3))
            let audioURL = rootURL.appendingPathComponent(try row.requireString(4))
            let manifestURL = audioURL.appendingPathExtension("manifest.json")
            #if DEBUG
            audioContentValidationCount += 1
            #endif
            let pathsSafe: Bool
            do {
                try validateRecordingPath(audioURL)
                try validateRecordingPath(manifestURL)
                pathsSafe = true
            } catch {
                pathsSafe = false
            }
            let isValid: Bool
            let stampedBeforeCheck = pathsSafe && hasVerifiedChunkAudioStamp(
                chunkID: envelope.manifest.chunkID,
                audioURL: audioURL,
                manifestURL: manifestURL,
                audioSHA256: envelope.manifest.audioSHA256,
                manifestSHA256: envelope.manifestSHA256
            )
            if stampedBeforeCheck {
                isValid = true
            } else if pathsSafe {
                let worker = Task.detached(priority: .userInitiated) {
                    try Self.checkStoredAudioHashes(
                        audioURL: audioURL,
                        manifestURL: manifestURL,
                        audioSHA256: envelope.manifest.audioSHA256,
                        manifestSHA256: envelope.manifestSHA256
                    )
                }
                isValid = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } else {
                isValid = false
            }
            try Task.checkCancellation()
            guard let live = try database.rows(
                "SELECT c.retention, s.deleted, r.sent FROM receipt_outbox r JOIN chunks c ON c.id=r.chunk_id JOIN sessions s ON s.id=c.session_id WHERE r.storage_sequence=?",
                [.integer(rowSequence)]
            ).first else {
                scannedThrough = rowSequence
                continue
            }
            if live.integer(1) == 0, live.string(0) == "present" {
                if isValid {
                    if !stampedBeforeCheck {
                        recordVerifiedChunkAudioStamp(
                            chunkID: envelope.manifest.chunkID,
                            audioURL: audioURL,
                            manifestURL: manifestURL,
                            audioSHA256: envelope.manifest.audioSHA256,
                            manifestSHA256: envelope.manifestSHA256
                        )
                    }
                    if live.integer(2) == 0 {
                        entries.append(ReceiptOutboxEntry(sequence: rowSequence, receipt: try WireJSON.decode(Receipt.self, from: payloadData)))
                    }
                } else {
                    verifiedChunkAudioStamps.removeValue(forKey: envelope.manifest.chunkID)
                    try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE id=? AND retention='present'", [.text(envelope.manifest.chunkID.uuidString)])
                    verifiedRecordingFilesCache.removeValue(forKey: envelope.manifest.sessionID)
                }
            }
            scannedThrough = rowSequence
            await Task.yield()
        }
        return ReceiptOutboxPage(entries: entries, scannedThrough: scannedThrough, hasMore: rows.count > limit)
    }

    public func pendingReceipts() async throws -> [Receipt] {
        var receipts: [Receipt] = [], sequence: Int64 = 0
        while true {
            let page = try await pendingReceiptPage(after: sequence)
            receipts.append(contentsOf: page.entries.map(\.receipt))
            guard page.hasMore else { break }
            sequence = page.scannedThrough
        }
        return receipts
    }

    public func markReceiptSent(receiptID: UUID) throws {
        try database.execute("UPDATE receipt_outbox SET sent=1 WHERE id=?", [.text(receiptID.uuidString)])
    }

    public func sourceDeviceID(for receipt: Receipt) throws -> UUID {
        guard try receiptForChunk(receipt.chunkID) == receipt,
              let row = try database.rows("SELECT s.source_device FROM chunks c JOIN sessions s ON s.id=c.session_id WHERE c.id=?",
                [.text(receipt.chunkID.uuidString)]).first,
              let source = UUID(uuidString: try row.requireString(0)) else { throw ArchiveError.staleSource }
        return source
    }

    public func applyReceipt(_ applied: ReceiptApplied) throws {
        let expected = try receiptForChunk(applied.receipt.chunkID)
        guard expected == applied.receipt else { throw ArchiveError.staleSource }
        try database.transaction {
            try database.execute("UPDATE chunks SET receipt_applied=1 WHERE id=?", [.text(expected.chunkID.uuidString)])
            try database.execute("UPDATE receipt_outbox SET sent=1 WHERE chunk_id=?", [.text(expected.chunkID.uuidString)])
        }
    }

    /// Platform completion may arrive after the peer applied an interactive copy, including across relaunch.
    public func controlWasApplied(_ message: ControlMessage) throws -> Bool {
        switch message {
        case .receipt(let receipt):
            guard let row = try database.rows("SELECT r.payload,c.receipt_applied FROM receipt_outbox r JOIN chunks c ON c.id=r.chunk_id WHERE r.id=?", [.text(receipt.receiptID.uuidString)]).first else { return false }
            return try row.requireInt(1) == 1 && WireJSON.decode(Receipt.self, from: row.requireData(0)) == receipt
        case .deleteSession(let deletion):
            guard let row = try database.rows("SELECT message,acknowledged_device FROM deletions WHERE id=?", [.text(deletion.deletionID.uuidString)]).first else { return false }
            return try row.string(1) != nil && WireJSON.decode(DeleteSession.self, from: row.requireData(0)) == deletion
        default: return false
        }
    }

    public func recoverInterruptedJobs() throws {
        try database.transaction {
            try recoverInterruptedBatches()
            try database.execute("UPDATE transcription_jobs SET state='pending',attempt_id=NULL WHERE state='running'")
            try database.execute("UPDATE analysis_epochs SET attempt_id=NULL")
            try database.execute("UPDATE analysis_windows SET state='pending',attempt_id=NULL WHERE state='running'")
        }
        audioLeases.removeAll()
    }

    public func claimAnalysisJob(configurationHash: String) throws -> AnalysisTicket? {
        guard !configurationHash.isEmpty, configurationHash.utf8.count <= 256 else { throw ArchiveError.invalidQuery }
        return try database.transaction {
            let candidates = try database.rows("SELECT j.id,j.chunk_id,j.generation,c.manifest,c.relative_path FROM transcription_jobs j JOIN chunks c ON c.id=j.chunk_id JOIN sessions s ON s.id=c.session_id WHERE j.state='pending' AND s.deleted=0 AND c.retention='present' ORDER BY s.recorded_at,c.storage_sequence")
            let decoded = try candidates.map { row in (row, try WireJSON.decode(ChunkManifest.self, from: row.requireData(3))) }
            let sorted = decoded.sorted {
                if $0.1.epochID == $1.1.epochID { return $0.1.frames.start < $1.1.frames.start }
                return $0.1.wallClockAnchor < $1.1.wallClockAnchor
            }
            var selected: (SQLRow, ChunkManifest)?
            for candidate in sorted {
                if try batchReservesSession(candidate.1.sessionID) { continue }
                if try predecessorsCompleted(for: candidate.1) { selected = candidate; break }
            }
            guard let (row, manifest) = selected else { return nil }
            let id = try row.requireUUID(0), chunkID = try row.requireUUID(1)
            let attemptID = UUID()
            try database.execute("UPDATE transcription_jobs SET state='running',attempt_id=?,configuration_hash=? WHERE id=?", [.text(attemptID.uuidString), .text(configurationHash), .text(id.uuidString)])
            return AnalysisTicket(jobID: id, attemptID: attemptID, sessionID: manifest.sessionID, chunkID: chunkID,
                                  expectedGeneration: try row.requireInt(2), configurationHash: configurationHash,
                                  manifest: manifest, audioURL: rootURL.appendingPathComponent(try row.requireString(4)))
        }
    }

    public func failAnalysis(ticket: AnalysisTicket, errorCode: String, retryable: Bool) throws {
        guard !errorCode.isEmpty, errorCode.utf8.count <= 128 else { throw ArchiveError.invalidQuery }
        try database.transaction {
            try validateTicket(ticket)
            try database.execute("UPDATE transcription_jobs SET state=?,attempt_id=NULL,error_code=? WHERE id=?", [.text(retryable ? "pending" : "failed"), .text(errorCode), .text(ticket.jobID.uuidString)])
        }
    }

    public func deleteSession(id: UUID) throws -> DeleteSession {
        if let row = try database.rows("SELECT message FROM deletions WHERE session_id=?", [.text(id.uuidString)]).first {
            return try scopedDeletion(WireJSON.decode(DeleteSession.self, from: row.requireData(0)))
        }
        let deletion = try database.transaction {
            try database.execute("INSERT OR IGNORE INTO sessions(id,source_device,recorded_at,source_kind) VALUES(?,?,?,'watch')", [.text(id.uuidString), .text(receiverDeviceID.uuidString), .double(Date().timeIntervalSince1970)])
            let generation = try sessionGeneration(id) + 1
            let deletion = try DeleteSession(sessionID: id, generation: generation,
                receiverDeviceID: receiverDeviceID, libraryInstanceID: libraryInstanceID)
            let hadLearnedVoiceEvidence = try !database.rows(
                "SELECT 1 FROM voice_profile_seeds WHERE session_id=? LIMIT 1", [.text(id.uuidString)]
            ).isEmpty || !database.rows(
                "SELECT 1 FROM speaker_observations WHERE session_id=? AND confirmed_person IS NOT NULL LIMIT 1", [.text(id.uuidString)]
            ).isEmpty || !database.rows(
                "SELECT 1 FROM voice_rejections r JOIN speaker_observations o ON o.span_id=r.span_id WHERE o.session_id=? LIMIT 1", [.text(id.uuidString)]
            ).isEmpty
            let hadSpeakerClusters = try !database.rows(
                "SELECT 1 FROM speaker_clusters WHERE session_id=? AND sample_count>=2 LIMIT 1", [.text(id.uuidString)]
            ).isEmpty
            try database.execute("UPDATE sessions SET generation=?,deleted=1,transcript_preview=NULL WHERE id=?", [.integer(generation), .text(id.uuidString)])
            try database.execute("DELETE FROM voice_profile_seeds WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM speaker_feedback_anchors WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM speaker_observations WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM speaker_clusters WHERE session_id=?", [.text(id.uuidString)])
            pendingSpeakerRematchSessionIDs.remove(id)
            if hadLearnedVoiceEvidence {
                invalidateVoiceprintCache()
                try refreshSpeakerMatches()
            } else if hadSpeakerClusters {
                invalidateTransductiveVoiceprintCache()
            }
            try database.execute("DELETE FROM metadata WHERE key=?", [.text("recording_projection_pending/" + id.uuidString)])
            try invalidateAgentSources(sessionID: id)
            try database.execute("UPDATE transcription_jobs SET state='deleted',attempt_id=NULL WHERE chunk_id IN (SELECT id FROM chunks WHERE session_id=?)", [.text(id.uuidString)])
            try database.execute("DELETE FROM capture_events WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM watch_status WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM analysis_windows WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM analysis_coverage WHERE epoch_id IN (SELECT id FROM epochs WHERE session_id=?)", [.text(id.uuidString)])
            try database.execute("DELETE FROM analysis_epochs WHERE epoch_id IN (SELECT id FROM epochs WHERE session_id=?)", [.text(id.uuidString)])
            try database.execute("DELETE FROM analysis_range_inputs WHERE epoch_id IN (SELECT id FROM epochs WHERE session_id=?)", [.text(id.uuidString)])
            try database.execute("DELETE FROM processing_turns WHERE epoch_id IN (SELECT id FROM epochs WHERE session_id=?)", [.text(id.uuidString)])
            try database.execute("DELETE FROM transcript_search WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM transcript_versions WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("DELETE FROM transcript_blocks WHERE session_id=?", [.text(id.uuidString)])
            try database.execute("UPDATE plans SET state='invalidated',document=X'',files_cleaned=0 WHERE id IN (SELECT plan_id FROM plan_sources WHERE session_id=?)", [.text(id.uuidString)])
            try database.execute("INSERT INTO deletions(id,session_id,message) VALUES(?,?,?)", [.text(deletion.deletionID.uuidString), .text(id.uuidString), .blob(try WireJSON.encode(deletion))])
            return deletion
        }
        verifiedRecordingFilesCache.removeValue(forKey: id)
        verifiedDirectoryIdentityCache.removeValue(forKey: id)
        verifiedManifestProjectionStamps.removeValue(forKey: id)
        if let deletedChunks = try? database.rows("SELECT id FROM chunks WHERE session_id=?", [.text(id.uuidString)]) {
            for row in deletedChunks {
                if let chunkID = try? row.requireUUID(0) {
                    verifiedChunkAudioStamps.removeValue(forKey: chunkID)
                }
            }
        }
        transcriptBlockPrefixCache.removeValue(forKey: id)
        speakerObservationEvidenceCache.removeValue(forKey: id)
        speakerObservationSessionOrder.removeAll { $0 == id }
        hasPendingFileDeletions = true
        try cleanDeletedFiles()
        return deletion
    }

    public func pendingDeletions() throws -> [DeleteSession] {
        try database.rows("SELECT message FROM deletions WHERE acknowledged_device IS NULL").map {
            try scopedDeletion(WireJSON.decode(DeleteSession.self, from: $0.requireData(0)))
        }
    }

    func scopedDeletion(_ deletion: DeleteSession) throws -> DeleteSession {
        let scoped = try deletion.scoped(receiverDeviceID: receiverDeviceID, libraryInstanceID: libraryInstanceID)
        if scoped != deletion {
            // A new message ID avoids a conflict with the legacy command already in a peer's Inbox.
            try database.execute("UPDATE deletions SET message=? WHERE id=?", [.blob(try WireJSON.encode(scoped)), .text(deletion.deletionID.uuidString)])
        }
        return scoped
    }

    public func applyDeletionAcknowledgement(_ applied: DeleteApplied) throws {
        guard let row = try database.rows("SELECT s.source_device,d.acknowledged_device FROM deletions d JOIN sessions s ON s.id=d.session_id WHERE d.id=?", [.text(applied.deletionID.uuidString)]).first else { throw ArchiveError.staleSource }
        let expectedSource = try row.requireUUID(0)
        guard expectedSource == receiverDeviceID || expectedSource == applied.deviceID else { throw ArchiveError.staleSource }
        if let existing = row.string(1), existing != applied.deviceID.uuidString { throw ArchiveError.staleSource }
        try database.execute("UPDATE deletions SET acknowledged_device=? WHERE id=?", [.text(applied.deviceID.uuidString), .text(applied.deletionID.uuidString)])
    }

    func cleanDeletedFilesIfPending() throws {
        guard hasPendingFileDeletions else { return }
        try cleanDeletedFiles()
    }

    public func cleanDeletedFiles() throws {
        var firstFailure: (any Error)?
        do { try cleanDeletedPlanFiles() }
        catch { firstFailure = error }
        let deletionRows = try database.rows("SELECT session_id FROM deletions WHERE files_cleaned=0")
        let storedInboxItems = try deletionRows.isEmpty ? [] : inbox.storedItems(includingIncomplete: true)
        var anyReaderBlocked = false
        for row in deletionRows {
            do {
                let session = try row.requireString(0)
                let chunks = try database.rows("SELECT id,relative_path FROM chunks WHERE session_id=?", [.text(session)])
                let hasReader = try chunks.contains { audioLeases.values.contains(try $0.requireUUID(0)) }
                if hasReader { anyReaderBlocked = true }
                for item in storedInboxItems where files.fileExists(atPath: item.directoryURL.path) {
                    let manifestFile = item.directoryURL.appendingPathComponent("manifest.json")
                    let hashFile = item.directoryURL.appendingPathComponent("manifest.sha256")
                    if files.fileExists(atPath: manifestFile.path), files.fileExists(atPath: hashFile.path) {
                        let envelope = try Self.loadEnvelopeFromDisk(item)
                        if envelope.manifest.sessionID.uuidString == session {
                            let uncommittedDirectory = rootURL.appendingPathComponent(recordingDirectory(manifest: envelope.manifest))
                            try validateRecordingPath(uncommittedDirectory)
                            if !hasReader, files.fileExists(atPath: uncommittedDirectory.path) { try files.removeItem(at: uncommittedDirectory) }
                            try removeInbox(item)
                        }
                    }
                }
                if let path = try database.rows("SELECT document_directory FROM sessions WHERE id=?", [.text(session)]).first?.string(0) {
                    let directory = rootURL.appendingPathComponent(path)
                    try validateRecordingPath(directory)
                    if hasReader {
                        // The native reader can still need the next audio file. Remove readable text immediately.
                        for name in ["transcript.json", "transcript.md", "manifest.json"] {
                            let file = directory.appendingPathComponent(name)
                            if files.fileExists(atPath: file.path) { try files.removeItem(at: file) }
                        }
                    } else if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
                }
                if !hasReader { try database.execute("UPDATE deletions SET files_cleaned=1 WHERE session_id=?", [.text(session)]) }
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        if !anyReaderBlocked { hasPendingFileDeletions = false }
    }

    func predecessorsCompleted(for manifest: ChunkManifest) throws -> Bool {
        if manifest.frames.start == 0 { return true }
        let rows = try database.rows("""
            SELECT c.start_frame, c.end_frame, j.state
            FROM chunks c JOIN transcription_jobs j ON j.chunk_id=c.id
            WHERE c.epoch_id=? AND c.start_frame < ?
            ORDER BY c.start_frame
            """, [.text(manifest.epochID.uuidString), .integer(manifest.frames.start)])
        var contiguousEnd: Int64 = 0
        for row in rows {
            let start = try row.requireInt(0), end = try row.requireInt(1), state = try row.requireString(2)
            guard start == contiguousEnd, state == "complete" else { return false }
            contiguousEnd = end
        }
        return contiguousEnd == manifest.frames.start
    }

    func loadEnvelope(_ item: InboxItem) throws -> ManifestEnvelope {
        try Self.loadEnvelopeFromDisk(item)
    }

    nonisolated static func loadEnvelopeFromDisk(_ item: InboxItem) throws -> ManifestEnvelope {
        let fm = FileManager.default
        guard try fm.attributesOfItem(atPath: item.directoryURL.path)[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.invalidInbox }
        for name in ["manifest.json", "manifest.sha256"] {
            guard try fm.attributesOfItem(atPath: item.directoryURL.appendingPathComponent(name).path)[.type] as? FileAttributeType == .typeRegular else { throw ArchiveError.invalidInbox }
        }
        let hash = try String(contentsOf: item.directoryURL.appendingPathComponent("manifest.sha256"), encoding: .utf8)
        return try ManifestEnvelope(manifestData: Data(contentsOf: item.directoryURL.appendingPathComponent("manifest.json")), manifestSHA256: hash)
    }

    nonisolated static func stageVerifiedChunkFiles(
        item: InboxItem,
        envelope: ManifestEnvelope,
        target: URL,
        skipSourceAudioValidation: Bool
    ) throws {
        let fm = FileManager.default
        let manifest = envelope.manifest
        let temporaryAudio = item.directoryURL.appendingPathComponent("audio")
        let source = fm.fileExists(atPath: temporaryAudio.path) ? temporaryAudio : target
        guard fm.fileExists(atPath: source.path) else { throw ArchiveError.invalidInbox }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(size ?? -1) == manifest.byteCount else { throw ArchiveError.byteCountMismatch }
        if !skipSourceAudioValidation || source != temporaryAudio {
            guard try ContentHash.sha256(fileAt: source) == manifest.audioSHA256 else { throw ArchiveError.checksumMismatch }
            try validateAudio(at: source, manifest: manifest)
        }
        try ArchiveFilePolicy.prepareDirectory(target.deletingLastPathComponent())
        let storedManifest = target.appendingPathExtension("manifest.json")
        if fm.fileExists(atPath: target.path) {
            guard try ContentHash.sha256(fileAt: target) == manifest.audioSHA256 else { throw ArchiveError.conflictingChunk(manifest.chunkID) }
        } else {
            try fm.moveItem(at: source, to: target)
        }
        _ = try ArchiveFilePolicy.apply(to: target)
        try ArchiveFilePolicy.write(envelope.manifestData, to: storedManifest)
    }

    nonisolated static func checkStoredAudioHashes(
        audioURL: URL,
        manifestURL: URL,
        audioSHA256: String,
        manifestSHA256: String
    ) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: audioURL.path), fm.fileExists(atPath: manifestURL.path) else { return false }
        guard try audioURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try manifestURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return false }
        return try ContentHash.sha256(fileAt: audioURL) == audioSHA256
            && ContentHash.sha256(fileAt: manifestURL) == manifestSHA256
    }
    func sessionIsDeleted(_ id: UUID) throws -> Bool {
        try database.rows("SELECT deleted FROM sessions WHERE id=?", [.text(id.uuidString)]).first?.integer(0) == 1
    }
    func sessionGeneration(_ id: UUID) throws -> Int64 {
        guard let row = try database.rows("SELECT generation FROM sessions WHERE id=?", [.text(id.uuidString)]).first else { throw ArchiveError.missingRecording(id) }
        return try row.requireInt(0)
    }
    func validateTicket(_ ticket: AnalysisTicket) throws {
        guard !((try sessionIsDeleted(ticket.sessionID))), try !batchReservesSession(ticket.sessionID),
              try sessionGeneration(ticket.sessionID) == ticket.expectedGeneration,
              let row = try database.rows("SELECT state,attempt_id,configuration_hash,c.audio_hash FROM transcription_jobs j JOIN chunks c ON c.id=j.chunk_id WHERE j.id=?", [.text(ticket.jobID.uuidString)]).first,
              row.string(0) == "running", row.string(1) == ticket.attemptID.uuidString,
              row.string(2) == ticket.configurationHash, row.string(3) == ticket.manifest.audioSHA256 else { throw ArchiveError.staleAttempt }
    }
    func receiptForChunk(_ id: UUID) throws -> Receipt {
        guard let row = try database.rows("SELECT payload FROM receipt_outbox WHERE chunk_id=?", [.text(id.uuidString)]).first else { throw ArchiveError.invalidInbox }
        return try WireJSON.decode(Receipt.self, from: row.requireData(0))
    }
    nonisolated static func readVerifiedChunkStamps(audioURL: URL, manifestURL: URL) -> VerifiedChunkFileStamps? {
        guard let audio = FileStatStamp.read(at: audioURL),
              let manifest = FileStatStamp.read(at: manifestURL),
              (audio.mode & UInt16(S_IFMT)) == UInt16(S_IFREG),
              (manifest.mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else {
            return nil
        }
        return VerifiedChunkFileStamps(audio: audio, manifest: manifest)
    }

    func hasVerifiedChunkAudioStamp(
        chunkID: UUID,
        audioURL: URL,
        manifestURL: URL,
        audioSHA256: String,
        manifestSHA256: String
    ) -> Bool {
        guard let cached = verifiedChunkAudioStamps[chunkID],
              cached.audioSHA256 == audioSHA256,
              cached.manifestSHA256 == manifestSHA256,
              let live = Self.readVerifiedChunkStamps(audioURL: audioURL, manifestURL: manifestURL),
              cached.audio == live.audio,
              cached.manifest == live.manifest else {
            return false
        }
        return true
    }

    func recordVerifiedChunkAudioStamp(
        chunkID: UUID,
        audioURL: URL,
        manifestURL: URL,
        audioSHA256: String,
        manifestSHA256: String
    ) {
        guard let live = Self.readVerifiedChunkStamps(audioURL: audioURL, manifestURL: manifestURL) else { return }
        if verifiedChunkAudioStamps.count >= 4_096, verifiedChunkAudioStamps[chunkID] == nil {
            verifiedChunkAudioStamps.removeAll(keepingCapacity: true)
        }
        verifiedChunkAudioStamps[chunkID] = VerifiedChunkAudioStamp(
            audio: live.audio,
            manifest: live.manifest,
            audioSHA256: audioSHA256,
            manifestSHA256: manifestSHA256
        )
    }

    func validStoredAudio(_ url: URL, envelope: ManifestEnvelope) throws -> Bool {
        #if DEBUG
        audioContentValidationCount += 1
        #endif
        let manifestURL = url.appendingPathExtension("manifest.json")
        try validateRecordingPath(url)
        try validateRecordingPath(manifestURL)
        let chunkID = envelope.manifest.chunkID
        if hasVerifiedChunkAudioStamp(
            chunkID: chunkID,
            audioURL: url,
            manifestURL: manifestURL,
            audioSHA256: envelope.manifest.audioSHA256,
            manifestSHA256: envelope.manifestSHA256
        ) {
            return true
        }
        let valid = try Self.checkStoredAudioHashes(
            audioURL: url,
            manifestURL: manifestURL,
            audioSHA256: envelope.manifest.audioSHA256,
            manifestSHA256: envelope.manifestSHA256
        )
        if valid {
            recordVerifiedChunkAudioStamp(
                chunkID: chunkID,
                audioURL: url,
                manifestURL: manifestURL,
                audioSHA256: envelope.manifest.audioSHA256,
                manifestSHA256: envelope.manifestSHA256
            )
        } else {
            verifiedChunkAudioStamps.removeValue(forKey: chunkID)
        }
        return valid
    }
    func removeInbox(_ item: InboxItem) throws {
        try files.removeItem(at: item.directoryURL)
        inbox.noteRemoved(itemID: item.id)
    }
    func recordingDirectory(manifest: ChunkManifest) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: manifest.timezoneOffset)
        formatter.dateFormat = "yyyy-MM-dd"
        return "Documents/recordings/\(formatter.string(from: manifest.wallClockAnchor))/\(manifest.sessionID.uuidString)"
    }
    func audioExtension(_ codec: AudioCodec) -> String { codec == .aac ? ".m4a" : ".wav" }
}

extension SQLRow {
    func requireString(_ i: Int) throws -> String { guard let value = string(i) else { throw ArchiveError.database(11) }; return value }
    func requireData(_ i: Int) throws -> Data { guard let value = data(i) else { throw ArchiveError.database(11) }; return value }
    func requireInt(_ i: Int) throws -> Int64 { guard let value = integer(i) else { throw ArchiveError.database(11) }; return value }
    func requireUUID(_ i: Int) throws -> UUID { guard let id = UUID(uuidString: try requireString(i)) else { throw ArchiveError.database(11) }; return id }
}
