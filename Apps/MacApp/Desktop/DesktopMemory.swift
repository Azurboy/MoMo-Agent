import SwiftUI
import WebKit
import MoMoAgentClient

struct DesktopMemory: View {
    @Bindable var model: DesktopModel
    @State private var listMode = true
    @State private var selectedCategory: DreamMemoryCategory? = nil
    @State private var selectedMemoryID: String? = nil
    @State private var readerBackStack: [(category: DreamMemoryCategory, memoryID: String?)] = []
    @State private var inspecting: ContextMemory?
    @State private var deletingMemory: ContextMemory?
    @State private var expandedFolderIDs: Set<String>? = nil
    @State private var collapsedParentIDs: Set<String> = []
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

    private var directoryFolders: [DreamMemorySection] {
        DreamMemoryCategory.directoryFolders(from: allMemories)
    }

    private var memories: [ContextMemory] { allMemories.filter { activeCategory.matches($0) } }
    private var sections: [DreamMemorySection] {
        activeCategory == .all
            ? directoryFolders
            : DreamMemoryCategory.sections(from: allMemories, category: activeCategory)
    }

    private var currentReaderItems: [ContextMemory] {
        let direct = sections.flatMap(\.items)
        if direct.count > 1 {
            return direct
        }
        let allNotebooks = directoryFolders.filter { $0.id != "core" }.flatMap(\.items)
        return allNotebooks.count > 1 ? allNotebooks : direct
    }

    private var activeReaderMemory: ContextMemory? {
        let items = sections.flatMap(\.items)
        guard !items.isEmpty else { return nil }
        if let selectedMemoryID, let matched = currentReaderItems.first(where: { $0.id == selectedMemoryID }) {
            return matched
        }
        return items.first
    }

    private func isFolderExpanded(_ folderID: String) -> Bool {
        let current = expandedFolderIDs ?? DreamMemoryCategory.defaultExpandedFolderIDs(for: directoryFolders)
        return current.contains(folderID)
    }

    private func toggleFolder(_ folderID: String) {
        var current = expandedFolderIDs ?? DreamMemoryCategory.defaultExpandedFolderIDs(for: directoryFolders)
        if current.contains(folderID) {
            current.remove(folderID)
        } else {
            current.insert(folderID)
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedFolderIDs = current
        }
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
                                readerBackStack.removeAll()
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
                    VStack(alignment: .leading, spacing: 12) {
                        if activeCategory.isNotebookReaderCategory, let memory = activeReaderMemory {
                            if let prev = readerBackStack.last {
                                HStack(spacing: 8) {
                                    Button {
                                        _ = readerBackStack.popLast()
                                        selectedCategory = prev.category
                                        selectedMemoryID = prev.memoryID
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "chevron.left")
                                                .font(.system(size: 10.5, weight: .semibold))
                                            Text(prev.category == .all ? "返回目录" : "返回上一页")
                                                .font(.system(size: 11.5, weight: .medium))
                                        }
                                        .foregroundStyle(colors.ink)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(colors.paper, in: Capsule())
                                        .overlay { Capsule().strokeBorder(colors.secondaryInk.opacity(0.16), lineWidth: 0.5) }
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                }
                            }
                            MemoryBinderPageSwitcher(
                                items: currentReaderItems,
                                selectedID: memory.id,
                                onSelect: { item in
                                    selectedMemoryID = item.id
                                    let targetCat = DreamMemoryCategory.category(for: item)
                                    if targetCat != activeCategory {
                                        selectedCategory = targetCat
                                    }
                                }
                            )
                            ClientMemoryContent(memory: memory, onDelete: { deletingMemory = memory })
                                .textSelection(.enabled)
                                .environment(\.openURL, OpenURLAction { url in
                                    if let next = DreamMemoryLinkResolver.resolve(url: url, in: allMemories) {
                                        readerBackStack.append((category: activeCategory, memoryID: memory.id))
                                        selectedCategory = DreamMemoryCategory.category(for: next)
                                        selectedMemoryID = next.id
                                        return .handled
                                    }
                                    return .systemAction
                                })
                        } else {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(sections) { section in
                                    let expanded = activeCategory != .all || isFolderExpanded(section.id)
                                    VStack(alignment: .leading, spacing: 6) {
                                        if activeCategory == .all && (sections.count > 1 || section.id != "core") {
                                            MemoryDirectoryFolderHeader(
                                                section: section,
                                                isExpanded: expanded,
                                                onToggle: { toggleFolder(section.id) }
                                            )
                                        }
                                        if expanded {
                                            ForEach(section.items) { memory in
                                                desktopDirectoryItemView(memory, colors: colors)
                                            }
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
        .confirmationDialog(
            deletingMemory?.kind == "person" ? "删除该人物档案？" : "忘记这条记忆？",
            isPresented: Binding(get: { deletingMemory != nil }, set: { if !$0 { deletingMemory = nil } }),
            titleVisibility: .visible
        ) {
            if let target = deletingMemory {
                Button(target.kind == "person" ? "删除" : "忘记", role: .destructive) {
                    deletingMemory = nil
                    Task { try? await model.forgetMemory(target) }
                }
            }
        } message: {
            Text(deletingMemory?.kind == "person"
                 ? "删除后 Dream 不会再次自动生成该说话人档案。"
                 : "原始录音和聊天记录仍保留。")
        }
    }

    private func openMemoryFromDirectory(_ memory: ContextMemory) {
        let targetCat = DreamMemoryCategory.category(for: memory)
        if targetCat.isNotebookReaderCategory {
            readerBackStack.append((category: activeCategory, memoryID: selectedMemoryID))
            selectedCategory = targetCat
            selectedMemoryID = memory.id
            listMode = true
        } else {
            inspecting = memory
        }
    }

    @ViewBuilder
    private func desktopDirectoryItemView(_ memory: ContextMemory, colors: MemoryNotebookPalette) -> some View {
        let childMemories = MemoryCardDigest.linkedChildren(for: memory, in: allMemories)
        let digest = MemoryCardDigest.cached(for: memory)
        let isParentExpanded = !collapsedParentIDs.contains(memory.id)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { openMemoryFromDirectory(memory) } label: {
                    MemoryCardView(memory: memory)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("remote.memoryRow." + memory.id)
                .contextMenu {
                    Button(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) {
                        deletingMemory = memory
                    }
                }

                if !childMemories.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if isParentExpanded {
                                collapsedParentIDs.insert(memory.id)
                            } else {
                                collapsedParentIDs.remove(memory.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isParentExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(childMemories.count)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(colors.secondaryInk)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 34)
                        .background(colors.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(colors.secondaryInk.opacity(0.14), lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if memory.kind == "person" {
                    Button(role: .destructive) {
                        deletingMemory = memory
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(colors.margin)
                            .frame(width: 34, height: 34)
                            .background(colors.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(colors.margin.opacity(0.22), lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("删除\(digest.title)")
                }
            }

            if !childMemories.isEmpty && isParentExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(childMemories.enumerated()), id: \.element.id) { idx, child in
                        Button { openMemoryFromDirectory(child) } label: {
                            MemoryDirectoryChildRowLabel(
                                child: child,
                                isLast: idx == childMemories.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 14)
            } else if childMemories.isEmpty && ["topic", "briefing"].contains(memory.kind) && !digest.sectionPills.isEmpty {
                HStack(spacing: 5) {
                    Text("└─")
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(colors.secondaryInk.opacity(0.6))
                    Text(digest.sectionPills.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(colors.secondaryInk)
                        .lineLimit(1)
                }
                .padding(.leading, 14)
                .padding(.vertical, 1)
            }
        }
    }
}

private struct DesktopMemoryDetail: View {
    let model: DesktopModel
    @State var memory: ContextMemory
    @State private var navigationStack: [ContextMemory] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var confirming = false
    @State private var forgetting = false
    @State private var error: String?
    @State private var source: ContextSource?
    @State private var contentHeight: CGFloat = 120
    var body: some View {
        let base = content.environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: model.memories), next.id != memory.id {
                navigationStack.append(memory)
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
        let active = model.memories.filter { $0.status != "forgotten" }
        let sameKind = DreamMemoryCategory.sortMemories(active.filter { $0.kind == memory.kind })
        if sameKind.count > 1 {
            return sameKind
        }
        if ["project", "briefing", "topic", "person", "journal"].contains(memory.kind) {
            let allNotebooks = DreamMemoryCategory.directoryFolders(from: active)
                .filter { $0.id != "core" }
                .flatMap(\.items)
            if allNotebooks.count > 1 {
                return allNotebooks
            }
        }
        return sameKind.isEmpty ? [memory] : sameKind
    }

    private var content: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let isNotebook = ["project", "briefing", "topic", "person", "journal"].contains(memory.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let previous = navigationStack.last {
                    Button {
                        _ = navigationStack.popLast()
                        memory = previous
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("返回「\(MemoryCardDigest.cached(for: previous).title)」")
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(colors.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(colors.paper, in: Capsule())
                        .overlay { Capsule().strokeBorder(colors.secondaryInk.opacity(0.16), lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)

                if isNotebook {
                    MemoryPageStepper(
                        items: siblingMemories,
                        selectedID: memory.id,
                        onSelect: {
                            navigationStack.removeAll()
                            memory = $0
                        }
                    )
                }

                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.paper)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(colors.ink, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if isNotebook && siblingMemories.count > 1 {
                MemoryBinderPageSwitcher(
                    items: siblingMemories,
                    selectedID: memory.id,
                    showStepper: false,
                    onSelect: {
                        navigationStack.removeAll()
                        memory = $0
                    }
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ClientMemoryContent(memory: memory, onDelete: { confirming = true }).textSelection(.enabled)
                    ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                        if let recording = model.sources.first(where: { $0.id == evidence.sourceId && $0.revision == evidence.sourceRevision }) {
                            Button("查看录音原文", systemImage: "text.alignleft") { source = recording }
                        } else {
                            Text("来源已变更或不可用，原引用保留。").phoneText(.caption).foregroundStyle(colors.secondaryInk)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }.frame(height: min(contentHeight, 380))
            if let error { Text(error).foregroundStyle(MoMoPalette.failure) }
        }.padding(14).frame(width: 500).fixedSize(horizontal: false, vertical: true)
        .background(colors.desk)
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
