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

    private func audioFileExists(
        relativePath: String,
        rootPrefix: String,
        localDirectories: inout [String: Set<String>?]
    ) -> Bool {
        let fullPath = rootPrefix + relativePath
        guard let slash = fullPath.lastIndex(of: "/") else {
            return fullPath.withCString { Darwin.access($0, F_OK) == 0 }
        }
        let dirPath = String(fullPath[..<slash])
        let fileName = String(fullPath[fullPath.index(after: slash)...])
        if let localEntry = localDirectories[dirPath] {
            if let names = localEntry {
                return names.contains(fileName)
            }
            return fullPath.withCString { Darwin.access($0, F_OK) == 0 }
        }
        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        guard let stamp = FileStatStamp.read(at: dirURL) else {
            verifiedAudioDirectoryFilesCache.removeValue(forKey: dirPath)
            localDirectories[dirPath] = []
            return false
        }
        guard (stamp.mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) else {
            verifiedAudioDirectoryFilesCache.removeValue(forKey: dirPath)
            localDirectories[dirPath] = nil
            return fullPath.withCString { Darwin.access($0, F_OK) == 0 }
        }
        if let cached = verifiedAudioDirectoryFilesCache[dirPath], cached.stamp == stamp {
            localDirectories[dirPath] = cached.fileNames
            return cached.fileNames.contains(fileName)
        }
        guard let dir = dirPath.withCString({ Darwin.opendir($0) }) else {
            localDirectories[dirPath] = nil
            return fullPath.withCString { Darwin.access($0, F_OK) == 0 }
        }
        defer { Darwin.closedir(dir) }
        var names = Set<String>(minimumCapacity: 64)
        while let entry = Darwin.readdir(dir) {
            let nameLen = Int(entry.pointee.d_namlen)
            if nameLen == 0 { continue }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(nameLen), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let dtype = Int32(entry.pointee.d_type)
            if dtype == DT_LNK || dtype == DT_UNKNOWN {
                let candidate = dirPath + "/" + name
                if candidate.withCString({ Darwin.access($0, F_OK) == 0 }) {
                    names.insert(name)
                }
            } else {
                names.insert(name)
            }
        }
        if verifiedAudioDirectoryFilesCache.count >= 64, verifiedAudioDirectoryFilesCache[dirPath] == nil {
            verifiedAudioDirectoryFilesCache.removeValue(forKey: verifiedAudioDirectoryFilesCache.keys.first!)
        }
        verifiedAudioDirectoryFilesCache[dirPath] = (stamp, names)
        localDirectories[dirPath] = names
        return names.contains(fileName)
    }

    private func timelineDaySnapshotImpl(_ day: TimelineDay, configurationFingerprint: String? = nil) throws -> TimelineDaySnapshot {
        if let configurationFingerprint, !ContentHash.isValid(configurationFingerprint) { throw ArchiveError.invalidQuery }
        try Task.checkCancellation()
        #if DEBUG
        timelineDayBuildCount += 1
        #endif
        struct TimelineSessionMeta {
            let generation: Int64
            let transcriptVersion: Int64
            let projectionBlocked: Bool
        }
        struct TimelineChunkMeta {
            let chunkID: UUID
            let frames: FrameRange
        }
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
        var sessionMetas: [UUID: TimelineSessionMeta] = [:]
        var sessionMarksCache: [UUID: [CaptureMark]] = [:]
        var documents: [UUID: TranscriptDocument] = [:]
        var loadedDocuments: Set<UUID> = []
        var localAudioDirectories: [String: Set<String>?] = [:]
        var receivedSeconds = 0.0, processedSeconds = 0.0, unavailableSeconds = 0.0, awaitingSyncSeconds = 0.0
        for row in rows {
            try Task.checkCancellation()
            let anchor = try WireJSON.decode(ChunkManifest.self, from: row.requireData(0))
            let sessionID = anchor.sessionID
            let sessionMeta: TimelineSessionMeta
            if let cached = sessionMetas[sessionID] {
                sessionMeta = cached
            } else {
                guard let srow = try database.rows(
                    "SELECT generation, transcript_version, projection_blocked FROM sessions WHERE id=? AND deleted=0",
                    [.text(sessionID.uuidString)]
                ).first else {
                    throw ArchiveError.missingRecording(sessionID)
                }
                let loaded = TimelineSessionMeta(
                    generation: try srow.requireInt(0),
                    transcriptVersion: try srow.requireInt(1),
                    projectionBlocked: srow.integer(2) == 1
                )
                sessionMetas[sessionID] = loaded
                sessionMeta = loaded
            }
            if !loadedDocuments.contains(sessionID) {
                loadedDocuments.insert(sessionID)
                if !sessionMeta.projectionBlocked && sessionMeta.transcriptVersion > 0,
                   let document = try currentTranscriptOrNil(sessionID: sessionID) {
                    documents[sessionID] = document
                }
            }
            let allMarks: [CaptureMark]
            if let cachedMarks = sessionMarksCache[sessionID] {
                allMarks = cachedMarks
            } else {
                let fetched = try marks(sessionID: sessionID)
                sessionMarksCache[sessionID] = fetched
                allMarks = fetched
            }
            let epochMarks = allMarks.filter { $0.epochID == anchor.epochID }
            let rate = anchor.timebaseHz
            if !rate.isFinite || rate <= 0 { throw ArchiveError.database(11) }
            let epoch = try epochCoverage(
                epochID: anchor.epochID,
                rate: rate,
                fingerprint: configurationFingerprint,
                marks: epochMarks,
                document: epochMarks.isEmpty ? nil : documents[sessionID]
            )
            guard epoch.observedThroughFrame > 0 else { continue }
            let base = anchor.wallClockAnchor.timeIntervalSince1970
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

            let epochIDText = anchor.epochID.uuidString
            let chunkRows = try database.rows("""
                SELECT c.id,c.start_frame,c.end_frame,c.retention,c.relative_path,j.state,j.error_code
                FROM chunks c LEFT JOIN transcription_jobs j ON j.chunk_id=c.id
                WHERE c.epoch_id=? AND c.end_frame > ? AND c.start_frame < ?
                ORDER BY c.start_frame
                """, [.text(epochIDText), .integer(firstFrame), .integer(throughFrame)])
            var chunks: [TimelineChunkMeta] = []
            chunks.reserveCapacity(chunkRows.count)
            var audioAvailable: [Bool] = []
            audioAvailable.reserveCapacity(chunkRows.count)
            var chunkAudioByID: [UUID: Bool] = Dictionary(minimumCapacity: chunkRows.count)
            for chunkRow in chunkRows {
                try Task.checkCancellation()
                let cid = try chunkRow.requireUUID(0)
                let startFrame = try chunkRow.requireInt(1)
                let endFrame = try chunkRow.requireInt(2)
                chunks.append(TimelineChunkMeta(chunkID: cid, frames: try FrameRange(start: startFrame, count: endFrame - startFrame)))
                let isAvail: Bool
                if chunkRow.string(3) == "present" {
                    let path = try chunkRow.requireString(4)
                    isAvail = audioFileExists(relativePath: path, rootPrefix: rootPrefix, localDirectories: &localAudioDirectories)
                } else {
                    isAvail = false
                }
                audioAvailable.append(isAvail)
                chunkAudioByID[cid] = isAvail
            }

            let marginFrames = max(1, Int64((rate * 2).rounded(.up)))
            let spanLowerBound = max(0, firstFrame - marginFrames)
            let spanUpperBound = throughFrame + marginFrames
            let candidateSpans = (documents[sessionID]?.spans ?? []).filter {
                $0.frames.end > spanLowerBound && $0.frames.start < spanUpperBound
            }
            if !candidateSpans.isEmpty {
                var missingChunkIDs: Set<UUID> = []
                for span in candidateSpans {
                    if chunkAudioByID[span.chunkID] == nil { missingChunkIDs.insert(span.chunkID) }
                    for source in span.sourceRanges where chunkAudioByID[source.chunkID] == nil {
                        missingChunkIDs.insert(source.chunkID)
                    }
                }
                if !missingChunkIDs.isEmpty {
                    let idList = Array(missingChunkIDs)
                    for batchStart in stride(from: 0, to: idList.count, by: 200) {
                        let slice = idList[batchStart..<min(batchStart + 200, idList.count)]
                        let placeholders = slice.map { _ in "?" }.joined(separator: ",")
                        let extraRows = try database.rows(
                            "SELECT id,retention,relative_path FROM chunks WHERE epoch_id=? AND id IN (\(placeholders))",
                            [.text(epochIDText)] + slice.map { .text($0.uuidString) }
                        )
                        for extra in extraRows {
                            let cid = try extra.requireUUID(0)
                            if extra.string(1) == "present" {
                                let path = try extra.requireString(2)
                                chunkAudioByID[cid] = audioFileExists(relativePath: path, rootPrefix: rootPrefix, localDirectories: &localAudioDirectories)
                            } else {
                                chunkAudioByID[cid] = false
                            }
                        }
                    }
                }
            }
            let documentSpans = candidateSpans
                .filter { chunkAudioByID[$0.chunkID] != nil }
                .sorted { $0.frames.start < $1.frames.start }

            let speechWindows: [FrameRange]
            if let configurationFingerprint {
                speechWindows = try database.rows("""
                    SELECT core_start,core_end FROM analysis_windows
                    WHERE epoch_id=? AND configuration_hash=? AND core_end > ? AND core_start < ?
                    """, [.text(epochIDText), .text(configurationFingerprint), .integer(firstFrame), .integer(throughFrame)])
                    .map { try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0)) }
            } else {
                speechWindows = []
            }
            let discardedWindows = try CoverageRanges.union(
                database.rows("""
                    SELECT core_start,core_end FROM analysis_windows
                    WHERE epoch_id=? AND state='complete' AND core_end > ? AND core_start < ? AND raw_result=?
                    """, [.text(epochIDText), .integer(firstFrame), .integer(throughFrame), .blob(TranscriptText.discardedPunctuation)])
                    .map { try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0)) }
            )

            let availableRanges = chunks.indices.filter { audioAvailable[$0] }.map { chunks[$0].frames }
            var epochIssues: [TimelineIssue] = []
            func addIssues(_ kind: TimelineIssue.Kind, ranges: [FrameRange], reason: TimelineIssue.FailureReason? = nil) throws {
                for range in try CoverageRanges.intersection(ranges, [dayFrames]) {
                    epochIssues.append(TimelineIssue(kind: kind,
                        source: TimelineAudioSource(sessionID: sessionID, generation: sessionMeta.generation,
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
            var isMissingUnexpected = [Bool](repeating: false, count: chunks.count)
            var missingUnexpected: [FrameRange] = []
            var unfinishedUnavailable: [FrameRange] = []
            for index in chunks.indices {
                let retention = chunkRows[index].string(3)
                if retention == "missing_unexpected" || (retention == "present" && !audioAvailable[index]) {
                    isMissingUnexpected[index] = true
                    missingUnexpected.append(chunks[index].frames)
                }
                if !audioAvailable[index] && chunkRows[index].string(5) != "complete" {
                    unfinishedUnavailable.append(chunks[index].frames)
                }
            }
            try addIssues(.audioUnavailable, ranges: missingUnexpected + unfinishedUnavailable)
            if documents[sessionID] == nil && sessionMeta.transcriptVersion > 0 {
                try addIssues(.transcriptUnavailable, ranges: [dayFrames])
            }
            epochIssues.sort { $0.source.frames.start < $1.source.frames.start }

            let speech = try CoverageRanges.union(speechWindows + documentSpans.map(\.frames))
            var activity = try CoverageRanges.subtract([dayFrames], epoch.noSpeech)
            if configurationFingerprint == nil {
                let unfinished = chunks.indices.filter { chunkRows[$0].string(5) != "complete" || chunkRows[$0].string(3) == "missing_unexpected" }
                    .map { chunks[$0].frames }
                let discarded = chunks.indices.filter { chunkRows[$0].string(6) == "discarded_punctuation" }.map { chunks[$0].frames }
                activity = speech + unfinished + discarded + epoch.notReceived
            }
            if documents[sessionID] == nil && sessionMeta.transcriptVersion > 0 { activity = [dayFrames] }
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
            connected.reserveCapacity(activity.count)
            for range in activity {
                if let last = connected.last, Double(range.start - last.end) / rate <= 10 {
                    connected[connected.count - 1] = try FrameRange(start: last.start, count: range.end - last.start)
                } else { connected.append(range) }
            }

            func overlapsSortedDisjoint(_ ranges: [FrameRange], cursor: inout Int, target: FrameRange) -> Bool {
                while cursor < ranges.count && ranges[cursor].end <= target.start { cursor += 1 }
                return cursor < ranges.count && ranges[cursor].start < target.end
            }
            func containsFrame(_ sortedDisjoint: [FrameRange], frame: Int64) -> Bool {
                var lo = 0, hi = sortedDisjoint.count
                while lo < hi {
                    let mid = (lo + hi) >> 1
                    if sortedDisjoint[mid].end <= frame { lo = mid + 1 } else { hi = mid }
                }
                return lo < sortedDisjoint.count && sortedDisjoint[lo].start <= frame && frame < sortedDisjoint[lo].end
            }

            var issueCursor = 0
            var issueMaxEndBeforeCursor: Int64 = 0
            var speechCursor = 0
            var notReceivedCursor = 0
            var failedCursor = 0
            var pendingCursor = 0
            var discardedCursor = 0
            var chunkCursor = 0
            var spanCursor = 0
            let document = documents[sessionID]

            for frames in connected {
                try Task.checkCancellation()
                let start = base + Double(frames.start) / rate
                let end = base + Double(frames.end) / rate
                let audioStart = max(dayFrames.start, frames.start - Int64(rate))
                let audioEnd = min(dayFrames.end, frames.end + Int64(rate))
                let audioFrames = try FrameRange(start: audioStart, count: audioEnd - audioStart)
                var builder = TimelineBuilder(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                    offset: anchor.timezoneOffset, configurationFingerprint: configurationFingerprint)
                builder.sources.append(TimelineAudioSource(sessionID: sessionID, generation: sessionMeta.generation,
                    epochID: anchor.epochID, frames: audioFrames, timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor))

                while issueCursor < epochIssues.count,
                      issueMaxEndBeforeCursor <= frames.start,
                      epochIssues[issueCursor].source.frames.end <= frames.start {
                    issueMaxEndBeforeCursor = max(issueMaxEndBeforeCursor, epochIssues[issueCursor].source.frames.end)
                    issueCursor += 1
                }
                let issueScanStart = issueMaxEndBeforeCursor <= frames.start ? issueCursor : 0
                for issueIdx in issueScanStart..<epochIssues.count {
                    let issue = epochIssues[issueIdx]
                    if issue.source.frames.start >= frames.end { break }
                    let s = max(issue.source.frames.start, frames.start)
                    let e = min(issue.source.frames.end, frames.end)
                    if e > s {
                        let range = try FrameRange(start: s, count: e - s)
                        builder.issues.append(TimelineIssue(kind: issue.kind,
                            source: TimelineAudioSource(sessionID: sessionID, generation: sessionMeta.generation,
                                epochID: anchor.epochID, frames: range, timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor),
                            failureReason: issue.failureReason))
                    }
                }

                builder.unknownTail = epoch.unknownTailFromFrame == frames.end
                while speechCursor < speech.count && speech[speechCursor].end <= frames.start { speechCursor += 1 }
                var sIdx = speechCursor
                while sIdx < speech.count && speech[sIdx].start < frames.end {
                    let s = max(speech[sIdx].start, frames.start)
                    let e = min(speech[sIdx].end, frames.end)
                    if e > s {
                        builder.speechIntervals.append(
                            DateInterval(start: Date(timeIntervalSince1970: base + Double(s) / rate), duration: Double(e - s) / rate)
                        )
                    }
                    sIdx += 1
                }

                builder.isFinal = epoch.closedAtFrame != nil || knownEnd - end >= TimelineWindow.inactivityGap
                    || (configurationFingerprint != nil && epoch.pending.isEmpty
                        && knownEnd < Date().addingTimeInterval(-30 * 60).timeIntervalSince1970)
                builder.waitingForSync = builder.waitingForSync || overlapsSortedDisjoint(epoch.notReceived, cursor: &notReceivedCursor, target: frames)
                builder.failed = builder.failed || overlapsSortedDisjoint(epoch.failed, cursor: &failedCursor, target: frames)
                builder.pending = builder.pending || overlapsSortedDisjoint(epoch.pending, cursor: &pendingCursor, target: frames)
                if !dayMarks.isEmpty {
                    builder.marks = dayMarks.compactMap { value in
                        let mark = value.mark
                        // Keep a mark at the final sample boundary on the preceding recording day.
                        // Interior midnight boundaries belong to the following day only.
                        let atEnd = mark.sourceFrame == epoch.observedThroughFrame && frames.end == epoch.observedThroughFrame
                        guard frames.start <= mark.sourceFrame, mark.sourceFrame < frames.end || atEnd else { return nil }
                        return TimelineMark(id: mark.markID, sessionID: sessionID, generation: sessionMeta.generation,
                            epochID: anchor.epochID, sourceFrame: mark.sourceFrame,
                            recordedAt: anchor.wallClockAnchor.addingTimeInterval(Double(mark.sourceFrame) / rate),
                            audioAvailable: containsFrame(availableRanges, frame: mark.sourceFrame))
                    }
                }
                builder.discarded = builder.discarded || overlapsSortedDisjoint(discardedWindows, cursor: &discardedCursor, target: frames)

                while chunkCursor < chunks.count && chunks[chunkCursor].frames.end <= frames.start { chunkCursor += 1 }
                var cIdx = chunkCursor
                while cIdx < chunks.count && chunks[cIdx].frames.start < frames.end {
                    if chunks[cIdx].frames.end > frames.start {
                        let cRow = chunkRows[cIdx]
                        builder.discarded = builder.discarded || cRow.string(6) == "discarded_punctuation"
                        let available = audioAvailable[cIdx]
                        builder.unavailable = builder.unavailable || !available
                        if isMissingUnexpected[cIdx] { builder.failed = true }
                        if configurationFingerprint == nil {
                            let jState = cRow.string(5)
                            builder.failed = builder.failed || jState == "failed"
                            builder.pending = builder.pending || (available && jState != "complete" && jState != "failed")
                        }
                    }
                    cIdx += 1
                }

                if let document {
                    while spanCursor < documentSpans.count && (base + Double(documentSpans[spanCursor].frames.start) / rate) < start {
                        spanCursor += 1
                    }
                    var paragraphIDs = Set<UUID>()
                    var spIdx = spanCursor
                    while spIdx < documentSpans.count {
                        let span = documentSpans[spIdx]
                        let at = base + Double(span.frames.start) / rate
                        if at >= end { break }
                        let available = span.sourceRanges.allSatisfy { source in
                            chunkAudioByID[source.chunkID] == true
                        }
                        let location = TimelineAudioSource(sessionID: sessionID, generation: sessionMeta.generation,
                            epochID: anchor.epochID, frames: span.frames, timebaseHz: rate, wallClockAnchor: anchor.wallClockAnchor)
                        var paragraph = TimelineParagraph(source: document.source(for: span), text: span.text,
                            recordedAt: Date(timeIntervalSince1970: at), audioAvailable: available, speaker: span.speaker, attribution: span.attribution)
                        paragraph.audioSource = location
                        paragraph.startsNewSpeakerTurn = span.startsNewSpeakerTurn
                        if paragraphIDs.insert(paragraph.id).inserted {
                            builder.paragraphs.append(paragraph)
                            builder.paragraphLocations[paragraph.id] = location
                        }
                        spIdx += 1
                    }
                } else if sessionMeta.transcriptVersion > 0 { builder.failed = true }
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
              let row = try database.rows("SELECT wall_clock_anchor,timebase_hz,timezone_offset FROM chunks WHERE id=?", [.text(span.chunkID.uuidString)]).first else {
            throw ArchiveError.staleSource
        }
        let anchorSeconds = try row.requireDouble(0)
        let rate = try row.requireDouble(1)
        let tzOffset = try row.requireInt(2)
        let at = Date(timeIntervalSince1970: anchorSeconds + Double(span.frames.start) / rate)
        let local = at.addingTimeInterval(Double(tzOffset))
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
        // Appending text elsewhere in the same session must not regenerate an unchanged summary.
        let stableParagraphs = sortedText.map { paragraph in
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
