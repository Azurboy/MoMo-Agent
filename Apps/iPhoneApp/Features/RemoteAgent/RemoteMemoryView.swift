import SwiftUI
import MoMoAgentClient

struct RemoteMemoryView: View {
    let sync: PhoneContextSync
    var taskStore: RemoteTaskStore? = nil
    var onSelectBriefingCard: ((DreamBriefingCard) -> Void)? = nil
    @State private var forgetting: ContextMemory?
    @State private var selectedCategory: DreamMemoryCategory? = nil
    @State private var searchQuery = ""
    @State private var expandedFolderIDs: Set<String>? = nil
    @State private var expandedParentIDs: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    private var allMemories: [ContextMemory] { sync.memories.filter { $0.status != "forgotten" } }

    private var activeCategory: DreamMemoryCategory {
        selectedCategory ?? DreamMemoryCategory.preferredInitialCategory(for: allMemories)
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

    private var baseSections: [DreamMemorySection] {
        activeCategory == .all
            ? directoryFolders
            : DreamMemoryCategory.sections(from: allMemories, category: activeCategory)
    }

    private var sections: [DreamMemorySection] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return baseSections }
        return baseSections.compactMap { folder in
            let matches = folder.items.filter { item in
                let digest = MemoryCardDigest.cached(for: item)
                return digest.title.localizedStandardContains(q)
                    || item.text.localizedStandardContains(q)
                    || digest.badge.title.localizedStandardContains(q)
            }
            return matches.isEmpty
                ? nil
                : DreamMemorySection(id: folder.id, title: folder.title, subtitle: folder.subtitle, items: matches)
        }
    }

    private var allFoldersExpanded: Bool {
        let current = expandedFolderIDs ?? DreamMemoryCategory.defaultExpandedFolderIDs(for: directoryFolders)
        return !directoryFolders.isEmpty && directoryFolders.allSatisfy { current.contains($0.id) }
    }

    private func toggleAllFolders() {
        withAnimation(.easeInOut(duration: 0.16)) {
            if allFoldersExpanded {
                expandedFolderIDs = []
                expandedParentIDs.removeAll()
            } else {
                expandedFolderIDs = DreamMemoryCategory.defaultExpandedFolderIDs(for: directoryFolders)
            }
        }
    }

    private func isFolderExpanded(_ folderID: String) -> Bool {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
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
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedFolderIDs = current
        }
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            if !allMemories.isEmpty {
                vaultHeaderBar(colors: colors)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }

            if visibleCategories.count > 2 {
                categoryFilterStrip
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if sync.hasLegacyChanges {
                Text("旧版待同步修改已保留，请核对当前记忆后重新修改。")
                    .phoneText(.metadata)
                    .foregroundStyle(colors.secondaryInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            if let failure = sync.failure {
                Text(failure)
                    .phoneText(.metadata)
                    .foregroundStyle(MoMoPalette.failure)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            if sections.isEmpty {
                ScrollView {
                    VStack(spacing: 16) {
                        ContentUnavailableView {
                            Label(
                                allMemories.isEmpty ? "还没有记忆" : "没有匹配的笔记",
                                systemImage: allMemories.isEmpty ? "folder" : "magnifyingglass"
                            )
                        } description: {
                            Text(
                                allMemories.isEmpty
                                    ? (sync.isSyncing ? "正在读取记忆…" : "轻触右上角即可整理或同步。")
                                    : "试试其他关键词或切换分类。"
                            )
                        }
                        .accessibilityIdentifier("remote.memoryEmpty")
                        syncStatusFooter
                    }
                    .padding(16)
                }
            } else {
                let childrenByParent = MemoryCardDigest.linkedChildrenMap(for: allMemories)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sections) { section in
                            let showHeader = activeCategory == .all && (sections.count > 1 || section.id != "core")
                            let expanded = !showHeader || isFolderExpanded(section.id)

                            VStack(alignment: .leading, spacing: 0) {
                                if showHeader {
                                    MemoryDirectoryFolderHeader(
                                        section: section,
                                        isExpanded: expanded,
                                        onToggle: { toggleFolder(section.id) }
                                    )
                                }

                                if expanded {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, memory in
                                            if idx > 0 {
                                                Divider()
                                                    .overlay(colors.line.opacity(0.55))
                                                    .padding(.leading, 26)
                                            }
                                            directoryItemView(
                                                memory,
                                                childMemories: childrenByParent[memory.id] ?? [],
                                                colors: colors
                                            )
                                        }
                                    }
                                    .padding(.leading, showHeader ? 12 : 0)
                                    .overlay(alignment: .leading) {
                                        if showHeader {
                                            Rectangle()
                                                .fill(colors.line.opacity(0.8))
                                                .frame(width: 1)
                                                .padding(.leading, 16)
                                                .padding(.vertical, 4)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                            .background(colors.paper, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(colors.line.opacity(0.8), lineWidth: 0.7)
                            }
                        }
                        syncStatusFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(colors.desk.ignoresSafeArea())
        .tint(colors.ink)
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(colors.desk, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if activeCategory == .all && directoryFolders.count > 1 {
                        Button(allFoldersExpanded ? "全部折叠" : "全部展开",
                               systemImage: allFoldersExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                            toggleAllFolders()
                        }
                    }
                    Button("立即 Dream 整理", systemImage: "sparkles") {
                        Task { await sync.triggerDream() }
                    }
                    .disabled(sync.isSyncing || sync.isDreamRequesting || sync.memoryReview?.running == true)
                    .accessibilityIdentifier("remote.triggerDream")
                    Button("同步录音与记忆", systemImage: "arrow.clockwise") { Task { await sync.refresh() } }
                        .disabled(sync.isSyncing)
                        .accessibilityIdentifier("remote.syncMemory")
                }
            }
        }
        .alert(forgetting?.kind == "person" ? "删除该人物档案？" : "忘记这条记忆？", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            if let memory = forgetting {
                Button(memory.kind == "person" ? "删除" : "忘记", role: .destructive) { Task { await sync.forget(memory) }; forgetting = nil }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(forgetting?.kind == "person"
                 ? "连接 Mac 后删除该人物档案与本地声纹，且 Dream 不会再次自动生成该说话人。"
                 : "连接 Mac 后删除这条记忆。原始录音与聊天记录仍保留。")
        }
        .task { await sync.refresh() }
    }

    private func vaultHeaderBar(colors: MemoryNotebookPalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13.5))
                .foregroundStyle(colors.secondaryInk)
            TextField("搜索笔记、项目、人物或关键词…", text: $searchQuery)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(colors.secondaryInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(colors.paper, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(colors.line, lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private func directoryItemView(_ memory: ContextMemory, childMemories: [ContextMemory], colors: MemoryNotebookPalette) -> some View {
        let digest = MemoryCardDigest.cached(for: memory)
        let isParentExpanded = expandedParentIDs.contains(memory.id)

        VStack(alignment: .leading, spacing: 0) {
            if childMemories.isEmpty {
                NavigationLink {
                    RemoteMemoryDetail(sync: sync, taskStore: taskStore, memoryID: memory.id)
                } label: {
                    MemoryPreviewRow(memory: memory)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("remote.memoryRow." + memory.id)
                .contextMenu {
                    Button("复制 Markdown", systemImage: "doc.on.doc") {
                        MemoryCardDigest.copyToPasteboard(memory.text)
                    }
                    Divider()
                    Button(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) {
                        forgetting = memory
                    }
                }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isParentExpanded {
                            expandedParentIDs.remove(memory.id)
                        } else {
                            expandedParentIDs.insert(memory.id)
                        }
                    }
                } label: {
                    MemoryCardView(
                        memory: memory,
                        childCount: childMemories.count,
                        isExpanded: isParentExpanded
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("remote.memoryRow." + memory.id)
                .contextMenu {
                    Button("复制 Markdown", systemImage: "doc.on.doc") {
                        MemoryCardDigest.copyToPasteboard(memory.text)
                    }
                    Divider()
                    Button(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) {
                        forgetting = memory
                    }
                }
            }

            if !childMemories.isEmpty && isParentExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink {
                        RemoteMemoryDetail(sync: sync, taskStore: taskStore, memoryID: memory.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(colors.tabAccent(memory.kind))
                                .frame(width: 14)
                                .accessibilityHidden(true)
                            Text("打开「\(digest.title)」全文")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(colors.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(colors.secondaryInk.opacity(0.6))
                                .accessibilityHidden(true)
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(childMemories.enumerated()), id: \.element.id) { idx, child in
                        Divider()
                            .overlay(colors.line.opacity(0.5))
                            .padding(.leading, 12)
                        NavigationLink {
                            RemoteMemoryDetail(sync: sync, taskStore: taskStore, memoryID: child.id)
                        } label: {
                            MemoryDirectoryChildRowLabel(
                                child: child,
                                isLast: idx == childMemories.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("复制 Markdown", systemImage: "doc.on.doc") {
                                MemoryCardDigest.copyToPasteboard(child.text)
                            }
                            Divider()
                            Button(child.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) {
                                forgetting = child
                            }
                        }
                    }
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(colors.line.opacity(0.8))
                        .frame(width: 1)
                        .padding(.leading, 18)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var categoryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(visibleCategories) { category in
                    let isSelected = activeCategory == category
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedCategory = category
                        }
                    } label: {
                        MemoryBinderTab(category: category, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("remote.memoryCategory.\(category.rawValue)")
                }
            }
        }
    }

    private var syncStatusFooter: some View {
        HStack(spacing: 6) {
            if sync.memoryReview?.running == true || sync.isDreamRequesting {
                Text("正在整理…")
            } else {
                Text(sync.isSyncing ? String(localized: "正在同步") : sourceStatus)
            }
            Spacer(minLength: 8)
            if let date = sync.lastSynced {
                Text(date, style: .relative)
            }
        }
        .font(.caption2)
        .foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote.memorySyncStatus")
    }

    private var sourceStatus: String {
        if sync.pendingSources > 0 { return String(localized: "\(sync.pendingSources) 份待送达") }
        return sync.lastSourcesSent == nil ? String(localized: "尚未同步") : String(localized: "已同步")
    }
}

private struct MemoryPreviewRow: View {
    let memory: ContextMemory
    var body: some View {
        MemoryCardView(memory: memory)
    }
}

private struct RemoteMemoryDetail: View {
    let sync: PhoneContextSync
    var taskStore: RemoteTaskStore? = nil
    @State var memoryID: String
    @State private var navigationStack: [String] = []
    @State private var forwardStack: [String] = []
    @State private var confirmingForget = false
    @State private var forgetInFlight = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var activeMemories: [ContextMemory] {
        sync.memories.filter { $0.status != "forgotten" }
    }

    private var memory: ContextMemory? {
        activeMemories.first { $0.id == memoryID }
    }

    private var previousMemory: ContextMemory? {
        guard let prevID = navigationStack.last else { return nil }
        return activeMemories.first { $0.id == prevID }
    }

    private var siblingMemories: [ContextMemory] {
        guard let memory else { return [] }
        let sameKind = DreamMemoryCategory.sortMemories(activeMemories.filter { $0.kind == memory.kind })
        if sameKind.count > 1 {
            return sameKind
        }
        if ["project", "briefing", "topic", "person", "journal"].contains(memory.kind) {
            let allNotebooks = DreamMemoryCategory.directoryFolders(from: activeMemories)
                .filter { $0.id != "core" }
                .flatMap(\.items)
            if allNotebooks.count > 1 {
                return allNotebooks
            }
        }
        return sameKind.isEmpty ? [memory] : sameKind
    }

    private func push(_ nextID: String) {
        guard nextID != memoryID else { return }
        navigationStack.append(memoryID)
        forwardStack.removeAll()
        memoryID = nextID
    }

    private var instructHandler: ((String) async throws -> Void)? {
        guard let store = taskStore else { return nil }
        return { fullPrompt in
            let previousDraft = store.draft
            store.setDraft(fullPrompt)
            defer {
                if !previousDraft.isEmpty {
                    store.setDraft(previousDraft)
                }
            }
            try store.enqueue()
            Task {
                await store.refresh(userInitiated: true)
                for delay in [6, 10, 15, 22] {
                    try? await Task.sleep(for: .seconds(delay))
                    await sync.refresh()
                }
            }
        }
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let backAction: (() -> Void)? = previousMemory.map { prev in
            {
                _ = navigationStack.popLast()
                forwardStack.append(memoryID)
                memoryID = prev.id
            }
        }
        let forwardAction: (() -> Void)? = (!navigationStack.isEmpty || !forwardStack.isEmpty) ? {
            guard let nextID = forwardStack.popLast() else { return }
            navigationStack.append(memoryID)
            memoryID = nextID
        } : nil

        Group {
            if let memory {
                if siblingMemories.count > 1 {
                    TabView(
                        selection: Binding(
                            get: { memory.id },
                            set: { newID in
                                guard newID != memoryID else { return }
                                navigationStack.removeAll()
                                forwardStack.removeAll()
                                memoryID = newID
                            }
                        )
                    ) {
                        ForEach(siblingMemories) { item in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    ClientMemoryContent(
                                        memory: item,
                                        allMemories: activeMemories,
                                        siblingItems: siblingMemories,
                                        onSelectSibling: {
                                            navigationStack.removeAll()
                                            forwardStack.removeAll()
                                            memoryID = $0.id
                                        },
                                        onSelectLinkedMemory: { push($0.id) },
                                        backLabel: "后退",
                                        onBack: backAction,
                                        canGoForward: !forwardStack.isEmpty,
                                        onForward: forwardAction,
                                        borderless: true,
                                        onInstruct: instructHandler
                                    )
                                    if let failure = sync.failure {
                                        Text(failure)
                                            .phoneText(.metadata)
                                            .foregroundStyle(MoMoPalette.failure)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                                .padding(.bottom, 28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .tag(item.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ClientMemoryContent(
                                memory: memory,
                                allMemories: activeMemories,
                                onSelectLinkedMemory: { push($0.id) },
                                backLabel: "后退",
                                onBack: backAction,
                                canGoForward: !forwardStack.isEmpty,
                                onForward: forwardAction,
                                borderless: true,
                                onInstruct: instructHandler
                            )
                            if let failure = sync.failure {
                                Text(failure)
                                    .phoneText(.metadata)
                                    .foregroundStyle(MoMoPalette.failure)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: sync.memories), next.id != memoryID {
                push(next.id)
                return .handled
            }
            return .systemAction
        })
        .background(colors.paper.ignoresSafeArea())
        .navigationTitle(memory.map { MemoryCardDigest.cached(for: $0).title } ?? "记忆详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(colors.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let memory {
                    Menu {
                        Button {
                            MemoryCardDigest.copyToPasteboard(memory.text)
                        } label: {
                            Label("复制 Markdown", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: memory.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) { confirmingForget = true }
                            .accessibilityIdentifier("remote.forgetMemory")
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("记忆操作")
                    .accessibilityIdentifier("remote.memoryActions")
                    .disabled(forgetInFlight)
                }
            }
        }
        .alert(memory?.kind == "person" ? "删除该人物档案？" : "忘记这条记忆？", isPresented: $confirmingForget) {
            if let memory {
                Button(memory.kind == "person" ? "删除" : "忘记", role: .destructive) {
                    forgetInFlight = true
                    Task { await sync.forget(memory); forgetInFlight = false }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(memory?.kind == "person"
                 ? "连接 Mac 后删除该人物档案与本地声纹，且 Dream 不会再次自动生成该说话人。"
                 : "连接 Mac 后删除这条记忆。原始录音与聊天记录仍保留。")
        }
        .onChange(of: memory == nil) { _, missing in if missing { dismiss() } }
    }
}

/// Only a recognized leading source stamp is moved out of the list excerpt.
/// The detail and share action always use the original, unmodified memory.
struct MemoryPreview {
    let date: String?
    let sourceNote: String?
    let text: String

    init(text original: String) {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{1,2}/\d{1,2}(?:[–—-]\d{1,2})?)\s*(?:录音\s*)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?:\s+v\d+(?:[–—-]\d+)?)?\s*(?:[（(](归属\s*/\s*执行未核)[）)]\s*[：:]\s*)?"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let stamp = Range(match.range, in: text), let dateRange = Range(match.range(at: 1), in: text),
           !text[stamp.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            date = String(text[dateRange])
            sourceNote = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            self.text = String(text[stamp.upperBound...])
        } else {
            date = nil
            sourceNote = nil
            self.text = text
        }
    }
}
