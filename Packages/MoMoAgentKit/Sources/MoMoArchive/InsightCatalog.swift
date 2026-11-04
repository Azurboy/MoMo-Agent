import Foundation
import MoMoContracts

public struct InsightTimelineCatalog: Sendable {
    public let revision: String
    public let days: [TimelineDay]
    public let dayRevisions: [String: String]
}

struct InsightCatalogCache {
    let revision: UInt64
    let externalVersion: Int64
    let dayStartHour: Int
    let sessions: [UUID: [TimelineDay: String]]
    let catalog: InsightTimelineCatalog
}

extension ArchiveStore {
    /// Rebuild changed recordings only; receipt/status writes do not invalidate this cache.
    public func insightTimelineCatalog() throws -> InsightTimelineCatalog {
        let external = try database.rows("PRAGMA data_version").first?.requireInt(0) ?? 0
        let revision = database.insightRevision
        let startHour = TimelineDay.currentStartHour
        if !database.isInTransaction, let cache = insightCatalogCache,
           cache.externalVersion == external, cache.revision == revision,
           cache.dayStartHour == startHour { return cache.catalog }
        var sessions: [UUID: [TimelineDay: String]]
        let changed: Set<UUID>
        if !database.isInTransaction, let cache = insightCatalogCache,
           cache.externalVersion == external, cache.dayStartHour == startHour,
           let updates = try database.changedInsightSessions() {
            sessions = cache.sessions
            changed = updates
        } else {
            sessions = [:]
            changed = Set(try database.rows("SELECT id FROM sessions WHERE deleted=0").map { try $0.requireUUID(0) })
        }
        for id in changed {
            sessions[id] = try insightDayRevisions(sessionID: id, startHour: startHour)
            #if DEBUG
            insightCatalogSessionBuildCount += 1
            #endif
        }
        var parts: [TimelineDay: [String]] = [:]
        for (session, days) in sessions {
            for (day, hash) in days { parts[day, default: []].append("\(session.uuidString)/\(hash)") }
        }
        let days = parts.keys.sorted(by: >)
        let hashes = parts.mapValues { ContentHash.sha256(Data($0.sorted().joined(separator: "\n").utf8)) }
        let dayRevisions = Dictionary(uniqueKeysWithValues: hashes.map { ($0.key.id, $0.value) })
        let identity = days.map { "\($0.id)/\(dayRevisions[$0.id]!)" }.joined(separator: "\n")
        let catalog = InsightTimelineCatalog(revision: ContentHash.sha256(Data(identity.utf8)), days: days,
                                             dayRevisions: dayRevisions)
        if !database.isInTransaction {
            insightCatalogCache = .init(revision: revision, externalVersion: external, dayStartHour: startHour,
                                        sessions: sessions, catalog: catalog)
            database.acknowledgeInsightChanges()
        }
        return catalog
    }

    private func insightDayRevisions(sessionID: UUID, startHour: Int) throws -> [TimelineDay: String]? {
        guard let session = try database.rows("SELECT generation,projection_blocked FROM sessions WHERE id=? AND deleted=0", [.text(sessionID.uuidString)]).first else { return nil }
        let scope = "\(try session.requireInt(0))/\(try session.requireInt(1))"
        var parts: [TimelineDay: [String]] = [:]
        var chunks: [UUID: ChunkManifest] = [:]
        var epochs: [UUID: ChunkManifest] = [:]
        func include(_ value: String, manifest: ChunkManifest, frames: FrameRange, clip: Bool = false) {
            let base = manifest.wallClockAnchor.addingTimeInterval(Double(manifest.timezoneOffset))
            let start = base.addingTimeInterval(Double(frames.start) / manifest.timebaseHz)
            let end = base.addingTimeInterval(Double(frames.end) / manifest.timebaseHz - 0.001)
            var day = TimelineDay(start, calendar: TimelineDay.calendar, startHour: startHour)
            let last = TimelineDay(max(start, end), calendar: TimelineDay.calendar, startHour: startHour)
            while day <= last {
                if clip {
                    // Catalog identity uses nearest frames so Date rounding cannot dirty yesterday.
                    let lower = max(frames.start, Int64((day.startDate(calendar: TimelineDay.calendar, startHour: startHour).timeIntervalSince(base) * manifest.timebaseHz).rounded()))
                    let upper = min(frames.end, Int64((day.adding(days: 1).startDate(calendar: TimelineDay.calendar, startHour: startHour).timeIntervalSince(base) * manifest.timebaseHz).rounded()))
                    parts[day, default: []].append("\(value)/\(lower)/\(upper)")
                } else { parts[day, default: []].append(value) }
                day = day.adding(days: 1)
            }
        }
        for row in try database.rows("SELECT manifest,manifest_hash,retention FROM chunks WHERE session_id=? ORDER BY id", [.text(sessionID.uuidString)]) {
            let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(0))
            chunks[manifest.chunkID] = manifest
            epochs[manifest.epochID] = manifest
            include("chunk/\(try row.requireString(1))/\(try row.requireString(2))", manifest: manifest, frames: manifest.frames)
        }
        if let document = try currentTranscriptOrNil(sessionID: sessionID) {
            for span in document.spans {
                let hash = ContentHash.sha256(try WireJSON.encode(span))
                for source in span.sourceRanges {
                    guard let manifest = chunks[source.chunkID] else { throw ArchiveError.invalidTranscript }
                    include("span/\(hash)", manifest: manifest, frames: source.frames)
                }
            }
        }
        let coverage = try database.rows("SELECT epoch_id,start_frame,end_frame,kind FROM analysis_coverage WHERE epoch_id IN (SELECT id FROM epochs WHERE session_id=?)", [.text(sessionID.uuidString)])
        for (epoch, manifest) in epochs {
            for kind in ["analyzed", "no_speech"] {
                let ranges = try coverage.filter { $0.string(0) == epoch.uuidString && $0.string(3) == kind }.map {
                    try FrameRange(start: $0.requireInt(1), count: $0.requireInt(2) - $0.requireInt(1))
                }
                for range in try CoverageRanges.union(ranges) {
                    include("coverage/\(epoch.uuidString)/\(kind)", manifest: manifest, frames: range, clip: true)
                }
            }
        }
        for row in try database.rows("SELECT id,descriptor,state FROM analysis_windows WHERE session_id=? ORDER BY id", [.text(sessionID.uuidString)]) {
            let window = try WireJSON.decode(ArchiveAnalysisWindow.self, from: row.requireData(1))
            guard let manifest = epochs[window.epochID] else { continue }
            let state = row.string(2) == "complete" ? "complete" : "pending"
            include("window/\(try row.requireString(0))/\(state)", manifest: manifest, frames: window.coreFrames)
        }
        for row in try database.rows("SELECT epoch_id,payload,kind FROM capture_events WHERE session_id=? ORDER BY id", [.text(sessionID.uuidString)]) {
            guard let manifest = epochs[try row.requireUUID(0)] else { continue }
            let data = try row.requireData(1)
            let frame: Int64
            switch try row.requireString(2) {
            case "mark": frame = try WireJSON.decode(CaptureMark.self, from: data).sourceFrame
            case "epoch_ended": frame = max(0, try WireJSON.decode(CaptureEpochEnded.self, from: data).endFrame - 1)
            case "epoch_interrupted": frame = max(0, try WireJSON.decode(CaptureEpochInterrupted.self, from: data).lastObservedFrame - 1)
            default: throw ArchiveError.invalidTranscript
            }
            include("event/\(ContentHash.sha256(data))", manifest: manifest, frames: try FrameRange(start: frame, count: 1))
        }
        for row in try database.rows("SELECT c.epoch_id,c.end_frame FROM epoch_closures c JOIN epochs e ON e.id=c.epoch_id WHERE e.session_id=?", [.text(sessionID.uuidString)]) {
            guard let manifest = epochs[try row.requireUUID(0)] else { continue }
            let end = try row.requireInt(1)
            include("closure/\(end)", manifest: manifest, frames: try FrameRange(start: max(0, end - 1), count: 1))
        }
        return parts.mapValues { ContentHash.sha256(Data(([scope] + $0.sorted()).joined(separator: "\n").utf8)) }
    }
}
