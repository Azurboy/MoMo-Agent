import Foundation
import XCTest
import MoMoAgentClient
import MoMoArchive
import MoMoContracts
@testable import MoMoAgent

@MainActor
final class RemoteContextSyncTests: XCTestCase {
    func testChangeDuringUploadRemainsPendingAfterTheEarlierReceipt() async throws {
        let (sync, root, archive, connection) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        try sync.markSourcesChanged()
        let received = expectation(description: "Mac received source, receipt still in flight")
        MemoryResponse.state.holdNextSource(received)
        defer { MemoryResponse.state.releaseSource() }
        let upload = Task { try await sync.synchronize(includeMemories: false) }
        await fulfillment(of: [received], timeout: 5)
        try sync.markSourcesChanged()
        MemoryResponse.state.releaseSource()
        try await upload.value
        XCTAssertTrue(sync.needsDelivery, "The earlier receipt cannot acknowledge a newer archive change")
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertTrue(restored.needsDelivery)
        let acknowledged = MemoryResponse.state.syncedSourceIDs
        try await restored.synchronize(includeMemories: false)
        XCTAssertFalse(restored.needsDelivery)
        XCTAssertEqual(MemoryResponse.state.syncedSourceIDs, acknowledged)
    }

    func testOfflineBackgroundOutboxSurvivesRestartAndAcknowledgedSourceIsNotReplayed() async throws {
        let (sync, root, archive, connection) = try fixture()
        _ = try await summaryWindow(archive: archive, root: root)
        try sync.markSourcesChanged()
        MemoryResponse.state.rejectSources = true
        do {
            try await sync.synchronize(includeMemories: false)
            XCTFail("The offline source must remain pending")
        } catch { }
        XCTAssertTrue(sync.needsDelivery)
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertTrue(restored.needsDelivery)
        MemoryResponse.state.rejectSources = false
        try await restored.synchronize(includeMemories: false)
        XCTAssertFalse(restored.needsDelivery)
        XCTAssertTrue(restored.memories.isEmpty, "Background delivery does not refresh the memory UI")
        let acknowledged = MemoryResponse.state.syncedSourceIDs
        try await restored.synchronize(includeMemories: false)
        XCTAssertEqual(MemoryResponse.state.syncedSourceIDs, acknowledged)
        let reopened = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection,
                                           key: "fixture", configuration: configuration())
        XCTAssertFalse(reopened.needsDelivery)
    }

    func testMemoryExcerptOnlyMovesRecognizedSourcePrefix() {
        let stamped = "10/29–30 录音 0fcdf941-b14c-4087-ad0e-a3eab9495fe2 v78 (归属/执行未核)：保留这段内容。"
        let preview = MemoryPreview(text: stamped)
        XCTAssertEqual(preview.date, "10/29–30")
        XCTAssertEqual(preview.text, "保留这段内容。")
        XCTAssertEqual(preview.sourceNote, "归属/执行未核")
        for text in ["11/3 提醒我复测 v2 模型。", "正文里引用 0fcdf941-b14c-4087-ad0e-a3eab9495fe2，不应删除。", "10/29 0fcdf941-b14c-4087-ad0e-a3eab9495fe2 v78", "10/29 录音 invalid-id v78 仍要显示。"] {
            XCTAssertEqual(MemoryPreview(text: text).text, text)
            XCTAssertNil(MemoryPreview(text: text).date)
        }
    }

    func testRecordingSummaryOutboxResumesAndCachesWithoutModelKey() async throws {
        let (sync, root, archive, connection) = try fixture()
        let window = try await summaryWindow(archive: archive, root: root)
        let first = try XCTUnwrap(sync.recordingSummaries)
        let pending = try await first.summaries(for: [window])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(MemoryResponse.state.requests, 0, "Offline queueing must not wait for the Mac")
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration())
        let summaries = try XCTUnwrap(restored.recordingSummaries)
        let received = expectation(description: "Mac summary applied after reopening")
        summaries.onChanged = { received.fulfill() }
        summaries.foreground()
        await fulfillment(of: [received], timeout: 8)
        summaries.background()
        XCTAssertEqual(MemoryResponse.state.requests, 2, "POST admits once; GET retrieves the completed result")
        let cache = try await summaries.summaries(for: [window])
        XCTAssertEqual(cache[window.summaryRevision], "团队决定周五交付。")
        let again = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration())
        let cached = try await again.recordingSummaries?.summaries(for: [window])
        XCTAssertEqual(cached, cache)
        let requests = MemoryResponse.state.requests
        _ = try await archive.deleteSession(id: window.paragraphs[0].source.sessionID)
        let removed = try await again.recordingSummaries?.summaries(for: [window])
        XCTAssertTrue(removed?.isEmpty == true, "Deleted source must never revive its old summary")
        XCTAssertEqual(requests, MemoryResponse.state.requests)
    }

    private func summaryWindow(archive: ArchiveStore, root: URL) async throws -> TimelineWindow {
        let audio = Self.makeWAVFixture(), now = Date()
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(), chunkID: UUID(),
            sourceDeviceID: UUID(), sourceBuild: "tests", sequence: 0, frames: FrameRange(start: 0, count: 1600),
            timebaseHz: 16000, wallClockAnchor: now, timezoneOffset: 28800, codec: .pcmInt16, sampleRate: 16000,
            channels: 1, decodedFrameCount: 1600, byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio),
            sealedAt: now, sourceKind: .fixture))
        let file = root.appendingPathComponent(UUID().uuidString)
        try audio.write(to: file)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: file, envelope: envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "summary-test")
        let ticket = try XCTUnwrap(claimed)
        let span = TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames,
                                  text: "团队今天讨论了发布安排，明确决定下周五交付第一版，并由小林准备演示材料。")
        _ = try await archive.commitTranscript(ticket: ticket, spans: [span])
        let snapshot = try await archive.transcriptSnapshot(sessionID: ticket.manifest.sessionID)
        let found = try await archive.timelineWindow(containing: snapshot.document.source(for: span))
        return try XCTUnwrap(found)
    }
    func testOrdinaryChatDoesNotWaitForArchiveOrMemoryDownload() async throws {
        let (sync, _, _, _) = try fixture()
        try await sync.prepareSubmission(input: "你好，接着聊")
        XCTAssertEqual(MemoryResponse.state.requests, 0)
    }
    func testNativeMemoryCacheSurvivesRestartAndFailedDeleteIsNotQueued() async throws {
        let (sync, root, archive, connection) = try fixture()
        await sync.refresh()
        XCTAssertNil(sync.failure); XCTAssertEqual(sync.memories.first?.basis, "hermes")
        let memory = try XCTUnwrap(sync.memories.first)
        await sync.forget(memory)
        XCTAssertNotNil(sync.failure); XCTAssertEqual(sync.memories.count, 1)
        XCTAssertFalse(sync.hasLegacyChanges, "This version edits Hermes online, without a second offline mutation engine")
        let restored = try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration())
        XCTAssertEqual(restored.memories.first?.id, memory.id)
        XCTAssertNotNil(restored.lastSourcesSent)
    }
    func testPendingUntranscribedRecordingDoesNotBlockOlderTranscriptDelivery() async throws {
        let (sync, root, archive, _) = try fixture()
        let fingerprint = ContentHash.sha256(Data("pending-sync-test".utf8))
        sync.configurationFingerprint = fingerprint
        let audio = Self.makeWAVFixture()
        func deliver(sessionID: UUID, anchor: Date) async throws {
            let envelope = try ManifestEnvelope(manifest: ChunkManifest(
                sessionID: sessionID, epochID: UUID(), chunkID: UUID(), sourceDeviceID: UUID(), sourceBuild: "tests",
                sequence: 0, frames: FrameRange(start: 0, count: 1600), timebaseHz: 16000, wallClockAnchor: anchor,
                timezoneOffset: 28800, codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: 1600,
                byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sealedAt: anchor, sourceKind: .fixture))
            let file = root.appendingPathComponent(UUID().uuidString)
            try audio.write(to: file)
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: file, envelope: envelope))
        }
        let transcribedSession = UUID()
        try await deliver(sessionID: transcribedSession, anchor: Date(timeIntervalSince1970: 1_790_000_000))
        let claimed = try await archive.claimAnalysisJob(configurationHash: fingerprint)
        let ticket = try XCTUnwrap(claimed)
        _ = try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "已经转写完成的录音")
        ])
        // Newer recording whose only recognition result was punctuation (version == 1, spans == []).
        let punctuationSession = UUID()
        try await deliver(sessionID: punctuationSession, anchor: Date(timeIntervalSince1970: 1_790_000_050))
        let claimedPunctuation = try await archive.claimAnalysisJob(configurationHash: fingerprint)
        let punctuationTicket = try XCTUnwrap(claimedPunctuation)
        _ = try await archive.commitTranscript(ticket: punctuationTicket, spans: [
            TranscriptSpan(chunkID: punctuationTicket.chunkID, frames: punctuationTicket.manifest.frames, text: "，。")
        ])
        // Newest recording without any transcript version yet (appears first on recordingsPage).
        let pendingSession = UUID()
        try await deliver(sessionID: pendingSession, anchor: Date(timeIntervalSince1970: 1_790_000_100))
        await sync.refresh()
        XCTAssertNil(sync.failure)
        XCTAssertEqual(sync.pendingSources, 0)
        let sourcePrefix = archive.libraryInstanceID.uuidString.lowercased() + "/"
        XCTAssertEqual(MemoryResponse.state.syncedSourceIDs, [sourcePrefix + pendingSession.uuidString.lowercased(), sourcePrefix + transcribedSession.uuidString.lowercased()])
        let pending = try XCTUnwrap(MemoryResponse.state.sourcePayloads.first)
        XCTAssertTrue(pending.spans.isEmpty)
        XCTAssertEqual(pending.pendingTranscriptionRanges, [.init(start: 1_790_000_100, end: 1_790_000_100.1)])
        let claimedAnalysis = try await archive.claimEpochAnalysis(configurationFingerprint: fingerprint,
            sessionID: pendingSession, expectedGeneration: pending.generation)
        let analysis = try XCTUnwrap(claimedAnalysis)
        let frames = try XCTUnwrap(analysis.inputs.first?.envelope.manifest.frames)
        try await archive.commitAnalysisBatch(ticket: analysis, windows: [], analyzedCoverage: [frames],
            noSpeechCoverage: [frames], checkpoint: nil, waitingForMoreAudio: true)
        await sync.refresh()
        XCTAssertNil(sync.failure)
        let finished = try XCTUnwrap(MemoryResponse.state.sourcePayloads.last)
        XCTAssertEqual(finished.sourceID, pending.sourceID)
        XCTAssertEqual(finished.version, pending.version)
        XCTAssertEqual(finished.textSha256, pending.textSha256)
        XCTAssertEqual(finished.pendingTranscriptionRanges, [])
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MemoryResponse.self]; return config
    }
    private func fixture() throws -> (PhoneContextSync, URL, ArchiveStore, AgentConnection) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoNativeMemory-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let url = URL(string: "http://127.0.0.1:8765")!
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: url, dataURL: url)
        MemoryResponse.state.reset(connection.workspaceID)
        return (try PhoneContextSync(directory: root, archive: archive, deviceID: UUID(), connection: connection, key: "fixture", configuration: configuration()), root, archive, connection)
    }
    private static func makeWAVFixture() -> Data {
        var data = Data("RIFF".utf8)
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(3236); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(3200); data.append(Data(repeating: 0, count: 3200))
        return data
    }
}
private final class MemoryResponse: URLProtocol, @unchecked Sendable {
    static let state = MemoryResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Self.state.receive(request)
        let respond: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        if !Self.state.holdResponse(request, respond: respond) { respond() }
    }
    override func stopLoading() {}
}
private final class MemoryResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var workspace = UUID(), count = 0, synced: [String] = []
    private var summaryRevision: String?
    private var payloads: [SourceEnvelope] = []
    private var rejected = false
    private var waitingForSource: XCTestExpectation?
    private var heldResponse: (@Sendable () -> Void)?
    func holdNextSource(_ waiting: XCTestExpectation) { lock.withLock { waitingForSource = waiting } }
    func holdResponse(_ request: URLRequest, respond: @escaping @Sendable () -> Void) -> Bool {
        guard request.url?.path == "/v1/sources", request.httpMethod == "POST" else { return false }
        return lock.withLock {
            guard let waitingForSource else { return false }
            self.waitingForSource = nil; heldResponse = respond
            waitingForSource.fulfill()
            return true
        }
    }
    func releaseSource() {
        let response = lock.withLock { let response = heldResponse; heldResponse = nil; return response }
        response?()
    }
    var rejectSources: Bool {
        get { lock.withLock { rejected } }
        set { lock.withLock { rejected = newValue } }
    }
    var requests: Int { lock.withLock { count } }
    var syncedSourceIDs: [String] { lock.withLock { synced } }
    var sourcePayloads: [SourceEnvelope] { lock.withLock { payloads } }
    func reset(_ workspace: UUID) { lock.withLock { self.workspace = workspace; count = 0; synced = []; payloads = []; summaryRevision = nil; rejected = false } }
    func receive(_ request: URLRequest) -> (Int, String) {
        lock.withLock {
            count += 1
            if request.url?.path == "/v1/summaries", request.httpMethod == "POST",
               let body = request.BodyData,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let revision = json["revision"] as? String {
                summaryRevision = revision
                return (200, "{\"id\":\"summary-fixture\",\"revision\":\"\(revision)\",\"state\":\"pending\"}")
            }
            if request.url?.path == "/v1/summaries", request.httpMethod == "GET", let revision = summaryRevision {
                return (200, "{\"id\":\"summary-fixture\",\"revision\":\"\(revision)\",\"state\":\"done\",\"text\":\"团队决定周五交付。\"}")
            }
            if request.url?.path == "/v1/status" {
                return (200, "{\"workspace_id\":\"\(workspace)\",\"source_sync\":true,\"memory_writer\":\"Hermes\"}")
            }
            if request.url?.path == "/v1/sources", rejected { return (503, "{}") }
            if request.url?.path == "/v1/sources", request.httpMethod == "POST",
               let body = request.BodyData,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let lib = json["library_id"] as? String, let sess = json["session_id"] as? String,
               let gen = json["generation"] as? Int, let ver = json["version"] as? Int,
               let sha = json["text_sha256"] as? String, let del = json["deleted"] as? Bool {
                let sourceID = "\(lib)/\(sess)"
                synced.append(sourceID)
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let envelope = try? decoder.decode(SourceEnvelope.self, from: body) { payloads.append(envelope) }
                let rev = "\(gen):\(ver):\(sha):\(del ? 1 : 0)"
                return (200, "{\"source_id\":\"\(sourceID)\",\"source_revision\":\"\(rev)\",\"revision\":1}")
            }
            if request.url?.path == "/v1/memories" {
                return (200, #"{"revision":1,"next_cursor":null,"items":[{"id":"hermes-memory-fixture","text":"下周五发方案","kind":"memory","basis":"hermes","status":"current","revision":1,"evidence":[]}]}"#)
            }
            return (503, "{}")
        }
    }
}
private extension URLRequest {
    var BodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}
