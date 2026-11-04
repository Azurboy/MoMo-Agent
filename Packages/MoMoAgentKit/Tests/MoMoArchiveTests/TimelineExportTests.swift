import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TimelineExportTests {
    // 2026-10-20 08:00:00 +08:00 (default 08:00 recording-day boundary between 2026-10-19 and 2026-10-20).
    private let boundary = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!

    @Test func dayMatchesRecordingLocalDateAndIncludesMarksWithoutNeedingCaptureEndOrAudio() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let old = try await receive(f, store: store, at: boundary.addingTimeInterval(-60), text: "昨天的文字")
        _ = try await receive(f, store: store, at: boundary, text: "今天的文字 <script> & **原样**")
        let manifest = old.manifest
        try await store.receiveMark(CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: manifest.sourceDeviceID, sourceFrame: 800))
        for receipt in try await store.pendingReceipts() { try await store.applyReceipt(ReceiptApplied(receipt: receipt)) }
        _ = try await store.expireAudio(olderThan: .distantFuture, replayFloors: [manifest.epochID: 1600])
        let day = TimelineDay(boundary.addingTimeInterval(-1 + 28_800), calendar: TimelineDay.calendar)
        let artifact = try await store.prepareTimelineExport(scope: .day(day))
        #expect(artifact.fileURLs.count == 1)
        #expect(artifact.fileURLs[0].lastPathComponent == "2026-10-19.md")
        let markdown = try String(contentsOf: artifact.fileURLs[0], encoding: .utf8)
        #expect(markdown.contains("昨天的文字"))
        #expect(!markdown.contains("今天的文字"))
        #expect(markdown.contains("⚑"))
        #expect(markdown.contains("2026-10-20 07:59:00 +08:00"))
        try await store.validateExportSource(artifact)
        try await store.removeExport(artifact)
        #expect(!FileManager.default.fileExists(atPath: artifact.fileURLs[0].path))
    }

    @Test func intervalCrossesMidnightSortsAndExcludesBothOutsideBoundaries() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let start = boundary.addingTimeInterval(-60), end = boundary.addingTimeInterval(60)
        _ = try await receive(f, store: store, at: end, text: "不包含结束边界")
        _ = try await receive(f, store: store, at: boundary, text: "第二段 <html> & **原样**")
        _ = try await receive(f, store: store, at: start.addingTimeInterval(-1), text: "不包含开始之前")
        _ = try await receive(f, store: store, at: start, text: "第一段")
        let artifact = try await store.prepareTimelineExport(scope: .interval(DateInterval(start: start, end: end)))
        let markdown = try String(contentsOf: artifact.fileURLs[0], encoding: .utf8)
        #expect(markdown.contains("第一段") && markdown.contains("第二段"))
        #expect(!markdown.contains("不包含"))
        #expect(try #require(markdown.range(of: "第一段")).lowerBound < #require(markdown.range(of: "第二段")).lowerBound)
        #expect(markdown.contains("&lt;html&gt; &amp; \\*\\*原样\\*\\*"))
        #expect(artifact.fileURLs[0].pathExtension == "md")
        try await store.removeExport(artifact)
    }

    @Test func emptyRangeCreatesNoFileAndSourceRevisionOrDeletionRejectsSharing() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        let scope = TimelineExportScope.day(TimelineDay(boundary.addingTimeInterval(28_800), calendar: TimelineDay.calendar))
        await #expect(throws: ArchiveExportError.noTranscriptInRange) { try await store.prepareTimelineExport(scope: scope) }
        let received = try await receive(f, store: store, at: boundary, text: "原来的安排")
        let artifact = try await store.prepareTimelineExport(scope: scope)
        let span = received.document.spans[0]
        _ = try await store.reviseTranscript(sessionID: received.manifest.sessionID, expectedVersion: received.document.version,
            spans: [TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames, text: "更正后的安排")])
        await #expect(throws: ArchiveExportError.sourceChanged) { try await store.validateExportSource(artifact) }
        let revised = try await store.prepareTimelineExport(scope: scope)
        _ = try await store.deleteSession(id: received.manifest.sessionID)
        await #expect(throws: ArchiveExportError.sourceChanged) { try await store.validateExportSource(revised) }
        try await store.removeExport(artifact)
        try await store.removeExport(revised)
        #expect(try await store.storageUsage(modelDirectory: nil).temporaryBytes == 0)
    }

    @Test func invalidIntervalIsRejected() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store()
        await #expect(throws: ArchiveError.invalidQuery) {
            try await store.prepareTimelineExport(scope: .interval(DateInterval(start: boundary, duration: 0)))
        }
    }

    private func receive(_ f: Fixture, store: ArchiveStore, at date: Date, text: String) async throws
        -> (manifest: ChunkManifest, document: TranscriptDocument) {
        let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), chunkID: UUID(), sourceDeviceID: f.deviceID,
            sourceBuild: "timeline-export-test", sequence: 0, frames: FrameRange(start: 0, count: 1600), timebaseHz: 16000,
            wallClockAnchor: date, timezoneOffset: 28800, codec: .pcmInt16, sampleRate: 16000, channels: 1,
            decodedFrameCount: 1600, byteCount: Int64(f.audio.count), audioSHA256: ContentHash.sha256(f.audio),
            sealedAt: date.addingTimeInterval(1), sourceKind: .fixture)
        _ = try await store.commitReceivedChunk(f.deliver(ManifestEnvelope(manifest: manifest), to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "timeline-export-test"))
        let document = try await store.commitTranscript(ticket: ticket,
            spans: [TranscriptSpan(chunkID: manifest.chunkID, frames: manifest.frames, text: text)])
        return (manifest, document)
    }
}
