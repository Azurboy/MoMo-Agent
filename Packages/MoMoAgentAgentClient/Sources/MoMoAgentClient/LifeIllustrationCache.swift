import CryptoKit
import Foundation

actor LifeIllustrationCache {
    struct Snapshot: Codable, Sendable {
        var cursor = "0"
        var items: [String: LifeIllustration] = [:]
    }

    let directory: URL
    private var verified: [String: FileStamp] = [:]

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date?
    }

    init(directory: URL) { self.directory = directory }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load() throws -> Snapshot {
        let file = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Snapshot() }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        for item in snapshot.items.values { try item.validate() }
        return snapshot
    }

    func verifiedURL(sha256: String) throws -> URL? {
        guard LifeIllustration.isSHA256(sha256) else { throw LifeIllustrationError.assetIntegrity }
        let url = directory.appendingPathComponent(sha256 + ".png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = try fileStamp(url)
        if verified[sha256] == stamp { return url }
        guard Self.digest(try Data(contentsOf: url)) == sha256 else {
            try FileManager.default.removeItem(at: url)
            verified.removeValue(forKey: sha256)
            return nil
        }
        verified[sha256] = stamp
        return url
    }

    func saveAsset(_ data: Data, sha256: String) throws -> URL {
        guard LifeIllustration.isSHA256(sha256), Self.digest(data) == sha256 else { throw LifeIllustrationError.assetIntegrity }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(sha256 + ".png")
        try data.write(to: url, options: .atomic)
        verified[sha256] = try fileStamp(url)
        return url
    }

    func apply(_ changes: [LifeIllustrationChange], cursor: String? = nil) throws -> Snapshot {
        var snapshot = try load()
        for change in changes {
            switch change {
            case .illustration(let item):
                try item.validate()
                snapshot.items[item.id] = item
            case .tombstone(let item):
                guard item.deleted, !item.id.isEmpty else { throw LifeIllustrationError.invalidManifest }
                snapshot.items.removeValue(forKey: item.id)
            }
        }
        if let cursor { snapshot.cursor = cursor }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        let referenced = Set(snapshot.items.values.flatMap { [$0.assetSha256, $0.thumbnailSha256] })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "png" && !referenced.contains(url.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at: url)
            verified.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
        }
        return snapshot
    }

    private func fileStamp(_ url: URL) throws -> FileStamp {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize else { throw LifeIllustrationError.assetIntegrity }
        return FileStamp(size: size, modified: values.contentModificationDate)
    }
}
