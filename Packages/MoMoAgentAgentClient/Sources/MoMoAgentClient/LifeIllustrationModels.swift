import Foundation

public struct LifeIllustrationSettings: Codable, Equatable, Sendable {
    public static let allowedIntervals = [2, 3, 4, 6]
    public var enabled = false
    public var intervalHours = 3
    public var dayStartHour = 8
    public var provider: String?
    public var supported = false
    public var serviceStatus = "unknown"
    public var updatedAt: Double = 0
    public var pendingCount = 0
    public var needsReviewCount = 0

    public init() {}

    public var canDisplayIllustrations: Bool {
        supported && provider == "openai-codex" && serviceStatus == "ready"
    }
}

/// Only completed server artifacts enter the timeline. Times are Unix seconds.
public struct LifeIllustrationRoutePoint: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Double
    public let endTimestamp: Double?
    public let kind: String
    public let title: String?

    public init(latitude: Double, longitude: Double, timestamp: Double, endTimestamp: Double? = nil,
                kind: String, title: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.kind = kind
        self.title = title
    }

    var isValid: Bool {
        Self.validCoordinate(latitude, longitude) && timestamp.isFinite
            && (endTimestamp.map { $0.isFinite && $0 >= timestamp } ?? true)
            && ["visit", "waypoint"].contains(kind)
    }

    static func validCoordinate(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct LifeIllustration: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let windowStart: Double
    public let windowEnd: Double
    public let logicalDay: String
    public let timezone: String
    public let place: String?
    public let summary: String?
    public let latitude: Double?
    public let longitude: Double?
    public let placeStart: Double?
    public let placeEnd: Double?
    public let routePoints: [LifeIllustrationRoutePoint]
    public let assetSha256: String
    public let thumbnailSha256: String
    public let width: Int
    public let height: Int
    public let sourceIds: [String]
    public let createdAt: Double
    public let updatedAt: Double

    public init(id: String, windowStart: Double, windowEnd: Double, logicalDay: String, timezone: String,
                place: String?, assetSha256: String, thumbnailSha256: String, width: Int, height: Int,
                sourceIds: [String], createdAt: Double, updatedAt: Double,
                summary: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                placeStart: Double? = nil, placeEnd: Double? = nil, routePoints: [LifeIllustrationRoutePoint] = []) {
        self.id = id; self.windowStart = windowStart; self.windowEnd = windowEnd
        self.logicalDay = logicalDay; self.timezone = timezone; self.place = place
        self.assetSha256 = assetSha256; self.thumbnailSha256 = thumbnailSha256
        self.width = width; self.height = height; self.sourceIds = sourceIds
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.summary = summary
        self.latitude = latitude
        self.longitude = longitude
        self.placeStart = placeStart
        self.placeEnd = placeEnd
        self.routePoints = routePoints
    }

    private enum CodingKeys: String, CodingKey {
        case id, windowStart, windowEnd, logicalDay, timezone, place, summary, latitude, longitude
        case placeStart, placeEnd, routePoints, assetSha256, thumbnailSha256, width, height, sourceIds, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        windowStart = try values.decode(Double.self, forKey: .windowStart)
        windowEnd = try values.decode(Double.self, forKey: .windowEnd)
        logicalDay = try values.decode(String.self, forKey: .logicalDay)
        timezone = try values.decode(String.self, forKey: .timezone)
        place = try values.decodeIfPresent(String.self, forKey: .place)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        placeStart = try values.decodeIfPresent(Double.self, forKey: .placeStart)
        placeEnd = try values.decodeIfPresent(Double.self, forKey: .placeEnd)
        routePoints = try values.decodeIfPresent([LifeIllustrationRoutePoint].self, forKey: .routePoints) ?? []
        assetSha256 = try values.decode(String.self, forKey: .assetSha256)
        thumbnailSha256 = try values.decode(String.self, forKey: .thumbnailSha256)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        sourceIds = try values.decode([String].self, forKey: .sourceIds)
        createdAt = try values.decode(Double.self, forKey: .createdAt)
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
    }

    func validate() throws {
        guard !id.isEmpty, windowStart.isFinite, windowEnd.isFinite, windowEnd > windowStart,
              createdAt.isFinite, updatedAt.isFinite, width > 0, height > 0,
              !logicalDay.isEmpty, TimeZone(identifier: timezone) != nil,
              !sourceIds.isEmpty, sourceIds.allSatisfy({ !$0.isEmpty }),
              Self.isSHA256(assetSha256), Self.isSHA256(thumbnailSha256),
              validPlace, routePoints.count <= 128, routePoints.allSatisfy(\.isValid) else {
            throw LifeIllustrationError.invalidManifest
        }
    }

    private var validPlace: Bool {
        if let latitude, let longitude {
            guard LifeIllustrationRoutePoint.validCoordinate(latitude, longitude) else { return false }
        } else if latitude != nil || longitude != nil { return false }
        if let placeStart, let placeEnd {
            return placeStart.isFinite && placeEnd.isFinite && placeEnd > placeStart && latitude != nil
        }
        return placeStart == nil && placeEnd == nil
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct LifeIllustrationTombstone: Codable, Equatable, Sendable {
    public let id: String
    public let deleted: Bool
    public let updatedAt: Double
}

public enum LifeIllustrationChange: Codable, Equatable, Sendable {
    case illustration(LifeIllustration)
    case tombstone(LifeIllustrationTombstone)

    public init(from decoder: any Decoder) throws {
        let marker = try LifeIllustrationTombstone(from: decoder)
        if marker.deleted { self = .tombstone(marker) }
        else { self = .illustration(try LifeIllustration(from: decoder)) }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .illustration(let item):
            try item.encode(to: encoder)
            var container = encoder.container(keyedBy: MarkerKey.self)
            try container.encode(false, forKey: .deleted)
        case .tombstone(let item): try item.encode(to: encoder)
        }
    }

    private enum MarkerKey: String, CodingKey { case deleted }
}

public struct LifeIllustrationManifest: Codable, Equatable, Sendable {
    public let items: [LifeIllustrationChange]
    public let nextCursor: String
    public let hasMore: Bool
}

public enum LifeIllustrationError: Error, LocalizedError {
    case unavailable, invalidInterval, invalidManifest, assetIntegrity, invalidPagination

    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "生活插画暂不可用。")
        case .invalidInterval: String(localized: "请选择 2、3、4 或 6 小时。")
        case .invalidManifest: String(localized: "生活插画资料不完整，请稍后重试。")
        case .assetIntegrity: String(localized: "生活插画下载校验失败，请稍后重试。")
        case .invalidPagination: String(localized: "生活插画同步进度无效，请稍后重试。")
        }
    }
}
