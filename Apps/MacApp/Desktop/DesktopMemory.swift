import SwiftUI
import WebKit
import MoMoAgentClient

struct DesktopMemory: View {
    @Bindable var model: DesktopModel
    @State private var listMode = false
    @State private var inspecting: ContextMemory?
    @State private var webFailure: String?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private var memories: [ContextMemory] { model.memories.filter { $0.status != "forgotten" } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("记忆").font(.system(size: 22, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(listMode ? "星图" : "列表", systemImage: listMode ? "circle.hexagongrid" : "list.bullet") { listMode.toggle() }
                    .frame(width: 28, height: 28).accessibilityIdentifier("settings.memory.view")
                    .disabled(reducedMotion).help(reducedMotion ? "减少动态效果时使用列表" : "切换记忆视图")
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.loadContext() } }.frame(width: 28, height: 28).help("刷新记忆").accessibilityIdentifier("settings.memory.refresh").disabled(model.contextLoading)
            }
            .buttonStyle(.plain).labelStyle(.iconOnly).padding(20)
            if let review = model.memoryReviewStatus {
                HStack(spacing: 12) {
                    Label(review.running ? "正在整理记忆" : "自动整理已开启", systemImage: review.running ? "sparkles" : "checkmark.circle")
                    Spacer(minLength: 8)
                    if review.needsReview + model.transcriptMemoryNeedsReview > 0 {
                        Text("部分整理未完成").foregroundStyle(MoMoPalette.failure)
                    } else if let dream = review.dream {
                        Text("Dream · \(Date(timeIntervalSince1970: dream.at).formatted(date: .abbreviated, time: .shortened))")
                    } else { Text("Dream 将在空闲时整理") }
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 16)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("settings.memory.status")
            }
            if let error = model.memoryError ?? webFailure {
                HStack { Text(error).phoneText(.caption); Spacer(); Button("重试") { webFailure = nil; Task { await model.loadContext() } } }
                    .foregroundStyle(MoMoPalette.failure).padding(16)
            }
            if model.contextLoading && memories.isEmpty { ProgressView("正在读取记忆").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if memories.isEmpty {
                ContentUnavailableView("还没有记忆", systemImage: "book.closed", description: Text("MoMo 记住的内容会出现在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listMode || reducedMotion || webFailure != nil {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(memories) { memory in
                            Button { inspecting = memory } label: {
                                HStack(spacing: 16) {
                                    ClientMemoryContent(memory: memory).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                                }.desktopSettingsRow().contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 24)
                }
            } else {
                HermesMemoryView(memories: memories, inspect: { id in inspecting = memories.first { $0.id == id } }, failure: { webFailure = $0 })
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            await model.loadContext()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await model.loadContext()
            }
        }
        .sheet(item: $inspecting) { memory in DesktopMemoryDetail(model: model, memory: memory) }
    }
}

private struct DesktopMemoryDetail: View {
    let model: DesktopModel
    let memory: ContextMemory
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var forgetting = false
    @State private var error: String?
    @State private var source: ContextSource?
    @State private var contentHeight: CGFloat = 120
    var body: some View {
        if #available(macOS 15, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("记忆").font(.system(size: 22, weight: .medium)); Spacer(); Button("完成") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ClientMemoryContent(memory: memory).textSelection(.enabled)
                    ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                        if let recording = model.sources.first(where: { $0.id == evidence.sourceId && $0.revision == evidence.sourceRevision }) {
                            Button("查看录音原文", systemImage: "text.alignleft") { source = recording }
                        } else {
                            Text("来源已变更或不可用，原引用保留。").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }.frame(height: min(contentHeight, 360))
            if let error { Text(error).foregroundStyle(MoMoPalette.failure) }
            HStack {
                Spacer()
                Button("忘记", role: .destructive) { confirming = true }.buttonStyle(.plain).foregroundStyle(MoMoPalette.failure).disabled(forgetting)
            }
        }.padding(24).frame(width: 580).fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("忘记这条记忆？", isPresented: $confirming, titleVisibility: .visible) {
            Button("忘记", role: .destructive) {
                forgetting = true
                Task {
                    defer { forgetting = false }
                    do { try await model.forgetMemory(memory); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
        }
        message: { Text("原始录音和聊天记录仍保留。") }
        .sheet(item: $source) { source in
            VStack {
                DesktopSourceReader(model: model, source: source, onDiscuss: { self.source = nil; dismiss() })
                Button("完成") { self.source = nil }.buttonStyle(.plain).foregroundStyle(.secondary).padding()
            }.frame(width: 640, height: 600)
        }
    }
}

/// A local-only build of the vendored Hermes StarMap. No server credential enters WebKit.
private struct HermesMemoryView: NSViewRepresentable {
    let memories: [ContextMemory]
    let inspect: (String) -> Void
    let failure: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "memory")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        if let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "MemoryWeb") {
            context.coordinator.directory = file.deletingLastPathComponent()
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else { DispatchQueue.main.async { failure(String(localized: "记忆界面资源未找到，已切换为列表。")) } }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.inspect = inspect; context.coordinator.failure = failure
        do {
            let data = try JSONEncoder().encode(memories)
            guard let json = String(data: data, encoding: .utf8) else { return }
            context.coordinator.json = json; context.coordinator.dark = colorScheme == .dark
            context.coordinator.push()
        } catch { DispatchQueue.main.async { failure(error.localizedDescription) } }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "memory")
        coordinator.view = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view: WKWebView?
        var directory: URL?
        var json = "[]"
        var dark = false
        var loaded = false
        var lastSent = ""
        var inspect: ((String) -> Void)?
        var failure: ((String) -> Void)?
        func push() {
            let fingerprint = json + String(dark)
            guard loaded, lastSent != fingerprint, let view else { return }
            lastSent = fingerprint
            let payload = json, dark = dark
            Task { [weak self] in
                do { _ = try await view.callAsyncJavaScript("window.setMemories(JSON.parse(payload), dark)", arguments: ["payload": payload, "dark": dark], in: nil, contentWorld: .page) }
                catch { self?.failure?(String(localized: "星图加载失败，已切换为列表。")) }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
            if body["action"] == "ready" { loaded = true; push() }
            else if body["action"] == "inspect", let id = body["id"] { inspect?(id) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = navigationAction.request.url.map { $0.isFileURL && $0.deletingLastPathComponent() == directory } ?? false
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure?(String(localized: "星图加载失败，已切换为列表。")) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure?(String(localized: "星图加载失败，已切换为列表。")) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure?(String(localized: "星图进程已退出，已切换为列表。")) }
    }
}
