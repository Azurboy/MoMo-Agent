import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Commits a complete chunk delivered over an authenticated direct local transport and returns its durable Receipt.
    public func receiveDirectChunk(
        envelope: ManifestEnvelope,
        audioData: Data,
        receiverDeviceID expectedReceiver: UUID,
        libraryInstanceID expectedLibrary: UUID
    ) throws -> Receipt {
        guard expectedReceiver == receiverDeviceID, expectedLibrary == libraryInstanceID else {
            throw ArchiveReconciliationError.receiverMismatch
        }
        let manifest = envelope.manifest
        try manifest.validate()
        guard manifest.representation == .full,
              manifest.byteCount <= AudioBlock.maximumFileBytes,
              Int64(audioData.count) == manifest.byteCount else {
            throw ContractError.invalidField("direct_chunk")
        }
        guard ContentHash.sha256(audioData) == manifest.audioSHA256 else {
            throw ArchiveError.checksumMismatch
        }
        guard try !sessionIsDeleted(manifest.sessionID) else {
            throw ArchiveError.sessionDeleted(manifest.sessionID)
        }
        if let row = try database.rows(
            "SELECT manifest_hash,audio_hash,relative_path,retention FROM chunks WHERE id=?",
            [.text(manifest.chunkID.uuidString)]
        ).first {
            guard row.string(0) == envelope.manifestSHA256, row.string(1) == manifest.audioSHA256 else {
                throw ArchiveError.conflictingChunk(manifest.chunkID)
            }
            if row.string(3) == "expired" || row.string(3) == "expiry_pending" {
                throw ArchiveError.staleSource
            }
            if row.string(3) == "present",
               try validStoredAudio(rootURL.appendingPathComponent(row.requireString(2)), envelope: envelope) {
                let receipt = try receiptForChunk(manifest.chunkID)
                try database.execute("UPDATE receipt_outbox SET sent=0 WHERE chunk_id=?", [.text(manifest.chunkID.uuidString)])
                return receipt
            }
        }
        let root = inbox.rootURL.deletingLastPathComponent().appendingPathComponent("AudioBlockInbox", isDirectory: true)
        try ArchiveFilePolicy.prepareDirectory(root)
        let tempURL = root.appendingPathComponent(UUID().uuidString + ".direct")
        defer { try? files.removeItem(at: tempURL) }
        try ArchiveFilePolicy.write(audioData, to: tempURL)
        try validateAudio(at: tempURL, manifest: manifest)
        let item = try inbox.preserve(fileURL: tempURL, envelope: envelope)
        let receipt: Receipt
        switch try commitReceivedChunk(item, preverifiedAudioSHA256: manifest.audioSHA256) {
        case .accepted(let value), .restored(let value), .duplicate(let value):
            receipt = value
        case .deleted:
            throw ArchiveError.sessionDeleted(manifest.sessionID)
        case .expired, .missing, .noLongerPending:
            throw ArchiveError.staleSource
        }
        let partialDir = root.appendingPathComponent(manifest.chunkID.uuidString, isDirectory: true)
        if files.fileExists(atPath: partialDir.path) {
            try? files.removeItem(at: partialDir)
        }
        return receipt
    }

    /// Marks a batch of Watch-acknowledged receipts sent in a single SQLite transaction.
    @discardableResult
    public func applyReceipts(_ items: [ReceiptApplied]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        var confirmedChunkIDs: [UUID] = []
        confirmedChunkIDs.reserveCapacity(items.count)
        for applied in items {
            if let expected = try? receiptForChunk(applied.receipt.chunkID), expected == applied.receipt {
                confirmedChunkIDs.append(expected.chunkID)
            }
        }
        guard !confirmedChunkIDs.isEmpty else { return 0 }
        try database.transaction {
            for chunkID in confirmedChunkIDs {
                let idText = SQLValue.text(chunkID.uuidString)
                try database.execute("UPDATE chunks SET receipt_applied=1 WHERE id=?", [idText])
                try database.execute("UPDATE receipt_outbox SET sent=1 WHERE chunk_id=?", [idText])
            }
        }
        return confirmedChunkIDs.count
    }
}
