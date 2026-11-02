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
        case run(AgentRun)
        case pendingSubmission(UUID)
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let sourceLabel: String
        let icon: String
        let statusLabel: String
        let isUrgent: Bool
        let isStopping: Bool
        let canStop: Bool
        let backing: Backing
    }

    let items: [Item]
    var count: Int { items.count }
    var badgeText: String? {
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    @MainActor
    init(store: RemoteTaskStore?) {
        guard let store else {
            self.items = []
            return
        }
        var collected: [Item] = []
        let activeWorks = store.backgroundWork.filter { work in
            work.isPending && !(work.state == "cancelled" && work.reportState == "cancelled")
        }

        for work in activeWorks {
            let parent = store.sharedRuns.first {
                (work.workID != nil && $0.workID == work.workID) || $0.runID == work.originRunID
            }
            let rawTitle = (work.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = (parent?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = !rawTitle.isEmpty ? rawTitle : (!fallbackTitle.isEmpty ? fallbackTitle : String(localized: "子智能体任务"))

            let isSuperAgent = work.id.hasPrefix("superagent:")
            let isProactive = (work.workID ?? "").hasPrefix("proactive-") || (work.nativeState ?? "").hasPrefix("proactive:")
            let sourceLabel: String
            let icon: String
            if isSuperAgent {
                sourceLabel = isProactive ? String(localized: "SuperAgent · 主动子智能体") : String(localized: "SuperAgent · 子智能体工单")
                icon = isProactive ? "sparkles" : "person.2"
            } else if work.kind == "process" {
                sourceLabel = String(localized: "Hermes · 后台终端任务")
                icon = "terminal"
            } else {
                sourceLabel = String(localized: "Hermes · 子智能体任务")
                icon = "person.2"
            }

            let terminalWork = ["completed", "failed", "cancelled", "unknown"].contains(work.state)
            let stopping = store.isControlInFlight(work.id) || (work.cancelRequested == true && !terminalWork)
            let urgent = work.waitReason == "computer_human" || work.waitReason == "clarify" || work.state == "failed" || work.reportState == "failed"
            let statusLabel: String
            if stopping {
                statusLabel = String(localized: "正在停止")
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

            let canStop = work.cancellable == true && !stopping && !terminalWork
            collected.append(
                Item(
                    id: "work:\(work.id)",
                    title: resolvedTitle,
                    sourceLabel: sourceLabel,
                    icon: icon,
                    statusLabel: statusLabel,
                    isUrgent: urgent,
                    isStopping: stopping,
                    canStop: canStop,
                    backing: .work(work)
                )
            )
        }

        for run in store.sharedRuns where !run.isTerminal {
            let coveredBySubAgent = activeWorks.contains { work in
                (work.workID != nil && work.workID == run.workID) || work.originRunID == run.runID
            }
            if coveredBySubAgent { continue }
            let stopping = store.isControlInFlight(run.runID) || run.cancelRequested == true
            let waiting = run.pendingControls?.isEmpty == false || ["computer", "computer_human", "clarify"].contains(run.waitReason ?? "")
            let statusLabel: String
            if stopping {
                statusLabel = String(localized: "正在停止")
            } else if waiting {
                statusLabel = String(localized: "等待确认")
            } else if run.status == "queued" || run.waitReason == "computer_task" {
                statusLabel = String(localized: "排队中")
            } else {
                statusLabel = String(localized: "正在处理")
            }
            collected.append(
                Item(
                    id: "run:\(run.runID)",
                    title: store.title(for: run),
                    sourceLabel: String(localized: "当前对话任务"),
                    icon: "bubble.left.and.text.bubble.right",
                    statusLabel: statusLabel,
                    isUrgent: waiting,
                    isStopping: stopping,
                    canStop: run.cancellable == true && !stopping,
                    backing: .run(run)
                )
            )
        }

        for task in store.tasks where task.isPending && task.run == nil && !task.needsReview && task.lastError == nil {
            let trimmed = task.input.trimmingCharacters(in: .whitespacesAndNewlines)
            collected.append(
                Item(
                    id: "pending:\(task.id.uuidString)",
                    title: trimmed.isEmpty ? String(localized: "新消息") : trimmed,
                    sourceLabel: String(localized: "发送队列"),
                    icon: "arrow.up.circle",
                    statusLabel: String(localized: "排队发送中"),
                    isUrgent: false,
                    isStopping: false,
                    canStop: false,
                    backing: .pendingSubmission(task.id)
                )
            )
        }

        self.items = collected
    }
}

struct AgentActiveTasksSheet: View {
    let store: RemoteTaskStore?
    var isPopover = false
    @Environment(\.dismiss) private var dismiss

    private var snapshot: AgentActiveTasksSnapshot {
        AgentActiveTasksSnapshot(store: store)
    }

    var body: some View {
        Group {
            if snapshot.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(snapshot.items) { item in
                            ActiveTaskItemRow(store: store, item: item)
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
        .accessibilityIdentifier("activeTasks.panel")
        .task {
            await store?.refresh(userInitiated: true)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text("正在进行的任务")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MoMoPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if snapshot.count > 0 {
                Text("\(snapshot.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MoMoPalette.canvas)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(MoMoPalette.ink, in: Capsule())
                    .accessibilityLabel("共 \(snapshot.count) 项")
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
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(MoMoPalette.muted)
                .accessibilityHidden(true)
            Text("当前没有正在进行的任务")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MoMoPalette.ink)
            Text("SuperAgent 派发的子智能体任务与 Hermes 后台委派任务会实时显示在这里。")
                .font(.system(size: 13))
                .foregroundStyle(MoMoPalette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted)
                    .accessibilityHidden(true)
                Text(item.sourceLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if item.isStopping {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle()
                            .fill(item.isUrgent ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(item.statusLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(item.isUrgent ? Color.orange : MoMoPalette.muted)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MoMoPalette.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if item.canStop, let store {
                    Button {
                        Task {
                            switch item.backing {
                            case .work(let work):
                                await store.cancelBackgroundWork(work)
                            case .run(let run):
                                await store.stopSharedRun(run)
                            case .pendingSubmission:
                                break
                            }
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
            }
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
