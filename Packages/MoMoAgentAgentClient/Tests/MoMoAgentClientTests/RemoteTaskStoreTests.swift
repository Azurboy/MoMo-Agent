import Foundation
import XCTest
@testable import MoMoAgentClient

@MainActor
final class RemoteTaskStoreTests: XCTestCase {
    private func setup(now: @escaping () -> Date = Date.init) throws -> (URL, AgentConnection, AgentClient, RemoteTaskStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("tasks.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(),
                                         baseURL: URL(string: "https://fixture.invalid")!)
        DeliveryProtocol.configure(connection)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeliveryProtocol.self]
        let client = try AgentClient(baseURL: connection.baseURL, credential: "synthetic", assistantID: connection.assistantID,
                                     configuration: configuration)
        return (file, connection, client, try RemoteTaskStore(file: file, connection: connection, client: client, now: now))
    }

    func testLostReceiptReplaysIdenticalOperationAfterProcessReconstruction() async throws {
        let state = DeliveryScenario(receiptsToLose: 2)
        DeliveryProtocol.install(state)
        let (file, connection, client, first) = try setup()
        first.setDraft("Write a synthetic receipt")
        let operation = try first.enqueue()
        await first.refresh()
        XCTAssertNil(first.tasks.first?.run)
        XCTAssertNotNil(first.tasks.first?.firstAttemptAt)
        XCTAssertFalse(first.tasks[0].deliveryFailed, "A lost receipt must not flash a failed delivery")
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertFalse(reopened.tasks[0].deliveryFailed, "Pending recovery survives process reconstruction")
        await reopened.refresh()
        XCTAssertEqual(reopened.tasks.first?.id, operation)
        XCTAssertFalse(reopened.tasks[0].deliveryFailed)
        XCTAssertEqual(state.submissions.count, 3, "One immediate retry, then recovery replays only the original operation")
        await reopened.checkAgain(id: operation)
        XCTAssertEqual(reopened.tasks.first?.run?.runID, "run-one")
        let requests = state.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(state.submissions[0], state.submissions[1])
        XCTAssertEqual(state.submissions[0], state.submissions[2])
    }

    func testAcceptedTaskIsRecoveredByGetAndBackgroundNeverStopsIt() async throws {
        let state = DeliveryScenario(); DeliveryProtocol.install(state)
        let (file, connection, client, first) = try setup()
        first.setDraft("Keep running on Mac"); try first.enqueue(); await first.refresh()
        first.background()
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        await reopened.refresh()
        XCTAssertEqual(reopened.tasks.first?.run?.output, "actual-result")
        XCTAssertTrue(reopened.tasks.first?.isFinished == true)
        XCTAssertEqual(state.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertFalse(state.requests.contains { $0.url!.path.hasSuffix("/stop") })
    }

    func testLostStatusIsVisibleAndRecoveryOnlyReadsTheAcceptedRun() async throws {
        let state = DeliveryScenario(loseFirstStatus: true); DeliveryProtocol.install(state)
        let (_, _, _, store) = try setup()
        store.setDraft("Recover the existing result"); let id = try store.enqueue()
        await store.refresh()
        XCTAssertEqual(store.interruptedTask?.id, id)
        XCTAssertFalse(store.hasActiveTask, "A disconnected status read must not keep the avatar working")
        XCTAssertFalse(store.tasks[0].deliveryFailed, "The Mac already accepted this message")
        await store.checkAgain(id: id)
        XCTAssertNil(store.interruptedTask)
        XCTAssertEqual(store.tasks[0].run?.output, "actual-result")
        XCTAssertTrue(store.tasks[0].isFinished)
        XCTAssertEqual(state.submissions.count, 1)
        XCTAssertFalse(state.requests.contains { $0.url!.path.hasSuffix("/stop") })
    }

    func testExpiredAmbiguousSubmissionCannotExecuteAgain() async throws {
        let state = DeliveryScenario(receiptsToLose: 2); DeliveryProtocol.install(state)
        let date = Date(timeIntervalSince1970: 1_000_000)
        let (file, connection, client, first) = try setup(now: { date })
        first.setDraft("An external side effect"); try first.enqueue(); await first.refresh()
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client,
                                          now: { date.addingTimeInterval(86_401) })
        await reopened.refresh()
        await reopened.checkAgain(id: reopened.tasks[0].id)
        XCTAssertTrue(reopened.tasks[0].needsReview)
        XCTAssertEqual(state.submissions.count, 2, "Both attempts precede expiry; no new admission after expiry")
    }

    func testUnknownRunNeverBecomesSuccessOrResubmission() async throws {
        let state = DeliveryScenario(status: "unknown"); DeliveryProtocol.install(state)
        let (_, _, _, store) = try setup()
        store.setDraft("Check original work"); try store.enqueue(); await store.refresh(); await store.refresh()
        XCTAssertTrue(store.tasks[0].needsReview)
        XCTAssertFalse(store.tasks[0].isFinished)
        await store.checkAgain(id: store.tasks[0].id)
        XCTAssertEqual(state.submissions.count, 1)
    }

    func testMissingAcceptedRunIsNotResubmitted() async throws {
        let state = DeliveryScenario(missingRun: true); DeliveryProtocol.install(state)
        let (_, _, _, store) = try setup()
        store.setDraft("Do not duplicate"); try store.enqueue(); await store.refresh(); await store.refresh()
        XCTAssertTrue(store.tasks[0].needsReview)
        XCTAssertFalse(store.tasks[0].isFinished)
        await store.checkAgain(id: store.tasks[0].id)
        XCTAssertEqual(state.submissions.count, 1)
    }

    func testSourcesMustBeAcknowledgedBeforeTaskAdmission() async throws {
        let state = DeliveryScenario(); DeliveryProtocol.install(state)
        let (_, _, _, store) = try setup()
        store.prepareSubmission = { task in
            XCTAssertEqual(task.input, "Use the recording")
            throw URLError(.notConnectedToInternet)
        }
        store.setDraft("Use the recording"); try store.enqueue(); await store.refresh()
        XCTAssertNil(store.tasks[0].firstAttemptAt)
        XCTAssertTrue(state.submissions.isEmpty)
        store.prepareSubmission = { _ in }; await store.checkAgain(id: store.tasks[0].id)
        XCTAssertEqual(state.submissions.count, 1)
    }

    func testCorruptOrDifferentIdentityJournalIsPreserved() throws {
        let (file, connection, client, store) = try setup()
        store.setDraft("Keep this draft")
        let original = try Data(contentsOf: file)
        let other = AgentConnection(workspaceID: connection.workspaceID, assistantID: connection.assistantID,
                                    instanceID: UUID(), baseURL: connection.baseURL)
        XCTAssertThrowsError(try RemoteTaskStore(file: file, connection: other, client: client))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let corrupt = Data("broken journal".utf8); try corrupt.write(to: file)
        XCTAssertThrowsError(try RemoteTaskStore(file: file, connection: connection, client: client))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testFailedLocalCommitDoesNotSubmitOrClearTheDraft() async throws {
        let state = DeliveryScenario(); DeliveryProtocol.install(state)
        let (file, _, _, store) = try setup()
        store.setDraft("Do not lose this input")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.enqueue())
        await store.refresh()
        XCTAssertEqual(store.draft, "Do not lose this input")
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertFalse(state.requests.contains { $0.httpMethod == "POST" })
    }

    func testRichHTMLAndMarkdownDeliverablesDecodeAndResolveAcrossMessagesAndWorkDetail() throws {
        let htmlID = UUID()
        let mdID = UUID()
        let htmlDoc = AgentAttachment(
            id: htmlID,
            name: "startup-roadmap.html",
            kind: .document,
            mediaType: "text/html",
            byteCount: 120_000,
            text: String(repeating: "a", count: 120_000)
        )
        let mdDoc = AgentAttachment(
            id: mdID,
            name: "competitive-matrix.md",
            kind: .document,
            mediaType: "text/markdown",
            byteCount: 80_000,
            text: String(repeating: "#", count: 80_000)
        )
        XCTAssertTrue(htmlDoc.isHTMLDocument)
        XCTAssertFalse(htmlDoc.isMarkdownDocument)
        XCTAssertTrue(mdDoc.isMarkdownDocument)
        XCTAssertFalse(mdDoc.isHTMLDocument)
        XCTAssertNoThrow(try AgentAttachment.validate([htmlDoc, mdDoc]))

        let oversized = AgentAttachment(
            name: "oversized.md",
            kind: .document,
            mediaType: "text/markdown",
            byteCount: 260_000,
            text: String(repeating: "x", count: 260_000)
        )
        XCTAssertThrowsError(try AgentAttachment.validate([oversized]))

        // Server-generated deliverables up to 512 KB decode without client upload validation limits.
        let serverDeliverableID = UUID()
        let serverPageJSON = """
        {
          "data": [{
            "id": "msg-proactive-1",
            "seq": 1,
            "role": "assistant",
            "content": "已为你整理好创业方案对比与原型。",
            "created_at": 1730620000.0,
            "run_id": "superagent:tkt-1",
            "attachments": [{
              "id": "\(serverDeliverableID.uuidString.lowercased())",
              "name": "interactive-prototype.html",
              "kind": "document",
              "media_type": "text/html",
              "byte_count": 320000,
              "text": "\(String(repeating: "p", count: 320_000))"
            }]
          }],
          "next_cursor": 1,
          "has_more": false
        }
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(ConversationPage.self, from: serverPageJSON)
        XCTAssertEqual(page.data.first?.attachments?.first?.id, serverDeliverableID)
        XCTAssertEqual(page.data.first?.attachments?.first?.isHTMLDocument, true)

        let detailWithAttachmentsJSON = """
        {
          "id": "sa_ticket:tkt-1",
          "ticket_id": "tkt-1",
          "title": "调研 AI 硬件创业切入点并输出可交互方案",
          "status": "completed",
          "status_label": "已完成",
          "origin_kind": "proactive_recording",
          "origin_label": "主动发现 · 录音触发",
          "cancellable": false,
          "matched_rules": ["research_and_synthesis"],
          "turn_count": 2,
          "step_count": 5,
          "todos": [],
          "activities": [],
          "attachments": [{
            "id": "\(mdID.uuidString.lowercased())",
            "name": "research-brief.md",
            "kind": "document",
            "media_type": "text/markdown",
            "byte_count": 2048,
            "text": "# 创业调研报告\\n\\n- 方案 A\\n- 方案 B"
          }]
        }
        """.data(using: .utf8)!
        let detail = try JSONDecoder().decode(ConversationWorkDetail.self, from: detailWithAttachmentsJSON)
        XCTAssertEqual(detail.attachments.count, 1)
        XCTAssertEqual(detail.attachments.first?.id, mdID)
        XCTAssertEqual(detail.attachments.first?.isMarkdownDocument, true)

        // Legacy work detail payloads without "attachments" still decode cleanly to [].
        let legacyDetailJSON = """
        {
          "id": "sa_ticket:tkt-legacy",
          "title": "旧版任务",
          "status": "completed",
          "status_label": "已完成",
          "origin_kind": "proactive_recording",
          "origin_label": "主动发现",
          "cancellable": false
        }
        """.data(using: .utf8)!
        let legacyDetail = try JSONDecoder().decode(ConversationWorkDetail.self, from: legacyDetailJSON)
        XCTAssertTrue(legacyDetail.attachments.isEmpty)
    }
}

private final class DeliveryScenario: @unchecked Sendable {
    var connection: AgentConnection?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var bodies: [Data] = []
    private var session = ""
    private var polls = 0
    let receiptsToLose: Int
    let status: String
    let missingRun: Bool
    let loseFirstStatus: Bool
    init(receiptsToLose: Int = 0, status: String = "running", missingRun: Bool = false, loseFirstStatus: Bool = false) {
        self.receiptsToLose = receiptsToLose; self.status = status; self.missingRun = missingRun
        self.loseFirstStatus = loseFirstStatus
    }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var submissions: [Data] { lock.withLock { bodies } }

    func reply(_ request: URLRequest) throws -> Data {
        try lock.withLock {
            recorded.append(request)
            if request.url!.path == "/momo/v1/conversation" {
                let c = connection!
                session = "momo-main-" + c.assistantID.uuidString.lowercased()
                return try JSONSerialization.data(withJSONObject: ["conversation_id": "fixture", "session_id": session,
                    "assistant_id": c.assistantID.uuidString, "instance_id": c.instanceID.uuidString,
                    "capabilities": ["shared_conversation": true, "server_owned_completion": true, "durable_steering": true, "independent_chat_while_waiting": false, "system_push": false]])
            }
            if request.httpMethod == "GET", request.url!.path == "/momo/v1/conversation/messages" { return Data(#"{"data":[],"next_cursor":0,"has_more":false}"#.utf8) }
            if request.url!.path == "/momo/v1/conversation/runs" { return Data(#"{"data":[]}"#.utf8) }
            if request.url!.path.hasSuffix("/capabilities") {
                return Data(#"{"features":{"run_submission":true,"runs_idempotency":{"supported":true,"durable":true,"retention_seconds":86400}}}"#.utf8)
            }
            if request.httpMethod == "POST" {
                let stream = request.httpBodyStream!
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(buffer, count: count)
                }
                bodies.append(body)
                if bodies.count <= receiptsToLose { throw URLError(.timedOut) }
                return try JSONSerialization.data(withJSONObject: ["run_id": "run-one", "status": "started"])
            }
            polls += 1
            if loseFirstStatus && polls == 1 { throw URLError(.badURL) }
            return try JSONSerialization.data(withJSONObject: ["run_id": "run-one", "session_id": session,
                                                               "status": status == "unknown" ? "unknown" : polls == 1 ? "running" : "completed", "output": "actual-result"])
        }
    }
}

private final class DeliveryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenario: DeliveryScenario?
    static func install(_ value: DeliveryScenario) { lock.withLock { scenario = value } }
    static func configure(_ connection: AgentConnection) { lock.withLock { scenario?.connection = connection } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let state = Self.lock.withLock { Self.scenario! }
            let data = try state.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: state.missingRun && request.httpMethod == "GET" && request.url!.path.contains("/runs/") ? 404 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
