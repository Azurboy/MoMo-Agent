import Foundation
import MoMoContracts

/// Bounded HTTP ranges preserve completed portions across cancellation and process termination.
/// A directory becomes selectable only after every artifact passes its pinned hash.
public actor SpeechModelInstaller {
    public struct Progress: Equatable, Sendable {
        public let receivedBytes: Int64
        public let totalBytes: Int64
        public let validating: Bool
    }

    private let catalog: DownloadableSpeechModel
    private let root: URL
    private let session: URLSession
    private let rangeBytes: Int64
    private var downloading = false
    private let manager = FileManager.default

    private static var fileProtection: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    public init(catalog: DownloadableSpeechModel, directory: URL,
                session: URLSession = .shared, rangeBytes: Int64 = 32 * 1_024 * 1_024) throws {
        try catalog.validate()
        guard rangeBytes > 0, rangeBytes <= 64 * 1_024 * 1_024 else {
            throw SpeechModelInstallationError.invalidCatalog
        }
        self.catalog = catalog
        self.root = directory
        self.session = session
        self.rangeBytes = rangeBytes
    }

    public static func repairInstalledProtection(at root: URL) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return }
        try? manager.setAttributes(fileProtection, ofItemAtPath: root.path)
        guard isDirectory.boolValue,
              let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            return
        }
        for case let item as URL in enumerator {
            try? manager.setAttributes(fileProtection, ofItemAtPath: item.path)
        }
    }

    public static func pruneUnreferencedDownloads(at root: URL, retaining activeCatalogs: [DownloadableSpeechModel]) {
        let manager = FileManager.default
        var kept: Set<String> = []
        for catalog in activeCatalogs {
            guard let revision = try? catalog.revision else { return }
            kept.insert(revision)
            kept.insert(revision + ".partial")
        }
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where !kept.contains(entry.lastPathComponent) {
            try? manager.removeItem(at: entry)
        }
    }

    public static func installedDirectory(for catalog: DownloadableSpeechModel, in root: URL) throws -> URL? {
        let manager = FileManager.default
        let directory = try root.appendingPathComponent(catalog.revision)
        let receipt = directory.appendingPathComponent("complete.json")
        guard manager.fileExists(atPath: receipt.path) else { return nil }
        guard let receiptSize = try fileSize(of: receipt, manager: manager), receiptSize <= 65_536,
              let saved = try? WireJSON.decode(DownloadableSpeechModel.self, from: Data(contentsOf: receipt)) else { return nil }
        guard saved == catalog else { return nil }
        for file in catalog.files {
            guard try fileSize(of: directory.appendingPathComponent(file.path), manager: manager) == file.byteCount else { return nil }
        }
        do { try catalog.validateFiles(at: directory, attempt: SpeechAttempt()) }
        catch SpeechModelInstallationError.fileMismatch { return nil }
        try? manager.setAttributes(fileProtection, ofItemAtPath: root.path)
        repairInstalledProtection(at: directory)
        return directory
    }

    public func installedDirectory() throws -> URL? {
        try Self.installedDirectory(for: catalog, in: root)
    }

    public func install(onProgress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        guard !downloading else { throw SpeechModelInstallationError.alreadyDownloading }
        downloading = true
        defer { downloading = false }
        if let installed = try installedDirectory() { return installed }
        let revision = try catalog.revision
        var staging = root.appendingPathComponent(revision + ".partial", isDirectory: true)
        let destination = root.appendingPathComponent(revision, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: Self.fileProtection)
        try? manager.setAttributes(Self.fileProtection, ofItemAtPath: root.path)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: Self.fileProtection)
        try? manager.setAttributes(Self.fileProtection, ofItemAtPath: staging.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try staging.setResourceValues(values)
        let savedBytes = try catalog.files.reduce(Int64(0)) { sum, file in
            let final = staging.appendingPathComponent(file.path)
            return sum + (try size(of: final) ?? size(of: partialURL(for: final)) ?? 0)
        }
        let required = max(0, catalog.downloadBytes - savedBytes) + rangeBytes + 256 * 1_024 * 1_024
        let attributes = try manager.attributesOfFileSystem(forPath: staging.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < required {
            throw SpeechModelInstallationError.insufficientSpace(requiredBytes: required)
        }
        var completed: Int64 = 0
        for file in catalog.files {
            try Task.checkCancellation()
            let final = staging.appendingPathComponent(file.path)
            let parent = final.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: Self.fileProtection)
            try? manager.setAttributes(Self.fileProtection, ofItemAtPath: parent.path)
            if try size(of: final) == file.byteCount,
               try speechFileHash(final, attempt: nil, recorder: nil, model: true) == file.sha256 {
                try? manager.setAttributes(Self.fileProtection, ofItemAtPath: final.path)
                completed += file.byteCount
                continue
            }
            if manager.fileExists(atPath: final.path) { try manager.removeItem(at: final) }
            let partial = partialURL(for: final)
            var offset = try size(of: partial) ?? 0
            if offset > file.byteCount {
                try manager.removeItem(at: partial)
                offset = 0
            }
            while offset < file.byteCount {
                try Task.checkCancellation()
                let end = min(file.byteCount, offset + rangeBytes) - 1
                var request = URLRequest(url: catalog.baseURL.appendingPathComponent(file.asset),
                    cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let progressOffset = completed
                let requestOffset = offset
                let progress = ModelDownloadProgress { [total = catalog.downloadBytes] bytes, isPartial in
                    onProgress(Progress(receivedBytes: min(total, progressOffset + (isPartial ? requestOffset : 0) + bytes),
                                        totalBytes: total, validating: false))
                }
                let (temporary, response) = try await session.download(for: request, delegate: progress)
                defer { try? manager.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw SpeechModelInstallationError.invalidResponse }
                let count = try size(of: temporary)
                if http.statusCode == 200, count == file.byteCount {
                    // Some asset servers ignore Range. The complete response still needs its hash.
                    if manager.fileExists(atPath: partial.path) { try manager.removeItem(at: partial) }
                    try manager.moveItem(at: temporary, to: partial)
                    try? manager.setAttributes(Self.fileProtection, ofItemAtPath: partial.path)
                    offset = file.byteCount
                } else {
                    guard http.statusCode == 206, count == end - offset + 1,
                          http.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(file.byteCount)" else {
                        throw SpeechModelInstallationError.invalidResponse
                    }
                    try append(temporary, to: partial, expectedOffset: offset)
                    offset = end + 1
                }
                onProgress(Progress(receivedBytes: completed + offset,
                                    totalBytes: catalog.downloadBytes, validating: false))
            }
            onProgress(Progress(receivedBytes: completed + offset,
                                totalBytes: catalog.downloadBytes, validating: true))
            try Task.checkCancellation()
            guard try speechFileHash(partial, attempt: nil, recorder: nil, model: true) == file.sha256 else {
                try manager.removeItem(at: partial)
                throw SpeechModelInstallationError.fileMismatch(file.path)
            }
            try manager.moveItem(at: partial, to: final)
            try? manager.setAttributes(Self.fileProtection, ofItemAtPath: final.path)
            completed += file.byteCount
        }
        try Task.checkCancellation()
        try WireJSON.encode(catalog).write(
            to: staging.appendingPathComponent("complete.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // A stale incomplete installation is app-owned and never used by the recognizer.
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: staging, to: destination)
        // Moving the directory changes stamps. All file hashes were checked above.
        try? catalog.validationStamp(at: destination, attempt: SpeechAttempt()).save(at: destination)
        Self.repairInstalledProtection(at: destination)
        return destination
    }

    public func remove() throws {
        guard !downloading else { throw SpeechModelInstallationError.alreadyDownloading }
        let revision = try catalog.revision
        for name in [revision, revision + ".partial"] {
            let url = root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
    }

    private func partialURL(for url: URL) -> URL { url.appendingPathExtension("download") }

    private static func fileSize(of url: URL, manager: FileManager) throws -> Int64? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize else { throw SpeechModelInstallationError.unsafeFile(url.lastPathComponent) }
        return Int64(count)
    }

    private func size(of url: URL) throws -> Int64? {
        try Self.fileSize(of: url, manager: manager)
    }

    private func append(_ source: URL, to destination: URL, expectedOffset: Int64) throws {
        if !manager.fileExists(atPath: destination.path) {
            guard manager.createFile(atPath: destination.path, contents: nil, attributes: Self.fileProtection) else {
                throw SpeechModelInstallationError.unsafeFile(destination.lastPathComponent)
            }
        }
        try? manager.setAttributes(Self.fileProtection, ofItemAtPath: destination.path)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        guard try output.seekToEnd() == UInt64(expectedOffset) else {
            throw SpeechModelInstallationError.unsafeFile(destination.lastPathComponent)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        do {
            while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
            try output.synchronize()
        } catch {
            try output.truncate(atOffset: UInt64(expectedOffset))
            throw error
        }
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let update: @Sendable (Int64, Bool) -> Void
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    init(update: @escaping @Sendable (Int64, Bool) -> Void) { self.update = update }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let publish = lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(lastUpdate) >= 0.2 else { return false }
            lastUpdate = now
            return true
        }
        if publish { update(totalBytesWritten, (downloadTask.response as? HTTPURLResponse)?.statusCode == 206) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
