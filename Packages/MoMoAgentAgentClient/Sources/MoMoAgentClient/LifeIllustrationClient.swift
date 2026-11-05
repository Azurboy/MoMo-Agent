import Foundation

extension AgentClient {
    public func lifeIllustrationSettings() async throws -> LifeIllustrationSettings {
        try decodeLifeIllustrations(await request(path: ["v1", "life-illustrations", "settings"]))
    }

    public func updateLifeIllustrationSettings(enabled: Bool, intervalHours: Int) async throws -> LifeIllustrationSettings {
        guard LifeIllustrationSettings.allowedIntervals.contains(intervalHours) else { throw LifeIllustrationError.invalidInterval }
        struct Input: Encodable { let enabled: Bool; let interval_hours: Int }
        let body = try JSONEncoder().encode(Input(enabled: enabled, interval_hours: intervalHours))
        return try decodeLifeIllustrations(await request(path: ["v1", "life-illustrations", "settings"], method: "POST", body: body))
    }

    public func lifeIllustrationManifest(cursor: String = "0") async throws -> LifeIllustrationManifest {
        try decodeLifeIllustrations(await request(path: ["v1", "life-illustrations", "manifest"],
            query: [.init(name: "cursor", value: cursor), .init(name: "limit", value: "100")]))
    }

    public func lifeIllustrationAsset(sha256: String) async throws -> Data {
        guard LifeIllustration.isSHA256(sha256) else { throw LifeIllustrationError.assetIntegrity }
        return try await request(path: ["v1", "life-illustrations", "assets", sha256])
    }

    public func deleteLifeIllustration(id: String) async throws -> LifeIllustrationTombstone {
        guard !id.isEmpty else { throw AgentClientError.invalidInput }
        struct Input: Encodable { let id: String }
        let receipt: LifeIllustrationTombstone = try decodeLifeIllustrations(await request(
            path: ["v1", "life-illustrations", "delete"], method: "POST", body: JSONEncoder().encode(Input(id: id))))
        guard receipt.id == id, receipt.deleted else { throw LifeIllustrationError.invalidManifest }
        return receipt
    }

    private func decodeLifeIllustrations<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
