import Foundation

public enum ReconciliationLimits {
    // Leaves room for a full Receipt per result inside the 16 KiB control envelope.
    public static let maximumItems = 16
    public static let maximumEncodedBytes = 15 * 1024
}

public struct ReconcileChunkIdentity: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let chunkID: UUID
    public let audioSHA256: String
    public let manifestSHA256: String
    public let representation: RepresentationKind

    public init(sessionID: UUID, chunkID: UUID, audioSHA256: String, manifestSHA256: String,
                representation: RepresentationKind = .full) throws {
        guard ContentHash.isValid(audioSHA256), ContentHash.isValid(manifestSHA256), representation == .full else {
            throw ContractError.invalidField("reconcile_chunk_identity")
        }
        self.sessionID = sessionID; self.chunkID = chunkID; self.audioSHA256 = audioSHA256
        self.manifestSHA256 = manifestSHA256; self.representation = representation
    }

    public init(envelope: ManifestEnvelope) throws {
        try self.init(sessionID: envelope.manifest.sessionID, chunkID: envelope.manifest.chunkID,
                      audioSHA256: envelope.manifest.audioSHA256, manifestSHA256: envelope.manifestSHA256,
                      representation: envelope.manifest.representation)
    }

    public func matches(_ receipt: Receipt) -> Bool {
        chunkID == receipt.chunkID && audioSHA256 == receipt.audioSHA256
            && manifestSHA256 == receipt.manifestSHA256 && representation == receipt.representation
    }

    private enum CodingKeys: String, CodingKey { case sessionID, chunkID, audioSHA256, manifestSHA256, representation }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionID: c.decode(UUID.self, forKey: .sessionID), chunkID: c.decode(UUID.self, forKey: .chunkID),
                      audioSHA256: c.decode(String.self, forKey: .audioSHA256), manifestSHA256: c.decode(String.self, forKey: .manifestSHA256),
                      representation: c.decode(RepresentationKind.self, forKey: .representation))
    }
}

public struct ReconcileRequest: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let sourceDeviceID: UUID
    public let receiverDeviceID: UUID
    public let libraryInstanceID: UUID
    public let items: [ReconcileChunkIdentity]
    public var requestSHA256: String { get throws { ContentHash.sha256(try WireJSON.encode(self)) } }

    public init(messageID: UUID = UUID(), sourceDeviceID: UUID, receiverDeviceID: UUID,
                libraryInstanceID: UUID, items: [ReconcileChunkIdentity]) throws {
        try self.init(messageID: messageID, sourceDeviceID: sourceDeviceID, receiverDeviceID: receiverDeviceID,
                      libraryInstanceID: libraryInstanceID, items: items, validateEncodedSize: true)
    }

    private init(messageID: UUID, sourceDeviceID: UUID, receiverDeviceID: UUID,
                 libraryInstanceID: UUID, items: [ReconcileChunkIdentity], validateEncodedSize: Bool) throws {
        guard !items.isEmpty, items.count <= ReconciliationLimits.maximumItems,
              Set(items.map(\.chunkID)).count == items.count else { throw ContractError.invalidField("reconcile_items") }
        self.messageID = messageID; self.sourceDeviceID = sourceDeviceID
        self.receiverDeviceID = receiverDeviceID; self.libraryInstanceID = libraryInstanceID; self.items = items
        if validateEncodedSize {
            guard try WireJSON.encode(self).count <= ReconciliationLimits.maximumEncodedBytes else {
                throw ContractError.invalidField("reconcile_request_bytes")
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case messageID, sourceDeviceID, receiverDeviceID, libraryInstanceID, items }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID), sourceDeviceID: c.decode(UUID.self, forKey: .sourceDeviceID),
                      receiverDeviceID: c.decode(UUID.self, forKey: .receiverDeviceID), libraryInstanceID: c.decode(UUID.self, forKey: .libraryInstanceID),
                      items: c.decode([ReconcileChunkIdentity].self, forKey: .items), validateEncodedSize: false)
    }
}

public enum ReconcileItemState: Codable, Equatable, Sendable {
    case received(Receipt)
    case unknown, missing, expired, conflict
    case deleted(DeleteSession)
}

public struct ReconcileResult: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let state: ReconcileItemState
    public init(chunkID: UUID, state: ReconcileItemState) throws {
        if case .received(let receipt) = state, receipt.chunkID != chunkID {
            throw ContractError.invalidField("reconcile_result_chunk")
        }
        self.chunkID = chunkID; self.state = state
    }
    private enum CodingKeys: String, CodingKey { case chunkID, state }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chunkID: c.decode(UUID.self, forKey: .chunkID), state: c.decode(ReconcileItemState.self, forKey: .state))
    }
}

public struct ReconcileResponse: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let requestID: UUID
    public let requestSHA256: String
    public let sourceDeviceID: UUID
    public let receiverDeviceID: UUID
    public let libraryInstanceID: UUID
    public let results: [ReconcileResult]

    public init(messageID: UUID = UUID(), requestID: UUID, requestSHA256: String, sourceDeviceID: UUID,
                receiverDeviceID: UUID, libraryInstanceID: UUID, results: [ReconcileResult]) throws {
        try self.init(messageID: messageID, requestID: requestID, requestSHA256: requestSHA256,
                      sourceDeviceID: sourceDeviceID, receiverDeviceID: receiverDeviceID,
                      libraryInstanceID: libraryInstanceID, results: results, validateEncodedSize: true)
    }

    private init(messageID: UUID, requestID: UUID, requestSHA256: String, sourceDeviceID: UUID,
                 receiverDeviceID: UUID, libraryInstanceID: UUID, results: [ReconcileResult], validateEncodedSize: Bool) throws {
        guard ContentHash.isValid(requestSHA256), !results.isEmpty, results.count <= ReconciliationLimits.maximumItems,
              Set(results.map(\.chunkID)).count == results.count else { throw ContractError.invalidField("reconcile_results") }
        for result in results {
            if case .received(let receipt) = result.state {
                guard receipt.receiverDeviceID == receiverDeviceID, receipt.libraryInstanceID == libraryInstanceID else {
                    throw ContractError.invalidField("reconcile_receipt_receiver")
                }
            }
        }
        self.messageID = messageID; self.requestID = requestID; self.requestSHA256 = requestSHA256
        self.sourceDeviceID = sourceDeviceID; self.receiverDeviceID = receiverDeviceID
        self.libraryInstanceID = libraryInstanceID; self.results = results
        if validateEncodedSize {
            guard try WireJSON.encode(self).count <= ReconciliationLimits.maximumEncodedBytes else {
                throw ContractError.invalidField("reconcile_response_bytes")
            }
        }
    }

    public func matches(_ request: ReconcileRequest) throws -> Bool {
        guard requestID == request.messageID, requestSHA256 == (try request.requestSHA256),
              sourceDeviceID == request.sourceDeviceID, receiverDeviceID == request.receiverDeviceID,
              libraryInstanceID == request.libraryInstanceID, results.count == request.items.count else { return false }
        let items = Dictionary(uniqueKeysWithValues: request.items.map { ($0.chunkID, $0) })
        for result in results {
            guard let item = items[result.chunkID] else { return false }
            switch result.state {
            case .received(let receipt): if !item.matches(receipt) { return false }
            case .deleted(let deletion):
                if deletion.sessionID != item.sessionID { return false }
                if let device = deletion.receiverDeviceID, let library = deletion.libraryInstanceID,
                   device != receiverDeviceID || library != libraryInstanceID { return false }
            default: break
            }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case messageID, requestID, requestSHA256, sourceDeviceID, receiverDeviceID, libraryInstanceID, results
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(UUID.self, forKey: .messageID), requestID: c.decode(UUID.self, forKey: .requestID),
                      requestSHA256: c.decode(String.self, forKey: .requestSHA256), sourceDeviceID: c.decode(UUID.self, forKey: .sourceDeviceID),
                      receiverDeviceID: c.decode(UUID.self, forKey: .receiverDeviceID), libraryInstanceID: c.decode(UUID.self, forKey: .libraryInstanceID),
                      results: c.decode([ReconcileResult].self, forKey: .results), validateEncodedSize: false)
    }
}
