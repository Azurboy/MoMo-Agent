import Foundation
import Observation
import MoMoArchive

struct PendingSpeakerOverride: Equatable {
    let editID: UUID
    let sessionID: UUID
    let generation: Int64
    let baseVersion: Int64
    let spanIDs: Set<UUID>
    let clusterID: UUID?
    let speaker: String?
    let attribution: SpeakerAttribution?
}

@MainActor @Observable
final class LibraryModel {
    private(set) var watchStatus: WatchStatusObservation?
    private(set) var recordings: [RecordingSummary] = []
    private(set) var speakerProfiles: [SpeakerProfile] = []
    private(set) var pendingSpeakerOverrides: [PendingSpeakerOverride] = []
    private(set) var fileIssues: [UUID: RecordingFileIssue] = [:]
    private(set) var speakerFeedbackFailure: String?
    private(set) var snapshotRevision: UInt64 = 0
    private(set) var searchRevision: UInt64 = 0
    let configurationFingerprint: String?
    let timeline: TimelineModel
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    var hasMoreRecordings: Bool { nextRecordingsCursor != nil }
    var failure: String?
    @ObservationIgnored let archive: ArchiveStore
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var pendingFileInspection = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var speakerFeedbackChain: Task<Void, Never>?
    @ObservationIgnored private var inFlightSpeakerFeedbackCount = 0
    @ObservationIgnored private var optimisticProfilesByID: [UUID: (name: String, isUser: Bool)] = [:]
    private var nextRecordingsCursor: String?
    private(set) var previews: [UUID: String] = [:]
    private(set) var searchResults: [LibrarySearchResult] = []
    private(set) var isSearching = false
    private(set) var searchFailure: String?
    private(set) var searchQuery = ""
    var hasMoreSearchResults: Bool { nextSearchCursor != nil }
    private var nextSearchCursor: String?
    private var searchGeneration: UInt64 = 0
    private var searchedRecordings: [UUID: RecordingSummary] = [:]
    @ObservationIgnored private var readingPositions: [UUID: RecordingReadingPosition] = [:]
    @ObservationIgnored private(set) var focusedSessionID: UUID?
    @ObservationIgnored var onFocusedSessionChanged: (@MainActor (UUID?) -> Void)?

    func setFocusedSession(_ sessionID: UUID) {
        guard focusedSessionID != sessionID else { return }
        focusedSessionID = sessionID
        onFocusedSessionChanged?(sessionID)
    }

    func clearFocusedSession(_ sessionID: UUID) {
        guard focusedSessionID == sessionID else { return }
        focusedSessionID = nil
        onFocusedSessionChanged?(nil)
    }

    @ObservationIgnored private var transcriptCache: [RecordingReadIdentity: RecordingTranscriptSnapshot] = [:]
    @ObservationIgnored private var transcriptRecency: [RecordingReadIdentity] = []
    @ObservationIgnored private var transcriptLoads: [RecordingReadIdentity: (UUID, Task<RecordingTranscriptSnapshot, Error>)] = [:]
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    func cachedTranscript(_ id: UUID) -> RecordingTranscriptSnapshot? {
        guard let summary = recording(id), fileIssues[id] == nil else { return nil }
        return transcriptCache[RecordingReadIdentity(summary)]
    }

    /// Concurrent navigation and bounded prefetch share the same immutable archive snapshot.
    /// A foreground read still consults the archive, including its deletion/conflict checks.
    func loadTranscript(_ id: UUID) async throws -> RecordingTranscriptSnapshot {
        guard let summary = recording(id), fileIssues[id] == nil else { throw ArchiveError.missingRecording(id) }
        let key = RecordingReadIdentity(summary)
        let request: (UUID, Task<RecordingTranscriptSnapshot, Error>)
        if let existing = transcriptLoads[key] { request = existing }
        else {
            let archive = archive
            request = (UUID(), Task {
                let value = try await archive.transcriptSnapshot(sessionID: id)
                try Task.checkCancellation()
                return RecordingTranscriptSnapshot(document: value.document, locations: value.locations)
            })
            transcriptLoads[key] = request
        }
        defer { if transcriptLoads[key]?.0 == request.0 { transcriptLoads.removeValue(forKey: key) } }
        let value = try await request.1.value
        try Task.checkCancellation()
        guard let current = recording(id), RecordingReadIdentity(current) == key, fileIssues[id] == nil,
              value.document.version == key.version, value.document.generation == key.generation else { throw CancellationError() }
        // Bound retained text; location maps share the document's span count.
        let cost = value.document.spans.reduce(0) { $0 + $1.text.utf8.count + 256 }
        if cost <= 4 * 1024 * 1024 {
            transcriptCache[key] = value
            transcriptRecency.removeAll { $0 == key }; transcriptRecency.append(key)
            while transcriptRecency.count > 3 { transcriptCache.removeValue(forKey: transcriptRecency.removeFirst()) }
        }
        return value
    }

    private func updateTranscriptCache(allowBackgroundPrefetch: Bool = true) {
        let valid = Set((recordings + Array(searchedRecordings.values)).filter { fileIssues[$0.id] == nil }.map(RecordingReadIdentity.init))
        transcriptCache = transcriptCache.filter { valid.contains($0.key) }
        transcriptRecency.removeAll { !valid.contains($0) }
        for (key, request) in transcriptLoads where !valid.contains(key) {
            request.1.cancel(); transcriptLoads.removeValue(forKey: key)
        }
        prefetchTask?.cancel()
        // Only the first two visible recordings when settled; during streaming progress ticks,
        // only prefetch a recording actively open in detail view so background ASR isn't starved.
        let candidates: [UUID]
        if allowBackgroundPrefetch {
            candidates = recordings.filter { $0.transcriptVersion > 0 && fileIssues[$0.id] == nil }.prefix(2).map(\.id)
        } else if let focused = focusedSessionID,
                  recordings.contains(where: { $0.id == focused && $0.transcriptVersion > 0 && fileIssues[$0.id] == nil }) {
            candidates = [focused]
        } else {
            candidates = []
        }
        guard !candidates.isEmpty else { return }
        prefetchTask = Task(priority: .utility) { [weak self] in
            for id in candidates {
                guard !Task.isCancelled, let self else { return }
                if cachedTranscript(id) == nil {
                    do { _ = try await loadTranscript(id) }
                    catch is CancellationError { return }
                    catch { /* Prefetch is optional; opening the recording presents read errors. */ }
                }
                await Task.yield()
            }
        }
    }

    /// Navigation owns the library model; individual detail views may be destroyed and recreated.
    /// A transcript append keeps its generation and span identities, so it keeps this anchor.
    func readingAnchor(in document: TranscriptDocument) -> UUID? {
        guard let current = recording(document.sessionID), current.generation == document.generation,
              current.transcriptVersion == document.version else { return nil }
        guard let saved = readingPositions[document.sessionID] else { return nil }
        guard saved.generation == document.generation, document.spans.contains(where: { $0.id == saved.spanID }) else {
            readingPositions.removeValue(forKey: document.sessionID)
            return nil
        }
        return saved.spanID
    }

    func rememberReadingPosition(_ spanID: UUID, in document: TranscriptDocument) {
        guard let current = recording(document.sessionID), current.generation == document.generation,
              current.transcriptVersion == document.version, document.spans.contains(where: { $0.id == spanID }) else { return }
        readingPositions[document.sessionID] = RecordingReadingPosition(generation: document.generation, spanID: spanID)
    }

    func recording(_ id: UUID) -> RecordingSummary? {
        recordings.first { $0.id == id } ?? searchedRecordings[id]
    }

    /// Sources can reference an older recording outside the currently loaded list pages.
    func ensureRecording(_ id: UUID) async throws {
        let summary = try await archive.recordingSummary(sessionID: id)
        let issues = try await archive.recordingFileIssues(sessionID: id)
        if let index = recordings.firstIndex(where: { $0.id == id }) { recordings[index] = summary }
        else { searchedRecordings[id] = summary }
        if let issue = issues.first(where: { $0.sessionID == id }) { fileIssues[id] = issue }
        else { fileIssues.removeValue(forKey: id) }
        updateTranscriptCache()
    }

    func search(_ query: String, loadMore: Bool = false) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if loadMore { guard !isSearching, query == searchQuery, nextSearchCursor != nil else { return } }
        searchGeneration &+= 1
        let selection = searchGeneration
        let cursor = loadMore ? nextSearchCursor : nil
        if query != searchQuery { searchedRecordings = [:] }
        searchQuery = query
        if !loadMore { searchResults = []; nextSearchCursor = nil }
        searchFailure = nil
        guard !query.isEmpty else { isSearching = false; return }
        guard query.utf8.count <= 256 else {
            isSearching = false
            searchFailure = String(localized: "搜索词太长，请缩短后重试。")
            return
        }
        isSearching = true
        defer { if selection == searchGeneration { isSearching = false } }
        do {
            let page = try await archive.searchTranscriptsPage(query: query, limit: 20, cursor: cursor)
            var results: [LibrarySearchResult] = []
            var summaries: [UUID: RecordingSummary] = [:]
            for hit in page.items {
                try Task.checkCancellation()
                let summary = try await archive.recordingSummary(sessionID: hit.source.sessionID)
                // Revisions and deletions between search and navigation must not expose old text.
                try await archive.validateSources([hit.source])
                summaries[summary.id] = summary
                results.append(LibrarySearchResult(hit: hit, recording: summary))
            }
            try Task.checkCancellation()
            guard selection == searchGeneration else { return }
            searchedRecordings.merge(summaries) { _, new in new }
            if loadMore {
                let visible = Set(searchResults.map(\.id))
                searchResults.append(contentsOf: results.filter { !visible.contains($0.id) })
            } else { searchResults = results }
            nextSearchCursor = page.nextCursor
        } catch is CancellationError {
            // A new query or leaving the page owns the next result.
        } catch {
            guard selection == searchGeneration else { return }
            searchFailure = String(localized: "搜索结果暂时无法读取，请重试。")
        }
    }

    private func transcriptPreviews(for recordings: [RecordingSummary], issues: Set<UUID>) async -> [UUID: String] {
        var result: [UUID: String] = [:]
        var missingRequests: [(sessionID: UUID, expectedVersion: Int64, expectedGeneration: Int64)] = []
        let previousByID = Dictionary(uniqueKeysWithValues: self.recordings.map { ($0.id, $0) })
        for recording in recordings where recording.transcriptVersion > 0 && !issues.contains(recording.id) {
            if let previous = previousByID[recording.id],
               previous.transcriptVersion == recording.transcriptVersion,
               previous.generation == recording.generation,
               let preview = previews[recording.id] {
                result[recording.id] = preview
                continue
            }
            missingRequests.append((
                sessionID: recording.id,
                expectedVersion: recording.transcriptVersion,
                expectedGeneration: recording.generation
            ))
        }
        if !missingRequests.isEmpty,
           let fetched = try? await archive.transcriptPreviews(requests: missingRequests) {
            result.merge(fetched) { _, latest in latest }
        }
        return result
    }

    init(archive: ArchiveStore, configurationFingerprint: String? = nil,
         cachedSummaries: (@MainActor ([String]) -> [String: String])? = nil,
         summarize: (@Sendable ([TimelineWindow]) async throws -> [String: String])? = nil) {
        self.archive = archive
        self.configurationFingerprint = configurationFingerprint
        timeline = TimelineModel(archive: archive, configurationFingerprint: configurationFingerprint,
                                 cachedSummaries: cachedSummaries, summarize: summarize)
    }

    func updateCurrentWatchStatus(_ observation: WatchStatusObservation?) {
        watchStatus = observation
    }

    func dismissSpeakerFeedbackFailure() {
        speakerFeedbackFailure = nil
    }

    func awaitPendingSpeakerFeedback() async {
        while let chain = speakerFeedbackChain {
            await chain.value
            if inFlightSpeakerFeedbackCount == 0 { break }
        }
    }

    func effectiveSpeaker(
        for source: SourceReference,
        defaultSpeaker: String?,
        defaultAttribution: SpeakerAttribution?
    ) -> (speaker: String?, attribution: SpeakerAttribution?) {
        for override in pendingSpeakerOverrides.reversed() {
            guard override.sessionID == source.sessionID,
                  override.generation == source.generation,
                  source.transcriptVersion <= override.baseVersion else { continue }
            if override.spanIDs.contains(source.spanID) {
                return (override.speaker, override.attribution)
            }
            if let clusterID = override.clusterID, defaultAttribution?.clusterID == clusterID {
                let clusterAttribution = override.attribution.map {
                    SpeakerAttribution(
                        clusterID: clusterID,
                        personID: $0.personID,
                        isUser: $0.isUser,
                        confirmed: $0.confirmed,
                        canLearn: defaultAttribution?.canLearn ?? $0.canLearn
                    )
                }
                return (override.speaker, clusterAttribution)
            }
        }
        return (defaultSpeaker, defaultAttribution)
    }

    private func mergeInFlightOptimisticProfiles(into loaded: [SpeakerProfile]) -> [SpeakerProfile] {
        guard inFlightSpeakerFeedbackCount > 0, !optimisticProfilesByID.isEmpty else { return loaded }
        var merged = loaded
        for (id, entry) in optimisticProfilesByID {
            let exists = merged.contains {
                (entry.isUser && $0.isUser)
                    || (!$0.isUser && !entry.isUser && $0.name.caseInsensitiveCompare(entry.name) == .orderedSame)
            }
            if !exists {
                if entry.isUser {
                    merged.insert(SpeakerProfile(id: id, name: entry.name, isUser: true), at: 0)
                } else {
                    merged.append(SpeakerProfile(id: id, name: entry.name, isUser: false))
                }
            }
        }
        return merged
    }

    /// Applies optimistic profile & cluster/span updates immediately and serializes voiceprint/cluster writes off the UI path.
    func enqueueSpeakerFeedback(
        sources: [SourceReference],
        speakerNameHint: String?,
        feedback: SpeakerFeedback,
        scope: SpeakerFeedbackScope,
        optimisticSpeaker: String? = nil,
        optimisticAttribution: SpeakerAttribution? = nil,
        clusterID: UUID? = nil,
        onCommitted: (@MainActor () async -> Void)? = nil
    ) {
        let editID = UUID()
        inFlightSpeakerFeedbackCount += 1
        var createdTempID: UUID?
        switch feedback {
        case .owner:
            if !speakerProfiles.contains(where: \.isUser) {
                let id = optimisticAttribution?.personID ?? UUID()
                let ownerName = String(localized: "我")
                optimisticProfilesByID[id] = (name: ownerName, isUser: true)
                createdTempID = id
                speakerProfiles.insert(SpeakerProfile(id: id, name: ownerName, isUser: true), at: 0)
            }
        case .person(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               !speakerProfiles.contains(where: { !$0.isUser && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                let id = optimisticAttribution?.personID ?? UUID()
                optimisticProfilesByID[id] = (name: trimmed, isUser: false)
                createdTempID = id
                speakerProfiles.append(SpeakerProfile(id: id, name: trimmed, isUser: false))
            }
        default:
            break
        }
        let knownTarget: (name: String, isUser: Bool)? = {
            switch feedback {
            case .knownPerson(let candidateID), .notPerson(let candidateID):
                if let cached = optimisticProfilesByID[candidateID] { return cached }
                if let existing = speakerProfiles.first(where: { $0.id == candidateID }) {
                    return (existing.name, existing.isUser)
                }
                return nil
            default:
                return nil
            }
        }()
        if let first = sources.first {
            let maxBaseVersion = sources.filter { $0.sessionID == first.sessionID }.map(\.transcriptVersion).max() ?? first.transcriptVersion
            let spanSet = Set(sources.filter { $0.sessionID == first.sessionID }.map(\.spanID))
            pendingSpeakerOverrides.append(
                PendingSpeakerOverride(
                    editID: editID,
                    sessionID: first.sessionID,
                    generation: first.generation,
                    baseVersion: maxBaseVersion,
                    spanIDs: spanSet,
                    clusterID: scope == .cluster ? clusterID : nil,
                    speaker: optimisticSpeaker,
                    attribution: optimisticAttribution
                )
            )
        }
        let previous = speakerFeedbackChain
        let archive = self.archive
        speakerFeedbackChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.inFlightSpeakerFeedbackCount = max(0, self.inFlightSpeakerFeedbackCount - 1)
                if let createdTempID, self.inFlightSpeakerFeedbackCount == 0 {
                    self.optimisticProfilesByID.removeValue(forKey: createdTempID)
                } else if self.inFlightSpeakerFeedbackCount == 0 {
                    self.optimisticProfilesByID.removeAll()
                }
            }
            do {
                let freshSources = (try? await archive.resolveCurrentSpeakerSources(sources)) ?? sources
                var effectiveFeedback = feedback
                switch feedback {
                case .knownPerson(let candidateID):
                    let profiles = (try? await archive.speakerProfiles()) ?? self.speakerProfiles
                    if !profiles.contains(where: { $0.id == candidateID }), let target = knownTarget {
                        if target.isUser {
                            effectiveFeedback = .owner
                        } else if let matched = profiles.first(where: {
                            !$0.isUser && $0.name.caseInsensitiveCompare(target.name) == .orderedSame
                        }) {
                            effectiveFeedback = .knownPerson(matched.id)
                        } else {
                            effectiveFeedback = .person(target.name)
                        }
                    }
                case .notPerson(let candidateID):
                    let profiles = (try? await archive.speakerProfiles()) ?? self.speakerProfiles
                    if !profiles.contains(where: { $0.id == candidateID }) {
                        if knownTarget?.isUser == true || speakerNameHint == String(localized: "我"),
                           let owner = profiles.first(where: \.isUser) {
                            effectiveFeedback = .notPerson(owner.id)
                        } else if let hint = knownTarget?.name ?? speakerNameHint,
                                  let matched = profiles.first(where: {
                                      !$0.isUser && $0.name.caseInsensitiveCompare(hint) == .orderedSame
                                  }) {
                            effectiveFeedback = .notPerson(matched.id)
                        }
                    }
                default:
                    break
                }
                try await archive.correctSpeakers(
                    freshSources,
                    feedback: effectiveFeedback,
                    scope: scope,
                    deferGlobalRematch: true
                )
                if let latestProfiles = try? await archive.speakerProfiles() {
                    self.speakerProfiles = self.mergeInFlightOptimisticProfiles(into: latestProfiles)
                }
                let affectedSessions = Set(freshSources.map(\.sessionID))
                var affectedDays: Set<TimelineDay> = [TimelineDay(Date())]
                for sessionID in affectedSessions {
                    try? await self.ensureRecording(sessionID)
                    if let summary = self.recording(sessionID) {
                        affectedDays.insert(TimelineDay(summary.recordedAt))
                        if summary.transcriptVersion > 0, self.fileIssues[sessionID] == nil {
                            self.previews[sessionID] = try? await archive.transcriptPreview(
                                sessionID: sessionID,
                                expectedVersion: summary.transcriptVersion,
                                expectedGeneration: summary.generation
                            )
                        }
                    }
                }
                self.searchGeneration &+= 1
                self.searchRevision &+= 1
                self.snapshotRevision &+= 1
                self.timeline.discardPendingReads(days: affectedDays)
                self.speakerFeedbackFailure = nil
                // Reload active detail views immediately so SourceReferences advance before timeline list refresh.
                await onCommitted?()
                self.pendingSpeakerOverrides.removeAll { $0.editID == editID }
                await self.timeline.refresh()
            } catch {
                self.pendingSpeakerOverrides.removeAll { $0.editID == editID }
                self.speakerFeedbackFailure = error.localizedDescription
                await self.refresh()
            }
        }
    }

    func removeCachedRecording(_ sessionID: UUID) {
        timeline.invalidate(sessionID: sessionID)
        generation &+= 1
        searchRevision &+= 1
        recordings.removeAll { $0.sessionID == sessionID }
        previews.removeValue(forKey: sessionID)
        searchedRecordings.removeValue(forKey: sessionID)
        searchResults.removeAll { $0.recording.id == sessionID }
        searchGeneration &+= 1
        isSearching = false
        fileIssues.removeValue(forKey: sessionID)
        readingPositions.removeValue(forKey: sessionID)
        updateTranscriptCache()
        if isLoading || isLoadingMore { refreshRequested = true }
    }

    func refresh(inspectFiles: Bool = true) async {
        refreshRequested = true
        if inspectFiles { pendingFileInspection = true }
        guard !isLoading, !isLoadingMore else { return }
        isLoading = true
        defer { isLoading = false }
        while refreshRequested {
            refreshRequested = false
            let runFileInspection = pendingFileInspection
            pendingFileInspection = false
            let selection = generation
            do {
                let visibleCount = max(50, self.recordings.count)
                var recordings: [RecordingSummary] = []
                var cursor: String?
                repeat {
                    let page = try await archive.recordingsPage(limit: 50, cursor: cursor)
                    recordings.append(contentsOf: page.items)
                    cursor = page.nextCursor
                } while cursor != nil && recordings.count < visibleCount && generation == selection
                let issues = runFileInspection ? try await archive.recordingFileIssues() : Array(self.fileIssues.values)
                let loadedProfiles = (try? await archive.speakerProfiles()) ?? self.speakerProfiles
                let previews = await transcriptPreviews(for: recordings, issues: Set(issues.map(\.sessionID)))
                var searched: [UUID: RecordingSummary] = [:]
                for id in searchedRecordings.keys {
                    if let current = try? await archive.recordingSummary(sessionID: id) { searched[id] = current }
                }
                guard generation == selection else { continue }
                let issuesByID = Dictionary(uniqueKeysWithValues: issues.map { ($0.sessionID, $0) })
                let changed = self.recordings.map(RecordingSearchIdentity.init) != recordings.map(RecordingSearchIdentity.init)
                    || self.fileIssues.mapValues(\.fingerprint) != issuesByID.mapValues(\.fingerprint)
                    || searchedRecordings.mapValues(RecordingSearchIdentity.init) != searched.mapValues(RecordingSearchIdentity.init)
                if changed {
                    let oldByID = Dictionary(uniqueKeysWithValues: self.recordings.map { ($0.id, $0) })
                    var affectedDays: Set<TimelineDay> = []
                    for current in recordings {
                        if let old = oldByID[current.id], RecordingSearchIdentity(old) == RecordingSearchIdentity(current),
                           self.fileIssues[current.id]?.fingerprint == issuesByID[current.id]?.fingerprint {
                            continue
                        }
                        affectedDays.insert(TimelineDay(current.recordedAt))
                        affectedDays.insert(TimelineDay(Date()))
                    }
                    var invalidatedAnySession = false
                    for old in self.recordings {
                        let current = recordings.first { $0.id == old.id }
                        if current == nil || current?.generation != old.generation || issuesByID[old.id] != nil {
                            timeline.invalidate(sessionID: old.id)
                            invalidatedAnySession = true
                        }
                    }
                    if !invalidatedAnySession {
                        if affectedDays.isEmpty { timeline.discardPendingReads() }
                        else { timeline.discardPendingReads(days: affectedDays) }
                    }
                    searchGeneration &+= 1
                    searchRevision &+= 1
                    isSearching = false
                    searchResults.removeAll { result in
                        let current = recordings.first { $0.id == result.recording.id } ?? searched[result.recording.id]
                        return current?.transcriptVersion != result.hit.source.transcriptVersion
                            || current?.generation != result.hit.source.generation
                            || issuesByID[result.recording.id] != nil
                    }
                }
                self.recordings = recordings
                self.speakerProfiles = self.mergeInFlightOptimisticProfiles(into: loadedProfiles)
                self.previews = previews
                searchedRecordings = searched
                nextRecordingsCursor = cursor
                fileIssues = issuesByID
                snapshotRevision &+= 1
                failure = nil
                // Render the selected timeline day before background detail prefetch touches ArchiveStore.
                await timeline.refresh()
                updateTranscriptCache(allowBackgroundPrefetch: runFileInspection)
            } catch {
                if generation == selection { failure = String(localized: "读取本机资料失败：\(error.localizedDescription)") }
                await timeline.refresh()
            }
        }
    }

    func loadMoreRecordings() async {
        guard !isLoading, !isLoadingMore, let cursor = nextRecordingsCursor else { return }
        isLoadingMore = true
        let selection = generation
        do {
            let page = try await archive.recordingsPage(limit: 50, cursor: cursor)
            let previews = await transcriptPreviews(for: page.items, issues: Set(fileIssues.keys))
            if generation == selection {
                self.previews.merge(previews) { _, new in new }
                let visible = Set(recordings.map(\.id))
                recordings.append(contentsOf: page.items.filter { !visible.contains($0.id) })
                nextRecordingsCursor = page.nextCursor
                failure = nil
            }
        } catch {
            if generation == selection { failure = String(localized: "读取更多录音失败：\(error.localizedDescription)") }
        }
        isLoadingMore = false
        if refreshRequested { await refresh() }
    }
}

private struct RecordingReadingPosition {
    let generation: Int64
    let spanID: UUID
}

/// Archive state describes durable work, while the runtime snapshot describes what is executing.
/// A cached `processing` row alone must not claim that native recognition is still running.
struct RecordingTranscriptionPresentation {
    enum Activity: Equatable { case preparing, transcribing, queued, deferred, failed, finished }
    let activity: Activity

    init(sessionID: UUID, state: RecordingTranscriptionState, snapshot: TranscriptionSnapshot?) {
        if snapshot?.phase == .failed, snapshot?.failedSessionID == sessionID {
            activity = .failed
        } else if let snapshot, snapshot.activeSessionID == sessionID, snapshot.nativeInFlight,
                  snapshot.phase == .preparing || snapshot.phase == .transcribing {
            activity = snapshot.phase == .preparing ? .preparing : .transcribing
        } else {
            switch state {
            case .failed: activity = .failed
            case .transcribed, .noSpeech, .completedWithoutText: activity = .finished
            case .pending, .processing:
                activity = snapshot?.phase == .paused || snapshot?.phase == .systemSuspended ? .deferred : .queued
            }
        }
    }

    var isActive: Bool { activity == .preparing || activity == .transcribing }

    var status: String? {
        switch activity {
        case .preparing: String(localized: "正在分析语音")
        case .transcribing: String(localized: "正在本机转写，已有内容可以先看")
        case .queued: String(localized: "等待本机整理")
        case .deferred: String(localized: "稍后继续整理，回到 App 后会自动继续")
        case .failed: String(localized: "转写暂未完成，音频已保留")
        case .finished: nil
        }
    }
}

extension RecordingTranscriptionState {
    var title: String {
        switch self {
        case .pending: String(localized: "等待转写")
        case .processing: String(localized: "正在处理")
        case .noSpeech: String(localized: "未检测到语音")
        case .completedWithoutText: String(localized: "已处理，无正文")
        case .transcribed: String(localized: "已有转录")
        case .failed: String(localized: "处理未完成")
        }
    }
}

extension RecordingAudioState {
    var title: String {
        switch self {
        case .available: String(localized: "原音保存在本机")
        case .partiallyExpired: String(localized: "部分原音已按保留设置清理")
        case .expired: String(localized: "原音已按保留设置清理")
        case .expiryPending: String(localized: "正在清理到期原音")
        case .missingUnexpected: String(localized: "部分原音文件意外缺失")
        case .unavailable: String(localized: "尚未收到原音")
        }
    }
}

struct LibrarySearchResult: Identifiable {
    var id: UUID { hit.source.spanID }
    let hit: TranscriptSearchHit
    let recording: RecordingSummary
}

private struct RecordingSearchIdentity: Equatable {
    let id: UUID
    let version: Int64
    let generation: Int64
    let chunkCount: Int
    let audioState: String
    let transcriptionState: String
    init(_ recording: RecordingSummary) {
        id = recording.id
        version = recording.transcriptVersion
        generation = recording.generation
        chunkCount = recording.chunkCount
        audioState = recording.audioState.rawValue
        transcriptionState = recording.transcriptionState.rawValue
    }
}

nonisolated struct RecordingTranscriptSnapshot: Sendable {
    let document: TranscriptDocument
    let locations: [UUID: TranscriptSpanLocation]
}

private nonisolated struct RecordingReadIdentity: Hashable, Sendable {
    let id: UUID
    let version: Int64
    let generation: Int64
    let chunkCount: Int
    let audioState: String
    init(_ recording: RecordingSummary) {
        id = recording.id; version = recording.transcriptVersion; generation = recording.generation
        chunkCount = recording.chunkCount; audioState = recording.audioState.rawValue
    }
}
