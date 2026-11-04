import Dispatch
import Foundation
import MoMoContracts
import OSLog

public enum CriticalAPI: String, Codable, CaseIterable, Sendable {
    case coldStartToTimelineInteractive
    case timelineDaySnapshot
    case earliestTimelineDay
    case recordingsPage
    case transcriptPreviewsBatch
    case transcriptSnapshot
    case recordingFileIssues
    case reconcileDocumentFiles
    case projectPendingDocuments
    case commitWindowTranscripts
    case commitReceivedChunk
    case receiveReconcileRequest
    case writeSyncDiagnostic
    case speechWarmUp

    public var defaultBudgetMs: Double {
        switch self {
        case .coldStartToTimelineInteractive: 500
        case .timelineDaySnapshot: 150
        case .earliestTimelineDay: 30
        case .recordingsPage: 80
        case .transcriptPreviewsBatch: 40
        case .transcriptSnapshot: 80
        case .recordingFileIssues: 250
        case .reconcileDocumentFiles: 400
        case .projectPendingDocuments: 400
        case .commitWindowTranscripts: 120
        case .commitReceivedChunk: 50
        case .receiveReconcileRequest: 80
        case .writeSyncDiagnostic: 60
        case .speechWarmUp: 12_000
        }
    }
}

public struct APIMetricSummary: Codable, Equatable, Sendable {
    public var callCount: Int
    public var errorCount: Int
    public var budgetMs: Double
    public var budgetViolationCount: Int
    public var lastDurationMs: Double
    public var minDurationMs: Double
    public var p50DurationMs: Double
    public var p95DurationMs: Double
    public var maxDurationMs: Double
    public var meanDurationMs: Double
    public var lastItemCount: Int
    public var lastRecordedAt: Date
    public var recentSamplesMs: [Double]

    static func percentile(_ sorted: [Double], q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = max(0, min(Double(sorted.count - 1), q * Double(sorted.count - 1)))
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1.0 - weight) + sorted[upper] * weight
    }
}

public struct APIVersionPerformance: Codable, Equatable, Sendable {
    public var marketingVersion: String
    public var buildVersion: String
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var metrics: [String: APIMetricSummary]
}

public struct APIPerformanceReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: Date
    public var currentVersionKey: String
    public var versions: [String: APIVersionPerformance]
}

public final class APIPerformanceMonitor: @unchecked Sendable {
    private static let maxRecentSamples = 64
    private static let maxRetainedVersions = 10
    private static let flushMinimumIntervalSeconds: Double = 5.0

    public let fileURL: URL
    public let marketingVersion: String
    public let buildVersion: String
    public let versionKey: String

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.momoagent.performance", category: "CriticalAPI")
    private let signposter: OSSignposter
    private let ioQueue = DispatchQueue(label: "com.momoagent.performance.persist", qos: .utility)
    private var report: APIPerformanceReport
    private var dirty = false
    private var flushScheduled = false
    private var lastFlushUptime: Double = 0

    public init(
        fileURL: URL,
        marketingVersion: String? = nil,
        buildVersion: String? = nil
    ) {
        self.fileURL = fileURL
        let resolvedMarketing = marketingVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0-dev"
        let resolvedBuild = buildVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "0"
        self.marketingVersion = resolvedMarketing
        self.buildVersion = resolvedBuild
        let key = "\(resolvedMarketing)+\(resolvedBuild)"
        self.versionKey = key
        self.signposter = OSSignposter(logger: logger)

        let now = Date()
        if let data = try? Data(contentsOf: fileURL),
           var loaded = try? WireJSON.decode(APIPerformanceReport.self, from: data) {
            loaded.currentVersionKey = key
            if loaded.versions[key] == nil {
                loaded.versions[key] = APIVersionPerformance(
                    marketingVersion: resolvedMarketing,
                    buildVersion: resolvedBuild,
                    firstObservedAt: now,
                    lastObservedAt: now,
                    metrics: [:]
                )
            }
            self.report = Self.pruneOldVersions(loaded)
        } else {
            self.report = APIPerformanceReport(
                schemaVersion: 1,
                updatedAt: now,
                currentVersionKey: key,
                versions: [
                    key: APIVersionPerformance(
                        marketingVersion: resolvedMarketing,
                        buildVersion: resolvedBuild,
                        firstObservedAt: now,
                        lastObservedAt: now,
                        metrics: [:]
                    )
                ]
            )
        }
    }

    @inline(__always)
    public static func uptimeMilliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
    }

    public func measure<T>(
        _ api: CriticalAPI,
        itemCount: Int = 1,
        _ body: () throws -> T
    ) rethrows -> T {
        let state = signposter.beginInterval("CriticalAPI", "\(api.rawValue, privacy: .public)")
        let startedMs = Self.uptimeMilliseconds()
        do {
            let value = try body()
            let elapsedMs = max(0, Self.uptimeMilliseconds() - startedMs)
            signposter.endInterval("CriticalAPI", state)
            record(api, durationMs: elapsedMs, itemCount: itemCount, failed: false)
            return value
        } catch {
            let elapsedMs = max(0, Self.uptimeMilliseconds() - startedMs)
            signposter.endInterval("CriticalAPI", state)
            record(api, durationMs: elapsedMs, itemCount: itemCount, failed: true)
            throw error
        }
    }

    public func measureAsync<T>(
        _ api: CriticalAPI,
        itemCount: Int = 1,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval("CriticalAPI", "\(api.rawValue, privacy: .public)")
        let startedMs = Self.uptimeMilliseconds()
        do {
            let value = try await body()
            let elapsedMs = max(0, Self.uptimeMilliseconds() - startedMs)
            signposter.endInterval("CriticalAPI", state)
            record(api, durationMs: elapsedMs, itemCount: itemCount, failed: false)
            return value
        } catch {
            let elapsedMs = max(0, Self.uptimeMilliseconds() - startedMs)
            signposter.endInterval("CriticalAPI", state)
            if !(error is CancellationError) {
                record(api, durationMs: elapsedMs, itemCount: itemCount, failed: true)
            }
            throw error
        }
    }

    public func record(
        _ api: CriticalAPI,
        durationMs: Double,
        itemCount: Int = 1,
        failed: Bool = false,
        now: Date = Date()
    ) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        let roundedMs = (durationMs * 100.0).rounded() / 100.0
        let budget = api.defaultBudgetMs
        let violated = roundedMs > budget
        var shouldScheduleFlush = false

        lock.lock()
        var versionEntry = report.versions[versionKey] ?? APIVersionPerformance(
            marketingVersion: marketingVersion,
            buildVersion: buildVersion,
            firstObservedAt: now,
            lastObservedAt: now,
            metrics: [:]
        )
        versionEntry.lastObservedAt = now
        var summary = versionEntry.metrics[api.rawValue] ?? APIMetricSummary(
            callCount: 0,
            errorCount: 0,
            budgetMs: budget,
            budgetViolationCount: 0,
            lastDurationMs: roundedMs,
            minDurationMs: roundedMs,
            p50DurationMs: roundedMs,
            p95DurationMs: roundedMs,
            maxDurationMs: roundedMs,
            meanDurationMs: roundedMs,
            lastItemCount: max(0, itemCount),
            lastRecordedAt: now,
            recentSamplesMs: []
        )
        let previousCount = summary.callCount
        summary.callCount = previousCount + 1
        if failed { summary.errorCount += 1 }
        summary.budgetMs = budget
        if violated { summary.budgetViolationCount += 1 }
        summary.lastDurationMs = roundedMs
        summary.minDurationMs = previousCount == 0 ? roundedMs : min(summary.minDurationMs, roundedMs)
        summary.maxDurationMs = previousCount == 0 ? roundedMs : max(summary.maxDurationMs, roundedMs)
        let runningMean = previousCount == 0
            ? roundedMs
            : ((summary.meanDurationMs * Double(previousCount)) + roundedMs) / Double(previousCount + 1)
        summary.meanDurationMs = (runningMean * 100.0).rounded() / 100.0
        summary.lastItemCount = max(0, itemCount)
        summary.lastRecordedAt = now
        summary.recentSamplesMs.append(roundedMs)
        if summary.recentSamplesMs.count > Self.maxRecentSamples {
            summary.recentSamplesMs.removeFirst(summary.recentSamplesMs.count - Self.maxRecentSamples)
        }
        let sorted = summary.recentSamplesMs.sorted()
        summary.p50DurationMs = (APIMetricSummary.percentile(sorted, q: 0.50) * 100.0).rounded() / 100.0
        summary.p95DurationMs = (APIMetricSummary.percentile(sorted, q: 0.95) * 100.0).rounded() / 100.0

        versionEntry.metrics[api.rawValue] = summary
        report.versions[versionKey] = versionEntry
        report.currentVersionKey = versionKey
        report.updatedAt = now
        dirty = true
        if !flushScheduled {
            flushScheduled = true
            shouldScheduleFlush = true
        }
        let p95 = summary.p95DurationMs
        let calls = summary.callCount
        lock.unlock()

        if violated {
            logger.notice(
                "API budget exceeded [v=\(self.versionKey, privacy: .public) api=\(api.rawValue, privacy: .public)]: last=\(roundedMs, format: .fixed(precision: 2))ms budget=\(budget, format: .fixed(precision: 1))ms p95=\(p95, format: .fixed(precision: 2))ms items=\(itemCount) calls=\(calls)"
            )
        }
        if shouldScheduleFlush {
            scheduleBackgroundFlush()
        }
    }

    public func snapshot() -> APIPerformanceReport {
        lock.lock()
        defer { lock.unlock() }
        return report
    }

    public func flushNow() throws {
        let payload: APIPerformanceReport?
        lock.lock()
        if dirty || !FileManager.default.fileExists(atPath: fileURL.path) {
            dirty = false
            lastFlushUptime = Self.uptimeMilliseconds() / 1_000.0
            payload = report
        } else {
            payload = nil
        }
        lock.unlock()
        if let payload {
            let encoded = try WireJSON.encode(payload)
            try ArchiveFilePolicy.write(encoded, to: fileURL)
        }
    }

    private func scheduleBackgroundFlush() {
        let nowSeconds = Self.uptimeMilliseconds() / 1_000.0
        lock.lock()
        let elapsed = nowSeconds - lastFlushUptime
        lock.unlock()
        let delay = max(0.25, Self.flushMinimumIntervalSeconds - elapsed)
        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.flushScheduled = false
            self.lock.unlock()
            try? self.flushNow()
        }
    }

    private static func pruneOldVersions(_ input: APIPerformanceReport) -> APIPerformanceReport {
        guard input.versions.count > maxRetainedVersions else { return input }
        var output = input
        let sortedKeys = output.versions.sorted { lhs, rhs in
            if lhs.key == output.currentVersionKey { return true }
            if rhs.key == output.currentVersionKey { return false }
            return lhs.value.lastObservedAt > rhs.value.lastObservedAt
        }.prefix(maxRetainedVersions).map(\.key)
        let keep = Set(sortedKeys)
        output.versions = output.versions.filter { keep.contains($0.key) }
        return output
    }
}
