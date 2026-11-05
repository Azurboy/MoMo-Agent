import Foundation
import Observation

@MainActor @Observable
public final class LifeIllustrationStore {
    public private(set) var settings = LifeIllustrationSettings()
    public private(set) var error: String?
    public private(set) var isRefreshing = false
    public var items: [LifeIllustration] { settings.canDisplayIllustrations ? cachedItems : [] }
    private var cachedItems: [LifeIllustration] = []
    private var assetURLs: [String: URL] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var cache: LifeIllustrationCache?
    @ObservationIgnored private var client: AgentClient?
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var refreshedAt = Date.distantPast
    @ObservationIgnored private var mutating = false

    public init(directory: URL) { self.directory = directory }

    public func configure(client: AgentClient, scope: String) {
        self.client = client
        guard self.scope != scope else { return }
        revision += 1
        refreshTask?.cancel(); refreshTask = nil
        self.scope = scope
        cache = LifeIllustrationCache(directory: directory.appendingPathComponent(LifeIllustrationCache.digest(Data(scope.utf8))))
        settings = LifeIllustrationSettings(); cachedItems = []; assetURLs = [:]
        refreshedAt = .distantPast; error = nil; isRefreshing = false
    }

    public func imageURL(for item: LifeIllustration, thumbnail: Bool = true) -> URL? {
        guard settings.canDisplayIllustrations, cachedItems.contains(where: { $0.id == item.id }) else { return nil }
        return assetURLs[thumbnail ? item.thumbnailSha256 : item.assetSha256]
    }

    public func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    public func stopPolling() {
        polling?.cancel(); polling = nil
        refreshTask?.cancel()
    }

    public func invalidateSupport() {
        settings.supported = false
        refreshedAt = .distantPast
        revision += 1
        refreshTask?.cancel(); refreshTask = nil; isRefreshing = false
    }

    /// Called by app lifecycle, never to request generation from a view.
    public func refresh(minimumInterval: TimeInterval = 0) async {
        if let refreshTask { await refreshTask.value; return }
        guard !mutating, let client, let cache, Date().timeIntervalSince(refreshedAt) >= minimumInterval else { return }
        let revision = revision
        isRefreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == revision { self.isRefreshing = false; self.refreshTask = nil } }
            do {
                let settings = try await client.lifeIllustrationSettings()
                try checkCurrent(revision)
                guard LifeIllustrationSettings.allowedIntervals.contains(settings.intervalHours) else { throw LifeIllustrationError.invalidInterval }
                self.settings = settings
                refreshedAt = Date()
                guard settings.canDisplayIllustrations else { error = nil; return }
                var snapshot = try await cache.load()
                var cursor = snapshot.cursor
                var seen = Set<String>()
                var latest: [String: LifeIllustrationChange] = [:]
                repeat {
                    try checkCurrent(revision)
                    let page = try await client.lifeIllustrationManifest(cursor: cursor)
                    try checkCurrent(revision)
                    guard let previous = Int64(cursor), let next = Int64(page.nextCursor), next >= previous,
                          !page.hasMore || next > previous && seen.insert(page.nextCursor).inserted else {
                        throw LifeIllustrationError.invalidPagination
                    }
                    for change in page.items {
                        switch change {
                        case .illustration(let item): try item.validate(); latest[item.id] = change
                        case .tombstone(let item): latest[item.id] = change
                        }
                    }
                    cursor = page.nextCursor
                    if !page.hasMore { break }
                } while true
                // A deleted/replaced artifact may no longer exist even when its earlier event is on another page.
                let changes = latest.keys.sorted().compactMap { latest[$0] }
                let tombstones = changes.filter { if case .tombstone = $0 { true } else { false } }
                if !tombstones.isEmpty {
                    snapshot = try await cache.apply(tombstones)
                    try checkCurrent(revision)
                    publish(snapshot)
                    pruneAssetURLs()
                }
                for change in changes {
                    if case .illustration(let item) = change {
                        for hash in Set([item.thumbnailSha256, item.assetSha256]) {
                            if try await cache.verifiedURL(sha256: hash) == nil {
                                let data = try await client.lifeIllustrationAsset(sha256: hash)
                                try checkCurrent(revision)
                                _ = try await cache.saveAsset(data, sha256: hash)
                            }
                        }
                    }
                }
                try checkCurrent(revision)
                snapshot = try await cache.apply(changes, cursor: cursor)
                // Restored cache may have been purged by the OS or interrupted before all bytes reached disk.
                var urls: [String: URL] = [:]
                for item in snapshot.items.values {
                    for hash in Set([item.thumbnailSha256, item.assetSha256]) where urls[hash] == nil {
                        if let url = try await cache.verifiedURL(sha256: hash) { urls[hash] = url }
                        else {
                            let data = try await client.lifeIllustrationAsset(sha256: hash)
                            try checkCurrent(revision)
                            urls[hash] = try await cache.saveAsset(data, sha256: hash)
                        }
                    }
                }
                try checkCurrent(revision)
                assetURLs = urls
                publish(snapshot)
                error = nil
            } catch {
                guard self.revision == revision, !AgentTransportFailure.isCancelled(error) else { return }
                self.error = error.localizedDescription
                // A failed capability check cannot authorize displaying a previous provider's images.
                if case AgentClientError.http(let status, _, _, _) = error, [401, 403, 404].contains(status) {
                    self.settings = LifeIllustrationSettings()
                }
            }
        }
        refreshTask = task
        await task.value
    }

    public func updateSettings(enabled: Bool, intervalHours: Int) async throws {
        guard !mutating, let client else { throw LifeIllustrationError.unavailable }
        mutating = true; defer { mutating = false }
        await cancelRefresh()
        let revision = revision
        do {
            let updated = try await client.updateLifeIllustrationSettings(enabled: enabled, intervalHours: intervalHours)
            try checkCurrent(revision)
            settings = updated
            error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }

    public func delete(_ item: LifeIllustration) async throws {
        guard !mutating, let client, let cache else { throw LifeIllustrationError.unavailable }
        mutating = true; defer { mutating = false }
        await cancelRefresh()
        let revision = revision
        do {
            let tombstone = try await client.deleteLifeIllustration(id: item.id)
            try checkCurrent(revision)
            let snapshot = try await cache.apply([.tombstone(tombstone)])
            try checkCurrent(revision)
            publish(snapshot)
            pruneAssetURLs()
            error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }

    private func cancelRefresh() async {
        revision += 1
        let task = refreshTask
        task?.cancel()
        await task?.value
        refreshTask = nil; isRefreshing = false
    }

    private func checkCurrent(_ revision: Int) throws {
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
    }

    private func publish(_ snapshot: LifeIllustrationCache.Snapshot) {
        cachedItems = snapshot.items.values.sorted {
            $0.windowStart == $1.windowStart ? $0.id < $1.id : $0.windowStart < $1.windowStart
        }
    }

    private func pruneAssetURLs() {
        let referenced = Set(cachedItems.flatMap { [$0.assetSha256, $0.thumbnailSha256] })
        assetURLs = assetURLs.filter { referenced.contains($0.key) }
    }
}
