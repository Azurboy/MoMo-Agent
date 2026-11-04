import Foundation
import MoMoContracts

enum TranscriptText {
    static let discardedPunctuation = Data("{\"discarded\":\"punctuation\"}".utf8)
    static func hasContent(_ text: String) -> Bool {
        let ignored = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        return text.unicodeScalars.contains { !ignored.contains($0) }
    }
}

extension ArchiveStore {
    public static let maximumSourceReferences = 4_096

    public func commitTranscript(ticket: AnalysisTicket, spans: [TranscriptSpan]) throws -> TranscriptDocument {
        guard Set(spans.map(\.id)).count == spans.count, spans.allSatisfy({
            $0.chunkID == ticket.chunkID && $0.text.utf8.count <= 65_536 && $0.frames.start >= ticket.manifest.frames.start
                && $0.frames.end <= ticket.manifest.frames.end
        }) else { throw ArchiveError.invalidTranscript }
        return try database.transaction {
            try validateTicket(ticket)
            let previous = try currentTranscriptOrNil(sessionID: ticket.sessionID)
            let kept = spans.filter { TranscriptText.hasContent($0.text) }
            let combined = (previous?.spans.filter { $0.chunkID != ticket.chunkID } ?? []) + kept
            let document = TranscriptDocument(sessionID: ticket.sessionID, version: (previous?.version ?? 0) + 1,
                                              generation: ticket.expectedGeneration,
                                              spans: try orderedSpans(combined, sessionID: ticket.sessionID), updatedAt: Date())
            try storeDocument(document, knownPrevious: .some(previous))
            try database.execute("UPDATE transcription_jobs SET state='complete',attempt_id=NULL,error_code=? WHERE id=?",
                [kept.count == spans.count ? .null : .text("discarded_punctuation"), .text(ticket.jobID.uuidString)])
            return document
        }
    }

    private static let discardedPunctuationMigrationKey = "discarded_punctuation_only_transcripts_v1"

    /// Remove old recognition noise through the normal revision/source-invalidation path.
    public func discardPunctuationOnlyTranscripts() throws {
        if try !database.rows(
            "SELECT 1 FROM metadata WHERE key=? LIMIT 1",
            [.text(Self.discardedPunctuationMigrationKey)]
        ).isEmpty {
            return
        }
        for row in try database.rows("SELECT id FROM sessions WHERE deleted=0 AND projection_blocked=0 AND transcript_version>0") {
            let sessionID = try row.requireUUID(0)
            guard let document = try currentTranscriptOrNil(sessionID: sessionID) else { continue }
            let kept = document.spans.filter { TranscriptText.hasContent($0.text) }
            if kept.count != document.spans.count {
                _ = try reviseTranscript(sessionID: sessionID, expectedVersion: document.version, spans: kept)
            }
        }
        try database.execute(
            "INSERT INTO metadata(key,value) VALUES(?, '1') ON CONFLICT(key) DO UPDATE SET value='1'",
            [.text(Self.discardedPunctuationMigrationKey)]
        )
    }

    public func readTranscript(sessionID: UUID) throws -> TranscriptDocument {
        guard let document = try currentTranscriptOrNil(sessionID: sessionID) else { throw ArchiveError.missingTranscript(sessionID) }
        if try database.rows("SELECT projection_blocked FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.integer(0) == 1 {
            throw ArchiveError.projectionConflict
        }
        return document
    }

    public func transcriptLocations(document: TranscriptDocument) throws -> [UUID: TranscriptSpanLocation] {
        let current = try readTranscript(sessionID: document.sessionID)
        guard current.version == document.version, current.generation == document.generation else {
            throw ArchiveError.staleSource
        }
        return try locationsForValidatedTranscript(current)
    }

    private func locationsForValidatedTranscript(_ document: TranscriptDocument) throws -> [UUID: TranscriptSpanLocation] {
        let rows = try database.rows("SELECT id,epoch_id,wall_clock_anchor,timebase_hz,retention FROM chunks WHERE session_id=?", [.text(document.sessionID.uuidString)])
        var chunks: [UUID: (epochID: UUID, wallClockAnchor: Date, timebaseHz: Double, present: Bool)] = [:]
        chunks.reserveCapacity(rows.count)
        for row in rows {
            let chunkID = try row.requireUUID(0)
            let epochID = try row.requireUUID(1)
            let present = try row.requireString(4) == "present"
            if let anchor = row.double(2), let rate = row.double(3), rate > 0 {
                chunks[chunkID] = (epochID, Date(timeIntervalSince1970: anchor), rate, present)
            } else if let mRow = try database.rows("SELECT manifest FROM chunks WHERE id=?", [.text(chunkID.uuidString)]).first {
                let manifest = try WireJSON.decode(ChunkManifest.self, from: mRow.requireData(0))
                chunks[chunkID] = (manifest.epochID, manifest.wallClockAnchor, manifest.timebaseHz, present)
            }
        }
        return try Dictionary(uniqueKeysWithValues: document.spans.map { span in
            guard let first = span.sourceRanges.first, let chunk = chunks[first.chunkID] else {
                throw ArchiveError.invalidTranscript
            }
            // All chunks in an epoch retain the writer's original wall clock anchor.
            let date = chunk.wallClockAnchor.addingTimeInterval(Double(first.frames.start) / chunk.timebaseHz)
            let available = span.sourceRanges.allSatisfy { chunks[$0.chunkID]?.present == true }
            return (span.id, TranscriptSpanLocation(recordedAt: date, audioAvailable: available,
                audioSource: TimelineAudioSource(sessionID: document.sessionID, generation: document.generation,
                    epochID: chunk.epochID, frames: span.frames, timebaseHz: chunk.timebaseHz, wallClockAnchor: chunk.wallClockAnchor)))
        })
    }

    /// Read text and its clock mapping in one actor turn, before ASR can append another version.
    public func transcriptSnapshot(sessionID: UUID, version: Int64? = nil) throws -> (document: TranscriptDocument, locations: [UUID: TranscriptSpanLocation]) {
        let startedMs = APIPerformanceMonitor.uptimeMilliseconds()
        do {
            let current = try readTranscript(sessionID: sessionID)
            let document = try snapshotDocument(current: current, version: version)
            let locations = try locationsForValidatedTranscript(document)
            performanceMonitor.record(.transcriptSnapshot, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: document.spans.count)
            return (document, locations)
        } catch {
            performanceMonitor.record(.transcriptSnapshot, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: 0, failed: true)
            throw error
        }
    }

    private func snapshotDocument(current: TranscriptDocument, version: Int64?) throws -> TranscriptDocument {
        if let version, version != current.version {
            guard version > 0, version < current.version,
                  let row = try database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=?",
                    [.text(current.sessionID.uuidString), .integer(version)]).first else { throw ArchiveError.staleSource }
            let snapshot = try decodeStoredTranscript(row.requireData(0))
            guard snapshot.generation == current.generation else { throw ArchiveError.staleSource }
            return snapshot
        }
        return current
    }

    /// A cited span remains valid after an append; revisions and deletions still invalidate its identity.
    public func transcriptLocations(sources: [SourceReference]) throws -> [UUID: [UUID: TranscriptSpanLocation]] {
        try validateSources(sources)
        var result: [UUID: [UUID: TranscriptSpanLocation]] = [:]
        for (sessionID, references) in Dictionary(grouping: sources, by: \.sessionID) {
            let snapshot = try transcriptSnapshot(sessionID: sessionID)
            let ids = Set(references.map(\.spanID))
            result[sessionID] = snapshot.locations.filter { ids.contains($0.key) }
        }
        return result
    }

    public func recordings(limit: Int = 50) throws -> [RecordingSummary] {
        try recordingsPage(limit: limit).items
    }

    func transcriptionState(sessionID: UUID) throws -> RecordingTranscriptionState {
        let key: [SQLValue] = [.text(sessionID.uuidString)]
        let jobs = try database.rows("SELECT j.state,c.retention FROM transcription_jobs j JOIN chunks c ON c.id=j.chunk_id WHERE c.session_id=?", key)
        if jobs.contains(where: { $0.string(0) == "failed" || $0.string(1) == "missing_unexpected" }) { return .failed }
        let activeAnalysis = try database.rows("SELECT 1 FROM analysis_epochs a JOIN epochs e ON e.id=a.epoch_id WHERE e.session_id=? AND a.attempt_id IS NOT NULL LIMIT 1", key)
        let windows = try database.rows("SELECT state FROM analysis_windows WHERE session_id=?", key)
        if !activeAnalysis.isEmpty || jobs.contains(where: { $0.string(0) == "running" }) || windows.contains(where: { $0.string(0) == "running" }) { return .processing }
        if jobs.isEmpty || jobs.contains(where: { $0.string(0) == "pending" }) || windows.contains(where: { $0.string(0) == "pending" }) { return .pending }
        let hasText = try !database.rows("SELECT 1 FROM transcript_search WHERE session_id=? LIMIT 1", key).isEmpty
        if hasText { return .transcribed }
        let hasRecognitionResult = try !database.rows("SELECT 1 FROM transcript_versions WHERE session_id=? LIMIT 1", key).isEmpty
        if hasRecognitionResult || windows.contains(where: { $0.string(0) == "complete" }) { return .completedWithoutText }
        return try receivedAudioHasExplicitNoSpeech(sessionID: sessionID) ? .noSpeech : .completedWithoutText
    }

    func receivedAudioHasExplicitNoSpeech(sessionID: UUID) throws -> Bool {
        let chunkRows = try database.rows("SELECT epoch_id,start_frame,end_frame FROM chunks WHERE session_id=?", [.text(sessionID.uuidString)])
        guard !chunkRows.isEmpty else { return false }
        var chunksByEpoch: [UUID: [FrameRange]] = [:]
        for row in chunkRows {
            let epochID = try row.requireUUID(0)
            let start = try row.requireInt(1), end = try row.requireInt(2)
            chunksByEpoch[epochID, default: []].append(try FrameRange(start: start, count: end - start))
        }
        for (epochID, chunkFrames) in chunksByEpoch {
            var configurations: [String: [FrameRange]] = [:]
            for row in try database.rows("SELECT configuration_hash,start_frame,end_frame FROM analysis_coverage WHERE epoch_id=? AND kind='no_speech'", [.text(epochID.uuidString)]) {
                let range = try FrameRange(start: row.requireInt(1), count: row.requireInt(2) - row.requireInt(1))
                configurations[try row.requireString(0), default: []].append(range)
            }
            // A missing interval is not silence, and partial results from different models do not form one verdict.
            guard configurations.values.contains(where: { ranges in chunkFrames.allSatisfy { covers($0, with: ranges) } }) else { return false }
        }
        return true
    }

    public func contextStatus() throws -> ArchiveContextStatus {
        let count = try database.rows("SELECT COUNT(*) FROM sessions WHERE deleted=0").first?.integer(0) ?? 0
        let pending = try database.rows("SELECT COUNT(*) FROM transcription_jobs WHERE state IN ('pending','running')").first?.integer(0) ?? 0
        let latest = try database.rows("SELECT v.document FROM transcript_versions v JOIN sessions s ON s.id=v.session_id AND s.transcript_version=v.version WHERE s.deleted=0 ORDER BY v.rowid DESC LIMIT 1").first
        let date: Date?
        if let latest { date = try decodeStoredTranscript(latest.requireData(0)).updatedAt }
        else { date = nil }
        return ArchiveContextStatus(recordingCount: Int(count), pendingAnalysisCount: Int(pending), latestTranscriptAt: date)
    }

    public func searchTranscripts(query: String, limit: Int = 20) throws -> [TranscriptSearchHit] {
        try searchTranscriptsPage(query: query, limit: limit).items
    }

    public func validateSources(_ sources: [SourceReference]) throws {
        guard sources.count <= Self.maximumSourceReferences else { throw ArchiveError.invalidQuery }
        // A large read shares documents; validate each version once, rather than decoding it once per span.
        for (sessionID, references) in Dictionary(grouping: sources, by: \.sessionID) {
            let current = try readTranscript(sessionID: sessionID)
            var currentSpans: [UUID: TranscriptSpan] = [:]
            var currentIndices: [UUID: Int] = [:]
            currentSpans.reserveCapacity(current.spans.count)
            currentIndices.reserveCapacity(current.spans.count)
            for (idx, span) in current.spans.enumerated() {
                currentSpans[span.id] = span
                currentIndices[span.id] = idx
            }
            for (version, citations) in Dictionary(grouping: references, by: \.transcriptVersion) {
                if version == current.version {
                    for source in citations {
                        guard source.generation == current.generation,
                              currentSpans[source.spanID] != nil else {
                            throw ArchiveError.staleSource
                        }
                    }
                    continue
                }
                guard version > 0, version < current.version,
                      let row = try database.rows(
                          "SELECT document FROM transcript_versions WHERE session_id=? AND version=?",
                          [.text(current.sessionID.uuidString), .integer(version)]
                      ).first else {
                    throw ArchiveError.staleSource
                }
                let neededIDs = Set(citations.map(\.spanID))
                let hints = neededIDs.compactMap { currentIndices[$0] }
                let citedSpans = try decodeStoredTranscriptSpans(
                    row.requireData(0),
                    expectedGeneration: current.generation,
                    spanIDs: neededIDs,
                    hintIndices: hints
                )
                for source in citations {
                    guard source.generation == current.generation,
                          let span = currentSpans[source.spanID], citedSpans[source.spanID] == span else {
                        throw ArchiveError.staleSource
                    }
                }
            }
        }
    }

    public func registerAgentSources(agentSessionID: UUID, sources: [SourceReference]) throws {
        try database.transaction {
            guard try agentCanResume(agentSessionID: agentSessionID) else { throw ArchiveError.staleSource }
            try validateSources(sources)
            for references in Dictionary(grouping: sources, by: \.sessionID).values {
                guard let source = references.max(by: { $0.transcriptVersion < $1.transcriptVersion }) else { continue }
                try database.execute("INSERT INTO agent_sources(agent_session_id,session_id,version,generation) VALUES(?,?,?,?) ON CONFLICT(agent_session_id,session_id) DO UPDATE SET version=excluded.version,generation=excluded.generation", [.text(agentSessionID.uuidString), .text(source.sessionID.uuidString), .integer(source.transcriptVersion), .integer(source.generation)])
            }
        }
    }

    public func agentCanResume(agentSessionID: UUID) throws -> Bool {
        try database.rows("SELECT completed FROM agent_cleanup WHERE agent_session_id=?", [.text(agentSessionID.uuidString)]).first?.integer(0) != 0
    }

    public func pendingAgentCleanups() throws -> [UUID] {
        try database.rows("SELECT agent_session_id FROM agent_cleanup WHERE completed=0").map { try $0.requireUUID(0) }
    }

    public func markAgentCleanupCompleted(agentSessionID: UUID) throws {
        try database.transaction {
            try database.execute("DELETE FROM agent_sources WHERE agent_session_id=?", [.text(agentSessionID.uuidString)])
            try database.execute("UPDATE agent_cleanup SET completed=1 WHERE agent_session_id=?", [.text(agentSessionID.uuidString)])
        }
    }

    public func reviseTranscript(sessionID: UUID, expectedVersion: Int64, spans: [TranscriptSpan]) throws -> TranscriptDocument {
        try database.transaction {
            guard let old = try currentTranscriptOrNil(sessionID: sessionID) else { throw ArchiveError.missingTranscript(sessionID) }
            guard old.version == expectedVersion, Set(spans.map(\.id)).count == spans.count,
                  spans.allSatisfy({ edited in
                    old.spans.contains(where: { $0.id == edited.id && $0.chunkID == edited.chunkID && $0.frames == edited.frames && $0.sourceRanges == edited.sourceRanges })
                        && !edited.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && edited.text.utf8.count <= 65_536
                  }) else { throw ArchiveError.staleSource }
            let generation = old.generation + 1
            let retained = Set(spans.map(\.id))
            var removedObservations = false
            var removedVoiceprintExemplar = false
            for removed in old.spans where !retained.contains(removed.id) {
                let sid = SQLValue.text(removed.id.uuidString)
                if let obs = try database.rows("SELECT confirmed_person FROM speaker_observations WHERE span_id=?", [sid]).first {
                    removedObservations = true
                    if try obs.string(0) != nil || !database.rows("SELECT 1 FROM voice_rejections WHERE span_id=? LIMIT 1", [sid]).isEmpty {
                        removedVoiceprintExemplar = true
                    }
                    try database.execute("DELETE FROM speaker_observations WHERE span_id=?", [sid])
                }
            }
            let document = TranscriptDocument(sessionID: sessionID, version: old.version + 1, generation: generation, spans: spans, updatedAt: Date())
            let discarded = old.spans.filter { oldSpan in
                !TranscriptText.hasContent(oldSpan.text) && !spans.contains(where: { $0.id == oldSpan.id })
            }
            for chunkID in Set(discarded.map(\.chunkID)) {
                try database.execute("UPDATE transcription_jobs SET error_code='discarded_punctuation' WHERE state='complete' AND chunk_id=?", [.text(chunkID.uuidString)])
            }
            let discardedIDs = Set(discarded.map(\.id))
            if !discardedIDs.isEmpty {
                for row in try database.rows("SELECT id FROM analysis_windows WHERE session_id=? AND state='complete'", [.text(sessionID.uuidString)]) {
                    let id = try row.requireString(0)
                    if discardedIDs.contains(try spanID(windowID: id)) {
                        try database.execute("UPDATE analysis_windows SET raw_result=? WHERE id=?", [.blob(TranscriptText.discardedPunctuation), .text(id)])
                    }
                }
            }
            try database.execute("UPDATE sessions SET generation=?,projection_blocked=0 WHERE id=?", [.integer(generation), .text(sessionID.uuidString)])
            // Text edits invalidate active attempts, not the remaining audio or committed analysis checkpoints.
            try database.execute("UPDATE transcription_jobs SET generation=?,state='pending',attempt_id=NULL WHERE chunk_id IN (SELECT id FROM chunks WHERE session_id=?) AND state IN ('running','pending')", [.integer(generation), .text(sessionID.uuidString)])
            // Keep failures stopped, but eligible for an explicit retry against the revised recording.
            try database.execute("UPDATE transcription_jobs SET generation=? WHERE chunk_id IN (SELECT id FROM chunks WHERE session_id=?) AND state='failed'", [.integer(generation), .text(sessionID.uuidString)])
            try database.execute("UPDATE analysis_epochs SET generation=?,attempt_id=NULL WHERE epoch_id IN (SELECT id FROM epochs WHERE session_id=?)", [.integer(generation), .text(sessionID.uuidString)])
            try database.execute("DELETE FROM analysis_range_inputs WHERE epoch_id IN (SELECT id FROM epochs WHERE session_id=?)", [.text(sessionID.uuidString)])
            try database.execute("UPDATE analysis_windows SET generation=?,state='pending',attempt_id=NULL WHERE session_id=? AND state IN ('pending','running')", [.integer(generation), .text(sessionID.uuidString)])
            try storeDocument(document, invalidatesExistingSources: true, knownPrevious: .some(old))
            if removedVoiceprintExemplar {
                invalidateVoiceprintCache()
                try refreshSpeakerMatches(editedSessions: [sessionID])
            } else if removedObservations {
                _ = try reconcileSpeakerClusters(sessionID: sessionID)
                invalidateTransductiveVoiceprintCache()
            }
            return document
        }
    }

    func currentTranscriptOrNil(sessionID: UUID) throws -> TranscriptDocument? {
        guard let state = try database.rows("SELECT deleted,transcript_version,generation FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first else { return nil }
        guard state.integer(0) == 0 else {
            removeTranscriptReadCache(sessionID)
            throw ArchiveError.sessionDeleted(sessionID)
        }
        let externalVersion = try database.rows("PRAGMA data_version").first?.requireInt(0) ?? 0
        if externalVersion != transcriptReadDataVersion {
            transcriptReadCache.removeAll(); transcriptReadRecency.removeAll(); transcriptReadCacheCost = 0
            transcriptBlockPrefixCache.removeAll()
            chunkOrderCache.removeAll(); chunkOrderRecency.removeAll()
            transcriptReadDataVersion = externalVersion
        }
        let version = try state.requireInt(1), generation = try state.requireInt(2)
        if !database.isInTransaction, let cached = transcriptReadCache[sessionID],
           cached.document.version == version, cached.document.generation == generation {
            transcriptReadRecency.removeAll { $0 == sessionID }; transcriptReadRecency.append(sessionID)
            return cached.document
        }
        removeTranscriptReadCache(sessionID)
        guard let row = try database.rows("SELECT v.document FROM transcript_versions v JOIN sessions s ON s.id=v.session_id AND s.transcript_version=v.version WHERE s.id=?", [.text(sessionID.uuidString)]).first else { return nil }
        let bytes = try row.requireData(0)
        let document = try decodeStoredTranscript(bytes)
        #if DEBUG
        transcriptReadDecodeCount += 1
        #endif
        // A rolled-back transaction must never populate the reusable read cache.
        if !database.isInTransaction, bytes.count <= 8 * 1024 * 1024 {
            transcriptReadCache[sessionID] = (document, bytes.count)
            transcriptReadCacheCost += bytes.count; transcriptReadRecency.append(sessionID)
            while transcriptReadRecency.count > 8 || transcriptReadCacheCost > 8 * 1024 * 1024 {
                guard let oldest = transcriptReadRecency.first else { break }
                removeTranscriptReadCache(oldest)
            }
        }
        return document
    }

    private func removeTranscriptReadCache(_ sessionID: UUID) {
        if let previous = transcriptReadCache.removeValue(forKey: sessionID) { transcriptReadCacheCost -= previous.cost }
        transcriptReadRecency.removeAll { $0 == sessionID }
    }

    func cacheCommittedWindowTranscript(
        _ document: TranscriptDocument,
        encodedByteCount: Int,
        previousCompactedPrefix: (fullSpanCount: Int, blockIDs: [Int64])?
    ) {
        guard !database.isInTransaction else { return }
        if let externalVersion = try? database.rows("PRAGMA data_version").first?.requireInt(0),
           externalVersion != transcriptReadDataVersion {
            transcriptReadCache.removeAll(); transcriptReadRecency.removeAll(); transcriptReadCacheCost = 0
            transcriptBlockPrefixCache.removeAll()
            chunkOrderCache.removeAll(); chunkOrderRecency.removeAll()
            transcriptReadDataVersion = externalVersion
        }
        removeTranscriptReadCache(document.sessionID)
        if encodedByteCount <= 8 * 1024 * 1024 {
            transcriptReadCache[document.sessionID] = (document, encodedByteCount)
            transcriptReadCacheCost += encodedByteCount
            transcriptReadRecency.append(document.sessionID)
            while transcriptReadRecency.count > 8 || transcriptReadCacheCost > 8 * 1024 * 1024 {
                guard let oldest = transcriptReadRecency.first else { break }
                removeTranscriptReadCache(oldest)
            }
        }
        if let prefix = previousCompactedPrefix {
            transcriptBlockPrefixCache[document.sessionID] = (
                version: document.version,
                generation: document.generation,
                fullSpanCount: prefix.fullSpanCount,
                blockIDs: prefix.blockIDs
            )
            if transcriptBlockPrefixCache.count > 16,
               let evict = transcriptBlockPrefixCache.keys.first(where: { $0 != document.sessionID }) {
                transcriptBlockPrefixCache.removeValue(forKey: evict)
            }
        } else {
            transcriptBlockPrefixCache.removeValue(forKey: document.sessionID)
        }
    }

    /// List rows need one short line, not a decoded copy of every transcript.
    public func transcriptPreview(sessionID: UUID, expectedVersion: Int64, expectedGeneration: Int64) throws -> String? {
        let row = try database.rows("""
            SELECT transcript_preview FROM sessions
            WHERE id=? AND deleted=0 AND projection_blocked=0 AND transcript_version=? AND generation=?
            """, [.text(sessionID.uuidString), .integer(expectedVersion), .integer(expectedGeneration)]).first
        return row?.string(0)
    }

    /// Batched preview lookup for an entire library page in one actor turn and one SQL query.
    public func transcriptPreviews(
        requests: [(sessionID: UUID, expectedVersion: Int64, expectedGeneration: Int64)]
    ) throws -> [UUID: String] {
        guard !requests.isEmpty else { return [:] }
        return try performanceMonitor.measure(.transcriptPreviewsBatch, itemCount: requests.count) {
            let expectedByID = Dictionary(
                requests.map { ($0.sessionID, (version: $0.expectedVersion, generation: $0.expectedGeneration)) },
                uniquingKeysWith: { _, latest in latest }
            )
            let placeholders = Array(repeating: "?", count: expectedByID.count).joined(separator: ",")
            let parameters = expectedByID.keys.map { SQLValue.text($0.uuidString) }
            let rows = try database.rows("""
                SELECT id, transcript_version, generation, transcript_preview
                FROM sessions
                WHERE id IN (\(placeholders)) AND deleted=0 AND projection_blocked=0 AND transcript_preview IS NOT NULL
                """, parameters)
            var result: [UUID: String] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let id = try row.requireUUID(0)
                guard let expected = expectedByID[id],
                      try row.requireInt(1) == expected.version,
                      try row.requireInt(2) == expected.generation,
                      let preview = row.string(3) else { continue }
                result[id] = preview
            }
            return result
        }
    }

    @discardableResult
    func storeDocument(_ document: TranscriptDocument, invalidatesExistingSources: Bool = false,
                       appendingSpans: [TranscriptSpan]? = nil,
                       knownPrevious: TranscriptDocument?? = nil,
                       trustedPreviousBlockPrefix: (fullSpanCount: Int, blockIDs: [Int64])? = nil,
                       preencodedDocument: Data? = nil) throws -> (encodedBytes: Int, compactedPrefix: (fullSpanCount: Int, blockIDs: [Int64])?) {
        if document.spans.contains(where: { !TranscriptText.hasContent($0.text) }) {
            try database.execute("DELETE FROM metadata WHERE key=?", [.text(Self.discardedPunctuationMigrationKey)])
        }
        let previous = try knownPrevious ?? currentTranscriptOrNil(sessionID: document.sessionID)
        removeTranscriptReadCache(document.sessionID)
        if appendingSpans == nil {
            transcriptBlockPrefixCache.removeValue(forKey: document.sessionID)
        }
        if verifiedRecordingFilesCache[document.sessionID]?.independentOfTranscriptVersion != true {
            verifiedRecordingFilesCache.removeValue(forKey: document.sessionID)
        }
        var compactedPrefix: (fullSpanCount: Int, blockIDs: [Int64])?
        if let previous {
            let previousCompacted = try compactTranscriptVersion(
                previous,
                trustedPrefix: appendingSpans != nil ? trustedPreviousBlockPrefix : nil
            )
            if appendingSpans != nil {
                // Out-of-order chunks can insert spans before the tail via orderedSpans; only
                // full 16-span blocks within the unchanged leading prefix may carry forward.
                let commonPrefixCount = zip(previous.spans, document.spans).prefix(while: { $0 == $1 }).count
                let reusableBlocks = min(previousCompacted.blockIDs.count, commonPrefixCount / 16)
                compactedPrefix = (
                    fullSpanCount: reusableBlocks * 16,
                    blockIDs: Array(previousCompacted.blockIDs.prefix(reusableBlocks))
                )
            }
        }
        let encoded = try preencodedDocument ?? WireJSON.encode(document)
        try database.execute("INSERT INTO transcript_versions(session_id,version,document) VALUES(?,?,?)", [.text(document.sessionID.uuidString), .integer(document.version), .blob(encoded)])
        let preview = document.spans.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { SQLValue.text(String($0.text.prefix(160))) } ?? .null
        try database.execute("UPDATE sessions SET transcript_version=?,transcript_preview=? WHERE id=?",
            [.integer(document.version), preview, .text(document.sessionID.uuidString)])
        // Append recognition never changes earlier spans. Speaker-only updates preserve span IDs and text.
        if let appendingSpans {
            for span in appendingSpans {
                try database.execute("INSERT INTO transcript_search(session_id,span_id,text,version) VALUES(?,?,?,?)", [.text(document.sessionID.uuidString), .text(span.id.uuidString), .text(span.text), .integer(document.version)])
            }
        } else if let previous,
                  previous.spans.count == document.spans.count,
                  zip(previous.spans, document.spans).allSatisfy({ $0.id == $1.id && $0.text == $1.text }) {
            try database.execute("UPDATE transcript_search SET version=? WHERE session_id=?",
                [.integer(document.version), .text(document.sessionID.uuidString)])
        } else {
            try database.execute("DELETE FROM transcript_search WHERE session_id=?", [.text(document.sessionID.uuidString)])
            for span in document.spans {
                try database.execute("INSERT INTO transcript_search(session_id,span_id,text,version) VALUES(?,?,?,?)", [.text(document.sessionID.uuidString), .text(span.id.uuidString), .text(span.text), .integer(document.version)])
            }
        }
        if invalidatesExistingSources {
            try invalidateAgentSources(sessionID: document.sessionID)
            try database.execute("UPDATE plans SET state='invalidated',document=X'',files_cleaned=0 WHERE id IN (SELECT plan_id FROM plan_sources WHERE session_id=?)", [.text(document.sessionID.uuidString)])
            hasPendingFileDeletions = true
        }
        return (encoded.count, appendingSpans != nil ? (compactedPrefix ?? (0, [])) : nil)
    }

    func invalidateAgentSources(sessionID: UUID) throws {
        try database.execute("INSERT INTO agent_cleanup(agent_session_id,completed) SELECT agent_session_id,0 FROM agent_sources WHERE session_id=? ON CONFLICT(agent_session_id) DO UPDATE SET completed=0", [.text(sessionID.uuidString)])
    }

    func orderedSpans(_ spans: [TranscriptSpan], sessionID: UUID) throws -> [TranscriptSpan] {
        guard spans.count > 1 else { return spans }
        var order = chunkOrderCache[sessionID]
        if let cached = order, spans.allSatisfy({ cached[$0.chunkID] != nil }) {
            // Reuse cached immutable (wall_clock_anchor, epoch_id) map when every referenced chunk is present.
        } else {
            var loaded: [UUID: (Double, UUID)] = [:]
            for row in try database.rows("SELECT id,wall_clock_anchor,epoch_id FROM chunks WHERE session_id=?", [.text(sessionID.uuidString)]) {
                loaded[try row.requireUUID(0)] = (row.double(1) ?? 0, try row.requireUUID(2))
            }
            order = loaded
            if !database.isInTransaction || loaded.count <= 4_096 {
                chunkOrderCache[sessionID] = loaded
                chunkOrderRecency.removeAll { $0 == sessionID }
                chunkOrderRecency.append(sessionID)
                while chunkOrderRecency.count > 16 {
                    let evicted = chunkOrderRecency.removeFirst()
                    chunkOrderCache.removeValue(forKey: evicted)
                }
            }
        }
        let map = order!
        func precedesOrEquals(_ lhs: TranscriptSpan, _ rhs: TranscriptSpan) -> Bool {
            guard let left = map[lhs.chunkID], let right = map[rhs.chunkID] else {
                return lhs.id.uuidString <= rhs.id.uuidString
            }
            if left.1 == right.1 { return lhs.frames.start <= rhs.frames.start }
            return left.0 <= right.0
        }
        var alreadyOrdered = true
        for idx in 1..<spans.count {
            if !precedesOrEquals(spans[idx - 1], spans[idx]) {
                alreadyOrdered = false
                break
            }
        }
        if alreadyOrdered { return spans }
        return spans.sorted {
            guard let left = map[$0.chunkID], let right = map[$1.chunkID] else { return $0.id.uuidString < $1.id.uuidString }
            if left.1 == right.1 { return $0.frames.start < $1.frames.start }
            return left.0 < right.0
        }
    }
}
