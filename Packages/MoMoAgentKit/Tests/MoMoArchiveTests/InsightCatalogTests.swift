import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct InsightCatalogTests {
    @Test func unchangedAndReceiptOnlyRequestsReuseTheCatalogAndLocalChangesRebuildOneRecording() async throws {
        let f = try Fixture(), other = try Fixture(); defer { f.remove(); other.remove() }
        let store = try f.store()
        _ = try await store.commitReceivedChunk(f.deliver(f.envelope(), to: store))
        _ = try await store.commitReceivedChunk(f.deliver(other.envelope(), to: store, audio: other.audio))
        let first = try await store.insightTimelineCatalog()
        #expect(await store.insightCatalogSessionBuildCount == 2)
        for _ in 0..<20 { #expect(try await store.insightTimelineCatalog().revision == first.revision) }
        try await store.changeReceiptForCatalogTest()
        #expect(try await store.insightTimelineCatalog().revision == first.revision)
        #expect(await store.insightCatalogSessionBuildCount == 2)
        _ = try await store.commitReceivedChunk(f.deliver(f.envelope(startFrame: 1_600, sequence: 1), to: store))
        #expect(try await store.insightTimelineCatalog().revision != first.revision)
        #expect(await store.insightCatalogSessionBuildCount == 3)
        let reopened = try f.store()
        let original = try await store.insightTimelineCatalog()
        #expect(try await reopened.insightTimelineCatalog().revision == original.revision)
    }

    @Test func newTextInTheSameCrossDayRecordingLeavesTheEarlierDayUnchanged() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let first = try crossingEnvelope(f, index: 0)
        _ = try await store.commitReceivedChunk(f.deliver(first, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "catalog-test"))
        _ = try await store.commitTranscript(ticket: ticket, spans: [TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "前一天确认的方案")])
        try await store.addCoverageForCatalogTest(epochID: f.epochID, through: 1_600)
        let before = try await store.insightTimelineCatalog()
        let oldDay = try #require(before.days.first)
        let second = try crossingEnvelope(f, index: 1)
        _ = try await store.commitReceivedChunk(f.deliver(second, to: store))
        let next = try #require(await store.claimAnalysisJob(configurationHash: "catalog-test"))
        _ = try await store.commitTranscript(ticket: next, spans: [TranscriptSpan(chunkID: next.chunkID, frames: next.manifest.frames, text: "新一天增加的讨论")])
        try await store.addCoverageForCatalogTest(epochID: f.epochID, through: 3_200)
        let after = try await store.insightTimelineCatalog()
        #expect(after.days.count == 2)
        #expect(after.dayRevisions[oldDay.id] == before.dayRevisions[oldDay.id])
        let reopened = try f.store()
        #expect(try await reopened.insightTimelineCatalog().dayRevisions == after.dayRevisions)
    }

    @Test func deletionAndAnExternalConnectionCannotLeaveAStaleCatalog() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        _ = try await store.commitReceivedChunk(f.deliver(f.envelope(), to: store))
        let before = try await store.insightTimelineCatalog()
        let external = try ArchiveDatabase(url: store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite"))
        try external.execute("UPDATE sessions SET projection_blocked=1 WHERE id=?", [.text(f.sessionID.uuidString)])
        #expect(try await store.insightTimelineCatalog().revision != before.revision)
        _ = try await store.deleteSession(id: f.sessionID)
        #expect(try await store.insightTimelineCatalog().days.isEmpty)
    }

    @Test func aRolledBackEditCannotPopulateTheReusableCatalogCache() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        _ = try await store.commitReceivedChunk(f.deliver(f.envelope(), to: store))
        let before = try await store.insightTimelineCatalog()
        try await store.rollbackCatalogMutationForTest(sessionID: f.sessionID)
        #expect(try await store.insightTimelineCatalog().revision == before.revision)
    }

    @Test func pendingProjectionSurvivesReopenAndDoesNotInspectUnchangedHistoricalFiles() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        _ = try await f.transcribe(store)
        try await store.projectPendingDocuments(includeUnchanged: false)
        let directory = try await store.transcriptFileURL(sessionID: f.sessionID).deletingLastPathComponent()
        _ = try await store.commitReceivedChunk(f.deliver(f.envelope(startFrame: 1_600, sequence: 1), to: store))
        let reopened = try f.store()
        try await reopened.projectPendingDocuments(includeUnchanged: false)
        #expect(try WireJSON.decode(RecordingManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))).chunks.count == 2)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("manifest.json"))
        try await reopened.projectPendingDocuments(includeUnchanged: false)
        #expect(try await reopened.readTranscript(sessionID: f.sessionID).spans.count == 1)
        #expect(try await reopened.reconcileDocumentFiles().first?.issue != nil)
    }

    private func crossingEnvelope(_ f: Fixture, index: Int) throws -> ManifestEnvelope {
        let m = try f.envelope().manifest
        return try ManifestEnvelope(manifest: ChunkManifest(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, sourceBuild: "cross-day-test", sequence: Int64(index),
            frames: FrameRange(start: Int64(index * 1_600), count: 1_600), timebaseHz: 16_000,
            wallClockAnchor: Date(timeIntervalSince1970: 86_400 + Double(TimelineDay.currentStartHour) * 3_600 - 0.1), timezoneOffset: 0,
            codec: m.codec, sampleRate: m.sampleRate, channels: m.channels, decodedFrameCount: 1_600,
            byteCount: m.byteCount, audioSHA256: m.audioSHA256, sourceKind: .fixture))
    }
}

private extension ArchiveStore {
    func changeReceiptForCatalogTest() throws { try database.execute("UPDATE receipt_outbox SET sent=1") }
    func addCoverageForCatalogTest(epochID: UUID, through end: Int64) throws {
        try database.execute("INSERT INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind) VALUES(?,'catalog-test',0,?,'analyzed')", [.text(epochID.uuidString), .integer(end)])
    }
    func rollbackCatalogMutationForTest(sessionID: UUID) throws {
        do {
            try database.transaction {
                try database.execute("UPDATE sessions SET projection_blocked=1 WHERE id=?", [.text(sessionID.uuidString)])
                _ = try insightTimelineCatalog()
                throw CatalogRollback.expected
            }
        } catch CatalogRollback.expected { }
    }
}

private enum CatalogRollback: Error { case expected }
