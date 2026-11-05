import Foundation
import XCTest
@testable import MoMoAgentClient

final class LifeIllustrationTests: XCTestCase, @unchecked Sendable {
    func testJourneyDecodingValidationAndLegacyCache() throws {
        var payload: [String: Any] = ["id": "test", "window_start": 100, "window_end": 200,
            "logical_day": "2026-11-05", "timezone": "Asia/Shanghai", "place": "工作室",
            "asset_sha256": String(repeating: "a", count: 64), "thumbnail_sha256": String(repeating: "b", count: 64),
            "width": 1024, "height": 1024, "source_ids": ["source"], "created_at": 201, "updated_at": 201]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func decode(_ value: [String: Any]) throws -> LifeIllustration {
            try decoder.decode(LifeIllustration.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let legacy = try decode(payload)
        try legacy.validate()
        XCTAssertNil(legacy.summary)
        XCTAssertEqual(legacy.routePoints, [])
        payload.merge(["summary": "在桌边讨论模块边界", "latitude": 39.9, "longitude": 116.4,
            "place_start": 100, "place_end": 180, "route_points": [["latitude": 39.9, "longitude": 116.4,
            "timestamp": 100, "end_timestamp": 180, "kind": "visit", "title": "工作室"]]]) { _, new in new }
        let journey = try decode(payload)
        try journey.validate()
        XCTAssertEqual(journey.summary, "在桌边讨论模块边界")
        XCTAssertEqual(journey.routePoints.first?.endTimestamp, 180)
        for invalid in [["latitude": 91], ["longitude": -181], ["place_end": 99], ["latitude": NSNull()]] as [[String: Any]] {
            let value = payload.merging(invalid) { _, new in new }
            XCTAssertThrowsError(try decode(value).validate())
        }
        payload["route_points"] = Array(repeating: ["latitude": 39.9, "longitude": 116.4, "timestamp": 100, "kind": "waypoint"], count: 129)
        XCTAssertThrowsError(try decode(payload).validate())
        let point = LifeIllustrationRoutePoint(latitude: .nan, longitude: 0, timestamp: 1, kind: "visit")
        XCTAssertFalse(point.isValid)
        XCTAssertFalse(LifeIllustrationRoutePoint(latitude: 0, longitude: 0, timestamp: .infinity, kind: "visit").isValid)
    }

    @MainActor func testIncrementalSyncRestoresAssetsAndHidesUnsupportedProvider() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = IllustrationTransport()
        let store = try makeStore(directory, route: route)
        XCTAssertTrue(store.isConfigured)
        XCTAssertFalse(store.hasLoadedSettings)
        XCTAssertEqual(store.settings.serviceStatus, "unknown")
        await store.refresh()
        XCTAssertTrue(store.hasLoadedSettings)
        XCTAssertNil(store.error)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.width, 1024)
        XCTAssertEqual(item.height, 1024)
        let original = try XCTUnwrap(store.imageURL(for: item, thumbnail: false))
        let thumbnail = try XCTUnwrap(store.imageURL(for: item))
        XCTAssertNotEqual(original, thumbnail)
        let firstDownloads = await route.assetRequests
        XCTAssertEqual(firstDownloads, 2)
        await store.refresh()
        let downloads = await route.assetRequests
        XCTAssertEqual(downloads, 2)
        let restored = try makeStore(directory, route: route)
        XCTAssertTrue(restored.items.isEmpty, "A disk cache cannot assert a signed-in Codex account.")
        await restored.refresh()
        XCTAssertEqual(restored.items, [item])
        let restoredDownloads = await route.assetRequests
        XCTAssertEqual(restoredDownloads, 2)

        await route.setProvider("anthropic", status: "unsupported_provider")
        await restored.refresh()
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertNil(restored.imageURL(for: item))
        await route.setProvider("openai-codex", status: "not_signed_in")
        await restored.refresh()
        XCTAssertTrue(restored.items.isEmpty)

        await route.setProvider("openai-codex", status: "ready")
        await route.removeItem()
        await restored.refresh()
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
        let cursors = await route.cursors
        XCTAssertEqual(cursors, ["0", "1", "1", "1"])
    }

    @MainActor func testHashMismatchDoesNotAdvanceCursorAndRetriesOnlyUncachedBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = IllustrationTransport()
        await route.setCorruptAssets(true)
        let store = try makeStore(directory, route: route)
        await store.refresh()
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.items.isEmpty)
        await route.setCorruptAssets(false)
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.items.count, 1)
        let cursors = await route.cursors
        XCTAssertEqual(cursors, ["0", "0"])

        let item = try XCTUnwrap(store.items.first)
        let original = try XCTUnwrap(store.imageURL(for: item, thumbnail: false))
        try Data("truncated".utf8).write(to: original)
        let countBeforeRepair = await route.assetRequests
        await store.refresh()
        let countAfterRepair = await route.assetRequests
        XCTAssertEqual(countAfterRepair, countBeforeRepair + 1)
        XCTAssertEqual(LifeIllustrationCache.digest(try Data(contentsOf: original)), item.assetSha256)
    }

    @MainActor func testSettingsValidationAndDeleteUseAuthenticatedDataAPI() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = IllustrationTransport()
        let store = try makeStore(directory, route: route)
        await store.refresh()
        do {
            try await store.updateSettings(enabled: true, intervalHours: 24)
            XCTFail("The removed full-day option must not be sent.")
        } catch LifeIllustrationError.invalidInterval {}
        try await store.updateSettings(enabled: true, intervalHours: 6)
        XCTAssertEqual(store.settings.intervalHours, 6)
        XCTAssertTrue(store.settings.enabled)
        let item = try XCTUnwrap(store.items.first)
        try await store.delete(item)
        XCTAssertTrue(store.items.isEmpty)
        await store.refresh()
        XCTAssertTrue(store.items.isEmpty)
        let requests = await route.requests
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret" })
        let settingsWrite = try XCTUnwrap(requests.first { $0.httpMethod == "POST" && $0.url?.lastPathComponent == "settings" })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(settingsWrite.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["enabled", "interval_hours"])
        XCTAssertEqual(body["interval_hours"] as? Int, 6)
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" && $0.url?.lastPathComponent == "delete" }.count, 1)
    }

    @MainActor func testRepeatedManifestCursorFailsWithoutPublishingPartialResults() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = IllustrationTransport()
        await route.setInvalidPagination()
        let store = try makeStore(directory, route: route)
        await store.refresh()
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.items.isEmpty)
        let requests = await route.cursors
        XCTAssertEqual(requests, ["0"])
    }

    @MainActor func testCrossPageTombstoneDoesNotDownloadDeletedHistoricalAsset() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = IllustrationTransport()
        await route.replayDeletedHistory()
        let store = try makeStore(directory, route: route)
        XCTAssertTrue(store.isConfigured)
        XCTAssertFalse(store.hasLoadedSettings)
        XCTAssertEqual(store.settings.serviceStatus, "unknown")
        await store.refresh()
        XCTAssertTrue(store.hasLoadedSettings)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.items.isEmpty)
        let downloads = await route.assetRequests
        let cursors = await route.cursors
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(cursors, ["0", "1"])
    }

    @MainActor func testOfflineRelaunchRestoresVerifiedCachedIllustrationsUntilRevoked() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = IllustrationTransport()
        let initial = try makeStore(directory, route: route)
        await initial.refresh()
        let cachedItem = try XCTUnwrap(initial.items.first)

        // Simulate app relaunch while Tailscale DERP / cellular is temporarily unreachable.
        await route.setOffline(true)
        let relaunched = try makeStore(directory, route: route)
        XCTAssertTrue(relaunched.items.isEmpty)
        await relaunched.refresh()
        XCTAssertFalse(relaunched.hasLoadedSettings)
        XCTAssertEqual(relaunched.items, [cachedItem])
        XCTAssertNotNil(relaunched.imageURL(for: cachedItem))

        // Once connection returns with HTTP 401, cached authorization must be revoked immediately.
        await route.setOffline(false)
        await route.setUnauthorized(true)
        await relaunched.refresh()
        XCTAssertTrue(relaunched.items.isEmpty)
        XCTAssertNil(relaunched.imageURL(for: cachedItem))
    }

    func testPendingTranscriptionMetadataDoesNotChangeTextIdentity() throws {
        let source = SourceEnvelope(library: UUID(), session: UUID(), device: UUID(), generation: 1, version: 2,
            recordedAt: Date(), spans: [.init(id: UUID(), text: "finished words", recordedAt: Date())])
        var pending = source
        pending.pendingTranscriptionRanges = [.init(start: 100, end: 120)]
        XCTAssertEqual(pending.textSha256, source.textSha256)
        XCTAssertNotEqual(pending, source)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(pending)) as? [String: Any])
        XCTAssertNotNil(body["pending_transcription_ranges"])
        XCTAssertEqual(pending.tombstone().pendingTranscriptionRanges, [])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("life-illustration-test-\(UUID())")
    }

    @MainActor private func makeStore(_ directory: URL, route: IllustrationTransport) throws -> LifeIllustrationStore {
        let client = try AgentClient(baseURL: URL(string: "http://127.0.0.1:8769")!, credential: "fixture-secret",
                                     assistantID: UUID(), transport: route)
        let store = LifeIllustrationStore(directory: directory)
        store.configure(client: client, scope: "test-workspace")
        return store
    }
}

private actor IllustrationTransport: AgentTransport {
    nonisolated var requiresExclusiveRouting: Bool { true }
    let original = Data("verified original image bytes".utf8)
    let thumbnail = Data("verified thumbnail image bytes".utf8)
    var requests: [URLRequest] = []
    var cursors: [String] = []
    var assetRequests = 0
    var settings: LifeIllustrationSettings
    var deleted = false
    var corruptAssets = false
    var invalidPagination = false
    var deletedHistory = false
    var offline = false
    var unauthorized = false

    init() {
        var settings = LifeIllustrationSettings()
        settings.provider = "openai-codex"; settings.supported = true; settings.serviceStatus = "ready"
        self.settings = settings
    }

    func setProvider(_ provider: String, status: String) {
        settings.provider = provider; settings.serviceStatus = status
        settings.supported = provider == "openai-codex" && status == "ready"
    }
    func setCorruptAssets(_ value: Bool) { corruptAssets = value }
    func setInvalidPagination() { invalidPagination = true }
    func removeItem() { deleted = true }
    func replayDeletedHistory() { deletedHistory = true }
    func setOffline(_ value: Bool) { offline = value }
    func setUnauthorized(_ value: Bool) { unauthorized = value }

    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        if unauthorized {
            return AgentByteStream(status: 401, contentType: "application/json", chunks: AsyncThrowingStream { continuation in
                continuation.yield(Data("{\"error\":{\"code\":\"unauthorized\"}}".utf8))
                continuation.finish()
            })
        }
        let url = try XCTUnwrap(request.url)
        let data: Data
        switch url.lastPathComponent {
        case "settings":
            if request.httpMethod == "POST" {
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                settings.enabled = try XCTUnwrap(body["enabled"] as? Bool)
                settings.intervalHours = try XCTUnwrap(body["interval_hours"] as? Int)
            }
            data = try encode(settings)
        case "manifest":
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value ?? ""
            cursors.append(cursor)
            let tombstone = LifeIllustrationTombstone(id: "illustration-1", deleted: true, updatedAt: 200)
            let item = LifeIllustration(id: "illustration-1", windowStart: 100, windowEnd: 200, logicalDay: "2026-11-05",
                timezone: "Asia/Shanghai", place: "杭州", assetSha256: LifeIllustrationCache.digest(original),
                thumbnailSha256: LifeIllustrationCache.digest(thumbnail), width: 1024, height: 1024,
                sourceIds: ["library/session"], createdAt: 201, updatedAt: 201)
            if deletedHistory {
                data = try encode(LifeIllustrationManifest(items: cursor == "0" ? [.illustration(item)] : [.tombstone(tombstone)],
                    nextCursor: cursor == "0" ? "1" : "2", hasMore: cursor == "0"))
            } else {
                data = try encode(LifeIllustrationManifest(
                    items: deleted ? [.tombstone(tombstone)] : cursor == "0" ? [.illustration(item)] : [],
                    nextCursor: invalidPagination ? cursor : deleted ? "2" : "1", hasMore: invalidPagination))
            }
        case "delete":
            deleted = true
            data = try encode(LifeIllustrationTombstone(id: "illustration-1", deleted: true, updatedAt: 200))
        default:
            assetRequests += 1
            data = corruptAssets ? Data("wrong bytes".utf8) : url.lastPathComponent == LifeIllustrationCache.digest(original) ? original : thumbnail
        }
        return AgentByteStream(status: 200, contentType: "application/json", chunks: AsyncThrowingStream { continuation in
            continuation.yield(data); continuation.finish()
        })
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }
}
