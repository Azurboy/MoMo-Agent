import Foundation

/// MoMo session transcript API.
public struct AgentSessionMessages: Decodable, Sendable {
    public struct Message: Decodable, Sendable {
        public let id: Int
        public let role: String
        public let displayKind: String?
        enum CodingKeys: String, CodingKey { case id, role; case displayKind = "display_kind" }
    }
    public let data: [Message]
}

extension AgentClient {
    public func sessionMessages(sessionID: String) async throws -> AgentSessionMessages {
        return try JSONDecoder().decode(AgentSessionMessages.self, from: await request(
            path: ["api", "sessions", sessionID, "messages"], query: [
                .init(name: "limit", value: "100"), .init(name: "offset", value: "0"),
                .init(name: "order", value: "latest")
            ]))
    }
}
