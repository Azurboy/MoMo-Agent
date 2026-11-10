import Foundation

/// A resumable copy of an already sealed original, addressed to one receiver library.
public struct AudioBlock: Codable, Sendable {
    public static let version = 1
    public static let maximumLegacyPayloadBytes = 32 * 1024
    public static let maximumPayloadBytes = 44 * 1024
    public static let maximumWireBytes = 62 * 1024
    public static let maximumFileBytes: Int64 = 64 * 1024 * 1024
    public let protocolVersion: Int
    public let receiverDeviceID: UUID
    public let libraryInstanceID: UUID
    public let envelope: ManifestEnvelope
    public let offset: Int64
    public let payload: Data
    public let payloadSHA256: String

    private struct BinaryHeader: Codable {
        let protocolVersion: Int
        let receiverDeviceID: UUID
        let libraryInstanceID: UUID
        let envelope: ManifestEnvelope
        let offset: Int64
        let payloadSHA256: String
    }

    public init(receiverDeviceID: UUID, libraryInstanceID: UUID, envelope: ManifestEnvelope,
                offset: Int64, payload: Data) throws {
        protocolVersion = Self.version
        self.receiverDeviceID = receiverDeviceID; self.libraryInstanceID = libraryInstanceID
        self.envelope = envelope; self.offset = offset; self.payload = payload
        payloadSHA256 = ContentHash.sha256(payload)
        try validate()
    }

    public func binaryWireMetadata() throws -> [String: Any] {
        let header = try WireJSON.encode(BinaryHeader(
            protocolVersion: protocolVersion,
            receiverDeviceID: receiverDeviceID,
            libraryInstanceID: libraryInstanceID,
            envelope: envelope,
            offset: offset,
            payloadSHA256: payloadSHA256))
        guard header.count + payload.count <= Self.maximumWireBytes else {
            throw ContractError.invalidField("audio_block_wire")
        }
        return ["audio_block_header": header, "audio_block_payload": payload]
    }

    public init(binaryHeaderData: Data, payload: Data) throws {
        guard binaryHeaderData.count + payload.count <= Self.maximumWireBytes else {
            throw ContractError.invalidField("audio_block_wire")
        }
        let header = try WireJSON.decode(BinaryHeader.self, from: binaryHeaderData)
        self.protocolVersion = header.protocolVersion
        self.receiverDeviceID = header.receiverDeviceID
        self.libraryInstanceID = header.libraryInstanceID
        self.envelope = header.envelope
        self.offset = header.offset
        self.payload = payload
        self.payloadSHA256 = header.payloadSHA256
        try validate()
    }

    public func validate() throws {
        guard protocolVersion == Self.version else { throw ContractError.unsupportedVersion(protocolVersion) }
        try envelope.manifest.validate()
        guard envelope.manifest.representation == .full,
              envelope.manifest.byteCount <= Self.maximumFileBytes,
              offset >= 0, offset <= envelope.manifest.byteCount,
              payload.count <= Self.maximumPayloadBytes,
              Int64(payload.count) <= envelope.manifest.byteCount - offset,
              ContentHash.sha256(payload) == payloadSHA256 else {
            throw ContractError.invalidField("audio_block")
        }
    }
}

public struct AudioBlockReply: Codable, Sendable {
    public let protocolVersion: Int
    public let chunkID: UUID
    public let manifestSHA256: String
    public let nextOffset: Int64
    /// Only Archive's committed receipt can confirm the original. An offset cannot.
    public let receipt: Receipt?

    public init(block: AudioBlock, nextOffset: Int64, receipt: Receipt? = nil) {
        protocolVersion = AudioBlock.version
        chunkID = block.envelope.manifest.chunkID; manifestSHA256 = block.envelope.manifestSHA256
        self.nextOffset = nextOffset; self.receipt = receipt
    }

    public func validate(for block: AudioBlock) throws {
        guard protocolVersion == AudioBlock.version, chunkID == block.envelope.manifest.chunkID,
              manifestSHA256 == block.envelope.manifestSHA256,
              nextOffset >= 0, nextOffset <= block.envelope.manifest.byteCount else {
            throw ContractError.invalidField("audio_block_reply")
        }
        if let receipt {
            guard receipt.matches(block.envelope), receipt.receiverDeviceID == block.receiverDeviceID,
                  receipt.libraryInstanceID == block.libraryInstanceID,
                  nextOffset == block.envelope.manifest.byteCount else {
                throw ContractError.invalidField("audio_block_receipt")
            }
        } else if nextOffset == block.envelope.manifest.byteCount {
            throw ContractError.invalidField("audio_block_missing_receipt")
        }
    }
}
