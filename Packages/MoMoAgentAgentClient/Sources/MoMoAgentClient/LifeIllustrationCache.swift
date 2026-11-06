import CryptoKit
import Darwin
import Foundation

actor LifeIllustrationCache {
    struct FileStamp: Codable, Equatable, Sendable {
        let size: Int64
        let inode: UInt64
        let mtimeSec: Int
        let mtimeNsec: Int
    }

    struct Snapshot: Codable, Sendable {
        var cursor = "0"
        var items: [String: LifeIllustration] = [:]
        var lastVerifiedSettings: LifeIllustrationSettings?
        var verifiedStamps: [String: FileStamp] = [:]

        init(
            cursor: String = "0",
            items: [String: LifeIllustration] = [:],
            lastVerifiedSettings: LifeIllustrationSettings? = nil,
            verifiedStamps: [String: FileStamp] = [:]
        ) {
            self.cursor = cursor
            self.items = items
            self.lastVerifiedSettings = lastVerifiedSettings
            self.verifiedStamps = verifiedStamps
        }

        private enum CodingKeys: String, CodingKey {
            case cursor, items, lastVerifiedSettings, verifiedStamps
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cursor = try container.decodeIfPresent(String.self, forKey: .cursor) ?? "0"
            items = try container.decodeIfPresent([String: LifeIllustration].self, forKey: .items) ?? [:]
            lastVerifiedSettings = try container.decodeIfPresent(LifeIllustrationSettings.self, forKey: .lastVerifiedSettings)
            verifiedStamps = try container.decodeIfPresent([String: FileStamp].self, forKey: .verifiedStamps) ?? [:]
        }
    }

    let directory: URL
    private var verified: [String: FileStamp] = [:]

    init(directory: URL) { self.directory = directory }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load() throws -> Snapshot {
        let file = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Snapshot() }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        for item in snapshot.items.values { try item.validate() }
        verified.merge(snapshot.verifiedStamps) { current, _ in current }
        return snapshot
    }

    func verifiedURL(sha256: String) throws -> URL? {
        guard LifeIllustration.isSHA256(sha256) else { throw LifeIllustrationError.assetIntegrity }
        let url = directory.appendingPathComponent(sha256 + ".png")
        guard let stamp = fileStamp(url) else { return nil }
        if verified[sha256] == stamp { return url }
        guard Self.digest(try Data(contentsOf: url)) == sha256 else {
            try? FileManager.default.removeItem(at: url)
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
        guard let stamp = fileStamp(url) else { throw LifeIllustrationError.assetIntegrity }
        verified[sha256] = stamp
        return url
    }

    func saveSettings(_ settings: LifeIllustrationSettings?) throws {
        var snapshot = (try? load()) ?? Snapshot()
        guard snapshot.lastVerifiedSettings != settings || snapshot.verifiedStamps != verified else { return }
        snapshot.lastVerifiedSettings = settings
        snapshot.verifiedStamps = verified
        try writeManifest(snapshot)
    }

    func existingAssetURLs(for items: [LifeIllustration]) throws -> [String: URL] {
        let previousVerified = verified
        var urls: [String: URL] = [:]
        for item in items {
            for hash in Set([item.thumbnailSha256, item.assetSha256]) where urls[hash] == nil {
                if let url = try verifiedURL(sha256: hash) {
                    urls[hash] = url
                }
            }
        }
        if verified != previousVerified, var snapshot = try? load(), snapshot.verifiedStamps != verified {
            snapshot.verifiedStamps = verified
            try? writeManifest(snapshot)
        }
        return urls
    }

    func apply(_ changes: [LifeIllustrationChange], cursor: String? = nil, keepHashes: Set<String> = []) throws -> Snapshot {
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
        let referenced = Set(snapshot.items.values.flatMap { [$0.assetSha256, $0.thumbnailSha256] }).union(keepHashes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "png" && !referenced.contains(url.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at: url)
            verified.removeValue(forKey: url.deletingPathExtension().lastPathComponent)
        }
        verified = verified.filter { referenced.contains($0.key) }
        snapshot.verifiedStamps = verified
        try writeManifest(snapshot)
        return snapshot
    }

    private func writeManifest(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func fileStamp(_ url: URL) -> FileStamp? {
        var info = Darwin.stat()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return stat(path, &info) == 0
        }
        guard ok, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(
            size: info.st_size,
            inode: info.st_ino,
            mtimeSec: info.st_mtimespec.tv_sec,
            mtimeNsec: info.st_mtimespec.tv_nsec
        )
    }
}
