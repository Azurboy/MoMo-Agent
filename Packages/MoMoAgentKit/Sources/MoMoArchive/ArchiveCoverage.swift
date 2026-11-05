import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Received, unfinished audio only: the still-open capture tail is not a processing dependency.
    public func pendingTranscriptionIntervals(sessionID: UUID, configurationFingerprint: String?) throws -> [DateInterval] {
        let coverage = try recordingCoverage(sessionID: sessionID, configurationFingerprint: configurationFingerprint)
        let rows = try database.rows("SELECT id,wall_clock_anchor FROM epochs WHERE session_id=?", [.text(sessionID.uuidString)])
        var intervals: [DateInterval] = []
        for epoch in coverage.epochs {
            guard let rate = epoch.timebaseHz, let row = rows.first(where: { $0.string(0) == epoch.epochID.uuidString }),
                  let anchor = row.double(1), rate > 0, rate.isFinite, anchor.isFinite else { continue }
            // Without a current model configuration, received processing coverage is unknown.
            let pending = configurationFingerprint == nil ? epoch.received : epoch.pending
            intervals += pending.map {
                DateInterval(start: Date(timeIntervalSince1970: anchor + Double($0.start) / rate), duration: Double($0.count) / rate)
            }
        }
        return intervals.sorted { $0.start < $1.start }
    }

    /// All processing ranges belong to the requested configuration; old model coverage is not combined.
    public func recordingCoverage(sessionID: UUID, configurationFingerprint: String?) throws -> RecordingCoverage {
        if let configurationFingerprint, !ContentHash.isValid(configurationFingerprint) { throw ArchiveError.invalidQuery }
        guard try !sessionIsDeleted(sessionID) else { throw ArchiveError.sessionDeleted(sessionID) }
        let key: [SQLValue] = [.text(sessionID.uuidString)]
        let epochRows = try database.rows("SELECT id,timebase FROM epochs WHERE session_id=? ORDER BY rowid", key)
        let marks = try marks(sessionID: sessionID)
        var epochIDs = try epochRows.map { try $0.requireUUID(0) }
        for row in try database.rows("SELECT epoch_id FROM capture_events WHERE session_id=? GROUP BY epoch_id ORDER BY MIN(rowid)", key) {
            let id = try row.requireUUID(0)
            if !epochIDs.contains(id) { epochIDs.append(id) }
        }
        let session = try database.rows("SELECT projection_blocked FROM sessions WHERE id=?", key).first
        guard !epochIDs.isEmpty || session != nil else {
            throw ArchiveError.missingRecording(sessionID)
        }
        let document: TranscriptDocument?
        if session?.integer(0) == 1 { document = nil }
        else { document = try currentTranscriptOrNil(sessionID: sessionID) }
        var epochs: [EpochCoverage] = []
        for epochID in epochIDs {
            let rate = epochRows.first { $0.string(0) == epochID.uuidString }?.double(1)
            if let rate, !rate.isFinite || rate <= 0 { throw ArchiveError.database(11) }
            epochs.append(try epochCoverage(epochID: epochID, rate: rate,
                fingerprint: configurationFingerprint, marks: marks.filter { $0.epochID == epochID }, document: document))
        }
        let status = try watchStatus(sessionID: sessionID)
        let captured: TimeInterval?
        if let status, case .watch(let watch) = status.snapshot.payload { captured = watch.capturedDuration }
        else { captured = nil }
        return RecordingCoverage(sessionID: sessionID, configurationFingerprint: configurationFingerprint,
            epochs: epochs, watchCapturedDuration: captured, watchStatusUpdatedAt: status?.snapshot.sampledAt)
    }

    private func epochCoverage(epochID: UUID, rate: Double?, fingerprint: String?,
                               marks: [CaptureMark], document: TranscriptDocument?) throws -> EpochCoverage {
        let key: [SQLValue] = [.text(epochID.uuidString)]
        let configurationKey = key + [fingerprint.map(SQLValue.text) ?? .null]
        let rows = try database.rows("SELECT c.manifest,c.retention,j.state,j.configuration_hash,j.error_code FROM chunks c LEFT JOIN transcription_jobs j ON j.chunk_id=c.id WHERE c.epoch_id=? ORDER BY c.rowid", key)
        let manifests = try rows.map { try WireJSON.decode(ChunkManifest.self, from: $0.requireData(0)) }
        let received = try CoverageRanges.union(manifests.map(\.frames))
        let closure = try database.rows("SELECT end_frame FROM epoch_closures WHERE epoch_id=?", key).first?.requireInt(0)
        let bounds = try interruptedEpochBounds(epochID: epochID)
        let observed = max(max(received.last?.end ?? 0, marks.map(\.sourceFrame).max() ?? 0), bounds?.observed ?? 0)
        if let closure, closure < observed { throw ArchiveError.conflictingEpoch(epochID) }
        let through = closure ?? observed
        let known = through > 0 ? [try FrameRange(start: 0, count: through)] : []
        let coverage = fingerprint == nil ? [] : try database.rows("SELECT start_frame,end_frame,kind FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=?", configurationKey)
        func ranges(kind: String) throws -> [FrameRange] {
            try coverage.filter { $0.string(2) == kind }.map {
                try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0))
            }
        }
        let analyzed = try CoverageRanges.intersection(ranges(kind: "analyzed"), received)
        let noSpeech = try CoverageRanges.intersection(ranges(kind: "no_speech"), analyzed)
        // Committed analysis remains valid after a text-only revision advances the session generation.
        let windowRows = fingerprint == nil ? [] : try database.rows("SELECT core_start,core_end FROM analysis_windows WHERE epoch_id=? AND configuration_hash=? AND state='complete'", configurationKey)
        let windows = try windowRows.map {
            try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0))
        }
        let hasEpochAnalysis = fingerprint == nil ? false : try !database.rows("SELECT 1 FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?", configurationKey).isEmpty
        let legacyCompleted = fingerprint == nil || hasEpochAnalysis ? [] : rows.indices.filter {
            rows[$0].string(2) == "complete" && rows[$0].string(3) == fingerprint
        }.map { manifests[$0].frames }
        let transcribed = try CoverageRanges.intersection(windows + legacyCompleted, received)
        let processed = try CoverageRanges.union(transcribed + noSpeech)
        var failures = rows.indices.filter { fingerprint != nil && rows[$0].string(2) == "failed" && rows[$0].string(3) == fingerprint }.map {
            CoverageFailure(chunkID: manifests[$0].chunkID, frames: manifests[$0].frames, errorCode: rows[$0].string(4))
        }
        for row in try database.rows("SELECT f.start_frame,f.end_frame,f.error_code FROM processing_failures f JOIN sessions s ON s.id=f.session_id WHERE f.epoch_id=? AND f.configuration_hash=? AND f.generation=s.generation AND s.deleted=0", configurationKey) {
            let range = try FrameRange(start: row.requireInt(0), count: row.requireInt(1) - row.requireInt(0))
            guard let manifest = manifests.first(where: { $0.frames.start < range.end && $0.frames.end > range.start }) else { throw ArchiveError.invalidTranscript }
            failures.append(CoverageFailure(chunkID: manifest.chunkID, frames: range, errorCode: row.string(2)))
        }
        let failed = try CoverageRanges.subtract(failures.map(\.frames), processed)
        let unavailable = try CoverageRanges.union(rows.indices.filter { rows[$0].string(1) != "present" }.map { manifests[$0].frames })
        let locations = marks.sorted {
            $0.sourceFrame == $1.sourceFrame ? $0.markID.uuidString < $1.markID.uuidString : $0.sourceFrame < $1.sourceFrame
        }.map { mark in
            let chunks = manifests.filter { $0.frames.contains(mark.sourceFrame) }.map(\.chunkID)
            let location: MarkCoverageLocation = !chunks.isEmpty ? .received
                : closure == mark.sourceFrame ? .epochEnd
                : mark.sourceFrame < through ? .notReceived : .unknownTail
            let sources = document.map { document in
                document.spans.filter { span in
                    span.sourceRanges.contains { chunks.contains($0.chunkID) && $0.frames.contains(mark.sourceFrame) }
                }.map { document.source(for: $0) }
            } ?? []
            return ArchiveMarkCoverage(mark: mark, location: location, chunkIDs: chunks, sources: sources)
        }
        return EpochCoverage(epochID: epochID, timebaseHz: rate, closedAtFrame: closure, observedThroughFrame: through,
            received: received, analyzed: analyzed, transcribed: transcribed, noSpeech: noSpeech, processed: processed,
            notReceived: try CoverageRanges.subtract(known, received),
            pendingAnalysis: fingerprint == nil ? [] : try CoverageRanges.subtract(received, analyzed),
            pendingTranscription: fingerprint == nil ? [] : try CoverageRanges.subtract(analyzed, processed),
            pending: fingerprint == nil ? [] : try CoverageRanges.subtract(received, processed + failed + unavailable),
            failed: failed, unavailableAudio: unavailable, failures: failures, marks: locations)
    }
}

private extension FrameRange {
    func contains(_ frame: Int64) -> Bool { start <= frame && frame < end }
}

enum CoverageRanges {
    static func union(_ ranges: [FrameRange]) throws -> [FrameRange] {
        var result: [FrameRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = try FrameRange(start: last.start, count: max(last.end, range.end) - last.start)
            } else { result.append(range) }
        }
        return result
    }

    static func intersection(_ lhs: [FrameRange], _ rhs: [FrameRange]) throws -> [FrameRange] {
        let left = try union(lhs), right = try union(rhs)
        var result: [FrameRange] = [], i = 0, j = 0
        while i < left.count && j < right.count {
            let start = max(left[i].start, right[j].start), end = min(left[i].end, right[j].end)
            if end > start { result.append(try FrameRange(start: start, count: end - start)) }
            if left[i].end < right[j].end { i += 1 } else { j += 1 }
        }
        return result
    }

    static func subtract(_ ranges: [FrameRange], _ removed: [FrameRange]) throws -> [FrameRange] {
        let removed = try union(removed)
        var result: [FrameRange] = []
        for range in try union(ranges) {
            var cursor = range.start
            for cut in removed where cut.end > cursor && cut.start < range.end {
                if cut.start > cursor { result.append(try FrameRange(start: cursor, count: cut.start - cursor)) }
                cursor = max(cursor, cut.end)
            }
            if cursor < range.end { result.append(try FrameRange(start: cursor, count: range.end - cursor)) }
        }
        return result
    }
}
