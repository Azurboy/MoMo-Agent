import Foundation
import MoMoContracts

private final class HandoffState: @unchecked Sendable {
    let lock = NSLock()
    var manifestIndexByRoot: [String: [String: UUID]] = [:]
    var chunkIndexByRoot: [String: [UUID: UUID]] = [:]
    var deduplicatedRoots: Set<String> = []
}

/// Synchronous ownership handoff for temporary WatchConnectivity files.
public struct InboxCustodian: Sendable {
    public let rootURL: URL
    // A new custodian must not recover a handoff another callback is still writing.
    private static let state = HandoffState()
    #if DEBUG && os(macOS)
    private var receiveObserver: (@Sendable (ArchiveReceiveBoundary) -> Void)?

    public init(rootURL: URL, receiveObserver: @escaping @Sendable (ArchiveReceiveBoundary) -> Void) throws {
        try self.init(rootURL: rootURL)
        self.receiveObserver = receiveObserver
    }
    #endif
    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try ArchiveFilePolicy.prepareDirectory(rootURL)
        try Self.state.lock.withLock {
            try recoverInterruptedHandoffs()
            deduplicateAndPrimeIndexesIfNeededLocked()
        }
    }

    public func preserve(fileURL: URL, manifestData: Data, manifestSHA256: String) throws -> InboxItem {
        let envelope = try ManifestEnvelope(manifestData: manifestData, manifestSHA256: manifestSHA256)
        return try preserve(fileURL: fileURL, envelope: envelope)
    }

    public func preserve(fileURL: URL, envelope: ManifestEnvelope) throws -> InboxItem {
        try Self.state.lock.withLock { try preserveLocked(fileURL: fileURL, envelope: envelope) }
    }

    private var standardizedRootKey: String {
        rootURL.standardizedFileURL.path
    }

    private static func isVerifiedPublishedEntry(directory: URL, envelope: ManifestEnvelope, fm: FileManager) -> Bool {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let shaURL = directory.appendingPathComponent("manifest.sha256")
        let audioURL = directory.appendingPathComponent("audio")
        guard (try? fm.attributesOfItem(atPath: manifestURL.path)[.type] as? FileAttributeType) == .typeRegular,
              (try? fm.attributesOfItem(atPath: shaURL.path)[.type] as? FileAttributeType) == .typeRegular,
              let audioAttrs = try? fm.attributesOfItem(atPath: audioURL.path),
              audioAttrs[.type] as? FileAttributeType == .typeRegular,
              (audioAttrs[.size] as? NSNumber)?.int64Value == envelope.manifest.byteCount,
              (try? ContentHash.sha256(fileAt: audioURL)) == envelope.manifest.audioSHA256 else {
            return false
        }
        return true
    }

    private func deduplicateAndPrimeIndexesIfNeededLocked() {
        let rootKey = standardizedRootKey
        let needsDeduplication = !Self.state.deduplicatedRoots.contains(rootKey)
        guard needsDeduplication || Self.state.manifestIndexByRoot[rootKey] == nil || Self.state.chunkIndexByRoot[rootKey] == nil else {
            return
        }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        ) else {
            Self.state.manifestIndexByRoot[rootKey] = [:]
            Self.state.chunkIndexByRoot[rootKey] = [:]
            Self.state.deduplicatedRoots.insert(rootKey)
            return
        }

        struct Candidate {
            let id: UUID
            let directory: URL
            let timestamp: Date
            let manifestSHA: String
        }
        var groupsBySHA: [String: [Candidate]] = [:]
        for directory in urls where directory.pathExtension.isEmpty {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let shaURL = directory.appendingPathComponent("manifest.sha256")
            guard let sha = try? String(contentsOf: shaURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  ContentHash.isValid(sha) else { continue }
            let values = try? directory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let timestamp = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            groupsBySHA[sha, default: []].append(Candidate(id: id, directory: directory, timestamp: timestamp, manifestSHA: sha))
        }

        var builtManifest: [String: UUID] = [:]
        var builtChunk: [UUID: UUID] = [:]

        for (sha, group) in groupsBySHA {
            let ordered = group.sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            guard let first = ordered.first else { continue }
            let firstManifestURL = first.directory.appendingPathComponent("manifest.json")
            let parsedEnvelope = (try? Data(contentsOf: firstManifestURL)).flatMap {
                try? ManifestEnvelope(manifestData: $0, manifestSHA256: sha)
            }
            if needsDeduplication, ordered.count > 1, let envelope = parsedEnvelope {
                // Prefer a canonical <chunkID> directory if present among verified byte-identical copies; otherwise keep earliest FIFO copy.
                var verified: [Candidate] = []
                for candidate in ordered {
                    let candManifestURL = candidate.directory.appendingPathComponent("manifest.json")
                    guard let candData = try? Data(contentsOf: candManifestURL),
                          let candEnvelope = try? ManifestEnvelope(manifestData: candData, manifestSHA256: sha),
                          candEnvelope.manifest.chunkID == envelope.manifest.chunkID,
                          Self.isVerifiedPublishedEntry(directory: candidate.directory, envelope: candEnvelope, fm: fm) else {
                        continue
                    }
                    verified.append(candidate)
                }
                if let keeper = verified.first(where: { $0.id == envelope.manifest.chunkID }) ?? verified.first {
                    for duplicate in verified where duplicate.id != keeper.id {
                        try? fm.removeItem(at: duplicate.directory)
                    }
                    builtManifest[sha] = keeper.id
                    builtChunk[envelope.manifest.chunkID] = keeper.id
                    continue
                }
            }
            builtManifest[sha] = first.id
            if let envelope = parsedEnvelope {
                builtChunk[envelope.manifest.chunkID] = first.id
            }
        }

        Self.state.manifestIndexByRoot[rootKey] = builtManifest
        Self.state.chunkIndexByRoot[rootKey] = builtChunk
        Self.state.deduplicatedRoots.insert(rootKey)
    }

    public func pendingItem(chunkID: UUID) -> InboxItem? {
        Self.state.lock.withLock {
            let rootKey = standardizedRootKey
            deduplicateAndPrimeIndexesIfNeededLocked()
            let candidateID = Self.state.chunkIndexByRoot[rootKey]?[chunkID] ?? chunkID
            let directory = rootURL.appendingPathComponent(candidateID.uuidString, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
                if Self.state.chunkIndexByRoot[rootKey]?[chunkID] == candidateID {
                    Self.state.chunkIndexByRoot[rootKey]?.removeValue(forKey: chunkID)
                }
                return nil
            }
            return InboxItem(id: candidateID, directoryURL: directory)
        }
    }

    public func pendingItem(manifestSHA256: String) -> InboxItem? {
        Self.state.lock.withLock {
            let rootKey = standardizedRootKey
            deduplicateAndPrimeIndexesIfNeededLocked()
            guard let id = Self.state.manifestIndexByRoot[rootKey]?[manifestSHA256] else { return nil }
            let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
                Self.state.manifestIndexByRoot[rootKey]?.removeValue(forKey: manifestSHA256)
                return nil
            }
            return InboxItem(id: id, directoryURL: directory)
        }
    }

    public func noteRemoved(itemID: UUID, manifestSHA256: String? = nil) {
        Self.state.lock.withLock {
            let rootKey = standardizedRootKey
            if let manifestSHA256 {
                if Self.state.manifestIndexByRoot[rootKey]?[manifestSHA256] == itemID {
                    Self.state.manifestIndexByRoot[rootKey]?.removeValue(forKey: manifestSHA256)
                }
            } else if let map = Self.state.manifestIndexByRoot[rootKey] {
                for (sha, existingID) in map where existingID == itemID {
                    Self.state.manifestIndexByRoot[rootKey]?.removeValue(forKey: sha)
                }
            }
            if let chunkMap = Self.state.chunkIndexByRoot[rootKey] {
                for (chunkID, existingID) in chunkMap where existingID == itemID {
                    Self.state.chunkIndexByRoot[rootKey]?.removeValue(forKey: chunkID)
                }
            }
        }
    }

    private func preserveLocked(fileURL: URL, envelope: ManifestEnvelope) throws -> InboxItem {
        guard envelope.manifestData.count <= 16_384 else { throw ArchiveError.invalidInbox }
        let rootKey = standardizedRootKey
        deduplicateAndPrimeIndexesIfNeededLocked()
        let fm = FileManager.default
        let chunkID = envelope.manifest.chunkID
        let existingCandidateID = Self.state.chunkIndexByRoot[rootKey]?[chunkID]
            ?? Self.state.manifestIndexByRoot[rootKey]?[envelope.manifestSHA256]
        if let existingID = existingCandidateID {
            let existingReady = rootURL.appendingPathComponent(existingID.uuidString, isDirectory: true)
            let existingSHAURL = existingReady.appendingPathComponent("manifest.sha256")
            if let existingSHA = try? String(contentsOf: existingSHAURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               existingSHA == envelope.manifestSHA256,
               Self.isVerifiedPublishedEntry(directory: existingReady, envelope: envelope, fm: fm),
               let incomingAttrs = try? fm.attributesOfItem(atPath: fileURL.path),
               incomingAttrs[.type] as? FileAttributeType == .typeRegular,
               (incomingAttrs[.size] as? NSNumber)?.int64Value == envelope.manifest.byteCount,
               (try? ContentHash.sha256(fileAt: fileURL)) == envelope.manifest.audioSHA256 {
                try? fm.removeItem(at: fileURL)
                Self.state.manifestIndexByRoot[rootKey, default: [:]][envelope.manifestSHA256] = existingID
                Self.state.chunkIndexByRoot[rootKey, default: [:]][chunkID] = existingID
                return InboxItem(id: existingID, directoryURL: existingReady)
            } else if !fm.fileExists(atPath: existingReady.path) {
                if Self.state.manifestIndexByRoot[rootKey]?[envelope.manifestSHA256] == existingID {
                    Self.state.manifestIndexByRoot[rootKey]?.removeValue(forKey: envelope.manifestSHA256)
                }
                if Self.state.chunkIndexByRoot[rootKey]?[chunkID] == existingID {
                    Self.state.chunkIndexByRoot[rootKey]?.removeValue(forKey: chunkID)
                }
            }
        }
        let chunkReady = rootURL.appendingPathComponent(chunkID.uuidString, isDirectory: true)
        let canUseDeterministicChunkID = !fm.fileExists(atPath: chunkReady.path)
            && !fm.fileExists(atPath: chunkReady.appendingPathExtension("receiving").path)
            && !fm.fileExists(atPath: chunkReady.appendingPathExtension("incomplete").path)
        let id = canUseDeterministicChunkID ? chunkID : UUID()
        let ready = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let directory = ready.appendingPathExtension("receiving")
        try ArchiveFilePolicy.prepareDirectory(directory)
        // Only the final same-directory rename publishes this handoff to readers.
        try ArchiveFilePolicy.write(envelope.manifestData, to: directory.appendingPathComponent("manifest.json"))
        try ArchiveFilePolicy.write(Data(envelope.manifestSHA256.utf8), to: directory.appendingPathComponent("manifest.sha256"))
        for name in ["manifest.json", "manifest.sha256"] {
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name))
            do { try handle.synchronize(); try handle.close() }
            catch { try handle.close(); throw error }
        }
        #if DEBUG && os(macOS)
        receiveObserver?(.inboxManifestSynced)
        #endif
        let audioURL = directory.appendingPathComponent("audio")
        try fm.moveItem(at: fileURL, to: audioURL)
        try ArchiveFilePolicy.apply(to: audioURL)
        let handle = try FileHandle(forWritingTo: audioURL)
        do { try handle.synchronize(); try handle.close() }
        catch { try handle.close(); throw error }
        try fm.moveItem(at: directory, to: ready)
        if (Self.state.manifestIndexByRoot[rootKey]?.count ?? 0) >= 8_192 {
            Self.state.manifestIndexByRoot[rootKey]?.removeAll(keepingCapacity: true)
            Self.state.chunkIndexByRoot[rootKey]?.removeAll(keepingCapacity: true)
        }
        Self.state.manifestIndexByRoot[rootKey, default: [:]][envelope.manifestSHA256] = id
        Self.state.chunkIndexByRoot[rootKey, default: [:]][chunkID] = id
        return InboxItem(id: id, directoryURL: ready)
    }

    public func pendingItems() throws -> [InboxItem] {
        try storedItems(includingIncomplete: false)
    }

    func storedItems(includingIncomplete: Bool) throws -> [InboxItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: keys)
        var collected: [(timestamp: Date, name: String, item: InboxItem)] = []
        collected.reserveCapacity(entries.count)
        for url in entries {
            let isIncomplete = url.pathExtension == "incomplete"
            if !includingIncomplete && !url.pathExtension.isEmpty { continue }
            let rawName = includingIncomplete && isIncomplete
                ? url.deletingPathExtension().lastPathComponent
                : url.lastPathComponent
            guard let id = UUID(uuidString: rawName) else { continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let timestamp = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            collected.append((timestamp: timestamp, name: url.lastPathComponent, item: InboxItem(id: id, directoryURL: url)))
        }
        collected.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.name < rhs.name
        }
        return collected.map(\.item)
    }

    private func recoverInterruptedHandoffs() throws {
        let files = FileManager.default
        for directory in try files.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            let receiving = directory.pathExtension == "receiving"
            let ready = receiving ? directory.deletingPathExtension() : directory
            guard UUID(uuidString: ready.lastPathComponent) != nil else { continue }
            // Missing inbox audio is valid for a published entry: commit may have moved it already.
            let required = receiving ? ["manifest.json", "manifest.sha256", "audio"] : ["manifest.json", "manifest.sha256"]
            let complete = try required.allSatisfy { name in
                do {
                    return try files.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.type] as? FileAttributeType == .typeRegular
                } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    return false
                }
            }
            if !complete {
                // Retain all bytes without retrying a handoff that cannot be verified. The Watch keeps its unacknowledged original.
                try files.moveItem(at: directory, to: ready.appendingPathExtension("incomplete"))
            } else if receiving {
                try files.moveItem(at: directory, to: ready)
            }
        }
    }
}
