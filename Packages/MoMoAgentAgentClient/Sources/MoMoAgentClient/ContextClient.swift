import Foundation
import CryptoKit

public struct SourceEnvelope: Codable, Sendable, Equatable {
    public struct PendingTranscriptionRange: Codable, Sendable, Equatable {
        public let start: Double
        public let end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }
    public struct Span: Codable, Sendable, Equatable {
        public let id: String
        public let text: String
        public let recordedAt: Double
        public let isOwner: Bool?
        public init(id: UUID, text: String, recordedAt: Date, isOwner: Bool? = nil) {
            self.id = id.uuidString.lowercased()
            self.text = text
            self.recordedAt = recordedAt.timeIntervalSince1970
            self.isOwner = isOwner
        }
    }
    public let libraryId: String
    public let sessionId: String
    public let deviceId: String
    public let generation: Int64
    public let version: Int64
    public let deleted: Bool
    public let recordedAt: Double
    public let spans: [Span]
    public let textSha256: String
    public var pendingTranscriptionRanges: [PendingTranscriptionRange]?
    public var sourceID: String { libraryId + "/" + sessionId }
    public init(library: UUID, session: UUID, device: UUID, generation: Int64, version: Int64,
                deleted: Bool = false, recordedAt: Date, spans: [Span], pendingTranscriptionRanges: [PendingTranscriptionRange]? = nil) {
        libraryId = library.uuidString.lowercased(); sessionId = session.uuidString.lowercased()
        deviceId = device.uuidString.lowercased(); self.generation = generation; self.version = version
        self.deleted = deleted; self.recordedAt = recordedAt.timeIntervalSince1970; self.spans = spans
        textSha256 = SHA256.hash(data: Data(spans.map(\.text).joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        self.pendingTranscriptionRanges = pendingTranscriptionRanges
    }
    public func tombstone() -> SourceEnvelope {
        SourceEnvelope(library: UUID(uuidString: libraryId)!, session: UUID(uuidString: sessionId)!,
                       device: UUID(uuidString: deviceId)!, generation: generation + 1, version: 0, deleted: true,
                       recordedAt: Date(timeIntervalSince1970: recordedAt), spans: [], pendingTranscriptionRanges: [])
    }
}

public struct SourceReceipt: Codable, Sendable {
    public let sourceId: String
    public let sourceRevision: String
    public let revision: Int64
}
public struct SpeakerRelabelInstruction: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceId: String
    public let sessionId: String
    public let spanIds: [String]
    public let newSpeaker: String
    public let isOwner: Bool
    public let scope: String
    public let reason: String
}
public struct DreamTriggerReceipt: Codable, Sendable {
    public let jobId: String
    public let state: String
    public let enqueued: Bool
}
public struct ContextStatus: Codable, Sendable {
    public let workspaceId: UUID
    public let sourceSync: Bool
    public let memoryWriter: String
    public let memoryPending: Int?
    public let memoryNeedsReview: Int?
    public let memoryReview: MemoryReviewStatus?
    public let speakerRelabels: [SpeakerRelabelInstruction]?
}
public struct MemoryReviewStatus: Codable, Sendable {
    public struct Dream: Codable, Sendable { public let at: Double }
    public let enabled: Bool
    public let running: Bool
    public let lastUpdated: Double?
    public let pending: Int
    public let needsReview: Int
    public let dream: Dream?
}
public struct ContextMemory: Codable, Sendable, Identifiable {
    public struct Evidence: Codable, Sendable {
        public let sourceId: String
        public let sourceRevision: String
        public let quote: String
        public let recordedAt: Double?
    }
    public let id: String
    public let text: String
    public let kind: String
    public let basis: String
    public let status: String
    public let revision: Int64
    public let evidence: [Evidence]
}
public struct MemoryPage: Codable, Sendable {
    public let revision: Int64
    public let items: [ContextMemory]
    public let nextCursor: String?
}
public struct ForgetMemory: Codable, Sendable {
    public let id: String
    public let operationId: UUID
    public let baseRevision: Int64
    public init(memory: ContextMemory) { id = memory.id; operationId = UUID(); baseRevision = memory.revision }
}

extension AgentClient {
    public func contextStatus() async throws -> ContextStatus {
        try decodeContext(await request(path: ["v1", "status"]))
    }
    public func syncSource(_ source: SourceEnvelope) async throws -> SourceReceipt {
        try decodeContext(await request(path: ["v1", "sources"], method: "POST", body: encodeContext(source)))
    }
    public func memories(after: String? = nil, revision: Int64? = nil, limit: Int = 100) async throws -> MemoryPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        if let revision { query.append(URLQueryItem(name: "revision", value: String(revision))) }
        return try decodeContext(await request(path: ["v1", "memories"], query: query))
    }
    public func forget(_ mutation: ForgetMemory) async throws {
        _ = try await request(path: ["v1", "memories", "forget"], method: "POST", body: encodeContext(mutation))
    }
    public func triggerDream() async throws -> DreamTriggerReceipt {
        struct Empty: Encodable {}
        return try decodeContext(await request(path: ["v1", "memories", "dream"], method: "POST", body: encodeContext(Empty())))
    }
    public func acknowledgeSpeakerRelabels(ids: [String]) async throws {
        struct Input: Encodable { let ids: [String] }
        _ = try await request(path: ["v1", "speakers", "ack"], method: "POST", body: encodeContext(Input(ids: ids)))
    }
    private func decodeContext<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    private func encodeContext<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
}

public struct ContextSourceWindow: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceId: String
    public let sourceRevision: String
    public let recordedAt: Double?
    public let endAt: Double?
    public let offset: Int
    public let end: Int
    public let totalCharacters: Int
    public let summary: String?
    public let preview: String?

    public init(
        id: String,
        sourceId: String,
        sourceRevision: String,
        recordedAt: Double?,
        endAt: Double?,
        offset: Int,
        end: Int,
        totalCharacters: Int,
        summary: String?,
        preview: String?
    ) {
        self.id = id
        self.sourceId = sourceId
        self.sourceRevision = sourceRevision
        self.recordedAt = recordedAt
        self.endAt = endAt
        self.offset = offset
        self.end = end
        self.totalCharacters = totalCharacters
        self.summary = summary
        self.preview = preview
    }
}
public struct ContextSource: Decodable, Sendable, Identifiable {
    public struct Organization: Decodable, Sendable { public let state: String; public let error: String? }
    public let id: String
    public let revision: String
    public let recordedAt: Double?
    public let totalCharacters: Int
    public let summary: String?
    public let preview: String?
    public let organization: Organization?
    public let windows: [ContextSourceWindow]?
}
public struct SourcePage: Decodable, Sendable {
    public let items: [ContextSource]
    public let nextCursor: String?
}
public struct SourceTextSpan: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let recordedAt: Double?
    public let text: String?
    public let citationUrl: String?
}
public struct SourceTextPage: Decodable, Sendable {
    public let sourceRevision: String
    public let text: String
    public let offset: Int
    public let end: Int
    public let totalCharacters: Int
    public let nextOffset: Int?
    public let spans: [SourceTextSpan]?
}
extension AgentClient {
    public func sources(after: String? = nil, summarize: Bool = false, limit: Int? = nil) async throws -> SourcePage {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        if summarize { query.append(URLQueryItem(name: "summarize", value: "1")) }
        return try decodeContext(await request(path: ["v1", "sources"], query: query))
    }
    public func sourceText(_ source: ContextSource, offset: Int = 0, limit: Int? = nil) async throws -> SourceTextPage {
        var query = [
            URLQueryItem(name: "source_id", value: source.id),
            URLQueryItem(name: "revision", value: source.revision),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try decodeContext(await request(path: ["v1", "source"], query: query))
    }
}
