import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import MoMoAgentClient

struct DesktopRoot: View {
    @Bindable var model: DesktopModel
    @State private var sidebarVisible = true
    @State private var recordingCitation: RecordingCitation?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible { sidebar.frame(width: 232).transition(.move(edge: .leading).combined(with: .opacity)) }
            VStack(spacing: 0) {
                if let failure = model.failure {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text(failure); Spacer(); Button("关闭") { model.failure = nil } }
                        .font(.callout).padding(16).padding(.top, 32)
                        .background(MoMoPalette.failureBackground).accessibilityIdentifier("desktop.failure")
                }
                if model.selection == "sources" { DesktopSources(model: model).padding(.top, 36) }
                else { DesktopChat(model: model).padding(.top, 28) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MoMoPalette.canvas)
        }
        .overlay(alignment: .topLeading) {
            if !sidebarVisible { sidebarToggle.padding(.leading, 92).padding(.top, 2) }
        }
        .background(MoMoPalette.paper)
        .background(DesktopWindowChrome())
        .ignoresSafeArea(.container)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "momoagent" else { return .systemAction }
            if let citation = RecordingCitation(url: url) { recordingCitation = citation }
            else { model.failure = String(localized: "这条录音来源不可用。") }
            return .handled
        })
        .sheet(item: $recordingCitation) { citation in
            DesktopRecordingCitation(model: model, citation: citation)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); sidebarToggle }.padding(.trailing, 16).frame(height: 32)
            HStack(spacing: 10) { PhoneBrandIcon(size: 22); PhoneBrandWordmark(size: 15); Spacer(minLength: 0) }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)
            VStack(spacing: 4) {
                destination("首页", icon: "house", selection: "chat")
                destination("转录", icon: "waveform", selection: "sources")
            }.padding(.horizontal, 12)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 14) {
                sidebarLabel(model.status?.agentOnline == true ? "MoMo 正在运行" : "MoMo 尚未运行", icon: model.status?.agentOnline == true ? "checkmark.circle" : "pause.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                SettingsLink { sidebarLabel("设置", icon: "gearshape").font(.system(size: 15)) }.buttonStyle(.plain)
            }.padding(24)
        }
    }

    private var sidebarToggle: some View {
        Button { withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible.toggle() } } label: {
            Image(systemName: "sidebar.left").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(sidebarVisible ? "收起侧栏" : "显示侧栏")
            .accessibilityLabel(sidebarVisible ? "收起侧栏" : "显示侧栏").accessibilityIdentifier("desktop.sidebarToggle")
            .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private func sidebarLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).accessibilityHidden(true)
            Text(LocalizedStringKey(title))
        }
    }

    private func destination(_ title: String, icon: String, selection: String) -> some View {
        Button { model.selection = selection } label: {
            sidebarLabel(title, icon: icon).font(.system(size: 15))
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).padding(.horizontal, 12)
                .background(model.selection == selection ? MoMoPalette.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityIdentifier("desktop.destination." + selection)
            .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
    }
}

struct DesktopDevices: View {
    @Bindable var model: DesktopModel
    @State private var revoking: AccessStatus.Device?
    @State private var showingPairing = false
    @State private var showingMethod = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(showingMethod ? "连接方式" : "设备").font(.system(size: 22, weight: .medium)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if showingMethod {
                        Button("返回") { showingMethod = false }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                            .keyboardShortcut(.cancelAction).disabled(model.busy != nil)
                            .accessibilityIdentifier("desktop.connectionBack")
                    }
                }
                if showingMethod {
                    DesktopConnectionSetup(model: model, inSettings: true, onSaved: { showingMethod = false })
                } else if model.status == nil {
                    DesktopSettingsGroup("设备") {
                    HStack {
                        Text("准备此 Mac 后可配对手机").font(.system(size: 14)).foregroundStyle(.secondary)
                        Spacer()
                        Button("准备") { Task { await model.prepare() } }
                            .buttonStyle(DesktopSettingsButtonStyle())
                            .disabled(model.busy != nil).accessibilityIdentifier("desktop.prepare")
                    }.desktopSettingsRow()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        devices
                        network
                    }
                }
                if !showingMethod, let busy = model.busy { ProgressView(busy).controlSize(.small) }
                if !showingMethod, let failure = model.failure { Text(failure).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure).textSelection(.enabled) }
            }.padding(20).frame(maxWidth: 808).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingPairing, onDismiss: { model.isPairingDevice = false }) {
            DesktopPairingSheet(model: model, onFinish: { showingPairing = false })
        }
        .onDisappear { model.isPairingDevice = false }
        .confirmationDialog("移除这台设备？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            if let revoking { Button("移除设备", role: .destructive) { Task { await model.control("devices/revoke", body: ["id": revoking.id]) }; self.revoking = nil } }
        } message: { Text("它将无法访问这台电脑，已有任务会继续。") }
    }

    private var devices: some View {
        DesktopSettingsGroup("已配对设备") {
            HStack {
                Spacer()
                Button("配对手机", systemImage: "qrcode") {
                    model.isPairingDevice = true
                    Task {
                        if model.status?.tunnel.state == "connected" { _ = await model.control("pair/invite") }
                        showingPairing = true
                    }
                }
                .buttonStyle(DesktopSettingsButtonStyle())
                .disabled(model.busy != nil).accessibilityIdentifier("desktop.addDevice")
            }
            Divider()
            ForEach(model.status?.devices.filter { $0.state == "approved" } ?? []) { device in
                HStack {
                    Label(device.name, systemImage: "iphone").font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 16)
                    Button("移除", role: .destructive) { revoking = device }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(MoMoPalette.failure)
                        .frame(minWidth: 44, minHeight: 36).disabled(model.busy != nil)
                        .accessibilityLabel("移除 \(device.name)")
                }.desktopSettingsRow()
            }
            if model.status?.devices.contains(where: { $0.state == "approved" }) != true {
                Text("尚未配对手机").font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
        }
    }

    private var network: some View {
        DesktopSettingsGroup("网络") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("远程访问").fontWeight(.medium)
                    Text(tunnelLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("远程访问", isOn: Binding(get: { model.status?.tunnel.state != "stopped" }, set: { enabled in
                    Task { await model.control(enabled ? "tunnel/start" : "tunnel/stop") }
                })).labelsHidden().toggleStyle(.switch)
                    .accessibilityHint(tunnelLabel)
                    .disabled(model.busy != nil).accessibilityIdentifier("desktop.remoteAccess")
            }.desktopSettingsRow()
            Divider()
            Button { showingMethod = true } label: {
                HStack {
                    Text("连接方式").fontWeight(.medium); Spacer()
                    Text(["tailscale", "embedded"].contains(model.status?.tunnel.mode ?? "") ? "Tailscale 私网" : model.status?.tunnel.mode == "external" ? "自建服务器" : model.status?.tunnel.mode == "relay" ? "加密中继" : "待选择").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                }.desktopSettingsRow().contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy != nil).accessibilityIdentifier("desktop.connectionMethod")
            if let url = model.status?.tunnel.endpoint {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("当前地址").fontWeight(.medium).fixedSize()
                    Spacer(minLength: 0)
                    Text(url).font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }.desktopSettingsRow().accessibilityElement(children: .combine)
            }
            if let error = model.status?.tunnel.error {
                Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure).textSelection(.enabled)
            }
        }.font(.system(size: 14))
    }

    private var tunnelLabel: String {
        switch model.status?.tunnel.state {
        case "connected": String(localized: "可用")
        case "starting": String(localized: "准备中")
        case "reconnecting": String(localized: "恢复中")
        case "failed", "needs_setup": String(localized: "需要设置")
        default: String(localized: "已关闭")
        }
    }
}

struct PairingQRCode: View {
    let payload: String
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() } else { ProgressView() } }
            .accessibilityLabel("手机配对二维码")
            .task(id: payload) {
                let filter = CIFilter.qrCodeGenerator(); filter.message = Data(payload.utf8); filter.correctionLevel = "M"
                guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return }
                image = NSImage(cgImage: cg, size: output.extent.size)
            }
    }
}

struct DesktopChat: View {
    @Bindable var model: DesktopModel
    @State private var composeRevision = 0
    @State private var previewAttachment: AgentAttachment?
    @State private var showingActiveTasks = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        VStack(spacing: 0) {
            if let store = model.taskStore {
                let snapshot = ChatRenderSnapshot(store: store, readingPosition: model.readingPosition)
                let isEmpty = store.isEmpty || snapshot.messages.isEmpty
                VStack(spacing: isEmpty ? 18 : 6) {
                    PersonalAgentSlot(size: isEmpty ? 144 : 56, active: store.hasActiveTask, expression: store.hasActiveTask ? .thinking : .present)
                    PhoneBrandWordmark(.momo, size: isEmpty ? 22 : 12)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: isEmpty ? .infinity : nil)
                .padding(.top, isEmpty ? 0 : 12)
                .padding(.bottom, isEmpty ? 0 : 8)
                if !isEmpty {
                    ChatRendererView(snapshot: snapshot, scrollToBottomRequest: composeRevision, onReadingPosition: model.rememberReadingPosition,
                        onAttachment: { id in previewAttachment = store.attachment(id: id) },
                        onRetryMessage: { id in Task { await store.checkAgain(id: id) } })
                        .frame(maxWidth: 780)
                }
                RemoteTaskControlsView(store: store, returnDesktop: {
                    do { try model.desktopHost?.returnControl() }
                    catch { model.failure = error.localizedDescription }
                }).frame(maxWidth: 780)
                RemoteTaskRecoveryView(store: store).frame(maxWidth: 780)
                if let failure = store.interactionFailure { Text(failure).font(.footnote).foregroundStyle(MoMoPalette.failure) }
                ClientComposer(text: Binding(get: { store.draft }, set: store.setDraft),
                               store: store,
                               inputID: "desktop.message", sendID: "desktop.send",
                               prompt: "发消息给 MoMo",
                               onCompose: { composeRevision += 1 },
                               onPreviewAttachment: { previewAttachment = $0 },
                               onError: { model.failure = $0 }) {
                    do { try store.enqueue(); Task { await store.refresh(userInitiated: true) } } catch { model.failure = error.localizedDescription }
                }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.bottom, 24).padding(.top, 12)
            } else {
                Spacer(); PersonalAgentSlot(size: 144, active: false, expression: .concerned)
                PhoneBrandWordmark(.momo, size: 24).padding()
                Text("MoMo 暂时没有连接上").phoneText(.heading)
                SettingsLink { Text("检查连接") }
                    .buttonStyle(DesktopSetupButton(minimumHeight: 48, fontSize: 14)).frame(width: 240).padding(); Spacer()
            }
        }.frame(maxWidth: .infinity).background(MoMoPalette.canvas)
            .overlay(alignment: .topTrailing) {
                desktopActiveTasksButton(store: model.taskStore)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
            }
            .sheet(item: $previewAttachment) { ClientAttachmentPreview(attachment: $0) }
            .animation(reduced ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: model.taskStore?.tasks.isEmpty)
    }

    private func desktopActiveTasksButton(store: RemoteTaskStore?) -> some View {
        let tasksSnap = AgentActiveTasksSnapshot(store: store)
        return Button {
            showingActiveTasks.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                Text("任务")
                    .font(.system(size: 12, weight: .medium))
                if let badge = tasksSnap.badgeText {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MoMoPalette.canvas)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(MoMoPalette.ink, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(MoMoPalette.ink)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(MoMoPalette.paper, in: Capsule())
            .overlay { Capsule().strokeBorder(MoMoPalette.line, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("查看正在进行的子智能体与后台任务")
        .accessibilityLabel(tasksSnap.count > 0 ? LocalizedStringKey("正在进行的任务，\(tasksSnap.count) 项") : LocalizedStringKey("正在进行的任务"))
        .accessibilityIdentifier("desktop.activeTasks")
        .popover(isPresented: $showingActiveTasks, arrowEdge: .bottom) {
            AgentActiveTasksSheet(store: store, isPopover: true)
                .frame(width: 380)
                .frame(minHeight: 240, maxHeight: 440)
        }
    }
}

struct DesktopSettings: View {
    private enum Page: String, CaseIterable, Identifiable {
        case model = "模型", pairing = "设备", memory = "记忆", advanced = "通用"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .model: "sparkles"
            case .pairing: "iphone"
            case .memory: "book.closed"
            case .advanced: "gearshape"
            }
        }
    }
    @Bindable var model: DesktopModel
    @State private var page = Page.advanced
    @State private var search = ""
    @State private var permissions = DesktopPermissionsController()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 15.0, *) {
            settingsContent.toolbar(removing: .title)
        } else {
            settingsContent
        }
    }

    private var settingsContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("设置").font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 10).padding(.bottom, 18)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("搜索", text: $search).textFieldStyle(.plain)
                        .accessibilityIdentifier("settings.search")
                        .onSubmit { if let first = matchingPages.first { page = first } }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    }
                }
                .font(.system(size: 14)).padding(.horizontal, 12).frame(height: 34)
                .background(Color.primary.opacity(0.045), in: Capsule())
                .padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if !search.isEmpty {
                            ForEach(matchingPages) { sidebarRow($0) }
                            if matchingPages.isEmpty {
                                Text("没有匹配的设置").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                            }
                        } else {
                            Text("个人").font(.system(size: 12)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).padding(.bottom, 5)
                            sidebarRow(.advanced)
                            sidebarRow(.model)
                            sidebarRow(.memory)
                            Text("设备").font(.system(size: 12)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 5)
                            sidebarRow(.pairing)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 44).frame(width: 240)
            .background {
                (colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(.sRGB, white: 0.985, opacity: 1))
                    .ignoresSafeArea(.container)
            }
            Divider().ignoresSafeArea(.container)
            Group {
                switch page {
                case .model: modelSettings
                case .pairing: DesktopDevices(model: model)
                case .memory: DesktopMemory(model: model)
                case .advanced: advancedSettings
                }
            }
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Color(nsColor: .textBackgroundColor).ignoresSafeArea(.container) }
        }
        .ignoresSafeArea(.container)
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity, minHeight: 500, idealHeight: 560, maxHeight: .infinity)
        .background(MoMoPalette.canvas)
        .background(DesktopWindowChrome())
        .environment(\.desktopSettingsDensity, true)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(MoMoPalette.ink).foregroundStyle(MoMoPalette.ink)
        .onChange(of: model.managingConnection) { _, show in
            if show { page = .pairing; model.managingConnection = false }
        }
    }

    private var matchingPages: [Page] {
        [Page.advanced, .model, .memory, .pairing].filter { destination in
            let terms: [String]
            switch destination {
            case .advanced: terms = [String(localized: "通用"), String(localized: "网络代理"), String(localized: "电脑控制"), String(localized: "运行环境"), String(localized: "智能体引擎"), "Hermes", "SuperAgent", "Proactive"]
            case .model: terms = [String(localized: "模型"), "API", "Codex", "Claude"]
            case .memory: terms = [String(localized: "记忆")]
            case .pairing: terms = [String(localized: "设备"), String(localized: "配对手机"), String(localized: "远程访问")]
            }
            return terms.contains { $0.localizedStandardContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private func sidebarRow(_ destination: Page) -> some View {
        Button { page = destination } label: {
            HStack(spacing: 9) {
                Image(systemName: destination.icon).font(.system(size: 14, weight: .regular))
                    .frame(width: 18).accessibilityHidden(true)
                Text(LocalizedStringKey(destination.rawValue)).font(.system(size: 14, weight: .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(page == destination ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("settings." + destination.id)
        .accessibilityAddTraits(page == destination ? .isSelected : [])
    }

    private var modelSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("模型").font(.system(size: 22, weight: .medium)).accessibilityAddTraits(.isHeader)
                DesktopSettingsGroup("接入方式") {
                    ModelConnectionFields(model: model).padding(.vertical, 6)
                }
                if model.status?.agentOnline == true {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MoMo 正在运行").font(.system(size: 14))
                            Text("停止后可更换模型").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("停止运行") { model.stopAgent() }
                            .buttonStyle(DesktopSettingsButtonStyle())
                            .disabled(!model.ownsAgent).accessibilityIdentifier("settings.stopAgent")
                    }
                }
                if let busy = model.busy { ProgressView(busy).controlSize(.small) }
                if let failure = model.failure { Text(failure).font(.callout).foregroundStyle(MoMoPalette.failure).textSelection(.enabled) }
            }.padding(20).frame(maxWidth: 808).frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var advancedSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("通用").font(.system(size: 22, weight: .medium)).accessibilityAddTraits(.isHeader)
                DesktopNetworkProxy(model: model)
                DesktopSettingsGroup("电脑控制") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("屏幕与控制权限").font(.system(size: 14))
                            Text("在系统设置「隐私与安全性」开启辅助功能与屏幕录制后，MoMo 与配对手机可查看和操作电脑")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button("管理") { permissions.present() }
                            .buttonStyle(DesktopSettingsButtonStyle())
                            .accessibilityIdentifier("settings.permissions")
                    }.desktopSettingsRow()
                    Divider().opacity(0.45)
                    HStack {
                        Text("电脑控制权").fontWeight(.regular)
                        Spacer()
                        if model.desktopHost?.humanHasControl == true {
                            Button("交还 MoMo") {
                                do { try model.desktopHost?.returnControl() }
                                catch { model.desktopFailure = error.localizedDescription }
                            }
                            .buttonStyle(DesktopSettingsButtonStyle())
                            .accessibilityIdentifier("settings.returnControl")
                        } else {
                            Text(model.desktopHost == nil ? "尚未连接" : "MoMo").foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 14)).desktopSettingsRow()
                    if let error = model.desktopFailure { Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure) }
                }
                DesktopSettingsGroup("智能体引擎") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Agent Runtime").font(.system(size: 14))
                            Text(model.runtimeEngine.summary)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Picker("Agent Runtime", selection: Binding(
                            get: { model.runtimeEngine },
                            set: { target in Task { await model.switchRuntimeEngine(target) } }
                        )) {
                            ForEach(DesktopAgentEngine.allCases) { engine in
                                Text(engine.title).tag(engine)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 196)
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("settings.runtimeEngine")
                    }.desktopSettingsRow()
                    if model.runtimeEngine == .superagent, let snap = model.proactiveSnapshot {
                        Divider().opacity(0.45)
                        HStack {
                            Text("引擎状态").font(.system(size: 14))
                            Spacer()
                            Text(snap.dshReady
                                 ? String(localized: "已就绪 · 进行中 \(snap.activeTickets) · 已分析 \(snap.totalDecisions)")
                                 : String(localized: "正在启动 DeepSeek SuperAgent…"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.desktopSettingsRow()
                    }
                }
                DesktopSettingsGroup("运行环境") {
                    if model.hasBundledRuntime {
                        HStack {
                            Text("运行组件")
                            Spacer()
                            Text("已内置").foregroundStyle(.secondary)
                        }.font(.system(size: 14)).desktopSettingsRow()
                    } else {
                        settingsAction("运行组件", action: "准备", id: "settings.prepareRuntime", disabled: model.busy != nil) {
                            Task { await model.prepare() }
                        }
                    }
                    Divider().opacity(0.45)
                    settingsAction("应用更新", action: "获取更新", id: "settings.getUpdates") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Miri-Labs/MoMo-Agent/releases/latest")!)
                    }
                    Divider().opacity(0.45)
                    settingsAction("结果文件夹", action: "打开", id: "settings.openResults") { model.showFiles() }
                    if let busy = model.busy { ProgressView(busy).controlSize(.small) }
                    if let failure = model.failure { Text(failure).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure) }
                }
            }.padding(20).frame(maxWidth: 808).frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func settingsAction(_ title: String, action label: String, id: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.system(size: 14))
            Spacer()
            Button(LocalizedStringKey(label), action: perform)
                .buttonStyle(DesktopSettingsButtonStyle())
                .disabled(disabled).accessibilityIdentifier(id)
        }.desktopSettingsRow()
    }
}

/// The presentation owns its measured height so each pairing step can resize the sheet.
private struct DesktopPairingSheet: View {
    let model: DesktopModel
    let onFinish: () -> Void
    @State private var contentHeight: CGFloat = 360

    var body: some View {
        if #available(macOS 15, *) {
            content.presentationSizing(PairingPresentationSize(height: min(contentHeight, 640)))
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            DesktopOnboardingPairing(model: model, onFinish: onFinish)
                .padding(20).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }.frame(width: 480, height: min(contentHeight, 640))
    }
}

@available(macOS 15, *)
private struct PairingPresentationSize: PresentationSizing {
    let height: CGFloat

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: 480, height: height)
    }
}

// Open rows size from their content; controls keep their native hit targets.
extension View {
    func desktopSettingsRow() -> some View {
        frame(minHeight: 20).padding(.vertical, 12)
    }
}

/// Quiet grouping shared by desktop settings; native controls retain focus and roles.
struct DesktopSettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 13, weight: .regular)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.05), lineWidth: 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        }
    }
}


struct DesktopSettingsControlSurface: ViewModifier {
    var active = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .regular))
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(active ? 0.45 : contrast == .increased ? 0.35 : 0.14), lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct DesktopSettingsButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? MoMoPalette.failure : Color.primary)
            .modifier(DesktopSettingsControlSurface(active: hovered || configuration.isPressed))
            .overlay {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.05 : 0))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .onHover { hovered = $0 }
    }
}
