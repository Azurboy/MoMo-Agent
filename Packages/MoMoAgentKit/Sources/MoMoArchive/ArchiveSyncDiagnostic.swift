import Foundation
import MoMoContracts

public struct ArchiveSyncDiagnostic: Codable, Sendable {
    public struct Day: Codable, Sendable {
        public let sourceDeviceID: String
        public let localDay: String
        public let chunkIDs: [String]
        public let retentionCounts: [String: Int]
        public let receivedBytes: Int64
    }
    public struct Commit: Codable, Sendable {
        public let chunkID: UUID
        public let committedAt: Date
    }
    public let observedAt: Date
    public let libraryInstanceID: UUID
    public let pendingReceiptCount: Int
    public let latestCommit: Commit?
    public let days: [Day]
}

extension ArchiveStore {
    /// One actor-owned snapshot, unlike copying SQLite and its changing WAL separately.
    public func writeSyncDiagnostic(now: Date = Date()) throws {
        guard lastSyncDiagnosticAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastSyncDiagnosticAt = now
        let startedMs = APIPerformanceMonitor.uptimeMilliseconds()
        let rows = try database.rows("""
            SELECT s.source_device,
              CASE
                WHEN c.timebase_hz > 0 AND c.wall_clock_anchor != 0 THEN
                  date(c.wall_clock_anchor + c.timezone_offset + 1.0 * c.start_frame / c.timebase_hz, 'unixepoch')
                ELSE
                  date(julianday(json_extract(CAST(c.manifest AS TEXT),'$.wallClockAnchor')) +
                    (json_extract(CAST(c.manifest AS TEXT),'$.timezoneOffset') +
                     1.0*json_extract(CAST(c.manifest AS TEXT),'$.frames.start') /
                     json_extract(CAST(c.manifest AS TEXT),'$.timebaseHz')) / 86400.0)
              END,
              c.id,c.retention,
              CASE
                WHEN c.byte_count > 0 THEN c.byte_count
                ELSE json_extract(CAST(c.manifest AS TEXT),'$.byteCount')
              END
            FROM chunks c JOIN sessions s ON s.id=c.session_id WHERE s.deleted=0
            ORDER BY s.source_device,2,c.rowid
            """)
        var days: [ArchiveSyncDiagnostic.Day] = []
        var source = "", day = "", ids: [String] = [], retention: [String: Int] = [:], bytes: Int64 = 0
        for row in rows {
            let nextSource = try row.requireString(0), nextDay = try row.requireString(1)
            if nextSource != source || nextDay != day {
                if !ids.isEmpty { days.append(.init(sourceDeviceID: source, localDay: day, chunkIDs: ids, retentionCounts: retention, receivedBytes: bytes)) }
                source = nextSource; day = nextDay; ids = []; retention = [:]; bytes = 0
            }
            ids.append(try row.requireString(2)); retention[try row.requireString(3), default: 0] += 1
            bytes += try row.requireInt(4)
        }
        if !ids.isEmpty { days.append(.init(sourceDeviceID: source, localDay: day, chunkIDs: ids, retentionCounts: retention, receivedBytes: bytes)) }
        let latest = try database.rows("SELECT value FROM metadata WHERE key='latest_receive_commit'").first
            .map { try WireJSON.decode(ArchiveSyncDiagnostic.Commit.self, from: Data($0.requireString(0).utf8)) }
        let snapshot = ArchiveSyncDiagnostic(observedAt: now, libraryInstanceID: libraryInstanceID,
            pendingReceiptCount: try pendingReceiptCount(), latestCommit: latest, days: days)
        try ArchiveFilePolicy.write(WireJSON.encode(snapshot), to: rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/sync-receive-diagnostic.json"))
        performanceMonitor.record(.writeSyncDiagnostic, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: rows.count)
    }

    func recordReceiveCommit(chunkID: UUID) throws {
        let value = ArchiveSyncDiagnostic.Commit(chunkID: chunkID, committedAt: Date())
        try database.execute("INSERT INTO metadata(key,value) VALUES('latest_receive_commit',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [.text(String(decoding: try WireJSON.encode(value), as: UTF8.self))])
    }
}
