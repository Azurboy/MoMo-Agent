import Foundation
import MoMoAgentClient
import MoMoContracts

/// The only translation between agent facts and the standalone renderer's wire format.
struct ChatRenderSnapshot: Encodable, Equatable {
    struct Focus: Encodable, Equatable {
        let requestID: String
        let messageID: String
    }
    var focus: Focus? = nil
    struct Message: Encodable, Equatable {
        struct Block: Encodable, Equatable {
            struct Tool: Encodable, Equatable {
                let id: String
                let name: String
                let input: String
                let output: String?
                let state: String
            }
            let id: String
            let type: String
            var text: String?
            var redacted: Bool?
            var tool: Tool?
            var name: String?
            var preview: String?
            var kind: String?
            var format: String?
            var size: String?
            var attachmentID: String?
        }
        let id: String
        let turnID: String
        let role: String
        let state: String
        let blocks: [Block]
        var sentAtMs: Double? = nil
        var delivery: String? = nil
        var deliveryError: String? = nil
    }
    let sessionID: String
    let locale: String
    let messages: [Message]
    let busy: Bool
    let stopped: Bool
    let canRegenerate: Bool
    let contextState: String
    var waitingForReply: Bool? = nil
    let readingPosition: ChatReadingPosition?

    // Match the Web renderer even when a system event follows the last outgoing message.
    var deliveryReceiptMessageID: String? {
        guard let index = messages.lastIndex(where: { $0.role == "user" }),
              let delivery = messages[index].delivery, ["delivered", "read"].contains(delivery),
              !messages.suffix(from: index + 1).contains(where: { $0.role == "assistant" }) else { return nil }
        return messages[index].id
    }

    private static let minimumPlausibleEpochSeconds = 946_684_800.0 // 2000-01-01T00:00:00Z
    private static let timestampMarkerIntervalMs = 1_800_000.0 // 30 minutes (Dots thread marker threshold)

    private static func epochMilliseconds(_ date: Date?) -> Double? {
        guard let seconds = date?.timeIntervalSince1970 else { return nil }
        return epochMilliseconds(seconds: seconds)
    }

    private static func epochMilliseconds(seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds >= minimumPlausibleEpochSeconds else { return nil }
        return (seconds * 1000).rounded()
    }

    func nativeTimestampMarkers(now: Date = Date()) -> [String: String] {
        let calendar = Calendar.current
        let localeIdentifier = locale == "zh-Hans" ? "zh-CN" : locale
        let formatterLocale = Locale(identifier: localeIdentifier)
        var result: [String: String] = [:]
        var previousMarkerMs: Double?
        var previousTurnKey: String?
        for message in messages {
            if message.role == "system" {
                previousTurnKey = "system:\(message.id)"
                continue
            }
            let turnKey = message.role == "assistant" ? "assistant:\(message.turnID)" : "user:\(message.id)"
            if message.role == "assistant", previousTurnKey == turnKey { continue }
            previousTurnKey = turnKey
            guard let sentAtMs = message.sentAtMs, sentAtMs.isFinite else { continue }
            let date = Date(timeIntervalSince1970: sentAtMs / 1000)
            let isFirst = previousMarkerMs == nil
            let shouldShow: Bool
            if let prevMs = previousMarkerMs {
                let prevDate = Date(timeIntervalSince1970: prevMs / 1000)
                shouldShow = !calendar.isDate(prevDate, inSameDayAs: date) || sentAtMs - prevMs >= Self.timestampMarkerIntervalMs
            } else {
                shouldShow = true
            }
            if shouldShow {
                let timeText = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(formatterLocale))
                let dayStart = calendar.startOfDay(for: date)
                let nowStart = calendar.startOfDay(for: now)
                let dayOffset = calendar.dateComponents([.day], from: nowStart, to: dayStart).day
                if dayOffset == 0 {
                    result[message.id] = switch locale {
                    case "en": "Today, \(timeText)"
                    case "ja": "今日 \(timeText)"
                    case "ko": "오늘 \(timeText)"
                    default: "今天 \(timeText)"
                    }
                } else if dayOffset == -1 {
                    result[message.id] = switch locale {
                    case "en": "Yesterday, \(timeText)"
                    case "ja": "昨日 \(timeText)"
                    case "ko": "어제 \(timeText)"
                    default: "昨天 \(timeText)"
                    }
                } else {
                    var style = Date.FormatStyle().locale(formatterLocale).month(.abbreviated).day().hour().minute()
                    if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
                        style = style.year()
                    }
                    result[message.id] = date.formatted(style)
                }
            }
            if isFirst || shouldShow { previousMarkerMs = sentAtMs }
        }
        return result
    }

    @MainActor init(store: RemoteTaskStore, readingPosition: ChatReadingPosition? = nil, notificationTarget: AgentNotificationTarget? = nil) {
        if let target = notificationTarget, target.matches(store.connection), let messageID = target.messageID {
            focus = Focus(requestID: target.deliveryID.uuidString, messageID: messageID)
        }
        sessionID = store.connection.assistantID.uuidString
        locale = AppLanguage.current.rawValue
        busy = store.hasActiveTask
        stopped = false; contextState = "idle"; canRegenerate = false
        waitingForReply = store.waitingForReply
        self.readingPosition = readingPosition
        let confirmedOperations = Set(store.messages.compactMap(\.operationID))
        let confirmedRuns = Set(store.messages.compactMap(\.runID))
        let tasksByID = Dictionary(store.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var tasksByRunID: [String: RemoteTask] = [:]
        for task in store.tasks {
            if let runID = task.run?.runID { tasksByRunID[runID] = task }
        }
        let sharedRunsByID = Dictionary(store.sharedRuns.map { ($0.runID, $0) }, uniquingKeysWith: { _, last in last })
        func receipt(runID: String?, operationID: UUID?, messageState: String? = nil, serverConfirmed: Bool = false) -> String? {
            let local = (operationID.flatMap { tasksByID[$0] } ?? runID.flatMap { tasksByRunID[$0] })?.run
            let remote = (runID ?? local?.runID).flatMap { sharedRunsByID[$0] }
            return AgentMessageReceipt.resolve(runs: [local, remote].compactMap { $0 },
                messageState: messageState, serverConfirmed: serverConfirmed)?.rawValue
        }
        func liveStreamingMessage(turnID: String, reply: RemoteReply, committedAssistantCount: Int = 0, sentAtMs: Double? = nil) -> Message? {
            var blocks: [Message.Block] = (reply.tools ?? []).map { tool in
                let identifier = tool.callID ?? String(tool.id)
                return .init(id: "\(turnID):tool:\(identifier)", type: "tool",
                    tool: .init(id: identifier, name: tool.name, input: "{}", output: nil, state: tool.state))
            }
            if committedAssistantCount < reply.messages.count {
                for index in committedAssistantCount..<reply.messages.count {
                    blocks.append(.init(id: "\(turnID):interim:\(index)", type: "text", text: reply.messages[index]))
                }
            }
            if !reply.partial.isEmpty {
                blocks.append(.init(id: "\(turnID):partial", type: "text", text: reply.partial))
            }
            guard !blocks.isEmpty else { return nil }
            return Message(id: "\(turnID):streaming", turnID: turnID, role: "assistant", state: "streaming", blocks: blocks, sentAtMs: sentAtMs)
        }
        let timeline: [(Date, Message)] = store.tasks.filter { task in
            !confirmedOperations.contains(task.id) && !(task.run.map { confirmedRuns.contains($0.runID) } ?? false)
        }.flatMap { task -> [(Date, Message)] in
            let turn = task.id.uuidString
            var rows: [(Date, Message)] = []
            if task.backgroundMessageIDs == nil {
                var blocks: [Message.Block] = (task.attachments ?? []).map { item in
                    .init(id: turn + ":attachment:\(item.id.uuidString)", type: "attachment", name: item.name,
                        preview: AttachmentPreviewDataURLCache.dataURL(for: item.id, preview: item.preview), kind: item.kind.rawValue,
                        format: item.displayFormat, size: item.displaySize, attachmentID: item.id.uuidString)
                }
                if !task.input.isEmpty || blocks.isEmpty {
                    blocks.append(.init(id: turn + ":input", type: "text", text: task.input))
                }
                rows.append((task.createdAt, Message(id: turn + ":user", turnID: turn, role: "user", state: "complete",
                blocks: blocks, sentAtMs: Self.epochMilliseconds(task.createdAt),
                delivery: task.deliveryFailed ? "failed" : receipt(runID: task.run?.runID, operationID: task.id), deliveryError: task.lastError)))
            }
            for (index, text) in (task.reply?.messages ?? []).enumerated() {
                let date = task.replyReceivedAt.flatMap { index < $0.count ? $0[index] : nil } ?? task.createdAt
                rows.append((date, Message(id: turn + ":reply-\(index)", turnID: turn, role: "assistant", state: "complete",
                    blocks: [.init(id: turn + ":reply-\(index)", type: "text", text: text)],
                    sentAtMs: Self.epochMilliseconds(date))))
            }
            if !task.isFinished, let reply = task.reply,
               let live = liveStreamingMessage(turnID: turn, reply: reply, committedAssistantCount: reply.messages.count,
                                               sentAtMs: Self.epochMilliseconds(task.firstTextReceivedAt ?? task.createdAt)) {
                rows.append((task.firstTextReceivedAt ?? task.createdAt, live))
            }
            if let text = task.run?.output, !text.isEmpty {
                let outputDate = task.finishedAt ?? task.createdAt
                rows.append((outputDate, Message(id: turn + ":assistant", turnID: turn, role: "assistant", state: "complete",
                    blocks: [.init(id: turn + ":output", type: "text", text: text)],
                    sentAtMs: Self.epochMilliseconds(outputDate))))
            }
            if let run = task.run, run.isTerminal, run.status != "completed" {
                let text = run.status == "failed" ? String(localized: "这次没能完成。") + (run.error.map { "\n" + $0 } ?? "") : String(localized: "已停止。")
                rows.append((task.finishedAt ?? task.createdAt, Message(id: turn + ":status", turnID: turn + ":status", role: "system", state: "complete",
                    blocks: [.init(id: turn + ":status", type: "text", text: text)])))
            }
            return rows
        }
        let displayed = store.displayMessages
        var lastDisplayIndexByRun: [String: Int] = [:]
        var assistantCountByRun: [String: Int] = [:]
        for (index, row) in displayed.enumerated() {
            if let runID = row.runID {
                lastDisplayIndexByRun[runID] = index
                if row.role == "assistant" { assistantCountByRun[runID, default: 0] += 1 }
            }
        }
        var remoteRows: [Message] = []
        remoteRows.reserveCapacity(displayed.count + store.sharedRunReplies.count)
        var renderedLiveRuns: Set<String> = []
        for (index, row) in displayed.enumerated() {
            let outgoing = row.role == "user" ? row.operationID?.uuidString : nil
            let attachments = row.attachments ?? (row.operationID.flatMap { tasksByID[$0]?.attachments }) ?? []
            var blocks: [Message.Block] = attachments.map { item in
                .init(id: row.id + ":attachment:\(item.id.uuidString)", type: "attachment", name: item.name,
                    preview: AttachmentPreviewDataURLCache.dataURL(for: item.id, preview: item.preview), kind: item.kind.rawValue,
                    format: item.displayFormat, size: item.displaySize, attachmentID: item.id.uuidString)
            }
            if !row.content.isEmpty || blocks.isEmpty {
                blocks.append(.init(id: row.id + ":text", type: "text", text: row.content))
            }
            // Keep the local outgoing timestamp on server echo so timestamp headers never jump.
            let rowSentAtMs: Double? = if row.role == "system" {
                nil
            } else if row.role == "user", let opID = row.operationID, let localCreatedAt = tasksByID[opID]?.createdAt {
                Self.epochMilliseconds(localCreatedAt)
            } else {
                Self.epochMilliseconds(seconds: row.createdAt)
            }
            remoteRows.append(Message(id: outgoing.map { $0 + ":user" } ?? row.id, turnID: outgoing ?? (row.role == "system" ? row.id : row.runID ?? row.id),
                role: row.role, state: "complete", blocks: blocks, sentAtMs: rowSentAtMs,
                delivery: row.role == "user" ? receipt(runID: row.runID, operationID: row.operationID,
                    messageState: row.deliveryState, serverConfirmed: true) : nil))
            if let runID = row.runID, lastDisplayIndexByRun[runID] == index {
                let run = sharedRunsByID[runID] ?? tasksByRunID[runID]?.run
                if run?.isTerminal != true,
                   let reply = store.sharedRunReplies[runID] ?? tasksByRunID[runID]?.reply {
                    let turnID = tasksByRunID[runID]?.id.uuidString ?? runID
                    let liveSentAtMs = Self.epochMilliseconds(tasksByRunID[runID]?.firstTextReceivedAt)
                        ?? Self.epochMilliseconds(seconds: run?.createdAt)
                        ?? Self.epochMilliseconds(seconds: row.createdAt)
                    if let live = liveStreamingMessage(turnID: turnID, reply: reply,
                                                       committedAssistantCount: assistantCountByRun[runID] ?? 0,
                                                       sentAtMs: liveSentAtMs) {
                        remoteRows.append(live)
                    }
                    renderedLiveRuns.insert(runID)
                }
            }
        }
        for run in store.sharedRuns where !run.isTerminal && !renderedLiveRuns.contains(run.runID) && tasksByRunID[run.runID] == nil {
            if let reply = store.sharedRunReplies[run.runID],
               let live = liveStreamingMessage(turnID: run.runID, reply: reply,
                                               sentAtMs: Self.epochMilliseconds(seconds: run.createdAt)) {
                remoteRows.append(live)
            }
        }
        let localRows = timeline.enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }.map { $0.element.1 }
        let outbox = Set(store.tasks.filter { $0.sessionID == store.conversation?.sessionID }.map { $0.id.uuidString })
        // Server sequence is authoritative even when a device or wall clock moves.
        messages = localRows.filter { !outbox.contains($0.turnID) } + remoteRows + localRows.filter { outbox.contains($0.turnID) }
        if messages.last(where: { $0.role == "user" })?.delivery != "read" { waitingForReply = false }
    }
    init(sessionID: UUID?, messages: [AgentChatMessage], busy: Bool, stopped: Bool = false,
         readingPosition: ChatReadingPosition? = nil, contextState: AgentContextState = .idle, canRegenerate: Bool = true) {
        self.sessionID = sessionID?.uuidString ?? "new"
        self.locale = AppLanguage.current.rawValue
        self.canRegenerate = canRegenerate
        self.busy = busy
        self.stopped = stopped
        self.contextState = stopped ? AgentContextState.idle.rawValue : contextState.rawValue
        self.readingPosition = readingPosition?.sessionID == sessionID ? readingPosition : nil
        self.messages = messages.map { message in
            Message(id: message.id, turnID: message.turnID, role: message.role, state: message.state.rawValue,
                blocks: message.blocks.map { block in
                    switch block.content {
                    case .text(let text): return .init(id: block.id, type: "text", text: text)
                    case .attachment(let item):
                        return .init(id: block.id, type: "attachment", name: item.name,
                            preview: AttachmentPreviewDataURLCache.dataURL(for: item.id, preview: item.preview), kind: item.kind.rawValue,
                            format: item.displayFormat, size: item.displaySize, attachmentID: item.id.uuidString)
                    case .reasoning(let text, let redacted):
                        return .init(id: block.id, type: "reasoning", text: text, redacted: redacted)
                    case .tool(let tool):
                        return .init(id: block.id, type: "tool", tool: .init(id: tool.id, name: tool.name,
                            input: tool.input, output: tool.output, state: tool.state.rawValue))
                    }
                },
                sentAtMs: Self.epochMilliseconds(message.sentAt))
        }
    }
}

private enum AttachmentPreviewDataURLCache {
    private struct Key: Hashable {
        let id: UUID
        let byteCount: Int
        let sampleHash: Int
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Key: String] = [:]
    nonisolated(unsafe) private static var order: [Key] = []
    private static let capacity = 128

    static func dataURL(for id: UUID, preview: Data?) -> String? {
        guard let preview else { return nil }
        var hasher = Hasher()
        hasher.combine(preview.prefix(64))
        hasher.combine(preview.suffix(64))
        let key = Key(id: id, byteCount: preview.count, sampleHash: hasher.finalize())
        return lock.withLock {
            if let cached = entries[key] { return cached }
            let encoded = "data:image/jpeg;base64," + preview.base64EncodedString()
            if entries.count >= capacity, !order.isEmpty {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
            entries[key] = encoded
            order.append(key)
            return encoded
        }
    }
}
