import SwiftUI
import MoMoAgentClient

struct RemoteMemoryView: View {
    let sync: PhoneContextSync
    var onSelectBriefingCard: ((DreamBriefingCard) -> Void)? = nil
    @State private var forgetting: ContextMemory?
    @State private var selectedCategory: DreamMemoryCategory? = nil
    @State private var selectedMemoryID: String? = nil
    @State private var readerBackStack: [(category: DreamMemoryCategory, memoryID: String?)] = []
    @State private var expandedFolderIDs: Set<String>? = nil
    @State private var collapsedParentIDs: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    private var allMemories: [ContextMemory] { sync.memories.filter { $0.status != "forgotten" } }

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
        VStack(alignment: .leading, spacing: 0) {
            if activeCategory != .all || visibleCategories.count > 2 {
                categoryFilterStrip
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
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
                            Label(allMemories.isEmpty ? "还没有记忆" : "暂无笔记", systemImage: "text.book.closed")
                        } description: {
                            Text(sync.isSyncing ? "正在读取记忆…" : "轻触右上角即可整理或同步。")
                        }
                        .accessibilityIdentifier("remote.memoryEmpty")
                        syncStatusFooter
                    }
                    .padding(16)
                }
            } else if activeCategory.isNotebookReaderCategory, let memory = activeReaderMemory {
                let backAction: (() -> Void)? = readerBackStack.last.map { prev in
                    {
                        _ = readerBackStack.popLast()
                        selectedCategory = prev.category
                        selectedMemoryID = prev.memoryID
                    }
                }
                let backText: String? = readerBackStack.last.map { $0.category == .all ? "目录" : "返回" }

                TabView(
                    selection: Binding(
                        get: { memory.id },
                        set: { newID in
                            selectedMemoryID = newID
                            if let switched = currentReaderItems.first(where: { $0.id == newID }) {
                                let targetCat = DreamMemoryCategory.category(for: switched)
                                if targetCat != activeCategory {
                                    selectedCategory = targetCat
                                }
                            }
                        }
                    )
                ) {
                    ForEach(currentReaderItems) { item in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ClientMemoryContent(
                                    memory: item,
                                    siblingItems: currentReaderItems,
                                    onSelectSibling: { next in
                                        selectedMemoryID = next.id
                                        let targetCat = DreamMemoryCategory.category(for: next)
                                        if targetCat != activeCategory {
                                            selectedCategory = targetCat
                                        }
                                    },
                                    backLabel: backText,
                                    onBack: backAction,
                                    onDelete: { forgetting = item }
                                )
                                .contextMenu {
                                    Button(item.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) {
                                        forgetting = item
                                    }
                                }
                                syncStatusFooter
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 24)
                        }
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
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
                                    if showHeader {
                                        Divider().overlay(colors.line)
                                    }
                                    ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, memory in
                                        if idx > 0 {
                                            Divider()
                                                .overlay(colors.line)
                                                .padding(.leading, 30)
                                        }
                                        directoryItemView(memory, colors: colors)
                                    }
                                }
                            }
                            .background(colors.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(colors.line, lineWidth: 1)
                            }
                        }
                        syncStatusFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 56, coordinateSpace: .local)
                        .onEnded { value in
                            guard visibleCategories.count > 2,
                                  abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                            stepCategory(by: value.translation.width < 0 ? 1 : -1)
                        }
                )
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
                    if activeCategory.isNotebookReaderCategory, let memory = activeReaderMemory {
                        Menu {
                            ShareLink(item: memory.text) { Label("分享", systemImage: "square.and.arrow.up") }
                            Button("忘记这条记忆", role: .destructive) { forgetting = memory }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("记忆操作")
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

    @ViewBuilder
    private func directoryItemView(_ memory: ContextMemory, colors: MemoryNotebookPalette) -> some View {
        let childMemories = MemoryCardDigest.linkedChildren(for: memory, in: allMemories)
        let digest = MemoryCardDigest.cached(for: memory)
        let isParentExpanded = !collapsedParentIDs.contains(memory.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                NavigationLink {
                    RemoteMemoryDetail(sync: sync, memoryID: memory.id)
                } label: {
                    MemoryPreviewRow(memory: memory)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("remote.memoryRow." + memory.id)
                .contextMenu {
                    Button(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) {
                        forgetting = memory
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
                            Text("\(childMemories.count)")
                                .font(.system(size: 11.5, weight: .medium))
                                .monospacedDigit()
                            Image(systemName: isParentExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .foregroundStyle(colors.secondaryInk)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isParentExpanded ? "收起关联页面" : "展开关联页面")
                }

                if memory.kind == "person" {
                    Button(role: .destructive) {
                        forgetting = memory
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(colors.secondaryInk)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除\(digest.title)")
                    .accessibilityIdentifier("remote.deletePerson.\(memory.id)")
                }
            }

            if !childMemories.isEmpty && isParentExpanded {
                ForEach(Array(childMemories.enumerated()), id: \.element.id) { idx, child in
                    Divider()
                        .overlay(colors.line.opacity(0.75))
                        .padding(.leading, 30)
                    NavigationLink {
                        RemoteMemoryDetail(sync: sync, memoryID: child.id)
                    } label: {
                        MemoryDirectoryChildRowLabel(
                            child: child,
                            isLast: idx == childMemories.count - 1
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(child.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive) {
                            forgetting = child
                        }
                    }
                }
            }
        }
    }

    private func stepCategory(by delta: Int) {
        let cats = visibleCategories
        guard cats.count > 1, let idx = cats.firstIndex(of: activeCategory) else { return }
        let nextIdx = (idx + delta + cats.count) % cats.count
        withAnimation(.easeInOut(duration: 0.2)) {
            readerBackStack.removeAll()
            selectedCategory = cats[nextIdx]
            selectedMemoryID = nil
        }
    }

    private var categoryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(visibleCategories) { category in
                    let isSelected = activeCategory == category
                    Button {
                        readerBackStack.removeAll()
                        selectedCategory = category
                        selectedMemoryID = nil
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
    @State var memoryID: String
    @State private var navigationStack: [String] = []
    @State private var confirmingForget = false
    @State private var forgetInFlight = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var memory: ContextMemory? {
        sync.memories.first { $0.id == memoryID && $0.status != "forgotten" }
    }

    private var previousMemory: ContextMemory? {
        guard let prevID = navigationStack.last else { return nil }
        return sync.memories.first { $0.id == prevID && $0.status != "forgotten" }
    }

    private var siblingMemories: [ContextMemory] {
        guard let memory else { return [] }
        let active = sync.memories.filter { $0.status != "forgotten" }
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

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let backAction: (() -> Void)? = previousMemory.map { prev in
            {
                _ = navigationStack.popLast()
                memoryID = prev.id
            }
        }

        Group {
            if let memory {
                if siblingMemories.count > 1 {
                    TabView(
                        selection: Binding(
                            get: { memory.id },
                            set: { newID in
                                navigationStack.removeAll()
                                memoryID = newID
                            }
                        )
                    ) {
                        ForEach(siblingMemories) { item in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    ClientMemoryContent(
                                        memory: item,
                                        siblingItems: siblingMemories,
                                        onSelectSibling: {
                                            navigationStack.removeAll()
                                            memoryID = $0.id
                                        },
                                        backLabel: "返回",
                                        onBack: backAction,
                                        onDelete: { confirmingForget = true }
                                    )
                                    if let failure = sync.failure {
                                        Text(failure)
                                            .phoneText(.metadata)
                                            .foregroundStyle(MoMoPalette.failure)
                                    }
                                }
                                .padding(16)
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
                                backLabel: "返回",
                                onBack: backAction,
                                onDelete: { confirmingForget = true }
                            )
                            if let failure = sync.failure {
                                Text(failure)
                                    .phoneText(.metadata)
                                    .foregroundStyle(MoMoPalette.failure)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: sync.memories), next.id != memoryID {
                navigationStack.append(memoryID)
                memoryID = next.id
                return .handled
            }
            return .systemAction
        })
        .background(colors.desk.ignoresSafeArea())
        .navigationTitle(memory.map { MemoryCardDigest.cached(for: $0).title } ?? "记忆详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(colors.desk, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let memory {
                    Menu {
                        ShareLink(item: memory.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        Button("忘记这条记忆", role: .destructive) { confirmingForget = true }
                            .accessibilityIdentifier("remote.forgetMemory")
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("记忆操作")
                    .accessibilityIdentifier("remote.memoryActions")
                    .disabled(forgetInFlight)
                }
            }
        }
        .alert("忘记这条记忆？", isPresented: $confirmingForget) {
            if let memory {
                Button("忘记", role: .destructive) {
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
