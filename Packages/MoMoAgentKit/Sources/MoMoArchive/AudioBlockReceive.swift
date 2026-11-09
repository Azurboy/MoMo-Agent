import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Serialized with normal ingestion and deletion. No file or database handle crosses an await.
    public func receiveAudioBlock(_ block: AudioBlock) throws -> AudioBlockReply {
        try block.validate()
        guard block.receiverDeviceID == receiverDeviceID, block.libraryInstanceID == libraryInstanceID else {
            throw ArchiveReconciliationError.receiverMismatch
        }
        let envelope = block.envelope, manifest = envelope.manifest
        let root = inbox.rootURL.deletingLastPathComponent().appendingPathComponent("AudioBlockInbox", isDirectory: true)
        let directory = root.appendingPathComponent(manifest.chunkID.uuidString, isDirectory: true)
        guard try !sessionIsDeleted(manifest.sessionID) else { throw ArchiveError.sessionDeleted(manifest.sessionID) }
        if let row = try database.rows("SELECT manifest_hash,audio_hash,relative_path,retention FROM chunks WHERE id=?",
                                       [.text(manifest.chunkID.uuidString)]).first {
            guard row.string(0) == envelope.manifestSHA256, row.string(1) == manifest.audioSHA256 else {
                throw ArchiveError.conflictingChunk(manifest.chunkID)
            }
            if row.string(3) == "expired" || row.string(3) == "expiry_pending" { throw ArchiveError.staleSource }
            if row.string(3) == "present",
               try validStoredAudio(rootURL.appendingPathComponent(row.requireString(2)), envelope: envelope) {
                let receipt = try receiptForChunk(manifest.chunkID)
                try database.execute("UPDATE receipt_outbox SET sent=0 WHERE chunk_id=?", [.text(manifest.chunkID.uuidString)])
                if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
                return AudioBlockReply(block: block, nextOffset: manifest.byteCount, receipt: receipt)
            }
        }

        try ArchiveFilePolicy.prepareDirectory(root)
        if files.fileExists(atPath: directory.path) {
            try ArchiveFilePolicy.apply(to: directory)
            // Initialization may have been interrupted before the first manifest was atomically written.
            if !files.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
                try files.removeItem(at: directory)
            }
        }
        if !files.fileExists(atPath: directory.path) {
            // Eviction loses only a resumable copy; the Watch still owns the unconfirmed original.
            let partials = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
                .sorted { lhs, rhs in
                    // Keep recently advancing copies, not the four lexicographically largest UUIDs.
                    let left = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                    let right = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                    return left == right ? lhs.lastPathComponent < rhs.lastPathComponent : left < right
                }
            if partials.count >= 4 {
                for partial in partials.prefix(partials.count - 3) { try files.removeItem(at: partial) }
            }
            try ArchiveFilePolicy.prepareDirectory(directory)
            try ArchiveFilePolicy.write(envelope.manifestData, to: directory.appendingPathComponent("manifest.json"))
            try ArchiveFilePolicy.write(Data(envelope.manifestSHA256.utf8), to: directory.appendingPathComponent("manifest.sha256"))
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try ArchiveFilePolicy.apply(to: manifestURL)
        guard try Data(contentsOf: manifestURL) == envelope.manifestData else {
            throw ArchiveError.conflictingChunk(manifest.chunkID)
        }
        let audio = directory.appendingPathComponent("audio")
        let offsetURL = directory.appendingPathComponent("offset")
        var offset: Int64 = 0
        if files.fileExists(atPath: offsetURL.path) {
            try ArchiveFilePolicy.apply(to: offsetURL)
            guard let saved = Int64(try String(contentsOf: offsetURL, encoding: .utf8)),
                  saved >= 0, saved <= manifest.byteCount else { throw ArchiveError.invalidInbox }
            offset = saved
        }
        if !files.fileExists(atPath: audio.path) {
            try ArchiveFilePolicy.write(Data(), to: audio)
            offset = 0 // A crash can leave a completed handoff in the normal Inbox.
        }
        try ArchiveFilePolicy.apply(to: audio)
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size else { throw ArchiveError.invalidInbox }
        if Int64(size) < offset { offset = 0 }
        let handle = try FileHandle(forWritingTo: audio)
        do {
            // Ignore a write which did not reach its durable offset checkpoint before termination.
            try handle.truncate(atOffset: UInt64(offset))
            if block.offset == offset, !block.payload.isEmpty {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: block.payload)
                offset += Int64(block.payload.count)
            }
            if offset == manifest.byteCount {
                try handle.synchronize()
            }
            try handle.close()
        } catch { try handle.close(); throw error }
        if files.fileExists(atPath: offsetURL.path) {
            try Data(String(offset).utf8).write(to: offsetURL)
        } else {
            try ArchiveFilePolicy.write(Data(String(offset).utf8), to: offsetURL)
        }
        if offset == manifest.byteCount {
            let checkpoint = try FileHandle(forWritingTo: offsetURL)
            do { try checkpoint.synchronize(); try checkpoint.close() }
            catch { try checkpoint.close(); throw error }
        }
        guard offset == manifest.byteCount else { return AudioBlockReply(block: block, nextOffset: offset) }
        guard try ContentHash.sha256(fileAt: audio) == manifest.audioSHA256 else {
            try files.removeItem(at: directory)
            throw ArchiveError.checksumMismatch
        }
        do {
            try validateAudio(at: audio, manifest: manifest)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        let item = try inbox.preserve(fileURL: audio, envelope: envelope)
        let receipt: Receipt
        switch try commitReceivedChunk(item, preverifiedAudioSHA256: manifest.audioSHA256) {
        case .accepted(let value), .restored(let value), .duplicate(let value): receipt = value
        case .deleted: throw ArchiveError.sessionDeleted(manifest.sessionID)
        case .expired, .missing, .noLongerPending: throw ArchiveError.staleSource
        }
        try files.removeItem(at: directory)
        return AudioBlockReply(block: block, nextOffset: offset, receipt: receipt)
    }
}
