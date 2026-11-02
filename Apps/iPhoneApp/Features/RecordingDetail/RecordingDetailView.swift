import SwiftUI
import MoMoArchive
import MoMoContracts

struct RecordingDetailView: View {
    let sessionID: UUID
    let library: LibraryModel
    let playback: AudioPlaybackController
    var transcription: TranscriptionSnapshot? = nil
    var retryTranscription: ((UUID, Int64) async throws -> Void)? = nil
    let delete: (UUID) async throws -> Void
    let canDiscuss: Bool
    let discuss: (SourceReference) -> Void
    var onSpeakersChanged: (() async -> Void)? = nil
    var resolveFiles: ((RecordingFileIssue, RecordingFileRecoveryAction) async throws -> Void)? = nil
    #if DEBUG
    var readingPositionObserver: (@MainActor (RecordingReadingDiagnostic) -> Void)? = nil
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var document: TranscriptDocument?
    @State private var locations: [UUID: TranscriptSpanLocation] = [:]
    @State private var coverage: RecordingCoverage?
    @State private var failure: String?
    @State private var confirmingDeletion = false
    @State private var deleting = false
    @State private var retrying = false
    @State private var retryFailure: String?
    @State private var resolvingFiles = false
    @State private var fileResolutionFailure: String?
    @State private var playbackSpanID: UUID?
    @State private var playbackRequestFailure: String?
    @State private var pendingReadingRestore: UUID?
    @State private var issuedReadingRestore: UUID?
    @State private var readyReadingRestore: ReadingRestorationRequest<RecordingReadingLayout>?
    @State private var readingPosition = ScrollPosition(idType: UUID.self)
    @State private var readingLayout: RecordingReadingLayout?
    @State private var visibleReadingSpans: Set<UUID> = []
    #if DEBUG
    @State private var readingViewportHeight: CGFloat = 0
    @State private var readingOccludedTop: CGFloat = 0
    #endif

    private var recording: RecordingSummary? { library.recording(sessionID) }
    private var fileIssue: RecordingFileIssue? { library.fileIssues[sessionID] }
    private var loadIdentity: TranscriptLoadIdentity? {
        recording.map { TranscriptLoadIdentity(sessionID: $0.sessionID, version: $0.transcriptVersion, generation: $0.generation,
                                               chunkCount: $0.chunkCount, state: $0.transcriptionState.rawValue,
                                               fileIssue: fileIssue?.fingerprint) }
    }

    var body: some View {
        let renderedLayout = readingLayout
        let renderedIdentity = renderedLayout?.loadIdentity
        let renderedDocument = document
        let renderedRestore = readyReadingRestore
        let renderedPendingRestore = pendingReadingRestore
        let renderedIssuedRestore = issuedReadingRestore
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                if let recording {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(RecordingDatePresentation.title(recording.recordedAt))
                            .phoneText(.title)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("transcript.date")
                        if let coverage {
                            Text("已收到内容 \(Duration.seconds(coverage.receivedDuration).formatted(.time(pattern: .minuteSecond)))")
                                .phoneText(.history).foregroundStyle(MoMoPalette.muted)
                                .accessibilityIdentifier("transcript.received")
                        }
                        if let status = processingStatus {
                            Text(status).phoneText(.history).foregroundStyle(MoMoPalette.muted)
                                .accessibilityIdentifier("transcript.status")
                        }
                    }.padding(.bottom, 14)
                }
                Section {
                        if let badge = completionBadge {
                            Label(badge, systemImage: isProcessing ? "waveform" : "checkmark")
                                .phoneText(.metadata).foregroundStyle(isProcessing ? MoMoPalette.muted : MoMoPalette.success)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(isProcessing ? MoMoPalette.surface : MoMoPalette.successBackground, in: Capsule())
                                .accessibilityIdentifier("transcript.progress")
                        }
                if canRetryTranscription, let retryTranscription, let recording {
                    VStack(alignment: .leading, spacing: 10) {
                        Button(retrying ? String(localized: "正在重试这段录音…") : String(localized: "重试未完成的转写")) {
                            retrying = true
                            retryFailure = nil
                            Task {
                                defer { retrying = false }
                                do { try await retryTranscription(sessionID, recording.generation) }
                                catch let error as ArchiveError {
                                    retryFailure = switch error {
                                    case .sessionDeleted, .missingRecording: String(localized: "这次录音已删除或不可用。")
                                    case .staleSource, .staleAttempt: String(localized: "录音资料已发生变化，请返回列表刷新后再试。")
                                    case .operationConflict: String(localized: "这段录音仍在处理批次中，暂时不能单独重试；已有内容可以继续阅读。")
                                    default: String(localized: "转写暂时无法重试，已收到的原音和文字会保留。")
                                    }
                                } catch is TranscriptionExecutionError {
                                    retryFailure = RecordingTranscriptionRetryError.busy.localizedDescription
                                } catch {
                                    retryFailure = (error as? RecordingTranscriptionRetryError)?.localizedDescription
                                        ?? String(localized: "转写暂时无法重试，已收到的原音和文字会保留。")
                                }
                            }
                        }
                        .phoneText(.menu).frame(minHeight: 44)
                        .disabled(retrying || deleting)
                        .accessibilityIdentifier("transcript.retry")
                        if let retryFailure {
                            Text(retryFailure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                                .accessibilityIdentifier("transcript.retry.failure")
                        }
                    }
                }
                if let issue = fileIssue {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("资料文件当前不可用，已有记录仍保留。")
                            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                            .accessibilityIdentifier("transcript.files.unavailable")
                        if let resolveFiles {
                            let choices: [(RecordingFileRecoveryAction, String)] = [
                                (.restoreDatabase, String(localized: "以应用内记录恢复导出文件")),
                                (.useMarkdown, String(localized: "采用 Markdown 文件修改")),
                                (.useJSON, String(localized: "采用 JSON 文件修改"))
                            ]
                            ForEach(choices.filter { issue.availableActions.contains($0.0) }, id: \.0.rawValue) { action, label in
                                Button(resolvingFiles ? String(localized: "正在处理…") : label) {
                                    resolvingFiles = true
                                    fileResolutionFailure = nil
                                    Task {
                                        defer { resolvingFiles = false }
                                        do { try await resolveFiles(issue, action) }
                                        catch { fileResolutionFailure = String(localized: "文件恢复未完成，请刷新后再试。") }
                                    }
                                }
                                .phoneText(.menu).frame(minHeight: 44)
                                .disabled(resolvingFiles || deleting)
                                .accessibilityIdentifier("transcript.files.resolve.\(action.rawValue)")
                            }
                            if let fileResolutionFailure {
                                Text(fileResolutionFailure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                            }
                        }
                    }
                } else if let document, document.sessionID == sessionID, document.generation == recording?.generation,
                          !document.spans.isEmpty {
                    let turns = document.readingTurns(locations: locations)
                    ForEach(turns) { span in
                        #if DEBUG
                        let recordsGeometry = readingPositionObserver != nil
                        #endif
                        transcript(span, in: document)
                            .padding(.bottom, span.id == turns.last?.id ? 0 : 8)
                            .id(span.id)
                            .readingParagraphBounds(span.id)
                            #if DEBUG
                            .onGeometryChange(for: ReadingSpanGeometry.self) { geometry in
                                ReadingSpanGeometry(diagnosticFrame: recordsGeometry
                                    ? geometry.frame(in: .named("recording-reading-viewport")) : nil,
                                    diagnosticVersion: recordsGeometry ? document.version : nil)
                            } action: { observation in
                                guard readingLayout == renderedLayout, renderedIdentity == loadIdentity,
                                      self.document?.sessionID == document.sessionID,
                                      self.document?.generation == document.generation,
                                      self.document?.version == document.version else { return }
                                traceReading("geometry", spanID: span.id, frame: observation.diagnosticFrame)
                            }
                            .onDisappear {
                                guard readingLayout == renderedLayout, renderedIdentity == loadIdentity,
                                      self.document?.generation == document.generation,
                                      self.document?.version == document.version else { return }
                                traceReading("disappear", spanID: span.id)
                            }
                            #endif
                    }
                    if isProcessing {
                        HStack(alignment: .center, spacing: 10) {
                            ProgressView().accessibilityHidden(true)
                            Text("后面的文字会继续出现在这里。")
                                .phoneText(.history).foregroundStyle(MoMoPalette.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                } else {
                    emptyContent
                }
                if let failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        .accessibilityIdentifier("transcript.failure")
                }
                } header: {
                    if let recording {
                        #if DEBUG
                        let recordsHeaderGeometry = readingPositionObserver != nil
                        #endif
                        AudioPlayerCard(playback: playback, target: .recording(sessionID, recording.generation),
                                        playLabel: String(localized: "回听已收到的原音"), actionIdentifier: "transcript.recording.play",
                                        unavailableReason: recordingAudioUnavailable, disabled: deleting)
                            .padding(.vertical, 8)
                            .background(MoMoPalette.canvas)
                            .readingViewportHeader()
                            #if DEBUG
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                guard recordsHeaderGeometry else { return 0 }
                                let frame = geometry.frame(in: .named("recording-reading-viewport"))
                                return frame.minY <= 0 ? max(0, frame.maxY) : 0
                            } action: { top in
                                readingOccludedTop = top
                                traceReading("header")
                            }
                            #endif
                    }
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .coordinateSpace(name: "recording-reading-viewport")
        .scrollPosition($readingPosition, anchor: .top)
        .onReadingViewportChange(identity: renderedLayout, hasHeader: recording != nil) { selection in
            guard let renderedLayout, selection.identity == renderedLayout, readingLayout == renderedLayout,
                  let renderedIdentity, renderedIdentity == loadIdentity, renderedIdentity.fileIssue == nil,
                  let renderedDocument, renderedDocument.sessionID == renderedIdentity.sessionID,
                  renderedDocument.generation == renderedIdentity.generation,
                  renderedDocument.version == renderedIdentity.version,
                  document?.sessionID == renderedDocument.sessionID,
                  document?.generation == renderedDocument.generation,
                  document?.version == renderedDocument.version else { return }
            visibleReadingSpans = selection.ids.intersection(renderedDocument.spans.map(\.id))
            #if DEBUG
            readingViewportHeight = selection.viewportHeight
            #endif
            traceReading("viewport")
            if let target = pendingReadingRestore, issuedReadingRestore != target,
               let anchor = selection.restorationAnchor {
                readyReadingRestore = ReadingRestorationRequest(identity: renderedLayout, spanID: target, anchor: anchor)
            } else { readyReadingRestore = nil }
            rememberVisibleParagraph()
        }
        .onScrollGeometryChange(for: ReadingRestorationRequest<RecordingReadingLayout>?.self) { geometry in
            guard geometry.containerSize.height > 0, geometry.contentSize.height > 0,
                  let renderedRestore, renderedRestore.identity == renderedLayout,
                  renderedRestore.spanID == renderedPendingRestore,
                  renderedRestore.spanID != renderedIssuedRestore else { return nil }
            return renderedRestore
        } action: { _, request in
            guard let request, readingLayout == request.identity,
                  loadIdentity == request.identity.loadIdentity,
                  pendingReadingRestore == request.spanID, issuedReadingRestore != request.spanID else { return }
            // Resolve the one command in the native scroll layout, after this document's
            // paragraph bounds have been admitted; generic view geometry can arrive first.
            issuedReadingRestore = request.spanID
            // Navigation can still be committing this layout; issue the command after that transaction.
            Task { @MainActor in
                await Task.yield()
                guard readingLayout == request.identity, loadIdentity == request.identity.loadIdentity,
                      pendingReadingRestore == request.spanID, issuedReadingRestore == request.spanID else { return }
                traceReading("scrollTo", spanID: request.spanID)
                readingPosition.scrollTo(id: request.spanID, anchor: request.anchor)
            }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting, pendingReadingRestore != nil {
                pendingReadingRestore = nil
                issuedReadingRestore = nil
                rememberVisibleParagraph()
            }
        }
        .accessibilityIdentifier("transcript.scroll")
        .phonePageSurface()
        .navigationTitle("录音")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if fileIssue == nil, let recording, let document,
               document.sessionID == recording.sessionID, document.generation == recording.generation,
               document.version == recording.transcriptVersion, let span = document.spans.first {
                VStack(spacing: 0) {
                    Button { discuss(document.source(for: span)) } label: {
                        Label(isProcessing ? String(localized: "围绕已有内容提问") : String(localized: "围绕这段录音提问"), systemImage: "bubble.left")
                            .phoneText(.body).frame(maxWidth: .infinity)
                            .padding(.vertical, 14).frame(minHeight: 52)
                            .foregroundStyle(MoMoPalette.paper)
                            .background(MoMoPalette.ink, in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDiscuss || deleting)
                    .accessibilityIdentifier("transcript.discuss")
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(MoMoPalette.canvas, ignoresSafeAreaEdges: [])
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("删除录音", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                        .accessibilityIdentifier("transcript.delete")
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("更多录音操作")
                .accessibilityIdentifier("transcript.more")
                .disabled(deleting || recording == nil)
            }
        }
        .confirmationDialog("删除这次录音及转录？相关的助理上下文也会清理。", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("删除录音与转录", role: .destructive) {
                deleting = true
                Task {
                    do {
                        await playback.stop()
                        try await delete(sessionID)
                        dismiss()
                    } catch {
                        await library.refresh()
                        failure = String(localized: "删除尚未完成，请稍后重试。")
                    }
                    deleting = false
                }
            }
        }
        .task(id: loadIdentity) { await load() }
    }

    private func rememberVisibleParagraph() {
        guard let document, document.sessionID == sessionID,
              let readingLayout, readingLayout.loadIdentity == loadIdentity,
              readingLayout.loadIdentity.generation == document.generation,
              readingLayout.loadIdentity.version == document.version else { return }
        if let restoring = pendingReadingRestore {
            // Initial top-of-page layout must not overwrite the saved off-screen anchor.
            guard issuedReadingRestore == restoring, visibleReadingSpans.contains(restoring) else { return }
            pendingReadingRestore = nil
            traceReading("restore-complete", spanID: restoring)
        }
        guard let first = document.spans.first(where: { visibleReadingSpans.contains($0.id) }) else { return }
        if library.readingAnchor(in: document) != first.id {
            library.rememberReadingPosition(first.id, in: document)
            traceReading("save", spanID: first.id)
        }
    }

    private func traceReading(_ event: String, spanID: UUID? = nil, frame: CGRect? = nil) {
        #if DEBUG
        guard let readingPositionObserver else { return }
        let spans = document?.spans ?? []
        readingPositionObserver(RecordingReadingDiagnostic(event: event, spanID: spanID,
            spanIndex: spanID.flatMap { id in spans.firstIndex(where: { $0.id == id }) },
            restoringSpanID: pendingReadingRestore, storedSpanID: document.flatMap { library.readingAnchor(in: $0) },
            visibleSpanIDs: spans.filter { visibleReadingSpans.contains($0.id) }.map(\.id),
            visibleIndices: spans.indices.filter { visibleReadingSpans.contains(spans[$0].id) },
            viewportHeight: readingViewportHeight, occludedTop: readingOccludedTop,
            version: document?.version ?? -1, spanCount: spans.count, frame: frame))
        #endif
    }

    private func transcript(_ span: TranscriptReadingTurn, in document: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let location = locations[span.id] {
                    Text(location.recordedAt.formatted(.dateTime.locale(AppLanguage.current.locale).hour().minute().second()))
                        .phoneText(.caption).monospacedDigit().foregroundStyle(MoMoPalette.muted)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("transcript.time.\(span.id)")
                }
                SpeakerFeedbackMenu(
                    speaker: span.speaker,
                    attribution: span.attribution,
                    source: span.source,
                    additionalSources: Array(span.sources.dropFirst()),
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
                }
                Spacer(minLength: 0)
                if locations[span.id]?.audioAvailable == true {
                    Button {
                        playbackSpanID = span.id
                        playbackRequestFailure = nil
                        Task {
                            do {
                                try await playback.toggle(.readingTurn(span))
                            } catch is CancellationError {
                                // A newer playback request owns the player.
                            } catch {
                                playbackRequestFailure = await AudioPlaybackFailure.message(for: error, source: span.source, archive: library.archive)
                                await library.refresh()
                            }
                        }
                    } label: {
                        Image(systemName: playback.activeTarget == .readingTurn(span) && playback.playbackState == .playing ? "pause" : "play")
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(playback.activeTarget == .readingTurn(span) && playback.playbackState == .playing ? String(localized: "暂停回听") : String(localized: "回听"))
                    .accessibilityIdentifier("transcript.play.\(span.id)")
                    .disabled(deleting)
                } else if locations[span.id] != nil {
                    Text("原音不可用").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                }
            }
            Text(span.text).phoneText(.transcript).textSelection(.enabled)
                .accessibilityIdentifier("transcript.text.\(span.id)")
            if playbackSpanID == span.id, let error = playbackRequestFailure ?? playback.failure {
                Text(error).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    .accessibilityIdentifier("transcript.playback.failure")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordingAudioUnavailable: String? {
        if fileIssue != nil { return String(localized: "资料文件需要处理，修复后可回听原音。") }
        switch recording?.audioState {
        case .expired: return String(localized: "原音已按保留设置清理，转录文字仍可阅读。")
        case .expiryPending: return String(localized: "原音正在清理，转录文字仍可阅读。")
        case .unavailable: return String(localized: "这次录音尚未收到可回听的原音。")
        default: return nil
        }
    }

    private var canRetryTranscription: Bool {
        fileIssue == nil && (retrying || retryFailure != nil || recording?.transcriptionState == .failed
            || (recording?.transcriptionState == .pending && transcription == nil)
            || (transcription?.phase == .failed && transcription?.failedSessionID == sessionID))
    }

    private var isProcessing: Bool {
        transcriptionPresentation?.isActive == true
    }

    private var transcriptionPresentation: RecordingTranscriptionPresentation? {
        recording.map { RecordingTranscriptionPresentation(sessionID: sessionID, state: $0.transcriptionState, snapshot: transcription) }
    }

    private var completionBadge: String? {
        if isProcessing { return String(localized: "正在本机转写") }
        guard recording?.transcriptionState == .transcribed,
              coverage?.epochs.contains(where: { !$0.pending.isEmpty || !$0.failed.isEmpty }) != true else { return nil }
        return String(localized: "已收到的内容已转写")
    }

    private var processingStatus: String? {
        if transcriptionPresentation?.activity == .failed {
            return String(localized: "部分内容未能完成转写，已收到的音频会保留。")
        }
        if isProcessing { return String(localized: "正在分析语音，已有内容可以先阅读。") }
        if coverage?.epochs.contains(where: { !$0.notReceived.isEmpty }) == true { return String(localized: "还有录音未传到手机，已收到的内容可以先阅读。") }
        if let status = transcriptionPresentation?.status { return status }
        switch recording?.audioState {
        case .expired: return String(localized: "原音已按保留设置清理，文字仍可阅读。")
        case .partiallyExpired: return String(localized: "部分原音已清理，文字仍可阅读。")
        case .expiryPending: return String(localized: "正在清理到期原音，文字仍可阅读。")
        case .missingUnexpected: return String(localized: "部分原音文件缺失，请查看同步与转写详情。")
        default: return nil
        }
    }

    @ViewBuilder private var emptyContent: some View {
        if recording == nil {
            ContentUnavailableView("录音已删除或不可用", systemImage: "doc.questionmark")
        } else if recording?.transcriptionState == .noSpeech {
            ContentUnavailableView("没有检测到说话声", systemImage: "waveform.slash")
        } else if recording?.transcriptionState == .completedWithoutText || document?.spans.isEmpty == true {
            ContentUnavailableView("这段录音没有转写文字", systemImage: "waveform",
                                   description: Text("识别未返回文字，或正文已被修改为空。"))
        } else if recording?.transcriptionState == .failed {
            ContentUnavailableView("转写尚未完成", systemImage: "exclamationmark.circle",
                                   description: Text("已收到的录音会保留。重新打开 App 后会再检查待处理内容。"))
        } else if failure == nil {
            ContentUnavailableView("等待转写", systemImage: "waveform",
                                   description: Text("转写完成后，文字会显示在这里。"))
        }
    }

    private func admit(_ snapshot: RecordingTranscriptSnapshot, expected: TranscriptLoadIdentity) {
        let loaded = snapshot.document
        guard loadIdentity == expected, loaded.sessionID == expected.sessionID,
              loaded.version == expected.version, loaded.generation == expected.generation else { return }
        let restoring = document == nil
        document = loaded
        locations = snapshot.locations
        // Cache seed and fresh confirmation are one displayed document. Replacing this
        // token between them can revoke an already queued native scroll restoration.
        if readingLayout?.loadIdentity != expected {
            readingLayout = RecordingReadingLayout(loadIdentity: expected, identity: UUID())
        }
        visibleReadingSpans.formIntersection(loaded.spans.map(\.id))
        if restoring {
            issuedReadingRestore = nil
            let anchor = library.readingAnchor(in: loaded)
            pendingReadingRestore = loaded.readingTurns(locations: locations).first { turn in
                turn.sources.contains { $0.spanID == anchor }
            }?.id
            traceReading("loaded-restore", spanID: pendingReadingRestore)
        } else { traceReading("loaded-append") }
        failure = nil
    }

    private func load() async {
        guard let expected = loadIdentity else {
            document = nil; coverage = nil; locations = [:]
            readingLayout = nil; pendingReadingRestore = nil; issuedReadingRestore = nil; visibleReadingSpans = []
            return
        }
        // Keep mounted paragraph identities while ASR appends a newer version in the same generation.
        // Revisions/deletions/file conflicts still remove the old content immediately.
        if document?.sessionID != expected.sessionID || document?.generation != expected.generation || expected.fileIssue != nil {
            document = nil
            coverage = nil
            locations = [:]
            readingLayout = nil
            pendingReadingRestore = nil
            issuedReadingRestore = nil
            visibleReadingSpans = []
        }
        if document == nil, expected.fileIssue == nil, let cached = library.cachedTranscript(sessionID) {
            admit(cached, expected: expected)
        }
        do {
            if expected.version > 0, expected.fileIssue == nil {
                let loaded = try await library.loadTranscript(expected.sessionID)
                try Task.checkCancellation()
                guard loadIdentity == expected else { return }
                admit(loaded, expected: expected)
            }
            // Coverage is supplemental. It must not hold already available text behind a spinner.
            do {
                let loadedCoverage = try await library.archive.recordingCoverage(sessionID: sessionID,
                    configurationFingerprint: library.configurationFingerprint)
                try Task.checkCancellation()
                guard loadIdentity == expected else { return }
                coverage = loadedCoverage
                failure = nil
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard !Task.isCancelled, loadIdentity == expected else { return }
                failure = String(localized: "同步与转写进度暂时无法读取，请重试。")
            }
        } catch is CancellationError {
            // The task for the new recording version owns the visible state.
        } catch {
            guard !Task.isCancelled, loadIdentity == expected else { return }
            document = nil
            locations = [:]
            readingLayout = nil; pendingReadingRestore = nil; issuedReadingRestore = nil; visibleReadingSpans = []
            failure = String(localized: "暂时无法读取这段录音，请返回列表后重试。")
        }
    }
}

#if DEBUG
nonisolated struct RecordingReadingDiagnostic: Sendable {
    let event: String
    let spanID: UUID?
    let spanIndex: Int?
    let restoringSpanID: UUID?
    let storedSpanID: UUID?
    let visibleSpanIDs: [UUID]
    let visibleIndices: [Int]
    let viewportHeight: CGFloat
    let occludedTop: CGFloat
    let version: Int64
    let spanCount: Int
    let frame: CGRect?

    var description: String {
        "\(event) span=\(String(describing: spanID)):\(String(describing: spanIndex)) restore=\(String(describing: restoringSpanID)) stored=\(String(describing: storedSpanID)) visible=\(visibleIndices) viewport=\(viewportHeight) occludedTop=\(occludedTop) version=\(version) spanCount=\(spanCount) frame=\(String(describing: frame))"
    }
}

private nonisolated struct ReadingSpanGeometry: Equatable, Sendable {
    let diagnosticFrame: CGRect?
    let diagnosticVersion: Int64?
}
#endif

private nonisolated struct TranscriptLoadIdentity: Hashable, Sendable {
    let sessionID: UUID
    let version: Int64
    let generation: Int64
    let chunkCount: Int
    let state: String
    let fileIssue: String?
}

private nonisolated struct RecordingReadingLayout: Equatable, Sendable {
    let loadIdentity: TranscriptLoadIdentity
    let identity: UUID
}
