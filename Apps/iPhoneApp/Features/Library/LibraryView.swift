import SwiftUI
import Observation
import MoMoArchive
import MoMoContracts
import MoMoAgentClient

private struct TimelineDestination: Hashable {
    let windowID: TimelineWindowID
    var markID: UUID? = nil
}

struct LibraryView: View {
    @Bindable var model: LibraryModel
    let playback: AudioPlaybackController
    let transcription: TranscriptionSnapshot?
    let speechFailure: String?
    let batches: [TranscriptionBatch]
    let delete: (UUID) async throws -> Void
    let refresh: () async -> Void
    let canDiscuss: Bool
    let discuss: (SourceReference) -> Void
    var illustrations: LifeIllustrationStore? = nil
    var openSettings: (() -> Void)? = nil
    var retryTranscription: ((UUID, Int64) async throws -> Void)? = nil
    var discussSources: (([SourceReference]) -> Void)? = nil
    var retryTimeline: ((TimelineRetryRequest) async throws -> Void)? = nil
    var continueInBackground: (() async throws -> Void)? = nil
    var hasBackgroundContinuation = false
    var requestWatchStatus: (() -> Void)? = nil
    var onSpeakersChanged: (() async -> Void)? = nil
    var resolveFiles: ((RecordingFileIssue, RecordingFileRecoveryAction) async throws -> Void)? = nil
    @State private var requestingContinuation = false
    @State private var continuationFailure: String?
    @State private var resolvingDayFiles = false
    @State private var fileResolutionFailure: String?
    @State private var query = ""
    @State private var searching = false
    @State private var choosingDate = false
    @State private var sharingDay: TimelineDay?
    @State private var selectedIllustration: LifeIllustration?
    @State private var dateDraft = Date()
    @State private var pendingDay: TimelineDay?
    @State private var page = ScrollPosition(idType: TimelineDay.self)
    @State private var isPagerStuck = false
    @State private var selectedWindow: TimelineDestination?
    @State private var recordingID: UUID?
    @State private var navigationFailure: String?
    @State private var readingStates = TimelineDayReadingStates()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EarphoneCaptureRuntime.self) private var earphone: EarphoneCaptureRuntime?

    private var timeline: TimelineModel { model.timeline }
    private var dateRange: TimelineDateRange {
        TimelineDateRange(earliestDay: timeline.earliestDay, hasLoaded: timeline.hasLoadedDateRange)
    }

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let earphone, earphone.settings.device == .earphone { EarphoneStatusView(runtime: earphone) }
                else { WatchStatusView(observation: model.watchStatus) }
            }
            .padding(.horizontal, 24).padding(.top, 12)
            dateBar
            if !searching, !selectedDayFileIssues.isEmpty {
                fileIssueBanner(selectedDayFileIssues).padding(.horizontal, 24)
            }
            if !searching, let progress = timeline.processingProgress[timeline.selectedDay], progress.received > 0,
               progress.processed == nil || (progress.remaining ?? 0) >= 0.01 || progress.awaitingSync > 0 {
                processingProgress(progress).padding(.horizontal, 24)
            }
            if searching { searchField.padding(.horizontal, 24) }
            if searching && !query.isEmpty { searchResults }
            else { dayPager }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .phonePageSurface()
        .watchStatusRefresh(requestWatchStatus)
        .navigationTitle("转录")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !searching, let illustrations, !selectedDayIllustrations.isEmpty {
                    LifeIllustrationStripView(items: selectedDayIllustrations, store: illustrations,
                        open: { selectedIllustration = $0 }, showSource: showIllustrationSource,
                        failure: { navigationFailure = $0 })
                }
                if playback.activeTarget != nil {
                    AudioMiniPlayer(playback: playback, openRecording: { id in openRecording(id) },
                        openWindow: { recordingID = nil; selectedWindow = TimelineDestination(windowID: $0) })
                        .padding(.horizontal, 12).padding(.vertical, 8).background(MoMoPalette.canvas)
                }
            }
        }
        .navigationDestination(item: $selectedWindow) { destination in
            TimelineDetailView(id: destination.windowID, library: model, playback: playback,
                transcription: transcription, speechFailure: speechFailure,
                retryTimeline: retryTimeline, canDiscuss: canDiscuss, discuss: { sources in
                    if let discussSources { discussSources(sources) }
                    else if let first = sources.first { discuss(first) }
                }, initialMarkID: destination.markID, onSpeakersChanged: onSpeakersChanged,
                resolveFiles: resolveFiles, openRecording: { openRecording($0) },
                requestWatchStatus: requestWatchStatus)
        }
        .navigationDestination(item: $recordingID) { id in
            RecordingDetailView(sessionID: id, library: model, playback: playback,
                transcription: transcription, retryTranscription: retryTranscription,
                delete: delete, canDiscuss: canDiscuss, discuss: discuss,
                onSpeakersChanged: onSpeakersChanged, resolveFiles: resolveFiles,
                requestWatchStatus: requestWatchStatus)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharingDay = timeline.selectedDay } label: {
                    Label("分享", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
                .accessibilityIdentifier("timeline.share")
            }
            if let openSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { Button("设置", systemImage: "gearshape", action: openSettings) }
                    label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("转录更多操作").accessibilityIdentifier("library.more")
                }
            }
        }
        .sheet(isPresented: $choosingDate) { datePicker }
        .sheet(item: $sharingDay) { day in
            TimelineShareView(day: day, archive: model.archive, configurationFingerprint: timeline.configurationFingerprint)
        }
        .fullScreenCover(item: $selectedIllustration) { item in
            if let illustrations {
                LifeIllustrationJourneyMapView(store: illustrations, initialID: item.id) { source in
                    selectedIllustration = nil
                    showIllustrationSource(source)
                }
            }
        }
        .alert("资料暂不可用", isPresented: Binding(get: { navigationFailure != nil }, set: { if !$0 { navigationFailure = nil } })) {
            Button("好", role: .cancel) { navigationFailure = nil }
        } message: { Text(navigationFailure ?? "") }
        .task { page.scrollTo(id: timeline.selectedDay, anchor: .leading); await refresh() }
        .task(id: timeline.selectedDay) { await timeline.load(timeline.selectedDay) }
        .onChange(of: page.viewID(type: TimelineDay.self)) { _, day in
            guard readingStates.isPagerSettled, page.isPositionedByUser,
                  let day, readingStates.alignedDay(in: timeline.days) == day else { return }
            timeline.select(day)
        }
        .onChange(of: dateRange) {
            if let pendingDay, !dateRange.isUnknown { select(pendingDay) }
        }
        .task(id: LibraryTimelineSearch(query: query, revision: model.searchRevision)) {
            do { if !query.isEmpty { try await Task.sleep(for: .milliseconds(250)) } }
            catch { return }
            await model.search(query)
        }
    }

    private var selectedDayIllustrations: [LifeIllustration] {
        let day = timeline.selectedDay
        let key = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        return (illustrations?.items ?? []).filter {
            $0.logicalDay == key && illustrations?.imageURL(for: $0) != nil
        }.sorted { $0.windowStart < $1.windowStart }
    }

    private func showIllustrationSource(_ source: LifeIllustration) {
        Task {
            let parts = source.logicalDay.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: source.timezone) ?? .current
            guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return }
            let sourceDay = TimelineDay(calendarDate: date, calendar: calendar)
            await timeline.load(sourceDay)
            select(sourceDay)
            let windows = timeline.listWindows[sourceDay] ?? []
            if let window = windows.first(where: {
                $0.id.start.timeIntervalSince1970 < source.windowEnd && $0.end.timeIntervalSince1970 > source.windowStart
            }) { selectedWindow = TimelineDestination(windowID: window.id) }
            else { navigationFailure = String(localized: "这段转录已不可用，请刷新后重试。") }
        }
    }

    private var dateBar: some View {
        HStack(spacing: 0) {
            Button { select(timeline.selectedDay.adding(days: -1)) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .disabled(!dateRange.canRequest(timeline.selectedDay.adding(days: -1)))
            .accessibilityLabel("前一天").accessibilityIdentifier("timeline.previousDay")
            Button {
                pendingDay = nil
                dateDraft = timeline.selectedDay.date(); choosingDate = true
            } label: {
                HStack(spacing: 5) {
                    Text(TimelineDate.day(timeline.selectedDay)).phoneText(.metadata)
                    Image(systemName: "chevron.down").font(.caption2)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("选择日期，\(TimelineDate.day(timeline.selectedDay))")
            .accessibilityIdentifier("timeline.datePicker")
            Button { select(timeline.selectedDay.adding(days: 1)) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(!dateRange.canRequest(timeline.selectedDay.adding(days: 1)))
            .accessibilityLabel("后一天").accessibilityIdentifier("timeline.nextDay")
            Button {
                searching.toggle()
                if !searching { query = "" }
            } label: { Image(systemName: searching ? "xmark" : "magnifyingglass").frame(width: 44, height: 44) }
                .accessibilityLabel(searching ? String(localized: "关闭搜索") : String(localized: "搜索全部转录"))
                .accessibilityIdentifier("timeline.search.toggle")
        }
        .foregroundStyle(MoMoPalette.ink).padding(.horizontal, 16)
    }

    private func processingProgress(_ progress: TimelineDayProgress) -> some View {
        let isToday = timeline.selectedDay == TimelineDay(Date())
        return VStack(alignment: .leading, spacing: 6) {
            if let processed = progress.processed, (progress.remaining ?? 0) >= 0.01 {
                if isToday {
                    Text("待处理 \(TimelineDate.duration(progress.received - processed))录音")
                        .phoneText(.metadata).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("timeline.todayProcessing")
                } else {
                    HStack {
                        Text("已接收音频的处理进度")
                        Spacer(minLength: 8)
                        Text("\(Int(min(1, processed / progress.received) * 100))%").monospacedDigit()
                    }.phoneText(.metadata)
                    ProgressView(value: processed, total: progress.received).tint(MoMoPalette.ink)
                        .accessibilityLabel("录音整理进度")
                        .accessibilityIdentifier("timeline.processingProgress")
                }
                if let processingNotice {
                    Text(processingNotice).phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                }
                if !isToday {
                    Text("已处理 \(Duration.seconds(processed).formatted(.time(pattern: .minuteSecond))) / 已收到 \(Duration.seconds(progress.received).formatted(.time(pattern: .minuteSecond)))")
                        .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                }
            } else if progress.processed == nil {
                Text("已收到 \(TimelineDate.duration(progress.received)) 原音，处理状态尚未就绪")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }
            if progress.awaitingSync > 0 { Text("另有 \(TimelineDate.duration(progress.awaitingSync)) 原音待同步").phoneText(.caption).foregroundStyle(MoMoPalette.muted) }
            if progress.unavailable > 0, (progress.remaining ?? 0) > 0 { Text("部分原音当前不可用，完整性可在录音信息中查看").phoneText(.caption).foregroundStyle(MoMoPalette.muted) }
            if (progress.remaining ?? progress.received) >= 0.01, let continueInBackground {
                Button {
                    requestingContinuation = true
                    continuationFailure = nil
                    Task {
                        defer { requestingContinuation = false }
                        do { try await continueInBackground() }
                        catch let error as BackgroundTranscriptionError { continuationFailure = error.localizedDescription }
                        catch is TranscriptionExecutionError { continuationFailure = String(localized: "当前整理任务正在切换，请稍后再试。") }
                        catch { continuationFailure = String(localized: "暂未能申请后台整理，已有原音和进度会保留。") }
                    }
                } label: {
                    Label(requestingContinuation ? String(localized: "正在申请…") : hasBackgroundContinuation ? String(localized: "后台整理已申请") : String(localized: "后台继续整理"),
                        systemImage: "arrow.down.circle")
                        .phoneText(.metadata).frame(minHeight: 44)
                }
                .disabled(requestingContinuation || hasBackgroundContinuation)
                .accessibilityIdentifier("timeline.continueInBackground")
                if let continuationFailure {
                    Text(continuationFailure).phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                        .accessibilityIdentifier("timeline.continueInBackground.status")
                }
            }
        }.accessibilityElement(children: .contain)
    }

    private var selectedDayFileIssues: [RecordingFileIssue] {
        guard !model.fileIssues.isEmpty else { return [] }
        let day = timeline.selectedDay
        var sessionIDs = Set((timeline.listWindows[day] ?? []).flatMap { $0.sources.map(\.sessionID) })
        for summary in model.recordings where TimelineDay(summary.recordedAt) == day {
            sessionIDs.insert(summary.id)
        }
        return sessionIDs.compactMap { model.fileIssues[$0] }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    private func fileIssueBanner(_ issues: [RecordingFileIssue]) -> some View {
        let restorable = issues.filter { $0.availableActions.contains(.restoreDatabase) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(issues.count == 1
                ? String(localized: "有 1 段录音的本地导出文件与记录不一致，暂未继续更新转录。")
                : String(localized: "有 \(issues.count) 段录音的本地导出文件与记录不一致，暂未继续更新转录。"))
                .phoneText(.metadata).foregroundStyle(MoMoPalette.ink)
            HStack(spacing: 16) {
                if let resolveFiles, !restorable.isEmpty {
                    Button {
                        resolvingDayFiles = true
                        fileResolutionFailure = nil
                        Task {
                            defer { resolvingDayFiles = false }
                            do {
                                for issue in restorable {
                                    try await resolveFiles(issue, .restoreDatabase)
                                }
                            } catch {
                                fileResolutionFailure = String(localized: "导出文件恢复未完成，请打开录音详情检查。")
                            }
                        }
                    } label: {
                        Label(resolvingDayFiles ? String(localized: "正在恢复…") : String(localized: "以应用内记录恢复并继续整理"),
                              systemImage: "arrow.clockwise.circle")
                            .phoneText(.metadata).frame(minHeight: 44)
                    }
                    .disabled(resolvingDayFiles)
                    .accessibilityIdentifier("timeline.fileIssues.restore")
                }
                if let first = issues.first {
                    Button { openRecording(first.sessionID) } label: {
                        Text("查看录音").phoneText(.metadata).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("timeline.fileIssues.openRecording")
                }
            }
            if let fileResolutionFailure {
                Text(fileResolutionFailure).phoneText(.caption).foregroundStyle(MoMoPalette.failure)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.fileIssues")
    }

    private var processingNotice: String? {
        if let explanation = TimelinePresentation.resourceExplanation(transcription) { return explanation }
        return switch transcription?.phase {
        case .idle, .preparing, .transcribing, .queued, nil: nil
        case .paused: String(localized: "处理已暂停，已有进度已保存")
        case .systemSuspended: String(localized: "系统已暂停后台处理，回到 App 后继续")
        case .failed: String(localized: "处理未完成，已有文字和原音已保留")
        case .waitingForAudio: String(localized: "正在等待缺失的原音或同步信息")
        case .waitingForContext: String(localized: "最新片段等待后续音频，前面的内容会先整理")
        case .waitingForRetry: String(localized: "部分片段稍后自动重试，其余录音已继续处理")
        case .audioUnavailable: String(localized: "部分原音不可用，可用的录音已继续处理")
        }
    }

    private var dayPager: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(timeline.days) { day in
                        TimelineDayPage(day: day, timeline: timeline, reading: readingStates.state(for: day),
                            transcription: transcription, speechFailure: speechFailure, dateRange: dateRange,
                            refresh: refresh, open: { selectedWindow = $0 })
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                            .id(day)
                            .accessibilityHidden(day != timeline.selectedDay)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            // Keep date navigation scoped to this scroll view, outside each day's reading position.
            .scrollPosition($page, anchor: .leading)
            .scrollIndicators(.hidden)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .accessibilityIdentifier("timeline.dayPager")
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting {
                    readingStates.pagerPhase = phase
                    readingStates.pagerInteracted = true
                } else if phase == .idle {
                    commitSettledDay()
                    readingStates.pagerPhase = .idle
                } else {
                    readingStates.pagerPhase = phase
                }
                updatePagerStuckState()
            }
            .onScrollGeometryChange(for: TimelinePagerSnapshot.self) {
                TimelinePagerSnapshot($0)
            } action: { old, snapshot in
                readingStates.snapshot = snapshot
                let layoutChanged = old.viewportWidth != snapshot.viewportWidth
                    || old.contentWidth != snapshot.contentWidth
                if layoutChanged, snapshot.viewportWidth > 0, snapshot.contentWidth >= snapshot.viewportWidth {
                    if readingStates.isPagerSettled {
                        readingStates.pendingDaysSync = false
                        page.scrollTo(id: timeline.selectedDay, anchor: .leading)
                    } else {
                        readingStates.pendingDaysSync = true
                    }
                }
                updatePagerStuckState()
            }
            .onChange(of: timeline.days, initial: true) {
                // Older dates can be inserted before the current page after the archive loads.
                guard readingStates.isPagerSettled else {
                    readingStates.pendingDaysSync = true
                    return
                }
                readingStates.pendingDaysSync = false
                page.scrollTo(id: timeline.selectedDay, anchor: .leading)
            }
            .task(id: isPagerStuck) {
                guard isPagerStuck else { return }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard readingStates.isMisalignedWhileIdle else {
                    isPagerStuck = false
                    return
                }
                snapMisalignedPager()
            }
        }
    }

    private var datePicker: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch dateRange {
                case .unknown:
                    if let failure = timeline.failures[timeline.selectedDay], !timeline.loading.contains(timeline.selectedDay) {
                        Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                        Button("重试读取日期范围") { Task { await timeline.load(timeline.selectedDay) } }
                            .frame(minHeight: 44).accessibilityIdentifier("timeline.calendar.retry")
                    } else {
                        ProgressView("正在读取日期范围")
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("timeline.calendar.loading")
                    }
                case .empty:
                    Text("还没有录音记录").phoneText(.body)
                        .accessibilityIdentifier("timeline.calendar.empty")
                    Button("今天") { choose(TimelineDay(Date())) }.frame(minHeight: 44)
                case .known(let bounds):
                    let upperDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: bounds.upperBound.date()) ?? bounds.upperBound.date()
                    let dates = bounds.lowerBound.date()...upperDate
                    DatePicker(String(localized: "选择日期"), selection: Binding(get: {
                        min(max(dateDraft, dates.lowerBound), dates.upperBound)
                    }, set: { dateDraft = $0 }), in: dates, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .accessibilityIdentifier("timeline.calendar")
                    HStack {
                        Button("今天") { choose(TimelineDay(Date())) }
                        Spacer()
                        Button("昨天") { choose(TimelineDay(Date()).adding(days: -1)) }
                            .disabled(!dateRange.canRequest(TimelineDay(Date()).adding(days: -1)))
                    }.frame(minHeight: 44)
                }
            }
            .padding(24).navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { pendingDay = nil; choosingDate = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if case .known(let bounds) = dateRange {
                            choose(min(max(TimelineDay(calendarDate: dateDraft), bounds.lowerBound), bounds.upperBound))
                        } else { choose(TimelineDay(Date())) }
                    }.disabled(dateRange.isUnknown).accessibilityIdentifier("timeline.calendar.done")
                }
            }
        }
        .task { if !timeline.hasLoadedDateRange { await timeline.load(timeline.selectedDay) } }
        .presentationDetents([.height(540), .large])
    }

    private var searchField: some View {
        TextField("搜索全部转录内容", text: $query).phoneText(.menu).submitLabel(.search)
            .padding(12).background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("library.search")
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(model.searchResults) { result in
                    Button {
                        Task {
                            do {
                                if let window = try await model.archive.timelineWindow(containing: result.hit.source,
                                    configurationFingerprint: model.configurationFingerprint) {
                                    await timeline.load(window.id.day)
                                    select(window.id.day); selectedWindow = TimelineDestination(windowID: window.id)
                                } else { openRecording(result.recording.id) }
                            } catch { navigationFailure = String(localized: "这条转录已更新或删除，请重新搜索。") }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(RecordingDatePresentation.title(result.recording.recordedAt)).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                            Text(result.hit.text).phoneText(.body).foregroundStyle(MoMoPalette.ink).lineLimit(3)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("library.search.result.\(result.id)")
                }
                if let failure = model.searchFailure { Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure) }
                else if model.isSearching, !model.searchResults.isEmpty {
                    ProgressView("正在搜索…").frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                else if !model.isSearching, model.searchResults.isEmpty { Text("没有找到相关转录，试试其他关键词。").phoneText(.metadata) }
                if model.hasMoreSearchResults {
                    Button("查看更多搜索结果") { Task { await model.search(query, loadMore: true) } }.frame(minHeight: 44)
                }
            }.padding(.horizontal, 24)
        }
        .modifier(TimelineReadingEdge())
        .overlay {
            if model.isSearching, model.searchResults.isEmpty, model.searchFailure == nil {
                ProgressView("正在搜索…")
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("library.search.loading")
                    .allowsHitTesting(false)
            }
        }
    }

    private func updatePagerStuckState() {
        let stuck = readingStates.isMisalignedWhileIdle
        if isPagerStuck != stuck { isPagerStuck = stuck }
    }

    private func commitSettledDay() {
        let wasUserSwipe = readingStates.pagerInteracted
        readingStates.pagerInteracted = false
        if wasUserSwipe {
            let target = readingStates.nearestDay(in: timeline.days)
                ?? page.viewID(type: TimelineDay.self).flatMap({ timeline.days.contains($0) ? $0 : nil })
                ?? timeline.selectedDay
            timeline.select(target)
        }
        if readingStates.pendingDaysSync {
            readingStates.pendingDaysSync = false
            page.scrollTo(id: timeline.selectedDay, anchor: .leading)
        }
    }

    private func snapMisalignedPager() {
        let target: TimelineDay
        if readingStates.pagerInteracted || page.isPositionedByUser {
            readingStates.pagerInteracted = false
            target = readingStates.nearestDay(in: timeline.days)
                ?? page.viewID(type: TimelineDay.self).flatMap({ timeline.days.contains($0) ? $0 : nil })
                ?? timeline.selectedDay
            timeline.select(target)
        } else {
            target = timeline.selectedDay
        }
        readingStates.pendingDaysSync = false
        isPagerStuck = false
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            page.scrollTo(id: target, anchor: .leading)
        }
    }

    private func select(_ day: TimelineDay) {
        guard dateRange.canRequest(day) else { pendingDay = nil; return }
        guard !dateRange.isUnknown else {
            pendingDay = day
            Task { await timeline.load(timeline.selectedDay) }
            return
        }
        pendingDay = nil
        let adjacent = day == timeline.selectedDay.adding(days: 1) || day == timeline.selectedDay.adding(days: -1)
        readingStates.pagerInteracted = false
        timeline.select(day)
        withAnimation(reduceMotion || !adjacent ? nil : .smooth(duration: 0.25)) {
            page.scrollTo(id: day, anchor: .leading)
        }
    }
    private func choose(_ day: TimelineDay) { select(day); choosingDate = false }
    private func openRecording(_ id: UUID) {
        Task {
            do {
                try await model.ensureRecording(id)
                selectedWindow = nil
                recordingID = id
            } catch {
                navigationFailure = String(localized: "这次录音已不可用，请刷新转录。")
            }
        }
    }


}

private struct LibraryTimelineSearch: Equatable { let query: String; let revision: UInt64 }

private struct TimelinePagerSnapshot: Equatable {
    var viewportWidth: CGFloat = 0
    var contentWidth: CGFloat = 0
    var nearestIndex: Int = 0
    var isAligned = true

    init() {}

    init(_ geometry: ScrollGeometry) {
        let width = geometry.containerSize.width
        let content = geometry.contentSize.width
        self.viewportWidth = width
        self.contentWidth = content
        guard width > 1, content >= width else {
            self.nearestIndex = 0
            self.isAligned = true
            return
        }
        let offset = geometry.contentOffset.x + geometry.contentInsets.leading
        let maxOffset = max(0, content - width)
        let clampedIndex = max(0, Int((min(max(offset, 0), maxOffset) / width).rounded()))
        let alignedOffset = CGFloat(clampedIndex) * width
        self.nearestIndex = clampedIndex
        self.isAligned = offset >= -1.5 && offset <= maxOffset + 1.5 && abs(offset - alignedOffset) <= 1.5
    }
}

// Each mounted day observes only its own scroll position. The store keeps positions when pages unmount.
@MainActor private final class TimelineDayReadingStates {
    private var values: [TimelineDay: TimelineDayReadingState] = [:]
    var pagerPhase: ScrollPhase = .idle
    var pagerInteracted = false
    var pendingDaysSync = false
    var snapshot = TimelinePagerSnapshot()

    var isPagerSettled: Bool {
        pagerPhase == .idle && !pagerInteracted
    }

    var isMisalignedWhileIdle: Bool {
        pagerPhase == .idle
            && snapshot.viewportWidth > 1
            && snapshot.contentWidth >= snapshot.viewportWidth
            && !snapshot.isAligned
    }

    func state(for day: TimelineDay) -> TimelineDayReadingState {
        if let state = values[day] { return state }
        let state = TimelineDayReadingState()
        values[day] = state
        return state
    }

    func nearestDay(in days: [TimelineDay]) -> TimelineDay? {
        guard !days.isEmpty, snapshot.viewportWidth > 1 else { return nil }
        let index = min(max(snapshot.nearestIndex, 0), days.count - 1)
        return days[index]
    }

    func alignedDay(in days: [TimelineDay]) -> TimelineDay? {
        guard snapshot.isAligned else { return nil }
        return nearestDay(in: days)
    }
}

@MainActor @Observable private final class TimelineDayReadingState {
    var position = ScrollPosition(idType: TimelineWindowID.self)
    var positioned = false
}

private struct TimelineDayPage: View {
    let day: TimelineDay
    let timeline: TimelineModel
    @Bindable var reading: TimelineDayReadingState
    let transcription: TranscriptionSnapshot?
    let speechFailure: String?
    let dateRange: TimelineDateRange
    let refresh: () async -> Void
    let open: (TimelineDestination) -> Void

    var body: some View {
        let windows = timeline.listWindows[day] ?? []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let repeatedClockRanges = timeline.repeatedClockRanges[day] ?? []
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 0) {
                        Button { open(TimelineDestination(windowID: window.id)) } label: {
                            TimelineRow(window: window, summary: timeline.summary(for: window),
                                status: TimelinePresentation.status(window, transcription: transcription, speechFailure: speechFailure),
                                connected: window.id != windows.last?.id,
                                continuesFromPrevious: window.id != windows.first?.id,
                                includeUTCOffset: repeatedClockRanges.contains(window.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.window.\(window.id.key)")
                        if !window.marks.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    ForEach(window.marks) { mark in
                                        Button {
                                            open(TimelineDestination(windowID: window.id, markID: mark.id))
                                        } label: {
                                            Label(TimelineDate.time(mark.recordedAt, offset: window.id.timezoneOffset, seconds: true), systemImage: "flag.fill")
                                                .phoneText(.caption).monospacedDigit().frame(minHeight: 44)
                                        }
                                        .buttonStyle(.plain).foregroundStyle(MoMoPalette.ink)
                                        .accessibilityLabel("查看 \(TimelineDate.time(mark.recordedAt, offset: window.id.timezoneOffset, seconds: true)) 的标记")
                                        .accessibilityIdentifier("timeline.mark.\(mark.id)")
                                    }
                                }
                            }.scrollIndicators(.hidden).padding(.leading, 26).padding(.bottom, 16)
                                .overlay(alignment: .leading) {
                                    if window.id != windows.last?.id {
                                        Rectangle().fill(MoMoPalette.line).frame(width: 1)
                                            .frame(width: 12).accessibilityHidden(true)
                                    }
                                }
                        }
                    }
                    .id(window.id)
                }
                if let failure = timeline.failures[day] {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                    Button("重试") { Task { await timeline.load(day) } }.frame(minHeight: 44)
                } else if windows.isEmpty, timeline.snapshots[day] != nil,
                          !timeline.loading.contains(day), !dateRange.isUnknown {
                    ContentUnavailableView(timeline.earliestDay == nil ? String(localized: "还没有可读的转录") : String(localized: "这一天没有可读的转录"),
                        systemImage: "waveform", description: Text(timeline.earliestDay == nil
                            ? String(localized: "在 Apple Watch 上开始录音，内容会自动出现在这里。")
                            : String(localized: "有说话的时段会显示在这里，长时间安静不会占据时间线。")))
                        .accessibilityIdentifier("timeline.day.empty")
                }
            }
            .scrollTargetLayout()
            .padding(.bottom, 24)
        }
        .overlay {
            if windows.isEmpty, timeline.failures[day] == nil,
               timeline.snapshots[day] == nil || timeline.loading.contains(day) || dateRange.isUnknown {
                ProgressView("正在读取记录")
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("timeline.day.loading")
                    .allowsHitTesting(false)
            }
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollPosition(Binding(get: {
            reading.position
        }, set: { position in
            // Offscreen pages must not replace this day's saved reading position.
            guard day == timeline.selectedDay else { return }
            reading.position = position
        }))
        .onScrollPhaseChange { _, phase in
            guard day == timeline.selectedDay, phase == .tracking || phase == .interacting else { return }
            // A delayed first load must not take control back after the reader starts scrolling.
            reading.positioned = true
        }
        .onChange(of: timeline.currentID(reading.position.viewID(type: TimelineWindowID.self))) { _, replacement in
            guard let previous = reading.position.viewID(type: TimelineWindowID.self),
                  let replacement, replacement != previous else { return }
            reading.position.scrollTo(id: replacement)
        }
        .onChange(of: day == timeline.selectedDay ? windows.last?.id : nil, initial: true) {
            guard day == timeline.selectedDay, !windows.isEmpty,
                  !reading.positioned else { return }
            reading.positioned = true
            var position = ScrollPosition(idType: TimelineWindowID.self)
            position.scrollTo(edge: .bottom)
            reading.position = position
        }
        .refreshable { await refresh() }
        .modifier(TimelineReadingEdge())
        // Keep the gutter outside the scrollable coordinate space. When archive
        // regrouping replaces a row ID, scrollTo(id:) can otherwise align that
        // inset target horizontally and consume the 24pt page margin.
        .padding(.horizontal, 24)
    }
}

// The date controls stay outside the two-axis pager so changing days preserves
// each list's scroll position. Soften just the content crossing that boundary.
private struct TimelineReadingEdge: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pastTop = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, pastTop in
                self.pastTop = pastTop
            }
            .overlay(alignment: .top) {
                if pastTop && !reduceTransparency {
                    LinearGradient(colors: [MoMoPalette.canvas, MoMoPalette.canvas.opacity(0)],
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
