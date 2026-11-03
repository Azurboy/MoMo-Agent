import Foundation
import UIKit
import SwiftUI
import WebKit
import XCTest
import MoMoAgentClient
@testable import MoMoAgent

@MainActor
final class ChatRendererTests: XCTestCase {
    func testInterleavedCompletionsNeverRebuildOrAnimateHistoryOnRefresh() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        func message(_ id: String, _ run: String, _ role: String) -> AgentChatMessage {
            .init(id: id, turnID: run, role: role, blocks: [.init(id: id + ":text", content: .text(id))], state: .complete)
        }
        var messages: [AgentChatMessage] = []
        for index in 0..<7 {
            messages += [message("user-\(index)", "run-\(index)", "user"), message("ack-\(index)", "run-\(index)", "assistant")]
        }
        renderer.render(messages, reduceMotion: false, canRegenerate: false)
        try await renderer.wait("document.querySelectorAll('.turn').length === 14")
        for index in 0..<7 { messages.append(message("final-\(index)", "run-\(index)", "assistant")) }
        renderer.render(messages, reduceMotion: false, canRegenerate: false)
        try await renderer.wait("document.querySelectorAll('.turn').length === 21 && document.querySelectorAll('.turn').item(20).textContent.includes('final-6')")
        try await Task.sleep(for: .milliseconds(400))
        _ = try await renderer.web.evaluateJavaScript("""
        window.historyDocument = document.documentElement;
        window.historyRows = [...document.querySelectorAll('.turn')];
        window.historyProse = [...document.querySelectorAll('.prose')];
        window.historyMutations = 0; window.historyAnimations = 0; window.historyRenderCount = 0;
        new MutationObserver(records => { historyMutations += records.filter(r=>r.type==='childList').length; })
          .observe(document.querySelector('#transcript'),{childList:true,subtree:true});
        document.querySelector('#transcript').addEventListener('animationstart',()=>historyAnimations++);
        const renderHistory = MoMoChat.render;
        MoMoChat.render = snapshot => { renderHistory(snapshot); historyRenderCount++; };
        true;
        """)
        for index in 0..<20 {
            renderer.render(messages, busy: index % 2 == 0, reduceMotion: false, canRegenerate: false)
            try await renderer.wait("historyRenderCount === \(index + 1)")
        }
        try await renderer.check("historyDocument === document.documentElement && historyMutations === 0 && historyAnimations === 0")
        try await renderer.check("historyRows.every((row,i)=>row===document.querySelectorAll('.turn')[i]) && historyProse.every((p,i)=>p===document.querySelectorAll('.prose')[i])")
        try await renderer.check("JSON.parse(document.querySelector('[data-message=\"ack-0:reply\"]').dataset.sourceIds).join() === 'ack-0'")
        try await renderer.check("JSON.parse(document.querySelector('[data-message=\"final-0:reply\"]').dataset.sourceIds).join() === 'final-0'")
        await renderer.attach(to: self, name: "interleaved-results-stable-history")
    }

    func testCompletedStatusKeepsDotsUntilSharedReplyIsRendered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tasks.json")
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: URL(string: "https://unsent.invalid")!)
        let client = try AgentClient(baseURL: connection.baseURL, credential: "fixture", assistantID: connection.assistantID)
        let seed = try RemoteTaskStore(file: file, connection: connection, client: client)
        seed.setDraft("等待实际回复"); let id = try seed.enqueue()
        var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var tasks = journal["tasks"] as! [[String: Any]]
        tasks[0]["run"] = ["run_id": "run-reply", "session_id": tasks[0]["sessionID"]!, "status": "completed", "output": "回复已经显示"]
        journal["tasks"] = tasks
        let echo: [String: Any] = ["id": "echo", "seq": 1, "role": "user", "content": "等待实际回复", "created_at": 1.0,
                                  "run_id": "run-reply", "operation_id": id.uuidString]
        journal["messages"] = [echo]; journal["messageCursor"] = 1
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        let completed = try RemoteTaskStore(file: file, connection: connection, client: client)
        let pending = ChatRenderSnapshot(store: completed)
        XCTAssertFalse(pending.messages.contains { $0.role == "assistant" })
        XCTAssertEqual(pending.waitingForReply, true)
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.coordinator.update(.init(snapshot: pending, appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        try await renderer.wait("document.body.textContent.includes('等待实际回复') && !document.querySelector('#working').hidden")
        try await renderer.check("document.querySelectorAll('.typing-dots > span').length === 3 && !document.querySelector('.prose')")
        journal["messages"] = [echo, ["id": "reply", "seq": 2, "role": "assistant", "content": "回复已经显示", "created_at": 2.0, "run_id": "run-reply"]]
        journal["messageCursor"] = 2
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        let delivered = try RemoteTaskStore(file: file, connection: connection, client: client)
        renderer.coordinator.update(.init(snapshot: .init(store: delivered), appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        try await renderer.wait("document.querySelector('.prose')?.textContent.includes('回复已经显示') && document.querySelector('#working').hidden")
        await renderer.attach(to: self, name: "reply-replaces-dots")
    }

    func testReceiptStateMachineShowsDeliveredThenReadAndDotsWithoutMovingBubbles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: URL(string: "https://unsent.invalid")!)
        let client = try AgentClient(baseURL: connection.baseURL, credential: "fixture", assistantID: connection.assistantID)
        let file = folder.appendingPathComponent("tasks.json")
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        store.setDraft("等待 Mac 接收"); try store.enqueue()
        XCTAssertNil(store.tasks.last?.firstAttemptAt)
        XCTAssertNil(ChatRenderSnapshot(store: store).deliveryReceiptMessageID)
        renderer.coordinator.update(.init(snapshot: .init(store: store), appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        try await renderer.wait("document.body.textContent.includes('等待 Mac 接收') && document.querySelector('#working').hidden")
        try await renderer.check("document.querySelector('.read-receipt')?.getAttribute('aria-hidden') === 'true' && !document.body.textContent.includes('发送中') && !document.body.textContent.includes('未送达')")
        _ = try await renderer.web.evaluateJavaScript("window.receiptBubble = document.querySelector('.user-bubble'); window.readSlot = document.querySelector('.read-receipt'); window.receiptHeight = document.body.scrollHeight; true")
        var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var tasks = journal["tasks"] as! [[String: Any]]
        tasks[0]["run"] = ["run_id":"run-received", "session_id":tasks[0]["sessionID"]!, "status":"queued"]
        journal["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        let received = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertEqual(ChatRenderSnapshot(store: received).deliveryReceiptMessageID, store.tasks[0].id.uuidString + ":user")
        XCTAssertEqual(ChatRenderSnapshot(store: received).waitingForReply, false)
        renderer.coordinator.update(.init(snapshot: .init(store: received), appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        try await renderer.wait("document.querySelector('.read-receipt')?.textContent === '已送达' && document.querySelector('#working').hidden")
        tasks[0]["run"] = ["run_id":"run-received", "session_id":tasks[0]["sessionID"]!, "status":"running", "execution_generation":1]
        journal["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        let started = try RemoteTaskStore(file: file, connection: connection, client: client)
        renderer.coordinator.update(.init(snapshot: .init(store: started), appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        try await renderer.wait("document.querySelector('.read-receipt')?.textContent === '已读' && !document.querySelector('#working').hidden")
        try await renderer.check("document.querySelectorAll('.typing-dots > span').length === 3 && document.querySelector('#working').dataset.phase === 'waiting'")
        try await renderer.check("window.receiptBubble === document.querySelector('.user-bubble') && readSlot === document.querySelector('.read-receipt') && readSlot.getAttribute('aria-hidden') === 'false' && receiptHeight === document.body.scrollHeight")
        journal["messages"] = [["id": "server-echo", "seq": 1, "role": "user", "content": "等待 Mac 接收", "created_at": 1.0,
                                "run_id": "run-received", "operation_id": store.tasks[0].id.uuidString]]
        journal["messageCursor"] = 1
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        let echoed = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertEqual(ChatRenderSnapshot(store: echoed).deliveryReceiptMessageID, store.tasks[0].id.uuidString + ":user")
        renderer.coordinator.update(.init(snapshot: .init(store: echoed), appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        try await renderer.wait("document.querySelectorAll('.user-bubble').length === 1 && !!document.querySelector('.read-receipt')")
        try await renderer.check("window.receiptBubble === document.querySelector('.user-bubble')")
        journal["messages"] = []; journal["messageCursor"] = 0
        await renderer.attach(to: self, name: "delivered-then-three-dots")
        tasks[0]["run"] = nil; tasks[0]["lastError"] = "Synthetic timeout"; journal["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        let failed = try RemoteTaskStore(file: file, connection: connection, client: client)
        XCTAssertNil(ChatRenderSnapshot(store: failed).deliveryReceiptMessageID)
        renderer.coordinator.update(.init(snapshot: .init(store: failed), appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        try await renderer.wait("!!document.querySelector('.delivery-retry') && document.querySelector('.read-receipt')?.getAttribute('aria-hidden') === 'true' && document.querySelector('#working').hidden")
        try await renderer.check("!document.body.textContent.includes('发送失败') && !document.body.textContent.includes('未送达')")
    }

    func testTerminatedWebContentReloadsLatestReplyWithoutLosingMessages() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("保留这条消息")])
        try await renderer.wait("document.body.textContent.includes('保留这条消息')")
        _ = try await renderer.web.evaluateJavaScript("window.beforeRecovery = true; true")
        renderer.coordinator.webViewWebContentProcessDidTerminate(renderer.web)
        renderer.render([user("保留这条消息"), assistant([.init(id: "recovered", content: .text("恢复后收到的回复"))])])
        try await renderer.wait("document.body.textContent.includes('恢复后收到的回复') && typeof window.beforeRecovery === 'undefined'")
        try await renderer.check("document.body.textContent.includes('保留这条消息')")
    }

    func testCancelledNavigationDoesNotDisableChat() {
        var failures = 0
        let coordinator = ChatWebCoordinator(failed: { failures += 1 }, open: { _ in })
        let web = WKWebView()
        coordinator.webView = web
        coordinator.webView(web, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        coordinator.webView(web, didFail: nil, withError: URLError(.cancelled))
        XCTAssertEqual(failures, 0)
    }

    func testBackgroundTerminationRestoresQueuedReplyOnForeground() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("后台前的消息")])
        try await renderer.wait("document.body.textContent.includes('后台前的消息')")
        renderer.coordinator.setActive(false)
        renderer.coordinator.webViewWebContentProcessDidTerminate(renderer.web)
        renderer.render([user("后台前的消息"), assistant([.init(id: "late", content: .text("后台完成的回复"))])])
        try await renderer.check("!document.body.textContent.includes('后台完成的回复')")
        renderer.coordinator.setActive(true)
        try await renderer.wait("document.body.textContent.includes('后台完成的回复')")
        try await renderer.check("document.body.textContent.includes('后台前的消息')")
        await renderer.attach(to: self, name: "reply-restored-after-background")
    }

    func testJavaScriptFailureReloadsAndReplaysLatestSnapshot() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("原消息")])
        try await renderer.wait("document.body.textContent.includes('原消息')")
        _ = try await renderer.web.evaluateJavaScript("window.MoMoChat.render = () => { throw new Error('synthetic-render-failure'); }; true")
        renderer.render([user("原消息"), assistant([.init(id: "new", content: .text("新回复没有丢失"))])])
        try await renderer.wait("document.body.textContent.includes('新回复没有丢失')")
        try await renderer.check("document.body.textContent.includes('原消息')")
    }

    func testAttachmentsUseClaudeTileGeometryAndKeepIdentityDuringStreaming() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 120), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        }
        let photo = try ChatAttachmentImporter.image(bytes)
        let file = AgentAttachment(name: "下周安排.txt", kind: .document, mediaType: "text/plain", byteCount: 20, text: "文件原文不能显示在气泡中")
        let question = AgentChatMessage(id: "files", turnID: "files", role: "user", blocks: [
            .init(id: photo.id.uuidString, content: .attachment(photo)),
            .init(id: file.id.uuidString, content: .attachment(file))], state: .complete)
        var opened: UUID?
        renderer.coordinator.attachment = { opened = $0 }
        for dark in [false, true] {
            renderer.render([question], dark: dark)
            try await renderer.wait("document.querySelectorAll('.message-attachment').length === 2 && document.querySelector('.attachment-preview').naturalWidth > 0 && document.documentElement.dataset.dark === '\(dark)'")
            try await renderer.check("document.querySelector('.message-attachment').getBoundingClientRect().width === 120 && getComputedStyle(document.querySelector('.attachment-preview')).objectFit === 'contain' && !document.querySelector('.user-bubble')")
            try await renderer.check("!document.body.textContent.includes('文件原文不能显示') && document.querySelector('.attachment-format').textContent === 'TXT'")
            _ = try await renderer.web.evaluateJavaScript("window.keptAttachment = document.querySelector('.message-attachment'); window.keptAttachment.click(); true")
            try await renderer.wait("true")
            XCTAssertEqual(opened, photo.id)
            await renderer.attach(to: self, name: dark ? "attachments-dark" : "attachments-light")
        }
        renderer.render([question, assistant([.init(id: "answer", content: .text("已经读取附件。"))], state: .streaming)], busy: true, dark: true)
        try await renderer.wait("document.querySelector('.prose')?.textContent.includes('已经读取附件') === true")
        try await renderer.check("document.querySelector('.message-attachment') === window.keptAttachment")
    }

    func testToolCardsStayOutsideReasoningAndKeepTheirIdentityAsTheReplyStreams() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let thought = AgentMessageBlock(id: "thought", content: .reasoning("查找相关录音。", redacted: false))
        func call(_ state: AgentToolExecution.State, output: String? = nil) -> AgentMessageBlock {
            .init(id: "read-source", content: .tool(.init(id: "read-source", name: "read_transcript",
                input: "{}", output: output, state: state)))
        }
        renderer.render([user("整理录音"), assistant([thought, call(.running)], state: .streaming)], busy: true)
        try await renderer.wait("document.querySelector('.badge.running')?.textContent === '进行中'")
        try await renderer.check("document.querySelectorAll('.tool-card').length === 1 && document.querySelectorAll('.process .tool-card').length === 0 && document.querySelector('#working').hidden")
        _ = try await renderer.web.evaluateJavaScript("window.originalToolCard = document.querySelector('.tool-card'); window.originalToolCard.querySelector('summary').click(); true")
        let result = "{\"passages\":[{\"text\":\"会议时间是周五下午三点。\"}],\"hasMore\":false}"
        renderer.render([user("整理录音"), assistant([thought, call(.succeeded, output: result),
            .init(id: "answer", content: .text("已找到相关内容，"))], state: .streaming)], busy: true, reduceMotion: false)
        try await renderer.wait("document.querySelector('.prose')?.textContent.includes('已找到相关内容，') === true")
        try await renderer.check("window.originalToolCard === document.querySelector('.tool-card') && window.originalToolCard.open")
        try await renderer.check("document.querySelector('.tool-outcome').textContent === '本次返回 1 段原文' && document.querySelector('.tool-excerpt').textContent === '会议时间是周五下午三点。'")
        try await renderer.check("!document.querySelector('.tool-output') && document.querySelector('#working').hidden && document.querySelector('.process-group').dataset.state === 'settled'")
        await renderer.attach(to: self, name: "mobile-tool-card-streaming")
    }

    func testWaitingForContentIsNotPresentedAsModelReasoning() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("你好")], busy: true)
        try await renderer.wait("document.querySelector('#working')?.dataset.phase === 'waiting'")
        try await renderer.check("document.querySelectorAll('.typing-dots > span').length === 3 && getComputedStyle(document.querySelector('.typing-bubble')).display === 'block' && getComputedStyle(document.querySelector('.working-label')).display === 'none' && !document.querySelector('.process')")
        renderer.render([user("你好"), assistant([.init(id: "reply", content: .text("你好，在的。"))], state: .streaming)], busy: true, reduceMotion: false)
        try await renderer.wait("document.querySelector('.prose')?.textContent.includes('你好，在的。') === true")
        try await renderer.check("document.querySelector('#working').hidden && document.querySelector('#working').dataset.phase === 'writing'")
    }

    func testCompactionStatusKeepsChatVisibleAndYieldsToTheAnswer() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let question = user("继续刚才的对话")
        renderer.render([question], busy: true, contextState: .compacting)
        try await renderer.wait("document.querySelector('#working')?.dataset.phase === 'compacting'")
        try await renderer.check("!document.querySelector('#working').hidden && document.querySelector('#working').textContent.includes('整理较早的对话') && document.querySelector('#transcript').textContent.includes('继续刚才的对话')")
        renderer.render([question], busy: true, contextState: .compacted)
        try await renderer.wait("document.querySelector('#working')?.dataset.phase === 'compacted'")
        try await renderer.check("document.querySelector('#working').textContent.includes('正在继续回复')")
        renderer.render([question, assistant([.init(id: "reply", content: .text("The full answer continues."))], state: .streaming)],
            busy: true, contextState: .compacted)
        try await renderer.wait("document.querySelector('#working').hidden && document.querySelector('#working').dataset.phase === 'writing'")
        try await renderer.check("document.querySelector('.prose').textContent.includes('The full answer continues.')")
        renderer.render([question], contextState: .failed)
        try await renderer.wait("document.querySelector('#working')?.dataset.phase === 'contextFailed'")
        try await renderer.check("document.querySelector('#working').textContent.includes('聊天记录已保留') && document.querySelector('#working').dataset.animating === 'false'")
        renderer.render([question], busy: true, stopped: true, contextState: .compacting)
        try await renderer.wait("document.querySelector('#working').hidden")
    }

    func testReasoningNeedsOnlyOneDisclosureAndKeepsTheReadersChoiceDuringStreaming() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        func messages(_ text: String, streaming: Bool = true) -> [AgentChatMessage] {
            [user("嗨"), assistant([.init(id: "thought", content: .reasoning(text, redacted: false)),
                .init(id: "reply", content: .text("嗨，在的。"))], state: streaming ? .streaming : .complete)]
        }
        renderer.render(messages("简短回应即可。"), busy: true)
        try await renderer.wait("document.querySelector('.reasoning')?.textContent === '简短回应即可。'")
        try await renderer.check("document.querySelector('.process').open === false && document.querySelectorAll('.process details').length === 0 && document.querySelector('.process-disclosure > summary').hidden")
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('.process > summary').click(); true")
        try await renderer.wait("document.querySelector('.process').open && document.querySelector('.reasoning').getBoundingClientRect().height > 0")
        try await renderer.check("document.querySelectorAll('.process-title').length === 1 && getComputedStyle(document.querySelector('.process-body')).borderTopWidth === '0px'")
        renderer.render(messages("简短回应即可。补充的思考继续显示。", streaming: true), busy: true)
        try await renderer.wait("document.querySelector('.process').open && document.querySelector('.reasoning').textContent.includes('补充的思考')")
        renderer.render(messages("简短回应即可。补充的思考继续显示。完成。", streaming: false))
        try await renderer.wait("document.querySelector('.reasoning').textContent.endsWith('完成。') && !document.querySelector('.process-disclosure').open")
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('.process-disclosure > summary').click(); true")
        try await renderer.check("document.querySelector('.reasoning').getBoundingClientRect().height > 0 && getComputedStyle(document.querySelector('.reasoning-step > summary')).display === 'none'")
        await renderer.attach(to: self, name: "reasoning-one-disclosure")
    }

    func testCompletedReplyFoldsAllStepsOnceAndPreservesManualReopening() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let steps: [AgentMessageBlock] = [
            .init(id: "thought", content: .reasoning("先查找录音，再核对原文。", redacted: false)),
            tool("list", name: "list_recordings", state: .succeeded, output: "{\"items\":[]}"),
            .init(id: "check", content: .reasoning("核对资料的时间范围。", redacted: false)),
            tool("read", name: "read_transcript", state: .succeeded, output: "{\"passages\":[{\"text\":\"周五下午三点开会。\"}]}")]
        // A tool-only message finishing is not the entire reply finishing.
        renderer.render([user("整理最近的录音"), assistant(steps)], busy: true, dark: true)
        try await renderer.wait("document.querySelectorAll('.tool-card').length === 2 && document.querySelector('.process-disclosure').open")
        _ = try await renderer.web.evaluateJavaScript("window.keptTool = document.querySelector('.tool-card'); window.keptTool.querySelector('summary').click(); true")
        let blocks = steps + [.init(id: "answer", content: .text("最近的录音里提到：周五下午三点开会。"))]
        renderer.render([user("整理最近的录音"), assistant(blocks, state: .streaming)], busy: true, dark: true)
        try await renderer.wait("document.querySelector('.prose')?.textContent.includes('周五下午三点') === true")
        try await renderer.check("window.keptTool.open && document.querySelector('.process-disclosure').open && document.querySelector('.process-group').dataset.completed === 'false'")
        await renderer.attach(to: self, name: "process-before-reply-finishes")
        // Submission bookkeeping may remain busy after the visible reply is complete.
        renderer.render([user("整理最近的录音"), assistant(blocks)], busy: true, dark: true)
        try await renderer.wait("!document.querySelector('.process-disclosure').open && document.querySelector('.process-group').dataset.completed === 'true'")
        try await renderer.check("!window.keptTool.open && window.keptTool === document.querySelector('.tool-card') && document.querySelector('.process-label').textContent === '思考与工具 · 已完成 2 项操作'")
        try await renderer.check("document.querySelector('.process-group').getBoundingClientRect().height <= 60 && document.querySelector('.process-disclosure > summary').getBoundingClientRect().height >= 44")
        await renderer.attach(to: self, name: "process-after-reply-finishes")
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('.process-disclosure > summary').click(); window.keptTool.querySelector('summary').click(); true")
        try await renderer.wait("document.querySelector('.process-disclosure').open && window.keptTool.open")
        let nextUser = AgentChatMessage(id: "next-user", turnID: "next", role: "user", blocks: [.init(id: "next-text", content: .text("还有呢"))], state: .complete)
        let nextReply = AgentChatMessage(id: "next-reply", turnID: "next", role: "assistant", blocks: [.init(id: "next-thought", content: .reasoning("再查一次。", redacted: false))], state: .streaming)
        renderer.render([user("整理最近的录音"), assistant(blocks), nextUser, nextReply], busy: true, dark: true)
        try await renderer.wait("document.querySelectorAll('.process-group').length === 2")
        try await renderer.check("document.querySelector('.process-disclosure').open && window.keptTool.open && window.keptTool === document.querySelector('.tool-card')")
        // Recreating history starts folded; no source text or result is discarded.
        renderer.render([user("整理最近的录音"), assistant(blocks)], dark: true, sessionID: UUID())
        try await renderer.wait("document.querySelectorAll('.process-group').length === 1 && !document.querySelector('.process-disclosure').open")
        try await renderer.check("document.querySelector('.tool-excerpt').textContent === '周五下午三点开会。'")
    }

    func testStoppedFailedAndTruncatedRepliesFoldWithoutHidingTheirOutcome() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        for state in [AgentMessageState.stopped, .failed, .truncated] {
            let sessionID = UUID()
            let steps: [AgentMessageBlock] = [
                .init(id: "thought", content: .reasoning("读取录音资料。", redacted: false)),
                tool("failed", name: "read_transcript", state: .failed, output: "资料暂不可用。")]
            renderer.render([user("读取录音"), assistant(steps, state: .streaming)], busy: true, sessionID: sessionID)
            try await renderer.wait("document.querySelector('.process-disclosure')?.open === true")
            _ = try await renderer.web.evaluateJavaScript("document.querySelector('.tool-card > summary').click(); true")
            renderer.render([user("读取录音"), assistant(steps, state: state)], busy: true, sessionID: sessionID)
            try await renderer.wait("!document.querySelector('.process-disclosure').open")
            try await renderer.check("document.querySelector('.process-label').textContent.includes('1 项失败') && !document.querySelector('.tool-card').open")
        }
        await renderer.attach(to: self, name: "process-failure-stays-visible-in-summary")
    }

    func testAutomaticProcessCollapseKeepsTheVisibleAnswerAtTheSamePosition() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let thought = AgentMessageBlock(id: "thought", content: .reasoning(String(repeating: "核对录音的时间和上下文。\n", count: 60), redacted: false))
        renderer.render([user("长内容"), assistant([thought], state: .streaming)], busy: true)
        try await renderer.wait("document.querySelector('.process')?.open === true")
        // Mark this as the reader's open choice before prose begins streaming.
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('.process > summary').click(); document.querySelector('.process > summary').click(); true")
        let blocks = [thought, AgentMessageBlock(id: "body", content: .text((1...40).map { "第\($0)段：这是录音整理的具体内容。" }.joined(separator: "\n\n")))]
        renderer.render([user("长内容"), assistant(blocks, state: .streaming)], busy: true)
        try await renderer.wait("document.querySelectorAll('.md-chunk').length > 20")
        _ = try await renderer.web.evaluateJavaScript("window.readingChunk = document.querySelectorAll('.md-chunk')[8]; window.scrollTo(0, scrollY + window.readingChunk.getBoundingClientRect().top - 60); true")
        try await renderer.wait("Math.abs(window.readingChunk.getBoundingClientRect().top - 60) < 2 && !document.querySelector('#jump').hidden")
        renderer.render([user("长内容"), assistant(blocks)])
        try await renderer.wait("!document.querySelector('.process-disclosure').open && Math.abs(window.readingChunk.getBoundingClientRect().top - 60) < 2")
        try await renderer.check("!document.querySelector('#jump').hidden && document.querySelectorAll('.md-chunk')[8] === window.readingChunk")
    }

    func testColdRendererPaintsTheUserMessageBeforeWebKitCanCallBack() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 500)
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .white
        window.rootViewController = UIHostingController(rootView: ChatRendererView(snapshot: .init(
            sessionID: nil, messages: [user("这句应立即出现，不等网页或模型。")], busy: true)))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.rootViewController?.view.layoutIfNeeded()
        // This synchronous capture cannot yield to WebKit's asynchronous ready/render callbacks.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        // Exclude the system status/home bars; only glyphs in the message area count.
        let crop = CGRect(x: 60 * image.scale, y: 70 * image.scale, width: 320 * image.scale, height: 110 * image.scale)
        let pixels = try XCTUnwrap(image.cgImage?.cropping(to: crop))
        var rgba = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        let count = try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            return stride(from: 0, to: buffer.count, by: 4).filter {
                buffer[$0] < 140 && buffer[$0 + 1] < 140 && buffer[$0 + 2] < 140 && buffer[$0 + 3] > 200
            }.count
        }
        XCTAssertGreaterThan(count, 100, "The first native frame must contain the user's text.")
        let attachment = XCTAttachment(image: image); attachment.name = "first-send-before-webkit-ready"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDarkFirstSendHasNoLightCanvasDuringNativeToWebHandoff() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 500)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = UIColor(white: 22 / 255.0, alpha: 1)
        let host = UIHostingController(rootView: ChatRendererView(snapshot: .init(
            sessionID: UUID(), messages: [user("发送后这条消息一直可见。")], busy: true))
            .environment(\.colorScheme, .dark)
            .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        var paintedWeb = false
        var paintedFrames = 0
        var maximumLightFraction = 0.0
        for _ in 0..<200 {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let pixels = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                x: 10 * image.scale, y: 70 * image.scale, width: 373 * image.scale, height: 340 * image.scale)))
            var bytes = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
            let light = try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height,
                    bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
                return stride(from: 0, to: buffer.count, by: 4).filter {
                    buffer[$0] > 220 && buffer[$0 + 1] > 220 && buffer[$0 + 2] > 220
                }.count
            }
            maximumLightFraction = max(maximumLightFraction, Double(light) / Double(pixels.width * pixels.height))
            if let web = findWeb(host.view),
               (try? await web.evaluateJavaScript("document.querySelector('.user-bubble')?.textContent === '发送后这条消息一直可见。' && getComputedStyle(document.documentElement).backgroundColor === 'rgb(22, 22, 22)'")) as? Bool == true {
                paintedWeb = true
                paintedFrames += 1
                if paintedFrames >= 4 { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(paintedWeb, "The test must cross into the real rendered WebKit document.")
        XCTAssertLessThan(maximumLightFraction, 0.12, "A dark first send must never expose a light document canvas.")
        let attachment = XCTAttachment(string: "maximum light fraction across first-send frames: \(maximumLightFraction)")
        attachment.name = "dark-first-send-frames"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testThinkingEndsWithTheVisibleReplyBeforeSubmissionBookkeepingFinishes() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("你好")], busy: true, reduceMotion: false)
        try await renderer.wait("document.querySelector('.user-bubble')?.textContent === '你好' && !document.querySelector('#working').hidden")
        renderer.render([user("你好"), assistant([.init(id: "reply", content: .text("已经回答。"))])], busy: true, reduceMotion: false)
        try await renderer.wait("document.querySelector('.prose')?.textContent.includes('已经回答。') === true && document.querySelector('#working').hidden")
        renderer.render([user("你好"), assistant([.init(id: "thought", content: .reasoning("核对已有资料。", redacted: false))], state: .streaming)], busy: true, reduceMotion: false)
        try await renderer.wait("document.querySelector('.process-group')?.dataset.state === 'running' && document.querySelector('#working').hidden")
        renderer.render([user("你好"), assistant([.init(id: "thought", content: .reasoning("核对已有资料。", redacted: false)),
            .init(id: "reply", content: .text("已经开始回答"))], state: .streaming)], busy: true, reduceMotion: false)
        try await renderer.wait("document.querySelector('.process-group')?.dataset.state === 'settled' && document.querySelector('#working').hidden")
        renderer.render([user("你好"), assistant([.init(id: "thought", content: .reasoning("核对已有资料。", redacted: false)),
            .init(id: "reply", content: .text("回答完成。"))])], busy: true, reduceMotion: false)
        try await renderer.wait("document.querySelector('.process-group')?.dataset.state === 'settled' && document.querySelector('#working').hidden")
    }

    func testHomeAvatarHasAVisibleViewportAndDrawsItsOriginalShape() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        let host = UIHostingController(rootView: PersonalAgentSlot(size: 84, active: false)
            .frame(width: 240, height: 240).environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.rootView = PersonalAgentSlot(size: 84, active: true)
            .frame(width: 240, height: 240).environment(\.scenePhase, .active)
        host.view.layoutIfNeeded()
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        var surface: WKWebView?
        for _ in 0..<100 {
            surface = findWeb(host.view)
            if let web = surface,
               (try? await web.evaluateJavaScript("Boolean(window.agentAvatar)")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let web = try XCTUnwrap(surface)
        let placement = web.convert(web.bounds, to: window)
        XCTAssertEqual(placement.midX, 120, accuracy: 2, "The first visible frame must already occupy its slot.")
        XCTAssertEqual(placement.midY, host.view.safeAreaLayoutGuide.layoutFrame.midY, accuracy: 3)
        XCTAssertEqual(web.scrollView.adjustedContentInset, .zero, "Safe-area insets must not introduce a strip inside the Avatar.")
        try await Task.sleep(for: .milliseconds(500))
        let data = try await web.evaluateJavaScript("JSON.stringify({ready:Boolean(window.agentAvatar),paths:document.querySelectorAll('svg path').length,width:innerWidth,height:innerHeight})")
        let diagnostic = XCTAttachment(string: "\(String(describing: data)); viewport=\(web.convert(web.bounds, to: window))")
        diagnostic.lifetime = .keepAlways; add(diagnostic)
        let drawsShape = try await web.evaluateJavaScript("Boolean(window.agentAvatar) && document.querySelectorAll('svg path').length > 2")
        XCTAssertTrue(drawsShape as? Bool == true)
        XCTAssertGreaterThan(web.convert(web.bounds, to: window).width, 100)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pixels = try XCTUnwrap(image.cgImage)
        var rgba = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        let darkPixels = try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            return stride(from: 0, to: buffer.count, by: 4).filter {
                buffer[$0] < 100 && buffer[$0 + 1] < 100 && buffer[$0 + 2] < 100 && buffer[$0 + 3] > 200
            }.count
        }
        XCTAssertGreaterThan(darkPixels, 500, "The Avatar must paint a visible shape, not just create an empty WebView.")
        let screenshot = XCTAttachment(image: image); screenshot.name = "native-home-avatar"
        screenshot.lifetime = .keepAlways; add(screenshot)
        var eyeCenters: [Double] = [], headCenters: [Double] = []
        for index in 0..<55 {
            let metrics = try await web.evaluateJavaScript("""
                (() => { const eyes=document.querySelector('.avatar-eyes').getBoundingClientRect();
                  const head=document.querySelector('.avatar-head').getBoundingClientRect();
                  const motion=document.querySelector('.avatar-eyes').parentElement;
                  return {eye:eyes.x+eyes.width/2,head:head.x+head.width/2,offset:motion.getAttribute('transform')}; })()
                """) as? [String: Any]
            let sample = try XCTUnwrap(metrics)
            eyeCenters.append(try XCTUnwrap(sample["eye"] as? Double))
            headCenters.append(try XCTUnwrap(sample["head"] as? Double))
            XCTAssertEqual(sample["offset"] as? String, "translate(0 0)")
            XCTAssertEqual(web.convert(web.bounds, to: window), placement, "The live viewport must not jitter as the head turns.")
            if [0,13,26,39].contains(index) {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let frame = XCTAttachment(image: image); frame.name = "header-turn-\(index)"
                frame.lifetime = .keepAlways; add(frame)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let travel = try XCTUnwrap(eyeCenters.max()) - XCTUnwrap(eyeCenters.min())
        let drift = try XCTUnwrap(headCenters.max()) - XCTUnwrap(headCenters.min())
        XCTAssertGreaterThan(travel, 6, "At the actual 84-point header size, the eye travel must make the 3D turn visible.")
        XCTAssertLessThan(drift, 0.5, "The head must rotate around a fixed center rather than shake sideways.")
        let motion = XCTAttachment(string: "Header eye travel: \(travel)pt; head-center drift: \(drift)pt")
        motion.name = "header-turn-measurements"; motion.lifetime = .keepAlways; add(motion)
        host.rootView = PersonalAgentSlot(size: 84, active: false)
            .frame(width: 240, height: 240).environment(\.scenePhase, .active)
        try await Task.sleep(for: .milliseconds(300))
        let stoppedShape = try await web.evaluateJavaScript("document.querySelector('svg').outerHTML") as? String
        try await Task.sleep(for: .milliseconds(200))
        let stillStopped = try await web.evaluateJavaScript("document.querySelector('svg').outerHTML") as? String
        XCTAssertEqual(stoppedShape, stillStopped, "Inactive pages must stop idle animation.")
    }

    func testAllMoMoExpressionsCrossTheNativeBridgeWithoutRecreatingTheActor() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        func content(_ expression: PersonalAgentExpression, dark: Bool = false) -> some View {
            PersonalAgentActor(size: 84, active: false, greeting: 0, expression: expression)
                .frame(width: 240, height: 240).environment(\.colorScheme, dark ? .dark : .light)
        }
        let host = UIHostingController(rootView: content(.present))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        let web = try XCTUnwrap(findWeb(host.view))
        var shapes = Set<String>()
        for expression in PersonalAgentExpression.allCases {
            host.rootView = content(expression)
            host.view.layoutIfNeeded()
            var applied = false
            for _ in 0..<100 {
                applied = (try? await web.evaluateJavaScript("document.querySelector('#agent').dataset.avatarExpression")) as? String == expression.rawValue
                if applied { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(applied, "Native appearance must deliver \(expression.rawValue) to the existing actor.")
            XCTAssertTrue(findWeb(host.view) === web)
            let shape = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.avatar-eyes path'), eye => eye.getAttribute('d')).join('|')")
            shapes.insert(try XCTUnwrap(shape as? String))
            let stopped = try await web.evaluateJavaScript("document.querySelector('#agent').dataset.avatarActive === 'false'")
            XCTAssertEqual(stopped as? Bool, true)
        }
        XCTAssertEqual(shapes.count, 8)
        host.rootView = content(.settled, dark: true)
        host.view.layoutIfNeeded()
        var darkEyes = ""
        for _ in 0..<100 {
            darkEyes = (try? await web.evaluateJavaScript("getComputedStyle(document.querySelector('.avatar-eyes path')).fill")) as? String ?? ""
            if darkEyes == "rgb(23, 23, 23)" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(darkEyes, "rgb(23, 23, 23)")
    }

    func testGreetingMovesVectorGeometryInsideAStationaryTransparentWebView() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 300)
        window.overrideUserInterfaceStyle = .dark
        let canvas = Color(white: 22 / 255.0)
        func content(_ greeting: Int, active: Bool = true) -> some View {
            PersonalAgentActor(size: 84, active: active, greeting: greeting)
                .frame(width: 240, height: 300).background(canvas)
                .environment(\.colorScheme, .dark).environment(\.scenePhase, .active)
        }
        let host = UIHostingController(rootView: content(0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        let web = try XCTUnwrap(findWeb(host.view))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("Boolean(window.agentAvatar && document.querySelector('.avatar-greeting'))")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let resting = web.convert(web.bounds, to: window)
        XCTAssertEqual(resting.width, 126, accuracy: 1)
        XCTAssertFalse(web.isOpaque)
        let headWidth = try await web.evaluateJavaScript("document.querySelector('.avatar-head').getBoundingClientRect().width")
        XCTAssertGreaterThan(try XCTUnwrap(headWidth as? Double), 47)
        XCTAssertLessThan(try XCTUnwrap(headWidth as? Double), 60, "Viewport padding must preserve the resting Avatar size.")
        host.rootView = content(1)
        host.view.layoutIfNeeded()
        var transforms = Set<String>()
        for index in 0..<24 {
            let value = try await web.evaluateJavaScript("document.querySelector('.avatar-greeting').getAttribute('transform') || ''") as? String ?? ""
            if !value.isEmpty { transforms.insert(value) }
            let frame = web.convert(web.bounds, to: window)
            XCTAssertEqual(frame.minX, resting.minX, accuracy: 0.5)
            XCTAssertEqual(frame.minY, resting.minY, accuracy: 0.5)
            XCTAssertEqual(frame.width, resting.width, accuracy: 0.5)
            let fits = try await web.evaluateJavaScript("""
                (() => { const svg=document.querySelector('svg'), layer=document.querySelector('.avatar-greeting');
                  const a=svg.getBoundingClientRect(), b=layer.getBoundingClientRect();
                  return b.top>=a.top && b.bottom<=a.bottom && b.left>=a.left && b.right<=a.right
                    && getComputedStyle(layer).filter==='none' && getComputedStyle(document.body).backgroundColor==='rgba(0, 0, 0, 0)'; })()
                """)
            XCTAssertTrue(fits as? Bool == true, "The greeting must stay sharp, transparent and inside its padded viewport.")
            if index == 6 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image); attachment.name = "dark-vector-greeting"
                attachment.lifetime = .keepAlways; add(attachment)
                host.rootView = content(2) // A repeated tap interrupts the same vector layer.
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(transforms.count, 5)
        let deadline = ContinuousClock.now + .seconds(2)
        var moving = true
        while moving, ContinuousClock.now < deadline {
            moving = (try await web.evaluateJavaScript("document.querySelector('.avatar-greeting').hasAttribute('transform')")) as? Bool == true
            if moving { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertFalse(moving, "A repeated greeting must finish and release its animation loop.")
        host.rootView = content(3)
        for _ in 0..<40 {
            if (try await web.evaluateJavaScript("appearance.greeting === 3")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Exercise the renderer's real reduced-motion payload without changing system settings.
        _ = try await web.callAsyncJavaScript("window.agentAvatar.update(value)", arguments: ["value":
            ["dark": true, "active": true, "reduceMotion": true, "greeting": 4]], in: nil, in: .page)
        let reduced = try await web.evaluateJavaScript("document.querySelector('.avatar-greeting').hasAttribute('transform')")
        XCTAssertEqual(reduced as? Bool, false)
        host.rootView = content(5, active: false)
        try await Task.sleep(for: .milliseconds(100))
        let inactive = try await web.evaluateJavaScript("document.querySelector('.avatar-greeting').hasAttribute('transform') || document.querySelector('#agent').dataset.avatarActive !== 'false'")
        XCTAssertEqual(inactive as? Bool, false)
    }

    func testColoredActionCardsKeepTimeTitleAndStateDistinctInBothThemes() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        func receipt(_ kind: String, _ title: String, _ extra: String) -> String {
            """
            {"actionID":"\(UUID().uuidString)","state":"succeeded","resource":{"kind":"\(kind)","fields":{"title":"\(title)"\(extra)}}}
            """
        }
        let messages = [user("安排一下今天的事情"), assistant([
            tool("alarm-card", name: "schedule_alarm", state: .succeeded, output: receipt("alarm", "慢慢醒来", ",\"weeklySchedule\":{\"hour\":7,\"minute\":30,\"weekdays\":[1,2,3,4,5]}")),
            tool("todo-card", name: "create_reminder", state: .succeeded, output: receipt("reminder", "下班记得买牛奶和面包", "")),
            tool("event-card", name: "create_calendar_event", state: .succeeded, output: receipt("event", "和团队碰一下设计", ",\"start\":\"2026-10-21T07:00:00Z\",\"timezone\":\"Asia/Shanghai\""))])]
        for dark in [false, true] {
            renderer.render(messages, dark: dark)
            try await renderer.wait("document.querySelectorAll('.system-action-card').length === 3 && document.documentElement.dataset.dark === '\(dark)'")
            try await renderer.check("document.querySelector('[data-kind=alarm] .action-card-time').textContent === '07:30'")
            try await renderer.check("document.querySelector('[data-kind=reminder] .action-card-detail').textContent === '未设截止日期' && document.querySelector('[data-kind=reminder] .action-card-status').textContent === '已添加'")
            try await renderer.check("document.querySelector('[data-kind=event] .action-card-when').textContent === '15:00' && !document.querySelector('.action-results').textContent.includes('T07:00')")
            try await renderer.check("new Set([...document.querySelectorAll('.system-action-card')].map(n => getComputedStyle(n).backgroundColor)).size === 3 && [...document.querySelectorAll('.action-card-open')].every(n => n.getBoundingClientRect().height >= 44 && n.scrollWidth <= n.clientWidth)")
            await renderer.attach(to: self, name: dark ? "action-cards-dark" : "action-cards-light")
        }
    }

    func testSystemReceiptCardStaysVisibleAndOpensOnlyItsSavedAction() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let action = UUID()
        func result(_ state: String) -> String {
            """
            {"actionID":"\(action.uuidString)","state":"\(state)","resource":{"fields":{"title":"工作日提醒","weeklySchedule":{"hour":9,"minute":30,"weekdays":[1,3,5],"timezonePolicy":"device"}}}}
            """
        }
        renderer.render([user("每周一三五九点半提醒我"), assistant([
            tool("alarm", name: "schedule_alarm", state: .succeeded, output: result("outcome_unknown"))])])
        try await renderer.wait("document.querySelector('.system-action-card')?.textContent.includes('结果待核对') === true")
        try await renderer.check("document.querySelector('.system-action-card').closest('details') === null")
        try await renderer.check("!document.querySelector('.process-disclosure').open && document.querySelector('.process-label').textContent.includes('结果待核对') && document.querySelector('.system-action-card').getBoundingClientRect().height > 44")
        try await renderer.check("document.querySelector('.step-label').textContent.includes('结果待核对') && document.querySelectorAll('.process').length === 0")
        renderer.render([user("每周一三五九点半提醒我"), assistant([
            tool("alarm", name: "schedule_alarm", state: .succeeded, output: result("succeeded"))])])
        try await renderer.wait("document.querySelector('.system-action-card')?.textContent.includes('已设定') === true")
        try await renderer.check("document.querySelectorAll('.system-action-card').length === 1 && document.querySelector('.action-card-time').textContent === '09:30' && document.querySelector('.action-card-detail').textContent.includes('周一、周三、周五')")
        await renderer.attach(to: self, name: "system-action-receipt-card")
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('.system-action-card button').click(); true")
        for _ in 0..<100 {
            if renderer.openedAction != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(renderer.openedAction, action)
    }

    func testReadingPositionRestoresOnlyItsSessionAcrossRendererRecreation() async throws {
        let first = UUID(), second = UUID()
        let body = (1...80).map { "第\($0)段：这是已保存的长会话内容。" }.joined(separator: "\n\n")
        let messages = [user("原问题"), assistant([.init(id: "body", content: .text(body))])]
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        try await renderer.recordScrollEvents()
        renderer.render(messages, sessionID: first)
        try await renderer.wait("scrollY > 800")
        let beforeReading = renderer.readingSequence
        _ = try await renderer.web.evaluateJavaScript("window.scrollTo(0,500); true")
        try await renderer.wait("Math.abs(scrollY - 500) < 2 && !document.querySelector('#jump').hidden")
        let saved = try await renderer.waitForReadingPosition(first, following: false, after: beforeReading, top: 500)
        XCTAssertEqual(saved.top, 500, accuracy: 2)
        XCTAssertEqual(saved.anchorID, "assistant:reply")
        let beforeSecondSession = renderer.readingSequence
        renderer.render([user("另一个会话")], sessionID: second, readingPosition: saved)
        try await renderer.wait("document.querySelector('.user-bubble').textContent === '另一个会话' && scrollY === 0")
        _ = try await renderer.waitForReadingPosition(second, following: true, after: beforeSecondSession, top: 0)
        let beforeReturning = renderer.readingSequence
        renderer.render(messages, sessionID: first, readingPosition: saved)
        try await renderer.wait("Math.abs(scrollY - 500) < 2 && !document.querySelector('#jump').hidden")
        _ = try await renderer.waitForReadingPosition(first, following: false, after: beforeReturning, top: 500)
        try await renderer.attachScrollEvents(to: self)
        renderer.close()

        let reopened = try RendererHarness()
        defer { reopened.close() }
        try await reopened.ready()
        try await reopened.recordScrollEvents()
        let beforeRecreation = reopened.readingSequence
        reopened.render(messages, busy: true, sessionID: first, readingPosition: saved)
        try await reopened.wait("Math.abs(scrollY - 500) < 2 && !document.querySelector('#jump').hidden")
        _ = try await reopened.waitForReadingPosition(first, following: false, after: beforeRecreation, top: 500)
        let longer = body + "\n\n请求完成后追加的结尾。"
        reopened.render([user("原问题"), assistant([.init(id: "body", content: .text(longer))])], sessionID: first)
        try await reopened.wait("document.querySelector('.prose').textContent.includes('请求完成后追加的结尾')")
        try await reopened.check("Math.abs(scrollY - 500) < 2 && !document.querySelector('#jump').hidden")
        let bottomValue = try await reopened.web.evaluateJavaScript("Math.max(0,document.documentElement.scrollHeight - innerHeight)")
        let bottom = try XCTUnwrap(bottomValue as? Double)
        let beforeJump = reopened.readingSequence
        _ = try await reopened.web.evaluateJavaScript("document.querySelector('#jump').click(); true")
        try await reopened.wait("scrollY > 800 && document.querySelector('#jump').hidden")
        let following = try await reopened.waitForReadingPosition(first, following: true, after: beforeJump, top: bottom)
        XCTAssertGreaterThan(following.top, saved.top)
        try await reopened.attachScrollEvents(to: self)
    }

    func testReadingPositionBridgeRejectsWrongSessionAndInvalidCoordinates() {
        var positions: [ChatReadingPosition] = []
        let id = UUID()
        let coordinator = ChatWebCoordinator(failed: {}, open: { _ in }, readingPosition: { positions.append($0) })
        coordinator.update(.init(snapshot: .init(sessionID: id, messages: [user("问题")], busy: false),
                                 appearance: .init(dark: false, reduceMotion: true, scale: 1)))
        var value: [String: Any] = ["sessionID": UUID().uuidString, "following": false,
                                   "top": 20.0, "anchorID": "user", "anchorOffset": -20.0]
        coordinator.receiveReadingPosition(value)
        value["sessionID"] = id.uuidString; value["top"] = Double.nan
        coordinator.receiveReadingPosition(value)
        value["top"] = 20.0; value["anchorID"] = "another-session-message"
        coordinator.receiveReadingPosition(value)
        XCTAssertTrue(positions.isEmpty)
        value["anchorID"] = "user"
        coordinator.receiveReadingPosition(value)
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions.first?.sessionID, id)
    }

    func testNavigationDelegateBlocksExternalMainFramesAndAllowsBundledBootstrap() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        let delegate = try XCTUnwrap(renderer.web.navigationDelegate)
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(delegate.responds(to: selector), "The policy must be an Objective-C delegate implementation, not a nearly matching Swift method.")
        guard delegate.responds(to: selector) else {
            throw NSError(domain: "ChatRendererNavigation", code: 1)
        }
        try await renderer.ready()
        let bootstrap = try XCTUnwrap(renderer.web.url)
        XCTAssertTrue(bootstrap.isFileURL)
        let observer = NavigationPolicyObserver(delegate: delegate)
        renderer.web.navigationDelegate = observer
        _ = try await renderer.web.evaluateJavaScript("window.navigationSentinel = 'original-bundled-document'; true")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-navigation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside.html")
        try "<!doctype html><title>External document must never load</title>".write(to: outside, atomically: true, encoding: .utf8)
        let targets = [try XCTUnwrap(URL(string: "http://renderer-navigation.invalid/blocked")),
                       try XCTUnwrap(URL(string: "https://renderer-navigation.invalid/blocked")), outside]
        for target in targets {
            let before = observer.decisions.count
            if target.isFileURL {
                // Grant read access so a sandbox rejection cannot masquerade as policy enforcement.
                renderer.web.loadFileURL(target, allowingReadAccessTo: directory)
            } else {
                renderer.web.load(URLRequest(url: target))
            }
            let decision = try await observer.waitForDecision(after: before)
            XCTAssertEqual(decision.url, target)
            XCTAssertTrue(decision.mainFrame)
            XCTAssertEqual(decision.policy, .cancel)
            try await renderer.wait("!document.hidden && window.navigationSentinel === 'original-bundled-document' && typeof window.MoMoChat === 'object'")
            XCTAssertEqual(renderer.web.url, bootstrap)
            XCTAssertNil(renderer.opened, "Programmatic navigation must not be forwarded as a user source-link action.")
        }

        let beforeReload = observer.decisions.count
        renderer.web.loadFileURL(bootstrap, allowingReadAccessTo: bootstrap.deletingLastPathComponent())
        let reload = try await observer.waitForDecision(after: beforeReload)
        XCTAssertEqual(reload.url, bootstrap)
        XCTAssertTrue(reload.mainFrame)
        XCTAssertEqual(reload.policy, .allow)
        try await renderer.wait("window.navigationSentinel === undefined && typeof window.MoMoChat === 'object'")
        XCTAssertEqual(renderer.web.url, bootstrap)
        let attachment = XCTAttachment(string: observer.decisions.map {
            "mainFrame=\($0.mainFrame) policy=\($0.policy.rawValue) url=\($0.url?.absoluteString ?? "nil")"
        }.joined(separator: "\n"))
        attachment.name = "renderer-navigation-policy"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOfflineMarkdownToolsAndSourceLinkBridge() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let source = "momoagent://source/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002?version=1&generation=0"
        let markdown = """
        ## 整理好了

        先确认 **参观时间**，再安排行程。[录音1](\(source))

        | 事项 | 状态 |
        | --- | --- |
        | 开放时间与供餐时间需要分别确认，不能合并为一个已确认事实 | 待确认 |

        ```swift
        let text = "<script>window.injected = true</script>"
        ```

        $$
        E = mc^2
        $$

        <script>window.injected = true</script>
        [bad](javascript:alert(1))
        ![model image](https://example.invalid/model-image.png)
        <img src="brand-thinking.png" onload="window.injected = true">
        """
        renderer.render([user("## **原样输入**"),assistant([
            tool("read",name:"read_transcript",state:.succeeded,output:"原文：供餐时间为12点。"),
            tool("failed",name:"search_transcripts",state:.failed,output:"资料暂不可用。"),
            .init(id:"body",content:.text(markdown))
        ])])
        try await renderer.wait("document.querySelectorAll('table').length === 1 && document.querySelectorAll('.katex').length === 1")
        try await renderer.check("getComputedStyle(document.querySelector('.prose')).fontSize === '16px' && getComputedStyle(document.querySelector('.prose')).fontWeight === '400' && getComputedStyle(document.querySelector('.prose')).lineHeight === '20px' && getComputedStyle(document.querySelector('.prose strong')).fontWeight === '600'")
        try await renderer.check("document.querySelectorAll('.process').length === 0 && document.querySelectorAll('.tool-card').length === 2")
        try await renderer.check("document.querySelector('.badge.failed').textContent === '失败'")
        try await renderer.check("document.querySelector('.user-bubble').textContent === '## **原样输入**'")
        try await renderer.check("[...document.querySelectorAll('.actions button svg')].every(icon => icon.getBoundingClientRect().width === 16 && icon.getBoundingClientRect().height === 16) && [...document.querySelectorAll('.actions button')].every(button => button.getBoundingClientRect().width >= 44 && button.getBoundingClientRect().height >= 44)")
        try await renderer.check("window.injected === undefined && !document.querySelector('.prose script, .prose img')")
        try await renderer.check("document.querySelector('pre code .hljs-keyword') !== null")
        try await renderer.check("[...document.querySelectorAll('a')].every(a => !a.getAttribute('href')?.startsWith('javascript:'))")
        try await renderer.check("performance.getEntriesByType('resource').every(r => r.name.startsWith('file:'))")
        try await renderer.check("!document.querySelector('.process-disclosure').open && document.querySelector('.process-label').textContent.includes('1 项失败')")
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('.process-disclosure > summary').click(); document.querySelector('.step > summary').click(); true")
        try await renderer.check("document.querySelector('.step').open && !document.querySelector('.step').closest('.reasoning-step')")
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('a[href^=\"momoagent:\"]').click(); true")
        try await renderer.waitForLink()
        XCTAssertEqual(renderer.opened?.absoluteString,source)
        let preview = """
        ## 周五的安排

        我把讨论中的安排整理好了。负责人还没定，先留空。[录音1](\(source))

        | 事项 | 当前安排 |
        | --- | --- |
        | 讨论时间 | 周五 15:00 |
        | 负责人 | 待确认 |

        > 还需要你决定：由谁来召集这次讨论。

        你想先确认负责人，还是先准备讨论材料？
        """
        let previewMessages = [user("刚才讨论定了什么，还有什么没定？"),assistant([
            tool("read",name:"read_transcript",state:.succeeded,output:"周五下午三点讨论，负责人还没有定。"),
            tool("read-more",name:"read_transcript",state:.succeeded,output:"正文已读完。"),
            .init(id:"body",content:.text(preview))
        ])]
        renderer.render(previewMessages)
        try await renderer.wait("document.querySelector('.prose').textContent.includes('周五的安排')")
        _ = try await renderer.web.evaluateJavaScript("document.querySelectorAll('details').forEach(node => node.open = false); window.scrollTo(0,0); true")
        await renderer.attach(to:self,name:"claude-aligned-rendering-light")
        renderer.render(previewMessages,dark:true)
        try await renderer.wait("getComputedStyle(document.documentElement).backgroundColor === 'rgb(22, 22, 22)' && getComputedStyle(document.querySelector('.prose')).fontSize === '16px'")
        await renderer.attach(to:self,name:"claude-aligned-rendering-dark")
    }

    func testBareRecordingCitationsAreCompactClickableAndStableAfterHistoryRefresh() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let source = "momoagent://source/d64b7800-be32-49ed-b6f1-7530ebf8c1be/6b1b8ca7-8855-3eb4-756b-05400adf5599?version=78&generation=0"
        let text = "14:24—14:40 的讨论。来源：\(source)。\n\n[讨论原文](\(source))\n\n<\(source)>"
        let messages = [user("回顾刚才的讨论"), assistant([.init(id: "body", content: .text(text))])]
        renderer.render(messages)
        try await renderer.wait("document.querySelectorAll('a.recording-source').length === 3")
        try await renderer.check("[...document.querySelectorAll('a.recording-source')].map(a=>a.textContent).join('|') === '查看录音|讨论原文|查看录音'")
        _ = try await renderer.web.evaluateJavaScript("window.sourceNode = document.querySelector('a.recording-source'); window.sourceBubble = document.querySelector('.prose'); sourceNode.click(); true")
        try await renderer.waitForLink()
        XCTAssertEqual(renderer.opened?.absoluteString, source)
        XCTAssertEqual(RecordingSourceURL.source(for: try XCTUnwrap(renderer.opened))?.transcriptVersion, 78)
        renderer.render(messages)
        try await renderer.check("sourceNode === document.querySelector('a.recording-source') && sourceBubble === document.querySelector('.prose')")
        await renderer.attach(to: self, name: "recording-source-links-light")
        renderer.render(messages, dark: true)
        try await renderer.wait("getComputedStyle(document.documentElement).backgroundColor === 'rgb(22, 22, 22)'")
        await renderer.attach(to: self, name: "recording-source-links-dark")
    }

    func testStreamingKeepsStableDOMAndFinishesWithoutDuplicateText() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("整理一下")],busy:true)
        try await renderer.wait("document.querySelector('.user-bubble') !== null")
        renderer.render([user("整理一下"),assistant([.init(id:"body",content:.text("第一段已完成。\n\n第二段正在"))],state:.streaming)],busy:true,reduceMotion:false)
        try await renderer.wait("document.querySelectorAll('.md-chunk').length >= 2")
        _ = try await renderer.web.evaluateJavaScript("window.stableChunk = document.querySelector('.md-chunk'); true")
        let body = "第一段已完成。\n\n第二段正在补充中文、👨‍👩‍👧‍👦和 e\u{301}，保留所有字符。\n\n- 核对时间\n- 确认地点"
        renderer.render([user("整理一下"),assistant([.init(id:"body",content:.text(body))],state:.streaming)],busy:true,reduceMotion:false)
        try await renderer.wait("document.querySelector('.prose').textContent.includes('保留所有字符')")
        try await renderer.check("window.stableChunk === document.querySelector('.md-chunk')")
        renderer.render([user("整理一下"),assistant([.init(id:"body",content:.text(body))])])
        try await renderer.wait("!document.querySelector('.actions').hidden")
        try await renderer.check("document.querySelectorAll('.turn.assistant').length === 1 && document.querySelectorAll('li').length === 2")
        try await renderer.check("document.querySelector('.prose').textContent.split('第一段已完成。').length === 2")
        try await renderer.check("window.stableChunk === document.querySelector('.md-chunk')")
        try await renderer.check("document.querySelector('#announcer').textContent === '回复已完成'")
        try await renderer.check("!document.querySelector('[data-action=copy-reply]') && !document.querySelector('[data-action=copy-code]')")
        try await renderer.check("getComputedStyle(document.querySelector('.user-bubble')).backgroundColor !== getComputedStyle(document.querySelector('.assistant .prose')).backgroundColor")
        try await renderer.check("getComputedStyle(document.querySelector('.prose')).fontFamily.includes('system') && getComputedStyle(document.querySelector('.prose')).fontSize === '16px' && getComputedStyle(document.querySelector('.prose')).lineHeight === '20px'")
        await renderer.attach(to:self,name:"streaming-completed-with-stable-blocks")
    }

    func testReadingAnchorRestoresBelowCustomHeader() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let session = UUID()
        let position = ChatReadingPosition(sessionID: session, following: false, top: 0,
                                           anchorID: "assistant:reply", anchorOffset: 0)
        let body = String(repeating: "一段用于滚动的长回复。\n\n", count: 80)
        renderer.render([user("第一条消息"), assistant([.init(id: "body", content: .text(body))])],
                        sessionID: session, readingPosition: position, headerInset: 120)
        try await renderer.wait("Math.abs(document.querySelector('.turn.assistant').getBoundingClientRect().top - 120) < 2")
        _ = try await renderer.web.evaluateJavaScript("window.scrollTo(0, 0); true")
        try await renderer.wait("scrollY === 0 && document.querySelector('.turn.user').getBoundingClientRect().top >= 120")
    }

    func testScrollUpDoesNotGetPulledDownAndJumpRestoresFollowing() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        try await renderer.recordScrollEvents()
        let body = (1...60).map { "第\($0)段：这是已收到的录音整理内容。" }.joined(separator:"\n\n")
        renderer.render([user("长内容"),assistant([.init(id:"body",content:.text(body))])])
        try await renderer.wait("window.scrollY > 500")
        _ = try await renderer.web.evaluateJavaScript("window.scrollTo(0,0); true")
        try await renderer.wait("!document.querySelector('#jump').hidden")
        renderer.render([user("长内容"),assistant([.init(id:"body",content:.text(body + "\n\n新增内容。"))],state:.streaming)],busy:true)
        try await renderer.wait("document.querySelector('.prose').textContent.includes('新增内容')")
        try await renderer.check("window.scrollY < 10")
        _ = try await renderer.web.evaluateJavaScript("document.querySelector('#jump').click(); true")
        try await renderer.wait("document.querySelector('#jump').hidden && window.scrollY > 500")
        // Replay the actual 0 -> bottom native offset sequence seen after a jump.
        // Both moves go through WKWebView scrolling and the document's real scroll
        // handlers, without changing PinState or dispatching a fabricated scroll event.
        for _ in 0..<2 {
            _ = try await renderer.web.evaluateJavaScript("window.scrollTo({ top:0, behavior:'auto' }); true")
            try await renderer.wait("scrollY < 2 && !document.querySelector('#jump').hidden")
            _ = try await renderer.web.evaluateJavaScript("window.scrollTo({ top:Math.max(0,document.documentElement.scrollHeight - innerHeight), behavior:'auto' }); true")
            try await renderer.wait("document.querySelector('#jump').hidden && scrollY > 500 && Math.abs(document.documentElement.scrollHeight - innerHeight - scrollY) < 2")
        }
        renderer.render([user("长内容"),assistant([.init(id:"body",content:.text(body + "\n\n新增内容。\n\n回到底部后继续接收。"))],state:.streaming)],busy:true)
        try await renderer.wait("document.querySelector('.prose').textContent.includes('回到底部后继续接收') && document.querySelector('#jump').hidden && document.documentElement.scrollHeight - innerHeight - scrollY < 80")
        renderer.render([user("长内容"),assistant([.init(id:"body",content:.text(body + "\n\n新增内容。\n\n回到底部后继续接收。"))],state:.stopped)],stopped:true)
        try await renderer.wait("document.querySelector('.end-status').textContent === ''")
        try await renderer.check("document.querySelector('#announcer').textContent === '已停止回复'")
        try await renderer.attachScrollEvents(to:self)
    }

    func testCancelledTouchDoesNotBlockJumpToLatest() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        try await renderer.recordScrollEvents()
        let sessionID = UUID()
        let body = (1...60).map { "第\($0)段：这是已收到的录音整理内容。" }.joined(separator:"\n\n")
        let beforeRender = renderer.readingSequence
        let renderTimeValue = try await renderer.web.evaluateJavaScript("performance.now()")
        let renderTime = try XCTUnwrap(renderTimeValue as? Double)
        renderer.render([user("取消触摸后继续阅读"),assistant([.init(id:"body",content:.text(body))])],sessionID:sessionID)
        try await renderer.wait("document.querySelector('.prose')?.textContent.includes('第60段') && window.scrollY > 500")
        let bottomValue = try await renderer.web.evaluateJavaScript("Math.max(0,document.documentElement.scrollHeight - innerHeight)")
        let bottom = try XCTUnwrap(bottomValue as? Double)
        // A scrollTo return can precede WK's first native scroll/scrollend. Do not
        // start reading at the top until that initial bottom movement really settled.
        _ = try await renderer.waitForReadingPosition(sessionID, following:true, after:beforeRender, top:bottom,
                                                     nativeScrollAfter:renderTime)
        let beforeReading = renderer.readingSequence
        let readingTimeValue = try await renderer.web.evaluateJavaScript("performance.now()")
        let readingTime = try XCTUnwrap(readingTimeValue as? Double)
        _ = try await renderer.web.evaluateJavaScript("window.scrollTo(0,0); true")
        _ = try await renderer.waitForReadingPosition(sessionID, following:false, after:beforeReading, top:0,
                                                     nativeScrollAfter:readingTime)
        try await renderer.wait("!document.querySelector('#jump').hidden")
        // Exercise the document's real event handlers without touching the test host's UI.
        _ = try await renderer.web.evaluateJavaScript("""
        window.dispatchEvent(new Event('touchstart'));
        window.dispatchEvent(new Event('touchcancel'));
        document.querySelector('#jump').click(); true
        """)
        try await renderer.wait("document.querySelector('#jump').hidden && window.scrollY > 500")
        renderer.render([user("取消触摸后继续阅读"),assistant([.init(id:"body",content:.text(body + "\n\n手势取消后收到的新内容。"))],state:.streaming)],busy:true,sessionID:sessionID)
        try await renderer.wait("document.querySelector('.prose').textContent.includes('手势取消后收到的新内容') && document.querySelector('#jump').hidden && document.documentElement.scrollHeight - innerHeight - scrollY < 80")
        try await renderer.attachScrollEvents(to:self)
    }

    func testStopBeforeFirstTokenAnnouncesOnceWithoutVisibleStatus() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("等待第一字")],busy:true)
        try await renderer.wait("document.querySelector('#announcer').textContent === '助理正在回复'")
        _ = try await renderer.web.evaluateJavaScript("window.stopAnnouncements = 0; new MutationObserver(() => { if(document.querySelector('#announcer').textContent === '已停止回复') window.stopAnnouncements++; }).observe(document.querySelector('#announcer'),{childList:true}); true")
        renderer.render([user("等待第一字")],stopped:true)
        try await renderer.wait("window.stopAnnouncements === 1")
        renderer.render([user("等待第一字")],dark:true,stopped:true)
        try await renderer.wait("document.documentElement.dataset.dark === 'true'")
        try await renderer.check("window.stopAnnouncements === 1 && !document.querySelector('#transcript').textContent.includes('已停止') && document.querySelector('#working').hidden")
    }

    func testRegenerationBridgeRejectsWrongSessionStaleMessageAndBusyState() {
        var calls: [String] = []
        let coordinator = ChatWebCoordinator(failed: {}, open: { _ in }, regenerate: { calls.append($0) })
        let id = UUID(), messages = [user("原问题"), assistant([.init(id:"text",content:.text("原回答"))])]
        func update(busy: Bool) {
            coordinator.update(.init(snapshot:.init(sessionID:id,messages:messages,busy:busy),
                                     appearance:.init(dark:false,reduceMotion:true,scale:1)))
        }
        update(busy:false)
        coordinator.requestRegeneration(["sessionID":UUID().uuidString,"messageID":"assistant"])
        coordinator.requestRegeneration(["sessionID":id.uuidString,"messageID":"unknown"])
        coordinator.requestRegeneration(["sessionID":id.uuidString,"messageID":"user"])
        XCTAssertTrue(calls.isEmpty)
        update(busy:true)
        coordinator.requestRegeneration(["sessionID":id.uuidString,"messageID":"assistant"])
        XCTAssertTrue(calls.isEmpty)
        update(busy:false)
        coordinator.requestRegeneration(["sessionID":id.uuidString,"messageID":"assistant"])
        XCTAssertEqual(calls,["assistant"])
    }

    func testPebbleBrandMotionFollowsActivityAndPausesWhenHiddenOrMotionReduced() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        renderer.render([user("整理一下刚才的录音")],busy:true,reduceMotion:true)
        try await renderer.wait("!document.querySelector('#working').hidden && document.querySelector('img.brand-thinking').complete && document.querySelector('img.brand-thinking').naturalWidth > 0")
        try await renderer.check("!document.querySelector('.activity-mark').dataset.motionReady && getComputedStyle(document.querySelector('canvas.brand-pebbles')).display === 'none'")
        await renderer.attach(to:self,name:"pebble-reduced-motion-cold-start-still")
        renderer.render([user("整理一下刚才的录音")],busy:true,reduceMotion:false)
        try await renderer.wait("!document.querySelector('#working').hidden && document.querySelector('#working').dataset.animating === String(!matchMedia('(prefers-reduced-motion: reduce)').matches)")
        try await renderer.wait("document.querySelector('#working img.brand-thinking')?.complete && document.querySelector('#working img.brand-thinking').naturalWidth > 0")
        try await renderer.check("getComputedStyle(document.querySelector('.typing-bubble')).width === '56px' && getComputedStyle(document.querySelector('.typing-dots > span')).width === '8px'")
        try await renderer.check("document.querySelectorAll('img.brand-thinking').length === 1 && !document.querySelector('svg.life-avatar')")
        try await renderer.check("getComputedStyle(document.querySelector('.typing-dots > span')).animationName === (matchMedia('(prefers-reduced-motion: reduce)').matches ? 'none' : 'typing-pulse')")
        _ = try await renderer.web.evaluateJavaScript("""
        window.sharedActivityMark = document.querySelector('img.brand-thinking');
        window.originalMarkSource = window.sharedActivityMark.src;
        window.sharedPebbles = document.querySelector('canvas.brand-pebbles');
        true
        """)
        try await renderer.check("window.sharedPebbles.width === 64 && window.sharedPebbles.height === 56 && getComputedStyle(document.querySelector('#working > .activity-mark')).display === 'none'")
        try await renderer.check("document.querySelector('.activity-mark').getAttribute('aria-hidden') === 'true' && document.querySelector('img.brand-thinking').getAttribute('alt') === ''")
        await renderer.attach(to:self,name:"brand-mark-waiting-light")
        renderer.render([user("整理一下刚才的录音")],busy:true,dark:true,reduceMotion:false)
        try await renderer.wait("document.documentElement.dataset.dark === 'true'")
        try await renderer.check("window.sharedActivityMark.src === window.originalMarkSource && window.sharedActivityMark.naturalWidth > 0")
        await renderer.attach(to:self,name:"brand-mark-waiting-dark")

        let thought = AgentMessageBlock(id:"thought",content:.reasoning("正在核对原文。",redacted:false))
        renderer.render([user("整理一下刚才的录音"),assistant([thought],state:.streaming)],busy:true,reduceMotion:false)
        try await renderer.wait("document.querySelector('.reasoning-step > summary img.brand-thinking') === window.sharedActivityMark && document.querySelector('.process-title').textContent === '正在思考'")
        try await renderer.wait("document.querySelector('.activity-mark').dataset.motionReady === 'true'")
        try await renderer.check("document.querySelectorAll('img.brand-thinking').length === 1 && getComputedStyle(document.querySelector('.process-title')).animationName === (matchMedia('(prefers-reduced-motion: reduce)').matches ? 'none' : 'activity-shimmer')")
        let initialPebbles = try await renderer.pebblePixels()
        if try await renderer.web.evaluateJavaScript("!matchMedia('(prefers-reduced-motion: reduce)').matches") as? Bool == true {
            try await renderer.wait("document.querySelector('.activity-mark').dataset.motionState === 'running'")
            try await Task.sleep(for:.milliseconds(180))
            let movingPebbles = try await renderer.pebblePixels()
            XCTAssertNotEqual(initialPebbles,movingPebbles,"The bundled animation must change actual WebKit pixels.")
        }
        try await renderer.check("document.querySelector('.reasoning-step > summary canvas.brand-pebbles') === window.sharedPebbles")
        await renderer.attach(to:self,name:"thinking-text-shimmer-brand-mark")

        let reading = AgentMessageBlock(id:"read-source",content:.tool(.init(id:"read-source",name:"read_transcript",input:"{}",output:nil,state:.running)))
        renderer.render([user("整理一下刚才的录音"),assistant([thought,reading],state:.streaming)],busy:true,reduceMotion:false)
        try await renderer.wait("document.querySelector('.tool-card > summary img.brand-thinking') === window.sharedActivityMark")
        try await renderer.check("document.querySelector('.tool-card > summary canvas.brand-pebbles') === window.sharedPebbles && document.querySelectorAll('canvas.brand-pebbles').length === 1")
        try await renderer.check("document.querySelectorAll('img.brand-thinking').length === 1 && getComputedStyle(document.querySelector('.tool-name')).animationName === (matchMedia('(prefers-reduced-motion: reduce)').matches ? 'none' : 'activity-shimmer') && getComputedStyle(document.querySelector('.process-title')).animationName === 'none'")
        await renderer.attach(to:self,name:"tool-text-shimmer-brand-mark")

        renderer.render([user("整理一下刚才的录音"),assistant([thought,reading],state:.streaming)],busy:true,reduceMotion:true)
        try await renderer.wait("document.documentElement.dataset.activityAnimating === 'false'")
        try await renderer.check("getComputedStyle(document.querySelector('.tool-name')).animationName === 'none' && getComputedStyle(document.querySelector('.tool-name')).webkitTextFillColor !== 'rgba(0, 0, 0, 0)'")

        renderer.render([user("整理一下刚才的录音")],busy:true,reduceMotion:true)
        try await renderer.wait("document.querySelector('#working').dataset.animating === 'false'")
        try await renderer.check("document.querySelector('.activity-mark').dataset.motionState === 'paused'")
        let staticPebbles = try await renderer.pebblePixels()
        try await Task.sleep(for:.milliseconds(180))
        let reducedPebbles = try await renderer.pebblePixels()
        XCTAssertEqual(staticPebbles,reducedPebbles)

        renderer.render([user("整理一下刚才的录音")],busy:true,reduceMotion:false)
        try await renderer.wait("document.querySelector('#working').dataset.animating === String(!matchMedia('(prefers-reduced-motion: reduce)').matches)")
        // Deliver a controlled visibility event to exercise the lifecycle gate without backgrounding the test host.
        _ = try await renderer.web.evaluateJavaScript("Object.defineProperty(document,'hidden',{configurable:true,value:true}); document.dispatchEvent(new Event('visibilitychange')); true")
        let hiddenPebbles = try await renderer.pebblePixels()
        try await Task.sleep(for:.milliseconds(180))
        try await renderer.check("document.querySelector('#working').dataset.animating === 'false' && document.querySelector('.activity-mark').dataset.motionState === 'paused'")
        let stillHiddenPebbles = try await renderer.pebblePixels()
        XCTAssertEqual(hiddenPebbles,stillHiddenPebbles)
        _ = try await renderer.web.evaluateJavaScript("delete document.hidden; document.dispatchEvent(new Event('visibilitychange')); true")
        try await renderer.wait("document.querySelector('#working').dataset.animating === String(!matchMedia('(prefers-reduced-motion: reduce)').matches)")

        renderer.render([user("整理一下刚才的录音"),assistant([.init(id:"thought",content:.reasoning("正在核对原文。",redacted:false)),.init(id:"body",content:.text("整理好了。"))])],reduceMotion:false)
        try await renderer.wait("document.querySelector('#working').hidden && document.querySelector('.reasoning-step').textContent.includes('正在核对原文')")
        try await renderer.check("document.querySelector('#working').dataset.animating === 'false' && document.querySelectorAll('.reasoning-step canvas.brand-pebbles').length === 0 && document.querySelector('.activity-mark').dataset.motionState === 'paused'")

        renderer.render([user("整理一下刚才的录音")],busy:true,reduceMotion:false)
        try await renderer.wait("!document.querySelector('#working').hidden")
        _ = try await renderer.web.evaluateJavaScript("window.MoMoChat.suspend(); true")
        let suspendedPebbles = try await renderer.pebblePixels()
        try await Task.sleep(for:.milliseconds(180))
        try await renderer.check("document.querySelector('.activity-mark').dataset.motionState === 'paused' && document.documentElement.dataset.activityAnimating === 'false' && getComputedStyle(document.querySelector('.working-label')).animationName === 'none'")
        let stillSuspendedPebbles = try await renderer.pebblePixels()
        XCTAssertEqual(suspendedPebbles,stillSuspendedPebbles)
    }

    func testDotsDateHeadersAndBubbleTypographyCenterAcrossTranscript() async throws {
        let renderer = try RendererHarness()
        defer { renderer.close() }
        try await renderer.ready()
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .hour, value: -10, to: todayStart))
        let todayFirst = try XCTUnwrap(calendar.date(byAdding: .minute, value: -45, to: now))
        let todayGrouped = try XCTUnwrap(calendar.date(byAdding: .minute, value: -35, to: now))
        let todaySecondMarker = try XCTUnwrap(calendar.date(byAdding: .minute, value: -5, to: now))
        let messages: [AgentChatMessage] = [
            .init(id: "u-yesterday", turnID: "t1", role: "user", blocks: [.init(id: "b1", content: .text("昨天的记录"))], state: .complete, sentAt: yesterday),
            .init(id: "a-today-1", turnID: "t2", role: "assistant", blocks: [.init(id: "b2", content: .text("今天的第一条 **重点** 与 `代码`"))], state: .complete, sentAt: todayFirst),
            .init(id: "u-today-grouped", turnID: "t3", role: "user", blocks: [.init(id: "b3", content: .text("十分钟内的追问"))], state: .complete, sentAt: todayGrouped),
            .init(id: "a-today-2", turnID: "t4", role: "assistant", blocks: [.init(id: "b4", content: .text("超过半小时后的新分组"))], state: .complete, sentAt: todaySecondMarker)
        ]
        renderer.render(messages)
        try await renderer.wait("document.querySelectorAll('.turn-timestamp > time').length === 3")
        try await renderer.check("document.querySelectorAll('.turn[data-has-timestamp=true]').length === 3 && document.querySelectorAll('.turn[data-has-timestamp=false]').length === 1")
        try await renderer.check("""
        (() => {
          const transcriptRect = document.querySelector('#transcript').getBoundingClientRect();
          const transcriptCenter = transcriptRect.left + transcriptRect.width / 2;
          const headers = [...document.querySelectorAll('.turn-timestamp')];
          const centered = headers.every(node => {
            const rect = node.getBoundingClientRect();
            return Math.abs((rect.left + rect.width / 2) - transcriptCenter) < 1.5;
          });
          const userBubble = getComputedStyle(document.querySelector('.user-bubble'));
          const prose = getComputedStyle(document.querySelector('.prose'));
          const strong = getComputedStyle(document.querySelector('.prose strong'));
          const code = getComputedStyle(document.querySelector('.prose code'));
          const time = getComputedStyle(document.querySelector('.turn-timestamp > time'));
          return centered &&
            userBubble.fontSize === '16px' && userBubble.fontWeight === '400' && userBubble.lineHeight === '20px' &&
            prose.fontSize === '16px' && prose.fontWeight === '400' && prose.lineHeight === '20px' &&
            strong.fontWeight === '600' && code.fontSize === '14px' &&
            time.fontSize === '12px' && time.fontWeight === '400' && time.lineHeight === '16px';
        })()
        """)
        try await renderer.check("""
        (() => {
          document.documentElement.toggleAttribute('data-desktop', true);
          const userBubble = getComputedStyle(document.querySelector('.user-bubble'));
          const prose = getComputedStyle(document.querySelector('.prose'));
          const code = getComputedStyle(document.querySelector('.prose code'));
          const time = getComputedStyle(document.querySelector('.turn-timestamp > time'));
          const ok = userBubble.fontSize === '14px' && userBubble.fontWeight === '430' && userBubble.lineHeight === '18px' &&
            prose.fontSize === '14px' && prose.fontWeight === '430' && prose.lineHeight === '18px' &&
            code.fontSize === '13px' &&
            time.fontSize === '12px' && time.fontWeight === '430' && time.lineHeight === '16px';
          document.documentElement.toggleAttribute('data-desktop', false);
          return ok;
        })()
        """)
        let snapshot = ChatRenderSnapshot(sessionID: UUID(), messages: messages, busy: false)
        let nativeMarkers = snapshot.nativeTimestampMarkers(now: now)
        XCTAssertEqual(Set(nativeMarkers.keys), ["u-yesterday", "a-today-1", "a-today-2"])
    }

    private func user(_ text: String) -> AgentChatMessage {
        .init(id:"user",turnID:"turn",role:"user",blocks:[.init(id:"user-text",content:.text(text))],state:.complete)
    }
    private func assistant(_ blocks: [AgentMessageBlock], state: AgentMessageState = .complete) -> AgentChatMessage {
        .init(id:"assistant",turnID:"turn",role:"assistant",blocks:blocks,state:state)
    }
    private func tool(_ id: String, name: String, state: AgentToolExecution.State, output: String) -> AgentMessageBlock {
        .init(id:id,content:.tool(.init(id:id,name:name,input:"{\"query\":\"参观时间\"}",output:output,state:state)))
    }
}

/// Records real WebKit policy dispatch while preserving the production delegate's decisions and lifecycle.
@MainActor
private final class NavigationPolicyObserver: NSObject, WKNavigationDelegate {
    struct Decision {
        let url: URL?
        let mainFrame: Bool
        let policy: WKNavigationActionPolicy
    }
    let delegate: any WKNavigationDelegate
    private(set) var decisions: [Decision] = []

    init(delegate: any WKNavigationDelegate) { self.delegate = delegate }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard delegate.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")) else {
            XCTFail("The production navigation-policy selector disappeared.")
            decisionHandler(.cancel)
            return
        }
        delegate.webView?(webView, decidePolicyFor: action, decisionHandler: { [self] policy in
            decisions.append(.init(url: action.request.url, mainFrame: action.targetFrame?.isMainFrame == true, policy: policy))
            decisionHandler(policy)
        })
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate.webView?(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        delegate.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        delegate.webView?(webView, didFail: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        delegate.webViewWebContentProcessDidTerminate?(webView)
    }

    func waitForDecision(after count: Int) async throws -> Decision {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if decisions.count > count { return decisions[count] }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("WebKit did not dispatch the requested navigation to the production policy.")
        throw NSError(domain: "ChatRendererNavigation", code: 2)
    }
}

@MainActor
private final class RendererHarness {
    let web: WKWebView
    let coordinator: ChatWebCoordinator
    private let window: UIWindow
    private weak var previousWindow: UIWindow?
    private let sessionID = UUID()
    private var failed = false
    private(set) var opened: URL?
    private(set) var openedAction: UUID?
    private(set) var readingPositions: [UUID: ChatReadingPosition] = [:]
    private(set) var readingSequence = 0
    private var readingSequences: [UUID: Int] = [:]
    private var readingEvents: [[String: Any]] = []

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:393,height:740)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        coordinator = ChatWebCoordinator(failed:{},open:{_ in})
        configuration.userContentController.add(coordinator,name:"chat")
        web = WKWebView(frame:window.bounds,configuration:configuration)
        // Match ChatWebSurface: its SwiftUI container already owns safe-area layout.
        web.scrollView.contentInsetAdjustmentBehavior = .never
        coordinator.webView = web
        coordinator.failed = { [weak self] in self?.failed = true }
        coordinator.open = { [weak self] in self?.opened = $0 }
        coordinator.systemAction = { [weak self] in self?.openedAction = $0 }
        coordinator.readingPosition = { [weak self] in self?.receiveReadingPosition($0) }
        let controller = UIViewController()
        controller.view = web
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let url = try XCTUnwrap(Bundle.main.url(forResource:"index",withExtension:"html",subdirectory:"Web"))
        coordinator.resourceDirectory = url.deletingLastPathComponent()
        web.navigationDelegate = coordinator
        web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent())
    }
    func ready() async throws { try await wait("typeof window.MoMoChat === 'object'") }
    func recordScrollEvents() async throws {
        _ = try await web.evaluateJavaScript("""
        (() => {
          window.rendererScrollEvents = [];
          const record = (event, detail = null) => {
            const entries = window.rendererScrollEvents;
            entries.push({ event, detail, time:performance.now(), top:scrollY,
              viewport:innerHeight, height:document.documentElement.scrollHeight,
              jumpHidden:document.querySelector('#jump').hidden, hidden:document.hidden });
            if (entries.length > 160) entries.shift();
          };
          const scroll = window.scrollTo.bind(window);
          window.scrollTo = (...args) => {
            record('scroll-request',args);
            const result = scroll(...args);
            record('scroll-return');
            return result;
          };
          const frame = window.requestAnimationFrame.bind(window);
          window.requestAnimationFrame = callback => frame(time => {
            record('frame-before'); callback(time); record('frame-after');
          });
          for (const event of ['scroll','scrollend','touchstart','touchend','touchcancel','wheel'])
            window.addEventListener(event,() => record(event),{ passive:true });
          document.querySelector('#jump').addEventListener('click',() => record('jump-click'));
          document.addEventListener('visibilitychange',() => record('visibility'));
          new ResizeObserver(() => record('resize')).observe(document.body);
          record('installed');
          return true;
        })()
        """)
    }
    func attachScrollEvents(to test: XCTestCase) async throws {
        let value = try await web.evaluateJavaScript("JSON.stringify(window.rendererScrollEvents ?? [])")
        let attachment = XCTAttachment(string: String(describing:value))
        attachment.name = "renderer-scroll-events"; attachment.lifetime = .keepAlways
        test.add(attachment)
        let bridge = XCTAttachment(data: try JSONSerialization.data(withJSONObject: readingEvents, options: [.prettyPrinted, .sortedKeys]),
                                   uniformTypeIdentifier: "public.json")
        bridge.name = "renderer-reading-bridge-events"; bridge.lifetime = .keepAlways
        test.add(bridge)
    }
    func render(_ messages: [AgentChatMessage], busy: Bool = false, dark: Bool = false, reduceMotion: Bool = true, stopped: Bool = false,
                sessionID id: UUID? = nil, readingPosition: ChatReadingPosition? = nil, contextState: AgentContextState = .idle, canRegenerate: Bool = true, headerInset: CGFloat = 0) {
        coordinator.update(.init(snapshot:.init(sessionID:id ?? sessionID,messages:messages,busy:busy,stopped:stopped,readingPosition:readingPosition,contextState:contextState,canRegenerate:canRegenerate),
            appearance:.init(dark:dark,reduceMotion:reduceMotion,scale:1,headerInset:headerInset)))
    }
    private func receiveReadingPosition(_ position: ChatReadingPosition) {
        readingSequence += 1
        readingPositions[position.sessionID] = position
        readingSequences[position.sessionID] = readingSequence
        readingEvents.append(["sequence": readingSequence, "time": ProcessInfo.processInfo.systemUptime,
                              "sessionID": position.sessionID.uuidString, "following": position.following,
                              "top": position.top, "anchorID": position.anchorID ?? "", "anchorOffset": position.anchorOffset])
        if readingEvents.count > 160 { readingEvents.removeFirst(readingEvents.count - 160) }
    }
    func waitForReadingPosition(_ id: UUID, following: Bool, after sequence: Int, top: Double,
                                nativeScrollAfter startTime: Double? = nil) async throws -> ChatReadingPosition {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            // A DOM scroll and its native bridge callback run on separate queues. An older
            // callback with the same following flag is not evidence of this scroll's position.
            if let value = readingPositions[id], (readingSequences[id] ?? 0) > sequence,
               value.following == following, abs(value.top - top) < 2,
               try await bool("Math.abs(scrollY - \(top)) < 2 && scrollY >= 0 && scrollY <= Math.max(0,document.documentElement.scrollHeight - innerHeight)") {
                if let startTime {
                    let measurement = try await web.evaluateJavaScript("""
                    (() => {
                      const events = window.rendererScrollEvents ?? [];
                      const scroll = events.findLast(e => e.event === 'scroll');
                      const end = events.findLast(e => e.event === 'scrollend');
                      return {
                        settled: !!scroll && !!end && scroll.time >= \(startTime) && end.time >= scroll.time &&
                          Math.abs(scroll.top - \(top)) < 2 && Math.abs(end.top - \(top)) < 2 &&
                          Math.abs(scrollY - \(top)) < 2,
                        bottom: Math.max(0,document.documentElement.scrollHeight - innerHeight)
                      };
                    })()
                    """) as? [String: Any]
                    let nativeBottom = max(0, web.scrollView.contentSize.height - web.scrollView.bounds.height)
                    if measurement?["settled"] as? Bool == true,
                       let bottom = measurement?["bottom"] as? Double,
                       abs(Double(web.scrollView.contentOffset.y) - top) < 2,
                       abs(Double(nativeBottom) - bottom) < 2 {
                        return value
                    }
                } else {
                    return value
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        print("Renderer reading bridge timed out: session=\(id) after=\(sequence) top=\(top) following=\(following) events=\(readingEvents)")
        let trace = try await web.evaluateJavaScript("JSON.stringify({top:scrollY,viewport:innerHeight,height:document.documentElement.scrollHeight,scrollEvents:window.rendererScrollEvents})")
        print("Renderer reading scroll diagnostic: \(String(describing: trace))")
        XCTFail("No new reading-position callback matched the requested session, following state and 2-point position bound.")
        throw NSError(domain: "ChatRendererReadingPosition", code: 1)
    }
    func bool(_ script: String) async throws -> Bool { try await web.evaluateJavaScript(script) as? Bool == true }
    func check(_ script: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await bool(script)
        XCTAssertTrue(result, script, file: file, line: line)
    }
    func wait(_ script: String) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if failed { throw NSError(domain:"ChatRenderer",code:1) }
            if try await bool(script) { return }
            try await Task.sleep(for:.milliseconds(75))
        }
        let diagnostic = try await web.evaluateJavaScript("JSON.stringify({tables:document.querySelectorAll('table').length,math:document.querySelectorAll('.katex').length,top:scrollY,viewport:innerHeight,height:document.documentElement.scrollHeight,hidden:document.hidden,scrollEvents:window.rendererScrollEvents,text:document.body.innerText.slice(0,3500)})")
        print("Renderer diagnostic: \(diagnostic)")
        print("Renderer reading bridge events: \(readingEvents)")
        print("Renderer native geometry: offset=\(web.scrollView.contentOffset), inset=\(web.scrollView.adjustedContentInset), content=\(web.scrollView.contentSize), bounds=\(web.bounds), window=\(window.bounds)")
        XCTFail("Renderer condition timed out: \(script)")
        throw NSError(domain:"ChatRenderer",code:2)
    }
    func waitForLink() async throws {
        for _ in 0..<40 { if opened != nil { return }; try await Task.sleep(for:.milliseconds(25)) }
        XCTFail("Source link did not reach the native resolver")
    }
    func attach(to test: XCTestCase, name: String) async {
        do {
            _ = try await web.callAsyncJavaScript("await document.fonts.ready; await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); return true", in:nil, in:.page)
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            let image = try await web.takeSnapshot(configuration:configuration)
            XCTAssertTrue(hasVisibleContent(image), "A blank WebKit capture is not visual evidence.")
            let attachment = XCTAttachment(image:image); attachment.name = name; attachment.lifetime = .keepAlways
            test.add(attachment)
        } catch { XCTFail("Could not capture renderer snapshot") }
    }
    func pebblePixels() async throws -> Data {
        // Local-file canvases are origin-tainted. Inspect native pixels without relaxing WebKit policy.
        let value = try await web.evaluateJavaScript("(document.querySelector('#working[data-phase=waiting]:not([hidden]) .typing-bubble') || document.querySelector('canvas.brand-pebbles')).getBoundingClientRect().toJSON()")
        let rect = try XCTUnwrap(value as? [String:Double])
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x:try XCTUnwrap(rect["x"]),y:try XCTUnwrap(rect["y"]),
                                    width:try XCTUnwrap(rect["width"]),height:try XCTUnwrap(rect["height"]))
        configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration:configuration)
        return try XCTUnwrap(image.pngData())
    }
    func close() {
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName:"chat")
        web.navigationDelegate = nil; window.isHidden = true; previousWindow?.makeKey()
    }
    private func hasVisibleContent(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        // Keep small text and the 28-point Avatar visible in a mostly empty waiting screen.
        let sampleSize = 128
        var pixels = [UInt8](repeating:0,count:sampleSize * sampleSize * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data:bytes.baseAddress,width:sampleSize,height:sampleSize,bitsPerComponent:8,bytesPerRow:sampleSize * 4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage,in:CGRect(x:0,y:0,width:sampleSize,height:sampleSize))
            let red = stride(from:0,to:bytes.count,by:4).map { Int(bytes[$0]) }
            return (red.max() ?? 0) - (red.min() ?? 0) > 24
        }
    }
}
