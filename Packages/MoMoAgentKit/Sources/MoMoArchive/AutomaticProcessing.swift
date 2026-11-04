import Foundation
import MoMoContracts

public enum AutomaticProcessingWork: Sendable {
    case analysis(EpochAnalysisTicket)
    case transcription(TranscriptionWindowTicket)
}

public struct LivePriorityWorkSummary: Sendable, Equatable {
    public let hasHotLiveWork: Bool
    public let hasUltraHotLiveWork: Bool
    public let hasTodayUnreservedWork: Bool
    public let hotPendingSeconds: Double

    public init(hasHotLiveWork: Bool, hasTodayUnreservedWork: Bool, hotPendingSeconds: Double,
                hasUltraHotLiveWork: Bool = false) {
        self.hasHotLiveWork = hasHotLiveWork
        self.hasUltraHotLiveWork = hasUltraHotLiveWork
        self.hasTodayUnreservedWork = hasTodayUnreservedWork
        self.hotPendingSeconds = hotPendingSeconds
    }

    public var hasAnyPriorityWork: Bool { hasHotLiveWork || hasTodayUnreservedWork }
}

extension ArchiveStore {
    /// Both stages compete here, so a historical window cannot outrank today's analysis.
    public func claimAutomaticWork(configurationFingerprint: String, inputLease: TranscriptionInputLease? = nil,
                                   allowHistorical: Bool = true, hotOnly: Bool = false,
                                   focusedDay: TimelineDay? = nil, now: Date = Date(),
                                   calendar: Calendar = .current,
                                   activeAnalysis: EpochAnalysisTicket? = nil) throws -> AutomaticProcessingWork? {
        try claimAutomatic(configurationFingerprint: configurationFingerprint, inputLease: inputLease,
            allowHistorical: allowHistorical, hotOnly: hotOnly, focusedDay: focusedDay,
            now: now, calendar: calendar, activeWindow: nil, activeAnalysis: activeAnalysis)
    }

    /// Shares the ordinary scheduler, with at most one additional registered analysis batch.
    public func claimAutomaticAnalysis(configurationFingerprint: String, activeWindow: ArchiveAnalysisWindow,
                                       allowHistorical: Bool = true, hotOnly: Bool = false,
                                       focusedDay: TimelineDay? = nil, now: Date = Date(),
                                       calendar: Calendar = .current) throws -> EpochAnalysisTicket? {
        let work = try claimAutomatic(configurationFingerprint: configurationFingerprint, inputLease: nil,
            allowHistorical: allowHistorical, hotOnly: hotOnly, focusedDay: focusedDay,
            now: now, calendar: calendar, activeWindow: activeWindow, activeAnalysis: nil)
        if case .analysis(let ticket)? = work { return ticket }
        return nil
    }

    /// Summarizes unreserved priority-0 work, separating the recent 5-minute live hot window from earlier same-day backlog.
    public func livePriorityWorkSummary(configurationFingerprint: String, now: Date = Date(),
                                        calendar: Calendar = .current) throws -> LivePriorityWorkSummary {
        guard ContentHash.isValid(configurationFingerprint), now.timeIntervalSince1970.isFinite else {
            return LivePriorityWorkSummary(hasHotLiveWork: false, hasTodayUnreservedWork: false, hotPendingSeconds: 0)
        }
        let policy = ProcessingDatePolicy(now: now, calendar: calendar)
        var hasHotLive = false
        var hasUltraHot = false
        var hasToday = false
        var hotSeconds = 0.0
        for row in try database.rows("""
            SELECT e.id,e.session_id,s.generation,c.manifest,a.attempt_id,a.last_input_hash,a.checkpoint
            FROM epochs e JOIN sessions s ON s.id=e.session_id
            JOIN chunks c ON c.rowid=COALESCE(e.min_chunk_rowid, (SELECT rowid FROM chunks WHERE epoch_id=e.id ORDER BY start_frame LIMIT 1))
            LEFT JOIN analysis_epochs a ON a.epoch_id=e.id AND a.configuration_hash=?
            WHERE s.deleted=0 AND s.projection_blocked=0 AND (a.epoch_id IS NULL OR a.has_pending=1
              OR EXISTS(SELECT 1 FROM analysis_windows w WHERE w.epoch_id=e.id AND w.configuration_hash=? AND w.state='pending'))
            ORDER BY e.rowid
            """, [.text(configurationFingerprint), .text(configurationFingerprint)]) {
            let epochID = try row.requireUUID(0)
            let generation = try row.requireInt(2)
            let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(3))
            let rate = manifest.timebaseHz
            guard rate.isFinite, rate > 0 else { continue }
            for windowRow in try database.rows("""
                SELECT w.descriptor FROM analysis_windows w
                WHERE w.epoch_id=? AND w.configuration_hash=? AND w.generation=?
                  AND w.state='pending'
                  AND NOT EXISTS(SELECT 1 FROM processing_failures f WHERE f.epoch_id=w.epoch_id
                    AND f.configuration_hash=w.configuration_hash AND f.generation=w.generation
                    AND f.stage='transcription' AND f.work_id=w.id
                    AND (f.error_code='audio_unavailable' OR f.retry_after>?))
                  AND NOT EXISTS(SELECT 1 FROM transcription_batch_windows m JOIN transcription_batches b ON b.id=m.batch_id
                    WHERE m.epoch_id=w.epoch_id AND b.state!='completed'
                    AND m.start_frame<w.core_end AND m.end_frame>w.core_start)
                ORDER BY w.rowid
                """, [.text(epochID.uuidString), .text(configurationFingerprint), .integer(generation), .double(now.timeIntervalSince1970)]) {
                let window = try WireJSON.decode(ArchiveAnalysisWindow.self, from: windowRow.requireData(0))
                guard policy.priority(window.coreFrames, manifest: manifest) == 0 else { continue }
                if try !batchReserves(window) && windowHasRetainedContextInputs(window) {
                    hasToday = true
                    if policy.isHotLive(window.coreFrames, manifest: manifest) {
                        hasHotLive = true
                        hotSeconds += Double(window.coreFrames.count) / rate
                        if policy.isUltraHotLive(window.coreFrames, manifest: manifest) {
                            hasUltraHot = true
                        }
                    }
                }
            }
            guard row.string(4) == nil, try !batchReservesAnalysis(epochID: epochID) else { continue }
            let pendingRanges = try pendingAnalysisRanges(epochID: epochID, fingerprint: configurationFingerprint, retainedOnly: true)
            let receivedEnd = try receivedAnalysisRanges(epochID: epochID, retainedOnly: false).last?.end
            let closedFrame = try analysisClosedFrame(epochID: epochID)
            for range in pendingRanges {
                for segment in try policy.splitForScheduling(range, manifest: manifest, focusedDay: nil) where segment.priority == 0 {
                    let frames = segment.frames
                    let inputs = try contiguousInputs(epochID: epochID, from: frames.start, through: frames.end)
                    guard let last = inputs.last else { continue }
                    let examined = try database.rows(
                        "SELECT input_hash FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=? AND generation=? AND start_frame=?",
                        [.text(epochID.uuidString), .text(configurationFingerprint), .integer(generation), .integer(frames.start)]
                    ).first?.string(0)
                    let boundary: AudioProcessingBoundary
                    if frames.end <= last.envelope.manifest.frames.end, frames.end < (receivedEnd ?? frames.end) {
                        boundary = .processingRange(frames.end)
                    } else if let closedFrame, closedFrame == last.envelope.manifest.frames.end {
                        boundary = .captureEnd(closedFrame)
                    } else if last.envelope.manifest.sealedAt < now.addingTimeInterval(-1_800),
                              last.envelope.manifest.frames.end >= frames.end {
                        boundary = .receivedSnapshot(min(frames.end, last.envelope.manifest.frames.end))
                    } else {
                        boundary = .open
                    }
                    let identity = try analysisInputIdentity(inputs, start: frames.start, boundary: boundary)
                    if examined == identity || row.string(5) == identity { continue }
                    if try processingIsDeferred(epochID: epochID, generation: generation, fingerprint: configurationFingerprint,
                                                stage: .analysis, workID: identity, now: now) { continue }
                    hasToday = true
                    if segment.tier == 0 {
                        hasHotLive = true
                        let runnableEnd = min(frames.end, last.envelope.manifest.frames.end)
                        if runnableEnd > frames.start {
                            hotSeconds += Double(runnableEnd - frames.start) / rate
                            if let runnableRange = try? FrameRange(start: frames.start, count: runnableEnd - frames.start),
                               policy.isUltraHotLive(runnableRange, manifest: manifest) {
                                hasUltraHot = true
                            }
                        }
                    }
                }
            }
        }
        return LivePriorityWorkSummary(hasHotLiveWork: hasHotLive, hasTodayUnreservedWork: hasToday,
                                       hotPendingSeconds: hotSeconds, hasUltraHotLiveWork: hasUltraHot)
    }

    public func isHotLiveWindow(_ window: ArchiveAnalysisWindow, now: Date = Date(),
                                calendar: Calendar = .current) throws -> Bool {
        guard let row = try database.rows(
            "SELECT c.manifest FROM epochs e JOIN chunks c ON c.rowid=COALESCE(e.min_chunk_rowid, (SELECT rowid FROM chunks WHERE epoch_id=e.id ORDER BY start_frame LIMIT 1)) WHERE e.id=?",
            [.text(window.epochID.uuidString)]
        ).first else { return false }
        let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(0))
        return ProcessingDatePolicy(now: now, calendar: calendar).isHotLive(window.coreFrames, manifest: manifest)
    }

    public nonisolated func isHotLiveAnalysis(_ ticket: EpochAnalysisTicket, now: Date = Date(),
                                              calendar: Calendar = .current) -> Bool {
        guard let first = ticket.inputs.first, let last = ticket.inputs.last else { return false }
        let start = ticket.checkpoint?.sourceFrame ?? first.envelope.manifest.frames.start
        let end = min(last.envelope.manifest.frames.end, ticket.boundary.endFrame ?? .max)
        guard end > start, let range = try? FrameRange(start: start, count: end - start) else { return false }
        return ProcessingDatePolicy(now: now, calendar: calendar).isHotLive(range, manifest: first.envelope.manifest)
    }

    /// Returns true when today's / recent live audio (`priority == 0`) has runnable work outside any active batch,
    /// allowing the foreground runtime to prioritize live recordings ahead of older frozen historical batches.
    public func hasUnreservedPriorityWork(configurationFingerprint: String, now: Date = Date(),
                                          calendar: Calendar = .current) throws -> Bool {
        try livePriorityWorkSummary(configurationFingerprint: configurationFingerprint, now: now, calendar: calendar).hasAnyPriorityWork
    }

    private func claimAutomatic(configurationFingerprint: String, inputLease: TranscriptionInputLease?,
                                allowHistorical: Bool, hotOnly: Bool, focusedDay: TimelineDay?,
                                now: Date, calendar: Calendar,
                                activeWindow: ArchiveAnalysisWindow?, activeAnalysis: EpochAnalysisTicket?) throws -> AutomaticProcessingWork? {
        guard ContentHash.isValid(configurationFingerprint), now.timeIntervalSince1970.isFinite else { throw ArchiveError.invalidQuery }
        let policy = ProcessingDatePolicy(now: now, calendar: calendar)
        let analysisTier: Int?
        if let activeAnalysis, let first = activeAnalysis.inputs.first, let last = activeAnalysis.inputs.last {
            let start = activeAnalysis.checkpoint?.sourceFrame ?? first.envelope.manifest.frames.start
            let end = min(last.envelope.manifest.frames.end, activeAnalysis.boundary.endFrame ?? .max)
            let range = try FrameRange(start: start, count: end - start)
            analysisTier = policy.freshnessTier(range, manifest: first.envelope.manifest, focusedDay: focusedDay)
        } else { analysisTier = nil }
        var candidates: [AutomaticCandidate] = []
        var batches: [Int: Set<String>] = [:]
        var activeTier = 3
        for row in try database.rows("""
            SELECT e.id,e.session_id,s.generation,c.manifest,COALESCE(t.last_turn,0),a.attempt_id,e.rowid
            FROM epochs e JOIN sessions s ON s.id=e.session_id
            JOIN chunks c ON c.rowid=COALESCE(e.min_chunk_rowid, (SELECT rowid FROM chunks WHERE epoch_id=e.id ORDER BY start_frame LIMIT 1))
            LEFT JOIN processing_turns t ON t.epoch_id=e.id AND t.configuration_hash=?
            LEFT JOIN analysis_epochs a ON a.epoch_id=e.id AND a.configuration_hash=?
            WHERE s.deleted=0 AND s.projection_blocked=0 AND (a.epoch_id IS NULL OR a.has_pending=1
              OR EXISTS(SELECT 1 FROM analysis_windows w WHERE w.epoch_id=e.id AND w.configuration_hash=? AND w.state='pending')
              OR e.id=?) ORDER BY e.rowid
            """, [.text(configurationFingerprint), .text(configurationFingerprint), .text(configurationFingerprint), activeWindow.map { .text($0.epochID.uuidString) } ?? .null]) {
            let epochID = try row.requireUUID(0), sessionID = try row.requireUUID(1)
            let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(3))
            let turn = try row.requireInt(4)
            let epochRowID = try row.requireInt(6)
            if let activeWindow, activeWindow.epochID == epochID {
                activeTier = policy.freshnessTier(activeWindow.coreFrames, manifest: manifest, focusedDay: focusedDay)
                batches[activeTier, default: []].insert("\(epochID)/\(activeWindow.analysisAnchor)")
            }
            for window in try database.rows("""
                SELECT w.id,w.core_start,w.core_end - w.core_start,w.analysis_anchor
                FROM analysis_windows w WHERE w.epoch_id=? AND w.configuration_hash=? AND w.generation=?
                  AND w.state='pending'
                  AND NOT EXISTS(SELECT 1 FROM processing_failures f WHERE f.epoch_id=w.epoch_id
                    AND f.configuration_hash=w.configuration_hash AND f.generation=w.generation
                    AND f.stage='transcription' AND f.work_id=w.id AND f.error_code!='audio_unavailable' AND f.retry_after>?)
                  AND NOT EXISTS(SELECT 1 FROM transcription_batch_windows m JOIN transcription_batches b ON b.id=m.batch_id
                    WHERE m.epoch_id=w.epoch_id AND b.state!='completed'
                    AND m.start_frame<w.core_end
                    AND m.end_frame>w.core_start)
                ORDER BY w.rowid
                """, [.text(epochID.uuidString), .text(configurationFingerprint), .integer(try row.requireInt(2)), .double(now.timeIntervalSince1970)]) {
                let frames = try FrameRange(start: window.requireInt(1), count: window.requireInt(2))
                let priority = policy.priority(frames, manifest: manifest)
                let tier = policy.freshnessTier(frames, manifest: manifest, focusedDay: focusedDay)
                batches[tier, default: []].insert("\(epochID)/\(try window.requireInt(3))")
                candidates.append(AutomaticCandidate(epochID: epochID, epochRowID: epochRowID, sessionID: sessionID,
                    generation: try row.requireInt(2), priority: priority, tier: tier, turn: turn,
                    recordedAt: manifest.wallClockAnchor, frames: frames, windowID: try window.requireString(0)))
            }
            guard row.string(5) == nil else { continue }
            let pendingRanges = try pendingAnalysisRanges(epochID: epochID, fingerprint: configurationFingerprint, retainedOnly: true)
            if pendingRanges.isEmpty {
                try database.execute("UPDATE analysis_epochs SET has_pending=0 WHERE epoch_id=? AND configuration_hash=?",
                    [.text(epochID.uuidString), .text(configurationFingerprint)])
            }
            for range in pendingRanges {
                for segment in try policy.splitForScheduling(range, manifest: manifest, focusedDay: focusedDay) {
                    candidates.append(AutomaticCandidate(epochID: epochID, epochRowID: epochRowID, sessionID: sessionID,
                        generation: try row.requireInt(2), priority: segment.priority, tier: segment.tier, turn: turn,
                        recordedAt: manifest.wallClockAnchor, frames: segment.frames, windowID: nil))
                }
            }
        }
        candidates.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.turn != $1.turn { return $0.turn < $1.turn }
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            if $0.epochRowID != $1.epochRowID { return $0.epochRowID < $1.epochRowID }
            if $0.epochID != $1.epochID { return $0.epochID.uuidString < $1.epochID.uuidString }
            if ($0.windowID != nil) != ($1.windowID != nil) { return $0.windowID != nil }
            return $0.frames.start < $1.frames.start
        }
        let prefetchTier = min(activeTier, candidates.filter { $0.windowID != nil }.map(\.tier).min() ?? 3)
        for candidate in candidates {
            guard !hotOnly || candidate.tier == 0 else { continue }
            guard allowHistorical || candidate.priority == 0 else { continue }
            if let analysisTier, candidate.tier > analysisTier { continue }
            // Equal-tier snapshots finish their bounded claim; alternating unstarted producers would livelock.
            if let analysisTier, candidate.windowID == nil, candidate.tier == analysisTier { continue }
            if activeWindow != nil {
                guard candidate.windowID == nil, candidate.tier <= prefetchTier,
                      (batches[candidate.tier]?.count ?? 0) < 2 else { continue }
            }
            let work: AutomaticProcessingWork
            if let windowID = candidate.windowID {
                guard let ticket = try claimTranscriptionWindow(configurationFingerprint: configurationFingerprint,
                    inputLease: inputLease, isolateLocalFailures: true, selectedWindowID: windowID, now: now) else { continue }
                work = .transcription(ticket)
            } else {
                guard let ticket = try claimEpochAnalysis(configurationFingerprint: configurationFingerprint,
                    sessionID: candidate.sessionID, expectedGeneration: candidate.generation,
                    finalizeAvailablePrefixBefore: now.addingTimeInterval(-1_800), isolateLocalFailures: true,
                    selectedEpochID: candidate.epochID, processingRange: candidate.frames, now: now) else { continue }
                work = .analysis(ticket)
            }
            do {
                try database.execute("""
                    INSERT INTO processing_turns(epoch_id,configuration_hash,last_turn)
                    VALUES(?,?,(SELECT COALESCE(MAX(last_turn),0)+1 FROM processing_turns))
                    ON CONFLICT(epoch_id,configuration_hash) DO UPDATE SET last_turn=excluded.last_turn
                    """, [.text(candidate.epochID.uuidString), .text(configurationFingerprint)])
            } catch {
                switch work {
                case .analysis(let ticket): try cancelEpochAnalysis(ticket: ticket)
                case .transcription(let ticket): try cancelTranscriptionWindow(ticket: ticket)
                }
                throw error
            }
            return work
        }
        return nil
    }

    func receivedAnalysisRanges(epochID: UUID, retainedOnly: Bool) throws -> [FrameRange] {
        try CoverageRanges.union(database.rows("""
            SELECT start_frame, end_frame - start_frame
            FROM chunks WHERE epoch_id=? AND (?=0 OR retention='present')
            ORDER BY start_frame
            """, [.text(epochID.uuidString), .integer(retainedOnly ? 1 : 0)]).map {
                try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1))
            })
    }

    func analyzedRanges(epochID: UUID, fingerprint: String) throws -> [FrameRange] {
        try CoverageRanges.union(database.rows("SELECT start_frame,end_frame FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=? AND kind='analyzed'",
            [.text(epochID.uuidString), .text(fingerprint)]).map { try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0)) })
    }

    func pendingAnalysisRanges(epochID: UUID, fingerprint: String, retainedOnly: Bool) throws -> [FrameRange] {
        try CoverageRanges.subtract(receivedAnalysisRanges(epochID: epochID, retainedOnly: retainedOnly),
            analyzedRanges(epochID: epochID, fingerprint: fingerprint))
    }
}

private struct AutomaticCandidate {
    let epochID: UUID
    let epochRowID: Int64
    let sessionID: UUID
    let generation: Int64
    let priority: Int
    let tier: Int
    let turn: Int64
    let recordedAt: Date
    let frames: FrameRange
    let windowID: String?
}

/// Classification follows the recorded local day; recent UTC time protects the midnight handoff.
struct ProcessingDatePolicy {
    static let hotWindowSeconds: TimeInterval = 300
    static let hotCutQuantumSeconds: TimeInterval = 120
    static let ultraHotWindowSeconds: TimeInterval = 180

    let now: Date
    let today: TimelineDay

    init(now: Date, calendar: Calendar) { self.now = now; today = TimelineDay(now, calendar: calendar) }

    var quantizedHotCutoff: Date {
        let raw = now.timeIntervalSince1970 - Self.hotWindowSeconds
        let quantized = floor(raw / Self.hotCutQuantumSeconds) * Self.hotCutQuantumSeconds
        return Date(timeIntervalSince1970: quantized)
    }

    func isHotLive(_ frames: FrameRange, manifest: ChunkManifest) -> Bool {
        let end = manifest.wallClockAnchor.addingTimeInterval(Double(frames.end) / manifest.timebaseHz)
        return end > quantizedHotCutoff
    }

    func isUltraHotLive(_ frames: FrameRange, manifest: ChunkManifest) -> Bool {
        let end = manifest.wallClockAnchor.addingTimeInterval(Double(frames.end) / manifest.timebaseHz)
        return end > now.addingTimeInterval(-Self.ultraHotWindowSeconds)
    }

    func overlapsDay(_ day: TimelineDay, frames: FrameRange, manifest: ChunkManifest) -> Bool {
        let start = manifest.wallClockAnchor.addingTimeInterval(Double(frames.start) / manifest.timebaseHz)
        let end = manifest.wallClockAnchor.addingTimeInterval(Double(frames.end) / manifest.timebaseHz)
        let recordedStart = start.timeIntervalSince1970 + Double(manifest.timezoneOffset)
        let recordedEnd = end.timeIntervalSince1970 + Double(manifest.timezoneOffset)
        let dayStart = day.date(calendar: TimelineDay.calendar).timeIntervalSince1970
        let dayEnd = day.adding(days: 1).date(calendar: TimelineDay.calendar).timeIntervalSince1970
        return recordedStart < dayEnd && recordedEnd > dayStart
    }

    /// 4-tier freshness: `0` = last 15–20m hot live, `1` = user-focused historical day, `2` = earlier today, `3` = other history.
    func freshnessTier(_ frames: FrameRange, manifest: ChunkManifest, focusedDay: TimelineDay? = nil) -> Int {
        if isHotLive(frames, manifest: manifest) { return 0 }
        if let focusedDay, focusedDay != today, overlapsDay(focusedDay, frames: frames, manifest: manifest) { return 1 }
        return priority(frames, manifest: manifest) == 0 ? 2 : 3
    }

    func priority(_ frames: FrameRange, manifest: ChunkManifest) -> Int {
        let start = manifest.wallClockAnchor.addingTimeInterval(Double(frames.start) / manifest.timebaseHz)
        let end = manifest.wallClockAnchor.addingTimeInterval(Double(frames.end) / manifest.timebaseHz)
        let localStart = today.date(calendar: TimelineDay.calendar).timeIntervalSince1970
        let recordedStart = start.timeIntervalSince1970 + Double(manifest.timezoneOffset)
        let recordedEnd = end.timeIntervalSince1970 + Double(manifest.timezoneOffset)
        let dayEnd = today.adding(days: 1).date(calendar: TimelineDay.calendar).timeIntervalSince1970
        return (recordedStart < dayEnd && recordedEnd > localStart)
            || end > now.addingTimeInterval(-1_800) ? 0 : 1
    }

    func split(_ range: FrameRange, manifest: ChunkManifest) throws -> [(FrameRange, Int)] {
        let base = manifest.wallClockAnchor.timeIntervalSince1970
        let localBase = base + Double(manifest.timezoneOffset)
        let dayStart = today.date(calendar: TimelineDay.calendar).timeIntervalSince1970
        let dayEnd = today.adding(days: 1).date(calendar: TimelineDay.calendar).timeIntervalSince1970
        // Already-received audio must not chase a moving `now` cut when the Watch
        // clock is ahead or its recorded timezone differs from the phone's day.
        let boundaries = [(dayStart - localBase), (dayEnd - localBase), (now.timeIntervalSince1970 - 1_800 - base)]
        var cuts = [range.start, range.end]
        for seconds in boundaries {
            let frame = (seconds * manifest.timebaseHz).rounded(.up)
            if frame.isFinite, frame > Double(range.start), frame < Double(range.end), frame < Double(Int64.max) {
                cuts.append(Int64(frame))
            }
        }
        cuts = Array(Set(cuts)).sorted()
        var result: [(FrameRange, Int)] = []
        for (start, end) in zip(cuts, cuts.dropFirst()) {
            let frames = try FrameRange(start: start, count: end - start), level = priority(frames, manifest: manifest)
            if let last = result.last, last.1 == level {
                result[result.count - 1] = (try FrameRange(start: last.0.start, count: end - last.0.start), level)
            } else { result.append((frames, level)) }
        }
        return result
    }

    func splitForScheduling(_ range: FrameRange, manifest: ChunkManifest,
                            focusedDay: TimelineDay? = nil) throws -> [(frames: FrameRange, priority: Int, tier: Int)] {
        let base = manifest.wallClockAnchor.timeIntervalSince1970
        let localBase = base + Double(manifest.timezoneOffset)
        let dayStart = today.date(calendar: TimelineDay.calendar).timeIntervalSince1970
        let dayEnd = today.adding(days: 1).date(calendar: TimelineDay.calendar).timeIntervalSince1970
        var boundaries = [(dayStart - localBase), (dayEnd - localBase), (now.timeIntervalSince1970 - 1_800 - base)]
        if manifest.sampleRate == 16_000 {
            boundaries.append(quantizedHotCutoff.timeIntervalSince1970 - base)
        }
        if let focusedDay, focusedDay != today {
            let focusedStart = focusedDay.date(calendar: TimelineDay.calendar).timeIntervalSince1970
            let focusedEnd = focusedDay.adding(days: 1).date(calendar: TimelineDay.calendar).timeIntervalSince1970
            boundaries.append(focusedStart - localBase)
            boundaries.append(focusedEnd - localBase)
        }
        var cuts = [range.start, range.end]
        for seconds in boundaries {
            let frame = (seconds * manifest.timebaseHz).rounded(.up)
            if frame.isFinite, frame > Double(range.start), frame < Double(range.end), frame < Double(Int64.max) {
                cuts.append(Int64(frame))
            }
        }
        cuts = Array(Set(cuts)).sorted()
        var result: [(frames: FrameRange, priority: Int, tier: Int)] = []
        for (start, end) in zip(cuts, cuts.dropFirst()) {
            let frames = try FrameRange(start: start, count: end - start)
            let level = priority(frames, manifest: manifest)
            let tier = freshnessTier(frames, manifest: manifest, focusedDay: focusedDay)
            if let last = result.last, last.priority == level, last.tier == tier {
                result[result.count - 1] = (try FrameRange(start: last.frames.start, count: end - last.frames.start), level, tier)
            } else {
                result.append((frames, level, tier))
            }
        }
        return result
    }
}
