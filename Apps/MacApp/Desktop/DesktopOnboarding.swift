import SwiftUI
import AppKit

struct ModelConnectionFields: View {
    private enum Page { case choices, login, subscription, api }
    @Bindable var model: DesktopModel
    var continueSetup = false
    @State private var page: Page?
    @State private var browserFailed = false
    @State private var choosingModel = false
    @State private var hoveredModel: String?
    @FocusState private var modelOptionsFocused: Bool
    private var currentPage: Page {
        if model.modelLogin != nil { return .login }
        if page == .login { return model.subscriptionConnected ? .subscription : .choices }
        if let page { return page }
        guard !continueSetup, !model.modelName.isEmpty else { return .choices }
        return model.modelProvider == .api ? .api : .subscription
    }

    var body: some View {
        VStack(alignment: continueSetup ? .center : .leading, spacing: 24) {
            if continueSetup, currentPage != .api {
                PersonalAgentSlot(size: 64, active: model.busy != nil, expression: .present)
            }
            switch currentPage {
            case .choices:
                if continueSetup { pageTitle("连接你的模型") }
                VStack(spacing: continueSetup ? 12 : 4) {
                    ForEach(DesktopModelProvider.allCases) { provider in
                        if continueSetup {
                            Button { choose(provider) } label: { providerLabel(provider) }
                                .buttonStyle(DesktopSetupButton(filled: provider == .codex))
                                .accessibilityIdentifier("model.provider." + provider.rawValue)
                        } else {
                            Button { choose(provider) } label: {
                                HStack {
                                    providerLabel(provider)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                                }.frame(minHeight: 52).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("model.provider." + provider.rawValue)
                            if provider != DesktopModelProvider.allCases.last { Divider() }
                        }
                    }
                }.disabled(model.busy != nil || model.loadingModelAccount || model.status?.agentOnline == true)
                    .accessibilityElement(children: .contain).accessibilityLabel("接入方式")
                if model.modelProvider == .claude, model.modelAccount?.loginAvailable == false {
                    Link("安装 Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                        .font(.callout)
                }
            case .api:
                if continueSetup {
                    pageTitle("配置 API")
                }
                if !continueSetup, model.status?.agentOnline == true {
                    VStack(spacing: 4) {
                        modelValue("服务", value: "API")
                        modelValue("模型", value: model.modelName)
                        modelValue("API 地址", value: model.providerURL)
                    }.font(.system(size: 14))
                } else {
                    apiFields
                    Text("密钥保存在这台电脑。验证时会发送一条测试消息。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if continueSetup { continueButton }
            case .subscription:
                if continueSetup { pageTitle("选择模型") }
                subscriptionSelection
                if continueSetup { continueButton }
            case .login:
                if !continueSetup { providerIcon(model.modelProvider).frame(width: 28, height: 28).accessibilityHidden(true) }
                pageTitle("登录 " + model.modelProvider.name)
                if let login = model.modelLogin {
                    if let failure = login.failure {
                        Text(failure).foregroundStyle(MoMoPalette.failure).font(.callout)
                    } else if let url = login.authorizationURL {
                        if let code = login.code {
                            HStack(spacing: 12) {
                                Text(code).font(.title.monospaced()).textSelection(.enabled)
                                    .accessibilityIdentifier("model.loginCode")
                                Button { copy(code) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.plain).help("复制验证码").accessibilityLabel("复制验证码")
                            }
                        }
                        HStack(spacing: 12) {
                            Button("打开登录页") { openLoginPage(url) }
                                .buttonStyle(DesktopSetupButton(minimumHeight: continueSetup ? 52 : 36, fontSize: continueSetup ? 15 : 13))
                                .accessibilityIdentifier("model.openLogin")
                            Button { copy(url.absoluteString) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.plain).help("复制登录链接").accessibilityLabel("复制登录链接")
                        }
                        if browserFailed { Text("请复制链接，在浏览器打开。").font(.caption).foregroundStyle(.secondary) }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(login.expiresAt.timeIntervalSince(context.date)))
                            Text("有效期 \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView("正在准备登录…").controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    Button(login.failure == nil ? "重新开始" : "重试") { model.beginModelLogin(flow: login.flow) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("model.retryLogin")
                    if login.provider == .codex {
                        Button(login.flow == .device ? "改用浏览器登录" : "改用验证码登录") {
                            model.beginModelLogin(flow: login.flow == .device ? .browser : .device)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("model.switchLogin")
                    }
                }
            }
            if model.loadingModelAccount, currentPage == .choices {
                ProgressView("正在检查登录状态…").controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if continueSetup {
                backButton
            } else if model.status?.agentOnline != true, currentPage != .choices {
                HStack {
                    backButton
                    Spacer()
                    if currentPage == .api || currentPage == .subscription {
                        Button("保存并启动") { Task { await model.connectModel(continueSetup: false) } }
                            .buttonStyle(DesktopSetupButton(minimumHeight: 36, fontSize: 13)).frame(width: 112)
                            .disabled(model.busy != nil || model.loadingModelAccount)
                            .accessibilityIdentifier("model.continue")
                    }
                }
            }
        }
        .multilineTextAlignment(continueSetup ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: continueSetup ? .center : .leading)
        .overlayPreferenceValue(ModelSelectionAnchor.self) { anchor in
            if choosingModel, let anchor {
                GeometryReader { geometry in
                    let field = geometry[anchor]
                    let height = min(CGFloat(model.modelAccount?.models.count ?? 0) * (continueSetup ? 48 : 36) + 16, 252)
                    let above = height > geometry.size.height - field.maxY + 40
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: 4000, height: 4000).contentShape(Rectangle())
                            .offset(x: -2000, y: -2000).onTapGesture { choosingModel = false }
                            .accessibilityHidden(true)
                        modelOptions
                            .frame(width: field.width, height: height)
                            .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MoMoPalette.line, lineWidth: 1))
                            .shadow(color: .black.opacity(0.09), radius: 14, y: 6)
                            .offset(x: field.minX, y: above ? field.minY - height - 6 : field.maxY + 6)
                    }
                }
            }
        }
        .onChange(of: model.modelLogin?.authorizationURL) { _, url in
            browserFailed = false
            if currentPage == .login, let url { openLoginPage(url) }
        }
        .onDisappear { if model.modelLogin != nil { model.cancelModelConnection() } }
        .task {
            guard !continueSetup, !model.modelName.isEmpty, model.modelProvider != .api else { return }
            await model.refreshModelAccount()
        }
    }

    private var backButton: some View {
        Button(continueSetup || currentPage == .login ? "返回" : "更换服务") {
            choosingModel = false
            let origin = currentPage
            if origin == .login { model.cancelModelConnection() }
            if origin == .choices { model.advanceSetup(.prepare) }
            else { page = .choices; model.failure = nil }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 6)
        .disabled(model.busy != nil || model.loadingModelAccount)
        .accessibilityIdentifier("model.back")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openLoginPage(_ url: URL) {
        browserFailed = !NSWorkspace.shared.open(url)
    }

    private func pageTitle(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(continueSetup ? .system(size: 28, weight: .semibold) : .headline).accessibilityAddTraits(.isHeader)
    }

    private func modelValue(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(title)).fontWeight(.medium).fixedSize()
            Spacer(minLength: 0)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.desktopSettingsRow().accessibilityElement(children: .combine)
    }

    @ViewBuilder private var subscriptionSelection: some View {
        if continueSetup {
            VStack(spacing: 16) {
                subscriptionIdentity
                modelSelection
            }
            .padding(20).background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MoMoPalette.line, lineWidth: 1))
        } else {
            VStack(spacing: 0) {
                subscriptionIdentity.padding(.vertical, 9)
                HStack(spacing: 24) {
                    Text("模型").font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    if model.status?.agentOnline == true {
                        Text(model.modelName).font(.system(size: 14)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                            .help("停止运行后可更换模型").accessibilityIdentifier("model.current")
                    } else { modelSelection.frame(maxWidth: 264) }
                }.desktopSettingsRow()
            }
        }
    }

    private var subscriptionIdentity: some View {
        HStack(spacing: 10) {
            providerIcon(model.modelProvider).frame(width: 24, height: 24).accessibilityHidden(true)
            Text(model.modelProvider.name).font(.system(size: continueSetup ? 16 : 14, weight: .medium))
            Spacer(minLength: 12)
            if model.loadingModelAccount {
                ProgressView().controlSize(.small).accessibilityLabel("正在检查登录状态")
                    .accessibilityIdentifier("model.account.refreshing")
            } else if model.subscriptionConnected {
                Label("已登录", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(MoMoPalette.success)
            } else if model.modelAccount == nil {
                Text("已配置").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button("重新登录") { model.beginModelLogin() }.buttonStyle(.plain)
                    .disabled(model.status?.agentOnline == true)
            }
        }
    }

    private var modelSelection: some View {
        Button { choosingModel = true } label: {
            HStack {
                Text(model.modelName.isEmpty ? "选择模型" : model.modelName).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .font(.system(size: continueSetup ? 15 : 14)).padding(.horizontal, 14).frame(height: continueSetup ? 46 : 28)
            .background(continueSetup ? MoMoPalette.surface : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: continueSetup ? 12 : 6))
            .overlay { if !continueSetup { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(choosingModel ? 0.45 : 0.14), lineWidth: 1).allowsHitTesting(false) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("模型").accessibilityValue(model.modelName).accessibilityIdentifier("model.selection")
        .disabled(model.busy != nil || model.status?.agentOnline == true || model.modelAccount?.models.isEmpty != false)
        .anchorPreference(key: ModelSelectionAnchor.self, value: .bounds) { $0 }
    }

    private var modelOptions: some View {
        let models = model.modelAccount?.models ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(models, id: \.self) { name in
                        Button {
                            model.modelName = name
                            choosingModel = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(name).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
                                    .opacity(model.modelName == name ? 1 : 0).accessibilityHidden(true)
                            }
                            .font(.system(size: continueSetup ? 14 : 13)).padding(.horizontal, 12).frame(height: continueSetup ? 44 : 32)
                            .contentShape(Rectangle())
                            .background(model.modelName == name || hoveredModel == name ? MoMoPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).id(name).help(name)
                        .onHover { hoveredModel = $0 ? name : nil }
                        .accessibilityAddTraits(model.modelName == name ? .isSelected : [])
                        .accessibilityIdentifier("model.option." + name)
                    }
                }.padding(8)
            }
            .onAppear { proxy.scrollTo(model.modelName, anchor: .center) }
        }
        .foregroundStyle(MoMoPalette.ink).focusable().focusEffectDisabled().focused($modelOptionsFocused)
        .onAppear { modelOptionsFocused = true }
        .onExitCommand { choosingModel = false }
    }

    private func providerLabel(_ provider: DesktopModelProvider) -> some View {
        HStack(spacing: 12) {
            providerIcon(provider).frame(width: continueSetup ? 28 : 20, height: continueSetup ? 28 : 20).accessibilityHidden(true)
            Text(provider == .api ? "使用 API" : "使用 \(provider.name) 订阅").font(.system(size: continueSetup ? 15 : 14))
        }
    }

    @ViewBuilder private func providerIcon(_ provider: DesktopModelProvider) -> some View {
        switch provider {
        case .codex: Image("OpenAIMark").renderingMode(.template).resizable().scaledToFit()
        case .claude: Image("AnthropicMark").renderingMode(.template).resizable().scaledToFit()
        case .api: Image(systemName: "key.horizontal").font(.system(size: 24, weight: .regular))
        }
    }

    private var apiFields: some View {
        VStack(alignment: .leading, spacing: continueSetup ? 16 : 0) {
            apiField("API 地址") {
                TextField("https://api.example.com/v1", text: $model.providerURL).accessibilityIdentifier("onboarding.modelURL")
            }
            apiField("模型") {
                TextField("模型名称", text: $model.modelName).accessibilityIdentifier("onboarding.modelName")
            }
            apiField("密钥") {
                SecureField("API 密钥", text: $model.providerKey).accessibilityIdentifier("onboarding.modelKey")
            }
        }.multilineTextAlignment(.leading).disabled(model.busy != nil || model.status?.agentOnline == true)
    }

    @ViewBuilder private func apiField<Content: View>(_ title: String, @ViewBuilder input: () -> Content) -> some View {
        let field = input().textFieldStyle(.plain).font(.system(size: 14)).padding(.horizontal, 14)
            .frame(height: continueSetup ? 44 : 28)
            .background(continueSetup ? MoMoPalette.surface : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: continueSetup ? 10 : 6))
            .overlay { if !continueSetup { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1).allowsHitTesting(false) } }
        if continueSetup {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(title)).font(.system(size: 12)).foregroundStyle(.secondary)
                field
            }
        } else {
            HStack(spacing: 16) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .medium)).fixedSize()
                Spacer(minLength: 0)
                field.frame(maxWidth: 280)
            }.desktopSettingsRow()
        }
    }

    private var continueButton: some View {
        Button(continueSetup ? "验证并继续" : "保存并启动") {
            Task { await model.connectModel(continueSetup: continueSetup) }
        }
        .buttonStyle(DesktopSetupButton())
        .disabled(model.busy != nil || model.loadingModelAccount || model.status?.agentOnline == true)
        .accessibilityIdentifier("model.continue")
    }

    private func choose(_ provider: DesktopModelProvider) {
        guard model.busy == nil, !model.loadingModelAccount else { return }
        model.modelProvider = provider
        model.failure = nil
        if provider == .api { page = .api; return }
        page = .login
        model.beginModelLogin()
    }
}

private struct ModelSelectionAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct DesktopSettingsDensityKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var desktopSettingsDensity: Bool {
        get { self[DesktopSettingsDensityKey.self] }
        set { self[DesktopSettingsDensityKey.self] = newValue }
    }
}

struct DesktopSetupButton: ButtonStyle {
    @Environment(\.desktopSettingsDensity) private var inSettings
    var filled = true
    var minimumHeight: CGFloat = 52
    var fontSize: CGFloat = 16
    var isLoading = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if inSettings {
            HStack(spacing: 6) {
                if isLoading { ProgressView().controlSize(.small) }
                configuration.label
            }
            .foregroundStyle(Color.primary)
            .modifier(DesktopSettingsControlSurface(active: configuration.isPressed))
        } else {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView().controlSize(.small)
                    .environment(\.colorScheme, filled ? (colorScheme == .dark ? .light : .dark) : colorScheme)
                    .accessibilityHidden(true)
            }
            configuration.label
        }.font(.system(size: fontSize, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .foregroundStyle(filled ? MoMoPalette.canvas : MoMoPalette.ink)
            .background(filled ? MoMoPalette.ink : MoMoPalette.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(MoMoPalette.ink.opacity(filled ? 0 : 0.16), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isLoading ? 1 : enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }
    }
}

struct DesktopOnboarding: View {
    @Bindable var model: DesktopModel
    var body: some View {
        Group {
            if model.setupStep == .welcome {
                WelcomeExperienceView(finish: model.continueWelcome).frame(maxWidth: 560).frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    windowHeader
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(spacing: 20) {
                                if model.setupStep != .pair && model.setupStep != .model && model.setupStep != .permissions {
                                    PersonalAgentSlot(size: 64, active: model.busy != nil, expression: model.setupStep == .ready ? .settled : .present)
                                }
                                stage
                                if let busy = model.busy, model.preparationPhase == nil, model.setupStep != .pair && model.setupStep != .permissions { ProgressView(busy).controlSize(.small).accessibilityIdentifier("onboarding.progress") }
                                if let failure = model.failure, model.setupStep != .pair { Text(failure).foregroundStyle(MoMoPalette.failure).phoneText(.metadata).textSelection(.enabled) }
                            }.frame(maxWidth: 360).padding(.horizontal, 32).padding(.vertical, 32).frame(maxWidth: .infinity)
                                .frame(minHeight: geometry.size.height)
                        }
                    }
                }
            }
        }.background(MoMoPalette.canvas.ignoresSafeArea()).background(DesktopWindowChrome()).ignoresSafeArea(.container)
    }
    @ViewBuilder private var windowHeader: some View {
        if #available(macOS 15.0, *) { headerContent.gesture(WindowDragGesture()) }
        else { headerContent }
    }
    private var headerContent: some View {
        HStack(spacing: 12) {
            PhoneBrandIcon(size: 24); PhoneBrandWordmark(size: 16)
            Spacer()
            Text(stepLabel).font(.system(size: 12).monospacedDigit()).foregroundStyle(MoMoPalette.muted)
        }.padding(.leading, 100).padding(.trailing, 28).frame(height: 60).contentShape(Rectangle())
    }
    private var stepLabel: String {
        switch model.setupStep {
        case .prepare: "1 / 4"
        case .model: "2 / 4"
        case .permissions: "3 / 4"
        case .pair: "4 / 4"
        default: String(localized: "准备完成")
        }
    }
    @ViewBuilder private var stage: some View {
        switch model.setupStep {
        case .prepare:
            title("准备 MoMo", detail: "让 MoMo 在这台 Mac 上运行")
            if let phase = model.preparationPhase {
                VStack(alignment: .leading, spacing: 12) {
                    if let download = model.preparationDownload {
                        ProgressView(value: download.fraction).progressViewStyle(.linear).tint(MoMoPalette.ink)
                            .accessibilityLabel("下载运行组件").accessibilityIdentifier("onboarding.downloadProgress")
                        HStack {
                            Text(DesktopDownloadProgress.bytes(download.received) + " / " + DesktopDownloadProgress.bytes(download.total))
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(download.speed(at: context.date).map { DesktopDownloadProgress.bytes($0) + "/s" } ?? "计算速度…")
                            }
                        }.font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        Text("当前批次").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(MoMoPalette.ink)
                            .accessibilityLabel(phase.label).accessibilityIdentifier("onboarding.downloadProgress")
                        Text(phase.label).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }.frame(minHeight: 52).accessibilityElement(children: .combine)
            } else {
                Button(model.hasBundledRuntime ? (model.failure == nil ? "开始设置" : "重试") : (model.failure == nil ? "下载运行组件" : "重试下载")) { Task { await model.prepareAndContinue() } }
                    .buttonStyle(DesktopSetupButton()).disabled(model.busy != nil).accessibilityIdentifier("onboarding.downloadRuntime")
            }
            Button("返回") { model.advanceSetup(.welcome) }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.busy != nil)
        case .model:
            if model.status?.agentOnline == true {
                PersonalAgentSlot(size: 64, active: false, expression: .present)
                Text("连接你的模型").font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Label("MoMo 已在运行", systemImage: "checkmark.circle")
                Button("继续") { model.advanceSetup(.permissions) }.buttonStyle(DesktopSetupButton())
                Button("返回") { model.advanceSetup(.prepare) }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                ModelConnectionFields(model: model, continueSetup: true)
            }
        case .permissions:
            DesktopOnboardingPermissions(model: model)
        case .pair:
            DesktopOnboardingPairing(model: model)
        case .ready:
            title(model.status?.agentOnline == true ? "准备好了" : "MoMo 尚未连接", detail: model.hasPairedPhone ? "手机已配对" : "随时可以配对手机")
            Label(model.status?.agentOnline == true ? (model.hasPairedPhone ? "Mac 正在运行 · 手机已连接" : "Mac 正在运行 · 可稍后连接手机") : "连接恢复后继续；已配对的信息会保留", systemImage: model.status?.agentOnline == true ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(MoMoPalette.muted)
            if model.status?.agentOnline != true {
                Button("检查模型连接") { model.advanceSetup(.model) }
            }
            Button("开始聊天") { model.advanceSetup(.completed) }.buttonStyle(DesktopSetupButton()).disabled(model.status?.agentOnline != true).accessibilityIdentifier("onboarding.finish")
        default: EmptyView()
        }
    }
    private func title(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Text(LocalizedStringKey(title)).phoneText(.heading).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            Text(LocalizedStringKey(detail)).phoneText(.body).foregroundStyle(MoMoPalette.muted).multilineTextAlignment(.center)
        }
    }
}

struct DesktopOnboardingPermissions: View {
    @Bindable var model: DesktopModel
    @State private var permissions = DesktopPermissionsController()
    @State private var openedScreenRecording = false

    private var state: DesktopPermissionState { permissions.state }
    private var primaryKind: DesktopPermissionKind? {
        DesktopPermissionKind.allCases.first { !state.isGranted($0) }
    }

    var body: some View {
        VStack(spacing: 24) {
            PersonalAgentSlot(size: 64, active: false, expression: state.allGranted ? .settled : .present)
            VStack(spacing: 8) {
                Text("开启电脑控制权限").font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text("让 MoMo 与配对手机能够查看屏幕并操作键鼠").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                permissionRow(.accessibility)
                Divider()
                permissionRow(.screenRecording)
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MoMoPalette.line, lineWidth: 1))

            if !state.allGranted {
                Text("若系统设置中已有旧的同名 MoMo Agent，请先选中点底部「-」移除再重新开启；开启屏幕录制后需重启生效。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = state.failure {
                Text(failure).font(.callout).foregroundStyle(MoMoPalette.failure)
            }

            if state.allGranted {
                Button("继续配对") { model.advanceSetup(.pair) }
                    .buttonStyle(DesktopSetupButton())
                    .accessibilityIdentifier("onboarding.permissionsContinue")
            } else if openedScreenRecording, !state.isGranted(.screenRecording) {
                Button("我已开启，重启刷新") { DesktopPermissionsController.relaunchApplication() }
                    .buttonStyle(DesktopSetupButton())
                    .accessibilityIdentifier("onboarding.permissionsRelaunch")
            }

            HStack(spacing: 24) {
                Button("返回") { model.advanceSetup(.model) }
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("onboarding.permissionsBack")
                if !state.allGranted, !openedScreenRecording || state.isGranted(.screenRecording) {
                    Button("重启刷新") { DesktopPermissionsController.relaunchApplication() }
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("onboarding.permissionsRelaunch")
                }
                if !state.allGranted {
                    Button("稍后开启") { model.advanceSetup(.pair) }
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("onboarding.skipPermissions")
                }
            }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .onAppear { permissions.startMonitoring() }
        .onDisappear { permissions.stopMonitoring() }
    }

    private func permissionRow(_ kind: DesktopPermissionKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.icon).font(.system(size: 17)).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.system(size: 14, weight: .medium))
                Text(kind.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
            }.multilineTextAlignment(.leading)
            Spacer(minLength: 12)
            if state.isGranted(kind) {
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MoMoPalette.success)
                    .accessibilityIdentifier("onboarding.permissions.\(kind.rawValue).granted")
            } else {
                Button("开启") {
                    if kind == .screenRecording { openedScreenRecording = true }
                    permissions.open(kind)
                }
                .buttonStyle(DesktopSetupButton(filled: primaryKind == kind, minimumHeight: 34, fontSize: 13))
                .frame(width: 68)
                .accessibilityLabel("开启\(kind.title)")
                .accessibilityIdentifier("onboarding.permissions.\(kind.rawValue).open")
            }
        }.padding(.vertical, 14)
    }
}
