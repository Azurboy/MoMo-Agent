import SwiftUI
import WebKit

/// Original product artwork; never replace it with a waveform or a font glyph.
struct PhoneBrandIcon: View {
    var size: CGFloat = 22

    var body: some View {
        Image("PhoneBrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Approved Pebble lettering; native text supplies layout, Dynamic Type and VoiceOver semantics.
struct PhoneBrandWordmark: View {
    enum Name: String {
        case momoAgent = "MoMo Agent"
        case momo = "MoMo"

        var asset: String { self == .momoAgent ? "PhoneWordmark" : "MoMoWordmark" }
    }

    let name: Name
    @ScaledMetric private var size: CGFloat

    init(_ name: Name = .momoAgent, size: CGFloat = 18) {
        self.name = name
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Text(name.rawValue)
            .font(.system(size: size, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.clear)
            .overlay {
                Image(name.asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(MoMoPalette.ink)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

enum PersonalAgentExpression: String, CaseIterable {
    case present, listening, thinking, working, speaking, settled, concerned, greeting
}

/// One live actor keeps its identity as the parent moves it between home and conversation.
struct PersonalAgentSlot: View {
    let size: CGFloat
    let active: Bool
    var playful = false
    var expression: PersonalAgentExpression = .present
    var conversationID: UUID?
    var action: () -> Void = {}
    @State private var greeting = 0
    @State private var visible = false

    var body: some View {
        ZStack {
            // UIKit-backed live content must not be rendered as a Button label snapshot.
            PersonalAgentActor(size: size, active: active && visible, greeting: greeting, playful: playful,
                               expression: expression, conversationID: conversationID)
                .allowsHitTesting(false)
            Button {
                greeting += 1
                action()
            } label: {
                Color.clear.frame(width: size, height: size).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("和 MoMo 打个招呼")
            .accessibilityIdentifier("personalAgent.avatar")
        }
        .frame(width: size, height: size)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

struct PersonalAgentActor: View {
    let size: CGFloat
    let active: Bool
    let greeting: Int
    var playful = false
    var expression: PersonalAgentExpression = .present
    var conversationID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded = PersonalAgentWebSurface.hasWarmView
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        ZStack {
            Image("MoMoStill").renderingMode(.template).resizable().scaledToFit()
                .foregroundStyle(MoMoPalette.ink).frame(width: size, height: size)
                .opacity(loaded ? 0 : 1)
            PersonalAgentWebSurface(dark: colorScheme == .dark, reduceMotion: reduceMotion,
                                    active: active && scenePhase == .active, greeting: greeting,
                                    playful: playful, expression: expression, conversationID: conversationID,
                                    lowPower: lowPower, availability: { loaded = $0 })
                // Extra transparent viewport lets the SVG jump without clipping its ears.
                .frame(width: size * 1.5, height: size * 1.5)
                .opacity(loaded ? 1 : 0)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }
}

#if os(macOS)
private typealias AgentWebRepresentable = NSViewRepresentable

@MainActor private enum WarmAvatarWebPool {
    struct Entry {
        let web: WKWebView
        let resourceURL: URL
        let sent: PersonalAgentWebSurface.Coordinator.Appearance?
    }
    static var entry: Entry?
    static func take() -> Entry? {
        defer { entry = nil }
        return entry
    }
}
#else
private typealias AgentWebRepresentable = UIViewRepresentable
#endif

private struct PersonalAgentWebSurface: AgentWebRepresentable {
    static var hasWarmView: Bool {
        #if os(macOS)
        MainActor.assumeIsolated { WarmAvatarWebPool.entry != nil }
        #else
        false
        #endif
    }

    let dark: Bool
    let reduceMotion: Bool
    let active: Bool
    let greeting: Int
    let playful: Bool
    let expression: PersonalAgentExpression
    let conversationID: UUID?
    let lowPower: Bool
    let availability: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(availability: availability) }
    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) { updateWebView(web, context: context) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { dismantleWebView(web, coordinator: coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) { updateWebView(web, context: context) }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { dismantleWebView(web, coordinator: coordinator) }
    #endif
    private func makeWebView(context: Context) -> WKWebView {
        #if os(macOS)
        let forceUnavailable: Bool = {
            #if DEBUG
            return ProcessInfo.processInfo.environment["MOMO_UI_TEST_AVATAR_UNAVAILABLE"] == "1"
            #else
            return false
            #endif
        }()
        if !forceUnavailable, let warm = WarmAvatarWebPool.take() {
            warm.web.navigationDelegate = context.coordinator
            context.coordinator.adoptWarm(web: warm.web, resourceURL: warm.resourceURL, sent: warm.sent)
            return warm.web
        }
        #endif
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.underPageBackgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.scrollView.isScrollEnabled = false
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.isUserInteractionEnabled = false
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOMO_UI_TEST_AVATAR_UNAVAILABLE"] == "1" { return web }
        #endif
        if let url = Bundle.main.url(forResource: "agent-avatar", withExtension: "html", subdirectory: "Web") {
            context.coordinator.resourceURL = url
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { Task { @MainActor in availability(false) } }
        return web
    }
    private func updateWebView(_ web: WKWebView, context: Context) {
        context.coordinator.availability = availability
        context.coordinator.update(.init(dark: dark, reduceMotion: reduceMotion, active: active, greeting: greeting,
                                         playful: playful, expression: expression, conversationID: conversationID, lowPower: lowPower))
    }
    private static func dismantleWebView(_ web: WKWebView, coordinator: Coordinator) {
        #if os(macOS)
        if WarmAvatarWebPool.entry == nil, let warm = coordinator.detachWarmState(for: web) {
            web.navigationDelegate = nil
            coordinator.invalidate()
            coordinator.web = nil
            WarmAvatarWebPool.entry = warm
            return
        }
        #endif
        web.stopLoading()
        web.navigationDelegate = nil
        coordinator.invalidate()
        coordinator.web = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        struct Appearance: Equatable {
            let dark: Bool
            let reduceMotion: Bool
            let active: Bool
            let greeting: Int
            let playful: Bool
            let expression: PersonalAgentExpression
            let conversationID: UUID?
            let lowPower: Bool
            var arguments: [String: Any] {
                ["dark": dark, "reduceMotion": reduceMotion, "active": active, "greeting": greeting,
                 "playful": playful, "expression": expression.rawValue, "conversationID": conversationID?.uuidString ?? "",
                 "lowPower": lowPower]
            }
        }
        weak var web: WKWebView?
        var resourceURL: URL?
        var availability: (Bool) -> Void
        private var generation = 0
        private var reloadAttempts = 0
        private var ready = false
        private var sending = false
        private var needsReload = false
        private var pending: Appearance?
        private var sent: Appearance?
        init(availability: @escaping (Bool) -> Void) { self.availability = availability }
        func invalidate() { generation += 1; ready = false; sending = false; sent = nil }
        #if os(macOS)
        func adoptWarm(web: WKWebView, resourceURL: URL, sent: Appearance?) {
            self.web = web
            self.resourceURL = resourceURL
            self.ready = true
            self.needsReload = false
            self.sent = sent
            self.availability(true)
        }
        func detachWarmState(for web: WKWebView) -> WarmAvatarWebPool.Entry? {
            guard ready, !needsReload, let resourceURL else { return nil }
            var pausedSent = sent ?? pending
            if let base = pausedSent, base.active {
                let paused = Appearance(
                    dark: base.dark,
                    reduceMotion: base.reduceMotion,
                    active: false,
                    greeting: base.greeting,
                    playful: base.playful,
                    expression: base.expression,
                    conversationID: base.conversationID,
                    lowPower: base.lowPower
                )
                pausedSent = paused
                web.callAsyncJavaScript(
                    "if (window.agentAvatar) window.agentAvatar.update(appearance);",
                    arguments: ["appearance": paused.arguments],
                    in: nil,
                    in: .page,
                    completionHandler: nil
                )
            }
            return WarmAvatarWebPool.Entry(web: web, resourceURL: resourceURL, sent: pausedSent)
        }
        #endif
        private func reloadIfPossible() {
            guard reloadAttempts < 1, let web, let resourceURL else { return }
            reloadAttempts += 1
            needsReload = false
            web.loadFileURL(resourceURL, allowingReadAccessTo: resourceURL.deletingLastPathComponent())
        }
        private func recover() {
            invalidate(); availability(false)
            guard pending?.active != false else {
                needsReload = true
                return
            }
            reloadIfPossible()
        }
        func update(_ appearance: Appearance) {
            let resumed = appearance.active && pending?.active == false
            pending = appearance
            if resumed { reloadAttempts = 0 }
            if needsReload, appearance.active {
                reloadIfPossible()
            } else {
                flush()
            }
        }
        private func flush() {
            guard ready, !sending, let appearance = pending, appearance != sent, let web else { return }
            sending = true
            let generation = generation
            web.callAsyncJavaScript("if (!window.agentAvatar || !document.querySelector('svg.life-avatar path[d]')) throw new Error('Avatar unavailable'); window.agentAvatar.update(appearance); return true", arguments: ["appearance": appearance.arguments],
                                    in: nil, in: .page) { [weak self] result in
                guard let self, self.generation == generation else { return }
                sending = false
                switch result {
                case .success:
                    reloadAttempts = 0
                    sent = appearance
                    availability(true)
                    flush()
                case .failure: recover()
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; flush() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { if (error as NSError).code != NSURLErrorCancelled { recover() } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { if (error as NSError).code != NSURLErrorCancelled { recover() } }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { recover() }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url == resourceURL && action.targetFrame?.isMainFrame == true ? .allow : .cancel
        }
    }
}
