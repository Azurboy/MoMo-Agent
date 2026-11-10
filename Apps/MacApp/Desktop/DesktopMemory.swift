import SwiftUI
import WebKit
import MoMoAgentClient

struct DesktopMemory: View {
    @Bindable var model: DesktopModel
    @State private var listMode = true
    @State private var selectedCategory: DreamMemoryCategory? = nil
    @State private var selectedMemoryID: String? = nil
    @State private var inspecting: ContextMemory?
    @State private var webFailure: String?
    @State private var dreamRequesting = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorScheme) private var scheme

    private var allMemories: [ContextMemory] { model.memories.filter { $0.status != "forgotten" } }

    private var activeCategory: DreamMemoryCategory {
        if let selectedCategory {
            return selectedCategory
        }
        return DreamMemoryCategory.preferredInitialCategory(for: allMemories)
    }

    private var visibleCategories: [DreamMemoryCategory] {
        let nonEmpty = DreamMemoryCategory.allCases.filter { cat in
            cat == .all || allMemories.contains(where: { cat.matches($0) })
        }
        return nonEmpty.isEmpty ? DreamMemoryCategory.allCases : nonEmpty
    }

    private var memories: [ContextMemory] { allMemories.filter { activeCategory.matches($0) } }
    private var sections: [DreamMemorySection] { DreamMemoryCategory.sections(from: allMemories, category: activeCategory) }

    private var currentReaderItems: [ContextMemory] {
        sections.flatMap(\.items)
    }

    private var activeReaderMemory: ContextMemory? {
        let items = currentReaderItems
        guard !items.isEmpty else { return nil }
        if let selectedMemoryID, let matched = items.first(where: { $0.id == selectedMemoryID }) {
            return matched
        }
        return items.first
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("记忆").font(.system(size: 22, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("立即 Dream 整理", systemImage: "sparkles") {
                    dreamRequesting = true
                    Task {
                        defer { dreamRequesting = false }
                        try? await model.triggerDream()
                    }
                }
                .frame(width: 28, height: 28)
                .help("立即执行 Dream 闲时深度整理")
                .accessibilityIdentifier("settings.memory.dream")
                .disabled(model.contextLoading || dreamRequesting || model.memoryReviewStatus?.running == true)
                Button(listMode ? "星图" : "列表", systemImage: listMode ? "circle.hexagongrid" : "list.bullet") { listMode.toggle() }
                    .frame(width: 28, height: 28).accessibilityIdentifier("settings.memory.view")
                    .disabled(reducedMotion).help(reducedMotion ? "减少动态效果时使用列表" : "切换记忆视图")
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.loadContext() } }.frame(width: 28, height: 28).help("刷新记忆").accessibilityIdentifier("settings.memory.refresh").disabled(model.contextLoading)
            }
            .buttonStyle(.plain).labelStyle(.iconOnly).padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)

            if !allMemories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(visibleCategories) { category in
                            let isSelected = activeCategory == category
                            Button {
                                selectedCategory = category
                                selectedMemoryID = nil
                                if category != .all { listMode = true }
                            } label: {
                                MemoryBinderTab(category: category, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("remote.memoryCategory.\(category.rawValue)")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            }
            if let error = model.memoryError ?? webFailure {
                HStack { Text(error).phoneText(.caption); Spacer(); Button("重试") { webFailure = nil; Task { await model.loadContext() } } }
                    .foregroundStyle(MoMoPalette.failure).padding(16)
            }
            if model.contextLoading && allMemories.isEmpty { ProgressView("正在读取记忆").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if memories.isEmpty {
                ContentUnavailableView(allMemories.isEmpty ? "还没有记忆" : "暂无笔记", systemImage: "book.closed", description: Text("轻触右上角即可整理或刷新。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listMode || reducedMotion || webFailure != nil || activeCategory != .all {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if activeCategory.isNotebookReaderCategory, let memory = activeReaderMemory {
                            MemoryBinderPageSwitcher(
                                items: currentReaderItems,
                                selectedID: memory.id,
                                onSelect: { selectedMemoryID = $0.id }
                            )
                            ClientMemoryContent(memory: memory)
                                .textSelection(.enabled)
                                .environment(\.openURL, OpenURLAction { url in
                                    if let next = DreamMemoryLinkResolver.resolve(url: url, in: allMemories) {
                                        selectedCategory = DreamMemoryCategory.category(for: next)
                                        selectedMemoryID = next.id
                                        return .handled
                                    }
                                    return .systemAction
                                })
                        } else {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(sections) { section in
                                    VStack(alignment: .leading, spacing: 8) {
                                        if sections.count > 1 {
                                            HStack(spacing: 6) {
                                                Text(section.title)
                                                    .momoHandwriting(size: 17, weight: .semibold, relativeTo: .headline)
                                                    .foregroundStyle(colors.ink)
                                                    .accessibilityAddTraits(.isHeader)
                                                Text("\(section.items.count)")
                                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                                    .foregroundStyle(colors.secondaryInk)
                                            }
                                            .padding(.top, 2)
                                        }
                                        ForEach(section.items) { memory in
                                            Button { inspecting = memory } label: {
                                                MemoryCardView(memory: memory)
                                            }.buttonStyle(.plain)
                                                .accessibilityIdentifier("remote.memoryRow." + memory.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            } else {
                MoMoMemoryGraphView(memories: memories, inspect: { id in inspecting = memories.first { $0.id == id } }, failure: { webFailure = $0 })
            }
        }
        .background(colors.desk)
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
    @State var memory: ContextMemory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var confirming = false
    @State private var forgetting = false
    @State private var error: String?
    @State private var source: ContextSource?
    @State private var contentHeight: CGFloat = 120
    var body: some View {
        let base = content.environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: model.memories) {
                memory = next
                return .handled
            }
            return .systemAction
        })
        if #available(macOS 15, *) {
            base.presentationSizing(.fitted)
        } else {
            base
        }
    }

    private var siblingMemories: [ContextMemory] {
        let active = model.memories.filter { $0.status != "forgotten" && $0.kind == memory.kind }
        return DreamMemoryCategory.sortMemories(active)
    }

    private var content: some View {
        let digest = MemoryCardDigest.cached(for: memory)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(digest.title)
                    .momoHandwriting(size: 19, weight: .semibold, relativeTo: .title3)
                    .foregroundStyle(MemoryNotebookPalette(scheme: scheme).ink)
                    .lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.plain).foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk)
            }
            if ["project", "briefing", "topic", "person", "journal"].contains(memory.kind) {
                MemoryBinderPageSwitcher(
                    items: siblingMemories,
                    selectedID: memory.id,
                    onSelect: { memory = $0 }
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ClientMemoryContent(memory: memory).textSelection(.enabled)
                    ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                        if let recording = model.sources.first(where: { $0.id == evidence.sourceId && $0.revision == evidence.sourceRevision }) {
                            Button("查看录音原文", systemImage: "text.alignleft") { source = recording }
                        } else {
                            Text("来源已变更或不可用，原引用保留。").phoneText(.caption).foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }.frame(height: min(contentHeight, 440))
            if let error { Text(error).foregroundStyle(MoMoPalette.failure) }
            HStack {
                Spacer()
                Button("忘记", role: .destructive) { confirming = true }.buttonStyle(.plain).foregroundStyle(MoMoPalette.failure).disabled(forgetting)
            }
        }.padding(20).frame(width: 540).fixedSize(horizontal: false, vertical: true)
        .background(MemoryNotebookPalette(scheme: scheme).desk)
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
                Button("完成") { self.source = nil }.buttonStyle(.plain).foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk).padding()
            }.frame(width: 600, height: 520)
        }
    }
}

/// A local-only build of the vendored StarMap memory graph. No server credential enters WebKit.
private struct MoMoMemoryGraphView: NSViewRepresentable {
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
        if let file = Bundle.main.url(forResource: "index", withExtension: "index.html".hasSuffix(".html") ? "html" : "html", subdirectory: "MemoryWeb") {
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
