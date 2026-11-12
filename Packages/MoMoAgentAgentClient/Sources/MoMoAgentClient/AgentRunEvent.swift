import Foundation

/// Only public assistant text and execution lifecycle are presented, never reasoning events.
public struct AgentRunEvent: Decodable, Sendable {
    public let event: String
    public let runID: String
    public let seq: Int?
    public let delta: String?
    public let text: String?
    public let tool: String?
    public let toolCallID: String?
    public let toolFailed: Bool
    public let message: ConversationMessage?
    public let input: ConversationMessage?
    public let receipt: AgentRun?
    enum CodingKeys: String, CodingKey { case event, seq, delta, text, tool, error, message, input, receipt; case runID = "run_id"; case toolCallID = "tool_call_id" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(String.self, forKey: .event); runID = try values.decode(String.self, forKey: .runID)
        seq = try values.decodeIfPresent(Int.self, forKey: .seq)
        delta = try values.decodeIfPresent(String.self, forKey: .delta); text = try values.decodeIfPresent(String.self, forKey: .text)
        tool = try values.decodeIfPresent(String.self, forKey: .tool); toolCallID = try values.decodeIfPresent(String.self, forKey: .toolCallID)
        // Run failures carry text in this field; only tool.completed uses a boolean.
        toolFailed = (try? values.decode(Bool.self, forKey: .error)) == true
        message = try values.decodeIfPresent(ConversationMessage.self, forKey: .message)
        input = try values.decodeIfPresent(ConversationMessage.self, forKey: .input)
        receipt = try values.decodeIfPresent(AgentRun.self, forKey: .receipt)
    }
}

struct RunEventParser {
    private var frames = SSEFrameParser()
    mutating func append(_ byte: UInt8) throws -> AgentRunEvent? {
        guard let frame = try frames.append(byte) else { return nil }
        return try JSONDecoder().decode(AgentRunEvent.self, from: frame)
    }
}

struct SSEFrameParser {
    var maximumBytes = 512 * 1024
    private var line = Data()
    private var payload = Data()
    mutating func append(_ byte: UInt8) throws -> Data? {
        guard line.count + payload.count < maximumBytes else { throw AgentClientError.invalidResponse }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !payload.isEmpty else { return nil }
            defer { payload.removeAll(keepingCapacity: true) }
            return payload
        }
        guard line.starts(with: Data("data:".utf8)) else { return nil }
        var value = line.dropFirst(5)
        if value.first == 32 { value = value.dropFirst() }
        if !payload.isEmpty { payload.append(10) }
        payload.append(contentsOf: value)
        return nil
    }
}

public struct RemoteReply: Codable, Sendable, Equatable {
    public struct ToolActivity: Codable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let callID: String?
        public fileprivate(set) var state: String
    }
    public private(set) var sequence: Int?
    public private(set) var messages: [String] = []
    public private(set) var partial = ""
    public private(set) var hasStartedWork = false
    public private(set) var historyIncomplete = false
    public var streamUnavailable = false
    // Optional so journals from earlier releases remain readable.
    public private(set) var tools: [ToolActivity]?
    public private(set) var phase: String?
    public var hasText: Bool { !messages.isEmpty || !partial.isEmpty }

    mutating func apply(_ event: AgentRunEvent) {
        if event.event == "replay.truncated" { historyIncomplete = true; partial = ""; return }
        guard let seq = event.seq, seq >= 0, seq > (sequence ?? -1) else { return }
        sequence = seq
        switch event.event {
        case "message.delta": partial += event.delta ?? ""; phase = "writing"
        case "message.interim":
            // The gateway sends the whole interim text even if deltas already streamed it.
            let text = event.text ?? partial
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append(text) }
            partial = ""
            phase = "replied"
        case "tool.started":
            hasStartedWork = true; phase = "working"
            if tools == nil { tools = [] }
            tools?.append(ToolActivity(id: seq, name: event.tool ?? "tool", callID: event.toolCallID, state: "running"))
        case "tool.completed", "tool.failed":
            if let index = tools?.lastIndex(where: { $0.name == event.tool && $0.state == "running" && (event.toolCallID == nil || $0.callID == event.toolCallID) }) {
                tools?[index].state = event.event == "tool.failed" || event.toolFailed ? "failed" : "succeeded"
            }
            if tools?.contains(where: { $0.state == "running" }) != true { phase = "waiting" }
        case "run.completed", "run.failed", "run.cancelled", "run.interrupted": partial = ""; phase = "finished"
        default: break
        }
    }
}
