import Foundation
import Observation

@MainActor @Observable
public final class LifeIllustrationStore {
    public private(set) var settings = LifeIllustrationSettings()
    public private(set) var hasLoadedSettings = false
    public private(set) var error: String?
    public private(set) var isRefreshing = false
    public var isConfigured: Bool { client != nil }
    public var items: [LifeIllustration] { cachedItems }
    private var cachedItems: [LifeIllustration] = []
    private var assetURLs: [String: URL] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var cache: LifeIllustrationCache?
    @ObservationIgnored private var client: AgentClient?
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var hydrateTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var refreshedAt = Date.distantPast
    @ObservationIgnored private var mutating = false
    @ObservationIgnored private var synchronizationFailure: Error?

    public init(directory: URL) { self.directory = directory }

    public func configure(client: AgentClient, scope: String) {
        self.client = client
        guard self.scope != scope else { return }
        revision += 1
        hydrateTask?.cancel(); hydrateTask = nil
        refreshTask?.cancel(); refreshTask = nil
        self.scope = scope
        let cache = LifeIllustrationCache(directory: directory.appendingPathComponent(LifeIllustrationCache.digest(Data(scope.utf8))))
        self.cache = cache
        settings = LifeIllustrationSettings(); hasLoadedSettings = false; cachedItems = []; assetURLs = [:]
        refreshedAt = .distantPast; error = nil; isRefreshing = false
        synchronizationFailure = nil
        let currentRevision = revision
        hydrateTask = Task { [weak self] in
            await self?.hydrateCachedIllustrations(cache: cache, revision: currentRevision)
        }
    }

    public func waitForCacheHydration() async {
        await hydrateTask?.value
    }

    public func requestRefresh(minimumInterval: TimeInterval = 0) {
        Task { @MainActor [weak self] in
            await self?.refresh(minimumInterval: minimumInterval)
        }
    }

    private func hydrateCachedIllustrations(cache: LifeIllustrationCache, revision: Int) async {
        defer { if self.revision == revision { self.hydrateTask = nil } }
        guard let snapshot = try? await cache.load(),
              self.revision == revision,
              !self.hasLoadedSettings else { return }
        guard let cachedURLs = try? await cache.existingAssetURLs(for: Array(snapshot.items.values)),
              self.revision == revision,
              !self.hasLoadedSettings else { return }
        self.settings = snapshot.lastVerifiedSettings ?? LifeIllustrationSettings()
        self.assetURLs = cachedURLs
        self.publish(snapshot)
    }

    public func imageURL(for item: LifeIllustration, thumbnail: Bool = true) -> URL? {
        guard cachedItems.contains(where: { $0.id == item.id }) else { return nil }
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
    }

    public func cancelSynchronization() { refreshTask?.cancel() }

    /// Background owners need a confirmed disk commit, rather than a UI refresh that reports errors in state.
    public func synchronize() async throws {
        guard !mutating, isConfigured else { throw LifeIllustrationError.unavailable }
        let owner = revision
        await refresh()
        try checkCurrent(owner)
        if let synchronizationFailure { throw synchronizationFailure }
        guard hasLoadedSettings, !mutating else { throw LifeIllustrationError.unavailable }
    }

    public func invalidateSupport() {
        settings.supported = false
        hasLoadedSettings = false
        refreshedAt = .distantPast
        revision += 1
        hydrateTask?.cancel(); hydrateTask = nil
        refreshTask?.cancel(); refreshTask = nil; isRefreshing = false
        let currentCache = cache
        Task { try? await currentCache?.saveSettings(nil) }
    }

    /// Called by app lifecycle, never to request generation from a view.
    public func refresh(minimumInterval: TimeInterval = 0) async {
        if let hydrateTask { await hydrateTask.value }
        if let existingTask = refreshTask {
            let waitStartedAt = Date()
            await existingTask.value
            if !existingTask.isCancelled, error == nil, hasLoadedSettings, refreshedAt >= waitStartedAt { return }
        }
        guard !mutating, let client, let cache, Date().timeIntervalSince(refreshedAt) >= minimumInterval else { return }
        let revision = revision
        isRefreshing = true
        synchronizationFailure = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == revision { self.isRefreshing = false; self.refreshTask = nil } }
            do {
                let settings = try await client.lifeIllustrationSettings()
                try checkCurrent(revision)
                guard LifeIllustrationSettings.allowedIntervals.contains(settings.intervalHours) else { throw LifeIllustrationError.invalidInterval }
                try? await cache.saveSettings(settings)
                try checkCurrent(revision)
                self.settings = settings
                self.hasLoadedSettings = true
                refreshedAt = Date()
                var snapshot = try await cache.load()
                if cachedItems.isEmpty, !snapshot.items.isEmpty {
                    let cachedURLs = try await cache.existingAssetURLs(for: Array(snapshot.items.values))
                    try checkCurrent(revision)
                    assetURLs = cachedURLs
                    publish(snapshot)
                }
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
                let illustrationItems: [LifeIllustration] = changes.compactMap {
                    if case .illustration(let item) = $0 { return item }
                    return nil
                }.sorted {
                    $0.windowStart == $1.windowStart ? $0.id < $1.id : $0.windowStart > $1.windowStart
                }
                let protectedHashes = Set(illustrationItems.flatMap { [$0.assetSha256, $0.thumbnailSha256] })
                if !tombstones.isEmpty {
                    snapshot = try await cache.apply(tombstones, keepHashes: protectedHashes)
                    try checkCurrent(revision)
                    publish(snapshot)
                    pruneAssetURLs()
                }
                var assetDownloadFailure: Error?
                if !illustrationItems.isEmpty {
                    let maxConcurrency = 4
                    await withTaskGroup(of: Result<(LifeIllustration, [String: URL]), Error>.self) { group in
                        var iterator = illustrationItems.makeIterator()
                        for _ in 0..<min(maxConcurrency, illustrationItems.count) {
                            if let nextItem = iterator.next() {
                                group.addTask {
                                    do {
                                        return .success(try await Self.ensureAssets(for: nextItem, client: client, cache: cache))
                                    } catch {
                                        return .failure(error)
                                    }
                                }
                            }
                        }
                        while let outcome = await group.next() {
                            if Task.isCancelled || self.revision != revision {
                                group.cancelAll()
                                break
                            }
                            switch outcome {
                            case .success(let (completedItem, itemURLs)):
                                do {
                                    snapshot = try await cache.apply([.illustration(completedItem)], keepHashes: protectedHashes)
                                    if self.revision == revision, !Task.isCancelled {
                                        assetURLs.merge(itemURLs) { _, new in new }
                                        publish(snapshot)
                                    }
                                } catch {
                                    if assetDownloadFailure == nil { assetDownloadFailure = error }
                                }
                            case .failure(let itemError):
                                if assetDownloadFailure == nil { assetDownloadFailure = itemError }
                            }
                            if !Task.isCancelled, self.revision == revision, let nextItem = iterator.next() {
                                group.addTask {
                                    do {
                                        return .success(try await Self.ensureAssets(for: nextItem, client: client, cache: cache))
                                    } catch {
                                        return .failure(error)
                                    }
                                }
                            }
                        }
                    }
                }
                try checkCurrent(revision)
                if let assetDownloadFailure { throw assetDownloadFailure }
                if cursor != snapshot.cursor || !tombstones.isEmpty {
                    snapshot = try await cache.apply([], cursor: cursor)
                }
                // Restored cache may have been purged by the OS or interrupted before all bytes reached disk.
                var urls: [String: URL] = [:]
                for item in snapshot.items.values {
                    for hash in Set([item.thumbnailSha256, item.assetSha256]) where urls[hash] == nil {
                        if let url = try await cache.verifiedURL(sha256: hash) { urls[hash] = url }
                        else {
                            let data = try await client.lifeIllustrationAsset(sha256: hash)
                            try checkCurrent(revision)
                            let saved = try await cache.saveAsset(data, sha256: hash)
                            urls[hash] = saved
                            assetURLs[hash] = saved
                        }
                    }
                }
                try checkCurrent(revision)
                assetURLs = urls
                publish(snapshot)
                error = nil
            } catch {
                guard self.revision == revision else { return }
                self.synchronizationFailure = error
                guard !AgentTransportFailure.isCancelled(error) else { return }
                self.error = error.localizedDescription
                // Pairing/authentication failures block network sync, but do not revoke the phone's saved artifacts.
                if case AgentClientError.http(let status, _, _, _) = error, [401, 403, 404].contains(status) {
                    self.settings = LifeIllustrationSettings()
                    self.hasLoadedSettings = false
                    try? await cache.saveSettings(nil)
                } else if !self.hasLoadedSettings, AgentTransportFailure.isTransient(error),
                          let snapshot = try? await cache.load(),
                          let cachedURLs = try? await cache.existingAssetURLs(for: Array(snapshot.items.values)),
                          self.revision == revision {
                    self.settings = snapshot.lastVerifiedSettings ?? LifeIllustrationSettings()
                    self.assetURLs = cachedURLs
                    self.publish(snapshot)
                }
            }
        }
        refreshTask = task
        await task.value
    }

    private nonisolated static func ensureAssets(
        for item: LifeIllustration,
        client: AgentClient,
        cache: LifeIllustrationCache
    ) async throws -> (LifeIllustration, [String: URL]) {
        var resolved: [String: URL] = [:]
        for hash in [item.thumbnailSha256, item.assetSha256] where resolved[hash] == nil {
            if let existing = try await cache.verifiedURL(sha256: hash) {
                resolved[hash] = existing
            } else {
                let data = try await client.lifeIllustrationAsset(sha256: hash)
                try Task.checkCancellation()
                resolved[hash] = try await cache.saveAsset(data, sha256: hash)
            }
        }
        return (item, resolved)
    }

    public func updateSettings(enabled: Bool, intervalHours: Int) async throws {
        guard !mutating, let client else { throw LifeIllustrationError.unavailable }
        mutating = true; defer { mutating = false }
        await cancelRefresh()
        let revision = revision
        let currentCache = cache
        do {
            let updated = try await client.updateLifeIllustrationSettings(enabled: enabled, intervalHours: intervalHours)
            try checkCurrent(revision)
            try? await currentCache?.saveSettings(updated)
            try checkCurrent(revision)
            settings = updated
            hasLoadedSettings = true
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
        let hydrating = hydrateTask
        hydrateTask?.cancel()
        await hydrating?.value
        hydrateTask = nil
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
