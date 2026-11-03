import Foundation

/// Execution facts only. Grouping, labels, Markdown layout and animation belong to the client.
public struct AgentChatMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let turnID: String
    public let role: String
    public let blocks: [AgentMessageBlock]
    public let state: AgentMessageState
    public var sentAt: Date?

    public var text: String {
        blocks.compactMap { if case .text(let text) = $0.content { text } else { nil } }.joined()
    }

    public init(id: String, turnID: String, role: String, blocks: [AgentMessageBlock], state: AgentMessageState, sentAt: Date? = nil) {
        self.id = id; self.turnID = turnID; self.role = role; self.blocks = blocks; self.state = state; self.sentAt = sentAt
    }
}

public enum AgentMessageState: String, Equatable, Sendable {
    case streaming, complete, stopped, failed, truncated
}

public struct AgentMessageBlock: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(String)
        case attachment(AgentAttachment)
        case reasoning(String, redacted: Bool)
        case tool(AgentToolExecution)
    }
    public let id: String
    public let content: Content

    public init(id: String, content: Content) { self.id = id; self.content = content }
}

/// Actual checkpoints reached inside a running tool; never an elapsed-time estimate.
public struct AgentToolProgress: Codable, Equatable, Sendable {
    public let completedUnitCount: UInt32
    public init(completedUnitCount: UInt32) { self.completedUnitCount = completedUnitCount }
}

public struct AgentToolExecution: Identifiable, Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, running, succeeded, failed, interrupted }
    public let id: String
    public let name: String
    /// JSON data, never an SDK type or a display label.
    public let input: String
    public let output: String?
    public let state: State
    public let progress: AgentToolProgress?

    public init(id: String, name: String, input: String, output: String?, state: State, progress: AgentToolProgress? = nil) {
        self.id = id; self.name = name; self.input = input; self.output = output; self.state = state; self.progress = progress
    }
}

public enum AgentContextState: String, Sendable {
    case idle, compacting, compacted, failed
}
