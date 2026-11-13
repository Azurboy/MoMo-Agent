import Foundation
import XCTest
@testable import MoMoAgentClient

@MainActor final class ConversationSubscriptionTests: XCTestCase {
    private func fixture(now: @escaping () -> Date = Date.init) throws -> (LiveWire, RemoteTaskStore, URL, AgentClient) {
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: URL(string: "https://live.invalid")!)
        let wire = LiveWire(connection)
        let client = try AgentClient(baseURL: connection.baseURL, credential: "paired", assistantID: connection.assistantID, transport: wire)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("tasks.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (wire, try RemoteTaskStore(file: file, connection: connection, client: client, now: now), file, client)
    }
    func eventually(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        let satisfied = await condition(); XCTAssertTrue(satisfied)
    }
    func testBackgroundRefreshPersistsUnreadReplyWithoutSendingDraftOrStartingSubscription() async throws {
        let (wire, store, file, client) = try fixture()
        store.setDraft("未发送的草稿")
        await wire.appendMessage("手机挂起后 Mac 发来的消息")
        let changed = try await store.refreshInboxInBackground()
        XCTAssertTrue(changed)
        let repeated = try await store.refreshInboxInBackground()
        XCTAssertFalse(repeated)
        let restored = try RemoteTaskStore(file: file, connection: store.connection, client: client)
        XCTAssertEqual(restored.messages.map(\.content), ["手机挂起后 Mac 发来的消息"])
        XCTAssertEqual(restored.draft, "未发送的草稿")
        XCTAssertEqual(restored.acknowledgedReadSequence, 0)
        let requests = await wire.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        let subscriptions = await wire.subscriptions
        XCTAssertTrue(subscriptions.isEmpty)
        restored.foreground()
        defer { restored.background() }
        try await eventually { await wire.streams.count == 1 }
        await wire.appendMessage("还有一条")
        try await eventually { restored.messages.count == 2 }
    }

    func testMultipleMessagesShareSubscriptionAndLateReceiptCannotRegressPushedCompletion() async throws {
        let (wire, store, _, _) = try fixture()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        for text in ["one", "two"] {
            store.setDraft(text); _ = try store.enqueue(); await store.refresh(userInitiated: true)
        }
        try await eventually { store.messages.count == 4 }
        XCTAssertEqual(store.tasks.map { $0.run?.status }, ["completed", "completed"])
        XCTAssertTrue(store.tasks.allSatisfy { $0.firstTextReceivedAt != nil })
        XCTAssertFalse(store.waitingForReply)
        await store.refresh(); await store.refresh()
        let requests = await wire.requests, subscriptions = await wire.subscriptions
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertFalse(requests.contains { $0.url?.path == "/v1/capabilities" && $0.timeoutInterval == 5 })
        XCTAssertEqual(requests.filter { $0.url?.path == "/momo/v1/conversation/messages" && $0.httpMethod == "POST" }.count, 2)
        XCTAssertFalse(requests.contains { $0.url?.path.hasPrefix("/v1/runs/") == true })
        XCTAssertFalse(requests.contains { $0.url?.path == "/momo/v1/conversation/runs" })
        XCTAssertTrue(requests.filter { $0.httpMethod == "POST" }.allSatisfy { $0.value(forHTTPHeaderField: "Accept") != "text/event-stream" })
    }
    func testBackgroundResumeUsesPersistedCursorAndDedupesReplayedMessage() async throws {
        let (wire, store, file, client) = try fixture()
        store.foreground(); try await eventually { await wire.subscriptions.count == 1 }
        await wire.appendMessage("from Mac")
        try await eventually { store.messages.count == 1 }
        let cursor = try XCTUnwrap(store.eventCursor)
        store.background()
        await wire.appendMessage("finished while phone asleep")
        let restored = try RemoteTaskStore(file: file, connection: store.connection, client: client)
        restored.foreground(); defer { restored.background() }
        try await eventually { restored.messages.count == 2 }
        await wire.repeatLast()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(restored.messages.count, 2)
        let after = await wire.subscriptions, snapshots = await wire.snapshots
        XCTAssertEqual(after, [0, cursor]); XCTAssertEqual(snapshots, 1)
    }
    func testLostPostReceiptCannotUndoAdmissionAlreadyReceivedOnSubscription() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.losePostReceipt()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        store.setDraft("accepted over live stream"); _ = try store.enqueue()
        await store.refresh(userInitiated: true)
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.tasks.last?.run?.status, "completed")
        XCTAssertNil(store.tasks.last?.lastError)
        XCTAssertFalse(store.tasks.last!.deliveryFailed)
        XCTAssertEqual(store.messages.count, 2)
        await store.refresh()
        let posts = await wire.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
    }
    func testPathNotificationsPreserveOpeningAndReceivingSubscription() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.delaySubscriptionHandshake()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        await store.retryConnection(ifNeeded: true)
        try await eventually { await wire.streams.count == 1 }
        await wire.appendMessage("before path change")
        try await eventually { store.messages.count == 1 }
        for _ in 0..<3 { await store.retryConnection(ifNeeded: true) }
        await wire.appendMessage("after path change")
        try await eventually { store.messages.count == 2 }
        let subscriptions = await wire.subscriptions
        let closed = await wire.detached
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(closed, 0)
    }

    func testEndedSubscriptionAutomaticallyReplacedWithoutSendingAnotherMessage() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.failSubscriptionOnce()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        await wire.appendMessage("completed while subscription was unavailable")
        try await eventually { await wire.subscriptions.count == 2 }
        try await eventually { store.messages.count == 1 }
        let subscriptions = await wire.subscriptions
        XCTAssertEqual(subscriptions, [0, 0])
        XCTAssertEqual(store.messages.first?.content, "completed while subscription was unavailable")
    }

    func testRepeatedStreamFailuresCatchUpOverHTTPAndResumeWithoutResending() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.rejectSubscription(502)
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        await wire.appendMessage("arrived during outage")
        try await eventually { store.messages.count == 1 && store.connectionState == .ready }
        store.setDraft("send during outage")
        _ = try store.enqueue()
        await store.refresh(userInitiated: true)
        try await eventually { store.messages.last?.content == "finished" && store.tasks.last?.run?.status == "completed" }
        await wire.rejectSubscription(nil)
        try await eventually { await wire.streams.count == 1 }
        await wire.appendMessage("back on stream")
        try await eventually { store.messages.count == 4 }
        let requests = await wire.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/momo/v1/conversation/messages" && $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(Set(store.messages.map(\.id)).count, 4)
    }

    func testSameStoreResumesBackgroundCompletionAndColdReopenKeepsCanonicalReply() async throws {
        let (wire, store, file, client) = try fixture()
        store.foreground(); try await eventually { await wire.subscriptions.count == 1 }
        store.background()
        await wire.appendMessage("finished after suspension", run: "accepted-run")
        store.foreground(); defer { store.background() }
        try await eventually { store.messages.count == 1 }
        await wire.repeatLast()
        let reopened = try RemoteTaskStore(file: file, connection: store.connection, client: client)
        XCTAssertEqual(reopened.messages.map(\.id), store.messages.map(\.id))
        XCTAssertEqual(reopened.eventCursor, store.eventCursor)
        XCTAssertEqual(reopened.messages.count, 1)
    }
    func testTransientSendFailureStaysPendingAndAutomaticallyUsesSameOperation() async throws {
        var clock = Date()
        let (wire, store, _, _) = try fixture(now: { clock })
        await wire.rejectPostOnce()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        store.setDraft("recover without red failure"); let id = try store.enqueue()
        await store.refresh(userInitiated: true)
        XCTAssertEqual(store.connectionState, .retrying)
        XCTAssertFalse(store.tasks.last!.deliveryFailed)
        XCTAssertNil(store.tasks.last?.run)
        XCTAssertFalse(store.waitingForReply, "No admission means no read receipt or typing")
        clock = try XCTUnwrap(store.nextConnectionAttempt).addingTimeInterval(1)
        await store.refresh()
        try await eventually { store.tasks.last?.run?.status == "completed" }
        XCTAssertEqual(store.tasks.last?.id, id)
        let posts = await wire.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
    }
    func testTransportRecoveryImmediatelyReplaysOnlyTheDurableOperation() async throws {
        for code in [URLError.badURL, .networkConnectionLost, .notConnectedToInternet] {
        let (wire, store, _, _) = try fixture()
        await wire.failPostOnce(code)
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        store.setDraft("repair the pool"); let id = try store.enqueue()
        await store.refresh(userInitiated: true)
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.tasks.last?.id, id)
        XCTAssertEqual(store.tasks.last?.run?.status, "completed")
        XCTAssertFalse(store.tasks.last!.deliveryFailed)
        let posts = await wire.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
        }
    }
    func testMissedCommitBetweenSnapshotAndSubscribeAndAllOlderPagesAreRecovered() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.seed(205)
        await wire.commitDuringSnapshot()
        store.foreground(); defer { store.background() }
        try await eventually { store.messages.count == 206 }
        XCTAssertEqual(Set(store.messages.map(\.id)).count, 206)
        XCTAssertEqual(store.messages.last?.content, "between snapshot and subscribe")
        XCTAssertEqual(store.messageCursor, 206)
    }
    func testDisconnectCatchesUpWithoutResubmittingAndForeignGenerationCannotWrite() async throws {
        let (wire, store, _, _) = try fixture()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        await wire.disconnect()
        await wire.appendMessage("offline result")
        try await eventually { store.messages.count == 1 }
        let cursor = store.eventCursor
        await wire.foreignEvent()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.eventCursor, cursor); XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.connectionState, .unavailable)
        await store.retryConnection()
        try await eventually { store.connectionState == .ready }
        await wire.appendMessage("after explicit recovery")
        try await eventually { store.messages.count == 2 }
        let requests = await wire.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    }
    func testReconnectingLegacyJournalAcceptsRevisedDreamBriefingOnly() async throws {
        for briefing in [true, false] {
            let (wire, store, file, client) = try fixture()
            await wire.appendMessage("current text", sourceKey: briefing ? "dream-briefing:updated" : nil)
            store.foreground()
            try await eventually { store.messages.count == 1 }
            store.background()
            var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var rows = try XCTUnwrap(saved["messages"] as? [[String: Any]])
            rows[0]["content"] = "previous text"
            rows[0].removeValue(forKey: "source_key")
            saved["messages"] = rows
            saved.removeValue(forKey: "eventCursor")
            try JSONSerialization.data(withJSONObject: saved).write(to: file)
            let restored = try RemoteTaskStore(file: file, connection: store.connection, client: client)
            restored.foreground()
            defer { restored.background() }
            if briefing {
                try await eventually { restored.messages.first?.content == "current text" && restored.connectionState == .ready }
                XCTAssertEqual(restored.messages.map(\.id), store.messages.map(\.id))
                let reopened = try RemoteTaskStore(file: file, connection: store.connection, client: client)
                XCTAssertEqual(reopened.messages, restored.messages)
            } else {
                try await eventually { restored.connectionState == .unavailable }
                XCTAssertEqual(restored.messages.first?.content, "previous text")
            }
        }
    }

    func testSnapshotRecoveryFillsGapEvenWhenOlderRowsAreAlreadyCached() async throws {
        let (wire, store, file, client) = try fixture()
        await wire.seed(5)
        store.foreground()
        try await eventually { store.messages.count == 5 }
        store.background()
        var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        saved.removeValue(forKey: "eventCursor")
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        await wire.seed(200)
        let restored = try RemoteTaskStore(file: file, connection: store.connection, client: client)
        restored.foreground(); defer { restored.background() }
        try await eventually { restored.messages.count == 205 }
        XCTAssertEqual(Set(restored.messages.map(\.seq)).count, 205)
        let snapshots = await wire.snapshots
        XCTAssertEqual(snapshots, 2)
    }
    func testIdleStreamTimesOutAndCancelsTransport() async throws {
        let (wire, _, _, client) = try fixture()
        do {
            for try await _ in try client.conversationEvents(after: 0, idleTimeout: 0.02) {}
            XCTFail("Half-open stream must time out")
        } catch URLError.timedOut { }
        try await eventually { await wire.detached > 0 }
    }
    func testUnauthorizedSubscriptionStopsWithoutNetworkFallback() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.rejectSubscription(401)
        store.foreground(); defer { store.background() }
        try await eventually { store.connectionState == .authenticationRequired }
        let count = await wire.subscriptions.count
        try await Task.sleep(for: .milliseconds(300))
        let later = await wire.subscriptions.count
        XCTAssertEqual(count, later)
    }
    func testLongCanonicalReplyUsesTheSameLimitAsSnapshotInsteadOfSilentlyDroppingIt() async throws {
        let (wire, store, _, _) = try fixture()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        let text = String(repeating: "long reply ", count: 55_000)
        await wire.appendMessage(text)
        try await eventually { store.messages.count == 1 }
        XCTAssertEqual(store.messages.first?.content, text)
    }
    func testFailedPersistenceCannotAdvanceAppliedCursor() async throws {
        let (wire, store, file, _) = try fixture()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        let cursor = store.eventCursor
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await wire.appendMessage("must replay after storage recovers")
        try await eventually { store.interactionFailure != nil }
        XCTAssertEqual(store.eventCursor, cursor)
        XCTAssertTrue(store.messages.isEmpty)
    }
    func testRetryAfterIsHonoredAndHeartbeatDoesNotAdvanceCursor() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.throttleOnce()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        try await eventually { store.connectionState == .retrying }
        await store.retryConnection(ifNeeded: true)
        await store.retryConnection()
        try await Task.sleep(for: .milliseconds(100))
        let early = await wire.subscriptions.count; XCTAssertEqual(early, 1)
        try await eventually { await wire.subscriptions.count == 2 }
        let cursor = store.eventCursor
        await wire.heartbeat()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.eventCursor, cursor)
    }

    func testCrossDeviceRunEventsPopulateSharedRunRepliesUntilTerminal() async throws {
        let (wire, store, _, _) = try fixture()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        let runID = "run-mac-peer"
        let root = await wire.root
        await wire.appendMessage("Run from Mac", role: "user", run: runID)
        await wire.pushRun(["run_id": runID, "session_id": root, "status": "running"])
        await wire.pushRunEvent(["event": "tool.started", "run_id": runID, "tool": "terminal", "title": "ls"])
        await wire.pushRunEvent(["event": "message.delta", "run_id": runID, "delta": "Hello from "])
        await wire.pushRunEvent(["event": "message.delta", "run_id": runID, "delta": "Mac"])
        try await eventually { store.sharedRunReplies[runID]?.partial == "Hello from Mac" }
        XCTAssertEqual(store.sharedRunReplies[runID]?.tools?.count, 1)

        await wire.appendMessage("Hello from Mac", role: "assistant", run: runID)
        await wire.pushRun(["run_id": runID, "session_id": root, "status": "completed"])
        try await eventually { store.sharedRunReplies[runID] == nil && store.messages.count == 2 }
    }

    func testInvalidResponseOnSubscriptionStreamRetriesInsteadOfPermanentUnavailable() async throws {
        let (wire, store, _, _) = try fixture()
        await wire.sendBadSubscriptionContentTypeOnce()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        XCTAssertNotEqual(store.connectionState, .unavailable)
        try await eventually { await wire.subscriptions.count == 2 && store.connectionState == .ready }
        await wire.appendMessage("recovered after proxy html")
        try await eventually { store.messages.last?.content == "recovered after proxy html" }
    }

    func testStreamingDeltasCoalesceJournalWritesUntilStructuralEventOrBackground() async throws {
        let (wire, store, file, _) = try fixture()
        await wire.keepPostStreaming()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        store.setDraft("stream tokens")
        let taskID = try store.enqueue()
        await store.refresh(userInitiated: true)
        let runID = try XCTUnwrap(store.tasks.first(where: { $0.id == taskID })?.run?.runID)
        try await eventually { store.tasks.first(where: { $0.id == taskID })?.firstTextReceivedAt != nil }

        let diskAfterFirstToken = try Data(contentsOf: file)
        for index in 1...12 {
            await wire.pushRunEvent(["event": "message.delta", "run_id": runID, "delta": " tok\(index)"])
        }
        try await eventually { store.tasks.first(where: { $0.id == taskID })?.reply?.partial.hasSuffix("tok12") == true }
        let diskDuringBurst = try Data(contentsOf: file)
        XCTAssertEqual(diskAfterFirstToken, diskDuringBurst, "Subsequent streaming deltas should coalesce rather than rewrite journal per token")

        store.background()
        let diskAfterBackground = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let savedTasks = diskAfterBackground["tasks"] as! [[String: Any]]
        let savedReply = savedTasks.first?["reply"] as? [String: Any]
        XCTAssertEqual((savedReply?["partial"] as? String)?.hasSuffix("tok12"), true)
    }

    func testConfirmedAttachmentStripsRawDataFromJournalWhileKeepingPreviewAndMetadata() async throws {
        var clock = Date()
        let (wire, store, file, _) = try fixture(now: { clock })
        await wire.rejectPostOnce()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }

        let rawPayload = Data(repeating: 0xAB, count: 65_536)
        let preview = Data([0x89, 0x50, 0x4E, 0x47])
        let attachment = AgentAttachment(name: "photo.jpg", kind: .image, mediaType: "image/jpeg",
                                         byteCount: rawPayload.count, data: rawPayload, preview: preview)
        try store.addAttachments([attachment])
        store.setDraft("describe photo")
        let taskID = try store.enqueue()
        await store.refresh(userInitiated: true)

        XCTAssertNil(store.tasks.first(where: { $0.id == taskID })?.run)
        XCTAssertEqual(store.tasks.first(where: { $0.id == taskID })?.attachments?.first?.data?.count, 65_536,
                       "Unconfirmed submission must retain raw attachment data for retry")

        clock = try XCTUnwrap(store.nextConnectionAttempt).addingTimeInterval(1)
        await store.refresh()
        try await eventually { store.tasks.first(where: { $0.id == taskID })?.run?.status == "completed" }

        let stripped = try XCTUnwrap(store.tasks.first(where: { $0.id == taskID })?.attachments?.first)
        XCTAssertNil(stripped.data)
        XCTAssertEqual(stripped.preview, preview)
        XCTAssertEqual(stripped.byteCount, 65_536)
        XCTAssertEqual(stripped.name, "photo.jpg")
        let journalBytes = try Data(contentsOf: file).count
        XCTAssertLessThan(journalBytes, 16_384)
    }

    func testForegroundClearsStaleBackgroundRetryingAndAbsorbsSingleInitialSocketWarmupFailure() async throws {
        let (wire, store, _, _) = try fixture()
        store.foreground()
        try await eventually { await wire.subscriptions.count == 1 && store.connectionState == .ready }
        await wire.appendMessage("initial message")
        try await eventually { store.messages.count == 1 }

        // Simulate iOS dropping the SSE socket right as the app transitions to background.
        store.recordConnectionFailure(URLError(.networkConnectionLost))
        XCTAssertEqual(store.connectionState, .retrying)
        XCTAssertNotNil(store.nextConnectionAttempt)
        store.background()

        // Reopen with one transient SOCKS5/DERP warmup socket error (-1000 badURL) on the first stream attempt.
        await wire.failSocketOnceOnSubscribe(.badURL)
        store.foreground()
        XCTAssertEqual(store.connectionState, .ready, "Stale background retrying state must not flash on first-screen reopen")
        XCTAssertNil(store.nextConnectionAttempt)
        try await eventually { await wire.subscriptions.count == 3 && store.connectionState == .ready }
        await wire.appendMessage("after smooth foreground reopen")
        try await eventually { store.messages.count == 2 }
        XCTAssertEqual(store.connectionState, .ready)
        store.background()

        // If the peer genuinely remains unreachable across consecutive attempts, recovery UI must surface.
        await wire.setLinkDown(true)
        store.foreground(); defer { store.background() }
        try await eventually { store.connectionState == .retrying }
    }

    func testProviderNoticeArrivesOverLiveStreamAndHonorsDismissal() async throws {
        let (wire, store, _, _) = try fixture()
        store.foreground(); defer { store.background() }
        try await eventually { await wire.subscriptions.count == 1 }
        XCTAssertNil(store.activeProviderNotice)

        let noticeID = "pnotice-" + UUID().uuidString.lowercased()
        await wire.pushProviderNotice([
            "id": noticeID,
            "kind": "quota",
            "provider": "antigravity",
            "provider_label": "Antigravity",
            "title": "Antigravity 当前额度已用完",
            "message": "可在设置中切换到其他模型服务继续使用。",
            "short_error": "Antigravity 当前额度已用完。",
            "created_at": 1762070400.0,
        ])
        try await eventually { store.activeProviderNotice?.id == noticeID }
        XCTAssertEqual(store.activeProviderNotice?.title, "Antigravity 当前额度已用完")

        store.dismissProviderNotice(noticeID)
        XCTAssertNil(store.activeProviderNotice)
        XCTAssertEqual(store.providerNotice?.id, noticeID)

        // Same notice ID pushed again on retry does not re-pop the alert.
        await wire.pushProviderNotice([
            "id": noticeID,
            "kind": "quota",
            "provider": "antigravity",
            "provider_label": "Antigravity",
            "title": "Antigravity 当前额度已用完",
            "message": "可在设置中切换到其他模型服务继续使用。",
            "created_at": 1762070400.0,
            "updated_at": 1762070405.0,
        ])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(store.activeProviderNotice)

        // Server clearing notice clears providerNotice completely.
        await wire.pushProviderNotice(nil)
        try await eventually { store.providerNotice == nil }
    }
}

private actor LiveWire: AgentTransport {
    nonisolated let requiresExclusiveRouting = true
    let connection: AgentConnection
    var root: String { "momo-main-" + connection.assistantID.uuidString.lowercased() }
    var conversationID: String { "conversation-" + connection.assistantID.uuidString.lowercased() }
    var requests: [URLRequest] = [], subscriptions: [Int] = []
    var messages: [[String: Any]] = [], events: [[String: Any]] = []
    var runs: [[String: Any]] = []
    var streams: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    var snapshots = 0, detached = 0
    var betweenSnapshot = false, rejection: Int?, throttle = false
    var lostReceipt = false, postError: URLError.Code?
    var postRejection: Int?
    var delayedHandshake = false
    func delaySubscriptionHandshake() { delayedHandshake = true }
    var failedSubscription = false
    var socketSubscribeFailure: URLError.Code?
    var linkDown = false
    var badSubscriptionContentType = false
    var holdCompletion = false
    enum InterruptedTransport: Error { case closed }
    func failSubscriptionOnce() { failedSubscription = true }
    func failSocketOnceOnSubscribe(_ code: URLError.Code) { socketSubscribeFailure = code }
    func setLinkDown(_ value: Bool) { linkDown = value }
    func sendBadSubscriptionContentTypeOnce() { badSubscriptionContentType = true }
    func keepPostStreaming() { holdCompletion = true }
    func pushRun(_ run: [String: Any]) {
        if let id = run["run_id"] as? String, let index = runs.firstIndex(where: { ($0["run_id"] as? String) == id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        emit("run.updated", ["run": run])
    }
    func pushRunEvent(_ event: [String: Any]) { emit("run.event", ["run_event": event]) }
    func pushProviderNotice(_ notice: [String: Any]?) {
        var payload: [String: Any] = ["background_work": [], "message_states": [:]]
        payload["provider_notice"] = notice ?? NSNull()
        emit("work.updated", payload)
    }
    init(_ connection: AgentConnection) { self.connection = connection }
    func commitDuringSnapshot() { betweenSnapshot = true }
    func rejectSubscription(_ code: Int?) { rejection = code }
    func throttleOnce() { throttle = true }
    func losePostReceipt() { lostReceipt = true }
    func failPostOnce(_ code: URLError.Code = .networkConnectionLost) { postError = code }
    func rejectPostOnce() { postRejection = 503 }
    func heartbeat() { for stream in streams.values { stream.yield(frame(["conversation_id":conversationID,"kind":"heartbeat"])) } }
    func seed(_ count: Int) async { for n in 0..<count { appendMessage("history \(n)") } }
    func appendMessage(_ content: String, role: String = "assistant", run: String? = nil, operation: String? = nil, sourceKey: String? = nil) {
        var message: [String: Any] = ["id":UUID().uuidString, "seq":messages.count+1, "role":role, "content":content, "created_at":1]
        message["source_key"] = sourceKey
        message["run_id"] = run; message["operation_id"] = operation
        messages.append(message); emit("message.created", ["message":message])
    }
    func emit(_ kind: String, _ payload: [String: Any]) {
        var value = payload; value["kind"] = kind; value["conversation_id"] = conversationID; value["cursor"] = events.count + 1
        if var event = value["run_event"] as? [String: Any] { event["seq"] = events.count + 1; value["run_event"] = event }
        events.append(value)
        for stream in streams.values { stream.yield(frame(value)) }
    }
    func repeatLast() { if let last = events.last { for stream in streams.values { stream.yield(frame(last)) } } }
    func foreignEvent() {
        let bad: [String: Any] = ["conversation_id":"other", "kind":"message.created", "cursor":events.count+1]
        for stream in streams.values { stream.yield(frame(bad)) }
    }
    func disconnect() { for stream in streams.values { stream.finish(throwing: URLError(.networkConnectionLost)) }; streams.removeAll() }
    func remove(_ id: UUID) { streams.removeValue(forKey: id); detached += 1 }
    func frame(_ value: [String: Any]) -> Data { Data("data: ".utf8) + (try! JSONSerialization.data(withJSONObject: value)) + Data("\n\n".utf8) }
    func json(_ value: [String: Any], status: Int = 200) throws -> AgentByteStream {
        let data = try JSONSerialization.data(withJSONObject: value)
        return AgentByteStream(status: status, contentType: "application/json", chunks: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        requests.append(request)
        if linkDown { throw URLError(.badURL) }
        let path = request.url!.path
        if path == "/momo/v1/conversation" {
            return try json(["conversation_id":conversationID,"session_id":root,"assistant_id":connection.assistantID.uuidString,"instance_id":connection.instanceID.uuidString,
                "capabilities":["shared_conversation":true,"server_owned_completion":true,"durable_steering":true,"independent_chat_while_waiting":true,"system_push":false,"conversation_events":true,
                    "message_idempotency":["supported":true,"durable":true,"retention_seconds":86400]]])
        }
        if path == "/momo/v1/conversation/snapshot" {
            snapshots += 1
            let result = try json(["conversation_id":conversationID,"cursor":events.count,
                "messages":["data":Array(messages.suffix(100)),"next_cursor":messages.suffix(100).first?["seq"] ?? 0,"has_more":messages.count>100],
                "runs":runs,"background_work":[],"message_states":[:]])
            if betweenSnapshot { betweenSnapshot = false; appendMessage("between snapshot and subscribe") }
            return result
        }
        if path == "/momo/v1/conversation/subscribe" {
            let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)!
            subscriptions.append(after)
            if delayedHandshake { try await Task.sleep(for: .milliseconds(100)) }
            if let code = socketSubscribeFailure { socketSubscribeFailure = nil; throw URLError(code) }
            if failedSubscription { failedSubscription = false; throw InterruptedTransport.closed }
            if badSubscriptionContentType {
                badSubscriptionContentType = false
                let html = Data("<html>splash</html>".utf8)
                return AgentByteStream(status: 200, contentType: "text/html", chunks: AsyncThrowingStream { $0.yield(html); $0.finish() })
            }
            if throttle {
                throttle = false
                return AgentByteStream(status:429,contentType:"application/json",retryAfter:"0.3",chunks:AsyncThrowingStream { $0.finish() })
            }
            if let rejection { return try json([:], status: rejection) }
            let id = UUID(), (stream, c) = AsyncThrowingStream<Data, Error>.makeStream()
            streams[id] = c; c.onTermination = { _ in Task { await self.remove(id) } }
            c.yield(frame(["conversation_id":conversationID,"kind":"ready"]))
            for event in events where (event["cursor"] as! Int) > after { c.yield(frame(event)) }
            return AgentByteStream(status:200,contentType:"text/event-stream",chunks:stream)
        }
        if path == "/momo/v1/conversation/messages", request.httpMethod == "POST" {
            if let status = postRejection { postRejection = nil; return try json([:], status: status) }
            if let code = postError { postError = nil; throw URLError(code) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let operation = body["operation_id"] as! String, run = "run_" + operation
            let receipt: [String: Any] = ["run_id":run,"session_id":root,"status":"queued"]
            appendMessage(body["content"] as! String, role:"user",run:run,operation:operation)
            emit("run.updated",["run":receipt])
            emit("run.event",["run_event":["event":"message.delta","run_id":run,"delta":"first token"]])
            if !holdCompletion {
                appendMessage("finished",run:run)
                var terminal = receipt; terminal["status"] = "completed"; runs.append(terminal)
                emit("run.updated",["run":terminal])
            } else {
                runs.append(receipt)
            }
            try await Task.sleep(for:.milliseconds(30))
            if lostReceipt { throw URLError(.networkConnectionLost) }
            return try json(receipt)
        }
        if path == "/momo/v1/conversation/messages", request.httpMethod == "GET" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL:false)!.queryItems!
            if let after = query.first(where: { $0.name == "after" })?.value.flatMap(Int.init) {
                let all = messages.filter { ($0["seq"] as! Int) > after }, page = Array(all.prefix(100))
                return try json(["data":page,"next_cursor":page.last?["seq"] ?? after,"has_more":all.count>100])
            }
            let before = Int(query.first(where: { $0.name == "before" })!.value!)!
            let all = messages.filter { ($0["seq"] as! Int) < before }, page = Array(all.suffix(100))
            return try json(["data":page,"next_cursor":page.first?["seq"] ?? before,"has_more":all.count>100])
        }
        if path == "/momo/v1/conversation/runs" { return try json(["data":runs, "background_work":[], "message_states":[:]]) }
        if path == "/v1/capabilities" { return try json(["features":["run_submission":true]]) }
        throw AgentClientError.http(status: 404, code: nil, message: path, retryAfter: nil)
    }
}
