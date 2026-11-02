import SwiftUI

/// Illustrative future contexts stay inside the introduction, never in the user's archive or chat.
struct WelcomeScenario: Identifiable {
    let id: String
    let title: String
    let moments: [String]
    let sources: [String]
    let request: String
    let reply: String
    let result: String
    let detail: String
    let symbol: String

    static let examples: [Self] = [
        .init(id: "travel", title: String(localized: "旅行，接着安排。"),
              moments: [String(localized: "11 月 20 日去大理。"), String(localized: "上海出发，选晚班。")],
              sources: [String(localized: "聊天"), String(localized: "日程与偏好")], request: String(localized: "安排一下行程。"),
              reply: String(localized: "好，选上海出发的晚班。"), result: String(localized: "上海 → 大理"),
              detail: String(localized: "11 月 20 日 · 晚间出发"), symbol: "airplane"),
        .init(id: "work", title: String(localized: "说过的事，接着做。"),
              moments: [String(localized: "周五给林总发方案。"), String(localized: "预算按邮件改。")],
              sources: [String(localized: "会议"), String(localized: "邮件与项目")], request: String(localized: "跟进刚才的事。"),
              reply: String(localized: "好，更新林总的方案。"), result: String(localized: "林总 · 新版方案"),
              detail: String(localized: "周五前 · 更新预算页"), symbol: "doc.text"),
        .init(id: "family", title: String(localized: "在意的人，也记着。"),
              moments: [String(localized: "下周六妈妈生日。"), String(localized: "吃清淡些，少走路。")],
              sources: [String(localized: "家人聊天"), String(localized: "关系与偏好")], request: String(localized: "安排一下生日。"),
              reply: String(localized: "好，找家清淡、好到的。"), result: String(localized: "妈妈的生日晚餐"),
              detail: String(localized: "下周六 · 清淡 · 方便到达"), symbol: "fork.knife")
    ]
}

private enum WelcomeStep: Int, CaseIterable {
    case firstMoment, listening, gathering, request, response, result, leaving, ready

    var duration: TimeInterval {
        switch self {
        // Three 3-second scenes; leave time for the final transition within the 10-second introduction.
        case .firstMoment: 0.15
        case .listening: 0.85
        case .gathering: 0.3
        case .request: 0.3
        case .response: 0.15
        case .result: 1.1
        case .leaving: 0.15
        case .ready: 0
        }
    }

    var elapsed: TimeInterval { Self.allCases.prefix(rawValue).reduce(0) { $0 + $1.duration } }
    static var sceneDuration: TimeInterval { Self.ready.elapsed }
}

struct WelcomeExperienceView: View {
    var finishTitle = "开始设置"
    let finish: () -> Void
    var greet: () -> Void = {}
    var closePreview: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scenarioIndex = 0
    @State private var step = WelcomeStep.firstMoment
    @State private var playbackStartedAt = Date.now

    private var scenario: WelcomeScenario { WelcomeScenario.examples[scenarioIndex] }
    private var playbackID: String { "\(scenarioIndex)-\(step.rawValue)-\(scenePhase == .active)-\(voiceOver)" }
    private var elapsed: TimeInterval { Double(scenarioIndex) * WelcomeStep.sceneDuration + step.elapsed }
    private var totalDuration: TimeInterval { Double(WelcomeScenario.examples.count) * WelcomeStep.sceneDuration }
    private var largeAvatarSize: CGFloat { 220 }
    private var showsConversation: Bool { step.rawValue >= WelcomeStep.request.rawValue }
    private var showsReply: Bool { step.rawValue >= WelcomeStep.response.rawValue }
    private var showsResult: Bool { step.rawValue >= WelcomeStep.result.rawValue }
    private var expression: PersonalAgentExpression {
        switch step {
        case .firstMoment, .listening: .listening
        case .gathering, .request: .thinking
        case .response: .speaking
        case .result, .leaving: .settled
        case .ready: .greeting
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 20) {
                        if step == .ready {
                            readyScene
                        } else {
                            ZStack {
                                if showsConversation {
                                    conversationScene
                                        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 24)))
                                } else {
                                    listeningScene
                                        .transition(.opacity)
                                }
                            }
                            .opacity(step == .leaving ? 0 : 1)
                            .offset(y: step == .leaving && !reduceMotion ? -18 : 0)
                            .accessibilityElement(children: .contain)
                            .accessibilityAction(named: "继续") { advanceForVoiceOver() }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .overlayPreferenceValue(WelcomeAvatarBoundsKey.self) { anchor in
                    GeometryReader { viewport in
                        let bounds = anchor.map { viewport[$0] } ?? .zero
                        // One live actor moves between the story and reply without reloading its WebView.
                        PersonalAgentSlot(size: largeAvatarSize, active: scenePhase == .active,
                                          expression: expression, action: greet)
                            .scaleEffect(bounds.width / largeAvatarSize)
                            .position(x: bounds.midX, y: bounds.midY)
                            .opacity(anchor == nil ? 0 : 1)
                            .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.08), value: showsConversation)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: step == .ready)
                    }
                }
                .clipped()
            }
            .phoneScrollHeader { welcomeHeader }

            footer.padding(.horizontal, 24).padding(.bottom, 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(MoMoPalette.ink)
        .phonePageSurface()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: playbackID) {
            guard scenePhase == .active, !voiceOver, step != .ready else { return }
            // Restart only the current beat after returning to the foreground, without skipping unread content.
            playbackStartedAt = .now.addingTimeInterval(-elapsed)
            do {
                try await Task.sleep(for: .seconds(step.duration))
                try Task.checkCancellation()
                advance()
            } catch is CancellationError { }
            catch { assertionFailure("Unexpected introduction clock failure: \(error)") }
        }
    }

    private func avatarSlot(size: CGFloat) -> some View {
        Color.clear.frame(width: size, height: size)
            .anchorPreference(key: WelcomeAvatarBoundsKey.self, value: .bounds) { $0 }
            .accessibilityHidden(true)
    }

    private var welcomeHeader: some View {
        HStack(spacing: 12) {
            PhoneBrandIcon(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                PhoneBrandWordmark()
                Text("Personal Agent").phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }
            Spacer(minLength: 8)
            if step != .ready {
                if closePreview == nil {
                    Text("未来演示").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                        .accessibilityIdentifier("welcome.illustrative")
                }
                Button("跳过") { step = .ready }
                    .phoneText(.metadata).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("welcome.skip")
            }
            if let closePreview {
                Button(action: closePreview) {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("关闭引导预览")
                .accessibilityIdentifier("welcome.preview.close")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private var listeningScene: some View {
        VStack(spacing: 18) {
            moment(scenario.moments[0], source: scenario.sources[0])
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaleEffect(step == .gathering && !reduceMotion ? 0.12 : 1, anchor: .bottom)
                .rotationEffect(.degrees(step == .gathering && !reduceMotion ? 8 : 0))
                .offset(y: step == .gathering && !reduceMotion ? largeAvatarSize / 2 + 18 : 0)
                .opacity(step == .gathering ? 0 : 1)
                .accessibilityHidden(step == .gathering)
            avatarSlot(size: largeAvatarSize)
                .background {
                    Circle().stroke(MoMoPalette.ink.opacity(0.12), lineWidth: 1)
                        .scaleEffect(step == .gathering && !reduceMotion ? 1.5 : 0.8)
                        .opacity(step == .listening ? 1 : 0)
                        .accessibilityHidden(true)
                }
            moment(scenario.moments[1], source: scenario.sources[1])
                .frame(maxWidth: .infinity, alignment: .trailing)
                .scaleEffect(step == .gathering && !reduceMotion ? 0.12 : 1, anchor: .top)
                .rotationEffect(.degrees(step == .gathering && !reduceMotion ? -8 : 0))
                .offset(x: step == .firstMoment && !reduceMotion ? 48 : 0,
                        y: step == .gathering && !reduceMotion ? -largeAvatarSize / 2 - 18 : 0)
                .opacity(step == .listening ? 1 : 0)
                .accessibilityHidden(step != .listening)
            Text(scenario.title)
                .font(.system(.title2, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .accessibilityIdentifier("welcome.title")
        }
    }

    private func moment(_ text: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).phoneText(.body).fixedSize(horizontal: false, vertical: true)
            Label(source, systemImage: "waveform")
                .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
        }
        .padding(16)
        .background(MoMoPalette.surface, in: .rect(cornerRadius: 20))
        .frame(maxWidth: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var conversationScene: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(scenario.request)
                .phoneText(.body).padding(16)
                .background(MoMoPalette.surface, in: .rect(cornerRadius: 20))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("welcome.request")
            HStack(alignment: .top, spacing: 10) {
                avatarSlot(size: 72)
                ZStack(alignment: .topLeading) {
                    if !showsReply {
                        HStack(spacing: 6) {
                            ForEach(0..<3) { _ in Circle().frame(width: 5, height: 5) }
                        }
                        .foregroundStyle(MoMoPalette.muted).padding(.top, 25)
                        .accessibilityLabel("私人助手正在回应")
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        Text(scenario.reply).phoneText(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("welcome.reply")
                            .opacity(showsReply ? 1 : 0)
                            .offset(y: showsReply || reduceMotion ? 0 : 18)
                            .accessibilityHidden(!showsReply)
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: scenario.symbol).foregroundStyle(MoMoPalette.muted)
                                .accessibilityHidden(true)
                            Text(scenario.result).font(.system(.title3, weight: .medium))
                                .accessibilityIdentifier("welcome.result.\(scenario.id)")
                            Text(scenario.detail).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(MoMoPalette.surface, in: .rect(cornerRadius: 20))
                        .scaleEffect(showsResult || reduceMotion ? 1 : 0.75, anchor: .topLeading)
                        .offset(y: showsResult || reduceMotion ? 0 : 32)
                        .opacity(showsResult ? 1 : 0)
                        .accessibilityHidden(!showsResult)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var readyScene: some View {
        VStack(spacing: 22) {
            avatarSlot(size: 104)
            Text("让生活成为你的上下文")
                .font(.system(.title2, weight: .medium))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome.ready")
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if step == .ready {
                Button(action: finish) {
                    Text(LocalizedStringKey(finishTitle)).phoneText(.body)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(MoMoPalette.canvas)
                        .background(MoMoPalette.ink, in: Capsule())
                }
                .accessibilityIdentifier("welcome.start")
            } else {
                Group {
                    if scenePhase == .active && !voiceOver {
                        ProgressView(timerInterval: playbackStartedAt...playbackStartedAt.addingTimeInterval(totalDuration),
                                     countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    } else {
                        ProgressView(value: elapsed, total: totalDuration)
                    }
                }
                .tint(MoMoPalette.ink.opacity(0.55))
                .frame(maxWidth: 160)
                .frame(height: 52)
                .accessibilityHidden(true)
            }
        }
    }

    private func advance() {
        guard step != .ready else { return }
        let nextStep: WelcomeStep = step == .leaving
            ? (scenarioIndex + 1 < WelcomeScenario.examples.count ? .firstMoment : .ready)
            : WelcomeStep(rawValue: step.rawValue + 1) ?? .ready
        // Finish each transition before the next beat starts, including the shorter scene exits.
        let transitionDuration = nextStep == .ready ? 0.24 : min(0.24, nextStep.duration)
        withAnimation(reduceMotion ? .easeOut(duration: transitionDuration)
                      : .spring(duration: transitionDuration, bounce: 0.08)) {
            if step == .leaving {
                if scenarioIndex + 1 < WelcomeScenario.examples.count {
                    scenarioIndex += 1
                }
            }
            step = nextStep
        }
    }

    private func advanceForVoiceOver() {
        // VoiceOver reads at the user's pace; decorative collection and exit beats need no separate action.
        if step == .listening { step = .gathering }
        if step == .result { step = .leaving }
        advance()
    }
}

private nonisolated struct WelcomeAvatarBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
