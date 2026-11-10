import Foundation

public enum DeviceRole: String, Codable, Sendable { case watch, phone }
public enum WatchCaptureActivity: String, Codable, Sendable {
    case idle, preparing, recording, paused, interrupted, stopped, failed
}

/// Observed capture and queue state. It never grants receipt or deletion authority.
public struct WatchCaptureStatus: Codable, Equatable, Sendable {
    public let receiverLibraryInstanceID: UUID?
    public let sessionID: UUID?
    public let epochID: UUID?
    public let activity: WatchCaptureActivity
    public let capturedDuration: TimeInterval
    public let sealedDuration: TimeInterval
    public let pendingChunkCount: Int
    public let pendingBytes: Int64
    public let lastSampleFrame: Int64?
    public let timebaseHz: Double?
    public let lastSampleAge: TimeInterval?
    /// Capability for explicit viewing requests; absent in older Watch builds.
    public let audioBatchVersion: Int?

    public init(receiverLibraryInstanceID: UUID?, sessionID: UUID?, epochID: UUID?, activity: WatchCaptureActivity,
                capturedDuration: TimeInterval, sealedDuration: TimeInterval, pendingChunkCount: Int, pendingBytes: Int64,
                lastSampleFrame: Int64? = nil, timebaseHz: Double? = nil, lastSampleAge: TimeInterval? = nil,
                audioBatchVersion: Int? = nil) throws {
        self.receiverLibraryInstanceID = receiverLibraryInstanceID; self.sessionID = sessionID; self.epochID = epochID
        self.activity = activity; self.capturedDuration = capturedDuration; self.sealedDuration = sealedDuration
        self.pendingChunkCount = pendingChunkCount; self.pendingBytes = pendingBytes
        self.lastSampleFrame = lastSampleFrame; self.timebaseHz = timebaseHz; self.lastSampleAge = lastSampleAge
        self.audioBatchVersion = audioBatchVersion
        try validate()
    }

    public func validate() throws {
        guard capturedDuration.isFinite, capturedDuration >= 0, sealedDuration.isFinite, sealedDuration >= 0,
              sealedDuration <= capturedDuration + 0.000_001, pendingChunkCount >= 0, pendingBytes >= 0,
              lastSampleFrame.map({ $0 >= 0 }) ?? true,
              timebaseHz.map({ $0.isFinite && $0 > 0 }) ?? true,
              lastSampleAge.map({ $0.isFinite && $0 >= 0 }) ?? true,
              audioBatchVersion.map({ $0 > 0 }) ?? true,
              (lastSampleFrame == nil) == (timebaseHz == nil),
              epochID == nil || sessionID != nil,
              lastSampleFrame == nil || epochID != nil,
              sessionID != nil || (capturedDuration == 0 && sealedDuration == 0 && activity == .idle) else {
            throw ContractError.invalidField("watch_status")
        }
        if activity == .recording, epochID == nil || lastSampleFrame == nil {
            throw ContractError.invalidField("watch_recording_sample")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case receiverLibraryInstanceID, sessionID, epochID, activity, capturedDuration, sealedDuration
        case pendingChunkCount, pendingBytes, lastSampleFrame, timebaseHz, lastSampleAge, audioBatchVersion
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(receiverLibraryInstanceID: c.decodeIfPresent(UUID.self, forKey: .receiverLibraryInstanceID),
                      sessionID: c.decodeIfPresent(UUID.self, forKey: .sessionID), epochID: c.decodeIfPresent(UUID.self, forKey: .epochID),
                      activity: c.decode(WatchCaptureActivity.self, forKey: .activity), capturedDuration: c.decode(Double.self, forKey: .capturedDuration),
                      sealedDuration: c.decode(Double.self, forKey: .sealedDuration), pendingChunkCount: c.decode(Int.self, forKey: .pendingChunkCount),
                      pendingBytes: c.decode(Int64.self, forKey: .pendingBytes), lastSampleFrame: c.decodeIfPresent(Int64.self, forKey: .lastSampleFrame),
                      timebaseHz: c.decodeIfPresent(Double.self, forKey: .timebaseHz), lastSampleAge: c.decodeIfPresent(Double.self, forKey: .lastSampleAge),
                      audioBatchVersion: c.decodeIfPresent(Int.self, forKey: .audioBatchVersion))
    }
}

public struct LocalSyncEndpoint: Codable, Equatable, Sendable {
    public let baseURLs: [String]
    public let bearerToken: String

    public init(baseURLs: [String], bearerToken: String) throws {
        let cleaned = baseURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...8).contains(cleaned.count),
              (32...128).contains(bearerToken.utf8.count),
              bearerToken.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw ContractError.invalidField("local_sync_endpoint")
        }
        for raw in cleaned {
            guard raw.utf8.count <= 256,
                  let comps = URLComponents(string: raw),
                  comps.scheme == "http",
                  let host = comps.host, !host.isEmpty,
                  let port = comps.port, (1...65_535).contains(port),
                  comps.path.isEmpty || comps.path == "/" else {
                throw ContractError.invalidField("local_sync_url")
            }
        }
        self.baseURLs = cleaned
        self.bearerToken = bearerToken
    }
}

public struct PhoneArchiveStatus: Codable, Equatable, Sendable {
    public let libraryInstanceID: UUID
    public let recordingCount: Int
    public let pendingAnalysisCount: Int
    public let pendingReceiptCount: Int
    public let audioBlockVersion: Int?
    public let binaryAudioBlocks: Bool?
    public let localSync: LocalSyncEndpoint?
    public init(libraryInstanceID: UUID, recordingCount: Int, pendingAnalysisCount: Int, pendingReceiptCount: Int,
                audioBlockVersion: Int? = nil, binaryAudioBlocks: Bool? = nil, localSync: LocalSyncEndpoint? = nil) throws {
        guard recordingCount >= 0, pendingAnalysisCount >= 0, pendingReceiptCount >= 0 else {
            throw ContractError.invalidField("phone_status_counts")
        }
        self.libraryInstanceID = libraryInstanceID; self.recordingCount = recordingCount
        self.pendingAnalysisCount = pendingAnalysisCount; self.pendingReceiptCount = pendingReceiptCount
        self.audioBlockVersion = audioBlockVersion
        self.binaryAudioBlocks = binaryAudioBlocks
        self.localSync = localSync
    }
    private enum CodingKeys: String, CodingKey {
        case libraryInstanceID, recordingCount, pendingAnalysisCount, pendingReceiptCount
        case audioBlockVersion, binaryAudioBlocks, localSync
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(libraryInstanceID: c.decode(UUID.self, forKey: .libraryInstanceID), recordingCount: c.decode(Int.self, forKey: .recordingCount),
                      pendingAnalysisCount: c.decode(Int.self, forKey: .pendingAnalysisCount), pendingReceiptCount: c.decode(Int.self, forKey: .pendingReceiptCount),
                      audioBlockVersion: c.decodeIfPresent(Int.self, forKey: .audioBlockVersion),
                      binaryAudioBlocks: c.decodeIfPresent(Bool.self, forKey: .binaryAudioBlocks),
                      localSync: c.decodeIfPresent(LocalSyncEndpoint.self, forKey: .localSync))
    }
}

public enum StatusPayload: Codable, Equatable, Sendable {
    case watch(WatchCaptureStatus)
    case phone(PhoneArchiveStatus)
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 15 * 1024
    public let protocolVersion: Int
    public let sourceDeviceID: UUID
    public let sourceBuild: String
    public let sourceStoreInstanceID: UUID
    public let revision: Int64
    public let sampledAt: Date
    public let payload: StatusPayload
    public var sourceRole: DeviceRole {
        switch payload { case .watch: .watch; case .phone: .phone }
    }

    public init(protocolVersion: Int = 1, sourceDeviceID: UUID, sourceBuild: String, sourceStoreInstanceID: UUID,
                revision: Int64, sampledAt: Date = Date(), payload: StatusPayload) throws {
        self.protocolVersion = protocolVersion; self.sourceDeviceID = sourceDeviceID; self.sourceBuild = sourceBuild
        self.sourceStoreInstanceID = sourceStoreInstanceID; self.revision = revision; self.sampledAt = sampledAt; self.payload = payload
        try validate()
    }

    public func validate() throws {
        guard protocolVersion == 1 else { throw ContractError.unsupportedVersion(protocolVersion) }
        guard !sourceBuild.isEmpty, sourceBuild.utf8.count <= 256, revision > 0, sampledAt.timeIntervalSince1970.isFinite else {
            throw ContractError.invalidField("status_snapshot")
        }
        switch payload {
        case .watch(let value): try value.validate()
        case .phone(let value):
            guard value.libraryInstanceID == sourceStoreInstanceID else { throw ContractError.invalidField("status_phone_library") }
        }
        guard try WireJSON.encode(self).count <= Self.maximumEncodedBytes else { throw ContractError.invalidField("status_snapshot_bytes") }
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, sourceDeviceID, sourceBuild, sourceStoreInstanceID, revision, sampledAt, payload }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(protocolVersion: c.decode(Int.self, forKey: .protocolVersion), sourceDeviceID: c.decode(UUID.self, forKey: .sourceDeviceID),
                      sourceBuild: c.decode(String.self, forKey: .sourceBuild), sourceStoreInstanceID: c.decode(UUID.self, forKey: .sourceStoreInstanceID),
                      revision: c.decode(Int64.self, forKey: .revision), sampledAt: c.decode(Date.self, forKey: .sampledAt), payload: c.decode(StatusPayload.self, forKey: .payload))
    }
}
