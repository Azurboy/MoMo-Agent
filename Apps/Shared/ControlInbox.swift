import Darwin
import Foundation
import MoMoContracts

/// The delegate persists control messages before returning to WatchConnectivity.
final class ControlInbox: Sendable {
    let directory: URL
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try Self.createProtectedDirectory(at: directory, withIntermediateDirectories: true)
    }

    func preserve(_ message: ControlMessage) throws {
        try lock.withLock { try preserveLocked(message) }
    }

    private func preserveLocked(_ message: ControlMessage) throws {
        let data = try WireJSON.encode(message)
        guard data.count <= 16_384 else { throw ControlInboxError.oversizedMessage }
        let id = Self.messageID(for: message)
        let rank = Self.priorityRank(for: message)
        let destination = Self.prefixedFileURL(in: directory, rank: rank, id: id)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else { throw ControlInboxError.conflictingMessage }
            Self.applyProtection(to: destination)
            return
        }
        let legacy = Self.legacyFileURL(in: directory, id: id)
        if fm.fileExists(atPath: legacy.path) {
            guard try Data(contentsOf: legacy) == data else { throw ControlInboxError.conflictingMessage }
            try fm.moveItem(at: legacy, to: destination)
            Self.applyProtection(to: destination)
            return
        }
        for otherRank in 0...3 where otherRank != rank {
            let conflicting = Self.prefixedFileURL(in: directory, rank: otherRank, id: id)
            if fm.fileExists(atPath: conflicting.path) {
                throw ControlInboxError.conflictingMessage
            }
        }
        try data.write(to: destination, options: Self.atomicWriteOptions)
        Self.applyProtection(to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try handle.close()
            throw error
        }
    }

    func pending() throws -> [ControlMessage] {
        let batch = try loadPending()
        guard batch.failures.isEmpty else { throw ControlInboxError.damagedMessage }
        return batch.messages
    }

    func hasPending() throws -> Bool {
        try lock.withLock {
            guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { throw ControlInboxError.damagedMessage }
            for case let path as URL in entries where path.pathExtension == "json" { return true }
            return false
        }
    }

    func loadPending(limit: Int? = nil, after cursor: String? = nil) throws -> ControlInboxBatch {
        guard limit.map({ (1...32).contains($0) }) ?? true else { throw ControlInboxError.invalidLimit }
        return try lock.withLock { try loadPendingLocked(limit: limit, after: cursor) }
    }

    /// A durable scan position prevents an unprocessable old message starving later replies after a cold wake.
    func loadBackgroundPage(limit: Int) throws -> ControlInboxBatch {
        guard (1...32).contains(limit) else { throw ControlInboxError.invalidLimit }
        return try lock.withLock {
            let position = directory.appendingPathComponent(".background-position")
            let hasPosition = FileManager.default.fileExists(atPath: position.path)
            let cursor = hasPosition
                ? String(decoding: try Data(contentsOf: position), as: UTF8.self) : ""
            let batch = try loadPendingLocked(limit: limit, after: cursor.isEmpty ? nil : cursor)
            let next = batch.hasMore ? (batch.scannedThrough ?? "") : ""
            if !hasPosition || next != cursor {
                try Data(next.utf8).write(to: position, options: Self.atomicWriteOptions)
                Self.applyProtection(to: position)
            }
            return batch
        }
    }

    private enum ParsedFilename {
        case prefixed(rank: Int, idString: String)
        case legacy(idString: String)
        case invalid
    }

    private struct PendingSlot {
        let rank: Int
        let idString: String
        let idFilename: String
        let url: URL
        let predecoded: ControlMessage?
    }

    private static func parseFilename(_ filename: String) -> ParsedFilename {
        guard filename.hasSuffix(".json") else { return .invalid }
        let stem = String(filename.dropLast(5))
        let utf8 = Array(stem.utf8)
        if utf8.count == 39,
           utf8[0] == UInt8(ascii: "p"),
           utf8[1] >= UInt8(ascii: "0"), utf8[1] <= UInt8(ascii: "3"),
           utf8[2] == UInt8(ascii: "-") {
            let rank = Int(utf8[1] - UInt8(ascii: "0"))
            let idPart = String(decoding: utf8.dropFirst(3), as: UTF8.self)
            if let uuid = UUID(uuidString: idPart), uuid.uuidString == idPart {
                return .prefixed(rank: rank, idString: idPart)
            }
            return .invalid
        }
        if utf8.count == 36, let uuid = UUID(uuidString: stem), uuid.uuidString == stem {
            return .legacy(idString: stem)
        }
        return .invalid
    }

    private static func readAndValidateMessage(
        at path: URL,
        expectedIDString: String,
        expectedRank: Int?
    ) throws -> ControlMessage {
        var info = stat()
        guard lstat(path.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size <= 16_384 else {
            throw ControlInboxError.oversizedMessage
        }
        let message = try WireJSON.decode(ControlMessage.self, from: Data(contentsOf: path))
        guard messageID(for: message).uuidString == expectedIDString else {
            throw ControlInboxError.conflictingMessage
        }
        if let expectedRank, priorityRank(for: message) != expectedRank {
            throw ControlInboxError.conflictingMessage
        }
        return message
    }

    private func loadPendingLocked(limit: Int?, after cursor: String?) throws -> ControlInboxBatch {
        pruneExpiredQuarantineLocked()
        var slots: [PendingSlot] = []
        var failures: [String] = []
        let fm = FileManager.default
        let paths = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        slots.reserveCapacity(paths.count)
        for path in paths {
            let filename = path.lastPathComponent
            switch Self.parseFilename(filename) {
            case .prefixed(let rank, let idString):
                slots.append(PendingSlot(
                    rank: rank,
                    idString: idString,
                    idFilename: "\(idString).json",
                    url: path,
                    predecoded: nil
                ))
            case .legacy(let idString):
                do {
                    let message = try Self.readAndValidateMessage(at: path, expectedIDString: idString, expectedRank: nil)
                    let rank = Self.priorityRank(for: message)
                    let migrated = directory.appendingPathComponent("p\(rank)-\(idString).json")
                    let resolvedURL: URL
                    if !fm.fileExists(atPath: migrated.path), (try? fm.moveItem(at: path, to: migrated)) != nil {
                        Self.applyProtection(to: migrated)
                        resolvedURL = migrated
                    } else {
                        resolvedURL = path
                    }
                    slots.append(PendingSlot(
                        rank: rank,
                        idString: idString,
                        idFilename: "\(idString).json",
                        url: resolvedURL,
                        predecoded: message
                    ))
                } catch {
                    quarantineCorruptFileLocked(path)
                    failures.append(String(localized: "设备同步消息 \(path.deletingPathExtension().lastPathComponent) 无法读取。"))
                }
            case .invalid:
                quarantineCorruptFileLocked(path)
                failures.append(String(localized: "设备同步消息 \(path.deletingPathExtension().lastPathComponent) 无法读取。"))
            }
        }

        slots.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.idFilename < rhs.idFilename
        }

        let remainingSlots = slots.filter { slot in
            Self.isAfterCursor(entryRank: slot.rank, filename: slot.idFilename, cursor: cursor)
        }

        var selected: [(sortKey: String, message: ControlMessage)] = []
        if let limit { selected.reserveCapacity(limit) }
        var hasMore = false

        for (index, slot) in remainingSlots.enumerated() {
            if let limit, selected.count >= limit {
                hasMore = index < remainingSlots.count
                break
            }
            do {
                let message = try slot.predecoded ?? Self.readAndValidateMessage(
                    at: slot.url,
                    expectedIDString: slot.idString,
                    expectedRank: slot.rank
                )
                selected.append((sortKey: "\(slot.rank):\(slot.idFilename)", message: message))
            } catch {
                quarantineCorruptFileLocked(slot.url)
                failures.append(String(localized: "设备同步消息 \(slot.url.deletingPathExtension().lastPathComponent) 无法读取。"))
            }
        }

        return ControlInboxBatch(
            messages: selected.map(\.message),
            failures: failures,
            scannedThrough: selected.last?.sortKey,
            hasMore: hasMore
        )
    }

    private static func priorityRank(for message: ControlMessage) -> Int {
        switch message {
        case .deleteSession, .deleteApplied:
            return 0
        case .receiverIdentity:
            return 1
        case .reconcileRequest, .reconcileResponse:
            return 2
        case .receipt, .receiptApplied, .epochEnded, .epochInterrupted, .captureMark:
            return 3
        }
    }

    private static func isAfterCursor(entryRank: Int, filename: String, cursor: String?) -> Bool {
        guard let cursor, !cursor.isEmpty else { return true }
        let parsed = parseCursor(cursor)
        if let cursorRank = parsed.rank {
            if entryRank < cursorRank { return true }
            if entryRank == cursorRank { return filename > parsed.filename }
            return true
        }
        if entryRank < 3 { return true }
        return filename > parsed.filename
    }

    private static func parseCursor(_ cursor: String) -> (rank: Int?, filename: String) {
        let bytes = Array(cursor.utf8)
        if bytes.count > 2, bytes[1] == UInt8(ascii: ":"), bytes[0] >= UInt8(ascii: "0"), bytes[0] <= UInt8(ascii: "9") {
            let rank = Int(bytes[0] - UInt8(ascii: "0"))
            let rawName = String(decoding: bytes.dropFirst(2), as: UTF8.self)
            return (rank, normalizeCursorFilename(rawName))
        }
        return (nil, normalizeCursorFilename(cursor))
    }

    private static func normalizeCursorFilename(_ raw: String) -> String {
        if case .prefixed(_, let idString) = parseFilename(raw) {
            return "\(idString).json"
        }
        return raw
    }

    private func quarantineCorruptFileLocked(_ path: URL) {
        let quarantine = directory.appendingPathComponent("Quarantine", isDirectory: true)
        do {
            try Self.createProtectedDirectory(at: quarantine, withIntermediateDirectories: true)
            let preferred = quarantine.appendingPathComponent(path.lastPathComponent)
            let destination = FileManager.default.fileExists(atPath: preferred.path)
                ? quarantine.appendingPathComponent("\(UUID().uuidString)-\(path.lastPathComponent)")
                : preferred
            try FileManager.default.moveItem(at: path, to: destination)
            Self.applyProtection(to: destination)
        } catch {
            // Leave unreadable path untouched if quarantine destination itself cannot be written.
        }
    }

    private func pruneExpiredQuarantineLocked(retentionInterval: TimeInterval = 14 * 86_400) {
        let quarantine = directory.appendingPathComponent("Quarantine", isDirectory: true)
        var rootStat = stat()
        guard lstat(quarantine.path, &rootStat) == 0,
              (rootStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              let children = try? FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil) else {
            return
        }
        let now = Date().timeIntervalSince1970
        for child in children {
            var info = stat()
            guard lstat(child.path, &info) == 0 else { continue }
            let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            if modified > 0, now - modified > retentionInterval {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    func remove(_ message: ControlMessage) throws {
        try lock.withLock {
            let id = Self.messageID(for: message)
            let rank = Self.priorityRank(for: message)
            let fm = FileManager.default
            let preferred = Self.prefixedFileURL(in: directory, rank: rank, id: id)
            let legacy = Self.legacyFileURL(in: directory, id: id)
            let target: URL
            if fm.fileExists(atPath: preferred.path) {
                target = preferred
            } else if fm.fileExists(atPath: legacy.path) {
                target = legacy
            } else {
                return
            }
            guard try Data(contentsOf: target) == WireJSON.encode(message) else { throw ControlInboxError.conflictingMessage }
            try fm.removeItem(at: target)
        }
    }

    private static func messageID(for message: ControlMessage) -> UUID {
        switch message {
        case .receiverIdentity(let value): return value.messageID
        case .epochEnded(let value): return value.messageID
        case .epochInterrupted(let value): return value.messageID
        case .captureMark(let value): return value.messageID
        case .receipt(let value): return value.messageID
        case .receiptApplied(let value): return value.messageID
        case .deleteSession(let value): return value.messageID
        case .deleteApplied(let value): return value.messageID
        case .reconcileRequest(let value): return value.messageID
        case .reconcileResponse(let value): return value.messageID
        }
    }

    private static func prefixedFileURL(in directory: URL, rank: Int, id: UUID) -> URL {
        directory.appendingPathComponent("p\(rank)-\(id.uuidString).json")
    }

    private static func legacyFileURL(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private static var atomicWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    private static func createProtectedDirectory(at url: URL, withIntermediateDirectories intermediates: Bool) throws {
        #if os(iOS) || os(watchOS)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: intermediates,
            attributes: attributes
        )
        applyProtection(to: url)
    }

    private static func applyProtection(to url: URL) {
        #if os(iOS) || os(watchOS)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

struct ControlInboxBatch: Sendable {
    let messages: [ControlMessage]
    let failures: [String]
    var scannedThrough: String? = nil
    var hasMore = false
}

enum ControlInboxError: Error { case conflictingMessage, oversizedMessage, damagedMessage, invalidLimit }
