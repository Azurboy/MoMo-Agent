import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Snapshot only locally retained, unanalyzed frames. New receipts never extend this batch.
    func unpreparedBatchRanges(fingerprint: String, now: Date = Date()) throws -> [(sessionID: UUID, epochID: UUID, timebaseHz: Double, frames: FrameRange)] {
        var sources: [(sessionID: UUID, epochID: UUID, timebaseHz: Double, frames: FrameRange)] = []
        for row in try database.rows("""
            SELECT e.id,e.session_id,e.timebase,s.generation FROM epochs e
            JOIN sessions s ON s.id=e.session_id
            WHERE s.deleted=0 AND s.projection_blocked=0
            ORDER BY s.recorded_at,e.rowid
            """) {
            let epochID = try row.requireUUID(0)
            guard try !batchReservesAnalysis(epochID: epochID) else { continue }
            guard let rate = row.double(2), rate.isFinite, rate > 0 else { throw ArchiveError.invalidTranscript }
            let generation = try row.requireInt(3)
            let pending = try pendingAnalysisRanges(epochID: epochID, fingerprint: fingerprint, retainedOnly: true)
            guard !pending.isEmpty else { continue }
            let onDisk = try onDiskRetainedRanges(epochID: epochID)
            let blockedFailures = try database.rows("""
                SELECT start_frame,end_frame FROM processing_failures
                WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage='analysis'
                  AND error_code='audio_unavailable'
                """, [.text(epochID.uuidString), .integer(generation), .text(fingerprint)]).map {
                    try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0))
                }
            let eligible = try CoverageRanges.subtract(CoverageRanges.intersection(pending, onDisk), blockedFailures)
            for frames in eligible {
                sources.append((sessionID: try row.requireUUID(1), epochID: epochID, timebaseHz: rate, frames: frames))
            }
        }
        return sources
    }

    // A paused batch owns preparation too; another scheduler must not analyze beyond its snapshot.
    func batchReservesAnalysis(epochID: UUID, except batchID: UUID? = nil) throws -> Bool {
        try database.rows("""
            SELECT DISTINCT r.batch_id FROM transcription_batch_ranges r
            JOIN transcription_batches b ON b.id=r.batch_id
            WHERE r.epoch_id=? AND r.kind='unprepared' AND b.state!='completed'
            """, [.text(epochID.uuidString)]).contains { try $0.requireUUID(0) != batchID }
    }

    /// Registers windows produced after admission, preserving the original progress denominator.
    func registerPreparedBatchWindows(execution: TranscriptionBatchExecution, fingerprint: String) throws {
        try validateBatchExecution(execution, fingerprint: fingerprint)
        try registerOverlappingBatchWindows(batchID: execution.batchID, fingerprint: fingerprint)
    }

    /// Counts runnable pending windows currently belonging to an active batch execution.
    public func pendingBatchWindowCount(execution: TranscriptionBatchExecution,
                                        configurationFingerprint: String) throws -> Int {
        try registerPreparedBatchWindows(execution: execution, fingerprint: configurationFingerprint)
        let count = try database.rows("""
            SELECT COUNT(*) FROM transcription_batch_windows m
            JOIN analysis_windows w ON w.id=m.window_id
            JOIN sessions s ON s.id=w.session_id
            WHERE m.batch_id=? AND w.configuration_hash=? AND w.state='pending'
              AND s.deleted=0 AND s.projection_blocked=0 AND w.generation=s.generation
            """, [.text(execution.batchID.uuidString), .text(configurationFingerprint)]).first?.integer(0) ?? 0
        return Int(max(0, count))
    }

    func registerOverlappingBatchWindows(batchID: UUID, fingerprint: String) throws {
        for row in try database.rows("""
            SELECT w.descriptor,w.state FROM analysis_windows w JOIN sessions s ON s.id=w.session_id
            WHERE w.configuration_hash=? AND w.generation=s.generation AND s.deleted=0 AND w.state IN ('pending','running','complete')
              AND NOT EXISTS(SELECT 1 FROM transcription_batch_windows m WHERE m.batch_id=? AND m.window_id=w.id)
              AND EXISTS(SELECT 1 FROM transcription_batch_ranges r WHERE r.batch_id=? AND r.epoch_id=w.epoch_id AND r.kind='unprepared')
            """, [.text(fingerprint), .text(batchID.uuidString), .text(batchID.uuidString)]) {
            let window = try WireJSON.decode(ArchiveAnalysisWindow.self, from: row.requireData(0))
            let ranges = try batchPreparationRanges(id: batchID, epochID: window.epochID)
            guard try !CoverageRanges.intersection([window.coreFrames], ranges).isEmpty else { continue }
            if row.string(1) != "complete", try batchReserves(window, except: batchID) { continue }
            try database.execute("INSERT OR IGNORE INTO transcription_batch_windows(batch_id,window_id,session_id,epoch_id,start_frame,end_frame) VALUES(?,?,?,?,?,?)", [
                .text(batchID.uuidString), .text(window.id), .text(window.sessionID.uuidString),
                .text(window.epochID.uuidString), .integer(window.coreFrames.start), .integer(window.coreFrames.end)
            ])
        }
    }

    public func claimTranscriptionBatchAnalysis(execution: TranscriptionBatchExecution,
                                                configurationFingerprint: String,
                                                maxStepSeconds: Double = 120,
                                                focusedDay: TimelineDay? = nil,
                                                now: Date = Date(),
                                                calendar: Calendar = .current) throws -> EpochAnalysisTicket? {
        try validateBatchExecution(execution, fingerprint: configurationFingerprint)
        let rows = try database.rows("""
            SELECT DISTINCT r.epoch_id,r.session_id,s.generation FROM transcription_batch_ranges r
            JOIN sessions s ON s.id=r.session_id WHERE r.batch_id=? AND r.kind='unprepared' AND s.deleted=0
            ORDER BY s.recorded_at,r.epoch_id
            """, [.text(execution.batchID.uuidString)])
        var slices: [(order: Int, tier: Int, epochID: UUID, sessionID: UUID, generation: Int64, range: FrameRange)] = []
        let policy = focusedDay != nil ? ProcessingDatePolicy(now: now, calendar: calendar) : nil
        for (order, row) in rows.enumerated() {
            let epochID = try row.requireUUID(0)
            let sessionID = try row.requireUUID(1)
            let generation = try row.requireInt(2)
            let pending = try CoverageRanges.subtract(batchPreparationRanges(id: execution.batchID, epochID: epochID),
                analyzedRanges(epochID: epochID, fingerprint: configurationFingerprint))
            guard !pending.isEmpty else { continue }
            let manifest: ChunkManifest?
            if policy != nil, let data = try database.rows("""
                SELECT c.manifest FROM epochs e
                JOIN chunks c ON c.rowid=COALESCE(e.min_chunk_rowid, (SELECT rowid FROM chunks WHERE epoch_id=e.id ORDER BY start_frame LIMIT 1))
                WHERE e.id=?
                """, [.text(epochID.uuidString)]).first?.data(0) {
                manifest = try? WireJSON.decode(ChunkManifest.self, from: data)
            } else {
                manifest = nil
            }
            for range in pending {
                let tier: Int
                if let policy, let manifest {
                    if let focusedDay, policy.overlapsDay(focusedDay, frames: range, manifest: manifest) {
                        tier = policy.isHotLive(range, manifest: manifest) ? 0 : 1
                    } else {
                        tier = policy.freshnessTier(range, manifest: manifest, focusedDay: focusedDay)
                    }
                } else {
                    tier = 0
                }
                slices.append((order: order, tier: tier, epochID: epochID, sessionID: sessionID, generation: generation, range: range))
            }
        }
        if focusedDay != nil {
            slices.sort {
                if $0.tier != $1.tier { return $0.tier < $1.tier }
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.range.start < $1.range.start
            }
        }
        for slice in slices {
            let epochID = slice.epochID
            let sessionID = slice.sessionID
            let generation = slice.generation
            let range = slice.range
            if let ticket = try claimEpochAnalysis(configurationFingerprint: configurationFingerprint,
                sessionID: sessionID, expectedGeneration: generation,
                finalizeAvailablePrefixBefore: .distantFuture, isolateLocalFailures: true,
                selectedEpochID: epochID, processingRange: range,
                batchExecution: execution, maxStepSeconds: maxStepSeconds, now: now) {
                return ticket
            }
            let stillPending = try CoverageRanges.subtract(batchPreparationRanges(id: execution.batchID, epochID: epochID),
                analyzedRanges(epochID: epochID, fingerprint: configurationFingerprint))
            if try !CoverageRanges.intersection([range], stillPending).isEmpty {
                let activeAttempt = try database.rows(
                    "SELECT attempt_id FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?",
                    [.text(epochID.uuidString), .text(configurationFingerprint)]
                ).first?.string(0)
                if activeAttempt == nil {
                    try deferBatchSlice(batchID: execution.batchID, sessionID: sessionID, epochID: epochID, frames: range)
                }
            }
        }
        return nil
    }

    private func onDiskRetainedRanges(epochID: UUID) throws -> [FrameRange] {
        var ranges: [FrameRange] = []
        for row in try database.rows("""
            SELECT start_frame, end_frame - start_frame, relative_path
            FROM chunks WHERE epoch_id=? AND retention='present'
            ORDER BY start_frame
            """, [.text(epochID.uuidString)]) {
            let relPath = try row.requireString(2)
            guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(relPath).path) else { continue }
            ranges.append(try FrameRange(start: row.requireInt(0), count: row.requireInt(1)))
        }
        return try CoverageRanges.union(ranges)
    }

    func batchPreparationRanges(id: UUID, epochID: UUID) throws -> [FrameRange] {
        try database.rows("SELECT start_frame,end_frame FROM transcription_batch_ranges WHERE batch_id=? AND epoch_id=? AND kind='unprepared'",
            [.text(id.uuidString), .text(epochID.uuidString)]).map {
                try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0))
            }
    }
}
