import Foundation

public struct SharedConversation: Codable, Sendable, Equatable {
    public let conversationID: String
    public let sessionID: String
    public let assistantID: UUID
    public let instanceID: UUID
    public let capabilities: Capabilities
    public struct Capabilities: Codable, Sendable, Equatable {
        public let sharedConversation: Bool
        public let serverOwnedCompletion: Bool
        public let durableSteering: Bool
        public let independentChatWhileWaiting: Bool
        public let systemPush: Bool
        public var messageIdempotency: AgentCapabilities.Features.Idempotency? = nil
        public var messageStreaming: Bool? = nil
        public var conversationEvents: Bool? = nil
        enum CodingKeys: String, CodingKey {
            case sharedConversation = "shared_conversation", serverOwnedCompletion = "server_owned_completion"
            case durableSteering = "durable_steering", independentChatWhileWaiting = "independent_chat_while_waiting"
            case systemPush = "system_push"
            case messageIdempotency = "message_idempotency"
            case messageStreaming = "message_streaming"
            case conversationEvents = "conversation_events"
        }
    }
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", sessionID = "session_id", assistantID = "assistant_id"
        case instanceID = "instance_id", capabilities
    }
}

public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let seq: Int
    public let role: String
    public let content: String
    public let createdAt: Double
    public let operationID: UUID?
    public let runID: String?
    public var sourceSession: String? = nil
    public var deliveryState: String? = nil
    public var attachments: [AgentAttachment]? = nil
    enum CodingKeys: String, CodingKey {
        case id, seq, role, content
        case createdAt = "created_at", operationID = "operation_id", runID = "run_id", sourceSession = "source_session"
        case deliveryState = "delivery_state", attachments
    }
}

public struct ConversationPage: Codable, Sendable {
    public let data: [ConversationMessage]
    public let nextCursor: Int
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey { case data; case nextCursor = "next_cursor", hasMore = "has_more" }
}

public struct ConversationWork: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let state: String
    public let reportState: String
    public var kind: String? = nil
    public var workID: String? = nil
    public var title: String? = nil
    public var originRunID: String? = nil
    public var executionGeneration: Int? = nil
    public var nativeState: String? = nil
    public var cancellable: Bool? = nil
    public var cancelRequested: Bool? = nil
    public var cancelState: String? = nil
    public var waitReason: String? = nil
    public var blockingWorkID: String? = nil
    public var reportRetryAvailable: Bool? = nil
    public var createdAt: Double? = nil
    public var updatedAt: Double? = nil
    public var sourceRecordedAt: Double? = nil
    public var originKind: String? = nil
    public var originLabel: String? = nil
    public var summary: String? = nil
    public var isPending: Bool { reportState != "reported" }
    enum CodingKeys: String, CodingKey {
        case id, state, reportState = "report_state", kind, title, workID = "work_id", originRunID = "origin_run_id"
        case executionGeneration = "execution_generation", nativeState = "native_state", cancellable
        case cancelRequested = "cancel_requested", cancelState = "cancel_state"
        case waitReason = "wait_reason", blockingWorkID = "blocking_work_id", reportRetryAvailable = "report_retry_available"
        case createdAt = "created_at", updatedAt = "updated_at", sourceRecordedAt = "source_recorded_at"
        case originKind = "origin_kind", originLabel = "origin_label", summary
    }
}

public struct ConversationWorkOverview: Codable, Sendable, Equatable {
    public let active: [ConversationWork]
    public let recent: [ConversationWork]
    public let skipped: [ConversationWork]
    public init(active: [ConversationWork] = [], recent: [ConversationWork] = [], skipped: [ConversationWork] = []) {
        self.active = active
        self.recent = recent
        self.skipped = skipped
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.active = try container.decodeIfPresent([ConversationWork].self, forKey: .active) ?? []
        self.recent = try container.decodeIfPresent([ConversationWork].self, forKey: .recent) ?? []
        self.skipped = try container.decodeIfPresent([ConversationWork].self, forKey: .skipped) ?? []
    }
}

public struct ConversationWorkDetail: Codable, Sendable, Equatable, Identifiable {
    public struct TodoItem: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let content: String
        public let status: String
    }

    public struct ActivityItem: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: String
        public let title: String
        public let detail: String?
        public let status: String
        public let timestamp: Double?
    }

    public let id: String
    public let ticketID: String?
    public let title: String
    public let status: String
    public let statusLabel: String
    public let originKind: String
    public let originLabel: String
    public let createdAt: Double?
    public let updatedAt: Double?
    public let endedAt: Double?
    public let sourceID: String?
    public let sourceTitle: String?
    public let sourceRecordedAt: Double?
    public let triggerPreview: String?
    public let scope: String?
    public let matchedRules: [String]
    public let summary: String?
    public let attentionQuestion: String?
    public let workspacePath: String?
    public let cancellable: Bool
    public let turnCount: Int
    public let stepCount: Int
    public let todos: [TodoItem]
    public let activities: [ActivityItem]

    public var isActive: Bool {
        ["queued", "running", "waiting_for_input", "finalizing"].contains(status)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, scope, summary, cancellable, todos, activities
        case ticketID = "ticket_id"
        case statusLabel = "status_label"
        case originKind = "origin_kind"
        case originLabel = "origin_label"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
        case sourceID = "source_id"
        case sourceTitle = "source_title"
        case sourceRecordedAt = "source_recorded_at"
        case triggerPreview = "trigger_preview"
        case matchedRules = "matched_rules"
        case attentionQuestion = "attention_question"
        case workspacePath = "workspace_path"
        case turnCount = "turn_count"
        case stepCount = "step_count"
    }
}

public struct ConversationRuns: Decodable, Sendable {
    public let data: [AgentRun]
    public let backgroundWork: [ConversationWork]?
    public let nextCursor: Int?
    public let hasMore: Bool?
    public var messageStates: [String: String]? = nil
    enum CodingKeys: String, CodingKey { case data, backgroundWork = "background_work", nextCursor = "next_cursor", hasMore = "has_more", messageStates = "message_states" }
}

public struct AgentControl: Codable, Sendable, Equatable, Identifiable {
    public let promptID: String
    public let kind: String
    public let prompt: String?
    public let command: String?
    public var question: String? = nil
    public let choices: [String]?
    public var id: String { promptID }
    enum CodingKeys: String, CodingKey { case promptID = "prompt_id", kind, prompt, command, choices, question }
}

public struct LegacyConsumption: Codable, Sendable {
    let runID: String
    let messageIDs: [Int]
    enum CodingKeys: String, CodingKey { case runID = "run_id", messageIDs = "message_ids" }
}

extension AgentClient {
    public func conversation() async throws -> SharedConversation {
        try JSONDecoder().decode(SharedConversation.self, from: await request(path: ["momo", "v1", "conversation"]))
    }
    public func conversationMessages(after cursor: Int) async throws -> ConversationPage {
        try JSONDecoder().decode(ConversationPage.self, from: await request(path: ["momo", "v1", "conversation", "messages"],
            query: [.init(name: "after", value: String(cursor)), .init(name: "limit", value: "100")]))
    }
    func conversationMessages(before cursor: Int) async throws -> ConversationPage {
        try JSONDecoder().decode(ConversationPage.self, from: await request(path: ["momo", "v1", "conversation", "messages"],
            query: [.init(name: "before", value: String(cursor)), .init(name: "limit", value: "100")]))
    }
    public func conversationRuns() async throws -> [AgentRun] {
        try await conversationRunSnapshot().data
    }
    public func conversationRunSnapshot(after cursor: Int = 0) async throws -> ConversationRuns {
        try JSONDecoder().decode(ConversationRuns.self, from: await request(path: ["momo", "v1", "conversation", "runs"],
            query: [.init(name: "after", value: String(cursor)), .init(name: "limit", value: "100")]))
    }
    public func submitMessage(input: String, operationID: UUID, targetRunID: String? = nil, generation: Int? = nil, workID: String? = nil, attachments: [AgentAttachment]? = nil) async throws -> AgentRun {
        let body = try messageBody(input: input, operationID: operationID, targetRunID: targetRunID, generation: generation, workID: workID, attachments: attachments)
        return try JSONDecoder().decode(AgentRun.self, from: await request(path: ["momo", "v1", "conversation", "messages"], method: "POST", body: body))
    }
    func messageBody(input: String, operationID: UUID, targetRunID: String?, generation: Int?, workID: String?, attachments: [AgentAttachment]? = nil) throws -> Data {
        var value: [String: Any] = ["operation_id": operationID.uuidString.lowercased(), "content": input, "intent": targetRunID == nil ? "new" : "steer"]
        if let targetRunID, let generation { value["target_run_id"] = targetRunID; value["execution_generation"] = generation; value["work_id"] = workID }
        if let attachments, !attachments.isEmpty {
            value["attachments"] = attachments.map { item -> [String: Any] in
                var dict: [String: Any] = [
                    "id": item.id.uuidString.lowercased(),
                    "name": item.name,
                    "kind": item.kind.rawValue,
                    "media_type": item.mediaType,
                    "byte_count": item.byteCount
                ]
                if let data = item.data { dict["data"] = data.base64EncodedString() }
                if let text = item.text { dict["text"] = text }
                if let preview = item.preview { dict["preview"] = preview.base64EncodedString() }
                return dict
            }
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    public func cancelWork(id: String, operationID: UUID, generation: Int, targetRunID: String? = nil) async throws {
        var value: [String: Any] = ["operation_id": operationID.uuidString.lowercased(), "execution_generation": generation]
        if let targetRunID { value["target_run_id"] = targetRunID }
        let body = try JSONSerialization.data(withJSONObject: value)
        _ = try await request(path: ["momo", "v1", "conversation", "work", id, "cancel"], method: "POST", body: body)
    }
    public func retryReport(id: String, operationID: UUID) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["operation_id": operationID.uuidString.lowercased()])
        _ = try await request(path: ["momo", "v1", "conversation", "work", id, "report-retry"], method: "POST", body: body)
    }
    public func respond(runID: String, control: AgentControl, generation: Int, answer: String) async throws {
        let field = control.kind == "approval" ? "choice" : "answer"
        let body = try JSONSerialization.data(withJSONObject: ["request_id": control.promptID, "execution_generation": generation, field: answer])
        _ = try await request(path: ["v1", "runs", runID, control.kind == "approval" ? "approval" : "clarify"], method: "POST", body: body)
    }
    public func adoptLegacyConversation(sessionID: String, consumptions: [LegacyConsumption] = []) async throws -> Bool {
        struct Body: Encodable { let session_id: String; let consumptions: [LegacyConsumption] }
        struct Response: Decodable { let adopted: Bool }
        let body = try JSONEncoder().encode(Body(session_id: sessionID, consumptions: consumptions))
        return try JSONDecoder().decode(Response.self, from: await request(
            path: ["momo", "v1", "conversation", "adopt"], method: "POST", body: body)).adopted
    }
    public func resolveUnknown(run: AgentRun) async throws {
        guard let admission = run.admissionID, let generation = run.executionGeneration else { throw RemoteTaskStore.StoreError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["admission_id": admission, "execution_generation": generation])
        _ = try await request(path: ["v1", "runs", run.runID, "resolve-unknown"], method: "POST", body: body)
    }
    public func markConversationRead(through seq: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["through_seq": seq])
        _ = try await request(path: ["momo", "v1", "conversation", "read"], method: "POST", body: body)
    }
    public func workOverview(limit: Int = 15) async throws -> ConversationWorkOverview {
        let clamped = max(1, min(50, limit))
        let data = try await request(
            path: ["momo", "v1", "conversation", "works"],
            query: [.init(name: "limit", value: String(clamped))]
        )
        return try JSONDecoder().decode(ConversationWorkOverview.self, from: data)
    }
    public func workDetail(id: String) async throws -> ConversationWorkDetail {
        let data = try await request(path: ["momo", "v1", "conversation", "work", id])
        return try JSONDecoder().decode(ConversationWorkDetail.self, from: data)
    }
}
