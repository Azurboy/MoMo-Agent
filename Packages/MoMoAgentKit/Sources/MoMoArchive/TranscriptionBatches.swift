import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Freezes available work. Optional raw ranges use received-snapshot boundaries, never a capture end.
    public func freezeTranscriptionBatch(id: UUID = UUID(), configurationFingerprint: String,
                                         includingUnpreparedAudio: Bool = false,
                                         now: Date = Date()) throws -> TranscriptionBatch? {
        guard ContentHash.isValid(configurationFingerprint) else { throw ArchiveError.invalidQuery }
        return try database.transaction {
            if try !database.rows("SELECT 1 FROM transcription_batches WHERE id=?", [.text(id.uuidString)]).isEmpty {
                let existing = try transcriptionBatch(id: id)
                guard existing.configurationFingerprint == configurationFingerprint else { throw TranscriptionBatchError.configurationMismatch }
                return existing
            }
            let rows = try database.rows("""
                SELECT w.descriptor,w.generation FROM analysis_windows w
                JOIN sessions s ON s.id=w.session_id
                WHERE w.state='pending' AND w.configuration_hash=? AND w.generation=s.generation
                  AND s.deleted=0 AND s.projection_blocked=0
                  AND NOT EXISTS (
                      SELECT 1 FROM transcription_jobs j JOIN chunks c ON c.id=j.chunk_id
                      WHERE c.session_id=s.id AND j.state='running'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM processing_failures f
                      WHERE f.epoch_id=w.epoch_id AND f.generation=w.generation
                        AND f.configuration_hash=w.configuration_hash
                        AND f.stage='transcription' AND f.work_id=w.id
                        AND f.error_code='audio_unavailable'
                  )
                ORDER BY w.rowid
                """, [.text(configurationFingerprint)])
            let windows = try rows.map { try WireJSON.decode(ArchiveAnalysisWindow.self, from: $0.requireData(0)) }
                .filter { try !batchReserves($0) && windowHasRetainedContextInputs($0) }
            let unprepared = includingUnpreparedAudio ? try unpreparedBatchRanges(fingerprint: configurationFingerprint, now: now) : []
            guard !windows.isEmpty || !unprepared.isEmpty else { return nil }
            try database.execute("INSERT INTO transcription_batches(id,configuration_hash) VALUES(?,?)", [.text(id.uuidString), .text(configurationFingerprint)])
            for source in unprepared {
                try database.execute("INSERT INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind) VALUES(?,?,?,?,?,?,'unprepared')", [
                    .text(id.uuidString), .text(source.sessionID.uuidString), .text(source.epochID.uuidString),
                    .double(source.timebaseHz), .integer(source.frames.start), .integer(source.frames.end)
                ])
            }
            for window in windows {
                try database.execute("INSERT INTO transcription_batch_windows(batch_id,window_id,session_id,epoch_id,start_frame,end_frame) VALUES(?,?,?,?,?,?)", [
                    .text(id.uuidString), .text(window.id), .text(window.sessionID.uuidString), .text(window.epochID.uuidString),
                    .integer(window.coreFrames.start), .integer(window.coreFrames.end)
                ])
            }
            let byEpoch = Dictionary(grouping: windows, by: \.epochID)
            let activeEpochIDs = Set(windows.map(\.epochID)).union(unprepared.map(\.epochID))
            if !activeEpochIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: activeEpochIDs.count).joined(separator: ",")
                let epochValues = activeEpochIDs.map { SQLValue.text($0.uuidString) }
                let epochs = try database.rows("SELECT e.id,e.session_id,e.timebase FROM epochs e JOIN sessions s ON s.id=e.session_id WHERE s.deleted=0 AND e.id IN (\(placeholders)) ORDER BY e.rowid", epochValues)
                for epoch in epochs {
                    let epochID = try epoch.requireUUID(0), sessionID = try epoch.requireUUID(1)
                    let members = byEpoch[epochID] ?? []
                    guard let rate = epoch.double(2), rate.isFinite, rate > 0 else { throw ArchiveError.invalidTranscript }
                    let known = try database.rows("SELECT start_frame,end_frame FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=? AND kind='no_speech'", [.text(epochID.uuidString), .text(configurationFingerprint)]).map { try batchRange($0) }
                    let previouslyFrozen = try database.rows("SELECT r.start_frame,r.end_frame FROM transcription_batch_ranges r JOIN transcription_batches b ON b.id=r.batch_id WHERE r.epoch_id=? AND b.configuration_hash=? AND r.kind!='deferred'", [.text(epochID.uuidString), .text(configurationFingerprint)]).map { try batchRange($0) }
                    let noSpeech = try subtractBatchRanges(known, removing: previouslyFrozen)
                    for (kind, ranges) in [("speech", try FrameRange.union(members.map(\.coreFrames))), ("no_speech", noSpeech)] {
                        for range in ranges {
                            try database.execute("INSERT INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind) VALUES(?,?,?,?,?,?,?)", [
                                .text(id.uuidString), .text(sessionID.uuidString), .text(epochID.uuidString), .double(rate),
                                .integer(range.start), .integer(range.end), .text(kind)
                            ])
                        }
                    }
                }
            }
            return try transcriptionBatch(id: id)
        }
    }

    public func transcriptionBatches(limit: Int = 50) throws -> [TranscriptionBatch] {
        guard (1...200).contains(limit) else { throw ArchiveError.invalidQuery }
        return try database.rows("SELECT id FROM transcription_batches ORDER BY rowid DESC LIMIT ?", [.integer(Int64(limit))])
            .map { try transcriptionBatch(id: $0.requireUUID(0)) }
    }

    public func activeTranscriptionBatches() throws -> [TranscriptionBatch] {
        try database.rows("SELECT id FROM transcription_batches WHERE state!='completed' ORDER BY rowid")
            .map { try transcriptionBatch(id: $0.requireUUID(0)) }
    }

    public func transcriptionBatch(id: UUID) throws -> TranscriptionBatch {
        guard let row = try database.rows("SELECT configuration_hash,state,end_reason,current_execution FROM transcription_batches WHERE id=?", [.text(id.uuidString)]).first else {
            throw TranscriptionBatchError.missingBatch(id)
        }
        guard let state = TranscriptionBatchState(rawValue: try row.requireString(1)) else { throw ArchiveError.database(11) }
        let reason = try batchEndReason(row.string(2))
        let execution: TranscriptionBatchExecution?
        if let value = row.string(3) {
            guard let executionID = UUID(uuidString: value),
                  let run = try database.rows("SELECT origin FROM transcription_batch_executions WHERE id=? AND batch_id=?", [.text(value), .text(id.uuidString)]).first,
                  let origin = TranscriptionBatchOrigin(rawValue: try run.requireString(0)) else { throw ArchiveError.database(11) }
            execution = TranscriptionBatchExecution(batchID: id, executionID: executionID, origin: origin)
        } else { execution = nil }
        let members = try database.rows("SELECT m.window_id,m.epoch_id,m.start_frame,m.end_frame,w.state FROM transcription_batch_windows m LEFT JOIN analysis_windows w ON w.id=m.window_id WHERE m.batch_id=? ORDER BY m.rowid", [.text(id.uuidString)])
        let ranges = try database.rows("SELECT r.session_id,r.epoch_id,r.timebase,r.start_frame,r.end_frame,r.kind,s.deleted FROM transcription_batch_ranges r JOIN sessions s ON s.id=r.session_id WHERE r.batch_id=? ORDER BY r.epoch_id,r.start_frame,r.kind", [.text(id.uuidString)])
        let fingerprint = try row.requireString(0)
        var coverage: [TranscriptionBatchCoverage] = []
        let grouped = try Dictionary(grouping: ranges, by: { try $0.requireUUID(1) })
        for epochID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let parts = grouped[epochID], let first = parts.first, let rate = first.double(2) else { throw ArchiveError.database(11) }
            let frozen = try FrameRange.union(parts.map { try batchRange($0, offset: 3) })
            let raw = try parts.filter { $0.string(5) == "unprepared" }.map { try batchRange($0, offset: 3) }
            let deferred = try FrameRange.union(parts.filter { $0.string(5) == "deferred" }.map { try batchRange($0, offset: 3) })
            let prePrepared = try FrameRange.union(parts.filter { ["speech", "no_speech"].contains($0.string(5) ?? "") }.map { try batchRange($0, offset: 3) })
            let analyzedSilence = raw.isEmpty ? [] : try database.rows("SELECT start_frame,end_frame FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=? AND kind='no_speech'",
                [.text(epochID.uuidString), .text(fingerprint)]).map { try batchRange($0) }
            let analyzedRaw = raw.isEmpty ? [] : try CoverageRanges.intersection(raw, analyzedRanges(epochID: epochID, fingerprint: fingerprint))
            let noSpeech = try FrameRange.union(parts.filter { $0.string(5) == "no_speech" }.map { try batchRange($0, offset: 3) }
                + CoverageRanges.intersection(raw, analyzedSilence))
            let sessionDeleted = first.integer(6) == 1
            let effectiveRemoved = sessionDeleted ? frozen : try CoverageRanges.intersection(frozen, deferred)
            let recognized = try members.filter { $0.string(1) == epochID.uuidString && $0.string(4) == "complete" }.map { try batchRange($0, offset: 2) }
            let prepared = sessionDeleted ? [] : try CoverageRanges.intersection(frozen, CoverageRanges.subtract(prePrepared + analyzedRaw, effectiveRemoved))
            let completed = try CoverageRanges.intersection(frozen, sessionDeleted ? [] : CoverageRanges.subtract(noSpeech + recognized, effectiveRemoved))
            coverage.append(TranscriptionBatchCoverage(sessionID: try first.requireUUID(0), epochID: epochID,
                timebaseHz: rate, frozen: frozen, noSpeech: noSpeech, prepared: prepared,
                completed: completed, removed: effectiveRemoved))
        }
        return TranscriptionBatch(id: id, configurationFingerprint: fingerprint, state: state,
            endReason: reason, execution: execution, windowIDs: try members.map { try $0.requireString(0) }, coverage: coverage)
    }

    public func beginTranscriptionBatch(id: UUID, executionID: UUID = UUID(), origin: TranscriptionBatchOrigin) throws -> TranscriptionBatchExecution {
        try database.transaction {
            let batch = try transcriptionBatch(id: id)
            let execution = TranscriptionBatchExecution(batchID: id, executionID: executionID, origin: origin)
            if batch.execution == execution, batch.state == .running { return execution }
            guard batch.state != .paused else { throw TranscriptionBatchError.paused }
            guard batch.state == .ready,
                  try database.rows("SELECT 1 FROM transcription_batch_executions WHERE id=?", [.text(executionID.uuidString)]).isEmpty else {
                throw TranscriptionBatchError.staleExecution
            }
            try database.execute("INSERT INTO transcription_batch_executions(id,batch_id,origin) VALUES(?,?,?)", [.text(executionID.uuidString), .text(id.uuidString), .text(origin.rawValue)])
            try database.execute("UPDATE transcription_batches SET state='running',end_reason=NULL,current_execution=? WHERE id=?", [.text(executionID.uuidString), .text(id.uuidString)])
            return execution
        }
    }

    /// The first end event wins. Replaying an old completion cannot end a newer execution.
    public func finishTranscriptionBatch(execution: TranscriptionBatchExecution, reason: TranscriptionBatchEndReason) throws -> TranscriptionBatch {
        try database.transaction {
            guard let run = try database.rows("SELECT batch_id,origin,end_reason FROM transcription_batch_executions WHERE id=?", [.text(execution.executionID.uuidString)]).first,
                  run.string(0) == execution.batchID.uuidString, run.string(1) == execution.origin.rawValue else { throw TranscriptionBatchError.staleExecution }
            if run.string(2) != nil { return try transcriptionBatch(id: execution.batchID) }
            try validateBatchExecution(execution)
            if reason == .completed {
                if let fingerprint = try database.rows("SELECT configuration_hash FROM transcription_batches WHERE id=?", [.text(execution.batchID.uuidString)]).first?.string(0) {
                    try registerOverlappingBatchWindows(batchID: execution.batchID, fingerprint: fingerprint)
                }
                let unfinished = try database.rows("SELECT 1 FROM transcription_batch_windows m JOIN sessions s ON s.id=m.session_id LEFT JOIN analysis_windows w ON w.id=m.window_id WHERE m.batch_id=? AND s.deleted=0 AND (w.id IS NULL OR w.state!='complete') LIMIT 1", [.text(execution.batchID.uuidString)])
                guard unfinished.isEmpty else { throw TranscriptionBatchError.incomplete }
                let batch = try transcriptionBatch(id: execution.batchID)
                for coverage in batch.coverage {
                    guard try CoverageRanges.subtract(coverage.frozen, coverage.completed + coverage.removed).isEmpty else {
                        throw TranscriptionBatchError.incomplete
                    }
                }
            }
            if reason == .backgroundExpired, execution.origin != .backgroundProcessing { throw ArchiveError.invalidQuery }
            try endBatchExecution(execution, reason: reason)
            return try transcriptionBatch(id: execution.batchID)
        }
    }

    public func resumeTranscriptionBatch(id: UUID) throws -> TranscriptionBatch {
        try database.transaction {
            let batch = try transcriptionBatch(id: id)
            guard batch.state != .running else { throw TranscriptionBatchError.staleExecution }
            if batch.state == .paused { try database.execute("UPDATE transcription_batches SET state='ready' WHERE id=?", [.text(id.uuidString)]) }
            return try transcriptionBatch(id: id)
        }
    }

    // Called inside Archive's startup recovery transaction, before stale window attempts are cleared.
    func recoverInterruptedBatches() throws {
        for row in try database.rows("SELECT b.id,x.id,x.origin FROM transcription_batches b JOIN transcription_batch_executions x ON x.id=b.current_execution WHERE b.state='running'") {
            guard let origin = TranscriptionBatchOrigin(rawValue: try row.requireString(2)) else { throw ArchiveError.database(11) }
            let execution = TranscriptionBatchExecution(batchID: try row.requireUUID(0), executionID: try row.requireUUID(1), origin: origin)
            try endBatchExecution(execution, reason: origin == .continuedProcessing ? .systemEndedUnknown : .interrupted)
        }
    }

    func validateBatchExecution(_ execution: TranscriptionBatchExecution, fingerprint: String? = nil) throws {
        guard let row = try database.rows("SELECT b.configuration_hash FROM transcription_batches b JOIN transcription_batch_executions x ON x.id=b.current_execution WHERE b.id=? AND b.state='running' AND b.current_execution=? AND x.origin=? AND x.end_reason IS NULL", [.text(execution.batchID.uuidString), .text(execution.executionID.uuidString), .text(execution.origin.rawValue)]).first else {
            throw TranscriptionBatchError.staleExecution
        }
        if let fingerprint, row.string(0) != fingerprint { throw TranscriptionBatchError.configurationMismatch }
    }

    func batchReserves(_ window: ArchiveAnalysisWindow, except batchID: UUID? = nil) throws -> Bool {
        let rows = try database.rows("SELECT m.batch_id FROM transcription_batch_windows m JOIN transcription_batches b ON b.id=m.batch_id WHERE m.epoch_id=? AND m.start_frame<? AND m.end_frame>? AND b.state!='completed'", [.text(window.epochID.uuidString), .integer(window.coreFrames.end), .integer(window.coreFrames.start)])
        return try rows.contains { try $0.requireUUID(0) != batchID }
            || batchReservesAnalysis(epochID: window.epochID, except: batchID)
    }

    func batchReservesSession(_ sessionID: UUID) throws -> Bool {
        try !database.rows("""
            SELECT 1 FROM transcription_batch_ranges r JOIN transcription_batches b ON b.id=r.batch_id
            WHERE r.session_id=? AND r.kind IN ('speech','unprepared') AND b.state!='completed' LIMIT 1
            """, [.text(sessionID.uuidString)]).isEmpty
    }

    func windowHasRetainedContextInputs(_ window: ArchiveAnalysisWindow) throws -> Bool {
        let inputs = try contiguousInputs(epochID: window.epochID, from: window.analysisAnchor, through: window.contextFrames.end)
        guard let last = inputs.last, last.envelope.manifest.frames.end >= window.contextFrames.end,
              inputs.map(\.envelope.manifestSHA256) == window.replayInputManifestHashes else { return false }
        return inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.audioURL.path) }
    }

    public func deferUnclaimableBatchItems(execution: TranscriptionBatchExecution,
                                           configurationFingerprint: String,
                                           now: Date = Date()) throws -> Int {
        guard ContentHash.isValid(configurationFingerprint) else { throw ArchiveError.invalidQuery }
        return try database.transaction {
            try validateBatchExecution(execution, fingerprint: configurationFingerprint)
            try registerOverlappingBatchWindows(batchID: execution.batchID, fingerprint: configurationFingerprint)
            var deferredCount = 0
            let batchID = execution.batchID

            let windowRows = try database.rows("""
                SELECT m.window_id,m.session_id,m.epoch_id,m.start_frame,m.end_frame,
                       s.deleted,s.projection_blocked,s.generation,
                       w.state,w.generation,w.descriptor
                FROM transcription_batch_windows m
                JOIN sessions s ON s.id=m.session_id
                LEFT JOIN analysis_windows w ON w.id=m.window_id
                WHERE m.batch_id=?
                ORDER BY m.rowid
                """, [.text(batchID.uuidString)])
            for row in windowRows {
                guard row.integer(5) == 0 else { continue }
                let windowState = row.string(8)
                if windowState == "complete" || windowState == "running" { continue }
                let windowID = try row.requireString(0)
                let sessionID = try row.requireUUID(1)
                let epochID = try row.requireUUID(2)
                let startFrame = try row.requireInt(3), endFrame = try row.requireInt(4)
                let frames = try FrameRange(start: startFrame, count: endFrame - startFrame)
                let projectionBlocked = row.integer(6) != 0
                let sessionGen = try row.requireInt(7)
                let windowGen = row.integer(9)

                var unclaimable = windowState == nil || projectionBlocked || windowGen != sessionGen
                var decodedWindow: ArchiveAnalysisWindow?
                if !unclaimable, let data = row.data(10) {
                    let window = try WireJSON.decode(ArchiveAnalysisWindow.self, from: data)
                    decodedWindow = window
                    if try batchReserves(window, except: batchID) {
                        unclaimable = true
                    } else if try !database.rows("""
                        SELECT 1 FROM processing_failures
                        WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage='transcription' AND work_id=?
                          AND error_code='audio_unavailable'
                        LIMIT 1
                        """, [.text(epochID.uuidString), .integer(sessionGen), .text(configurationFingerprint),
                              .text(windowID)]).isEmpty {
                        unclaimable = true
                    } else {
                        let inputs = try contiguousInputs(epochID: window.epochID, from: window.analysisAnchor, through: window.contextFrames.end)
                        if let last = inputs.last, last.envelope.manifest.frames.end >= window.contextFrames.end,
                           inputs.map(\.envelope.manifestSHA256) == window.replayInputManifestHashes {
                            for input in inputs {
                                if (try? validStoredAudio(input.audioURL, envelope: input.envelope)) != true {
                                    try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE id=?", [.text(input.envelope.manifest.chunkID.uuidString)])
                                    verifiedRecordingFilesCache.removeValue(forKey: window.sessionID)
                                    try saveProcessingFailure(sessionID: window.sessionID, epochID: window.epochID, generation: sessionGen,
                                        fingerprint: configurationFingerprint, stage: .transcription, workID: window.id,
                                        frames: window.coreFrames, code: .audioUnavailable, now: now)
                                    unclaimable = true
                                    break
                                }
                            }
                        } else {
                            unclaimable = true
                        }
                    }
                } else {
                    unclaimable = true
                }

                if unclaimable {
                    if let decodedWindow {
                        try deferBatchWindow(batchID: batchID, window: decodedWindow)
                    } else {
                        try database.execute("DELETE FROM transcription_batch_windows WHERE batch_id=? AND window_id=?",
                            [.text(batchID.uuidString), .text(windowID)])
                        try deferBatchSlice(batchID: batchID, sessionID: sessionID, epochID: epochID, frames: frames)
                    }
                    deferredCount += 1
                }
            }

            let rawEpochs = try database.rows("""
                SELECT DISTINCT r.epoch_id,r.session_id,s.deleted,s.projection_blocked,s.generation
                FROM transcription_batch_ranges r
                JOIN sessions s ON s.id=r.session_id
                WHERE r.batch_id=? AND r.kind='unprepared'
                """, [.text(batchID.uuidString)])
            for row in rawEpochs {
                guard row.integer(2) == 0 else { continue }
                let epochID = try row.requireUUID(0)
                let sessionID = try row.requireUUID(1)
                let projectionBlocked = row.integer(3) != 0
                let sessionGen = try row.requireInt(4)
                let epochState = try database.rows(
                    "SELECT attempt_id,generation FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?",
                    [.text(epochID.uuidString), .text(configurationFingerprint)]
                ).first
                if epochState?.string(0) != nil { continue }
                let epochGenMismatch = epochState != nil && (epochState?.integer(1) != sessionGen)
                let reservedElsewhere = try batchReservesAnalysis(epochID: epochID, except: batchID)
                let pending = try CoverageRanges.subtract(
                    batchPreparationRanges(id: batchID, epochID: epochID),
                    analyzedRanges(epochID: epochID, fingerprint: configurationFingerprint)
                )
                for range in pending {
                    var unclaimable = projectionBlocked || epochGenMismatch || reservedElsewhere
                    if !unclaimable {
                        if try !database.rows("""
                            SELECT 1 FROM processing_failures
                            WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage='analysis'
                              AND start_frame<? AND end_frame>? AND error_code='audio_unavailable'
                            LIMIT 1
                            """, [.text(epochID.uuidString), .integer(sessionGen), .text(configurationFingerprint),
                                  .integer(range.end), .integer(range.start)]).isEmpty {
                            unclaimable = true
                        } else {
                            let inputs = try contiguousInputs(epochID: epochID, from: range.start, through: range.end)
                            if inputs.isEmpty {
                                unclaimable = true
                            } else {
                                for input in inputs {
                                    if (try? validStoredAudio(input.audioURL, envelope: input.envelope)) != true {
                                        try database.execute("UPDATE chunks SET retention='missing_unexpected' WHERE id=?", [.text(input.envelope.manifest.chunkID.uuidString)])
                                        verifiedRecordingFilesCache.removeValue(forKey: sessionID)
                                        unclaimable = true
                                        break
                                    }
                                }
                            }
                        }
                    }
                    if unclaimable {
                        try deferBatchSlice(batchID: batchID, sessionID: sessionID, epochID: epochID, frames: range)
                        deferredCount += 1
                    }
                }
            }

            // Final sweep: if an epoch in this batch has no remaining pending/running windows
            // and no remaining unanalyzed preparation ranges, any residual frozen gap (e.g. VAD
            // sub-window boundary frames) has no claimable work left and must not wedge batch completion.
            let postBatch = try transcriptionBatch(id: batchID)
            for coverage in postBatch.coverage {
                let residual = try CoverageRanges.subtract(coverage.frozen, coverage.completed + coverage.removed)
                guard !residual.isEmpty else { continue }
                let hasPendingWindow = try !database.rows("""
                    SELECT 1 FROM transcription_batch_windows m
                    JOIN analysis_windows w ON w.id=m.window_id
                    WHERE m.batch_id=? AND m.epoch_id=? AND w.state IN ('pending','running')
                    LIMIT 1
                    """, [.text(batchID.uuidString), .text(coverage.epochID.uuidString)]).isEmpty
                guard !hasPendingWindow else { continue }
                let hasRunningAnalysis = try database.rows(
                    "SELECT attempt_id FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?",
                    [.text(coverage.epochID.uuidString), .text(configurationFingerprint)]
                ).first?.string(0) != nil
                guard !hasRunningAnalysis else { continue }
                let remainingUnprepared = try CoverageRanges.subtract(
                    batchPreparationRanges(id: batchID, epochID: coverage.epochID),
                    analyzedRanges(epochID: coverage.epochID, fingerprint: configurationFingerprint)
                )
                guard remainingUnprepared.isEmpty else { continue }
                for slice in residual {
                    try deferBatchSlice(batchID: batchID, sessionID: coverage.sessionID, epochID: coverage.epochID, frames: slice)
                    deferredCount += 1
                }
            }
            return deferredCount
        }
    }

    func deferBatchWindow(batchID: UUID, window: ArchiveAnalysisWindow) throws {
        try database.execute("DELETE FROM transcription_batch_windows WHERE batch_id=? AND window_id=?",
            [.text(batchID.uuidString), .text(window.id)])
        try deferBatchSlice(batchID: batchID, sessionID: window.sessionID, epochID: window.epochID, frames: window.coreFrames)
    }

    func deferBatchSlice(batchID: UUID, sessionID: UUID, epochID: UUID, frames: FrameRange) throws {
        let rows = try database.rows("""
            SELECT timebase,start_frame,end_frame,kind FROM transcription_batch_ranges
            WHERE batch_id=? AND epoch_id=? AND kind IN ('speech','unprepared') AND start_frame<? AND end_frame>?
            """, [.text(batchID.uuidString), .text(epochID.uuidString), .integer(frames.end), .integer(frames.start)])
        guard !rows.isEmpty else { return }
        for row in rows {
            guard let rate = row.double(0), rate.isFinite, rate > 0 else { continue }
            let rowStart = try row.requireInt(1)
            let rowEnd = try row.requireInt(2)
            let kind = try row.requireString(3)
            try database.execute("""
                DELETE FROM transcription_batch_ranges
                WHERE batch_id=? AND epoch_id=? AND start_frame=? AND end_frame=? AND kind=?
                """, [.text(batchID.uuidString), .text(epochID.uuidString), .integer(rowStart), .integer(rowEnd), .text(kind)])
            if rowStart < frames.start {
                try database.execute("""
                    INSERT OR IGNORE INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind)
                    VALUES(?,?,?,?,?,?,?)
                    """, [.text(batchID.uuidString), .text(sessionID.uuidString), .text(epochID.uuidString),
                          .double(rate), .integer(rowStart), .integer(frames.start), .text(kind)])
            }
            if frames.end < rowEnd {
                try database.execute("""
                    INSERT OR IGNORE INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind)
                    VALUES(?,?,?,?,?,?,?)
                    """, [.text(batchID.uuidString), .text(sessionID.uuidString), .text(epochID.uuidString),
                          .double(rate), .integer(frames.end), .integer(rowEnd), .text(kind)])
            }
            let cutStart = max(rowStart, frames.start)
            let cutEnd = min(rowEnd, frames.end)
            if cutEnd > cutStart {
                try database.execute("""
                    INSERT OR IGNORE INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind)
                    VALUES(?,?,?,?,?,?,'deferred')
                    """, [.text(batchID.uuidString), .text(sessionID.uuidString), .text(epochID.uuidString),
                          .double(rate), .integer(cutStart), .integer(cutEnd)])
            }
        }
    }

    private func endBatchExecution(_ execution: TranscriptionBatchExecution, reason: TranscriptionBatchEndReason) throws {
        let state: TranscriptionBatchState
        switch reason {
        case .completed: state = .completed
        case .userPaused, .systemEndedUnknown: state = .paused
        case .backgroundExpired, .interrupted: state = .ready
        }
        try database.execute("UPDATE transcription_batch_executions SET end_reason=? WHERE id=? AND end_reason IS NULL", [.text(reason.rawValue), .text(execution.executionID.uuidString)])
        try database.execute("UPDATE transcription_batches SET state=?,end_reason=?,current_execution=NULL WHERE id=?", [.text(state.rawValue), .text(reason.rawValue), .text(execution.batchID.uuidString)])
        // Invalidate writes immediately; the worker releases its own audio leases only after native returns.
        try database.execute("UPDATE analysis_windows SET state='pending',attempt_id=NULL WHERE state='running' AND id IN (SELECT window_id FROM transcription_batch_windows WHERE batch_id=?)", [.text(execution.batchID.uuidString)])
        try database.execute("UPDATE analysis_epochs SET attempt_id=NULL WHERE epoch_id IN (SELECT epoch_id FROM transcription_batch_ranges WHERE batch_id=? AND kind='unprepared')",
            [.text(execution.batchID.uuidString)])
    }
}

private func batchEndReason(_ value: String?) throws -> TranscriptionBatchEndReason? {
    guard let value else { return nil }
    guard let reason = TranscriptionBatchEndReason(rawValue: value) else { throw ArchiveError.database(11) }
    return reason
}

private func batchRange(_ row: SQLRow, offset: Int = 0) throws -> FrameRange {
    try FrameRange(start: row.requireInt(offset), count: row.requireInt(offset + 1) - row.requireInt(offset))
}

private func subtractBatchRanges(_ ranges: [FrameRange], removing removed: [FrameRange]) throws -> [FrameRange] {
    let removed = try FrameRange.union(removed)
    var result: [FrameRange] = []
    for range in try FrameRange.union(ranges) {
        var cursor = range.start
        for cut in removed where cut.end > cursor && cut.start < range.end {
            if cut.start > cursor { result.append(try FrameRange(start: cursor, count: cut.start - cursor)) }
            cursor = min(range.end, max(cursor, cut.end))
        }
        if cursor < range.end { result.append(try FrameRange(start: cursor, count: range.end - cursor)) }
    }
    return result
}
