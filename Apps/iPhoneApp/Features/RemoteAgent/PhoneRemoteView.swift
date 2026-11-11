import SwiftUI
import MoMoAgentClient
import MoMoArchive
import MoMoSpeech

struct PhoneRemoteView: View {
    let agent: PhoneRemoteAgent
    let openSettings: () -> Void
    var watchStatus: WatchStatusObservation?
    var requestWatchStatus: (() -> Void)?
    let openLibrary: () -> Void
    var openMemory: () -> Void = {}
    var speech: SpeechEngine? = nil
    var stopPlayback: () async -> Void = {}
    var chatIsVisible = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showingTasks = false
    @State private var tasksSheetDetent: PresentationDetent = .medium
    @State private var showingDesktop = false
    @State private var reconnecting = false

    private var activeTasksSnapshot: AgentActiveTasksSnapshot {
        AgentActiveTasksSnapshot(store: agent.store)
    }

    var body: some View {
        Group {
            if let store = agent.store {
                RemoteConversationView(store: store, agent: agent, watchStatus: watchStatus,
                    requestWatchStatus: requestWatchStatus, openLibrary: openLibrary, reconnect: { reconnecting = true },
                    openDesktop: { showingDesktop = true }, openNotebook: openMemory,
                    speech: speech, stopPlayback: stopPlayback,
                    voiceInputEnabled: chatIsVisible && !showingDesktop && !showingTasks && !reconnecting)
            } else {
                VStack(spacing: 24) {
                    RemoteAvatar(size: 120, active: false, watchStatus: watchStatus,
                        requestWatchStatus: requestWatchStatus, openLibrary: openLibrary)
                    PhoneBrandWordmark(.momo, size: 26)
                        .accessibilityIdentifier("personalAgent.name")
                    Text("让生活成为你的上下文").phoneText(.title)
                    Button("开始配对") { agent.advanceSetup(.connect) }
                        .buttonStyle(ClientPrimaryButton()).accessibilityIdentifier("remote.connect")
                    if let failure = agent.failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .phonePageSurface()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 12) { headerActions }
            } else {
                headerActions
            }
        }
        .onChange(of: showingDesktop) { _, value in agent.notifications.desktopVisible = value }
        .onChange(of: agent.notifications.navigationRevision) { _, _ in showingDesktop = false; showingTasks = false }
        .sheet(isPresented: $showingTasks, onDismiss: { tasksSheetDetent = .medium }) {
            AgentActiveTasksSheet(store: agent.store) { isDetail in
                if isDetail { tasksSheetDetent = .large }
            }
            .presentationDetents([.medium, .large], selection: $tasksSheetDetent)
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $reconnecting) { PhoneConnectionFlow(agent: agent, reconnecting: true, finish: { reconnecting = false }) }
        .fullScreenCover(isPresented: $showingDesktop) { PhoneDesktopView(agent: agent) }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            headerButton("设置", icon: "gearshape", id: "remote.settings", action: openSettings)
            Spacer()
            tasksHeaderButton
            headerButton("电脑桌面", icon: "desktopcomputer", id: "remote.desktop") { showingDesktop = true }
        }.padding(.horizontal, 16).frame(height: 72)
    }

    private var tasksHeaderButton: some View {
        let badge = activeTasksSnapshot.badgeText
        return Button {
            showingTasks = true
        } label: {
            if let badge {
                tasksBadgeCapsule(badge)
            } else {
                headerSymbol("checklist")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activeTasksSnapshot.count > 0 ? LocalizedStringKey("正在进行的任务，\(activeTasksSnapshot.count) 项") : LocalizedStringKey("正在进行的任务"))
        .accessibilityIdentifier("remote.tasks")
    }

    @ViewBuilder private func tasksBadgeCapsule(_ badge: String) -> some View {
        let content = HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(MoMoPalette.ink)
            Text(badge)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MoMoPalette.canvas)
                .padding(.horizontal, 6)
                .frame(minWidth: 18, minHeight: 18)
                .background(MoMoPalette.ink, in: Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Capsule())
        if reduceTransparency {
            content
                .background(MoMoPalette.paper, in: Capsule())
                .overlay { Capsule().strokeBorder(MoMoPalette.line, lineWidth: 0.5) }
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(MoMoPalette.line, lineWidth: 0.5) }
        }
    }

    private func headerButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            headerSymbol(icon)
        }.buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(title)).accessibilityIdentifier(id)
    }

    @ViewBuilder private func headerSymbol(_ icon: String) -> some View {
        let symbol = Image(systemName: icon).font(.system(size: 20, weight: .regular))
            .foregroundStyle(MoMoPalette.ink).frame(width: 44, height: 44).contentShape(Circle())
        if reduceTransparency {
            symbol
                .background(MoMoPalette.paper, in: Circle())
                .overlay { Circle().strokeBorder(MoMoPalette.line, lineWidth: 0.5) }
        } else if #available(iOS 26, *) {
            symbol.glassEffect(.regular.interactive(), in: .circle)
        } else {
            symbol.background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(MoMoPalette.line, lineWidth: 0.5) }
        }
    }
}

private struct RemoteConversationView: View {
    let store: RemoteTaskStore
    let agent: PhoneRemoteAgent
    let watchStatus: WatchStatusObservation?
    let requestWatchStatus: (() -> Void)?
    let openLibrary: () -> Void
    let reconnect: () -> Void
    let openDesktop: () -> Void
    let openNotebook: () -> Void
    let speech: SpeechEngine?
    let stopPlayback: () async -> Void
    let voiceInputEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composeRevision = 0
    @State private var sendFailure: String?
    @State private var viewport = CGRect.zero
    @State private var previewAttachment: AgentAttachment?
    @State private var dismissedBriefingCardIDs: Set<String> = DreamDismissedCardsStore.load()
    @State private var showingBriefingDetail = false
    @State private var previewingMemoryNote: ContextMemory?

    private var briefingDocument: DreamBriefingDocument? {
        guard let sync = agent.context else { return nil }
        return DreamBriefingDocument.resolve(from: sync.memories)
    }

    var body: some View {
        let snapshot = ChatRenderSnapshot(store: store, readingPosition: agent.readingPosition,
            notificationTarget: agent.notifications.focusedTarget)
        let isEmpty = store.isEmpty || snapshot.messages.isEmpty
        let draftEmpty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(spacing: 0) {
            if isEmpty {
                identityHeader(isEmpty: true)
            } else {
                PhoneHeaderViewport { inset in
                    transcript(snapshot, headerInset: inset)
                }
                .phoneScrollHeader { identityHeader(isEmpty: false) }
            }
            if draftEmpty, !store.hasActiveTask, let doc = briefingDocument,
               !doc.cards.filter({ !$0.isDismissed(in: dismissedBriefingCardIDs, headline: doc.headline) }).isEmpty {
                DreamHomeCardsSection(
                    document: doc,
                    dismissedIDs: $dismissedBriefingCardIDs,
                    compact: !isEmpty,
                    onSelectCard: { card in
                        store.setDraft(card.prompt)
                        do {
                            try store.enqueue()
                            sendFailure = nil
                            composeRevision += 1
                            Task { await store.refresh(userInitiated: true) }
                        } catch {
                            sendFailure = error.localizedDescription
                        }
                    },
                    onOpenBriefing: { showingBriefingDetail = true },
                    onOpenNotebook: openNotebook
                )
                .padding(.top, isEmpty ? 0 : 8)
                .padding(.bottom, 8)
            }
            RemoteTaskControlsView(store: store, viewport: viewport, onControlVisibility: agent.notifications.controlVisible,
                                   openDesktop: openDesktop)
            RemoteTaskRecoveryView(store: store, reconnect: reconnect, retry: { await agent.reconnect() })
            if let failure = sendFailure ?? store.interactionFailure { Text(failure).foregroundStyle(.red).font(.footnote) }
        }
        .onChange(of: agent.notifications.navigationRevision) { _, _ in
            if agent.notifications.focusedTarget?.messageID == nil { composeRevision += 1 }
        }
        .task { await agent.context?.refresh() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: isEmpty)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $previewAttachment) { ClientAttachmentPreview(attachment: $0) }
        .sheet(item: $previewingMemoryNote) { note in
            MemoryNotePreviewSheet(
                memory: note,
                allMemories: agent.context?.memories ?? [],
                onOpenFullNotebook: openNotebook
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingBriefingDetail) {
            if let doc = briefingDocument {
                NavigationStack {
                    ScrollView {
                        MarkdownReadingView(markdown: MemoryCardDigest.cleanNotebookMarkdownForDetail(doc.rawMarkdown), accessibilityID: "assistant.dreamBriefingMarkdown", handwriting: true)
                            .memoryNotebookPage()
                            .padding(20)
                    }
                    .phonePageSurface()
                    .navigationTitle(doc.headline)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showingBriefingDetail = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard DreamMemoryLinkResolver.isMemoryURL(url) else { return .systemAction }
            let memories = agent.context?.memories ?? []
            if let matched = DreamMemoryLinkResolver.resolve(url: url, in: memories) {
                previewingMemoryNote = matched
            } else {
                Task {
                    await agent.context?.refresh()
                    if let matched = DreamMemoryLinkResolver.resolve(url: url, in: agent.context?.memories ?? []) {
                        previewingMemoryNote = matched
                    } else {
                        openNotebook()
                    }
                }
            }
            return .handled
        })
        .safeAreaInset(edge: .bottom) {
            ClientComposer(text: Binding(get: { store.draft }, set: store.setDraft),
                           store: store,
                           prompt: "发消息给 MoMo",
                           onCompose: { composeRevision += 1 },
                           onPreviewAttachment: { previewAttachment = $0 },
                           onError: { sendFailure = $0 }, speech: speech, stopPlayback: stopPlayback,
                           voiceInputEnabled: voiceInputEnabled && previewAttachment == nil) {
                do { try store.enqueue(); sendFailure = nil; Task { await store.refresh(userInitiated: true) } }
                catch { sendFailure = error.localizedDescription }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func transcript(_ snapshot: ChatRenderSnapshot, headerInset: CGFloat) -> some View {
        ChatRendererView(snapshot: snapshot,
            scrollToBottomRequest: composeRevision, headerInset: headerInset,
            onReadingPosition: agent.rememberReadingPosition,
            onAttachment: { id in previewAttachment = store.attachment(id: id) },
            onRetryMessage: { id in Task { await store.checkAgain(id: id) } })
    }

    private func identityHeader(isEmpty: Bool) -> some View {
        VStack(spacing: 6) {
            RemoteAvatar(size: isEmpty ? 144 : 84, active: store.hasActiveTask,
                watchStatus: watchStatus, requestWatchStatus: requestWatchStatus, openLibrary: openLibrary)
            PhoneBrandWordmark(.momo, size: isEmpty ? 22 : 14)
                .accessibilityIdentifier("personalAgent.name")
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isEmpty ? .infinity : nil)
        .padding(.bottom, isEmpty ? 0 : 8)
    }
}

private struct RemoteAvatar: View {
    let size: CGFloat
    let active: Bool
    let watchStatus: WatchStatusObservation?
    let requestWatchStatus: (() -> Void)?
    let openLibrary: () -> Void
    @State private var showingStatus = false
    @Environment(EarphoneCaptureRuntime.self) private var earphone: EarphoneCaptureRuntime?
    var body: some View {
        PersonalAgentSlot(size: size, active: true, expression: active ? .working : .present)
            .watchStatusRefresh(requestWatchStatus)
            .frame(height: size * (72.0 / 84.0), alignment: .top)
            .overlay(alignment: .bottomTrailing) {
                if let earphone, earphone.settings.device == .earphone { earphoneBadge(earphone) }
                else { watchBadge }
            }
    }

    private func earphoneBadge(_ earphone: EarphoneCaptureRuntime) -> some View {
        let status = EarphoneStatusPresentation(earphone)
        return Button { showingStatus.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: CaptureDevice.earphone.symbol).font(.system(size: 11, weight: .medium))
                Circle().fill(status.indicatorColor).frame(width: 5, height: 5)
            }.foregroundStyle(MoMoPalette.ink).padding(4)
                .background(MoMoPalette.paper, in: Capsule())
                .overlay { Capsule().strokeBorder(MoMoPalette.line, lineWidth: 1) }
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(status.title).accessibilityValue(status.indicator.title)
            .accessibilityHint("查看耳机录音状态").accessibilityIdentifier("assistant.earphoneStatus")
            .popover(isPresented: $showingStatus, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                EarphoneStatusPopover(runtime: earphone) { showingStatus = false; openLibrary() }
                    .presentationCompactAdaptation(.popover)
            }
            .offset(x: 8, y: 8)
    }

    private var watchBadge: some View {
        TimelineView(.periodic(from: .now, by: 5)) { clock in
            let status = WatchStatusPresentation(observation: watchStatus, now: clock.date)
            Button { showingStatus.toggle() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "applewatch").font(.system(size: 11, weight: .medium))
                    Circle().fill(status.indicatorColor).frame(width: 5, height: 5)
                }.foregroundStyle(MoMoPalette.ink).padding(4)
                    .background(MoMoPalette.paper, in: Capsule())
                    .overlay { Capsule().strokeBorder(MoMoPalette.line, lineWidth: 1) }
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(status.title).accessibilityValue(status.indicator.title)
                .accessibilityHint("查看录音与同步状态").accessibilityIdentifier("assistant.watchStatus")
                .popover(isPresented: $showingStatus, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    WatchStatusPopover(observation: watchStatus) { showingStatus = false; openLibrary() }
                        .presentationCompactAdaptation(.popover)
                }
        }.offset(x: 8, y: 8)
    }
}

struct PhoneMacConnectionView: View {
    @Bindable var agent: PhoneRemoteAgent
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PhoneSettingsSection(title: "这台 Mac") {
                    PhoneSettingsSurface {
                        PhoneSettingsLinkRow(title: "配对状态", value: agent.connection == nil ? "尚未配对" : "已配对", disclosure: false)
                            .accessibilityIdentifier("remote.deviceState")
                        if agent.connection != nil {
                            Divider().padding(.leading, 18)
                            PhoneSettingsLinkRow(title: "连接状态", value: connectionLabel, disclosure: false)
                        }
                        Divider().padding(.leading, 18)
                        if needsPairing {
                            Button { pairing = true } label: {
                                PhoneSettingsLinkRow(title: agent.connection == nil ? "扫码配对" : "重新配对", symbol: "qrcode")
                            }.accessibilityIdentifier("remote.pairDevice")
                        } else {
                            Button { Task { await agent.reconnect() } } label: {
                                HStack {
                                    PhoneSettingsLinkRow(title: agent.connecting ? "正在重连" : "重新连接", symbol: "arrow.clockwise", disclosure: false)
                                    if agent.connecting { ProgressView().padding(.trailing, 18) }
                                }
                            }.disabled(agent.connecting).accessibilityIdentifier("remote.reconnectDevice")
                        }
                    }
                    if let failure = agent.failure { Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure) }
                }
                if let endpoint = agent.connection?.baseURL {
                    PhoneSettingsSection(title: "网络") {
                        PhoneSettingsSurface {
                            if let network = agent.network {
                                PhoneSettingsLinkRow(title: "传输方式", value: network.routeLabel, disclosure: false)
                                    .accessibilityIdentifier("remote.networkRoute")
                            } else if agent.connection?.network == "relay" {
                                PhoneSettingsLinkRow(title: "加密中继", value: "端到端加密", disclosure: false)
                                    .accessibilityIdentifier("remote.networkRoute")
                            } else if agent.connection?.network == "tailscale" {
                                PhoneSettingsLinkRow(title: "Tailscale", value: agent.tailnet.state == "Running" ? "已连接私网" : "等待连接", disclosure: false)
                                    .accessibilityIdentifier("remote.networkRoute")
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("地址").phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                                Text(endpoint.absoluteString).phoneText(.metadata).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        }
                    }
                }
                PhoneSettingsSection(title: "连接管理") {
                    PhoneSettingsSurface {
                        if agent.connection != nil && !needsPairing {
                            Button { pairing = true } label: { PhoneSettingsLinkRow(title: "重新配对", symbol: "qrcode") }
                                .accessibilityIdentifier("remote.pairDevice")
                            Divider().padding(.leading, 18)
                        }
                        NavigationLink { PhoneManualConnectionView(agent: agent) } label: {
                            PhoneSettingsLinkRow(title: "手动配置")
                        }.accessibilityIdentifier("remote.manualConnection")
                    }
                }
            }.buttonStyle(.plain).padding(24)
        }
        .phonePageSurface()
        .fullScreenCover(isPresented: $pairing) { PhoneConnectionFlow(agent: agent, reconnecting: true, finish: { pairing = false }) }
        .navigationTitle("Mac 连接").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var needsPairing: Bool { agent.connection == nil || agent.store?.connectionState == .authenticationRequired }
    private var connectionLabel: String {
        if agent.connecting { return String(localized: "正在连接") }
        switch agent.store?.connectionState {
        case .ready: return String(localized: "已连接")
        case .retrying: return String(localized: "正在重连")
        case .authenticationRequired: return String(localized: "需要重新配对")
        case .unavailable, nil: return String(localized: "暂未连接")
        }
    }
}

private struct PhoneManualConnectionView: View {
    let agent: PhoneRemoteAgent
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = ""
    @State private var credential = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $configuration).frame(minHeight: 180).font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityLabel("连接信息").accessibilityIdentifier("remote.connectionJSON")
            } header: { Text("连接信息") } footer: { Text("粘贴 Mac 提供的连接信息。") }
            Section {
                SecureField("设备密钥", text: $credential).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("remote.credential")
            } footer: { Text("密钥保存在这台手机的钥匙串中。") }
            Section {
                Button(agent.connecting ? "正在连接…" : "保存") {
                    Task {
                        await agent.connect(configuration: configuration, credential: credential)
                        if agent.failure == nil { credential = ""; dismiss() }
                    }
                }.disabled(agent.connecting || credential.isEmpty || configuration.isEmpty)
                    .accessibilityIdentifier("remote.saveConnection")
                if let failure = agent.failure { Text(failure).font(.footnote).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .phonePageSurface()
        .tint(MoMoPalette.ink)
        .navigationTitle("手动配置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let connection = agent.connection,
               let data = try? JSONEncoder().encode(connection), let value = String(data: data, encoding: .utf8) {
                configuration = value
            }
        }
    }
}
