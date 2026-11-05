import Foundation
import Observation
import OSLog
import MoMoArchive

@MainActor @Observable
final class TimelineModel {
    private(set) var selectedDay = TimelineDay(Date())
    @ObservationIgnored private var observedToday = TimelineDay(Date())
    private(set) var earliestDay: TimelineDay?
    private(set) var hasLoadedDateRange = false
    private(set) var days: [TimelineDay] = [TimelineDay(Date())]
    private(set) var snapshots: [TimelineDay: [TimelineWindow]] = [:]
    private(set) var listWindows: [TimelineDay: [TimelineWindow]] = [:]
    private(set) var repeatedClockRanges: [TimelineDay: Set<TimelineWindowID>] = [:]
    private(set) var loading: Set<TimelineDay> = []
    private(set) var failures: [TimelineDay: String] = [:]
    private(set) var summaries: [TimelineWindowID: Summary] = [:]
    @ObservationIgnored let archive: ArchiveStore
    @ObservationIgnored let configurationFingerprint: String?
    @ObservationIgnored private let cachedSummaries: (@MainActor ([String]) -> [String: String])?
    @ObservationIgnored private let summarize: (@Sendable ([TimelineWindow]) async throws -> [String: String])?
    @ObservationIgnored private var loadCounts: [TimelineDay: Int] = [:]
    @ObservationIgnored private var readRevision: UInt64 = 0
    @ObservationIgnored private var loadedRevisions: [TimelineDay: (archive: TimelineReadRevision, reads: UInt64)] = [:]
    @ObservationIgnored private var summaryQueue: [TimelineWindow] = []
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored var requestSummaries: (@MainActor (TimelineDay) -> Void)?
    @ObservationIgnored var preparePlayback: (@MainActor ([TimelineWindow]) -> Void)?
    @ObservationIgnored var onSelectedDayChanged: (@MainActor (TimelineDay) -> Void)?
    private(set) var invalidationRevision: UInt64 = 0
    @ObservationIgnored private var readingPositions: [TimelineWindowID: TimelineReadingAnchor] = [:]
    @ObservationIgnored private var readingLayouts: [TimelineWindowID: ReadingLayout] = [:]
    @ObservationIgnored private var detailRequests: [TimelineWindowID: UInt64] = [:]
    @ObservationIgnored private var nextDetailRequest: UInt64 = 0
    private(set) var processingProgress: [TimelineDay: TimelineDayProgress] = [:]
    @ObservationIgnored private var dayLoads: [TimelineDay: DayRead] = [:]
    @ObservationIgnored private var summaryFingerprints: [TimelineWindowID: (revision: String, summary: String)] = [:]
    private var replacements: [TimelineWindowID: TimelineWindowID] = [:]

    struct Summary { let revision: String; let text: String }

    private struct LoadedDay: Sendable {
        let snapshot: TimelineDaySnapshot
        let summaries: [TimelineWindowID: String]
        let first: TimelineDay?
        let listWindows: [TimelineWindow]
        let repeatedClockRanges: Set<TimelineWindowID>
        let revision: TimelineReadRevision
    }

    private struct DayRead {
        let id: UUID
        let task: Task<LoadedDay, Error>
        var consumers: Set<UUID>
    }

    private func summaryRevision(for window: TimelineWindow) -> String {
        if let cached = summaryFingerprints[window.id], cached.revision == window.revision { return cached.summary }
        return window.summaryRevision
    }

    private struct ReadingLayout {
        let token: TimelineReadingLayoutToken
        let window: TimelineWindow
        let anchors: [UUID: TimelineReadingAnchor]
        let sources: Set<TimelineReadingSource>
    }

    /// A detail snapshot and its layout share one admission token. A later request or
    /// invalidation cannot install an old response or save a disappearing row's position.
    func loadWindow(_ id: TimelineWindowID, previous: TimelineWindow? = nil,
                    fallbackSources: [TimelineAudioSource] = [], preservingLayout: TimelineReadingLayoutToken? = nil)
        async throws -> (window: TimelineWindow, layout: TimelineReadingLayoutToken)? {
        if let preservingLayout, !isCurrent(preservingLayout) { throw CancellationError() }
        nextDetailRequest &+= 1
        let request = nextDetailRequest, expectedRevision = invalidationRevision
        let lookupID = previous?.id ?? id
        detailRequests[id] = request
        detailRequests[lookupID] = request
        let candidates = try await readDay(id.day).snapshot.windows
        var value = candidates.first { $0.id == lookupID }
        if value == nil {
            let paragraphIDs = Set(previous?.paragraphs.map(\.id) ?? [])
            let previousSources = previous?.sources ?? []
            let sources = previousSources.isEmpty ? fallbackSources : previousSources
            value = candidates.first { $0.paragraphs.contains { paragraphIDs.contains($0.id) } }
                ?? candidates.last { $0.sharesSource(with: sources) }
        }
        try Task.checkCancellation()
        guard expectedRevision == invalidationRevision, detailRequests[id] == request,
              detailRequests[lookupID] == request else { throw CancellationError() }
        if let preservingLayout, !isCurrent(preservingLayout) { throw CancellationError() }
        guard let value else {
            for staleID in Set([id, lookupID]) {
                readingLayouts.removeValue(forKey: staleID)
                readingPositions.removeValue(forKey: staleID)
            }
            return nil
        }
        // A request for the replacement itself may have started while the old ID was
        // resolving. Its newer admission must not be replaced by this late alias result.
        guard (detailRequests[value.id] ?? 0) <= request else { throw CancellationError() }
        detailRequests[value.id] = request
        if let preservingLayout, readingLayouts[value.id]?.token == preservingLayout,
           readingLayouts[value.id]?.window == value {
            hydrateCachedSummaries(for: [value])
            queueSummaries([value])
            return (value, preservingLayout)
        }
        return admit(value, id: id, lookupID: lookupID)
    }

    /// Seed from the already mounted day while the fresh archive query validates it.
    func cachedWindow(_ id: TimelineWindowID) -> (window: TimelineWindow, layout: TimelineReadingLayoutToken)? {
        guard let value = snapshots[id.day]?.first(where: { $0.id == (currentID(id) ?? id) }) else { return nil }
        return admit(value, id: id, lookupID: id)
    }

    private func admit(_ value: TimelineWindow, id: TimelineWindowID, lookupID: TimelineWindowID)
        -> (window: TimelineWindow, layout: TimelineReadingLayoutToken) {
        let anchors = Dictionary(uniqueKeysWithValues: value.paragraphs.filter(\.hasReadableText).map { ($0.id, TimelineReadingAnchor($0.source)) })
        let sources = Set(value.sources.map { TimelineReadingSource(sessionID: $0.sessionID, generation: $0.generation) })
        let previousID = readingLayouts[value.id] != nil ? value.id : lookupID
        if let previous = readingLayouts[previousID], previous.sources.isSubset(of: sources),
           let saved = readingPositions[previousID], anchors[saved.spanID] == saved {
            readingPositions[value.id] = saved
        } else {
            readingPositions.removeValue(forKey: value.id)
        }
        for staleID in Set([id, lookupID]) where staleID != value.id {
            readingLayouts.removeValue(forKey: staleID)
            readingPositions.removeValue(forKey: staleID)
            replacements[staleID] = value.id
        }
        let token = TimelineReadingLayoutToken(windowID: value.id, revision: value.revision, identity: UUID())
        readingLayouts[value.id] = ReadingLayout(token: token, window: value, anchors: anchors, sources: sources)
        hydrateCachedSummaries(for: [value])
        if let index = snapshots[value.id.day]?.firstIndex(where: { $0.id == value.id }),
           snapshots[value.id.day]?[index] != value {
            snapshots[value.id.day]?[index] = value
            updateListPresentation(value.id.day)
        }
        queueSummaries([value])
        return (value, token)
    }

    /// One archive day build can serve list refresh and detail navigation concurrently.
    /// Completed reads are not reused here: a new request must observe ASR edits/deletions.
    private func readDay(_ day: TimelineDay) async throws -> LoadedDay {
        try Task.checkCancellation()
        let expectedRevision = readRevision, consumer = UUID()
        var request: DayRead
        if let existing = dayLoads[day] { request = existing }
        else {
            let archive = archive, fingerprint = configurationFingerprint
            request = DayRead(id: UUID(), task: Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                // Capture before the read: a concurrent archive write must cause a later refresh.
                let revision = try await archive.timelineReadRevision()
                let snapshot = try await archive.timelineDaySnapshot(day, configurationFingerprint: fingerprint)
                try Task.checkCancellation()
                let first = try await archive.earliestTimelineDay()
                var summaries: [TimelineWindowID: String] = [:]
                for window in snapshot.windows where window.canSummarize {
                    try Task.checkCancellation()
                    summaries[window.id] = window.summaryRevision
                }
                let windows = snapshot.windows.reversed().filter { !$0.omitsPunctuationOnlyResult }
                return LoadedDay(snapshot: snapshot, summaries: summaries, first: first,
                    listWindows: windows, repeatedClockRanges: TimelineDate.repeatedClockRanges(in: windows), revision: revision)
            }, consumers: [])
        }
        request.consumers.insert(consumer)
        dayLoads[day] = request
        let requestID = request.id, task = request.task
        defer { releaseRead(day, requestID: requestID, consumer: consumer) }
        let loaded = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseRead(day, requestID: requestID, consumer: consumer)
            }
        }
        try Task.checkCancellation()
        guard expectedRevision == readRevision else { throw CancellationError() }
        summaryFingerprints = summaryFingerprints.filter { $0.key.day != day }
        for window in loaded.snapshot.windows {
            if let summary = loaded.summaries[window.id] { summaryFingerprints[window.id] = (window.revision, summary) }
        }
        if processingProgress[day] != loaded.snapshot.progress { processingProgress[day] = loaded.snapshot.progress }
        return loaded
    }

    private func releaseRead(_ day: TimelineDay, requestID: UUID, consumer: UUID) {
        guard var read = dayLoads[day], read.id == requestID else { return }
        read.consumers.remove(consumer)
        if read.consumers.isEmpty {
            read.task.cancel()
            dayLoads.removeValue(forKey: day)
        } else { dayLoads[day] = read }
    }

    private func updateListPresentation(_ day: TimelineDay) {
        let windows = snapshots[day, default: []].reversed().filter { !$0.omitsPunctuationOnlyResult }
        listWindows[day] = windows
        repeatedClockRanges[day] = TimelineDate.repeatedClockRanges(in: windows)
    }

    func isCurrent(_ layout: TimelineReadingLayoutToken) -> Bool {
        readingLayouts[layout.windowID]?.token == layout
    }

    func readingAnchor(in window: TimelineWindow, layout: TimelineReadingLayoutToken) -> UUID? {
        guard window.id == layout.windowID, window.revision == layout.revision, isCurrent(layout),
              let saved = readingPositions[window.id], readingLayouts[window.id]?.anchors[saved.spanID] == saved else { return nil }
        return saved.spanID
    }

    func rememberReadingPosition(_ spanID: UUID, in window: TimelineWindow, layout: TimelineReadingLayoutToken) {
        guard window.id == layout.windowID, window.revision == layout.revision, isCurrent(layout),
              let anchor = readingLayouts[window.id]?.anchors[spanID] else { return }
        readingPositions[window.id] = anchor
    }

    init(archive: ArchiveStore, configurationFingerprint: String?,
         cachedSummaries: (@MainActor ([String]) -> [String: String])? = nil,
         summarize: (@Sendable ([TimelineWindow]) async throws -> [String: String])? = nil) {
        self.archive = archive; self.configurationFingerprint = configurationFingerprint
        self.cachedSummaries = cachedSummaries
        self.summarize = summarize
    }

    func select(_ day: TimelineDay) {
        guard day <= TimelineDay(Date()) else { return }
        let changed = selectedDay != day
        selectedDay = day
        if changed {
            if let windows = snapshots[day] {
                hydrateCachedSummaries(for: windows)
                queueSummaries(windows)
                requestSummaries?(day)
            }
            onSelectedDayChanged?(day)
        }
    }

    func handleDayBoundaryChanged() {
        invalidationRevision &+= 1
        discardPendingReads()
        loadedRevisions.removeAll()
        snapshots.removeAll()
        listWindows.removeAll()
        repeatedClockRanges.removeAll()
        processingProgress.removeAll()
        failures.removeAll()
        earliestDay = nil
        hasLoadedDateRange = false
        let currentToday = TimelineDay(Date())
        observedToday = currentToday
        selectedDay = currentToday
        days = [currentToday]
        onSelectedDayChanged?(currentToday)
    }

    func currentID(_ id: TimelineWindowID?) -> TimelineWindowID? {
        guard var current = id else { return nil }
        var visited: Set<TimelineWindowID> = []
        while visited.insert(current).inserted {
            if snapshots[current.day]?.contains(where: { $0.id == current }) == true { return current }
            guard let next = replacements[current] else { break }
            current = next
        }
        return id
    }

    func summary(for window: TimelineWindow) -> String? {
        guard window.canSummarize else { return nil }
        let revision = summaryRevision(for: window)
        if let value = summaries[window.id], value.revision == revision { return value.text }
        if let text = cachedSummaries?([revision])[revision], !text.isEmpty { return text }
        return nil
    }

    private func hydrateCachedSummaries(for windows: [TimelineWindow], pruneDay: TimelineDay? = nil) {
        if let pruneDay {
            let validIDs = Set(windows.map(\.id))
            for existingID in summaries.keys where existingID.day == pruneDay && !validIDs.contains(existingID) {
                summaries.removeValue(forKey: existingID)
            }
        }
        var missingRevisions: [(id: TimelineWindowID, revision: String)] = []
        for window in windows {
            guard window.canSummarize else {
                summaries.removeValue(forKey: window.id)
                continue
            }
            let revision = summaryRevision(for: window)
            if summaries[window.id]?.revision != revision {
                summaries.removeValue(forKey: window.id)
                missingRevisions.append((window.id, revision))
            }
        }
        guard let cachedSummaries, !missingRevisions.isEmpty else { return }
        let resolved = cachedSummaries(missingRevisions.map(\.revision))
        for item in missingRevisions {
            if let text = resolved[item.revision], !text.isEmpty {
                summaries[item.id] = Summary(revision: item.revision, text: text)
            }
        }
    }

    func refresh() async {
        let currentToday = TimelineDay(Date())
        if currentToday != observedToday {
            if selectedDay == observedToday {
                selectedDay = currentToday
                onSelectedDayChanged?(currentToday)
            }
            observedToday = currentToday
        }
        let day = selectedDay
        if let loaded = loadedRevisions[day], loaded.reads == readRevision,
           snapshots[day] != nil, failures[day] == nil, days.last == TimelineDay(Date()),
           let revision = try? await archive.timelineReadRevision(), loaded.archive == revision {
            guard !Task.isCancelled, selectedDay == day else { return }
            let currentWindows = snapshots[day, default: []]
            hydrateCachedSummaries(for: currentWindows)
            queueSummaries(currentWindows)
            requestSummaries?(day)
            return
        }
        guard !Task.isCancelled, selectedDay == day else { return }
        await load(selectedDay)
    }

    func load(_ day: TimelineDay) async {
        guard !Task.isCancelled else { return }
        loadCounts[day, default: 0] += 1
        loading.insert(day)
        defer {
            loadCounts[day, default: 0] -= 1
            if loadCounts[day, default: 0] == 0 { loadCounts.removeValue(forKey: day); loading.remove(day) }
        }
        while !Task.isCancelled {
            let expected = readRevision
            do {
                let loaded = try await readDay(day)
                let windows = loaded.snapshot.windows, first = loaded.first
                try Task.checkCancellation()
                guard expected == readRevision else { continue }
                loadedRevisions[day] = (loaded.revision, expected)
                // Hydrate already-completed summaries synchronously on MainActor BEFORE publishing
                // `listWindows[day]` so SwiftUI never flashes raw transcript text on the first frame.
                hydrateCachedSummaries(for: windows, pruneDay: day)
                if snapshots[day] != windows {
                    let ids = Set(windows.map(\.id))
                    for previous in snapshots[day, default: []] where !ids.contains(previous.id) {
                        if let replacement = windows.last(where: { $0.sharesSource(with: previous.sources) }) {
                            replacements[previous.id] = replacement.id
                        }
                    }
                    snapshots[day] = windows
                    listWindows[day] = loaded.listWindows
                    repeatedClockRanges[day] = loaded.repeatedClockRanges
                    if day == selectedDay { preparePlayback?(windows) }
                }
                failures.removeValue(forKey: day)
                let today = TimelineDay(Date())
                earliestDay = first.map { min($0, today) }
                hasLoadedDateRange = true
                var dates: [TimelineDay] = []
                var cursor = min(earliestDay ?? today, day)
                while cursor <= today { dates.append(cursor); cursor = cursor.adding(days: 1) }
                if days != dates { days = dates }
                if snapshots.count > 7 {
                    let oldest = snapshots.keys.filter { $0 != selectedDay && $0 != day }
                        .max { abs($0.date().timeIntervalSince(selectedDay.date())) < abs($1.date().timeIntervalSince(selectedDay.date())) }
                    if let oldest {
                        snapshots.removeValue(forKey: oldest); processingProgress.removeValue(forKey: oldest)
                        listWindows.removeValue(forKey: oldest); repeatedClockRanges.removeValue(forKey: oldest)
                        loadedRevisions.removeValue(forKey: oldest)
                        summaryFingerprints = summaryFingerprints.filter { $0.key.day != oldest }
                        for staleID in summaries.keys where staleID.day == oldest {
                            summaries.removeValue(forKey: staleID)
                        }
                    }
                }
                if day == selectedDay { queueSummaries(windows); requestSummaries?(day) }
                return
            } catch is CancellationError {
                if !Task.isCancelled, expected != readRevision { continue }
                return
            }
            catch {
                guard !Task.isCancelled else { return }
                failures[day] = String(localized: "这一天的记录暂时无法读取，请重试。")
                return
            }
        }
    }

    func discardPendingReads(days affectedDays: Set<TimelineDay>? = nil) {
        guard let affectedDays else {
            readRevision &+= 1
            for request in dayLoads.values { request.task.cancel() }
            dayLoads.removeAll()
            return
        }
        var cancelledAny = false
        for day in affectedDays {
            if let request = dayLoads.removeValue(forKey: day) {
                request.task.cancel()
                cancelledAny = true
            }
            loadedRevisions.removeValue(forKey: day)
        }
        if cancelledAny { readRevision &+= 1 }
    }

    func invalidate(sessionID: UUID) {
        invalidationRevision &+= 1
        discardPendingReads()
        let invalidLayouts = readingLayouts.filter { $0.value.sources.contains { $0.sessionID == sessionID } }.map(\.key)
        for id in invalidLayouts {
            readingLayouts.removeValue(forKey: id)
            readingPositions.removeValue(forKey: id)
            detailRequests.removeValue(forKey: id)
        }
        for day in snapshots.keys {
            let invalid = snapshots[day, default: []].filter { $0.sources.contains { $0.sessionID == sessionID } }
            for window in invalid {
                summaries.removeValue(forKey: window.id)
                summaryFingerprints.removeValue(forKey: window.id)
            }
            snapshots[day]?.removeAll { $0.sources.contains { $0.sessionID == sessionID } }
            if !invalid.isEmpty { updateListPresentation(day) }
        }
        summaryQueue.removeAll { $0.sources.contains { $0.sessionID == sessionID } }
    }

    func refreshCachedSummaries(day: TimelineDay? = nil) {
        let windows = snapshots.values.flatMap { $0 } + readingLayouts.values.map(\.window)
        let filtered = windows.filter { day == nil || $0.id.day == day }
        hydrateCachedSummaries(for: filtered)
        queueSummaries(filtered, reload: true)
    }

    private func queueSummaries(_ windows: [TimelineWindow], reload: Bool = false) {
        guard let summarize else { return }
        for window in windows where window.canSummarize && (reload || summary(for: window) == nil) {
            let revision = summaryRevision(for: window)
            if !summaryQueue.contains(where: { summaryRevision(for: $0) == revision }) { summaryQueue.append(window) }
        }
        guard summaryTask == nil, !summaryQueue.isEmpty else { return }
        summaryTask = Task { [weak self] in
            guard let self else { return }
            defer { summaryTask = nil }
            while !summaryQueue.isEmpty {
                let windows = summaryQueue
                summaryQueue.removeAll()
                do {
                    let texts = try await summarize(windows)
                    for window in windows {
                        let current = snapshots[window.id.day]?.first { $0.id == window.id } ?? readingLayouts[window.id]?.window
                        let revision = summaryRevision(for: window)
                        guard let current, current.canSummarize, summaryRevision(for: current) == revision else { continue }
                        // A cache miss is not a content revision; keep the already admitted summary.
                        if let text = texts[revision] { summaries[window.id] = Summary(revision: revision, text: text) }
                    }
                } catch is CancellationError { return }
                catch { Logger(subsystem: "com.momoagent.ios", category: "timeline").notice("Optional timeline summary unavailable") }
            }
        }
    }
}

nonisolated struct TimelineReadingLayoutToken: Equatable, Sendable {
    let windowID: TimelineWindowID
    let revision: String
    let identity: UUID
}

private nonisolated struct TimelineReadingAnchor: Hashable, Sendable {
    let sessionID: UUID
    let generation: Int64
    let spanID: UUID

    init(_ source: SourceReference) {
        sessionID = source.sessionID; generation = source.generation; spanID = source.spanID
    }
}

private nonisolated struct TimelineReadingSource: Hashable, Sendable {
    let sessionID: UUID
    let generation: Int64
}
