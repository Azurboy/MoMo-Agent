import SwiftUI
import MoMoAgentClient
import MoMoContracts

struct DesktopTranscriptWindow: Identifiable {
    let source: ContextSource
    let window: ContextSourceWindow
    var id: String { window.id }
    var recordedAt: Double? { window.recordedAt ?? source.recordedAt }
    var endAt: Double? { window.endAt ?? recordedAt }
    var summary: String? { window.summary }
    var preview: String? { window.preview ?? source.preview }
}

struct DesktopSources: View {
    @Bindable var model: DesktopModel
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var observedToday = Calendar.current.startOfDay(for: Date())
    @State private var selectedID: String?
    @State private var query = ""
    @State private var searching = false
    @State private var choosingDate = false
    private let calendar = Calendar.current
    private static let clockFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    private var ordered: [DesktopTranscriptWindow] {
        model.sources.flatMap { source -> [DesktopTranscriptWindow] in
            if let windows = source.windows, !windows.isEmpty {
                return windows.map { DesktopTranscriptWindow(source: source, window: $0) }
            }
            let fallback = ContextSourceWindow(
                id: source.id,
                sourceId: source.id,
                sourceRevision: source.revision,
                recordedAt: source.recordedAt,
                endAt: source.recordedAt,
                offset: 0,
                end: source.totalCharacters,
                totalCharacters: source.totalCharacters,
                summary: source.summary,
                preview: source.preview
            )
            return [DesktopTranscriptWindow(source: source, window: fallback)]
        }
        .sorted { ($0.recordedAt ?? 0) < ($1.recordedAt ?? 0) }
    }

    private var visible: [DesktopTranscriptWindow] {
        ordered.filter { item in
            if !query.isEmpty {
                return (item.summary ?? item.preview ?? "").localizedStandardContains(query)
            }
            return item.recordedAt.map { calendar.isDate(Date(timeIntervalSince1970: $0), inSameDayAs: day) } ?? false
        }
    }

    private var selected: DesktopTranscriptWindow? {
        ordered.first { $0.id == selectedID }
    }

    private var earliest: Date {
        min(
            ordered.compactMap(\.recordedAt).min().map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0)) } ?? day,
            calendar.startOfDay(for: Date())
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720
            HStack(spacing: 0) {
                if wide || selected == nil {
                    timeline.frame(maxWidth: wide ? 340 : .infinity)
                }
                if wide { Divider() }
                if let selected {
                    DesktopSourceReader(
                        model: model,
                        source: selected.source,
                        window: selected.window,
                        close: wide ? nil : { selectedID = nil }
                    )
                    .id(selected.id + selected.source.revision + (selected.summary ?? ""))
                    .frame(maxWidth: .infinity)
                } else if wide {
                    ContentUnavailableView("选择一段转录", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(MoMoPalette.canvas)
        .task {
            await model.loadContext()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) } catch { break }
                let today = calendar.startOfDay(for: Date())
                if today != observedToday {
                    if calendar.isDate(day, inSameDayAs: observedToday) { day = today }
                    observedToday = today
                }
                await model.loadContext(silent: true)
            }
        }
        .onChange(of: ordered.map { $0.id + $0.source.revision }) {
            if selectedID != nil && selected == nil { selectedID = nil }
        }
    }

    private var timeline: some View {
        VStack(spacing: 14) {
            HStack {
                Text("转录").font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.loadContext() } }
                    .labelStyle(.iconOnly).buttonStyle(.plain).disabled(model.contextLoading)
                    .help("刷新转录").accessibilityIdentifier("desktop.transcripts.refresh")
            }.padding(.horizontal, 24).padding(.top, 12)
            dateBar
            if searching {
                TextField("搜索已同步的摘要与片段", text: $query).textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 24).accessibilityIdentifier("desktop.transcripts.search")
            }
            if let error = model.memoryError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).phoneText(.caption).foregroundStyle(MoMoPalette.failure)
                    Button("重试") { Task { await model.loadContext() } }
                }.padding(.horizontal, 24)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { item in
                        Button { selectedID = item.id } label: {
                            ClientTranscriptRow(
                                time: timeLabel(item),
                                preview: item.summary.map { MarkdownDocument.plainTextPreview($0) } ?? item.preview ?? "",
                                status: nil,
                                connected: item.id != visible.last?.id,
                                isFinal: true
                            ) {
                                EmptyView()
                            }
                            .padding(.horizontal, 12)
                            .background(selectedID == item.id ? MoMoPalette.surface : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("desktop.source.\(item.id)")
                        .accessibilityAddTraits(selectedID == item.id ? [.isSelected] : [])
                    }
                    if visible.isEmpty && !model.contextLoading && model.memoryError == nil {
                        ContentUnavailableView(
                            query.isEmpty ? "这一天还没有转录" : "没有匹配的转录",
                            systemImage: "waveform",
                            description: Text(query.isEmpty ? "手机同步的录音稿会按日期出现在这里。" : "搜索范围为已同步的摘要与原文片段。")
                        )
                        if query.isEmpty, let latest = ordered.last?.recordedAt,
                           !calendar.isDate(Date(timeIntervalSince1970: latest), inSameDayAs: day) {
                            Button("查看最近的转录") { day = calendar.startOfDay(for: Date(timeIntervalSince1970: latest)) }
                        }
                    }
                    if model.contextLoading { ProgressView("正在读取记录").padding(24) }
                }.padding(.horizontal, 12).padding(.bottom, 24)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dateBar: some View {
        HStack(spacing: 0) {
            Button { moveDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                .disabled(day <= earliest || !query.isEmpty).accessibilityLabel("前一天")
            Button { choosingDate = true } label: {
                HStack(spacing: 5) {
                    Text(query.isEmpty ? dayTitle(day) : String(localized: "全部日期")).phoneText(.metadata)
                    Image(systemName: "chevron.down").font(.caption2)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.popover(isPresented: $choosingDate) {
                VStack(spacing: 14) {
                    DatePicker("选择日期", selection: $day, in: earliest...Date(), displayedComponents: .date).datePickerStyle(.graphical)
                    HStack {
                        Button("今天") { day = calendar.startOfDay(for: Date()); query = ""; choosingDate = false }
                        Spacer()
                        Button("完成") { query = ""; choosingDate = false }
                    }
                }.padding(20).frame(width: 300)
            }
            Button { moveDay(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }
                .disabled(calendar.isDateInToday(day) || !query.isEmpty).accessibilityLabel("后一天")
            Button { searching.toggle(); if !searching { query = "" } } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass").frame(width: 36, height: 44)
            }.accessibilityLabel(searching ? "关闭搜索" : "搜索转录")
        }.buttonStyle(.plain).foregroundStyle(MoMoPalette.ink).padding(.horizontal, 16)
    }

    private func moveDay(_ value: Int) {
        if let next = calendar.date(byAdding: .day, value: value, to: day) { day = next }
    }

    private func dayTitle(_ date: Date) -> String {
        let monthDay = date.formatted(.dateTime.locale(AppLanguage.current.locale).month().day())
        if calendar.isDateInToday(date) { return String(localized: "今天 · \(monthDay)") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天 · \(monthDay)") }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return monthDay }
        return date.formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day())
    }

    private func timeLabel(_ item: DesktopTranscriptWindow) -> String {
        guard let timestamp = item.recordedAt else { return String(localized: "时间不详") }
        let start = Date(timeIntervalSince1970: timestamp)
        let end = Date(timeIntervalSince1970: item.endAt ?? timestamp)
        let startLabel = start.formatted(Self.clockFormat)
        let endLabel = end.formatted(Self.clockFormat)
        let range = startLabel == endLabel ? startLabel : "\(startLabel)–\(endLabel)"
        if query.isEmpty { return range }
        let dayPrefix = start.formatted(.dateTime.locale(AppLanguage.current.locale).month().day())
        return "\(dayPrefix) \(range)"
    }
}

struct DesktopSourceReader: View {
    let model: DesktopModel
    let source: ContextSource
    var window: ContextSourceWindow? = nil
    var close: (() -> Void)?
    var onDiscuss: (() -> Void)? = nil
    @State private var page: SourceTextPage?
    @State private var text = ""
    @State private var spans: [SourceTextSpan] = []
    @State private var loading = false
    @State private var error: String?

    private static let clockFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    private static let secondFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    private var recordedAt: Double? { window?.recordedAt ?? source.recordedAt }
    private var endAt: Double? { window?.endAt ?? recordedAt }
    private var summary: String? { window?.summary ?? source.summary }
    private var startOffset: Int { window?.offset ?? 0 }
    private var endOffset: Int { window?.end ?? source.totalCharacters }
    private var hasMore: Bool {
        guard let page else { return true }
        guard let next = page.nextOffset else { return false }
        return next < endOffset
    }

    private var headerTimeLabel: String {
        guard let timestamp = recordedAt else { return "" }
        let start = Date(timeIntervalSince1970: timestamp)
        let end = Date(timeIntervalSince1970: endAt ?? timestamp)
        let startLabel = start.formatted(Self.clockFormat)
        let endLabel = end.formatted(Self.clockFormat)
        return startLabel == endLabel ? startLabel : "\(startLabel)–\(endLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let close { Button("返回", action: close).buttonStyle(.plain).foregroundStyle(.secondary) }
                Spacer()
                Text("转录详情").font(.system(size: 14, weight: .medium))
                Spacer()
                if !hasMore && !text.isEmpty {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.plain).help("分享完整原文")
                }
            }.padding(.horizontal, 24).frame(height: 44)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let timestamp = recordedAt {
                            let date = Date(timeIntervalSince1970: timestamp)
                            TranscriptDetailDateHeader(
                                date: date.formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day()),
                                time: headerTimeLabel
                            )
                        }
                        if let summary, !summary.isEmpty {
                            TimelineSummaryView(text: summary).padding(.top, 10)
                        }
                    }.padding(.top, 20)

                    let visibleSpans = spans.filter { ($0.text ?? "").isEmpty == false }
                    if !visibleSpans.isEmpty {
                        ForEach(visibleSpans) { span in
                            VStack(alignment: .leading, spacing: 6) {
                                if let spanTime = span.recordedAt {
                                    Text(Date(timeIntervalSince1970: spanTime).formatted(Self.secondFormat))
                                        .phoneText(.caption)
                                        .foregroundStyle(MoMoPalette.muted)
                                        .monospacedDigit()
                                }
                                TranscriptParagraphText(
                                    text: span.text ?? "",
                                    accessibilityID: "transcript.text.\(span.id)"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if !text.isEmpty {
                        TranscriptParagraphText(text: text, accessibilityID: "desktop.source.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if hasMore || error != nil {
                        Button(error == nil ? "继续读取原文" : "重试读取") { Task { await more() } }
                            .buttonStyle(.plain).disabled(loading)
                    }
                    if loading { ProgressView("正在读取原文") }
                    if let error { Text(error).phoneText(.metadata).foregroundStyle(MoMoPalette.failure) }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !text.isEmpty {
                TranscriptDiscussAction(title: "围绕这段录音提问", enabled: model.taskStore != nil) {
                    guard let store = model.taskStore else { return }
                    let at = recordedAt.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day().hour().minute().second()) }
                    let reference = String(localized: "围绕") + (at.map { $0 + String(localized: "的") } ?? "") + String(localized: "这段录音，我想问：\n")
                    store.setDraft(store.draft.isEmpty ? reference : store.draft + "\n\n" + reference)
                    model.selection = "chat"
                    onDiscuss?()
                }.frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
        }
        .task { await more() }
    }

    private func more() async {
        guard !loading, hasMore else { return }
        loading = true; defer { loading = false }
        do {
            while hasMore {
                let currentOffset = page?.nextOffset ?? startOffset
                let remaining = max(1, endOffset - currentOffset)
                let limit = min(4000, remaining)
                let next = try await model.readSource(source, offset: currentOffset, limit: limit)
                try Task.checkCancellation()
                if !text.isEmpty && !next.text.isEmpty {
                    text += "\n" + next.text
                } else {
                    text += next.text
                }
                if let nextSpans = next.spans {
                    let existingIDs = Set(spans.map(\.id))
                    for span in nextSpans where !existingIDs.contains(span.id) {
                        spans.append(span)
                    }
                }
                page = next
                error = nil
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

/// Keep source navigation inside MoMo; Launch Services cannot resolve private recording URLs.
struct DesktopRecordingCitation: View {
    let model: DesktopModel
    let citation: RecordingCitation
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var retry = 0
    @State private var showingFullTranscript = false

    private enum LoadState {
        case loading, loaded(ResolvedRecordingCitation), failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("录音原文").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            switch state {
            case .loading:
                ProgressView("正在读取原文").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("暂时无法打开录音", systemImage: "waveform")
                } description: { Text(message) } actions: {
                    Button("重试") { retry += 1 }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let resolved):
                if showingFullTranscript {
                    DesktopSourceReader(model: model, source: resolved.source, close: { showingFullTranscript = false }, onDiscuss: { dismiss() })
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let time = resolved.span.recordedAt {
                                Text(Date(timeIntervalSince1970: time).formatted(.dateTime.year().month().day().hour().minute().second()))
                                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                            }
                            if resolved.showsUpdatedTranscript {
                                Text("录音已有更新，以下为当前原文。")
                                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                            }
                            TranscriptParagraphText(text: resolved.span.text ?? "", accessibilityID: "desktop.citation.text")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("查看完整转录") { showingFullTranscript = true }
                    }.padding(20)
                }
            }
        }
        .frame(width: 640, height: 540)
        .background(MoMoPalette.canvas)
        .task(id: retry) {
            state = .loading
            do {
                let result = try await model.readRecordingCitation(citation)
                try Task.checkCancellation()
                state = .loaded(result)
            } catch is CancellationError { }
            catch { state = .failed(error.localizedDescription) }
        }
    }
}
