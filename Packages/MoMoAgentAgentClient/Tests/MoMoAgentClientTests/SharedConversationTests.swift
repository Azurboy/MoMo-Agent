import Foundation
import XCTest
@testable import MoMoAgentClient

@MainActor final class SharedConversationTests: XCTestCase {
    func testAutomaticRecoveryKeepsDisconnectedStateUntilResponseArrives() async throws {
        let (wire, connection, client, folder) = try fixture()
        var clock = Date(timeIntervalSince1970: 1000)
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("recovery.json"), connection: connection, client: client, now: { clock })
        await store.refresh()
        store.setDraft("keep my draft")
        let cursor = store.messageCursor
        await wire.setSyncOffline(true); await store.refresh()
        XCTAssertEqual(store.connectionState, .retrying)
        clock = try XCTUnwrap(store.nextConnectionAttempt).addingTimeInterval(1)
        await wire.setSyncOffline(false); await wire.holdRead()
        let recovery = Task { await store.refresh() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await wire.readHeld), ContinuousClock.now < deadline { await Task.yield() }
        let held = await wire.readHeld
        XCTAssertTrue(held)
        XCTAssertEqual(store.connectionState, .retrying, "Starting a retry is not evidence of a connection")
        XCTAssertEqual(store.draft, "keep my draft")
        XCTAssertEqual(store.messageCursor, cursor)
        await wire.releaseRead(); await recovery.value
        XCTAssertEqual(store.connectionState, .ready)
    }

    func testAutomaticRecoveryRetriesOutboxWithOriginalOperationWithoutManualAction() async throws {
        let (wire, connection, client, folder) = try fixture()
        var clock = Date(timeIntervalSince1970: 1000)
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("outbox-recovery.json"), connection: connection, client: client, now: { clock })
        await store.refresh()
        await wire.setHTTPStatus(503)
        store.setDraft("Hello"); let operation = try store.enqueue()
        await store.refresh(userInitiated: true)
        XCTAssertEqual(store.connectionState, .retrying)
        XCTAssertNil(store.tasks.first?.admittedAt)
        clock = try XCTUnwrap(store.nextConnectionAttempt).addingTimeInterval(1)
        await wire.setHTTPStatus(nil)
        await store.refresh()
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.tasks.first?.id, operation)
        XCTAssertNotNil(store.tasks.first?.admittedAt)
        await store.refresh()
        let sends = await wire.sends
        XCTAssertEqual(sends, 1, "No QR, manual retry or new operation identity is needed")
    }

    func testStreamingSubmissionPersistsReceiptWithoutWaitingForReplyOrOpeningAnotherRequest() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.enableSubmissionStream()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("stream.json"), connection: connection, client: client)
        await store.refresh(); store.foreground()
        defer { store.background() }
        store.setDraft("First"); let first = try store.enqueue(); await store.refresh(userInitiated: true)
        store.setDraft("Second while first is running"); let second = try store.enqueue(); await store.refresh(userInitiated: true)
        for _ in 0..<100 where store.tasks.first(where: { $0.id == first })?.reply?.partial != "首字" { await Task.yield() }
        XCTAssertNotNil(store.tasks.first(where: { $0.id == first })?.admittedAt)
        XCTAssertNotNil(store.tasks.first(where: { $0.id == second })?.admittedAt)
        XCTAssertEqual(store.tasks.first(where: { $0.id == first })?.reply?.partial, "首字")
        let reads = await wire.eventReads, sends = await wire.sends
        XCTAssertEqual(reads, 0, "POST already owns the reply stream")
        XCTAssertEqual(sends, 2, "An open reply stream cannot hold the next send")
        await wire.closeSubmissionStreams()
    }
    func testFirstTextIsReceivedWhileHistorySyncIsStillBlocked() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("first-text.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await store.refresh()
        await wire.enableTextEvents(); await wire.holdRead()
        store.foreground()
        while !(await wire.readHeld) { await Task.yield() }
        store.setDraft("Hello"); try store.enqueue()
        await store.refresh(userInitiated: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.tasks.first?.firstTextReceivedAt == nil, ContinuousClock.now < deadline { await Task.yield() }
        let received = store.tasks.first?.firstTextReceivedAt
        XCTAssertNotNil(received, "The first text must not wait for status/history polling")
        XCTAssertEqual(store.tasks.first?.reply?.partial, "首字")
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertEqual(reopened.tasks.first?.firstTextReceivedAt, received)
        store.background(); await wire.releaseRead()
    }

    func testUserSendImmediatelyRetriesTransportFailureWithoutDuplicatingAdmission() async throws {
        let (wire, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("send.json"), connection: connection, client: client,
                                        now: { Date(timeIntervalSince1970: 1000) })
        await store.refresh()
        store.recordConnectionFailure(URLError(.networkConnectionLost))
        store.setDraft("Hello"); try store.enqueue()
        await store.refresh()
        let before = await wire.sends
        XCTAssertEqual(before, 0, "Automatic polling still observes its backoff")
        await store.refresh(userInitiated: true)
        await store.refresh(userInitiated: true)
        let after = await wire.sends
        XCTAssertEqual(after, 1, "A deliberate send should try the recovered connection now, exactly once")
        XCTAssertNotNil(store.tasks.first?.admittedAt)
    }

    func testConcurrentLinkFailuresDoNotPostponeThePendingMessage() async throws {
        let (wire, connection, client, folder) = try fixture()
        var clock = Date(timeIntervalSince1970: 1000)
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("retry.json"),
                                        connection: connection, client: client, now: { clock })
        await store.refresh()
        store.setDraft("queued while offline")
        try store.enqueue()
        store.recordConnectionFailure(URLError(.networkConnectionLost))
        let deadline = try XCTUnwrap(store.nextConnectionAttempt)
        clock = deadline.addingTimeInterval(-0.1)
        store.recordConnectionFailure(URLError(.timedOut))
        XCTAssertEqual(store.nextConnectionAttempt, deadline)
        clock = deadline
        await store.refresh()
        let sends = await wire.sends
        XCTAssertEqual(sends, 1)
    }

    func testUserSendHonorsServerRetryAfterAndAuthenticationFailure() async throws {
        for status in [429, 503, 401] {
            let (wire, connection, client, folder) = try fixture()
            var clock = Date(timeIntervalSince1970: 1000)
            let store = try RemoteTaskStore(file: folder.appendingPathComponent("send.json"), connection: connection, client: client, now: { clock })
            await store.refresh()
            store.recordConnectionFailure(AgentClientError.http(status: status, code: nil, message: nil, retryAfter: 20))
            store.setDraft("Hello"); try store.enqueue()
            await store.refresh(userInitiated: true)
            let before = await wire.sends
            XCTAssertEqual(before, 0)
            clock = clock.addingTimeInterval(21)
            await store.refresh(userInitiated: true)
            let after = await wire.sends
            XCTAssertEqual(after, status == 401 ? 0 : 1)
        }
    }

    func testCompletionBeforeSharedAnswerKeepsWaitingButFailureDoesNot() async throws {
        let (_, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("gap.json")
        let seed = try RemoteTaskStore(file: file, connection: connection, client: client)
        await seed.refresh(); seed.setDraft("Hello"); let id = try seed.enqueue()
        var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var tasks = journal["tasks"] as! [[String: Any]]
        let session = tasks[0]["sessionID"] as! String
        let user: [String: Any] = ["id": "echo", "seq": 1, "role": "user", "content": "Hello", "created_at": 1.0,
                                  "run_id": "run-reply", "operation_id": id.uuidString]
        journal["messages"] = [user]; journal["messageCursor"] = 1
        func restored(status: String, output: String? = nil, answer: Bool = false) throws -> RemoteTaskStore {
            var run: [String: Any] = ["run_id": "run-reply", "session_id": session, "status": status]
            run["output"] = output; tasks[0]["run"] = run; journal["tasks"] = tasks
            if answer {
                journal["messages"] = [user, ["id": "answer", "seq": 2, "role": "assistant", "content": "Hello back", "created_at": 2.0, "run_id": "run-reply"]]
                journal["messageCursor"] = 2
            }
            try JSONSerialization.data(withJSONObject: journal).write(to: file)
            return try RemoteTaskStore(file: file, connection: connection, client: client)
        }
        XCTAssertTrue(try restored(status: "running").waitingForReply)
        XCTAssertTrue(try restored(status: "completed", output: "Hello back").waitingForReply,
                      "The user echo already hid the local output, but the shared answer has not arrived")
        XCTAssertFalse(try restored(status: "failed").waitingForReply)
        XCTAssertFalse(try restored(status: "cancelled").waitingForReply)
        XCTAssertFalse(try restored(status: "completed").waitingForReply, "No output must not spin forever")
        XCTAssertFalse(try restored(status: "completed", output: "Hello back", answer: true).waitingForReply)
    }

    func testRepeatedVisibleFramesCoalesceReadReceiptsWithoutHoldingSend() async throws {
        let (wire, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("read.json"), connection: connection, client: client)
        await store.refresh(); await wire.holdReadReceipt()
        let first = Task { await store.markVisibleMessagesRead(through: 7) }
        while !(await wire.receiptHeld) { await Task.yield() }
        for _ in 0..<25 { _ = await store.markVisibleMessagesRead(through: 7) }
        _ = await store.markVisibleMessagesRead(through: 9)
        let heldReads = await wire.readSeq
        XCTAssertEqual(heldReads, [7])
        store.setDraft("Do not queue behind read receipts"); try store.enqueue(); await store.refresh()
        let sends = await wire.sends
        XCTAssertEqual(sends, 1)
        await wire.releaseReadReceipt(); let sent = await first.value
        XCTAssertTrue(sent)
        let completedReads = await wire.readSeq
        XCTAssertEqual(completedReads, [7, 9])
        XCTAssertEqual(store.acknowledgedReadSequence, 9)
    }

    func testSlowLegacyAdoptionDoesNotBlockNewSharedMessage() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("old.json")
        let seed = try RemoteTaskStore(file: file, connection: connection, client: client)
        seed.setDraft("Old message"); try seed.enqueue(); await seed.refresh()
        var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var tasks = journal["tasks"] as! [[String: Any]]
        tasks[0]["sessionID"] = journal["sessionID"]
        journal["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await wire.holdAdoption()
        let refresh = Task { await store.refresh() }
        while !(await wire.adoptionHeld) { await Task.yield() }
        store.setDraft("New shared message"); try store.enqueue()
        await store.refresh()
        let sends = await wire.sends
        XCTAssertEqual(sends, 2, "The new message must be admitted while history adoption is still waiting")
        await wire.releaseAdoption(); await refresh.value
    }

    func testUnadmittedMessageDoesNotPretendMacIsTyping() async throws {
        let (wire, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("wait.json"), connection: connection, client: client)
        await store.refresh()
        let before = await wire.requests
        store.setDraft("Hello"); try store.enqueue()
        XCTAssertFalse(store.waitingForReply)
        let after = await wire.requests
        XCTAssertEqual(before, after, "The local bubble is saved without sending a request")
        await wire.setHTTPStatus(503)
        await store.refresh()
        XCTAssertFalse(store.tasks.last!.deliveryFailed, "A retryable 503 is pending, not confirmed undelivered")
        XCTAssertFalse(store.waitingForReply)
    }

    func testWarmSubmissionReusesContractAndRecordsDeliveryStages() async throws {
        let (wire, connection, client, folder) = try fixture()
        var clock = Date()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("latency.json"), connection: connection, client: client, now: { clock })
        for index in 0..<2 {
            store.setDraft("Message \(index)"); try store.enqueue(); await store.refresh()
        }
        let warmChecks = await wire.capabilityRequests
        XCTAssertEqual(warmChecks, 1, "A warm send must not wait for redundant capability requests")
        let task = try XCTUnwrap(store.tasks.last)
        XCTAssertNotNil(task.deliveryStartedAt); XCTAssertNotNil(task.sourcesPreparedAt)
        XCTAssertNotNil(task.firstAttemptAt); XCTAssertNotNil(task.admittedAt)
        XCTAssertFalse(store.waitingForReply, "An approval request is waiting for the user")
        clock = clock.addingTimeInterval(61)
        store.setDraft("After expiry"); try store.enqueue(); await store.refresh()
        let expiredChecks = await wire.capabilityRequests
        XCTAssertEqual(expiredChecks, 2)
    }

    func testSharedSubmissionUsesPersistedIdentityBoundContractWithoutPreflight() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.setMessageContract(retention: 86400)
        var clock = Date()
        let file = folder.appendingPathComponent("contract.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client, now: { clock })
        await store.refresh()
        store.setDraft("First"); try store.enqueue(); await store.refresh()
        clock = clock.addingTimeInterval(61)
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client, now: { clock })
        reopened.setDraft("After relaunch"); try reopened.enqueue(); await reopened.refresh()
        let checks = await wire.capabilityRequests
        let sends = await wire.sends
        XCTAssertEqual(checks, 0, "A verified shared conversation already carries its submission contract")
        XCTAssertEqual(sends, 2)
        let task = try XCTUnwrap(reopened.tasks.last)
        XCTAssertEqual(try XCTUnwrap(task.replayBefore).timeIntervalSince(try XCTUnwrap(task.firstAttemptAt)), 86340)
    }

    func testSharedSubmissionRejectsInsufficientAdvertisedContract() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.setMessageContract(retention: 60)
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("contract.json"), connection: connection, client: client)
        await store.refresh(); store.setDraft("Do not send"); try store.enqueue(); await store.refresh()
        let sends = await wire.sends
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(store.tasks.last!.needsReview)
    }

    func testFailedEntryDiscoveryRetriesContractAfterConnectionRecovers() async throws {
        let (wire, connection, client, folder) = try fixture()
        var clock = Date()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("recovery.json"), connection: connection, client: client, now: { clock })
        await store.refresh()
        await wire.setDiscoveryFailure(.offline)
        store.foreground(); defer { store.background() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.connectionState != .retrying, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(store.connectionState, .retrying)
        await wire.setDiscoveryFailure(nil); await wire.setMessageContract(retention: 86400)
        clock = clock.addingTimeInterval(40)
        await store.refresh()
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertNil(store.failure, "A recovered connection must clear the stale discovery error")
        XCTAssertEqual(store.conversation?.capabilities.messageIdempotency?.retentionSeconds, 86400)
    }

    func testCommittedReplyArrivesWithoutPollingAndDoesNotSkipMissingHistory() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("committed.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await store.refresh()
        let cursor = store.messageCursor
        await wire.enableTextEvents(); await wire.enableCommittedEvents(); await wire.holdRead()
        store.foreground(); defer { store.background() }
        store.setDraft("Hello"); try store.enqueue()
        let delivery = Task { await store.refresh(userInitiated: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !store.messages.contains(where: { $0.id == "committed-answer" }), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(store.messages.filter { $0.id == "committed-answer" }.count, 1)
        XCTAssertEqual(store.messages.filter { $0.id == "committed-input" }.count, 1, "The original message remains visible when its answer overtakes polling")
        XCTAssertEqual(store.messageCursor, cursor, "SSE must not skip concurrent messages from another device")
        XCTAssertNotNil(store.tasks.last?.firstCommittedTextAt)
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertEqual(reopened.messages, store.messages)
        await wire.releaseRead(); await delivery.value
    }

    private func fixture() throws -> (SharedWire, AgentConnection, AgentClient, URL) {
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: URL(string: "https://shared.invalid")!)
        let wire = SharedWire(connection)
        let client = try AgentClient(baseURL: connection.baseURL, credential: "fixture", assistantID: connection.assistantID, transport: wire)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (wire, connection, client, folder)
    }

    func testTwoDevicesRecoverAllPagesAndSameIDsWithoutSubmittingWake() async throws {
        let (wire, connection, client, folder) = try fixture()
        let a = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        let b = try RemoteTaskStore(file: folder.appendingPathComponent("b.json"), connection: connection, client: client)
        await a.refresh(); await b.refresh()
        XCTAssertEqual(a.messages.count, 205)
        XCTAssertEqual(a.messages, b.messages)
        XCTAssertEqual(a.messageCursor, 205)
        let reopened = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        await reopened.refresh()
        XCTAssertEqual(reopened.messages, a.messages)
        let sends = await wire.sends
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(a.sharedRuns.first?.pendingControls?.first?.promptID, "approval-1")
    }

    func testCachedConversation503RetriesAfterDeadlineAnd401StopsAllAutomaticRequests() async throws {
        let (wire, connection, client, folder) = try fixture()
        var clock = Date(timeIntervalSince1970: 1000)
        let file = folder.appendingPathComponent("journal.json")
        let first = try RemoteTaskStore(file: file, connection: connection, client: client, now: { clock })
        await first.refresh()
        let store = try RemoteTaskStore(file: file, connection: connection, client: client, now: { clock })
        store.setDraft("keep this draft")
        await wire.setHTTPStatus(503)
        await store.refresh()
        XCTAssertEqual(store.connectionState, .retrying)
        let deadline = try XCTUnwrap(store.nextConnectionAttempt)
        let count = await wire.requests
        await store.refresh()
        let unchanged = await wire.requests
        XCTAssertEqual(count, unchanged)
        await wire.setHTTPStatus(nil); clock = deadline.addingTimeInterval(1)
        await store.refresh()
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertNil(store.nextConnectionAttempt)
        XCTAssertEqual(store.draft, "keep this draft")
        await wire.setHTTPStatus(401); await store.refresh()
        XCTAssertEqual(store.connectionState, .authenticationRequired)
        let blocked = await wire.requests
        clock = clock.addingTimeInterval(100)
        await store.refresh(); await store.retryConnection(); store.foreground(); await Task.yield()
        let stillBlocked = await wire.requests
        XCTAssertEqual(blocked, stillBlocked)
        XCTAssertEqual(store.draft, "keep this draft")
    }

    func testOldResponseCannotClear401OrCommitAfterBackground() async throws {
        let (wire, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("journal.json"), connection: connection, client: client)
        await wire.holdRead()
        let pending = Task { await store.refresh() }
        while !(await wire.readHeld) { await Task.yield() }
        store.recordConnectionFailure(AgentClientError.http(status:401, code:nil, message:nil))
        await wire.releaseRead(); await pending.value
        XCTAssertEqual(store.connectionState, .authenticationRequired)
        XCTAssertEqual(store.messageCursor, 0)
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testVisibleReadDoesNotUseDownloadedCursorOrLateLegacyPage() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.backfillLegacyHistory()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("journal.json"), connection: connection, client: client)
        await store.refresh()
        let valid = await store.markVisibleMessagesRead(through: 7)
        let legacy = await store.markVisibleMessagesRead(through: 205)
        let invalid = await store.markVisibleMessagesRead(through: 999)
        XCTAssertTrue(valid); XCTAssertFalse(legacy); XCTAssertFalse(invalid)
        let read = await wire.readSeq
        XCTAssertEqual(read, [7])
        XCTAssertEqual(store.messageCursor, 205)
    }

    func testLateLegacyBackfillStaysBeforeSharedChatWithoutRewindingCursor() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.backfillLegacyHistory()
        let a = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        let b = try RemoteTaskStore(file: folder.appendingPathComponent("b.json"), connection: connection, client: client)
        await a.refresh(); await b.refresh()
        XCTAssertEqual(a.messageCursor, 205)
        XCTAssertEqual(a.messages.last?.id, "m-205", "Persist the append cursor, not presentation order")
        XCTAssertEqual(a.displayMessages.first?.id, "m-205")
        XCTAssertEqual(a.displayMessages.last?.id, "m-204")
        XCTAssertEqual(a.displayMessages, b.displayMessages)
        let reopened = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        await reopened.refresh()
        XCTAssertEqual(reopened.displayMessages, b.displayMessages)
        let sends = await wire.sends
        XCTAssertEqual(sends, 0, "Importing history must never execute the old request again")
    }

    func testDiscoveryDistinguishesStartupConnectivityFromUnsupportedServerAndRecovers() async throws {
        for issue in [SharedWire.DiscoveryFailure.offline, .startingUp, .missingEndpoint, .noCapability] {
            let (wire, connection, client, folder) = try fixture()
            let store = try RemoteTaskStore(file: folder.appendingPathComponent("journal.json"), connection: connection, client: client)
            await wire.setDiscoveryFailure(issue)
            await store.refresh()
            XCTAssertNil(store.conversation)
            XCTAssertEqual(store.connectionState, issue == .missingEndpoint || issue == .noCapability ? .unavailable : .retrying)
            await wire.setDiscoveryFailure(nil)
            await store.retryConnection()
            XCTAssertNotNil(store.conversation)
            XCTAssertEqual(store.messages.count, 205)
            XCTAssertNil(store.failure)
        }
    }

    func testCachedConversationClearsSyncFailureOnlyAfterFullSyncRecovers() async throws {
        let (wire, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("journal.json"), connection: connection, client: client)
        await store.refresh()
        await wire.setSyncOffline(true)
        await store.refresh()
        XCTAssertNotNil(store.conversation)
        XCTAssertEqual(store.connectionState, .retrying)
        await wire.setSyncOffline(false)
        await store.retryConnection()
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.messageCursor, 205)
    }

    func testNetworkRecoveryDoesNotEraseUnresolvedJournalWriteFailure() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("journal.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await wire.setDiscoveryFailure(.offline)
        await store.refresh()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await wire.setDiscoveryFailure(nil)
        await store.retryConnection()
        let storageFailure = try XCTUnwrap(store.failure)
        XCTAssertNotEqual(storageFailure, "暂时无法连接 Mac，正在重试。")
        XCTAssertNotEqual(storageFailure, RemoteTaskStore.StoreError.unsupportedServer.localizedDescription)
        await store.refresh()
        XCTAssertEqual(store.failure, storageFailure)
        XCTAssertNil(store.conversation, "A discovered identity is not committed when its journal write fails")
    }

    func testSyncRecoveryDoesNotEraseApprovalFailure() async throws {
        let (wire, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("journal.json"), connection: connection, client: client)
        await store.refresh()
        let run = try XCTUnwrap(store.sharedRuns.first), control = try XCTUnwrap(run.pendingControls?.first)
        await wire.advanceGeneration()
        await store.respond(run: run, control: control, answer: "once")
        let controlFailure = try XCTUnwrap(store.failure)
        await wire.setSyncOffline(true); await store.refresh()
        await wire.setSyncOffline(false); await store.retryConnection()
        XCTAssertEqual(store.failure, controlFailure)
        store.setDraft("Still keep the approval error")
        XCTAssertEqual(store.failure, controlFailure)
        let current = try XCTUnwrap(store.sharedRuns.first)
        await store.respond(run: current, control: try XCTUnwrap(current.pendingControls?.first), answer: "once")
        XCTAssertNil(store.failure, "Only the successful control action clears its failure")
    }

    func testLostReceiptReusesOperationAndPayloadAfterReopen() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.loseNextReceipts(2)
        let file = folder.appendingPathComponent("journal.json")
        let first = try RemoteTaskStore(file: file, connection: connection, client: client)
        first.setDraft("补充资料"); let id = try first.enqueue(); await first.refresh()
        XCTAssertNil(first.tasks[0].run)
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        await reopened.checkAgain(id: id)
        XCTAssertEqual(reopened.tasks.first?.id, id)
        let bodies = await wire.bodies
        XCTAssertEqual(bodies.count, 3); XCTAssertEqual(bodies[0], bodies[1]); XCTAssertEqual(bodies[0], bodies[2])
    }

    func testCursorIsNotAdvancedIfTheJournalCannotCommit() async throws {
        let (_, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("journal.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await store.refresh()
        XCTAssertEqual(store.messageCursor, 205)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await store.refresh()
        XCTAssertEqual(store.messageCursor, 205)
        XCTAssertEqual(store.messages.count, 205)
        XCTAssertNotNil(store.failure)
    }

    func testStaleApprovalNeverWritesToAnotherGeneration() async throws {
        let (wire, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        await store.refresh()
        let run = try XCTUnwrap(store.sharedRuns.first), control = try XCTUnwrap(store.sharedRuns.first?.pendingControls?.first)
        await wire.advanceGeneration()
        await store.respond(run: run, control: control, answer: "once")
        let approvals = await wire.approvals
        XCTAssertEqual(approvals, 0)
        XCTAssertNotNil(store.failure)
    }

    func testMismatchedServerIdentityKeepsInputAndNeverFallsBackToLegacyRun() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.useWrongIdentity()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        store.setDraft("Keep my intent"); try store.enqueue(); await store.refresh()
        XCTAssertNil(store.conversation)
        XCTAssertNil(store.tasks[0].firstAttemptAt)
        XCTAssertEqual(store.tasks[0].input, "Keep my intent")
        let writes = await wire.writes
        XCTAssertEqual(writes, 0)
    }

    func testSchemaOneJournalKeepsOriginalSessionDraftAndAmbiguousOperation() throws {
        let (_, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("old.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        store.setDraft("Old request"); let id = try store.enqueue(); store.setDraft("Unsent draft"); store.flushDraft()
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let legacy = "momo-legacy-session"
        object["schemaVersion"] = 1; object["sessionID"] = legacy
        var tasks = object["tasks"] as! [[String: Any]]
        tasks[0]["sessionID"] = legacy; tasks[0]["firstAttemptAt"] = 123.0
        object["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertEqual(reopened.tasks[0].id, id)
        XCTAssertEqual(reopened.tasks[0].sessionID, legacy)
        XCTAssertEqual(reopened.draft, "Unsent draft")
        XCTAssertNotNil(reopened.tasks[0].firstAttemptAt)
    }

    func testLegacyOutboxAdoptsOnlyAfterItsOriginalSessionExists() async throws {
        for deferred in [false, true] {
            let (wire, connection, client, folder) = try fixture()
            let file = folder.appendingPathComponent("old.json")
            let first = try RemoteTaskStore(file: file, connection: connection, client: client)
            first.setDraft("Old unsent request"); let operation = try first.enqueue(); first.setDraft("Keep my draft"); first.flushDraft()
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            object["schemaVersion"] = 1; object["sessionID"] = "momo-old-session"
            var tasks = object["tasks"] as! [[String: Any]]
            tasks[0]["sessionID"] = "momo-old-session"; object["tasks"] = tasks
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            await wire.deferLegacyAdoption(deferred)
            let restored = try RemoteTaskStore(file: file, connection: connection, client: client)
            await restored.refresh()
            let initialCalls = await wire.legacyCalls
            XCTAssertEqual(initialCalls, ["adopt:false", "submit:momo-old-session", deferred ? "adopt:false" : "adopt:true"])
            await restored.refresh(); await restored.refresh()
            let calls = await wire.legacyCalls, keys = await wire.legacyKeys
            XCTAssertEqual(calls, deferred ? initialCalls + ["adopt:true"] : initialCalls)
            XCTAssertEqual(keys, [operation.uuidString.lowercased()])
            XCTAssertEqual(restored.tasks[0].id, operation)
            XCTAssertEqual(restored.tasks[0].sessionID, "momo-old-session")
            XCTAssertEqual(restored.tasks[0].input, "Old unsent request")
            XCTAssertEqual(restored.draft, "Keep my draft")
        }
    }

    func testLegacyTaskSelectionDoesNotSilentlyRedirectAnOrdinaryChatDraft() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("old-composer.json")
        let old = try RemoteTaskStore(file: file, connection: connection, client: client)
        await old.refresh()
        old.setSteeringTarget(try XCTUnwrap(old.sharedRuns.first))
        old.setDraft("今天聊点别的")
        old.flushDraft()
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertEqual(reopened.draft, "今天聊点别的")
        XCTAssertNil(reopened.steeringTarget)
        try reopened.enqueue(); await reopened.refresh()
        let body = await wire.lastBody()
        let submitted = try JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as! [String: Any]
        XCTAssertEqual(submitted["intent"] as? String, "new")
        XCTAssertNil(submitted["target_run_id"])
        XCTAssertEqual(submitted["content"] as? String, "今天聊点别的")
    }

    func testUnconsumedSteeringWithReceiptRestoresDraftWithoutResubmitting() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("steering.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await store.refresh()
        let run = try XCTUnwrap(store.sharedRuns.first)
        store.setSteeringTarget(run)
        store.setDraft("Keep this precise supplement"); let id = try store.enqueue()
        await wire.rejectSteeringAfterReceipt()
        await store.refresh()
        let task = try XCTUnwrap(store.tasks.first { $0.id == id })
        XCTAssertEqual(task.run?.status, "not_applied")
        XCTAssertTrue(task.isFinished); XCTAssertTrue(task.deliveryFailed)
        let lastBody = await wire.lastBody()
        let submitted = try JSONSerialization.jsonObject(with: try XCTUnwrap(lastBody)) as! [String: Any]
        XCTAssertEqual(submitted["intent"] as? String, "steer")
        XCTAssertEqual(submitted["work_id"] as? String, "work-shared")
        XCTAssertEqual(submitted["target_run_id"] as? String, run.runID)
        XCTAssertEqual(submitted["execution_generation"] as? Int, 1)
        store.setDraft("A newer unsent draft")
        XCTAssertFalse(store.restoreAsNewMessage(task))
        XCTAssertEqual(store.draft, "A newer unsent draft")
        store.setDraft(""); XCTAssertTrue(store.restoreAsNewMessage(task))
        XCTAssertNil(store.steeringTarget)
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        await reopened.refresh()
        XCTAssertEqual(reopened.draft, task.input)
        XCTAssertFalse(reopened.tasks[0].deliveryFailed)
        XCTAssertFalse(reopened.tasks[0].isPending)
        let sends = await wire.sends; XCTAssertEqual(sends, 1, "Restore never silently turns steering into a new request")
    }

    func testCancellationRetryRetainsIdentityAndStaleGenerationStopsRetrying() async throws {
        for stale in [false, true] {
            let (wire, connection, client, folder) = try fixture()
            let file = folder.appendingPathComponent("cancel.json")
            let first = try RemoteTaskStore(file: file, connection: connection, client: client)
            await first.refresh()
            let run = try XCTUnwrap(first.sharedRuns.first)
            await wire.failNextCancellation(stale ? 409 : nil)
            await first.stopSharedRun(run)
            XCTAssertFalse(first.isControlInFlight(run.runID))
            let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
            await reopened.refresh(); await reopened.refresh()
            let bodies = await wire.cancellationBodies
            XCTAssertEqual(bodies.count, stale ? 1 : 2)
            if !stale {
                let one = try JSONSerialization.jsonObject(with: bodies[0]) as! NSDictionary
                let two = try JSONSerialization.jsonObject(with: bodies[1]) as! NSDictionary
                XCTAssertEqual(one, two)
                XCTAssertEqual(one["execution_generation"] as? Int, 1)
            }
        }
    }

    func testPreviouslyReadSupplementFailureSyncsAcrossBothDevicesAndRestart() async throws {
        let (wire, connection, client, folder) = try fixture()
        let a = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        let b = try RemoteTaskStore(file: folder.appendingPathComponent("b.json"), connection: connection, client: client)
        await wire.setDeliveryState("steering"); await a.refresh(); await b.refresh()
        let cursor = a.messageCursor
        await wire.setDeliveryState("not_applied"); await a.refresh(); await b.refresh()
        XCTAssertEqual(a.messageCursor, cursor)
        XCTAssertEqual(a.messages, b.messages)
        XCTAssertEqual(a.rejectedSharedSupplements.count, 1)
        XCTAssertTrue(a.displayMessages.contains { $0.id == "delivery-m-1" })
        let reopened = try RemoteTaskStore(file: folder.appendingPathComponent("b.json"), connection: connection, client: client)
        XCTAssertEqual(reopened.rejectedSharedSupplements.count, 1)
        let rejected = try XCTUnwrap(reopened.rejectedSharedSupplements.first)
        reopened.setDraft("Keep my new draft")
        XCTAssertFalse(reopened.restoreAsNewMessage(rejected))
        reopened.setDraft(""); XCTAssertTrue(reopened.restoreAsNewMessage(rejected))
        XCTAssertEqual(reopened.draft, rejected.content)
        XCTAssertTrue(reopened.rejectedSharedSupplements.isEmpty)
        let sends = await wire.sends; XCTAssertEqual(sends, 0)
        let restored = try RemoteTaskStore(file: folder.appendingPathComponent("b.json"), connection: connection, client: client)
        XCTAssertTrue(restored.rejectedSharedSupplements.isEmpty)
        XCTAssertEqual(restored.draft, rejected.content)
    }

    func testQueuedCancellationUsesDurableWorkJournalAndStableRunIdentity() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("queue.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await store.refresh()
        let data = try JSONSerialization.data(withJSONObject: ["run_id":"queued-run", "status":"queued", "work_id":"queued-work"])
        let run = try JSONDecoder().decode(AgentRun.self, from: data)
        await wire.failNextCancellation(nil); await store.stopSharedRun(run)
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        await reopened.refresh()
        let bodies = await wire.cancellationBodies
        XCTAssertEqual(bodies.count, 2)
        let one = try JSONSerialization.jsonObject(with: bodies[0]) as! NSDictionary
        let two = try JSONSerialization.jsonObject(with: bodies[1]) as! NSDictionary
        XCTAssertEqual(one, two); XCTAssertEqual(one["execution_generation"] as? Int, 0)
        XCTAssertEqual(one["target_run_id"] as? String, "queued-run")
    }

    func testReportRetryPersistsOperationAcrossLostResponseAndReopen() async throws {
        let (wire, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("report.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        await store.refresh()
        let data = try JSONSerialization.data(withJSONObject: ["id":"process:finished", "state":"completed", "report_state":"failed", "report_retry_available":true])
        let work = try JSONDecoder().decode(ConversationWork.self, from: data)
        await store.retryReport(work)
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        await reopened.refresh()
        let bodies = await wire.reportBodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[0]) as! NSDictionary,
                       try JSONSerialization.jsonObject(with: bodies[1]) as! NSDictionary)
        let sends = await wire.sends; XCTAssertEqual(sends, 0)
    }

    func testBackgroundStatusKeepsUnknownAndFailedReportsVisible() throws {
        for (state,report,expected) in [("cancelled","pending",true),("failed","failed",true),("unknown","pending",true),("cancelled","reported",false)] {
            let data = try JSONSerialization.data(withJSONObject: ["id":"process:fixture","kind":"process","state":state,"report_state":report,"execution_generation":1,"cancel_requested":true])
            let value = try JSONDecoder().decode(ConversationWork.self, from: data)
            XCTAssertEqual(value.isPending, expected)
            XCTAssertEqual(value.executionGeneration, 1)
        }
    }

    func testBothDevicesKeepTerminalStatusesAfterALaterSuccessfulReply() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.showTerminalRuns(includeSuccess: false)
        let a = try RemoteTaskStore(file: folder.appendingPathComponent("a.json"), connection: connection, client: client)
        let b = try RemoteTaskStore(file: folder.appendingPathComponent("b.json"), connection: connection, client: client)
        a.setDraft("First request"); let operation = try a.enqueue(); await a.refresh()
        XCTAssertEqual(a.messages.first?.operationID, operation)
        let statuses = a.displayMessages.filter { $0.role == "system" }
        XCTAssertEqual(statuses.count, 3)
        XCTAssertTrue(statuses[0].content.contains("Synthetic failure"))
        XCTAssertEqual(statuses[1].content, "已停止。")
        XCTAssertEqual(statuses[2].content, "已停止。")
        await wire.showTerminalRuns(includeSuccess: true)
        await a.refresh(); await b.refresh()
        XCTAssertEqual(a.displayMessages, b.displayMessages)
        XCTAssertEqual(a.displayMessages.filter { $0.role == "system" }, statuses)
        let statusIndex = try XCTUnwrap(a.displayMessages.firstIndex { $0.id == statuses[0].id })
        let successIndex = try XCTUnwrap(a.displayMessages.firstIndex { $0.id == "later-user" })
        XCTAssertLessThan(statusIndex, successIndex)
        XCTAssertEqual(a.displayMessages.last?.content, "Later request succeeded")
        XCTAssertFalse(a.displayMessages.contains { $0.id == "run-status-run-steering" })
        XCTAssertEqual(a.messageCursor, 6, "Presentation notices must not advance the persisted server cursor")
        let reopened = try RemoteTaskStore(file: folder.appendingPathComponent("b.json"), connection: connection, client: client)
        await reopened.refresh()
        XCTAssertEqual(reopened.displayMessages, a.displayMessages)
    }

    func testDraftPersistenceDebouncesKeystrokesAndFlushesOnDemandOrBackground() async throws {
        let (_, connection, client, folder) = try fixture()
        let file = folder.appendingPathComponent("debounced.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        store.setDraft(""); store.flushDraft()

        store.setDraft("h")
        store.setDraft("he")
        store.setDraft("hello")
        XCTAssertEqual(store.draft, "hello")
        if let existing = try? Data(contentsOf: file),
           let raw = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            XCTAssertNotEqual(raw["draft"] as? String, "hello", "Rapid keystrokes must debounce synchronous disk writes")
        }

        try await Task.sleep(for: .milliseconds(360))
        let afterDebounce = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(afterDebounce["draft"] as? String, "hello")

        store.setDraft("hello world")
        store.background()
        let afterBackground = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(afterBackground["draft"] as? String, "hello world")
    }

    func testUnavailableConnectionRecoversOnUserRefreshOrForegroundReopen() async throws {
        let (wire, connection, client, folder) = try fixture()
        await wire.setDiscoveryFailure(.missingEndpoint)
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("recover.json"), connection: connection, client: client)
        await store.refresh()
        XCTAssertEqual(store.connectionState, .unavailable)

        await wire.setDiscoveryFailure(nil)
        await store.refresh(userInitiated: true)
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertNotNil(store.conversation)

        await wire.setHTTPStatus(501)
        await store.refresh()
        XCTAssertEqual(store.connectionState, .unavailable)

        await wire.setHTTPStatus(nil)
        store.background()
        store.foreground()
        defer { store.background() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.connectionState != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.connectionState, .ready)
    }

    func testWorkOverviewAndDetailDecodingAndFetching() async throws {
        let (_, connection, client, folder) = try fixture()
        let store = try RemoteTaskStore(file: folder.appendingPathComponent("works.json"), connection: connection, client: client)
        let overview = try await store.fetchWorkOverview(limit: 10)
        XCTAssertEqual(overview.active.count, 1)
        XCTAssertEqual(overview.active.first?.id, "superagent:t-live")
        XCTAssertEqual(overview.active.first?.originLabel, "录音主动派发")
        XCTAssertEqual(overview.recent.count, 1)
        XCTAssertEqual(overview.recent.first?.state, "dropped")
        XCTAssertFalse(overview.recent.first?.isPending ?? true)

        let detail = try await store.fetchWorkDetail(id: "superagent:t-live")
        XCTAssertEqual(detail.ticketID, "t-live")
        XCTAssertTrue(detail.isActive)
        XCTAssertEqual(detail.scope, "核查录音中的发布检查清单")
        XCTAssertEqual(detail.matchedRules, ["明确备忘与交付物起草"])
        XCTAssertEqual(detail.todos.count, 1)
        XCTAssertEqual(detail.activities.count, 1)
        XCTAssertEqual(detail.activities.first?.kind, "subagent")
    }
}

private actor SharedWire: AgentTransport {
    var submissionStream = false, eventReads = 0
    var submissionContinuations: [AsyncThrowingStream<Data, Error>.Continuation] = []
    func enableSubmissionStream() { submissionStream = true; messageRetention = 86400 }
    func closeSubmissionStreams() { for c in submissionContinuations { c.finish() }; submissionContinuations.removeAll() }
    enum DiscoveryFailure { case offline, startingUp, missingEndpoint, noCapability }
    let connection: AgentConnection
    var hold = false, readHeld = false
    var readContinuation: CheckedContinuation<Void,Never>?
    func holdRead() { hold = true }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil; hold = false }
    var requests = 0
    var textEvents = false
    func enableTextEvents() { textEvents = true }
    var committedEvents = false
    func enableCommittedEvents() { committedEvents = true }
    var capabilityRequests = 0
    var messageRetention: Int?
    func setMessageContract(retention: Int) { messageRetention = retention }
    var receiptHeld = false, holdReceipt = false
    var receiptContinuation: CheckedContinuation<Void,Never>?
    func holdReadReceipt() { holdReceipt = true }
    func releaseReadReceipt() { holdReceipt = false; receiptContinuation?.resume(); receiptContinuation = nil }
    var adoptionHeld = false, holdAdopt = false
    var adoptionContinuation: CheckedContinuation<Void,Never>?
    func holdAdoption() { holdAdopt = true }
    func releaseAdoption() { holdAdopt = false; adoptionContinuation?.resume(); adoptionContinuation = nil }
    var deliveryState: String?
    func setDeliveryState(_ state: String) { deliveryState = state }
    var reportBodies: [Data] = []
    var readSeq: [Int] = []
    var httpStatus: Int?
    func setHTTPStatus(_ value: Int?) { httpStatus = value }
    var sends = 0, approvals = 0, generation = 1
    var unappliedSteering = false
    var cancellationBodies: [Data] = []
    var cancellationFailure: Int? = nil
    var failCancellation = false
    func rejectSteeringAfterReceipt() { unappliedSteering = true }
    func lastBody() -> Data? { bodies.last }
    func failNextCancellation(_ status: Int?) { failCancellation = true; cancellationFailure = status }
    var writes = 0
    var wrongIdentity = false
    var bodies: [Data] = []
    var receiptsToLose = 0
    var legacyCalls: [String] = [], legacyKeys: [String] = []
    var legacySession: String?, delayedAdoption = false
    var terminalScenario = false, laterSuccess = false
    var terminalOperation: String?
    var discoveryFailure: DiscoveryFailure?
    var syncOffline = false
    var legacyBackfill = false
    init(_ connection: AgentConnection) { self.connection = connection }
    func loseNextReceipts(_ count: Int) { receiptsToLose = count }
    func advanceGeneration() { generation += 1 }
    func useWrongIdentity() { wrongIdentity = true }
    func deferLegacyAdoption(_ value: Bool) { delayedAdoption = value }
    func showTerminalRuns(includeSuccess: Bool) { terminalScenario = true; laterSuccess = includeSuccess }
    func setDiscoveryFailure(_ value: DiscoveryFailure?) { discoveryFailure = value }
    func setSyncOffline(_ value: Bool) { syncOffline = value }
    func backfillLegacyHistory() { legacyBackfill = true }
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        requests += 1
        if let httpStatus { throw AgentClientError.http(status: httpStatus, code: nil, message: nil, retryAfter: httpStatus == 503 ? 5 : nil) }
        let path = request.url!.path
        if request.httpMethod == "POST" { writes += 1 }
        let root = "momo-main-" + connection.assistantID.uuidString.lowercased()
        var value: [String: Any] = [:]
        func run(_ id: String) -> [String: Any] {
            ["run_id": id, "session_id": root, "status": "waiting_for_approval", "execution_generation": generation,
             "work_id": "work-shared", "title": "Shared task", "pending_controls": [["prompt_id": "approval-1", "kind": "approval", "command": "synthetic command", "choices": ["once", "deny"]]]]
        }
        if path == "/momo/v1/conversation" {
            switch discoveryFailure {
            case .offline: throw URLError(.cannotConnectToHost)
            case .startingUp: throw AgentClientError.http(status: 503, code: nil, message: "Starting")
            case .missingEndpoint: throw AgentClientError.http(status: 404, code: nil, message: "Missing")
            default: break
            }
            value = ["conversation_id": "shared", "session_id": root, "assistant_id": connection.assistantID.uuidString,
                "instance_id": wrongIdentity ? UUID().uuidString : connection.instanceID.uuidString,
                "capabilities": ["shared_conversation": true, "server_owned_completion": discoveryFailure != .noCapability, "durable_steering": true,
                    "independent_chat_while_waiting": false, "system_push": false]]
            if let messageRetention {
                var capabilities = value["capabilities"] as! [String: Any]
                capabilities["message_idempotency"] = ["supported": true, "durable": true, "retention_seconds": messageRetention]
                capabilities["message_streaming"] = submissionStream
                value["capabilities"] = capabilities
            }
        } else if path.hasSuffix("/report-retry") {
            reportBodies.append(request.httpBody!)
            if reportBodies.count == 1 { throw URLError(.networkConnectionLost) }
        } else if path.hasSuffix("/cancel") {
            cancellationBodies.append(request.httpBody!)
            if failCancellation {
                failCancellation = false
                if let status = cancellationFailure { throw AgentClientError.http(status: status, code: "stale_target", message: nil) }
                throw URLError(.networkConnectionLost)
            }
        } else if path.hasSuffix("/read") {
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
            readSeq.append(object["through_seq"] as! Int)
            if holdReceipt { receiptHeld = true; await withCheckedContinuation { receiptContinuation = $0 } }
        } else if path.hasSuffix("/adopt") {
            if holdAdopt { adoptionHeld = true; await withCheckedContinuation { adoptionContinuation = $0 } }
            let adopted = legacySession != nil && !delayedAdoption
            if legacySession != nil { delayedAdoption = false }
            legacyCalls.append("adopt:\(adopted)"); value = ["adopted": adopted]
        } else if path == "/v1/runs" && request.httpMethod == "POST" {
            let submitted = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            legacySession = submitted["session_id"] as? String
            legacyCalls.append("submit:" + legacySession!); legacyKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
            value = ["run_id": "run-legacy", "session_id": legacySession!, "status": "completed"]
        } else if path == "/v1/runs/run-legacy" {
            value = ["run_id": "run-legacy", "session_id": legacySession!, "status": "completed"]
        } else if path == "/momo/v1/conversation/messages" && request.httpMethod == "GET" {
            if hold { readHeld = true; await withCheckedContinuation { readContinuation = $0 } }
            let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!)!
            if terminalScenario {
                var rows: [[String: Any]] = [
                    ["id":"failed-user", "seq":1, "role":"user", "content":"First request", "created_at":1.0, "run_id":"run-failed"],
                    ["id":"failed-ack", "seq":2, "role":"assistant", "content":"Working on it", "created_at":2.0, "run_id":"run-failed"],
                    ["id":"cancelled-user", "seq":3, "role":"user", "content":"Cancelled request", "created_at":3.0, "run_id":"run-cancelled"],
                    ["id":"interrupted-user", "seq":4, "role":"user", "content":"Interrupted request", "created_at":4.0, "run_id":"run-interrupted"]]
                if let terminalOperation { rows[0]["operation_id"] = terminalOperation }
                if laterSuccess { rows += [
                    ["id":"later-user", "seq":5, "role":"user", "content":"Another request", "created_at":5.0, "run_id":"run-success"],
                    ["id":"later-answer", "seq":6, "role":"assistant", "content":"Later request succeeded", "created_at":6.0, "run_id":"run-success"]] }
                value = ["data": rows.filter { ($0["seq"] as! Int) > after }, "next_cursor": rows.count, "has_more": false]
            } else {
                let end = min(205, after + 100)
                var data: [[String: Any]] = end > after ? ((after + 1)...end).map { ["id": "m-\($0)", "seq": $0, "role": "assistant", "content": "Result \($0)", "created_at": Double($0)] } : []
                if legacyBackfill, end == 205, !data.isEmpty { data[data.count - 1]["source_session"] = "momo-old-phone" }
                value = ["data": data, "next_cursor": end, "has_more": end < 205]
            }
        } else if path == "/momo/v1/conversation/messages" {
            sends += 1; bodies.append(request.httpBody!)
            let submitted = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if receiptsToLose > 0 { receiptsToLose -= 1; throw URLError(.timedOut) }
            if terminalScenario { terminalOperation = submitted["operation_id"] as? String; value = ["run_id":"run-failed", "session_id":root, "status":"failed", "error":"Synthetic failure"] }
            else { value = run("run-" + (submitted["operation_id"] as! String)); if unappliedSteering { value["status"] = "not_applied"; value["delivery_state"] = "not_applied" } }
            if submissionStream && request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
                let id = value["run_id"] as! String
                var bytes = Data()
                for event: [String: Any] in [["event":"run.accepted", "run_id":id, "receipt":value], ["event":"message.delta", "run_id":id, "seq":0, "delta":"首字"]] {
                    bytes += Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: event)) + Data("\n\n".utf8)
                }
                let (chunks, c) = AsyncThrowingStream<Data, Error>.makeStream()
                submissionContinuations.append(c); c.yield(bytes)
                return AgentByteStream(status: 200, contentType: "text/event-stream", chunks: chunks)
            }
        } else if path == "/momo/v1/conversation/runs" {
            if syncOffline { throw URLError(.networkConnectionLost) }
            if terminalScenario {
                var rows = ["failed","cancelled","interrupted","steering"].map { ["run_id":"run-" + $0, "session_id":root, "status":$0, "error": $0 == "failed" ? "Synthetic failure" : ""] }
                if laterSuccess { rows.append(["run_id":"run-success", "session_id":root, "status":"completed"]) }
                value = ["data": rows]
            } else { value = ["data": [run("run-shared")]] }
            if let deliveryState { value["message_states"] = ["m-1": deliveryState] }
        } else if path.hasSuffix("/capabilities") { capabilityRequests += 1; value = ["features": ["run_submission": true, "runs_idempotency": ["supported": true, "durable": true, "retention_seconds": 86400]]]
        } else if path.hasSuffix("/approval") { approvals += 1; value = [:]
        } else if path.hasSuffix("/events") {
            eventReads += 1
            guard textEvents else { throw URLError(.networkConnectionLost) }
            let id = request.url!.deletingLastPathComponent().lastPathComponent
            let event = try JSONSerialization.data(withJSONObject: ["event":"message.delta", "run_id":id, "seq":0, "delta":"首字"])
            var frame = Data("data: ".utf8) + event + Data("\n\n".utf8)
            if committedEvents {
                for seq in 1...2 {
                    let message: [String: Any] = ["id":"committed-answer", "seq":210, "role":"assistant", "content":"完整回复", "created_at":1.0, "run_id":id]
                    let submitted = try JSONSerialization.jsonObject(with: bodies.last!) as! [String: Any]
                    let input: [String: Any] = ["id":"committed-input", "seq":209, "role":"user", "content":submitted["content"]!, "created_at":0.5, "run_id":id, "operation_id":submitted["operation_id"]!]
                    let committed = try JSONSerialization.data(withJSONObject: ["event":"message.committed", "run_id":id, "seq":seq, "message":message, "input":input])
                    frame += Data("data: ".utf8) + committed + Data("\n\n".utf8)
                }
            }
            return AgentByteStream(status: 200, contentType: "text/event-stream", chunks: AsyncThrowingStream { $0.yield(frame); $0.finish() })
        } else if path.hasSuffix("/conversation/works") {
            value = [
                "active": [[
                    "id": "superagent:t-live",
                    "state": "running",
                    "report_state": "pending",
                    "title": "核查发布清单",
                    "execution_generation": 1,
                    "cancellable": true,
                    "origin_kind": "proactive_transcript",
                    "origin_label": "录音主动派发",
                    "source_recorded_at": 1761897600.0
                ]],
                "recent": [[
                    "id": "superagent:t-old",
                    "state": "dropped",
                    "report_state": "reported",
                    "title": "历史讨论跳过",
                    "execution_generation": 1,
                    "cancellable": false,
                    "origin_kind": "proactive_transcript",
                    "origin_label": "录音主动派发"
                ]]
            ]
        } else if path.contains("/conversation/work/") && request.httpMethod == "GET" {
            value = [
                "id": "superagent:t-live",
                "ticket_id": "t-live",
                "title": "核查发布清单",
                "status": "running",
                "status_label": "正在执行",
                "origin_kind": "proactive_transcript",
                "origin_label": "录音主动派发",
                "created_at": 1762070400.0,
                "updated_at": 1762070430.0,
                "source_id": "lib/sess-1",
                "source_title": "晚间备忘",
                "source_recorded_at": 1761897600.0,
                "trigger_preview": "[2025-10-31 16:00:00] 备忘一下：整理发布清单。",
                "scope": "核查录音中的发布检查清单",
                "matched_rules": ["明确备忘与交付物起草"],
                "cancellable": true,
                "turn_count": 1,
                "step_count": 2,
                "todos": [["id": "1", "content": "整理检查项", "status": "in_progress"]],
                "activities": [[
                    "id": "call-1",
                    "kind": "subagent",
                    "title": "派发子任务：核对版本构建配置",
                    "detail": "检查 Config/App.xcconfig",
                    "status": "running",
                    "timestamp": 1762070420.0
                ]]
            ]
        } else if path.contains("/v1/runs/") { value = run(path.components(separatedBy: "/").last!); if unappliedSteering { value["status"] = "not_applied"; value["delivery_state"] = "not_applied" } }
        let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return AgentByteStream(status: 200, contentType: "application/json", chunks: AsyncThrowingStream { $0.yield(body); $0.finish() })
    }
}
