import SwiftUI
import MoMoArchive
import MoMoContracts

struct TimelineDetailView: View {
    let id: TimelineWindowID
    let library: LibraryModel
    let playback: AudioPlaybackController
    let transcription: TranscriptionSnapshot?
    let speechFailure: String?
    let retryTimeline: ((TimelineRetryRequest) async throws -> Void)?
    let canDiscuss: Bool
    let discuss: ([SourceReference]) -> Void
    var initialMarkID: UUID? = nil
    var onSpeakersChanged: (() async -> Void)? = nil
    var resolveFiles: ((RecordingFileIssue, RecordingFileRecoveryAction) async throws -> Void)? = nil
    var openRecording: ((UUID) -> Void)? = nil
    #if DEBUG
    var readingPositionObserver: (@MainActor (TimelineReadingDiagnostic) -> Void)? = nil
    #endif
    @State private var window: TimelineWindow?
    @State private var entries: [TimelineDetailEntry] = []
    @State private var readableSpans: Set<UUID> = []
    @State private var readingOrder: [UUID: Int] = [:]
    @State private var references: [SourceReference] = []
    @State private var failure: String?
    @State private var retrying = false
    @State private var resolvingIssueSessionID: UUID?
    @State private var selectedMarkID: UUID?
    @State private var initialMarkConsumed = false
    @State private var readingPosition = ScrollPosition(idType: TimelineDetailEntry.ID.self)
    @State private var readingLayout: TimelineReadingLayoutToken?
    @State private var loadedIdentity: TimelineDetailLoadIdentity?
    @State private var pendingReadingRestore: UUID?
    @State private var issuedReadingRestore: UUID?
    @State private var readyReadingRestore: ReadingRestorationRequest<TimelineReadingLayoutToken>?
    @State private var viewport = TimelineReadingViewport()
    @State private var playbackScope = TimelineDetailPlaybackScope()

    private var loadIdentity: TimelineDetailLoadIdentity {
        TimelineDetailLoadIdentity(id: id, revisions: library.timeline.snapshots[id.day, default: []].map(\.revision),
            recordingRevisions: library.recordings.map {
                "\($0.id)/\($0.generation)/\($0.transcriptVersion)/\($0.chunkCount)/\($0.transcriptionState.rawValue)/\($0.audioState.rawValue)"
            } + library.fileIssues.values.map(\.fingerprint).sorted(),
                                   invalidationRevision: library.timeline.invalidationRevision)
    }

    private var target: AudioPlaybackTarget? {
        if let frozen = playbackScope.frozenTarget(playback.activeTarget, state: playback.playbackState, for: id) { return frozen }
        guard loadedIdentity?.id == id, let window else { return nil }
        return playback.target(for: window)
    }

    private var selectedMark: TimelineMark? { window?.marks.first { $0.id == selectedMarkID } }

    var body: some View {
        let renderedLayout = readingLayout
        let renderedIdentity = loadedIdentity
        let renderedRestore = readyReadingRestore
        let renderedPendingRestore = pendingReadingRestore
        let renderedIssuedRestore = issuedReadingRestore
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 10) {
                    TranscriptDetailDateHeader(date: TimelineDate.day(id.day),
                        time: window.map { TimelineDate.range($0.id, end: $0.end) },
                        duration: window.flatMap { $0.speechDuration > 0 ? String(localized: "说话约 \(TimelineDate.duration($0.speechDuration))") : nil })
                    if let window, let summary = library.timeline.summary(for: window) {
                        TimelineSummaryView(text: summary).padding(.top, 10)
                    }
                    if let window, !window.marks.isEmpty {
                        markPicker(window)
                        if let mark = selectedMark, mark.nearbyParagraphID == nil {
                            Text(window.state == .complete ? String(localized: "标记附近没有识别到文字。") : String(localized: "标记附近的文字还在整理。"))
                                .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                            markPlayback(mark, in: window)
                        }
                    }
                }.padding(.top, 20)
                if let window {
                    Section {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 0) {
                                switch entry {
                                case .paragraph(let paragraph): readingParagraph(paragraph)
                                case .issue(let issue): issueView(issue, in: window)
                                }
                            }
                        }
                        if readableSpans.isEmpty {
                            Text(window.state == .complete ? (window.speechDuration > 0 ? String(localized: "暂无可读文字，原音仍可回听。") : String(localized: "未识别到语音")) : String(localized: "文字整理好后会显示在这里。"))
                                .phoneText(.body).foregroundStyle(MoMoPalette.muted)
                                .accessibilityIdentifier("timeline.detail.empty")
                        }
                        if let explanation = TimelinePresentation.explanation(window, transcription: transcription, speechFailure: speechFailure) {
                            Text(explanation).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        }
                        if window.unavailableAudio {
                            Text("部分原音尚不可用或已清理，播放器中的断点不可定位，文字仍可阅读。")
                                .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        }
                        if window.sources.count > 1 {
                            Text("按说话片段连接回听，跳过长静默和未录音的间隔。")
                                .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                        }
                        if window.hasUnknownTail {
                            Text(window.state == .complete ? String(localized: "已处理完当前收到的音频。结束回执尚未同步，不影响现有文字和回听。") : String(localized: "已收到的原音会先处理，不等待结束回执。"))
                                .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                                .accessibilityIdentifier("timeline.detail.unknownTail")
                        }
                        if window.issues.isEmpty,
                           TimelinePresentation.hasRetryableFailure(window, transcription: transcription, speechFailure: speechFailure), retryTimeline != nil {
                            Button(retrying ? String(localized: "正在重新整理…") : String(localized: "重新整理这部分")) { retry(TimelineRetryRequest(window: window)) }
                                .phoneText(.menu).frame(minHeight: 44).disabled(retrying)
                                .accessibilityIdentifier("timeline.detail.retry")
                        }
                        if let failure { Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure) }
                    } header: {
                        if let target {
                            AudioPlayerCard(playback: playback, target: target, playLabel: String(localized: "播放这一时段的原音"),
                                actionIdentifier: "transcript.recording.play")
                                .padding(.vertical, 6).background(MoMoPalette.canvas)
                                .readingViewportHeader()
                        }
                    }
                } else if let failure { Text(failure).phoneText(.metadata) }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .overlay {
            if window == nil, failure == nil {
                ProgressView("正在读取这一时段")
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("timeline.detail.loading")
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "timeline-reading-viewport")
        .scrollPosition($readingPosition, anchor: .top)
        .onReadingViewportChange(identity: renderedLayout, hasHeader: target != nil) { selection in
            guard renderedIdentity == loadIdentity, let renderedLayout,
                  selection.identity == renderedLayout, readingLayout == renderedLayout, library.timeline.isCurrent(renderedLayout),
                  window != nil else { return }
            let visible = selection.ids.intersection(readableSpans)
            viewport.visibleSpans = visible
            viewport.restorationAnchor = selection.restorationAnchor
            #if DEBUG
            viewport.height = selection.viewportHeight
            #endif
            traceReading("viewport")
            if let target = pendingReadingRestore, issuedReadingRestore != target,
               let anchor = selection.restorationAnchor {
                readyReadingRestore = ReadingRestorationRequest(identity: renderedLayout, spanID: target, anchor: anchor)
            } else { readyReadingRestore = nil }
            rememberVisibleParagraph()
        }
        .onScrollGeometryChange(for: ReadingRestorationRequest<TimelineReadingLayoutToken>?.self) { geometry in
            guard geometry.containerSize.height > 0, geometry.contentSize.height > 0,
                  let renderedRestore, renderedRestore.identity == renderedLayout,
                  renderedRestore.spanID == renderedPendingRestore,
                  renderedRestore.spanID != renderedIssuedRestore else { return nil }
            return renderedRestore
        } action: { _, request in
            guard let request, loadedIdentity == loadIdentity, readingLayout == request.identity,
                  library.timeline.isCurrent(request.identity),
                  window?.id == request.identity.windowID, window?.revision == request.identity.revision,
                  pendingReadingRestore == request.spanID, issuedReadingRestore != request.spanID else { return }
            issuedReadingRestore = request.spanID
            Task { @MainActor in
                await Task.yield()
                guard loadedIdentity == loadIdentity, readingLayout == request.identity,
                      library.timeline.isCurrent(request.identity), pendingReadingRestore == request.spanID,
                      issuedReadingRestore == request.spanID else { return }
                traceReading("scrollTo", spanID: request.spanID)
                // Address the lazy row's identity; a nested bare UUID is not the mixed ForEach target.
                readingPosition.scrollTo(id: TimelineDetailEntry.ID.paragraph(request.spanID), anchor: request.anchor)
            }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                pendingReadingRestore = nil
                issuedReadingRestore = nil
                rememberVisibleParagraph()
            }
        }
        .accessibilityIdentifier("timeline.detail.scroll")
        .phonePageSurface().navigationTitle("转录详情").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if window != nil, !references.isEmpty {
                TranscriptDiscussAction(title: String(localized: "围绕这段时间提问"), enabled: canDiscuss) { discuss(references) }
            }
        }
        .task(id: loadIdentity) { await load() }
        .onChange(of: transcription?.failureScope) {
            if let window { updateEntries(window) }
        }
    }

    @ViewBuilder
    private func readingParagraph(_ paragraph: TranscriptReadingTurn) -> some View {
        #if DEBUG
        let layout = readingLayout
        let identity = loadedIdentity
        let recordsGeometry = readingPositionObserver != nil
        #endif
        paragraphView(paragraph)
            .readingParagraphBounds(paragraph.id)
            #if DEBUG
            .onGeometryChange(for: TimelineReadingGeometry.self) { geometry in
                TimelineReadingGeometry(layout: layout, frame: recordsGeometry
                    ? geometry.frame(in: .named("timeline-reading-viewport")) : nil)
            } action: { observation in
                guard identity == loadIdentity, let layout,
                      readingLayout == layout, library.timeline.isCurrent(layout) else { return }
                traceReading("geometry", spanID: paragraph.id, frame: observation.frame)
            }
            .onDisappear {
                guard readingLayout == layout else { return }
                traceReading("disappear", spanID: paragraph.id)
            }
            #endif
    }

    private func issueView(_ issue: TimelineIssuePresentation, in window: TimelineWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(TimelineDate.time(issue.start, offset: window.id.timezoneOffset, seconds: true))–\(TimelineDate.time(issue.end, offset: window.id.timezoneOffset, seconds: true)) · \(issue.title)")
                .phoneText(.metadata).monospacedDigit()
            Text(issue.explanation).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            if issue.issue.canRetry, retryTimeline != nil {
                Button(retrying ? String(localized: "正在整理…") : issue.retryTitle) {
                    retry(TimelineRetryRequest(window: window, issueID: issue.issue.id, frames: issue.frames))
                }
                .phoneText(.menu).frame(minHeight: 44).disabled(retrying)
                .accessibilityLabel("\(issue.retryTitle)，\(TimelineDate.time(issue.start, offset: window.id.timezoneOffset, seconds: true))至\(TimelineDate.time(issue.end, offset: window.id.timezoneOffset, seconds: true))")
                .accessibilityIdentifier("timeline.issue.retry.\(issue.id)")
            } else if issue.issue.kind == .transcriptUnavailable {
                let sessionID = issue.issue.source.sessionID
                HStack(spacing: 16) {
                    if let resolveFiles,
                       let fileIssue = library.fileIssues[sessionID],
                       fileIssue.availableActions.contains(.restoreDatabase) {
                        Button(resolvingIssueSessionID == sessionID ? String(localized: "正在恢复…") : String(localized: "以应用内记录恢复")) {
                            resolvingIssueSessionID = sessionID
                            failure = nil
                            Task {
                                defer { resolvingIssueSessionID = nil }
                                do {
                                    try await resolveFiles(fileIssue, .restoreDatabase)
                                    await load()
                                } catch {
                                    failure = String(localized: "导出文件恢复未完成，请稍后再试。")
                                }
                            }
                        }
                        .phoneText(.menu).frame(minHeight: 44)
                        .disabled(resolvingIssueSessionID != nil)
                        .accessibilityIdentifier("timeline.issue.restoreFiles.\(issue.id)")
                    }
                    if let openRecording {
                        Button("查看原录音") { openRecording(sessionID) }
                            .phoneText(.menu).frame(minHeight: 44)
                            .accessibilityIdentifier("timeline.issue.openRecording.\(issue.id)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.issue.\(issue.id)")
    }

    private func paragraphView(_ paragraph: TranscriptReadingTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(TimelineDate.time(paragraph.recordedAt, offset: id.timezoneOffset, seconds: true))
                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted).monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("transcript.time.\(paragraph.id)")
                SpeakerFeedbackMenu(
                    speaker: paragraph.speaker,
                    attribution: paragraph.attribution,
                    source: paragraph.source,
                    additionalSources: Array(paragraph.sources.dropFirst()),
                    initialPeople: library.speakerProfiles,
                    archive: library.archive,
                    enqueueFeedback: { sources, speakerHint, feedback, scope in
                        library.enqueueSpeakerFeedback(
                            sources: sources,
                            speakerNameHint: speakerHint,
                            feedback: feedback,
                            scope: scope
                        ) {
                            if let onSpeakersChanged { await onSpeakersChanged() }
                            await load()
                        }
                    }
                ) {
                    if let onSpeakersChanged { await onSpeakersChanged() }
                    else { await library.refresh() }
                    await load()
                }
                Spacer(minLength: 0)
                if paragraph.audioAvailable {
                    Button {
                        Task {
                            do {
                                try await playback.toggle(.readingTurn(paragraph))
                            } catch is CancellationError { }
                            catch { failure = String(localized: "这段原音暂时无法回听，请检查是否已同步或已清理。") }
                        }
                    } label: {
                        Image(systemName: playback.playingSpanID == paragraph.id ? "pause" : "play")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(playback.playingSpanID == paragraph.id ? String(localized: "暂停回听这段文字")
                        : playback.activeTarget == .readingTurn(paragraph) && playback.playbackState == .paused
                            ? String(localized: "继续回听这段文字") : String(localized: "回听这段文字"))
                    .accessibilityIdentifier("transcript.play.\(paragraph.id)")
                }
            }
            if let window, let mark = selectedMark, paragraph.sources.contains(where: { $0.spanID == mark.nearbyParagraphID }) {
                markPlayback(mark, in: window)
            }
            TranscriptParagraphText(text: paragraph.text, accessibilityID: "transcript.text.\(paragraph.id)")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if paragraph.sources.contains(where: { $0.spanID == selectedMark?.nearbyParagraphID }) {
                    RoundedRectangle(cornerRadius: 12).fill(MoMoPalette.ink.opacity(0.045))
                        .padding(-8)
                }
            }
    }

    private func markPicker(_ window: TimelineWindow) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(window.marks) { mark in
                    Button { selectMark(mark) } label: {
                        Label(TimelineDate.time(mark.recordedAt, offset: window.id.timezoneOffset, seconds: true), systemImage: "flag.fill")
                            .phoneText(.caption).monospacedDigit().padding(.horizontal, 12).frame(minHeight: 44)
                            .background(MoMoPalette.ink.opacity(selectedMarkID == mark.id ? 0.10 : 0.04), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("定位 \(TimelineDate.time(mark.recordedAt, offset: window.id.timezoneOffset, seconds: true)) 标记附近的文字")
                    .accessibilityAddTraits(selectedMarkID == mark.id ? [.isSelected] : [])
                    .accessibilityIdentifier("timeline.detail.mark.\(mark.id)")
                }
            }
        }.scrollIndicators(.hidden)
    }

    private func readingTurnID(for spanID: UUID?) -> UUID? {
        guard let spanID else { return nil }
        for entry in entries {
            if case .paragraph(let turn) = entry, turn.sources.contains(where: { $0.spanID == spanID }) { return turn.id }
        }
        return nil
    }

    private func selectMark(_ mark: TimelineMark) {
        selectedMarkID = mark.id
        pendingReadingRestore = readingTurnID(for: mark.nearbyParagraphID)
        issuedReadingRestore = nil
        if let paragraphID = pendingReadingRestore, let readingLayout, let anchor = viewport.restorationAnchor {
            readyReadingRestore = ReadingRestorationRequest(identity: readingLayout, spanID: paragraphID, anchor: anchor)
        } else { readyReadingRestore = nil }
    }

    private func markPlayback(_ mark: TimelineMark, in window: TimelineWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                guard let position = mark.playbackPosition(in: window.sources) else { return }
                Task {
                    do { try await playback.play(.window(window.id, window.sources), from: position) }
                    catch is CancellationError { }
                    catch { failure = String(localized: "标记处的原音暂时无法回听，请检查是否已同步或已清理。") }
                }
            } label: {
                Label("从 \(TimelineDate.time(mark.recordedAt, offset: window.id.timezoneOffset, seconds: true)) 标记处回听", systemImage: "play.fill")
                    .phoneText(.caption).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(!mark.audioAvailable || mark.playbackPosition(in: window.sources) == nil)
            .accessibilityIdentifier("timeline.mark.play.\(mark.id)")
            if mark.playbackPosition(in: window.sources) == nil {
                Text("标记位于当前录音末尾，可查看附近文字。")
                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
            } else if !mark.audioAvailable {
                Text("标记已保留，此处原音尚未同步或已不可用。")
                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
            }
        }
    }

    private func admit(_ loaded: (window: TimelineWindow, layout: TimelineReadingLayoutToken), expected: TimelineDetailLoadIdentity) {
        if readingLayout == loaded.layout, window == loaded.window {
            if loadedIdentity != expected { loadedIdentity = expected }
            if failure != nil { failure = nil }
            return
        }
        let continuing = window.map { previous in
            previous.id == loaded.window.id && previous.sources.allSatisfy { source in
                loaded.window.sources.contains { $0.sessionID == source.sessionID && $0.generation == source.generation }
            }
        } ?? false
        if !continuing { clearReadingLayout() }
        playbackScope.admit(loaded.window.id, for: id)
        window = loaded.window
        updateEntries(loaded.window)
        let paragraphs = entries.compactMap { entry -> TranscriptReadingTurn? in
            if case .paragraph(let turn) = entry { return turn }; return nil
        }
        readableSpans = Set(paragraphs.map(\.id))
        readingOrder = Dictionary(uniqueKeysWithValues: paragraphs.enumerated().map { ($0.element.id, $0.offset) })
        references = paragraphs.map(\.source)
        if pendingReadingRestore != nil, readingLayout != loaded.layout {
            issuedReadingRestore = nil
            readyReadingRestore = nil
        }
        readingLayout = loaded.layout
        loadedIdentity = expected
        // Appending can leave the native visible IDs unchanged, so no new visibility
        // callback is guaranteed. Preserve their intersection without moving the scroll view.
        viewport.visibleSpans.formIntersection(readableSpans)
        if !continuing {
            issuedReadingRestore = nil
            if !initialMarkConsumed, let mark = loaded.window.marks.first(where: { $0.id == initialMarkID }) {
                initialMarkConsumed = true
                selectMark(mark)
            } else {
                selectedMarkID = nil
                pendingReadingRestore = readingTurnID(for: library.timeline.readingAnchor(in: loaded.window, layout: loaded.layout))
            }
            traceReading("loaded-restore", spanID: pendingReadingRestore)
        } else { traceReading("loaded-append") }
        failure = nil
    }

    private func load() async {
        let expected = loadIdentity
        if window == nil, let cached = library.timeline.cachedWindow(id),
           cached.window.sources.allSatisfy({ library.fileIssues[$0.sessionID] == nil
               && library.recording($0.sessionID)?.generation == $0.generation }) {
            admit(cached, expected: expected)
        }
        do {
            var fallbackSources: [TimelineAudioSource] = []
            if let active = playback.snapshot?.target, active.windowID == id,
               case .window(_, let sources) = active { fallbackSources = sources }
            let ownedLayout = readingLayout.flatMap { library.timeline.isCurrent($0) ? $0 : nil }
            let loaded = try await library.timeline.loadWindow(id, previous: window,
                fallbackSources: fallbackSources, preservingLayout: ownedLayout)
            try Task.checkCancellation()
            guard loadIdentity == expected else { return }
            guard let loaded else {
                clearReadingLayout()
                window = nil
                failure = String(localized: "这一时段已删除或不可用。")
                return
            }
            admit(loaded, expected: expected)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, loadIdentity == expected else { return }
            clearReadingLayout()
            window = nil; failure = String(localized: "这一时段暂时无法读取，请返回后重试。")
        }
    }

    private func clearReadingLayout() {
        readingLayout = nil
        loadedIdentity = nil
        pendingReadingRestore = nil
        issuedReadingRestore = nil
        viewport.visibleSpans = []
        viewport.restorationAnchor = nil
        readingPosition = ScrollPosition(idType: TimelineDetailEntry.ID.self)
        entries = []; readableSpans = []; readingOrder = [:]; references = []
    }

    private func updateEntries(_ window: TimelineWindow) {
        entries = TimelineDetailEntry.ordered(window: window,
            issues: TimelineIssuePresentation.rows(for: window, failureScope: transcription?.failureScope))
    }

    private func rememberVisibleParagraph() {
        guard loadedIdentity == loadIdentity, let window, let readingLayout,
              library.timeline.isCurrent(readingLayout) else { return }
        if let restoring = pendingReadingRestore {
            guard issuedReadingRestore == restoring, viewport.visibleSpans.contains(restoring) else { return }
            pendingReadingRestore = nil
            traceReading("restore-complete", spanID: restoring)
        }
        guard let first = viewport.visibleSpans.min(by: { readingOrder[$0, default: .max] < readingOrder[$1, default: .max] }) else { return }
        if library.timeline.readingAnchor(in: window, layout: readingLayout) != first {
            library.timeline.rememberReadingPosition(first, in: window, layout: readingLayout)
            traceReading("save", spanID: first)
        }
    }

    private func traceReading(_ event: String, spanID: UUID? = nil, frame: CGRect? = nil) {
        #if DEBUG
        guard let readingPositionObserver else { return }
        let paragraphs = window?.paragraphs.filter(\.hasReadableText) ?? []
        let stored = window.flatMap { window in
            readingLayout.flatMap { library.timeline.readingAnchor(in: window, layout: $0) }
        }
        readingPositionObserver(TimelineReadingDiagnostic(event: event, spanID: spanID,
            spanIndex: spanID.flatMap { id in paragraphs.firstIndex { $0.id == id } },
            restoringSpanID: pendingReadingRestore, storedSpanID: stored,
            visibleSpanIDs: paragraphs.filter { viewport.visibleSpans.contains($0.id) }.map(\.id),
            viewportHeight: viewport.height, layout: readingLayout, frame: frame))
        #endif
    }

    private func retry(_ request: TimelineRetryRequest) {
        guard !retrying, let retryTimeline, loadedIdentity == loadIdentity,
              window?.id == request.window.id, window?.revision == request.window.revision else { return }
        let route = id
        retrying = true; failure = nil
        Task {
            defer { retrying = false }
            do {
                try await retryTimeline(request)
                guard id == route else { return }
                await load()
            } catch {
                guard id == route else { return }
                await load()
                guard id == route, let current = window,
                      current.id == request.window.id,
                      current.sources.allSatisfy({ source in request.window.sources.contains {
                          $0.sessionID == source.sessionID && $0.generation == source.generation
                      } }) else { return }
                if error as? ArchiveError == .staleSource {
                    failure = String(localized: "内容已更新，请按当前显示的时间范围重试。")
                } else {
                    failure = String(localized: "这部分仍未整理完成，已有文字和原音已保留。")
                }
            }
        }
    }
}

// Viewport bookkeeping must not invalidate the transcript body on every scroll update.
@MainActor private final class TimelineReadingViewport {
    var visibleSpans: Set<UUID> = []
    var restorationAnchor: UnitPoint?
    #if DEBUG
    var height: CGFloat = 0
    #endif
}

/// A regrouped detail can retain several admitted window IDs while its player keeps
/// the exact earlier range. Shared audio sources alone do not establish this ownership.
struct TimelineDetailPlaybackScope {
    private var routeID: TimelineWindowID?
    private var admitted: Set<TimelineWindowID> = []

    mutating func admit(_ windowID: TimelineWindowID, for routeID: TimelineWindowID) {
        if self.routeID != routeID { admitted.removeAll() }
        self.routeID = routeID
        admitted.insert(windowID)
    }

    func frozenTarget(_ target: AudioPlaybackTarget?, state: AudioPlaybackState?, for routeID: TimelineWindowID) -> AudioPlaybackTarget? {
        guard let target, state != .failed, let activeID = target.windowID,
              activeID == routeID || (self.routeID == routeID && admitted.contains(activeID)) else { return nil }
        return target
    }
}

private struct TimelineDetailLoadIdentity: Equatable {
    let id: TimelineWindowID
    let revisions: [String]
    let recordingRevisions: [String]
    let invalidationRevision: UInt64
}

#if DEBUG
private nonisolated struct TimelineReadingGeometry: Equatable, Sendable {
    let layout: TimelineReadingLayoutToken?
    let frame: CGRect?
}

nonisolated struct TimelineReadingDiagnostic: Sendable {
    let event: String
    let spanID: UUID?
    let spanIndex: Int?
    let restoringSpanID: UUID?
    let storedSpanID: UUID?
    let visibleSpanIDs: [UUID]
    let viewportHeight: CGFloat
    let layout: TimelineReadingLayoutToken?
    let frame: CGRect?

    var description: String {
        "\(event) index=\(String(describing: spanIndex)) span=\(String(describing: spanID)) restore=\(String(describing: restoringSpanID)) stored=\(String(describing: storedSpanID)) visible=\(visibleSpanIDs) viewport=\(viewportHeight) layout=\(String(describing: layout?.identity)) revision=\(layout?.revision ?? "nil") frame=\(String(describing: frame))"
    }
}
#endif
