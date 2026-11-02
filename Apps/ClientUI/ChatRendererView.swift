import SwiftUI
import WebKit
import OSLog
import MoMoContracts

/// Offline presentation surface. It cannot execute agent tools or access provider configuration.
struct ChatRendererView: View {
    let snapshot: ChatRenderSnapshot
    var scrollToBottomRequest = 0
    var headerInset: CGFloat = 0
    var onRegenerate: (String) -> Void = { _ in }
    var onReadingPosition: (ChatReadingPosition) -> Void = { _ in }
    var onSystemAction: (UUID) -> Void = { _ in }
    var onAttachment: (UUID) -> Void = { _ in }
    var onRetryMessage: (UUID) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var fontSize = Double(PhoneTextStyle.body.size)
    @State private var renderingFailed = false
    @State private var rendererReady = false
    @State private var nativeFocusedRequest: String?

    var body: some View {
        VStack(spacing: 0) {
            if renderingFailed {
                Text("消息暂以文字显示")
                    .phoneText(.metadata).foregroundStyle(.secondary)
                    .padding(.top, headerInset)
                    .accessibilityIdentifier("assistant.renderingFailure")
                Button("重新加载消息") { rendererReady = false; renderingFailed = false }
                    .accessibilityIdentifier("assistant.reloadRendering")
                plainTranscript
            } else {
                ZStack(alignment: .top) {
                    ChatWebSurface(snapshot: snapshot, scrollToBottomRequest: scrollToBottomRequest, dark: colorScheme == .dark,
                        reduceMotion: reduceMotion, scale: fontSize / 16, headerInset: headerInset, active: scenePhase == .active,
                        failed: { renderingFailed = true }, rendered: { rendererReady = true },
                        recovering: { rendererReady = false },
                        open: { openURL($0) }, regenerate: onRegenerate,
                        readingPosition: onReadingPosition, systemAction: onSystemAction, attachment: onAttachment, retryMessage: onRetryMessage)
                        .opacity(rendererReady ? 1 : 0)
                        .accessibilityHidden(!rendererReady)
                        .accessibilityIdentifier("assistant.transcript")
                    if !rendererReady { plainTranscript }
                }
            }
        }
        .background(MoMoPalette.canvas)
        .phoneSoftTopEdge()
        .onChange(of: snapshot.sessionID) { renderingFailed = false }
        .onChange(of: scenePhase) {
            if scenePhase == .active, renderingFailed { rendererReady = false; renderingFailed = false }
        }
    }

    private func typingOpacity(at date: Date, index: Int) -> Double {
        let phase = (date.timeIntervalSinceReferenceDate - Double(index) * 0.25).truncatingRemainder(dividingBy: 1)
        let distance = min(phase, 1 - phase)
        return 0.2 + 0.05 * (1 + cos(.pi * min(distance / 0.37, 1)))
    }

    // First send paints natively while WebKit starts; no network or rich renderer admission is required.
    private var plainTranscript: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(snapshot.messages, id: \.id) { message in
                        let body = message.blocks.filter { $0.type == "text" }.compactMap(\.text).joined()
                        let text = body.isEmpty ? message.blocks.filter { $0.type == "attachment" }.compactMap(\.name).joined(separator: "\n") : body
                        if !text.isEmpty {
                            if message.role == "user" {
                                HStack(alignment: .center, spacing: 8) {
                                    Spacer(minLength: 0)
                                    Text(text).phoneText(.body).textSelection(.enabled)
                                        .foregroundStyle(MoMoPalette.canvas)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 16).padding(.vertical, 10)
                                        .background(MoMoPalette.ink, in: .rect(cornerRadius: 22))
                                        .frame(maxWidth: max(0, geometry.size.width - 40) * 0.85, alignment: .trailing)
                                    if message.delivery == "failed", let id = UUID(uuidString: message.turnID) {
                                        Button { onRetryMessage(id) } label: {
                                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(MoMoPalette.failure)
                                                .frame(width: 28, height: 44)
                                        }.buttonStyle(.plain).accessibilityLabel("发送失败，点击重试")
                                    }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    let delivered = snapshot.deliveryReceiptMessageID == message.id
                                    Text(message.delivery == "read" ? "已读" : "已送达", bundle: AppLanguage.resourceBundle)
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                        .frame(height: 16).offset(y: 18)
                                        .opacity(delivered ? 1 : 0).accessibilityHidden(!delivered)
                                        .allowsHitTesting(false)
                                        .contentTransition(.identity)
                                        .animation(reduceMotion ? nil : .timingCurve(0.19, 1, 0.22, 1, duration: 0.3), value: delivered)
                                }
                                .padding(.trailing, -8).padding(.bottom, 2)
                            } else if message.role == "system" {
                                Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                                    .padding(.leading, 10).padding(.vertical, 4)
                            } else {
                                Text(text).phoneText(.body).textSelection(.enabled)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(MoMoPalette.surface, in: .rect(cornerRadius: 22))
                                    .frame(maxWidth: max(0, geometry.size.width - 40) * 0.85, alignment: .leading)
                            }
                        }
                    }
                    let waiting = snapshot.waitingForReply ?? (snapshot.busy && snapshot.messages.last?.role == "user")
                    let reserveReply = !snapshot.stopped && snapshot.messages.last?.role == "user" && snapshot.messages.last?.delivery != "failed"
                    if waiting || reserveReply {
                        TimelineView(.animation(minimumInterval: 0.1, paused: !waiting || reduceMotion || scenePhase != .active)) { clock in
                            HStack(spacing: 4) {
                                ForEach(0..<3) { index in
                                    Circle().fill(MoMoPalette.ink)
                                        .opacity(reduceMotion ? 0.3 : typingOpacity(at: clock.date, index: index))
                                        .frame(width: 8, height: 8)
                                }
                            }.frame(width: 56, height: 40).background(MoMoPalette.surface, in: Capsule())
                        }
                        .frame(height: 44, alignment: .topLeading)
                        .opacity(waiting ? 1 : 0).accessibilityHidden(!waiting)
                        .accessibilityElement(children: .ignore).accessibilityLabel("助理正在回复")
                    }
                    Color.clear.frame(height: 1).id("composer-bottom")
                }.padding(.horizontal, 24).padding(.top, 20)
                #if os(macOS)
                .padding(.top, renderingFailed ? 0 : headerInset)
                #endif
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            #if os(iOS)
            .safeAreaPadding(.top, renderingFailed ? 0 : headerInset)
            .scrollDismissesKeyboard(.interactively)
            #endif
            #if os(macOS)
            .overlay(alignment: .top) {
                if !renderingFailed {
                    LinearGradient(colors: [MoMoPalette.canvas, MoMoPalette.canvas.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: headerInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            #endif
            .accessibilityIdentifier("assistant.nativeTranscript")
            .onChange(of: scrollToBottomRequest) { reader.scrollTo("composer-bottom", anchor: .bottom) }
            .onChange(of: snapshot.focus, initial: true) { _, _ in focusNativeMessage(reader) }
            .onChange(of: snapshot.messages.count) { _, _ in focusNativeMessage(reader) }
            }
        }
    }

    private func focusNativeMessage(_ reader: ScrollViewProxy) {
        guard let focus = snapshot.focus, focus.requestID != nativeFocusedRequest,
              snapshot.messages.contains(where: { $0.id == focus.messageID }) else { return }
        reader.scrollTo(focus.messageID, anchor: .top)
        nativeFocusedRequest = focus.requestID
    }
}

#if os(macOS)
private typealias ChatWebRepresentable = NSViewRepresentable
#else
private typealias ChatWebRepresentable = UIViewRepresentable
#endif

private struct ChatWebSurface: ChatWebRepresentable {
    let snapshot: ChatRenderSnapshot
    let scrollToBottomRequest: Int
    let dark: Bool
    let reduceMotion: Bool
    let scale: Double
    let headerInset: CGFloat
    let active: Bool
    let failed: () -> Void
    let rendered: () -> Void
    let recovering: () -> Void
    let open: (URL) -> Void
    let regenerate: (String) -> Void
    let readingPosition: (ChatReadingPosition) -> Void
    let systemAction: (UUID) -> Void
    let attachment: (UUID) -> Void
    let retryMessage: (UUID) -> Void

    func makeCoordinator() -> ChatWebCoordinator {
        let coordinator = ChatWebCoordinator(failed: failed, open: open, regenerate: regenerate, readingPosition: readingPosition, systemAction: systemAction)
        coordinator.rendered = rendered
        coordinator.recovering = recovering
        coordinator.setActive(active)
        coordinator.attachment = attachment
        coordinator.retryMessage = retryMessage
        return coordinator
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) { updateWebView(web, context: context) }
    static func dismantleNSView(_ web: WKWebView, coordinator: ChatWebCoordinator) { dismantleWebView(web, coordinator: coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) { updateWebView(web, context: context) }
    static func dismantleUIView(_ web: WKWebView, coordinator: ChatWebCoordinator) { dismantleWebView(web, coordinator: coordinator) }
    #endif
    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "chat")
        let web = WKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        web.isOpaque = false
        if #available(iOS 26, *) {
            web.scrollView.contentInsetAdjustmentBehavior = .always
            web.scrollView.topEdgeEffect.style = .soft
        } else {
            web.scrollView.contentInsetAdjustmentBehavior = .never
        }
        web.scrollView.keyboardDismissMode = .interactive
        web.scrollView.alwaysBounceVertical = true
        let dismissKeyboard = UIPanGestureRecognizer(target: context.coordinator, action: #selector(ChatWebCoordinator.dismissKeyboardOnDrag(_:)))
        dismissKeyboard.delegate = context.coordinator
        dismissKeyboard.cancelsTouchesInView = false
        web.addGestureRecognizer(dismissKeyboard)
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        configureBackground(web)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            context.coordinator.resourceDirectory = url.deletingLastPathComponent()
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            Task { @MainActor in failed() }
        }
        return web
    }

    private func updateWebView(_ web: WKWebView, context: Context) {
        configureBackground(web)
        context.coordinator.failed = failed
        context.coordinator.rendered = rendered
        context.coordinator.recovering = recovering
        context.coordinator.open = open
        context.coordinator.regenerate = regenerate
        context.coordinator.readingPosition = readingPosition
        context.coordinator.systemAction = systemAction
        context.coordinator.attachment = attachment
        context.coordinator.retryMessage = retryMessage
        context.coordinator.setActive(active)
        context.coordinator.update(.init(snapshot: snapshot, appearance: .init(dark: dark, reduceMotion: reduceMotion, scale: scale, headerInset: headerInset)), scrollRequest: scrollToBottomRequest)
    }

    private func configureBackground(_ web: WKWebView) {
        // WebKit's first document paint precedes the bridge payload. Match the native canvas
        // immediately, including the overscroll area and prefers-color-scheme evaluation.
        #if os(iOS)
        web.overrideUserInterfaceStyle = dark ? .dark : .light
        let canvas = UIColor(white: dark ? 22 / 255.0 : 250 / 255.0, alpha: 1)
        web.backgroundColor = canvas
        web.scrollView.backgroundColor = canvas
        web.underPageBackgroundColor = canvas
        #else
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        web.underPageBackgroundColor = NSColor(white: dark ? 22 / 255.0 : 250 / 255.0, alpha: 1)
        #endif
    }

    private static func dismantleWebView(_ web: WKWebView, coordinator: ChatWebCoordinator) {
        coordinator.webView = nil
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
        web.stopLoading()
    }
}

#if os(iOS)
extension ChatWebCoordinator: UIGestureRecognizerDelegate {
    @objc func dismissKeyboardOnDrag(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: webView)
        if delta.y > 12, delta.y > abs(delta.x) { webView?.window?.endEditing(true) }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: webView)
        return velocity.y > 0 && velocity.y > abs(velocity.x)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#endif

struct ChatRenderPayload: Encodable, Equatable {
    struct Appearance: Encodable, Equatable {
        let dark: Bool
        let reduceMotion: Bool
        let scale: Double
        var headerInset: CGFloat = 0
        #if os(macOS)
        let desktopHeader = true
        #endif
    }
    let snapshot: ChatRenderSnapshot
    let appearance: Appearance

    func encode(to encoder: any Encoder) throws {
        try snapshot.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(appearance, forKey: .appearance)
    }
    private enum Keys: String, CodingKey { case appearance }
}

@MainActor
final class ChatWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var webView: WKWebView?
    var resourceDirectory: URL?
    var failed: () -> Void
    var open: (URL) -> Void
    var regenerate: (String) -> Void
    var readingPosition: (ChatReadingPosition) -> Void
    var systemAction: (UUID) -> Void
    var attachment: (UUID) -> Void = { _ in }
    var retryMessage: (UUID) -> Void = { _ in }
    var rendered: () -> Void = {}
    var recovering: () -> Void = {}
    private var active = true
    private var needsReload = false
    private var reloads = 0
    private var documentID = UUID()
    private var recoveryNavigation: WKNavigation?
    private let logger = Logger(subsystem: "com.momoagent.chat", category: "renderer")
    private var didRender = false
    private var ready = false
    private var pending: ChatRenderPayload?
    private var sent: ChatRenderPayload?
    private var sending = false
    private var pendingScroll = 0
    private var sentScroll = 0
    private var lastFlushTime: ContinuousClock.Instant?
    private var coalescedFlushTask: Task<Void, Never>?

    init(failed: @escaping () -> Void, open: @escaping (URL) -> Void, regenerate: @escaping (String) -> Void = { _ in },
         readingPosition: @escaping (ChatReadingPosition) -> Void = { _ in }, systemAction: @escaping (UUID) -> Void = { _ in }) {
        self.failed = failed; self.open = open; self.regenerate = regenerate
        self.readingPosition = readingPosition
        self.systemAction = systemAction
    }

    func update(_ payload: ChatRenderPayload, scrollRequest: Int = 0) {
        pending = payload; pendingScroll = scrollRequest
        scheduleFlush()
    }

    func setActive(_ value: Bool) {
        let resumed = value && !active
        active = value
        if !value {
            coalescedFlushTask?.cancel(); coalescedFlushTask = nil
        }
        if resumed {
            reloads = 0
            if needsReload { reloadDocument() } else { flush() }
        }
    }

    private func recover(from error: Error) {
        guard webView != nil else { return }
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue { return }
        logger.error("Render interruption: domain=\(error.domain, privacy: .public) code=\(error.code) active=\(self.active)")
        coalescedFlushTask?.cancel(); coalescedFlushTask = nil
        documentID = UUID(); ready = false; sending = false; needsReload = true
        recovering()
        guard active else { return }
        if reloads < 1 { reloadDocument() } else { failed() }
    }

    private func reloadDocument() {
        guard let webView, let resourceDirectory else { failed(); return }
        coalescedFlushTask?.cancel(); coalescedFlushTask = nil
        reloads += 1; needsReload = false; ready = false; sending = false
        documentID = UUID(); sent = nil; sentScroll = 0; didRender = false; lastFlushTime = nil
        recoveryNavigation = webView.loadFileURL(resourceDirectory.appendingPathComponent("index.html"), allowingReadAccessTo: resourceDirectory)
    }

    private func scheduleFlush() {
        guard active, ready, !sending, let payload = pending,
              payload != sent || pendingScroll != sentScroll else { return }
        if let sent,
           pendingScroll == sentScroll,
           payload.appearance == sent.appearance,
           payload.snapshot.sessionID == sent.snapshot.sessionID,
           payload.snapshot.messages.count == sent.snapshot.messages.count,
           payload.snapshot.messages.last?.state == "streaming",
           sent.snapshot.messages.last?.state == "streaming",
           let last = lastFlushTime {
            let elapsed = last.duration(to: .now)
            if elapsed < .milliseconds(16) {
                guard coalescedFlushTask == nil else { return }
                let delay = Duration.milliseconds(16) - elapsed
                coalescedFlushTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard let self else { return }
                    self.coalescedFlushTask = nil
                    self.flush()
                }
                return
            }
        }
        flush()
    }

    private func flush() {
        coalescedFlushTask?.cancel(); coalescedFlushTask = nil
        guard active, ready, !sending, let webView, let payload = pending,
              payload != sent || pendingScroll != sentScroll else { return }
        do {
            let payloadJSON: Any = payload != sent ? String(decoding: try JSONEncoder().encode(payload), as: UTF8.self) : NSNull()
            let scroll = pendingScroll
            let document = documentID
            sending = true
            lastFlushTime = .now
            // Structured arguments keep model text out of executable JavaScript.
            // Rendering updates the DOM synchronously. An opacity-zero WKWebView can suspend
            // animation frames, so waiting for one before revealing it deadlocks first paint.
            let script = "if (payloadJSON) window.MoMoChat.render(JSON.parse(payloadJSON)); if (scrollToBottom) window.MoMoChat.scrollToBottom();"
            webView.callAsyncJavaScript(script, arguments: ["payloadJSON": payloadJSON, "scrollToBottom": scroll != sentScroll],
                in: nil, in: .page, completionHandler: { [weak self] result in
                guard let self, self.webView === webView, document == self.documentID else { return }
                sending = false
                switch result {
                case .success:
                    reloads = 0
                    sent = payload
                    sentScroll = scroll
                    // Do not replace the native first message with a previously sent empty page
                    // or a stale session while the latest payload is still waiting to paint.
                    if !didRender, !payload.snapshot.messages.isEmpty,
                       payload.snapshot.sessionID == pending?.snapshot.sessionID {
                        didRender = true; rendered()
                    }
                    scheduleFlush()
                case .failure(let error): recover(from: error)
                }
            })
        } catch { recover(from: error) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready": ready = true; flush()
        case "retryMessage":
            if let value = body["value"] as? [String: String], let raw = value["turnID"], let id = UUID(uuidString: raw),
               let snapshot = pending?.snapshot, value["sessionID"] == snapshot.sessionID,
               snapshot.messages.contains(where: { $0.role == "user" && $0.turnID == raw && $0.delivery == "failed" }) {
                retryMessage(id)
            }
        case "regenerate":
            if let value = body["value"] as? [String: String] { requestRegeneration(value) }
        case "attachment":
            if let value = body["value"] as? [String: String], let raw = value["attachmentID"], let id = UUID(uuidString: raw),
               let snapshot = pending?.snapshot, value["sessionID"] == snapshot.sessionID,
               snapshot.messages.flatMap(\.blocks).contains(where: { $0.type == "attachment" && $0.attachmentID == raw }) {
                attachment(id)
            }
        case "systemAction":
            if let value = body["value"] as? [String: String], let raw = value["actionID"], let id = UUID(uuidString: raw),
               let snapshot = pending?.snapshot, value["sessionID"] == snapshot.sessionID,
               snapshot.messages.flatMap(\.blocks).contains(where: { block in
                   guard let output = block.tool?.output, let data = output.data(using: .utf8),
                         let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                   return (receipt["actionID"] as? String).flatMap(UUID.init(uuidString:)) == id
               }) { systemAction(id) }
        case "readingPosition":
            if let value = body["value"] as? [String: Any] { receiveReadingPosition(value) }
        case "copy": if let text = body["value"] as? String {
            #if os(macOS)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
        case "link":
            if let text = body["value"] as? String, let url = URL(string: text) {
                // Source/version authorization is still performed by RecordingSourceLinks.
                switch url.scheme?.lowercased() {
                case "https", "http": if url.host != nil { open(url) }
                case "momoagent": if url.host == "source" { open(url) }
                default: break
                }
            }
        default: break
        }
    }

    func receiveReadingPosition(_ value: [String: Any]) {
        guard let rawID = value["sessionID"] as? String, let id = UUID(uuidString: rawID),
              let snapshot = [pending?.snapshot, sent?.snapshot].compactMap({ $0 }).first(where: { $0.sessionID == rawID }),
              let following = value["following"] as? Bool,
              let top = value["top"] as? Double, let offset = value["anchorOffset"] as? Double else { return }
        let anchorID = value["anchorID"] as? String
        let visibleIDs = Set(snapshot.messages.map { $0.role == "assistant" ? "\($0.id):reply" : $0.id })
        if let anchorID, !visibleIDs.contains(anchorID) { return }
        var position = ChatReadingPosition(sessionID: id, following: following, top: top,
                                           anchorID: anchorID, anchorOffset: offset)
        let shown = value["visibleMessageIDs"] as? [String] ?? []
        let known = Set(snapshot.messages.map(\.id))
        guard shown.count <= 500, shown.allSatisfy({ known.contains($0) }) else { return }
        position.visibleMessageIDs = shown
        guard position.isValid else { return }
        readingPosition(position)
    }

    func requestRegeneration(_ value: [String: String]) {
        guard let snapshot = pending?.snapshot, !snapshot.busy,
              value["sessionID"] == snapshot.sessionID, let id = value["messageID"],
              snapshot.messages.contains(where: { $0.id == id && $0.role == "assistant" && $0.state != "streaming" }) else { return }
        regenerate(id)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let localDocument = url?.isFileURL == true && url?.deletingLastPathComponent() == resourceDirectory
        decisionHandler(localDocument && navigationAction.navigationType == .other ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if let recoveryNavigation, let navigation, navigation !== recoveryNavigation { return }
        recover(from: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if let recoveryNavigation, let navigation, navigation !== recoveryNavigation { return }
        recover(from: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { recover(from: WKError(.webContentProcessTerminated)) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let recoveryNavigation, let navigation, navigation !== recoveryNavigation { return }
        let document = documentID
        webView.evaluateJavaScript("typeof window.MoMoChat === 'object'", completionHandler: { [weak self] value, error in
            guard let self, self.webView === webView, self.documentID == document else { return }
            if error != nil || value as? Bool != true { recover(from: error ?? WKError(.javaScriptExceptionOccurred)) }
        })
    }
}
