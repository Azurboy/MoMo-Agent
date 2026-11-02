import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TranscriptionThroughputTests {
    private let fingerprint = ContentHash.sha256(Data("transcript-append-throughput".utf8))

    @Test func recognitionAppendsIndexOnlyNewSpansAndKeepPreviewsSourcesAndSnapshots() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store(), count = 200
        try await prepareWindows(count, fixture: fixture, store: store)
        try await store.observeIndexMutations()
        var firstSource: SourceReference?
        for index in 0..<count {
            let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
            let text = index == 0 ? "最早的人声记录" : "追加的人声记录 \(index)"
            let document = try await store.commitWindowTranscript(ticket: ticket, text: text, rawResult: Data("{}".utf8))
            if index == 0 { firstSource = document.source(for: try #require(document.spans.first)) }
        }
        let mutations = try await store.indexMutations()
        let current = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(mutations["insert"] == Int64(count))
        #expect(mutations["delete", default: 0] == 0)
        #expect(try await store.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: Int64(count),
            expectedGeneration: current.generation) == "最早的人声记录")
        let source = try #require(firstSource)
        try await store.validateSources([source])
        let original = try await store.transcriptSnapshot(sessionID: fixture.sessionID, version: 1)
        #expect(original.document.spans.count == 1)
        #expect(try await store.searchTranscripts(query: "最早的人声记录").count == 1)
        let matches = try await store.searchTranscriptsPage(query: "追加的人声记录", limit: 100)
        #expect(matches.items.count == 100)
        #expect(matches.nextCursor != nil)

        let first = try #require(current.spans.first)
        let edited = TranscriptSpan(id: first.id, chunkID: first.chunkID, frames: first.frames,
            text: "人工修订后的内容", sourceRanges: first.sourceRanges)
        let revised = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: current.version, spans: [edited])
        #expect(try await store.searchTranscripts(query: "追加的人声记录").isEmpty)
        #expect(try await store.searchTranscripts(query: "人工修订后的内容").count == 1)
        await #expect(throws: ArchiveError.staleSource) { try await store.validateSources([source]) }
        let reopened = try fixture.store()
        #expect(try await reopened.searchTranscripts(query: "人工修订后的内容").count == 1)
        #expect(try await reopened.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: Int64(count + 1),
            expectedGeneration: revised.generation) == "人工修订后的内容")
    }

    @Test func anEmptyRecognitionKeepsEarlierSearchRowsVisible() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        try await prepareWindows(2, fixture: fixture, store: store)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: first, text: "保留这句正文", rawResult: Data("{}".utf8))
        let second = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        try await store.observeIndexMutations()
        let last = try await store.commitWindowTranscript(ticket: second, text: "……", rawResult: Data("{}".utf8))
        #expect(try await store.indexMutations().isEmpty)
        #expect(try await store.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: 2,
            expectedGeneration: last.generation) == "保留这句正文")
    }

    @Test func outOfOrderRecognitionKeepsPreviewInDocumentOrder() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        try await prepareWindows(2, fixture: fixture, store: store)
        let earlier = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let later = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        #expect(earlier.window.coreFrames.start < later.window.coreFrames.start)
        _ = try await store.commitWindowTranscript(ticket: later, text: "先识别的较晚录音", rawResult: Data("{}".utf8))
        let completed = try await store.commitWindowTranscript(ticket: earlier, text: "后补的最早录音", rawResult: Data("{}".utf8))
        #expect(completed.spans.first?.text == "后补的最早录音")
        #expect(try await store.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: completed.version,
            expectedGeneration: completed.generation) == "后补的最早录音")
        let reopened = try fixture.store()
        #expect(try await reopened.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: completed.version,
            expectedGeneration: completed.generation) == "后补的最早录音")
        _ = try await reopened.deleteSession(id: fixture.sessionID)
        #expect(try await reopened.persistedPreview(sessionID: fixture.sessionID) == nil)
    }

    @Test func outOfOrderGapCommitAcrossCompactedBlockBoundaryPreservesHistoryAndProjection() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        try await prepareWindows(22, fixture: fixture, store: store)
        var tickets: [TranscriptionWindowTicket] = []
        for _ in 0..<22 {
            tickets.append(try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint)))
        }
        var committedByVersion: [Int64: TranscriptDocument] = [:]
        for index in Array(0..<15) + Array(16..<20) {
            let doc = try await store.commitWindowTranscript(
                ticket: tickets[index],
                text: "片段-\(index)",
                rawResult: Data("{}".utf8)
            )
            committedByVersion[doc.version] = doc
        }
        let gapInserted = try await store.commitWindowTranscript(
            ticket: tickets[15],
            text: "补齐乱序缺口-15",
            rawResult: Data("{}".utf8)
        )
        committedByVersion[gapInserted.version] = gapInserted
        #expect(gapInserted.version == 20)
        #expect(gapInserted.spans[15].text == "补齐乱序缺口-15")
        try await store.projectPendingDocuments(sessionID: fixture.sessionID, includeUnchanged: false)

        for index in 20..<22 {
            let doc = try await store.commitWindowTranscript(
                ticket: tickets[index],
                text: "片段-\(index)",
                rawResult: Data("{}".utf8)
            )
            committedByVersion[doc.version] = doc
        }
        try await store.projectPendingDocuments(sessionID: fixture.sessionID, includeUnchanged: false)
        #expect(try await !store.projectionIsBlocked(fixture.sessionID))
        #expect(try await store.recordingFileIssues(sessionID: fixture.sessionID).isEmpty)

        for version in Int64(1)...22 {
            let expected = try #require(committedByVersion[version])
            let actual = try await store.transcriptSnapshot(sessionID: fixture.sessionID, version: version).document
            #expect(actual.spans == expected.spans)
            #expect(Set(actual.spans.map(\.id)).count == actual.spans.count)
        }
        let reconciled = try await store.reconcileDocumentFiles()
        #expect(reconciled.first?.issue == nil)
        #expect(try await !store.projectionIsBlocked(fixture.sessionID))
    }

    @Test func schemaTenMigrationBackfillsPreviewWithoutChangingSources() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let first = try #require(document.spans.first)
        let source = document.source(for: first)
        try await store.makeSchemaTenForPreviewMigration()
        let reopened = try fixture.store()
        #expect(try await reopened.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: document.version,
            expectedGeneration: document.generation) == String(first.text.prefix(160)))
        try await reopened.validateSources([source])
        #expect(try await WireJSON.encode(reopened.readTranscript(sessionID: fixture.sessionID)) == WireJSON.encode(document))
    }

    @Test func failedIncrementalIndexWriteRollsBackDocumentAndLeavesWindowRetryable() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        try await prepareWindows(2, fixture: fixture, store: store)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: first, text: "第一次识别", rawResult: Data("{}".utf8))
        let second = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        try await store.failNextIndexWrite()
        await #expect(throws: ArchiveError.self) {
            _ = try await store.commitWindowTranscript(ticket: second, text: "下一次识别", rawResult: Data("{}".utf8))
        }
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).version == 1)
        #expect(try await store.persistedPreview(sessionID: fixture.sessionID) == "第一次识别")
        #expect(try await store.searchTranscripts(query: "第一次识别").count == 1)
        #expect(try await store.searchTranscripts(query: "下一次识别").isEmpty)
        try await store.stopFailingIndexWrites()
        let retried = try await store.commitWindowTranscript(ticket: second, text: "下一次识别", rawResult: Data("{}".utf8))
        #expect(retried.version == 2 && retried.spans.count == 2)
    }

    @Test func targetedProjectionLeavesUnrelatedExternalEditsForNormalReconciliation() async throws {
        let selected = try Fixture(), other = try Fixture()
        defer { selected.remove(); other.remove() }
        let store = try selected.store()
        let first = try await selected.transcribe(store)
        _ = try await other.transcribe(store)
        try await store.projectPendingDocuments()
        let otherURL = try await store.transcriptFileURL(sessionID: other.sessionID)
        try Data("外部编辑，等待正常核对".utf8).write(to: otherURL)
        let span = try #require(first.spans.first)
        let changed = TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames,
            text: "只更新这段录音", sourceRanges: span.sourceRanges)
        _ = try await store.reviseTranscript(sessionID: selected.sessionID, expectedVersion: first.version, spans: [changed])
        try await store.projectPendingDocuments(sessionID: selected.sessionID)
        let selectedURL = try await store.transcriptFileURL(sessionID: selected.sessionID)
        #expect(try String(contentsOf: selectedURL, encoding: .utf8).contains("只更新这段录音"))
        #expect(try await !store.projectionIsBlocked(other.sessionID))
        #expect(try String(contentsOf: otherURL, encoding: .utf8) == "外部编辑，等待正常核对")
        try await store.projectPendingDocuments()
        #expect(try await store.projectionIsBlocked(other.sessionID))
    }

    private func prepareWindows(_ count: Int, fixture: Fixture, store: ArchiveStore) async throws {
        let envelope = try fixture.envelope(), manifest = envelope.manifest
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: manifest.frames.end)
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let windows = try (0..<count).map { index in
            let start = Int64(index) * 1_600 / Int64(count), end = Int64(index + 1) * 1_600 / Int64(count)
            let frames = try FrameRange(start: start, count: end - start)
            return ArchiveAnalysisWindow(id: ContentHash.sha256(Data("window-\(index)".utf8)), sessionID: fixture.sessionID,
                epochID: fixture.epochID, analysisAnchor: 0, coreFrames: frames, contextFrames: frames,
                modelCoreFrames: frames, modelContextFrames: frames, sources: [ArchiveWindowSource(chunkID: manifest.chunkID,
                    manifestSHA256: envelope.manifestSHA256, audioSHA256: manifest.audioSHA256, sourceFrames: frames)],
                configurationFingerprint: fingerprint)
        }
        try await store.commitAnalysisBatch(ticket: ticket, windows: windows, analyzedCoverage: [manifest.frames],
            noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
    }
}

private extension ArchiveStore {
    func persistedPreview(sessionID: UUID) throws -> String? {
        try database.rows("SELECT transcript_preview FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.string(0)
    }
    func makeSchemaTenForPreviewMigration() throws {
        try database.transaction {
            try restoreLegacyHistoryForTests()
            try database.execute("ALTER TABLE sessions DROP COLUMN transcript_preview")
            try database.execute("PRAGMA user_version=10")
        }
    }
    func observeIndexMutations() throws {
        try database.execute("CREATE TEMP TABLE index_mutations(kind TEXT NOT NULL)")
        for (name, operation) in [("insert", "INSERT"), ("delete", "DELETE")] {
            try database.execute("CREATE TEMP TRIGGER observe_index_\(name) AFTER \(operation) ON transcript_search BEGIN INSERT INTO index_mutations VALUES('\(name)'); END")
        }
    }
    func indexMutations() throws -> [String: Int64] {
        try Dictionary(uniqueKeysWithValues: database.rows("SELECT kind,count(*) FROM index_mutations GROUP BY kind")
            .map { (try $0.requireString(0), try $0.requireInt(1)) })
    }
    func failNextIndexWrite() throws {
        try database.execute("CREATE TEMP TRIGGER fail_index BEFORE INSERT ON transcript_search BEGIN SELECT RAISE(ABORT,'controlled index failure'); END")
    }
    func stopFailingIndexWrites() throws { try database.execute("DROP TRIGGER fail_index") }
    func projectionIsBlocked(_ sessionID: UUID) throws -> Bool {
        try database.rows("SELECT projection_blocked FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.requireInt(0) == 1
    }
}
