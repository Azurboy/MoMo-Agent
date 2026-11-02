import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Requeues only failed legacy jobs for the selected recording. Modern failures already
    /// release their own attempts to pending; completed windows and checkpoints are untouched.
    public func prepareTranscriptionRetry(sessionID: UUID, expectedGeneration: Int64, sources: [TimelineAudioSource]? = nil) throws {
        try database.transaction {
            try validateRetryScope(sessionID: sessionID, expectedGeneration: expectedGeneration)
            guard try !batchReservesSession(sessionID), try transcriptionState(sessionID: sessionID) != .processing else {
                throw ArchiveError.operationConflict(sessionID)
            }
            if let sources {
                guard sources.allSatisfy({ $0.sessionID == sessionID && $0.generation == expectedGeneration }) else { throw ArchiveError.staleSource }
                for row in try database.rows("SELECT c.id,c.epoch_id,c.start_frame,c.end_frame FROM chunks c JOIN transcription_jobs j ON j.chunk_id=c.id WHERE c.session_id=? AND c.retention='present' AND j.state='failed' AND j.generation=?", [.text(sessionID.uuidString), .integer(expectedGeneration)]) {
                    let epochID = try row.requireUUID(1)
                    let start = try row.requireInt(2), end = try row.requireInt(3)
                    if sources.contains(where: { $0.epochID == epochID && $0.frames.start < end && $0.frames.end > start }) {
                        try database.execute("UPDATE transcription_jobs SET state='pending',attempt_id=NULL,error_code=NULL WHERE chunk_id=?", [.text(try row.requireString(0))])
                    }
                }
            } else {
                try database.execute("UPDATE transcription_jobs SET state='pending',attempt_id=NULL,error_code=NULL WHERE state='failed' AND generation=? AND chunk_id IN (SELECT id FROM chunks WHERE session_id=? AND retention='present')", [.integer(expectedGeneration), .text(sessionID.uuidString)])
            }
            for row in try database.rows("SELECT epoch_id,stage,work_id,start_frame,end_frame FROM processing_failures WHERE session_id=? AND generation=?", [.text(sessionID.uuidString), .integer(expectedGeneration)]) {
                let epochID = try row.requireUUID(0), start = try row.requireInt(3), end = try row.requireInt(4)
                if sources.map({ $0.contains(where: { $0.epochID == epochID && $0.frames.start < end && $0.frames.end > start }) }) ?? true {
                    try database.execute("DELETE FROM processing_failures WHERE epoch_id=? AND stage=? AND work_id=? AND generation=?",
                        [.text(epochID.uuidString), .text(try row.requireString(1)), .text(try row.requireString(2)), .integer(expectedGeneration)])
                }
            }
        }
    }

    private func validateRetryScope(sessionID: UUID?, expectedGeneration: Int64?) throws {
        guard let sessionID else {
            guard expectedGeneration == nil else { throw ArchiveError.invalidQuery }
            return
        }
        guard let expectedGeneration else { throw ArchiveError.invalidQuery }
        guard try !sessionIsDeleted(sessionID) else { throw ArchiveError.sessionDeleted(sessionID) }
        guard try sessionGeneration(sessionID) == expectedGeneration else { throw ArchiveError.staleSource }
    }

    public func markEpochClosed(epochID: UUID, endFrame: Int64) throws {
        guard endFrame >= 0 else { throw ArchiveError.invalidTranscript }
        if let row = try database.rows("SELECT end_frame FROM epoch_closures WHERE epoch_id=?", [.text(epochID.uuidString)]).first {
            guard row.integer(0) == endFrame else { throw ArchiveError.conflictingEpoch(epochID) }
            return
        }
        try database.execute("INSERT INTO epoch_closures(epoch_id,end_frame) VALUES(?,?)", [.text(epochID.uuidString), .integer(endFrame)])
    }

    public func claimEpochAnalysis(configurationFingerprint: String, sessionID: UUID? = nil,
                                   expectedGeneration: Int64? = nil, sources: [TimelineAudioSource]? = nil,
                                   finalizeAvailablePrefixBefore: Date? = nil, isolateLocalFailures: Bool = false,
                                   selectedEpochID: UUID? = nil, processingRange: FrameRange? = nil,
                                   batchExecution: TranscriptionBatchExecution? = nil,
                                   maxStepSeconds: Double = 120,
                                   now: Date = Date()) throws -> EpochAnalysisTicket? {
        guard ContentHash.isValid(configurationFingerprint) else { throw ArchiveError.invalidQuery }
        if let batchExecution {
            try validateBatchExecution(batchExecution, fingerprint: configurationFingerprint)
            guard let selectedEpochID, let processingRange,
                  try CoverageRanges.subtract([processingRange], batchPreparationRanges(id: batchExecution.batchID, epochID: selectedEpochID)).isEmpty else {
                throw ArchiveError.invalidQuery
            }
        }
        try validateRetryScope(sessionID: sessionID, expectedGeneration: expectedGeneration)
        let filter = sessionID.map { SQLValue.text($0.uuidString) } ?? .null
        let selected = selectedEpochID.map { SQLValue.text($0.uuidString) } ?? .null
        for row in try database.rows("SELECT e.id,e.session_id,s.generation,e.timebase FROM epochs e JOIN sessions s ON s.id=e.session_id WHERE s.deleted=0 AND s.projection_blocked=0 AND (? IS NULL OR s.id=?) AND (? IS NULL OR e.id=?) ORDER BY s.recorded_at,e.rowid", [filter, filter, selected, selected]) {
            let epochID = try row.requireUUID(0), sessionID = try row.requireUUID(1), generation = try row.requireInt(2)
            if try batchReservesAnalysis(epochID: epochID, except: batchExecution?.batchID) { continue }
            if let sources, !sources.contains(where: { $0.epochID == epochID && $0.sessionID == sessionID }) { continue }
            let state = try database.rows("SELECT attempt_id,last_input_hash,checkpoint,generation FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?", [.text(epochID.uuidString), .text(configurationFingerprint)]).first
            if state?.string(0) != nil { continue }
            if let state, try state.requireInt(3) != generation { continue }
            let checkpoint: ArchiveCheckpoint?
            if let processingRange {
                checkpoint = processingRange.start == 0 ? nil : ArchiveCheckpoint(sessionID: sessionID, epochID: epochID,
                    sourceFrame: processingRange.start, configurationFingerprint: configurationFingerprint)
            } else if let data = state?.data(2) { checkpoint = try WireJSON.decode(ArchiveCheckpoint.self, from: data) }
            else { checkpoint = nil }
            let start = checkpoint?.sourceFrame ?? 0
            let rangeEnd = try processingRange?.end ?? pendingAnalysisRanges(epochID: epochID,
                fingerprint: configurationFingerprint, retainedOnly: false).first(where: { $0.start <= start && start < $0.end })?.end
            let hasRangeBoundary: Bool
            if processingRange != nil { hasRangeBoundary = true }
            else if let rangeEnd { hasRangeBoundary = try analyzedRanges(epochID: epochID, fingerprint: configurationFingerprint).contains { $0.start == rangeEnd } }
            else { hasRangeBoundary = false }
            guard let rate = row.double(3), rate.isFinite, rate > 0, rate <= 192_000 else { throw ArchiveError.invalidTranscript }
            let clampedStepSeconds = max(5, min(120, maxStepSeconds.isFinite ? maxStepSeconds : 120))
            let step = max(1, Int64((rate * clampedStepSeconds).rounded()))
            var (through, overflow) = start.addingReportingOverflow(step)
            guard !overflow else { throw ArchiveError.invalidTranscript }
            let closedFrame = try analysisClosedFrame(epochID: epochID)
            let receivedEnd = try receivedAnalysisRanges(epochID: epochID, retainedOnly: false).last?.end
            let previous = try database.rows("SELECT input_hash FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=? AND generation=? AND start_frame=?",
                [.text(epochID.uuidString), .text(configurationFingerprint), .integer(generation), .integer(start)]).first?.string(0)
            var inputs: [ArchivedAudioInput] = []
            var boundary: AudioProcessingBoundary = .open
            var identity = ""
            while true {
                inputs = try contiguousInputs(epochID: epochID, from: start, through: min(through, rangeEnd ?? .max))
                guard let last = inputs.last else { break }
                if let closedFrame, last.envelope.manifest.frames.end > closedFrame { throw ArchiveError.conflictingEpoch(epochID) }
                // Finalizing this received snapshot never writes a capture-end event. Late audio
                // remains admissible and continues from the committed checkpoint.
                if let rangeEnd, rangeEnd <= last.envelope.manifest.frames.end,
                   rangeEnd < (receivedEnd ?? rangeEnd),
                   hasRangeBoundary {
                    boundary = .processingRange(rangeEnd)
                } else if let closedFrame, closedFrame == last.envelope.manifest.frames.end {
                    boundary = .captureEnd(closedFrame)
                } else if finalizeAvailablePrefixBefore.map({ last.envelope.manifest.sealedAt < $0 }) == true,
                          last.envelope.manifest.frames.end >= (rangeEnd ?? .max) {
                    boundary = .receivedSnapshot(min(rangeEnd ?? .max, last.envelope.manifest.frames.end))
                } else { boundary = .open }
                identity = try analysisInputIdentity(inputs, start: start, boundary: boundary)
                guard (previous == identity || state?.string(1) == identity), boundary == .open,
                      last.envelope.manifest.frames.end < (rangeEnd ?? .max) else { break }
                let (nextThrough, nextOverflow) = last.envelope.manifest.frames.end.addingReportingOverflow(step)
                guard !nextOverflow else { throw ArchiveError.invalidTranscript }
                let nextInputs = try contiguousInputs(epochID: epochID, from: start, through: min(nextThrough, rangeEnd ?? .max))
                guard nextInputs.last?.envelope.manifest.frames.end != last.envelope.manifest.frames.end else { break }
                through = nextThrough
            }
            guard !inputs.isEmpty else { continue }
            if previous == identity || state?.string(1) == identity { continue }
            try database.execute("DELETE FROM processing_failures WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage='analysis' AND start_frame=? AND work_id!=?",
                [.text(epochID.uuidString), .integer(generation), .text(configurationFingerprint), .integer(start), .text(identity)])
            if batchExecution == nil,
               try processingIsDeferred(epochID: epochID, generation: generation, fingerprint: configurationFingerprint, stage: .analysis, workID: identity, now: now) { continue }
            let leases: [UUID]
            do { leases = try leaseInputs(inputs) }
            catch let error as ArchiveError {
                guard isolateLocalFailures, case .missingRecording = error else { throw error }
                let failedFrames = try analysisInputRange(inputs, start: start, end: boundary.endFrame)
                try saveProcessingFailure(sessionID: sessionID, epochID: epochID, generation: generation,
                    fingerprint: configurationFingerprint, stage: .analysis, workID: identity,
                    frames: failedFrames, code: .audioUnavailable, now: now)
                if let batchExecution {
                    try deferBatchSlice(batchID: batchExecution.batchID, sessionID: sessionID, epochID: epochID, frames: failedFrames)
                }
                continue
            }
            let attemptID = UUID()
            do {
                try database.execute("INSERT INTO analysis_epochs(epoch_id,configuration_hash,generation,attempt_id) VALUES(?,?,?,?) ON CONFLICT(epoch_id,configuration_hash) DO UPDATE SET attempt_id=excluded.attempt_id", [.text(epochID.uuidString), .text(configurationFingerprint), .integer(generation), .text(attemptID.uuidString)])
            } catch {
                for lease in leases { audioLeases.removeValue(forKey: lease) }
                throw error
            }
            return EpochAnalysisTicket(attemptID: attemptID, sessionID: sessionID, epochID: epochID, expectedGeneration: generation,
                                       inputs: inputs, checkpoint: checkpoint, replayOrigin: nil, boundary: boundary, configurationFingerprint: configurationFingerprint,
                                       batchExecution: batchExecution, inputIdentity: identity, leaseIDs: leases)
        }
        return nil
    }

    /// Lease recovery input before queuing analysis; the detector may change before that work starts.
    public func withAnalysisReplayPrefix(_ ticket: EpochAnalysisTicket,
                                        includingRecognitionContext: Bool = false) throws -> EpochAnalysisTicket {
        try validateEpochTicket(ticket)
        let start = ticket.checkpoint?.sourceFrame ?? 0
        if start == 0 && !includingRecognitionContext { return ticket }
        let retainedStart: Int64
        if let retained = try receivedAnalysisRanges(epochID: ticket.epochID, retainedOnly: true)
            .first(where: { $0.start <= start && start < $0.end }) {
            retainedStart = retained.start
        } else if ticket.inputs.first?.envelope.manifest.frames.start == start {
            retainedStart = start
        } else {
            throw ArchiveError.missingRecording(ticket.sessionID)
        }
        // Native 16 kHz audio needs only a bounded detector warmup. Resampled audio
        // keeps its original origin so restarting the converter preserves its phase.
        let rate = ticket.inputs.first?.envelope.manifest.sampleRate
        var origin = rate == 16_000 ? max(retainedStart, max(0, start - 60 * 16_000) / 512 * 512) : retainedStart
        if rate == 16_000, origin < start {
            let failedEnd = try database.rows("""
                SELECT MAX(end_frame) FROM processing_failures
                WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage='analysis' AND end_frame<=?
                """, [.text(ticket.epochID.uuidString), .integer(ticket.expectedGeneration),
                      .text(ticket.configurationFingerprint), .integer(start)]).first?.integer(0) ?? 0
            if failedEnd > origin { origin = min(start, (failedEnd + 511) / 512 * 512) }
        }
        var prefix = origin < start ? try contiguousInputs(epochID: ticket.epochID, from: origin, through: start) : []
        if rate == 16_000, !prefix.isEmpty {
            if let lastMissingIdx = prefix.lastIndex(where: { !FileManager.default.fileExists(atPath: $0.audioURL.path) }) {
                prefix = Array(prefix[(lastMissingIdx + 1)...])
                origin = prefix.first.map { max(origin, $0.envelope.manifest.frames.start) } ?? start
            }
        }
        let end = ticket.boundary.endFrame ?? ticket.inputs.last!.envelope.manifest.frames.end
        let rawSuffix = includingRecognitionContext && rate == 16_000 && ticket.boundary.endFrame != nil
            ? try contiguousInputs(epochID: ticket.epochID, from: end, through: end + 16_000) : []
        let suffix: [ArchivedAudioInput]
        if let firstMissing = rawSuffix.firstIndex(where: { !FileManager.default.fileExists(atPath: $0.audioURL.path) }) {
            suffix = Array(rawSuffix[..<firstMissing])
        } else {
            suffix = rawSuffix
        }
        if prefix.isEmpty && suffix.isEmpty && origin == start { return ticket }
        let existing = Set(ticket.inputs.map { $0.envelope.manifest.chunkID })
        var seen = existing
        let additional = (prefix + suffix).filter { seen.insert($0.envelope.manifest.chunkID).inserted }
        // These rows were checked above on the archive actor. Protect them from deletion
        // now; EpochAudioReader verifies each file's hash on the analysis queue before use.
        // Hashing the entire prefix here would block unrelated archive operations.
        let leases = additional.map { input in
            let id = UUID()
            audioLeases[id] = input.envelope.manifest.chunkID
            return id
        }
        return EpochAnalysisTicket(attemptID: ticket.attemptID, sessionID: ticket.sessionID, epochID: ticket.epochID,
            expectedGeneration: ticket.expectedGeneration,
            inputs: (additional + ticket.inputs).sorted { $0.envelope.manifest.frames.start < $1.envelope.manifest.frames.start }, checkpoint: ticket.checkpoint,
            replayOrigin: origin < start ? origin : nil, boundary: ticket.boundary, configurationFingerprint: ticket.configurationFingerprint,
            batchExecution: ticket.batchExecution, inputIdentity: ticket.inputIdentity, leaseIDs: ticket.leaseIDs + leases)
    }

    public func commitAnalysisBatch(ticket: EpochAnalysisTicket, windows: [ArchiveAnalysisWindow],
                                    analyzedCoverage: [FrameRange], noSpeechCoverage: [FrameRange],
                                    checkpoint: ArchiveCheckpoint?, waitingForMoreAudio: Bool,
                                    continuing: Bool = false) throws {
        guard let first = ticket.inputs.first, let last = ticket.inputs.last,
              Set(windows.map(\.id)).count == windows.count else { throw ArchiveError.invalidTranscript }
        let lower = ticket.checkpoint?.sourceFrame ?? first.envelope.manifest.frames.start
        let upper = min(last.envelope.manifest.frames.end, ticket.boundary.endFrame ?? .max)
        for range in analyzedCoverage + noSpeechCoverage {
            guard range.start >= lower, range.end <= upper else { throw ArchiveError.invalidTranscript }
        }
        for range in noSpeechCoverage {
            guard covers(range, with: analyzedCoverage), !windows.contains(where: { overlaps($0.coreFrames, range) }) else { throw ArchiveError.invalidTranscript }
        }
        if let checkpoint {
            guard checkpoint.sessionID == ticket.sessionID, checkpoint.epochID == ticket.epochID,
                  checkpoint.configurationFingerprint == ticket.configurationFingerprint,
                  checkpoint.sourceFrame >= lower, checkpoint.sourceFrame <= upper else { throw ArchiveError.invalidTranscript }
            if checkpoint.sourceFrame > lower {
                guard covers(try FrameRange(start: lower, count: checkpoint.sourceFrame - lower), with: analyzedCoverage) else { throw ArchiveError.invalidTranscript }
            }
        }
        if ticket.epochClosed && waitingForMoreAudio { throw ArchiveError.invalidTranscript }
        if continuing, waitingForMoreAudio || checkpoint == nil || analyzedCoverage.isEmpty { throw ArchiveError.invalidTranscript }
        for window in windows { try validateWindow(window, ticket: ticket) }
        try database.transaction {
            try validateEpochTicket(ticket)
            let existingCores = try database.rows("SELECT id,core_start,core_end FROM analysis_windows WHERE epoch_id=? AND configuration_hash=?", [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint)]).map { row -> (id: String, core: FrameRange) in
                let start = try row.requireInt(1), end = try row.requireInt(2)
                return (try row.requireString(0), try FrameRange(start: start, count: end - start))
            }
            guard !noSpeechCoverage.contains(where: { range in existingCores.contains { overlaps($0.core, range) } }) else {
                throw ArchiveError.invalidTranscript
            }
            let allCores = existingCores + windows.map { (id: $0.id, core: $0.coreFrames) }
            for window in windows {
                guard !allCores.contains(where: { $0.id != window.id && overlaps($0.core, window.coreFrames) }) else { throw ArchiveError.invalidTranscript }
                let data = try WireJSON.encode(window)
                if let existing = try database.rows("SELECT descriptor FROM analysis_windows WHERE id=?", [.text(window.id)]).first {
                    guard try existing.requireData(0) == data else { throw ArchiveError.invalidTranscript }
                } else {
                    try database.execute("""
                        INSERT INTO analysis_windows(
                            id,epoch_id,session_id,generation,configuration_hash,descriptor,
                            core_start,core_end,context_start,context_end,analysis_anchor,model_core_start
                        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                        """, [
                            .text(window.id), .text(window.epochID.uuidString), .text(window.sessionID.uuidString),
                            .integer(ticket.expectedGeneration), .text(window.configurationFingerprint), .blob(data),
                            .integer(window.coreFrames.start), .integer(window.coreFrames.end),
                            .integer(window.contextFrames.start), .integer(window.contextFrames.end),
                            .integer(window.analysisAnchor), .integer(window.modelCoreFrames.start)
                        ])
                }
            }
            for (kind, ranges) in [("analyzed", analyzedCoverage + windows.map(\.coreFrames)), ("no_speech", noSpeechCoverage)] {
                for range in ranges {
                    try database.execute("INSERT OR IGNORE INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind) VALUES(?,?,?,?,?)", [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint), .integer(range.start), .integer(range.end), .text(kind)])
                }
            }
            // Only a contiguous analyzed prefix can advance the replay/retention floor.
            let prefix = try analyzedRanges(epochID: ticket.epochID, fingerprint: ticket.configurationFingerprint).first
            let floor = prefix?.start == 0 ? prefix?.end ?? 0 : 0
            let checkpointValue: SQLValue = floor > 0 ? .blob(try WireJSON.encode(ArchiveCheckpoint(sessionID: ticket.sessionID,
                epochID: ticket.epochID, sourceFrame: floor, configurationFingerprint: ticket.configurationFingerprint))) : .null
            let hasPending = try !pendingAnalysisRanges(epochID: ticket.epochID, fingerprint: ticket.configurationFingerprint, retainedOnly: false).isEmpty
            if continuing {
                try database.execute("UPDATE analysis_epochs SET checkpoint=?,has_pending=? WHERE epoch_id=? AND configuration_hash=?",
                    [checkpointValue, .integer(hasPending ? 1 : 0), .text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint)])
            } else {
                var memoStart = lower, memoIdentity = ticket.inputIdentity
                if waitingForMoreAudio,
                   let remaining = try pendingAnalysisRanges(epochID: ticket.epochID, fingerprint: ticket.configurationFingerprint,
                       retainedOnly: false).first(where: { $0.end > lower && $0.start < upper }), remaining.start > lower {
                    memoStart = remaining.start
                    // Only this attempt's snapshot was inspected; newly arrived inputs must still wake the tail.
                    let tailInputs = ticket.inputs.filter { $0.envelope.manifest.frames.end > memoStart }
                    memoIdentity = try analysisInputIdentity(tailInputs, start: memoStart, boundary: .open)
                }
                try database.execute("UPDATE analysis_epochs SET attempt_id=NULL,last_input_hash=?,checkpoint=?,has_pending=? WHERE epoch_id=? AND configuration_hash=?", [.text(memoIdentity), checkpointValue, .integer(hasPending ? 1 : 0), .text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint)])
                try database.execute("INSERT INTO analysis_range_inputs(epoch_id,configuration_hash,generation,start_frame,input_hash) VALUES(?,?,?,?,?) ON CONFLICT(epoch_id,configuration_hash,generation,start_frame) DO UPDATE SET input_hash=excluded.input_hash",
                    [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint), .integer(ticket.expectedGeneration), .integer(memoStart), .text(memoIdentity)])
            }
            try database.execute("DELETE FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=? AND generation=? AND start_frame<?",
                [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint), .integer(ticket.expectedGeneration), .integer(floor)])
            // A resumed checkpoint has a new start; clear earlier failures once their entire range is analyzed.
            try database.execute("DELETE FROM processing_failures WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage='analysis' AND (start_frame=? OR end_frame<=?)",
                [.text(ticket.epochID.uuidString), .integer(ticket.expectedGeneration), .text(ticket.configurationFingerprint), .integer(lower), .integer(floor)])
            try updateCompletedChunks(epochID: ticket.epochID, configurationFingerprint: ticket.configurationFingerprint)
        }
        if !continuing { for lease in ticket.leaseIDs { audioLeases.removeValue(forKey: lease) } }
    }

    public func invalidateEpochAnalysisAttempt(ticket: EpochAnalysisTicket) throws {
        try database.execute("UPDATE analysis_epochs SET attempt_id=NULL WHERE epoch_id=? AND configuration_hash=? AND attempt_id=?", [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint), .text(ticket.attemptID.uuidString)])
    }

    public func invalidateTranscriptionWindowAttempt(ticket: TranscriptionWindowTicket) throws {
        try database.execute("UPDATE analysis_windows SET state='pending',attempt_id=NULL WHERE id=? AND attempt_id=?", [.text(ticket.window.id), .text(ticket.attemptID.uuidString)])
    }

    public func cancelEpochAnalysis(ticket: EpochAnalysisTicket) throws {
        for lease in ticket.leaseIDs { audioLeases.removeValue(forKey: lease) }
        try database.execute("UPDATE analysis_epochs SET attempt_id=NULL WHERE epoch_id=? AND configuration_hash=? AND attempt_id=?", [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint), .text(ticket.attemptID.uuidString)])
        try cleanDeletedFilesIfPending()
    }

    public func claimTranscriptionWindow(configurationFingerprint: String,
                                         batchExecution: TranscriptionBatchExecution? = nil,
                                         inputLease: TranscriptionInputLease? = nil,
                                         sessionID: UUID? = nil, expectedGeneration: Int64? = nil, sources: [TimelineAudioSource]? = nil,
                                         isolateLocalFailures: Bool = false, selectedWindowID: String? = nil,
                                         now: Date = Date()) throws -> TranscriptionWindowTicket? {
        if let batchExecution {
            try registerPreparedBatchWindows(execution: batchExecution, fingerprint: configurationFingerprint)
        }
        try validateRetryScope(sessionID: sessionID, expectedGeneration: expectedGeneration)
        let filter = sessionID.map { SQLValue.text($0.uuidString) } ?? .null
        let selected = selectedWindowID.map(SQLValue.text) ?? .null
        var cursorRowID: Int64 = 0
        while true {
            let candidates = try database.rows("""
                SELECT w.rowid,w.descriptor,w.generation FROM analysis_windows w
                JOIN sessions s ON s.id=w.session_id
                WHERE w.state='pending' AND w.configuration_hash=? AND s.deleted=0 AND s.projection_blocked=0 AND w.generation=s.generation
                  AND (? IS NULL OR s.id=?) AND (? IS NULL OR w.id=?) AND w.rowid > ?
                ORDER BY w.rowid LIMIT 64
                """, [.text(configurationFingerprint), filter, filter, selected, selected, .integer(cursorRowID)])
            guard !candidates.isEmpty else { break }
            for row in candidates {
                cursorRowID = try row.requireInt(0)
                let window = try WireJSON.decode(ArchiveAnalysisWindow.self, from: row.requireData(1))
                if let sources, !sources.contains(where: { $0.epochID == window.epochID && $0.sessionID == window.sessionID && $0.frames.start < window.coreFrames.end && $0.frames.end > window.coreFrames.start }) { continue }
                if let batchExecution {
                    guard try !database.rows("SELECT 1 FROM transcription_batch_windows WHERE batch_id=? AND window_id=?", [.text(batchExecution.batchID.uuidString), .text(window.id)]).isEmpty else { continue }
                }
                guard try !batchReserves(window, except: batchExecution?.batchID) else { continue }
                let generation = try row.requireInt(2)
                if batchExecution == nil, try processingIsDeferred(epochID: window.epochID, generation: generation, fingerprint: configurationFingerprint, stage: .transcription, workID: window.id, now: now) { continue }
                let inputs = try contiguousInputs(epochID: window.epochID, from: window.analysisAnchor, through: window.contextFrames.end)
                guard let last = inputs.last, last.envelope.manifest.frames.end >= window.contextFrames.end else {
                    if let batchExecution, isolateLocalFailures {
                        try saveProcessingFailure(sessionID: window.sessionID, epochID: window.epochID, generation: generation,
                            fingerprint: configurationFingerprint, stage: .transcription, workID: window.id, frames: window.coreFrames, code: .audioUnavailable, now: now)
                        try deferBatchWindow(batchID: batchExecution.batchID, window: window)
                    }
                    continue
                }
                guard inputs.map({ $0.envelope.manifestSHA256 }) == window.replayInputManifestHashes else {
                    guard let batchExecution, isolateLocalFailures else { throw ArchiveError.staleSource }
                    try saveProcessingFailure(sessionID: window.sessionID, epochID: window.epochID, generation: generation,
                        fingerprint: configurationFingerprint, stage: .transcription, workID: window.id, frames: window.coreFrames, code: .invalidAudio, now: now)
                    try deferBatchWindow(batchID: batchExecution.batchID, window: window)
                    continue
                }
                let reuses = inputLease.map { canReuseInputLease($0, window: window, generation: generation, inputs: inputs) } ?? false
                let leases: [UUID]
                do { leases = reuses ? [] : try leaseInputs(inputs) }
                catch let error as ArchiveError {
                    guard isolateLocalFailures, case .missingRecording = error else { throw error }
                    try saveProcessingFailure(sessionID: window.sessionID, epochID: window.epochID, generation: generation,
                        fingerprint: configurationFingerprint, stage: .transcription, workID: window.id, frames: window.coreFrames, code: .audioUnavailable, now: now)
                    if let batchExecution {
                        try deferBatchWindow(batchID: batchExecution.batchID, window: window)
                    }
                    continue
                }
                let attempt = UUID()
                do {
                    try database.execute("UPDATE analysis_windows SET state='running',attempt_id=? WHERE id=?", [.text(attempt.uuidString), .text(window.id)])
                } catch {
                    for lease in leases { audioLeases.removeValue(forKey: lease) }
                    throw error
                }
                return TranscriptionWindowTicket(attemptID: attempt, window: window, inputs: inputs, expectedGeneration: generation,
                                                 batchExecution: batchExecution, leaseIDs: leases)
            }
            if candidates.count < 64 { break }
        }
        return nil
    }

    /// Only durable predecessors can influence overlap joining; cancelled results cannot consume words.
    public func precedingWindowResult(for ticket: TranscriptionWindowTicket) throws -> (window: ArchiveAnalysisWindow, rawResult: Data)? {
        try validateWindowTicket(ticket)
        guard let row = try database.rows("""
            SELECT descriptor,raw_result FROM analysis_windows
            WHERE epoch_id=? AND configuration_hash=? AND state='complete'
              AND core_end=?
            ORDER BY rowid DESC LIMIT 1
            """, [.text(ticket.window.epochID.uuidString), .text(ticket.window.configurationFingerprint),
                  .integer(ticket.window.coreFrames.start)]).first,
              let raw = row.data(1), raw != TranscriptText.discardedPunctuation else { return nil }
        return (try WireJSON.decode(ArchiveAnalysisWindow.self, from: row.requireData(0)), raw)
    }

    public func commitWindowTranscript(ticket: TranscriptionWindowTicket, text: String, rawResult: Data,
                                       speakerParts: [SpeakerTranscriptPart]? = nil) throws -> TranscriptDocument {
        guard text.utf8.count <= 65_536, rawResult.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalidTranscript }
        let preloadedPrevious = !database.isInTransaction
            ? (try? currentTranscriptOrNil(sessionID: ticket.window.sessionID))
            : nil
        let preloadedBlockPrefix = !database.isInTransaction
            ? transcriptBlockPrefixCache[ticket.window.sessionID]
            : nil
        let (document, storedMeta) = try database.transaction {
            try validateWindowTicket(ticket)
            let previous: TranscriptDocument?
            if let state = try database.rows(
                "SELECT deleted,transcript_version,generation FROM sessions WHERE id=?",
                [.text(ticket.window.sessionID.uuidString)]
            ).first, state.integer(0) == 0,
               let dbVersion = try? state.requireInt(1),
               let dbGen = try? state.requireInt(2) {
                if dbVersion == 0 {
                    previous = nil
                } else if let pre = preloadedPrevious, pre.version == dbVersion, pre.generation == dbGen {
                    previous = pre
                } else {
                    previous = try currentTranscriptOrNil(sessionID: ticket.window.sessionID)
                }
            } else {
                previous = try currentTranscriptOrNil(sessionID: ticket.window.sessionID)
            }
            var spans = previous?.spans ?? []
            var appendedSpans: [TranscriptSpan] = []
            let hasContent = TranscriptText.hasContent(text)
            var sharedPreparedBanks: [String: [Int: VoiceprintMatcher.PreparedBank]] = [:]
            if hasContent {
              let parts = speakerParts ?? [.init(text: text, frames: ticket.window.coreFrames, evidence: nil)]
              guard !parts.isEmpty, parts.count <= 256, parts.map(\.text).joined() == text,
                    parts.first?.frames.start == ticket.window.coreFrames.start,
                    parts.last?.frames.end == ticket.window.coreFrames.end,
                    zip(parts, parts.dropFirst()).allSatisfy({ $0.frames.end == $1.frames.start }),
                    parts.allSatisfy({ $0.frames.count > 0 && !$0.text.isEmpty }) else { throw ArchiveError.invalidTranscript }
              var localClusters: [Int: Set<UUID>] = [:]
              var sessionCones: [String: VoiceprintCone?] = [:]
              let hasVoicedEvidence = parts.contains { $0.evidence?.hasVoiceprint == true }
              let cachedPeople = hasVoicedEvidence ? try cachedVoicePeople() : nil
              for (index, part) in parts.enumerated() {
                let range = part.frames
                let sources = try ticket.window.sources.compactMap { source -> TranscriptAudioRange? in
                    let start = max(source.sourceFrames.start, range.start), end = min(source.sourceFrames.end, range.end)
                    guard end > start else { return nil }
                    return TranscriptAudioRange(chunkID: source.chunkID, frames: try FrameRange(start: start, count: end - start))
                }
                guard let first = sources.first else { throw ArchiveError.invalidTranscript }
                let id = try spanID(windowID: index == 0 ? ticket.window.id : ContentHash.sha256(Data("\(ticket.window.id):speaker:\(index)".utf8)))
                let localSpeaker = part.evidence?.localSpeaker
                // Local IDs encode the 4-speaker DiariZen segmentation window. Different windows
                // may number the same voice differently; only one window supplies cannot-links.
                let excluded = Set(localClusters.filter { entry in
                    guard let localSpeaker, localSpeaker > 0, entry.key > 0 else { return false }
                    return entry.key != localSpeaker && (entry.key - 1) / 4 == (localSpeaker - 1) / 4
                }.values.flatMap { $0 })
                let attribution = try attributeSpeaker(
                    spanID: id,
                    sessionID: ticket.window.sessionID,
                    evidence: part.evidence,
                    excluding: excluded,
                    preloadedPeople: cachedPeople,
                    preparedBanks: &sharedPreparedBanks,
                    sessionCones: &sessionCones)
                if let localSpeaker, let cluster = attribution.1?.clusterID { localClusters[localSpeaker, default: []].insert(cluster) }
                let previousAttr = appendedSpans.last?.attribution
                let sameAsPreviousPart: Bool = {
                    guard index > 0, let prev = previousAttr, let curr = attribution.1 else { return false }
                    if let p1 = prev.personID, let p2 = curr.personID { return p1 == p2 }
                    return prev.personID == nil && curr.personID == nil && prev.clusterID == curr.clusterID
                }()
                let span = TranscriptSpan(id: id, chunkID: first.chunkID,
                    frames: range, text: part.text, speaker: attribution.0, sourceRanges: sources, attribution: attribution.1,
                    startsNewSpeakerTurn: index > 0 && !sameAsPreviousPart)
                spans.append(span)
                appendedSpans.append(span)
              }
            }
            let restoredAnchors = hasContent
                ? try applyHistoricalFeedbackAnchors(
                    sessionID: ticket.window.sessionID,
                    epochID: ticket.window.epochID,
                    coreEnd: ticket.window.coreFrames.end,
                    newSpans: appendedSpans)
                : false
            if restoredAnchors { sharedPreparedBanks.removeAll() }
            let regrouped = try reconcileSpeakerClusters(
                sessionID: ticket.window.sessionID,
                preparedBanks: sharedPreparedBanks.isEmpty ? nil : sharedPreparedBanks)
            if regrouped || restoredAnchors {
                spans = try labeledSpeakerSpans(spans, sessionID: ticket.window.sessionID)
            }
            let updated = TranscriptDocument(sessionID: ticket.window.sessionID, version: (previous?.version ?? 0) + 1,
                                             generation: ticket.expectedGeneration,
                                             spans: try orderedSpans(spans, sessionID: ticket.window.sessionID), updatedAt: Date())
            let trustedPrefix: (fullSpanCount: Int, blockIDs: [Int64])? = {
                guard let prev = previous,
                      let cached = preloadedBlockPrefix,
                      cached.version == prev.version,
                      cached.generation == prev.generation else { return nil }
                return (cached.fullSpanCount, cached.blockIDs)
            }()
            let meta = try storeDocument(
                updated,
                invalidatesExistingSources: regrouped || restoredAnchors,
                appendingSpans: (regrouped || restoredAnchors) ? nil : appendedSpans,
                knownPrevious: .some(previous),
                trustedPreviousBlockPrefix: trustedPrefix
            )
            try database.execute("UPDATE analysis_windows SET state='complete',attempt_id=NULL,raw_result=? WHERE id=?",
                [.blob(hasContent ? rawResult : TranscriptText.discardedPunctuation), .text(ticket.window.id)])
            try clearProcessingFailures(epochID: ticket.window.epochID, generation: ticket.expectedGeneration,
                fingerprint: ticket.window.configurationFingerprint, stage: .transcription, frames: ticket.window.coreFrames)
            try updateCompletedChunks(epochID: ticket.window.epochID, configurationFingerprint: ticket.window.configurationFingerprint)
            return (updated, meta)
        }
        cacheCommittedWindowTranscript(
            document,
            encodedByteCount: storedMeta.encodedBytes,
            previousCompactedPrefix: storedMeta.compactedPrefix
        )
        for lease in ticket.leaseIDs { audioLeases.removeValue(forKey: lease) }
        return document
    }

    public func cancelTranscriptionWindow(ticket: TranscriptionWindowTicket) throws {
        for lease in ticket.leaseIDs { audioLeases.removeValue(forKey: lease) }
        try database.execute("UPDATE analysis_windows SET state='pending',attempt_id=NULL WHERE id=? AND attempt_id=?", [.text(ticket.window.id), .text(ticket.attemptID.uuidString)])
        try cleanDeletedFilesIfPending()
    }

    public func analysisReplayFloors(configurationFingerprint: String) throws -> [UUID: Int64] {
        var result: [UUID: Int64] = [:]
        for row in try database.rows("SELECT epoch_id,checkpoint FROM analysis_epochs WHERE configuration_hash=? AND checkpoint IS NOT NULL", [.text(configurationFingerprint)]) {
            result[try row.requireUUID(0)] = try WireJSON.decode(ArchiveCheckpoint.self, from: row.requireData(1)).sourceFrame
        }
        return result
    }

    func validateEpochTicket(_ ticket: EpochAnalysisTicket) throws {
        guard try !sessionIsDeleted(ticket.sessionID), try sessionGeneration(ticket.sessionID) == ticket.expectedGeneration,
              let row = try database.rows("SELECT attempt_id,generation FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?", [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint)]).first,
              row.string(0) == ticket.attemptID.uuidString, row.integer(1) == ticket.expectedGeneration else { throw ArchiveError.staleAttempt }
        if let execution = ticket.batchExecution {
            do { try validateBatchExecution(execution, fingerprint: ticket.configurationFingerprint) }
            catch is TranscriptionBatchError { throw ArchiveError.staleAttempt }
        }
    }

    func validateWindowTicket(_ ticket: TranscriptionWindowTicket) throws {
        guard try !sessionIsDeleted(ticket.window.sessionID), try sessionGeneration(ticket.window.sessionID) == ticket.expectedGeneration,
              let row = try database.rows("SELECT state,attempt_id,descriptor FROM analysis_windows WHERE id=?", [.text(ticket.window.id)]).first,
              row.string(0) == "running", row.string(1) == ticket.attemptID.uuidString,
              try row.requireData(2) == WireJSON.encode(ticket.window) else { throw ArchiveError.staleAttempt }
        if let execution = ticket.batchExecution {
            do { try validateBatchExecution(execution, fingerprint: ticket.window.configurationFingerprint) }
            catch is TranscriptionBatchError { throw ArchiveError.staleAttempt }
        } else if try batchReserves(ticket.window) { throw ArchiveError.staleAttempt }
    }

    func validateWindow(_ window: ArchiveAnalysisWindow, ticket: EpochAnalysisTicket) throws {
        guard ContentHash.isValid(window.id), window.sessionID == ticket.sessionID, window.epochID == ticket.epochID,
              window.configurationFingerprint == ticket.configurationFingerprint,
              window.analysisAnchor >= (ticket.replayOrigin ?? ticket.checkpoint?.sourceFrame ?? 0),
              window.coreFrames.start >= (ticket.checkpoint?.sourceFrame ?? 0), window.analysisAnchor <= window.contextFrames.start,
              window.coreFrames.end <= (ticket.boundary.endFrame ?? .max),
              window.contextFrames.start <= window.coreFrames.start, window.contextFrames.end >= window.coreFrames.end,
              window.modelContextFrames.start <= window.modelCoreFrames.start, window.modelContextFrames.end >= window.modelCoreFrames.end else { throw ArchiveError.invalidTranscript }
        let expected = try ticket.inputs.compactMap { input -> ArchiveWindowSource? in
            let manifest = input.envelope.manifest
            let start = max(manifest.frames.start, window.contextFrames.start), end = min(manifest.frames.end, window.contextFrames.end)
            guard end > start else { return nil }
            return ArchiveWindowSource(chunkID: manifest.chunkID, manifestSHA256: input.envelope.manifestSHA256,
                                       audioSHA256: manifest.audioSHA256, sourceFrames: try FrameRange(start: start, count: end - start))
        }
        let replayHashes = ticket.inputs.filter {
            $0.envelope.manifest.frames.end > window.analysisAnchor && $0.envelope.manifest.frames.start < window.contextFrames.end
        }.map { $0.envelope.manifestSHA256 }
        guard !expected.isEmpty, expected == window.sources, replayHashes == window.replayInputManifestHashes,
              covers(window.contextFrames, with: expected.map(\.sourceFrames)) else { throw ArchiveError.invalidTranscript }
    }

    func contiguousInputs(epochID: UUID, from start: Int64, through end: Int64? = nil) throws -> [ArchivedAudioInput] {
        let all = try database.rows("""
            SELECT manifest,manifest_hash,relative_path FROM chunks WHERE epoch_id=? AND retention='present'
            AND end_frame > ? AND start_frame < ?
            ORDER BY start_frame
            """, [.text(epochID.uuidString), .integer(start), .integer(end ?? .max)]).map { row in
            ArchivedAudioInput(envelope: try ManifestEnvelope(manifestData: row.requireData(0), manifestSHA256: row.requireString(1)), audioURL: rootURL.appendingPathComponent(try row.requireString(2)))
        }
        var cursor = start
        var result: [ArchivedAudioInput] = []
        for input in all {
            let range = input.envelope.manifest.frames
            if range.end <= start { continue }
            if let end, range.start >= end { break }
            guard range.start <= cursor, range.end > cursor else { break }
            result.append(input); cursor = range.end
        }
        return result
    }

    func leaseInputs(_ inputs: [ArchivedAudioInput]) throws -> [UUID] {
        var leases: [UUID] = []
        do {
            for input in inputs { leases.append(try acquireAudioLease(chunkID: input.envelope.manifest.chunkID).id) }
            return leases
        } catch {
            for lease in leases { audioLeases.removeValue(forKey: lease) }
            throw error
        }
    }

    func updateCompletedChunks(epochID: UUID, configurationFingerprint: String) throws {
        let candidates = try database.rows("""
            SELECT c.id,c.start_frame,c.end_frame FROM chunks c JOIN transcription_jobs j ON j.chunk_id=c.id
            WHERE c.epoch_id=? AND j.state NOT IN ('complete','superseded')
            """, [.text(epochID.uuidString)])
        guard !candidates.isEmpty else { return }
        let coverage = try analyzedRanges(epochID: epochID, fingerprint: configurationFingerprint)
        let pending = try database.rows("SELECT context_start,context_end FROM analysis_windows WHERE epoch_id=? AND configuration_hash=? AND state!='complete'", [.text(epochID.uuidString), .text(configurationFingerprint)]).map {
            let start = try $0.requireInt(0), end = try $0.requireInt(1)
            return try FrameRange(start: start, count: end - start)
        }
        // Build the completed union once per commit. Sorting every historical coverage
        // row for every chunk makes a long recording progressively more expensive.
        // Pending context (not just its core) must still protect each intersecting chunk.
        let completed = try CoverageRanges.subtract(coverage, pending)
        for row in candidates {
            let start = try row.requireInt(1), end = try row.requireInt(2)
            if completed.contains(where: { $0.start <= start && $0.end >= end }) {
                try database.execute("UPDATE transcription_jobs SET state='complete',attempt_id=NULL WHERE chunk_id=? AND state NOT IN ('complete','superseded')", [.text(try row.requireString(0))])
            }
        }
    }

    func pendingWindowNeeds(_ manifest: ChunkManifest) throws -> Bool {
        try !database.rows("""
            SELECT 1 FROM analysis_windows
            WHERE epoch_id=? AND state IN ('pending','running') AND analysis_anchor < ? AND context_end > ?
            LIMIT 1
            """, [.text(manifest.epochID.uuidString), .integer(manifest.frames.end), .integer(manifest.frames.start)]).isEmpty
    }

    func spanID(windowID: String) throws -> UUID {
        let hash = String(windowID.prefix(32))
        guard hash.count == 32 else { throw ArchiveError.invalidTranscript }
        let chunks = [8,4,4,4,12]
        var cursor = hash.startIndex, pieces: [String] = []
        for count in chunks { let end = hash.index(cursor, offsetBy: count); pieces.append(String(hash[cursor..<end])); cursor = end }
        guard let id = UUID(uuidString: pieces.joined(separator: "-")) else { throw ArchiveError.invalidTranscript }
        return id
    }

    func covers(_ range: FrameRange, with ranges: [FrameRange]) -> Bool {
        var cursor = range.start
        for part in ranges.sorted(by: { $0.start < $1.start }) {
            if part.end <= cursor { continue }
            if part.start > cursor { return false }
            cursor = part.end
            if cursor >= range.end { return true }
        }
        return false
    }
    func overlaps(_ lhs: FrameRange, _ rhs: FrameRange) -> Bool { lhs.start < rhs.end && rhs.start < lhs.end }
}

func analysisInputIdentity(_ inputs: [ArchivedAudioInput], start: Int64, boundary: AudioProcessingBoundary) throws -> String {
    guard let last = inputs.last else { throw ArchiveError.invalidTranscript }
    return ContentHash.sha256(try WireJSON.encode(AnalysisIdentity(hashes: inputs.map { $0.envelope.manifestSHA256 },
        closed: boundary.endFrame != nil, start: start,
        end: boundary.endFrame == last.envelope.manifest.frames.end ? nil : boundary.endFrame)))
}

private struct AnalysisIdentity: Codable { let hashes: [String]; let closed: Bool; let start: Int64; let end: Int64? }
