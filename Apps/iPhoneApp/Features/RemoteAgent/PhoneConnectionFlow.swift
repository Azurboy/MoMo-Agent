import SwiftUI

struct PhoneConnectionFlow: View {
    @Bindable var agent: PhoneRemoteAgent
    var reconnecting = false
    let finish: () -> Void
    var deferConnection: (() -> Void)?
    @State private var initialGeneration: Int?
    @State private var networkPrepared = false
    @State private var login = TailnetLogin()
    @State private var showingHelp = false
    private var canScan: Bool { networkPrepared || agent.pairing.pending != nil || agent.tailnet.state == "Running" }
    private var ready: Bool { agent.store != nil && agent.pairing.pending == nil && (!reconnecting || agent.pairing.completionGeneration > (initialGeneration ?? agent.pairing.completionGeneration)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    PersonalAgentSlot(size: ready || canScan ? 120 : 64, active: false, expression: ready ? .settled : .present)
                    PhoneBrandWordmark(.momo, size: ready || canScan ? 24 : 18)
                }
                Text(ready ? "配对成功" : canScan ? "扫码连接 Mac" : "连接 Mac")
                    .phoneText(.heading).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                if ready {
                    Label("配对已验证", systemImage: "checkmark.circle")
                    Button("开始聊天", action: finish).buttonStyle(ClientPrimaryButton()).accessibilityIdentifier("onboarding.finish")
                } else {
                    if canScan {
                        PhonePairingControls(agent: agent)
                    } else {
                        Text("手机与 Mac 登录同一账号")
                            .phoneText(.body).foregroundStyle(MoMoPalette.muted).multilineTextAlignment(.center)
                            Button { login.begin(agent.tailnet) } label: {
                                if login.busy { Text("正在连接") }
                                else {
                                    HStack(spacing: 10) {
                                        Image("TailscaleMark").resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                                        Text("登录 Tailscale")
                                    }
                                }
                            }
                                .buttonStyle(ClientPrimaryButton(isLoading: login.busy)).disabled(login.busy)
                                .accessibilityIdentifier("onboarding.loginTailscale")
                        if let error = login.error ?? agent.tailnet.message, !login.busy {
                            Text(error).phoneText(.caption).foregroundStyle(MoMoPalette.failure)
                        }
                    }
                    if let deferConnection {
                        Button("稍后配对") {
                            try? agent.pairing.clear()
                            deferConnection()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MoMoPalette.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }.frame(maxWidth: 480).padding(24).frame(maxWidth: .infinity)
        }
        .phoneScrollHeader { connectionHeader }
        .phonePageSurface()
        .task { try? await agent.tailnet.start() }
        .onAppear { if initialGeneration == nil { initialGeneration = agent.pairing.completionGeneration } }
        .onDisappear { login.cancel() }
    }

    private var connectionHeader: some View {
        HStack(spacing: 12) {
            PhoneBrandIcon(size: 28); PhoneBrandWordmark()
            Spacer()
            Menu {
                Button("连接帮助") { showingHelp = true }
                Button("加密中继") { login.cancel(); networkPrepared = true }
                    .accessibilityIdentifier("onboarding.relay")
                Button("自建服务器") { login.cancel(); networkPrepared = true }
                    .accessibilityIdentifier("onboarding.otherNetwork")
                if agent.tailnet.state == "Running" {
                    Button("退出账号") {
                        Task {
                            do { try await agent.tailnet.logout(); networkPrepared = false }
                            catch { login.error = error.localizedDescription }
                        }
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("更多连接选项").accessibilityIdentifier("onboarding.more")
                .popover(isPresented: $showingHelp) { TailnetHelp().presentationCompactAdaptation(.popover) }
            if reconnecting { Button("取消", action: finish).frame(minHeight: 44) }
        }.padding(24)
    }
}
