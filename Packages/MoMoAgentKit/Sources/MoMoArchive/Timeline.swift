import Darwin
import Foundation
import MoMoContracts

public struct TimelineReadRevision: Equatable, Sendable {
    let local: UInt64
    let external: Int64
}

extension ArchiveStore {
    /// Reading a date need not rescan audio when only receipts or device status changed.
    public func timelineReadRevision() throws -> TimelineReadRevision {
        try Task.checkCancellation()
        return TimelineReadRevision(local: database.timelineRevision,
            external: try database.rows("PRAGMA data_version").first?.requireInt(0) ?? 0)
    }

    /// Query the entire selected date before grouping. Session-list pagination never truncates a window.
    public func timelineDay(_ day: TimelineDay, configurationFingerprint: String? = nil) throws -> [TimelineWindow] {
        try timelineDaySnapshot(day, configurationFingerprint: configurationFingerprint).windows
    }

    public func timelineDaySnapshot(_ day: TimelineDay, configurationFingerprint: String? = nil) throws -> TimelineDaySnapshot {
        let startedMs = APIPerformanceMonitor.uptimeMilliseconds()
        do {
            let snapshot = try timelineDaySnapshotImpl(day, configurationFingerprint: configurationFingerprint)
            performanceMonitor.record(.timelineDaySnapshot, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: snapshot.windows.count)
            return snapshot
        } catch {
            if !(error is CancellationError) {
                performanceMonitor.record(.timelineDaySnapshot, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: 0, failed: true)
            }
            throw error
        }
    }

    private func timelineDaySnapshotImpl(_ day: TimelineDay, configurationFingerprint: String? = nil) throws -> TimelineDaySnapshot {
        try Task.checkCancellation()
        #if DEBUG
        timelineDayBuildCount += 1
        #endif
        let rootPrefix = rootURL.standardizedFileURL.path + "/"
        let localStart = day.startDate(calendar: TimelineDay.calendar).timeIntervalSince1970
        let localEnd = day.adding(days: 1).startDate(calendar: TimelineDay.calendar).timeIntervalSince1970
        let rows = try database.rows("""
            SELECT c.manifest FROM epochs e
            JOIN sessions s ON s.id=e.session_id
            JOIN chunks c ON c.rowid=COALESCE(e.min_chunk_rowid, (SELECT rowid FROM chunks WHERE epoch_id=e.id ORDER BY start_frame LIMIT 1))
            LEFT JOIN epoch_closures ec ON ec.epoch_id=e.id
            WHERE s.deleted=0 AND e.wall_clock_anchor IS NOT NULL
              AND (e.wall_clock_anchor + COALESCE(e.timezone_offset, 0)) < ?
              AND (e.wall_clock_anchor + COALESCE(e.timezone_offset, 0)
                   + MAX(COALESCE(ec.end_frame, 0), e.max_received_end_frame) / e.timebase) > ?
            """, [.double(localEnd + 0.001), .double(localStart - 0.001)])
        var slices: [TimelineBuilder] = []
        var coverages: [UUID: RecordingCoverage] = [:]
        var documents: [UUID: TranscriptDocument] = [:]
        var summaries: [UUID: RecordingSummary] = [:]
        var receivedSeconds = 0.0, processedSeconds = 0.0, unavailableSeconds = 0.0, awaitingSyncSeconds = 0.0
        for row in rows {
            try Task.checkCancellation()
            let anchor = try WireJSON.decode(ChunkManifest.self, from: row.requireData(0))
            let sessionID = anchor.sessionID
            let summary: RecordingSummary
            if let cached = summaries[sessionID] { summary = cached }
            else {
                summary = try recordingSummary(sessionID: sessionID)
                summaries[sessionID] = summary
            }
            let coverage: RecordingCoverage
            if let cached = coverages[sessionID] { coverage = cached }
            else {
                coverage = try recordingCoverage(sessionID: sessionID, configurationFingerprint: configurationFingerprint)
                coverages[sessionID] = coverage
                let blocked = try database.rows("SELECT projection_blocked FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.integer(0) == 1
                if !blocked, let document = try currentTranscriptOrNil(sessionID: sessionID) { documents[sessionID] = document }
            }
            guard let epoch = coverage.epochs.first(where: { $0.epochID == anchor.epochID }),
                  epoch.observedThroughFrame > 0 else { continue }
            struct TimelineChunkMeta {
                let chunkID: UUID
                let frames: FrameRange
            }
            let chunkRows = try database.rows("SELECT c.id,c.start_frame,c.end_frame,c.retention,c.relative_path,j.state,j.error_code FROM chunks c LEFT JOIN transcription_jobs j ON j.chunk_id=c.id WHERE c.epoch_id=? ORDER BY c.start_frame", [.text(anchor.epochID.uuidString)])
            let chunks = try chunkRows.map { row -> TimelineChunkMeta in
                try Task.checkCancellation()
                let startFrame = try row.requireInt(1)
                let endFrame = try row.requireInt(2)
                return TimelineChunkMeta(chunkID: try row.requireUUID(0),
                    frames: try FrameRange(start: startFrame, count: endFrame - startFrame))
            }
            let speechWindows = try database.rows("SELECT core_start,core_end FROM analysis_windows WHERE epoch_id=? AND configuration_hash=?",
                [.text(anchor.epochID.uuidString), configurationFingerprint.map(SQLValue.text) ?? .null])
                .map { try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0)) }
            let discardedWindows = try database.rows("SELECT core_start,core_end FROM analysis_windows WHERE epoch_id=? AND state='complete' AND raw_result=?",
                [.text(anchor.epochID.uuidString), .blob(TranscriptText.discardedPunctuation)])
                .map { try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0)) }
            let byID = Dictionary(uniqueKeysWithValues: chunks.enumerated().map { ($0.element.chunkID, $0.offset) })
            let base = anchor.wallClockAnchor.timeIntervalSince1970
            let rate = anchor.timebaseHz
            let offset = Double(anchor.timezoneOffset)
            let knownEnd = base + Double(epoch.observedThroughFrame) / rate
            let lower = max(base, localStart - offset)
            let upper = min(knownEnd, localEnd - offset)
            guard upper > lower else { continue }
            let firstFrame = max(0, Int64(((lower - base) * rate).rounded(.up)))
            let throughFrame = min(epoch.observedThroughFrame, Int64(((upper - base) * rate).rounded(.up)))
            guard throughFrame > firstFrame else { continue }
            let dayFrames = try FrameRange(start: firstFrame, count: throughFrame - firstFrame)
            func seconds(_ ranges: [FrameRange]) throws -> Double {
                try CoverageRanges.intersection(ranges, [dayFrames]).reduce(0) { $0 + Double($1.count) / rate }
            }
            receivedSeconds += try seconds(epoch.received)
            processedSeconds += try seconds(epoch.processed)
            unavailableSeconds += try seconds(epoch.unavailableAudio)
            awaitingSyncSeconds += try seconds(epoch.notReceived)
            let documentSpans = (documents[sessionID]?.spans ?? []).filter { byID[$0.chunkID] != nil }
            let audioAvailable = try chunkRows.map { row in
                try Task.checkCancellation()
                guard row.string(3) == "present" else { return false }
                let path = try row.requireString(4)
                let fullPath = rootPrefix + path
                return fullPath.withCString { Darwin.access($0, F_OK) == 0 }
            }
            let availableRanges = chunks.indices.filter { audioAvailable[$0] }.map { chunks[$0].frames }
            var epochIssues: [TimelineIssue] = []
            func addIssues(_ kind: TimelineIssue.Kind, ranges: [FrameRange], reason: TimelineIssue.FailureReason? = nil) throws {
                for range in try CoverageRanges.intersection(ranges, [dayFrames]) {
                    epochIssues.append(TimelineIssue(kind: kind,
                        source: TimelineAudioSource(sessionID: sessionID, generation: summary.generation,
                            epochID: anchor.epochID, frames: range, timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor),
                        failureReason: reason))
                }
            }
            try addIssues(.waitingForSync, ranges: epoch.notReceived)
            // Keep ASR window boundaries: retrying one failure must not select another pending window.
            if configurationFingerprint != nil {
                let pendingAvailable = try CoverageRanges.intersection(epoch.pending, availableRanges)
                if !pendingAvailable.isEmpty {
                    for range in speechWindows {
                        try addIssues(.waitingForTranscription,
                            ranges: CoverageRanges.intersection([range], pendingAvailable))
                    }
                    try addIssues(.waitingForAnalysis,
                        ranges: CoverageRanges.intersection(epoch.pendingAnalysis, pendingAvailable))
                }
                if !epoch.failures.isEmpty {
                    let failedAvailable = try CoverageRanges.intersection(epoch.failed, availableRanges)
                    for failure in epoch.failures {
                        try addIssues(.transcriptionFailed,
                            ranges: CoverageRanges.intersection([failure.frames], failedAvailable),
                            reason: TimelineIssue.FailureReason(code: failure.errorCode))
                    }
                }
            } else {
                for index in chunks.indices where audioAvailable[index] && chunkRows[index].string(5) != "complete" {
                    let failed = chunkRows[index].string(5) == "failed"
                    try addIssues(failed ? .transcriptionFailed : .waitingForAnalysis, ranges: [chunks[index].frames],
                        reason: failed ? TimelineIssue.FailureReason(code: chunkRows[index].string(6)) : nil)
                }
            }
            let missingUnexpected = chunks.indices.filter {
                chunkRows[$0].string(3) == "missing_unexpected" || (chunkRows[$0].string(3) == "present" && !audioAvailable[$0])
            }.map { chunks[$0].frames }
            let unfinishedUnavailable = chunks.indices.filter {
                !audioAvailable[$0] && chunkRows[$0].string(5) != "complete"
            }.map { chunks[$0].frames }
            try addIssues(.audioUnavailable, ranges: missingUnexpected + unfinishedUnavailable)
            if documents[sessionID] == nil && summary.transcriptVersion > 0 {
                try addIssues(.transcriptUnavailable, ranges: [dayFrames])
            }
            let speech = try CoverageRanges.union(speechWindows + documentSpans.map(\.frames))
            var activity = try CoverageRanges.subtract([dayFrames], epoch.noSpeech)
            if configurationFingerprint == nil {
                let unfinished = chunks.indices.filter { chunkRows[$0].string(5) != "complete" || chunkRows[$0].string(3) == "missing_unexpected" }
                    .map { chunks[$0].frames }
                let discarded = chunks.indices.filter { chunkRows[$0].string(6) == "discarded_punctuation" }.map { chunks[$0].frames }
                activity = speech + unfinished + discarded + epoch.notReceived
            }
            if documents[sessionID] == nil && summary.transcriptVersion > 0 { activity = [dayFrames] }
            activity += missingUnexpected
            let dayMarks = epoch.marks.filter { value in
                let frame = value.mark.sourceFrame
                return dayFrames.start <= frame && (frame < dayFrames.end
                    || (frame == epoch.observedThroughFrame && frame == dayFrames.end))
            }
            let marked = try dayMarks.map { value in
                let first = max(0, value.mark.sourceFrame - Int64(rate))
                return try FrameRange(start: first, count: max(1, min(epoch.observedThroughFrame, value.mark.sourceFrame + Int64(rate)) - first))
            }
            activity = try CoverageRanges.intersection(activity + speech + marked, [dayFrames])
            // Keep short natural pauses in the audio, then group longer pauses only in the reading UI.
            var connected: [FrameRange] = []
            for range in activity {
                if let last = connected.last, Double(range.start - last.end) / rate <= 10 {
                    connected[connected.count - 1] = try FrameRange(start: last.start, count: range.end - last.start)
                } else { connected.append(range) }
            }
            for frames in connected {
                try Task.checkCancellation()
                let start = base + Double(frames.start) / rate
                let end = base + Double(frames.end) / rate
                let audioStart = max(dayFrames.start, frames.start - Int64(rate))
                let audioEnd = min(dayFrames.end, frames.end + Int64(rate))
                let audioFrames = try FrameRange(start: audioStart, count: audioEnd - audioStart)
                var builder = TimelineBuilder(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                    offset: anchor.timezoneOffset, configurationFingerprint: configurationFingerprint)
                builder.sources.append(TimelineAudioSource(sessionID: sessionID, generation: summary.generation,
                    epochID: anchor.epochID, frames: audioFrames, timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor))
                builder.issues = try epochIssues.compactMap { issue in
                    guard let range = try CoverageRanges.intersection([issue.source.frames], [frames]).first else { return nil }
                    return TimelineIssue(kind: issue.kind,
                        source: TimelineAudioSource(sessionID: sessionID, generation: summary.generation,
                            epochID: anchor.epochID, frames: range, timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor),
                        failureReason: issue.failureReason)
                }
                builder.unknownTail = epoch.unknownTailFromFrame == frames.end
                builder.speechIntervals = try CoverageRanges.intersection(speech, [frames]).map {
                    DateInterval(start: Date(timeIntervalSince1970: base + Double($0.start) / rate), duration: Double($0.count) / rate)
                }
                builder.isFinal = epoch.closedAtFrame != nil || knownEnd - end >= TimelineWindow.inactivityGap
                    || (configurationFingerprint != nil && epoch.pending.isEmpty
                        && knownEnd < Date().addingTimeInterval(-30 * 60).timeIntervalSince1970)
                builder.waitingForSync = builder.waitingForSync || epoch.notReceived.contains { $0.overlaps(frames) }
                builder.failed = builder.failed || epoch.failed.contains { $0.overlaps(frames) }
                builder.pending = builder.pending || epoch.pending.contains { $0.overlaps(frames) }
                builder.marks = dayMarks.compactMap { value in
                    let mark = value.mark
                    // Keep a mark at the final sample boundary on the preceding recording day.
                    // Interior midnight boundaries belong to the following day only.
                    let atEnd = mark.sourceFrame == epoch.observedThroughFrame && frames.end == epoch.observedThroughFrame
                    guard frames.start <= mark.sourceFrame, mark.sourceFrame < frames.end || atEnd else { return nil }
                    return TimelineMark(id: mark.markID, sessionID: sessionID, generation: summary.generation,
                        epochID: anchor.epochID, sourceFrame: mark.sourceFrame,
                        recordedAt: anchor.wallClockAnchor.addingTimeInterval(Double(mark.sourceFrame) / rate),
                        audioAvailable: availableRanges.contains { $0.start <= mark.sourceFrame && mark.sourceFrame < $0.end })
                }
                builder.discarded = builder.discarded || discardedWindows.contains { $0.overlaps(frames) }
                for (index, chunk) in chunks.enumerated() where chunk.frames.overlaps(frames) {
                    let row = chunkRows[index]
                    builder.discarded = builder.discarded || row.string(6) == "discarded_punctuation"
                    let available = audioAvailable[index]
                    builder.unavailable = builder.unavailable || !available
                    if missingUnexpected.contains(where: { $0.overlaps(frames) }) { builder.failed = true }
                    if configurationFingerprint == nil {
                        builder.failed = builder.failed || row.string(5) == "failed"
                        builder.pending = builder.pending || (available && row.string(5) != "complete" && row.string(5) != "failed")
                    }
                }
                if let document = documents[sessionID] {
                    var paragraphIDs = Set<UUID>()
                    for span in documentSpans {
                        guard byID[span.chunkID] != nil else { continue }
                        let at = base + Double(span.frames.start) / rate
                        guard at >= start, at < end else { continue }
                        let available = span.sourceRanges.allSatisfy { source in
                            guard let index = byID[source.chunkID] else { return false }
                            return audioAvailable[index]
                        }
                        var paragraph = TimelineParagraph(source: document.source(for: span), text: span.text,
                            recordedAt: Date(timeIntervalSince1970: at), audioAvailable: available, speaker: span.speaker, attribution: span.attribution)
                        paragraph.audioSource = TimelineAudioSource(sessionID: sessionID, generation: summary.generation,
                            epochID: anchor.epochID, frames: span.frames, timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor)
                        paragraph.startsNewSpeakerTurn = span.startsNewSpeakerTurn
                        if paragraphIDs.insert(paragraph.id).inserted {
                            builder.paragraphs.append(paragraph)
                            builder.paragraphLocations[paragraph.id] = TimelineAudioSource(sessionID: sessionID,
                                generation: summary.generation, epochID: anchor.epochID, frames: span.frames,
                                timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor)
                        }
                    }
                } else if summary.transcriptVersion > 0 { builder.failed = true }
                slices.append(builder)
            }
        }
        var groups: [TimelineBuilder] = []
        for slice in slices.sorted(by: { $0.start == $1.start ? $0.offset < $1.offset : $0.start < $1.start }) {
            if let index = groups.lastIndex(where: { $0.offset == slice.offset && slice.start.timeIntervalSince($0.end) <= TimelineWindow.inactivityGap }) {
                groups[index].merge(slice)
            } else { groups.append(slice) }
        }
        var windows: [TimelineWindow] = try groups.map { try $0.build() }
        windows.sort {
            $0.id.start == $1.id.start ? $0.id.timezoneOffset < $1.id.timezoneOffset : $0.id.start > $1.id.start
        }
        return TimelineDaySnapshot(windows: windows, progress: TimelineDayProgress(received: receivedSeconds,
            processed: configurationFingerprint == nil ? nil : min(receivedSeconds, processedSeconds),
            unavailable: unavailableSeconds, awaitingSync: awaitingSyncSeconds))
    }

    public func timelineWindow(_ id: TimelineWindowID, configurationFingerprint: String? = nil) throws -> TimelineWindow? {
        try timelineDay(id.day, configurationFingerprint: configurationFingerprint).first { $0.id == id }
    }

    public func timelineWindow(containing source: SourceReference, configurationFingerprint: String? = nil) throws -> TimelineWindow? {
        try validateSources([source])
        let document = try readTranscript(sessionID: source.sessionID)
        guard let span = document.spans.first(where: { $0.id == source.spanID }),
              let row = try database.rows("SELECT manifest FROM chunks WHERE id=?", [.text(span.chunkID.uuidString)]).first else {
            throw ArchiveError.staleSource
        }
        let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(0))
        let at = manifest.wallClockAnchor.addingTimeInterval(Double(span.frames.start) / manifest.timebaseHz)
        let local = at.addingTimeInterval(Double(manifest.timezoneOffset))
        return try timelineDay(TimelineDay(local, calendar: TimelineDay.calendar), configurationFingerprint: configurationFingerprint)
            .first { $0.references.contains(source) }
    }

    public func validateTimelineWindow(_ window: TimelineWindow) throws {
        guard let current = try timelineWindow(window.id, configurationFingerprint: window.configurationFingerprint),
              current.revision == window.revision else { throw ArchiveError.staleSource }
        try validateSources(window.references)
    }

    /// Summaries depend on available readable content, not capture, sync or processing completion.
    public func validateTimelineSummary(_ window: TimelineWindow) throws {
        guard try validTimelineSummaryRevisions([window]).contains(window.summaryRevision) else { throw ArchiveError.staleSource }
    }

    /// One authoritative day read per batch. No validation survives this call or a source change.
    public func validTimelineSummaryRevisions(_ windows: [TimelineWindow]) throws -> Set<String> {
        struct DayKey: Hashable { let day: TimelineDay; let fingerprint: String? }
        var valid: Set<String> = []
        let grouped = Dictionary(grouping: windows.filter(\.canSummarize)) {
            DayKey(day: $0.id.day, fingerprint: $0.configurationFingerprint)
        }
        for (key, requested) in grouped {
            let current = Dictionary(uniqueKeysWithValues:
                try timelineDay(key.day, configurationFingerprint: key.fingerprint).map { ($0.id, $0) })
            for window in requested {
                guard let actual = current[window.id], actual.canSummarize,
                      actual.summaryRevision == window.summaryRevision else { continue }
                try validateSources(actual.references)
                valid.insert(window.summaryRevision)
            }
        }
        return valid
    }

    /// Re-read authoritative ranges; callers cannot turn a missing-audio notice into a whole-session retry.
    public func timelineRetrySources(_ request: TimelineRetryRequest) throws -> [TimelineAudioSource] {
        guard let current = try timelineWindow(request.window.id, configurationFingerprint: request.window.configurationFingerprint),
              current.revision == request.window.revision else { throw ArchiveError.staleSource }
        try validateSources(current.references)
        guard let issueID = request.issueID else {
            guard request.frames == nil else { throw ArchiveError.invalidQuery }
            return current.sources
        }
        guard let issue = current.issues.first(where: { $0.id == issueID }), issue.canRetry else { throw ArchiveError.invalidQuery }
        let source = issue.source, frames = request.frames ?? source.frames
        guard frames.start >= source.frames.start, frames.end <= source.frames.end else { throw ArchiveError.staleSource }
        return [TimelineAudioSource(sessionID: source.sessionID, generation: source.generation, epochID: source.epochID,
            frames: frames, timebaseHz: source.timebaseHz, wallClockAnchor: source.wallClockAnchor)]
    }

    public func timelineRetryIsComplete(sources: [TimelineAudioSource], configurationFingerprint: String) throws -> Bool {
        guard !sources.isEmpty else { throw ArchiveError.invalidQuery }
        var coverages: [UUID: RecordingCoverage] = [:]
        for source in sources {
            guard try recordingSummary(sessionID: source.sessionID).generation == source.generation else { throw ArchiveError.staleSource }
            if coverages[source.sessionID] == nil {
                coverages[source.sessionID] = try recordingCoverage(sessionID: source.sessionID, configurationFingerprint: configurationFingerprint)
            }
            guard let epoch = coverages[source.sessionID]?.epochs.first(where: { $0.epochID == source.epochID }),
                  epoch.processed.contains(where: { $0.contains(source.frames) }) else { return false }
        }
        return true
    }

    public func earliestTimelineDay() throws -> TimelineDay? {
        try performanceMonitor.measure(.earliestTimelineDay) {
            try Task.checkCancellation()
            let externalVersion = try database.rows("PRAGMA data_version").first?.requireInt(0) ?? 0
            let localRevision = database.timelineRevision
            if !database.isInTransaction,
               let cached = cachedEarliestTimelineDay,
               cached.dataVersion == externalVersion,
               cached.timelineRevision == localRevision {
                return cached.value
            }
            let computed: TimelineDay?
            if let row = try database.rows("""
                SELECT MIN(e.wall_clock_anchor + COALESCE(e.timezone_offset, 0))
                FROM epochs e JOIN sessions s ON s.id=e.session_id
                WHERE s.deleted=0 AND e.wall_clock_anchor IS NOT NULL
                """).first, let seconds = row.double(0) {
                computed = TimelineDay(Date(timeIntervalSince1970: seconds.rounded()), calendar: TimelineDay.calendar)
            } else {
                computed = nil
            }
            if !database.isInTransaction {
                cachedEarliestTimelineDay = (externalVersion, localRevision, computed)
            }
            return computed
        }
    }
}

private struct TimelineBuilder {
    var start: Date
    var end: Date
    let offset: Int
    var id: TimelineWindowID { TimelineWindowID(start: start, timezoneOffset: offset) }
    let configurationFingerprint: String?
    var speechIntervals: [DateInterval] = []
    var sources: [TimelineAudioSource] = []
    var paragraphs: [TimelineParagraph] = []
    var paragraphLocations: [UUID: TimelineAudioSource] = [:]
    var marks: [TimelineMark] = []
    var issues: [TimelineIssue] = []
    var unknownTail = false
    var isFinal = true
    var waitingForSync = false
    var pending = false
    var failed = false
    var unavailable = false
    var discarded = false

    mutating func merge(_ other: Self) {
        end = max(end, other.end)
        sources += other.sources; paragraphs += other.paragraphs; speechIntervals += other.speechIntervals
        issues += other.issues; unknownTail = unknownTail || other.unknownTail
        isFinal = isFinal && other.isFinal
        marks += other.marks
        paragraphLocations.merge(other.paragraphLocations) { current, _ in current }
        waitingForSync = waitingForSync || other.waitingForSync; pending = pending || other.pending
        failed = failed || other.failed; unavailable = unavailable || other.unavailable; discarded = discarded || other.discarded
    }

    func build() throws -> TimelineWindow {
        var intervals: [DateInterval] = []
        for interval in speechIntervals.sorted(by: { $0.start < $1.start }) {
            if let last = intervals.last, interval.start <= last.end {
                intervals[intervals.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { intervals.append(interval) }
        }
        let sortedSources = sources.sorted {
            if $0.recordedAt == $1.recordedAt { return $0.epochID.uuidString < $1.epochID.uuidString }
            return $0.recordedAt < $1.recordedAt
        }
        let sortedText = paragraphs.sorted {
            $0.recordedAt == $1.recordedAt ? $0.id.uuidString < $1.id.uuidString : $0.recordedAt < $1.recordedAt
        }
        let sortedMarks = marks.sorted {
            $0.recordedAt == $1.recordedAt ? $0.id.uuidString < $1.id.uuidString : $0.recordedAt < $1.recordedAt
        }.map { mark in
            var resolved = mark
            var nearestDistance = Int64.max
            for paragraph in sortedText where paragraph.hasReadableText {
                guard let location = paragraphLocations[paragraph.id], location.sessionID == mark.sessionID,
                      location.generation == mark.generation, location.epochID == mark.epochID else { continue }
                let distance = mark.sourceFrame < location.frames.start ? location.frames.start - mark.sourceFrame
                    : mark.sourceFrame >= location.frames.end ? mark.sourceFrame - location.frames.end + 1 : 0
                if distance < nearestDistance {
                    nearestDistance = distance
                    resolved.nearbyParagraphID = paragraph.id
                }
            }
            return resolved
        }
        let marked = !sortedMarks.isEmpty
        let sortedIssues = issues.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let state: TimelineProcessingState = failed ? .failed : waitingForSync ? .waitingForSync : pending ? .waitingForTranscription : .complete
        let content = TimelineWindow(id: id, end: end, sources: sortedSources, paragraphs: sortedText, state: state,
            isFinal: isFinal, isMarked: marked, unavailableAudio: unavailable, revision: "", configurationFingerprint: configurationFingerprint, speechIntervals: intervals,
            discardedTranscription: discarded, issues: sortedIssues, hasUnknownTail: unknownTail, marks: sortedMarks)
        // Appending text elsewhere in the same session must not regenerate an unchanged summary.
        let stableParagraphs = content.paragraphs.map { paragraph in
            TimelineParagraph(source: SourceReference(sessionID: paragraph.source.sessionID, spanID: paragraph.source.spanID,
                transcriptVersion: 0, generation: paragraph.source.generation), text: paragraph.text,
                recordedAt: paragraph.recordedAt, audioAvailable: paragraph.audioAvailable, speaker: paragraph.speaker,
                attribution: paragraph.attribution, audioSource: paragraph.audioSource, startsNewSpeakerTurn: paragraph.startsNewSpeakerTurn)
        }
        let stable = TimelineWindow(id: id, end: end, sources: sortedSources, paragraphs: stableParagraphs, state: state,
            isFinal: isFinal, isMarked: marked, unavailableAudio: unavailable, revision: "", configurationFingerprint: configurationFingerprint, speechIntervals: intervals,
            discardedTranscription: discarded, issues: sortedIssues, hasUnknownTail: unknownTail, marks: sortedMarks)
        return TimelineWindow(id: id, end: end, sources: sortedSources, paragraphs: sortedText, state: state,
            isFinal: isFinal, isMarked: marked, unavailableAudio: unavailable,
            revision: ContentHash.sha256(try WireJSON.encode(stable)), configurationFingerprint: configurationFingerprint, speechIntervals: intervals,
            discardedTranscription: discarded, issues: sortedIssues, hasUnknownTail: unknownTail, marks: sortedMarks)
    }
}

private extension FrameRange {
    func overlaps(_ other: Self) -> Bool { start < other.end && end > other.start }
}
