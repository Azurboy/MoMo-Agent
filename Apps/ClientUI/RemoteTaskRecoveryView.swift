import SwiftUI
import MoMoAgentClient

struct RemoteTaskRecoveryView: View {
    let store: RemoteTaskStore
    var reconnect: (() -> Void)? = nil
    var retry: (() async -> Void)? = nil
    @State private var retrying = false

    var body: some View {
        if store.connectionState != .ready {
            HStack(spacing: 10) {
                Image(systemName: store.connectionState == .authenticationRequired ? "link.badge.plus" : "wifi.slash")
                Text(store.connectionState == .authenticationRequired ? "配对已失效" :
                        store.connectionState == .retrying ? "连接中断，正在重连" : "无法连接 Mac")
                Spacer(minLength: 8)
                if store.connectionState != .authenticationRequired {
                    Button {
                        retrying = true
                        Task {
                            defer { retrying = false }
                            if let retry { await retry() }
                            else { await store.retryConnection() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if retrying { ProgressView().controlSize(.small) }
                            Text(retrying ? "重连中" : "重连")
                        }
                    }.disabled(retrying).accessibilityIdentifier("remote.retryConnection")
                } else if let reconnect { Button("重新配对", action: reconnect) }
                else {
                    #if os(macOS)
                    SettingsLink { Text("检查连接") }
                    #endif
                }
            }.font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                .accessibilityIdentifier("remote.connectionRecovery")
        }
    }
}


struct RemoteTaskControlsView: View {
    let store: RemoteTaskStore
    var viewport: CGRect = .zero
    var onControlVisibility: ((AgentRun, AgentControl, Bool) -> Void)? = nil
    var openDesktop: (() -> Void)? = nil
    var returnDesktop: (() -> Void)? = nil
    @State private var contentHeight: CGFloat = 0
    @State private var controlsViewport = CGRect.zero
    // The composer only surfaces decisions and recovery, never the execution queue.
    private var runs: [AgentRun] {
        store.sharedRuns.filter {
            !$0.isTerminal && ($0.pendingControls?.isEmpty == false ||
                ["computer", "computer_human"].contains($0.waitReason ?? ""))
        }
    }
    private var backgroundAttention: [ConversationWork] {
        store.backgroundWork.filter { work in
            guard work.isPending else { return false }
            if work.reportRetryAvailable == true && work.state != "unknown" && work.reportState != "unknown" { return true }
            return work.waitReason == "computer_human" && !runs.contains { $0.workID == work.workID }
        }
    }
    private var rejectedSupplements: [RemoteTask] {
        store.tasks.filter { task in task.deliveryFailed && task.needsReview && task.targetRunID != nil && !store.messages.contains(where: { $0.operationID == task.id }) }
    }
    private var hasControls: Bool {
        !runs.isEmpty || !backgroundAttention.isEmpty || !rejectedSupplements.isEmpty || !store.rejectedSharedSupplements.isEmpty
    }
    var body: some View {
        if hasControls {
            let visibleControls = viewport.intersection(controlsViewport)
            VStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(backgroundAttention) { work in
                            RemoteBackgroundWorkRow(store: store, work: work, openDesktop: openDesktop, returnDesktop: returnDesktop)
                        }
                        ForEach(runs, id: \.runID) { run in
                            if let controls = run.pendingControls, !controls.isEmpty {
                                ForEach(controls) { control in
                                    RemoteControlCard(store: store, run: run, control: control,
                                                      openDesktop: openDesktop, returnDesktop: returnDesktop)
                                        .onGeometryChange(for: Bool.self) { geometry in
                                            let frame = geometry.frame(in: .global)
                                            return !visibleControls.isEmpty && frame.height > 0 && visibleControls.contains(frame)
                                        } action: { onControlVisibility?(run, control, $0) }
                                        .onDisappear { onControlVisibility?(run, control, false) }
                                }
                            } else {
                                RemoteRunRow(store: store, run: run, openDesktop: openDesktop,
                                             returnDesktop: returnDesktop)
                            }
                        }
                        ForEach(rejectedSupplements) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Label("这条补充未应用", systemImage: "arrow.uturn.backward")
                                Text(task.input).lineLimit(2).foregroundStyle(.secondary)
                                Button("改为新消息") { store.restoreAsNewMessage(task) }
                                    .disabled(!store.draft.isEmpty)
                                    .accessibilityIdentifier("remote.restoreSupplement.\(task.id)")
                            }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(store.rejectedSharedSupplements) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Label("这条补充未应用", systemImage: "arrow.uturn.backward")
                                Text(message.content).lineLimit(2).foregroundStyle(.secondary)
                                Button("改为新消息") { store.restoreAsNewMessage(message) }
                                    .disabled(!store.draft.isEmpty)
                            }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(contentHeight, 220))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlsViewport = $0 }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("remote.taskControls")
            }.padding(.horizontal, 20)
        }
    }
}

private struct RemoteRunRow: View {
    let store: RemoteTaskStore
    let run: AgentRun
    var openDesktop: (() -> Void)?
    var returnDesktop: (() -> Void)?
    private var waitingForComputer: Bool { ["computer", "computer_human"].contains(run.waitReason ?? "") }
    private var status: LocalizedStringKey {
        if run.cancelRequested == true { return "正在停止" }
        if waitingForComputer { return "等待交还电脑" }
        if run.waitReason == "computer_task" { return "等待另一任务使用完电脑" }
        if run.status == "queued" { return "排队中" }
        return "正在处理"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.title(for: run)).font(.footnote.weight(.medium)).lineLimit(2)
            HStack(spacing: 12) {
                Text(status).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if waitingForComputer {
                    if let openDesktop { Button("查看电脑", action: openDesktop) }
                    if let returnDesktop { Button("交还控制权", action: returnDesktop) }
                }
            }.font(.footnote)
        }.padding(.vertical, 5).accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote.task.\(run.runID)")
    }
}

private struct RemoteBackgroundWorkRow: View {
    let store: RemoteTaskStore
    let work: ConversationWork
    var openDesktop: (() -> Void)?
    var returnDesktop: (() -> Void)?
    private var stopping: Bool {
        store.isControlInFlight(work.id) || (work.cancelRequested == true && !["completed", "failed", "cancelled", "unknown"].contains(work.state))
    }
    private var status: LocalizedStringKey {
        if work.state == "cancelled" { return "已停止" }
        if work.state == "unknown" || work.reportState == "unknown" { return "结果待核对" }
        if stopping { return "正在停止" }
        if work.waitReason == "computer_human" { return "等待交还电脑" }
        if work.waitReason == "computer_task" { return "等待另一任务使用完电脑" }
        if work.state == "failed" { return "任务未完成" }
        if work.reportState == "failed" { return "结果回报未完成" }
        if ["running", "finalizing", "stalling"].contains(work.state) { return "后台进行中" }
        if work.reportState == "blocked" { return "结果已保存，等待继续" }
        return "正在整理任务结果"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: work.kind == "process" ? "terminal" : "tray").accessibilityHidden(true)
                if let title = work.title { Text(title).lineLimit(2) }
                else { Text("后台任务") }
            }.font(.footnote.weight(.medium))
            HStack {
                Text(status).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if work.waitReason == "computer_human" {
                    if let openDesktop { Button("查看电脑", action: openDesktop) }
                    if let returnDesktop { Button("交还控制权", action: returnDesktop) }
                }
                if work.reportRetryAvailable == true {
                    Button { Task { await store.retryReport(work) } } label: {
                        HStack(spacing: 5) {
                            if store.isControlInFlight(work.id) { ProgressView().controlSize(.small) }
                            Text("重新汇报")
                        }
                    }.disabled(store.isControlInFlight(work.id) || !store.canContactServer)
                        .accessibilityIdentifier("remote.retryReport.\(work.id)")
                }
            }.font(.footnote)
        }.padding(.vertical, 5).accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote.work.\(work.id)")
    }
}

private struct RemoteControlCard: View {
    let store: RemoteTaskStore
    let run: AgentRun
    let control: AgentControl
    var openDesktop: (() -> Void)?
    var returnDesktop: (() -> Void)?
    @State private var answer = ""
    @State private var answerBeingSent: String?
    private var sending: Bool { store.isControlInFlight(run.runID) }
    private var computer: Bool { ["computer", "computer_human"].contains(run.waitReason ?? "") || control.kind == "computer" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.title(for: run)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Label(computer ? "等待交还电脑" : control.kind == "approval" ? "需要你的确认" : "需要你补充", systemImage: computer ? "desktopcomputer" : "hand.raised")
                .font(.subheadline.weight(.semibold))
            if computer {
                HStack {
                    if let openDesktop { Button("查看电脑", action: openDesktop) }
                    if let returnDesktop { Button("交还控制权", action: returnDesktop) }
                    Spacer()
                }.font(.footnote)
            } else {
                if let detail = control.question ?? control.prompt ?? control.command { Text(detail).font(.footnote).textSelection(.enabled) }
            }
            if !computer && control.kind == "approval" {
                HStack {
                    Button { send("deny") } label: {
                        HStack { if answerBeingSent == "deny" { ProgressView().controlSize(.small) }; Text("拒绝") }
                    }.accessibilityIdentifier("remote.deny.\(run.runID)")
                    if control.choices?.contains("once") == true {
                        Button { send("once") } label: {
                            Text("允许这一次")
                        }.buttonStyle(ClientPrimaryButton(isLoading: answerBeingSent == "once"))
                            .accessibilityIdentifier("remote.approve.\(run.runID)")
                    }
                }.disabled(sending || run.cancelRequested == true || !store.canContactServer)
            } else if !computer {
                HStack {
                    TextField("回复", text: $answer).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("remote.answer.\(run.runID)")
                    Button { send(answer) } label: {
                        HStack { if answerBeingSent != nil { ProgressView().controlSize(.small) }; Text("发送") }
                    }.disabled(sending || run.cancelRequested == true || !store.canContactServer || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("remote.submitAnswer.\(run.runID)")
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
    private func send(_ value: String) {
        guard !sending, answerBeingSent == nil else { return }
        answerBeingSent = value
        Task { await store.respond(run: run, control: control, answer: value); answerBeingSent = nil }
    }
}

struct AgentActiveTasksSnapshot: Equatable {
    enum Backing: Equatable {
        case work(ConversationWork)
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let work: ConversationWork
        let title: String
        let statusLabel: String
        let originLabel: String?
        let dateBadge: String?
        let isCrossDaySource: Bool
        let summaryPreview: String?
        let isUrgent: Bool
        let isStopping: Bool
        let isHistorical: Bool
        let canStop: Bool
        var backing: Backing { .work(work) }
    }

    let items: [Item]
    var count: Int { items.count }
    var badgeText: String? {
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    @MainActor
    static func makeItem(from work: ConversationWork, store: RemoteTaskStore?, isRecent: Bool) -> Item {
        let parent = store?.sharedRuns.first {
            (work.workID != nil && $0.workID == work.workID) || $0.runID == work.originRunID
        }
        let rawTitle = (work.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = (parent?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = !rawTitle.isEmpty ? rawTitle : (!fallbackTitle.isEmpty ? fallbackTitle : String(localized: "后台任务"))

        let terminalStates: Set<String> = ["completed", "dropped", "failed", "cancelled", "unknown"]
        let terminalWork = isRecent || terminalStates.contains(work.state)
        let stopping = (store?.isControlInFlight(work.id) == true) || (work.cancelRequested == true && !terminalWork)
        let urgent = !isRecent && (
            work.waitReason == "computer_human"
            || work.waitReason == "clarify"
            || work.state == "failed"
            || work.reportState == "failed"
        )
        let statusLabel: String
        if stopping {
            statusLabel = String(localized: "正在停止")
        } else if isRecent {
            switch work.state {
            case "dropped":
                statusLabel = String(localized: "核查后跳过")
            case "cancelled":
                statusLabel = String(localized: "已停止")
            case "failed":
                statusLabel = String(localized: "执行未完成")
            default:
                statusLabel = String(localized: "已完成")
            }
        } else if work.waitReason == "computer_human" {
            statusLabel = String(localized: "等待交还电脑")
        } else if work.waitReason == "clarify" {
            statusLabel = String(localized: "等待确认")
        } else if work.state == "queued" || work.waitReason == "computer_task" {
            statusLabel = String(localized: "排队中")
        } else if work.state == "finalizing" {
            statusLabel = String(localized: "正在整理结果")
        } else if work.state == "failed" || work.reportState == "failed" {
            statusLabel = String(localized: "待核对结果")
        } else {
            statusLabel = String(localized: "正在执行")
        }

        let cal = Calendar.current
        let refTime = work.createdAt ?? work.updatedAt ?? Date().timeIntervalSince1970
        let refDate = Date(timeIntervalSince1970: refTime)
        var isCrossDay = false
        let dateBadge: String?
        if let recTs = work.sourceRecordedAt, recTs > 0 {
            let recDate = Date(timeIntervalSince1970: recTs)
            isCrossDay = !cal.isDate(recDate, inSameDayAs: refDate)
            if isCrossDay {
                dateBadge = "源录音 " + AgentTaskDateFormatter.monthDay(recDate)
            } else {
                dateBadge = AgentTaskDateFormatter.shortTimestamp(refDate)
            }
        } else if let ts = work.updatedAt ?? work.createdAt, ts > 0 {
            dateBadge = AgentTaskDateFormatter.shortTimestamp(Date(timeIntervalSince1970: ts))
        } else {
            dateBadge = nil
        }

        let cleanSummary = (work.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let canStop = !isRecent && work.cancellable == true && !stopping && !terminalWork
        return Item(
            id: "work:\(work.id)",
            work: work,
            title: resolvedTitle,
            statusLabel: statusLabel,
            originLabel: work.originLabel,
            dateBadge: dateBadge,
            isCrossDaySource: isCrossDay,
            summaryPreview: cleanSummary.isEmpty ? nil : cleanSummary,
            isUrgent: urgent,
            isStopping: stopping,
            isHistorical: isRecent,
            canStop: canStop
        )
    }

    @MainActor
    init(store: RemoteTaskStore?) {
        guard let store else {
            self.items = []
            return
        }
        // Only surface non-main-thread background tasks (SuperAgent Worker tickets,
        // delegated subagents, and background processes) — never main-thread chat turns.
        let activeWorks = store.backgroundWork.filter { work in
            work.isPending && !(work.state == "cancelled" && work.reportState == "cancelled")
        }
        self.items = activeWorks.map { Self.makeItem(from: $0, store: store, isRecent: false) }
    }
}

private enum AgentTaskDateFormatter {
    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dayShortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        return f
    }()

    static func full(_ date: Date) -> String { fullFormatter.string(from: date) }
    static func monthDay(_ date: Date) -> String { dayShortFormatter.string(from: date) }
    static func timeOnly(_ date: Date) -> String { timeOnlyFormatter.string(from: date) }

    static func shortTimestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return String(timeOnlyFormatter.string(from: date).prefix(5))
        }
        return monthDayFormatter.string(from: date)
    }
}

struct AgentActiveTasksSheet: View {
    let store: RemoteTaskStore?
    var isPopover = false
    var onDetailPresentedChange: ((Bool) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWork: ConversationWork?
    @State private var overviewActive: [ConversationWork] = []
    @State private var overviewRecent: [ConversationWork] = []
    @State private var loadedOverviewOnce = false

    private var snapshot: AgentActiveTasksSnapshot {
        AgentActiveTasksSnapshot(store: store)
    }

    private var activeItems: [AgentActiveTasksSnapshot.Item] {
        let liveByID = Dictionary(uniqueKeysWithValues: overviewActive.map { ($0.id, $0) })
        let baseWorks = store?.backgroundWork.filter { work in
            work.isPending && !(work.state == "cancelled" && work.reportState == "cancelled")
        } ?? []
        if baseWorks.isEmpty && !overviewActive.isEmpty {
            return overviewActive.map { AgentActiveTasksSnapshot.makeItem(from: $0, store: store, isRecent: false) }
        }
        return baseWorks.map { work in
            var merged = work
            if let rich = liveByID[work.id] {
                if merged.originLabel == nil { merged.originLabel = rich.originLabel }
                if merged.originKind == nil { merged.originKind = rich.originKind }
                if merged.sourceRecordedAt == nil { merged.sourceRecordedAt = rich.sourceRecordedAt }
                if merged.createdAt == nil { merged.createdAt = rich.createdAt }
                if merged.updatedAt == nil { merged.updatedAt = rich.updatedAt }
                if merged.summary == nil { merged.summary = rich.summary }
            }
            return AgentActiveTasksSnapshot.makeItem(from: merged, store: store, isRecent: false)
        }
    }

    private var recentItems: [AgentActiveTasksSnapshot.Item] {
        let activeIDs = Set(activeItems.map { $0.work.id })
        return overviewRecent
            .filter { !activeIDs.contains($0.id) }
            .map { AgentActiveTasksSnapshot.makeItem(from: $0, store: store, isRecent: true) }
    }

    var body: some View {
        Group {
            if let work = selectedWork {
                AgentTaskDetailView(
                    store: store,
                    initialWork: work,
                    isPopover: isPopover,
                    onBack: { selectedWork = nil },
                    onDismissSheet: { dismiss() }
                )
            } else {
                listSurface
            }
        }
        .onChange(of: selectedWork != nil) { _, isDetail in
            onDetailPresentedChange?(isDetail)
        }
        .accessibilityIdentifier("activeTasks.panel")
    }

    private var listSurface: some View {
        Group {
            if activeItems.isEmpty && recentItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !activeItems.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                sectionTitle("正在进行", count: activeItems.count)
                                ForEach(activeItems) { item in
                                    ActiveTaskItemRow(store: store, item: item) {
                                        selectedWork = item.work
                                    }
                                }
                            }
                        }
                        if !recentItems.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                sectionTitle("最近派发记录", count: nil)
                                ForEach(recentItems) { item in
                                    ActiveTaskItemRow(store: store, item: item) {
                                        selectedWork = item.work
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .phoneScrollHeader {
            VStack(spacing: 0) {
                headerBar
                #if os(macOS)
                Divider().overlay(MoMoPalette.line)
                #endif
            }
        }
        .phonePageSurface()
        .task {
            await store?.refresh(userInitiated: true)
            await refreshOverview()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(3200))
                if Task.isCancelled { break }
                await refreshOverview()
            }
        }
    }

    private func refreshOverview() async {
        guard let store else { return }
        if let fetched = try? await store.fetchWorkOverview(limit: 15) {
            overviewActive = fetched.active
            overviewRecent = fetched.recent
        }
        loadedOverviewOnce = true
    }

    private func sectionTitle(_ title: LocalizedStringKey, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MoMoPalette.muted)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MoMoPalette.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text("任务与子代理动态")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MoMoPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if activeItems.count > 0 {
                Text("\(activeItems.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MoMoPalette.canvas)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(MoMoPalette.ink, in: Capsule())
                    .accessibilityLabel("共 \(activeItems.count) 项正在进行")
            }
            Spacer()
            if !isPopover {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MoMoPalette.muted)
                        .frame(width: 30, height: 30)
                        .background(MoMoPalette.ink.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("activeTasks.close")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if !loadedOverviewOnce && store?.canContactServer == true {
                ProgressView().controlSize(.regular)
                Text("正在同步任务列表…")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(MoMoPalette.muted)
            } else {
                Image(systemName: "checklist")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(MoMoPalette.muted)
                    .accessibilityHidden(true)
                Text("当前没有正在进行的任务")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MoMoPalette.ink)
                Text("SuperAgent 主动派发或后台执行的子任务会在这里实时展示，点进任意任务可查看具体执行步骤。")
                    .font(.system(size: 12))
                    .foregroundStyle(MoMoPalette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activeTasks.empty")
    }
}

private struct ActiveTaskItemRow: View {
    let store: RemoteTaskStore?
    let item: AgentActiveTasksSnapshot.Item
    let onSelect: () -> Void

    private var dotColor: Color {
        if item.isHistorical {
            switch item.work.state {
            case "failed": return MoMoPalette.failure
            case "dropped", "cancelled": return MoMoPalette.muted.opacity(0.65)
            default: return MoMoPalette.success
            }
        }
        return item.isUrgent ? Color.orange : Color.green
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MoMoPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        if item.isStopping {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(dotColor)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(item.statusLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.isUrgent ? Color.orange : MoMoPalette.muted)

                        if let origin = item.originLabel, !origin.isEmpty {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(MoMoPalette.muted.opacity(0.6))
                            Text(origin)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(MoMoPalette.muted)
                                .lineLimit(1)
                        }

                        if let badge = item.dateBadge {
                            Spacer(minLength: 4)
                            Text(badge)
                                .font(.system(size: 11, weight: item.isCrossDaySource ? .semibold : .regular))
                                .foregroundStyle(item.isCrossDaySource ? Color.orange : MoMoPalette.muted)
                                .padding(.horizontal, item.isCrossDaySource ? 6 : 0)
                                .padding(.vertical, item.isCrossDaySource ? 2 : 0)
                                .background(
                                    item.isCrossDaySource ? Color.orange.opacity(0.12) : Color.clear,
                                    in: Capsule()
                                )
                        }
                    }

                    if let summary = item.summaryPreview {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(MoMoPalette.muted)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title)，\(item.statusLabel)，点击查看任务详情")

            if item.canStop, let store {
                Button {
                    Task {
                        await store.cancelBackgroundWork(item.work)
                    }
                } label: {
                    Text("停止")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MoMoPalette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(MoMoPalette.ink.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!store.canContactServer || item.isStopping)
                .accessibilityLabel("停止任务：\(item.title)")
                .accessibilityIdentifier("activeTasks.stop.\(item.id)")
            }

            Button(action: onSelect) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MoMoPalette.muted.opacity(0.75))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(14)
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(MoMoPalette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activeTasks.item.\(item.id)")
    }
}

private struct AgentTaskDetailView: View {
    let store: RemoteTaskStore?
    let initialWork: ConversationWork
    let isPopover: Bool
    let onBack: () -> Void
    let onDismissSheet: () -> Void

    @State private var detail: ConversationWorkDetail?
    @State private var loading = true
    @State private var loadError: String?
    @State private var stopping = false

    private var effectiveTitle: String {
        detail?.title ?? initialWork.title ?? String(localized: "后台任务")
    }

    private var effectiveStatusLabel: String {
        if stopping || store?.isControlInFlight(initialWork.id) == true {
            return String(localized: "正在停止")
        }
        if let detail { return detail.statusLabel }
        return initialWork.isPending ? String(localized: "正在执行") : String(localized: "已结束")
    }

    private var isActive: Bool {
        detail?.isActive ?? initialWork.isPending
    }

    private var canStop: Bool {
        guard let store, store.canContactServer, !stopping, !store.isControlInFlight(initialWork.id) else { return false }
        if let detail { return detail.cancellable && detail.isActive }
        return initialWork.cancellable == true && initialWork.isPending
    }

    private var isCrossDayBackfill: Bool {
        guard let recTs = detail?.sourceRecordedAt ?? initialWork.sourceRecordedAt, recTs > 0 else { return false }
        let dispatchTs = detail?.createdAt ?? initialWork.createdAt ?? Date().timeIntervalSince1970
        return !Calendar.current.isDate(
            Date(timeIntervalSince1970: recTs),
            inSameDayAs: Date(timeIntervalSince1970: dispatchTs)
        )
    }

    private var currentRunningActivity: ConversationWorkDetail.ActivityItem? {
        detail?.activities.last(where: { $0.status == "running" })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                overviewCard

                if let question = detail?.attentionQuestion, !question.isEmpty {
                    detailSectionCard(title: "等待你的确认", icon: "exclamationmark.bubble.fill", tint: .orange) {
                        Text(question)
                            .font(.system(size: 13))
                            .foregroundStyle(MoMoPalette.ink)
                            .textSelection(.enabled)
                    }
                }

                if isActive {
                    liveStepBanner
                }

                if let summary = detail?.summary ?? initialWork.summary, !summary.isEmpty {
                    detailSectionCard(title: "处理结论", icon: "checkmark.seal", tint: MoMoPalette.ink) {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(MoMoPalette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let ws = detail?.workspacePath, !ws.isEmpty {
                            Text("工作目录：\(ws)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MoMoPalette.muted)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                    }
                }

                if detail?.scope != nil || detail?.triggerPreview != nil {
                    dispatchMandateCard
                }

                if let todos = detail?.todos, !todos.isEmpty {
                    todosCard(todos)
                }

                activitiesCard
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .phoneScrollHeader {
            VStack(spacing: 0) {
                detailHeaderBar
                #if os(macOS)
                Divider().overlay(MoMoPalette.line)
                #endif
            }
        }
        .phonePageSurface()
        .task(id: initialWork.id) {
            await fetchDetail()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                if let detail, !detail.isActive && !stopping {
                    break
                }
                await fetchDetail()
            }
        }
    }

    private func fetchDetail() async {
        guard let store else {
            loading = false
            return
        }
        do {
            let loaded = try await store.fetchWorkDetail(id: initialWork.id)
            detail = loaded
            loadError = nil
        } catch {
            if detail == nil {
                loadError = error.localizedDescription
            }
        }
        loading = false
    }

    private var detailHeaderBar: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(MoMoPalette.ink)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activeTasks.detail.back")

            Spacer()

            Text(effectiveStatusLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.green : MoMoPalette.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background((isActive ? Color.green : MoMoPalette.ink).opacity(0.1), in: Capsule())

            if canStop, let store {
                Button {
                    stopping = true
                    Task {
                        await store.cancelBackgroundWorkByID(
                            initialWork.id,
                            generation: initialWork.executionGeneration ?? 1
                        )
                        await fetchDetail()
                        stopping = false
                    }
                } label: {
                    Text("停止")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MoMoPalette.failure)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(MoMoPalette.failure.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activeTasks.detail.stop")
            }

            if !isPopover {
                Button(action: onDismissSheet) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MoMoPalette.muted)
                        .frame(width: 30, height: 30)
                        .background(MoMoPalette.ink.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(effectiveTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MoMoPalette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                metaRow(
                    label: "任务来源",
                    value: detail?.originLabel ?? initialWork.originLabel ?? String(localized: "后台子任务")
                )

                if let rules = detail?.matchedRules, !rules.isEmpty {
                    metaRow(label: "命中规则", value: rules.joined(separator: "、"))
                }

                if let recTs = detail?.sourceRecordedAt ?? initialWork.sourceRecordedAt, recTs > 0 {
                    let recStr = AgentTaskDateFormatter.full(Date(timeIntervalSince1970: recTs))
                    let srcTitle = (detail?.sourceTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    HStack(alignment: .top, spacing: 8) {
                        Text("录音时间")
                            .font(.system(size: 12))
                            .foregroundStyle(MoMoPalette.muted)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(recStr)
                                    .font(.system(size: 12, weight: isCrossDayBackfill ? .semibold : .regular))
                                    .foregroundStyle(isCrossDayBackfill ? Color.orange : MoMoPalette.ink)
                                if isCrossDayBackfill {
                                    Text("跨日历史录音")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.14), in: Capsule())
                                }
                            }
                            if !srcTitle.isEmpty {
                                Text(srcTitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(MoMoPalette.muted)
                            }
                        }
                    }
                }

                if let createdTs = detail?.createdAt ?? initialWork.createdAt, createdTs > 0 {
                    metaRow(
                        label: "派发时间",
                        value: AgentTaskDateFormatter.full(Date(timeIntervalSince1970: createdTs))
                    )
                }

                if let detail, detail.turnCount > 0 || detail.stepCount > 0 {
                    metaRow(label: "执行进度", value: "第 \(max(1, detail.turnCount)) 轮 · 已执行 \(detail.stepCount) 步")
                }
            }
        }
        .padding(14)
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(MoMoPalette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(MoMoPalette.muted)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(MoMoPalette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var liveStepBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("当前正在执行")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green)
                Text(currentRunningActivity?.title ?? String(localized: "正在分析上下文并规划下一步动作…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MoMoPalette.ink)
                if let cmd = currentRunningActivity?.detail, !cmd.isEmpty {
                    Text(cmd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MoMoPalette.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.green.opacity(0.28), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var dispatchMandateCard: some View {
        detailSectionCard(title: "子任务派发说明", icon: "arrow.triangle.branch", tint: MoMoPalette.ink) {
            if let scope = detail?.scope, !scope.isEmpty {
                Text(scope)
                    .font(.system(size: 13))
                    .foregroundStyle(MoMoPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let preview = detail?.triggerPreview, !preview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("触发上下文片段")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MoMoPalette.muted)
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(MoMoPalette.muted)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MoMoPalette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.top, detail?.scope == nil ? 0 : 6)
            }
        }
    }

    private func todosCard(_ todos: [ConversationWorkDetail.TodoItem]) -> some View {
        detailSectionCard(title: "子任务检查项", icon: "checklist", tint: MoMoPalette.ink) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(todos) { todo in
                    HStack(alignment: .top, spacing: 8) {
                        Group {
                            switch todo.status {
                            case "completed":
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(MoMoPalette.success)
                            case "in_progress":
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Color.orange)
                            default:
                                Image(systemName: "circle")
                                    .foregroundStyle(MoMoPalette.muted)
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.top, 1)

                        Text(todo.content)
                            .font(.system(size: 12))
                            .foregroundStyle(todo.status == "completed" ? MoMoPalette.muted : MoMoPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var activitiesCard: some View {
        let activities = detail?.activities ?? []
        return detailSectionCard(
            title: activities.isEmpty ? "执行动态" : "执行动态（\(activities.count)）",
            icon: "waveform.path.ecg",
            tint: MoMoPalette.ink
        ) {
            if loading && detail == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载 Worker 执行记录…")
                        .font(.system(size: 12))
                        .foregroundStyle(MoMoPalette.muted)
                }
                .padding(.vertical, 6)
            } else if activities.isEmpty {
                Text(loadError != nil ? "暂时无法读取详细步骤，请稍后重试。" : "暂无工具调用记录（任务可能在调度阶段直接完成或正在初始化）。")
                    .font(.system(size: 12))
                    .foregroundStyle(MoMoPalette.muted)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(activities.enumerated().reversed()), id: \.element.id) { index, act in
                        activityRow(index: index + 1, item: act)
                        if index > 0 {
                            Divider().overlay(MoMoPalette.line.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private func activityRow(index: Int, item: ConversationWorkDetail.ActivityItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activityIcon(for: item.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.kind == "subagent" ? Color.blue : MoMoPalette.muted)
                .frame(width: 22, height: 22)
                .background(MoMoPalette.ink.opacity(0.05), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("#\(index)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(MoMoPalette.muted)
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MoMoPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    activityStatusBadge(item)
                }
                if let detailText = item.detail, !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: 11, design: item.kind == "tool" ? .monospaced : .default))
                        .foregroundStyle(MoMoPalette.muted)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func activityStatusBadge(_ item: ConversationWorkDetail.ActivityItem) -> some View {
        HStack(spacing: 4) {
            if item.status == "running" {
                ProgressView().controlSize(.mini)
            } else if item.status == "failed" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(MoMoPalette.failure)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MoMoPalette.muted)
            }
            if let ts = item.timestamp, ts > 0 {
                Text(AgentTaskDateFormatter.timeOnly(Date(timeIntervalSince1970: ts)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MoMoPalette.muted)
            }
        }
    }

    private func activityIcon(for kind: String) -> String {
        switch kind {
        case "subagent": return "person.2.wave.2"
        case "report": return "flag.checkered"
        case "thought": return "text.bubble"
        default: return "terminal"
        }
    }

    private func detailSectionCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MoMoPalette.muted)
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(MoMoPalette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
