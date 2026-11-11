import SwiftUI
import MoMoAgentClient

struct DesktopMemory: View {
    @Bindable var model: DesktopModel
    var isActive: Bool = true
    @State private var selectedMemoryID: String? = nil
    @State private var revealInExplorerID: String? = nil
    @State private var readerBackStack: [String] = []
    @State private var readerForwardStack: [String] = []
    @State private var inspecting: ContextMemory?
    @State private var deletingMemory: ContextMemory?
    @State private var expandedFolderIDs: Set<String>? = nil
    @State private var expandedParentIDs: Set<String> = []
    @State private var searching = false
    @State private var searchQuery = ""
    @State private var readingSource: ContextSource?
    @State private var dreamRequesting = false
    @Environment(\.colorScheme) private var scheme

    private var vault: MemoryVaultSnapshot {
        model.vaultSnapshot
    }

    private var filteredFolders: [DreamMemorySection] {
        vault.filteredFolders(matching: searchQuery)
    }

    private func resolvedSelectedMemory(wide: Bool, folders: [DreamMemorySection]) -> ContextMemory? {
        if let selectedMemoryID, let direct = vault.byID[selectedMemoryID] {
            return direct
        }
        guard wide else { return nil }
        return folders.first?.items.first
    }

    private func siblingItems(for memory: ContextMemory, folders: [DreamMemorySection]) -> [ContextMemory] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vault.siblingsByMemoryID[memory.id] ?? [memory]
        }
        if let folder = folders.first(where: { $0.items.contains(where: { $0.id == memory.id }) }),
           folder.items.count > 1 {
            return folder.items
        }
        let allVisible = folders.flatMap(\.items)
        return allVisible.count > 1 ? allVisible : [memory]
    }

    private var allFoldersExpanded: Bool {
        let current = expandedFolderIDs ?? vault.defaultExpandedFolderIDs
        return !vault.folders.isEmpty && vault.folders.allSatisfy { current.contains($0.id) }
    }

    private func toggleAllFolders() {
        if allFoldersExpanded {
            expandedFolderIDs = []
            expandedParentIDs.removeAll()
        } else {
            expandedFolderIDs = vault.defaultExpandedFolderIDs
        }
    }

    private func isFolderExpanded(_ folderID: String) -> Bool {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let current = expandedFolderIDs ?? vault.defaultExpandedFolderIDs
        return current.contains(folderID)
    }

    private func toggleFolder(_ folderID: String) {
        var current = expandedFolderIDs ?? vault.defaultExpandedFolderIDs
        if current.contains(folderID) {
            current.remove(folderID)
        } else {
            current.insert(folderID)
        }
        expandedFolderIDs = current
    }

    private func navigateToNote(_ targetID: String, currentID: String?) {
        guard targetID != currentID else { return }
        if let currentID {
            readerBackStack.append(currentID)
        }
        readerForwardStack.removeAll()
        selectedMemoryID = targetID
        revealInExplorerID = targetID
    }

    static func dispatchInstruction(_ fullPrompt: String, model: DesktopModel) async throws {
        guard let store = model.taskStore else {
            throw NSError(domain: "MoMoMemory", code: 1, userInfo: [NSLocalizedDescriptionKey: "MoMo 尚未连接，暂时无法发送修改指令"])
        }
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
            for delay in [6, 9, 12, 15, 20] {
                try? await Task.sleep(for: .seconds(delay))
                await model.loadContext(silent: true)
            }
        }
    }

    private func buildFlatEntries(folders: [DreamMemorySection], activeID: String?) -> [VaultSidebarEntry] {
        let childrenByParent = vault.childrenByParentID
        let metaByID = vault.rowMetaByID
        var entries: [VaultSidebarEntry] = []
        entries.reserveCapacity(vault.activeMemories.count + folders.count)

        for section in folders {
            let showFolderRow = folders.count > 1 || section.id != "core"
            let expanded = !showFolderRow || isFolderExpanded(section.id)

            if showFolderRow {
                entries.append(.folder(
                    sectionID: section.id,
                    title: section.title,
                    itemCount: section.items.count,
                    isExpanded: expanded
                ))
            }

            guard expanded else { continue }

            for memory in section.items {
                let meta = metaByID[memory.id]
                let children = childrenByParent[memory.id] ?? []
                let parentExpanded = !children.isEmpty && expandedParentIDs.contains(memory.id)

                entries.append(.note(
                    memory: memory,
                    title: meta?.title ?? memory.id,
                    symbol: meta?.symbol ?? "doc.text",
                    shortJournalDate: meta?.shortJournalDate,
                    childCount: children.count,
                    isExpanded: parentExpanded,
                    isSelected: activeID == memory.id,
                    underFolder: showFolderRow
                ))

                if parentExpanded {
                    for child in children {
                        let childMeta = metaByID[child.id]
                        entries.append(.childNote(
                            parentID: memory.id,
                            child: child,
                            title: childMeta?.title ?? child.id,
                            symbol: childMeta?.symbol ?? "doc.text",
                            isSelected: activeID == child.id,
                            underFolder: showFolderRow
                        ))
                    }
                }
            }
        }
        return entries
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let folders = filteredFolders

        GeometryReader { geometry in
            let totalWidth = max(1, geometry.size.width)
            let totalHeight = max(1, geometry.size.height)
            let wide = totalWidth >= 680
            let active = resolvedSelectedMemory(wide: wide, folders: folders)
            let sidebarWidth: CGFloat = wide ? 268 : totalWidth
            let paneWidth: CGFloat = wide ? max(1, totalWidth - sidebarWidth - 1) : totalWidth

            HStack(spacing: 0) {
                if wide || active == nil {
                    vaultExplorerSidebar(folders: folders, activeID: active?.id, colors: colors)
                        .frame(width: sidebarWidth, height: totalHeight)
                        .background(MoMoPalette.canvas)
                }

                if wide {
                    Rectangle()
                        .fill(MoMoPalette.line.opacity(0.85))
                        .frame(width: 1, height: totalHeight)
                        .accessibilityHidden(true)
                }

                if wide || active != nil {
                    documentWorkspacePane(
                        active: active,
                        folders: folders,
                        wide: wide,
                        paneWidth: paneWidth,
                        colors: colors
                    )
                    .frame(width: paneWidth, height: totalHeight)
                }
            }
        }
        .background(MoMoPalette.paper)
        .task(id: isActive) {
            guard isActive else { return }
            await model.loadContextIfStale(maxAge: 12)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await model.loadContext(silent: true)
            }
        }
        .sheet(item: $inspecting) { memory in
            DesktopMemoryDetail(model: model, memory: memory)
        }
        .sheet(item: $readingSource) { source in
            VStack(spacing: 0) {
                DesktopSourceReader(
                    model: model,
                    source: source,
                    close: { readingSource = nil },
                    onDiscuss: { readingSource = nil }
                )
            }
            .frame(width: 620, height: 520)
            .background(MoMoPalette.canvas)
        }
        .confirmationDialog(
            deletingMemory?.kind == "person" ? "删除该人物档案？" : "忘记这条记忆？",
            isPresented: Binding(get: { deletingMemory != nil }, set: { if !$0 { deletingMemory = nil } }),
            titleVisibility: .visible
        ) {
            if let target = deletingMemory {
                Button(target.kind == "person" ? "删除" : "忘记", role: .destructive) {
                    let deletedID = target.id
                    deletingMemory = nil
                    if selectedMemoryID == deletedID {
                        selectedMemoryID = nil
                    }
                    readerBackStack.removeAll(where: { $0 == deletedID })
                    readerForwardStack.removeAll(where: { $0 == deletedID })
                    Task { try? await model.forgetMemory(target) }
                }
            }
        } message: {
            Text(deletingMemory?.kind == "person"
                 ? "删除后 Dream 不会再次自动生成该说话人档案。"
                 : "原始录音和聊天记录仍保留。")
        }
    }

    private var explorerToolbar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("记忆")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MoMoPalette.ink)
                    .accessibilityAddTraits(.isHeader)

                if !vault.activeMemories.isEmpty {
                    Text("\(vault.activeMemories.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(MoMoPalette.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(MoMoPalette.surface, in: Capsule())
                }
            }

            Spacer(minLength: 4)

            VaultIconButton(
                symbol: searching ? "xmark" : "magnifyingglass",
                isActive: searching,
                help: searching ? "关闭搜索" : "搜索笔记",
                accessibilityLabel: searching ? "关闭搜索" : "搜索记忆"
            ) {
                searching.toggle()
                if !searching { searchQuery = "" }
            }

            if !vault.folders.isEmpty {
                VaultIconButton(
                    symbol: allFoldersExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                    isActive: false,
                    help: allFoldersExpanded ? "全部折叠" : "全部展开",
                    accessibilityLabel: allFoldersExpanded ? "全部折叠" : "全部展开"
                ) {
                    toggleAllFolders()
                }
            }

            VaultIconButton(
                symbol: "sparkles",
                isActive: dreamRequesting || model.memoryReviewStatus?.running == true,
                help: "立即执行 Dream 闲时深度整理",
                accessibilityLabel: "立即 Dream 整理",
                accessibilityID: "settings.memory.dream",
                disabled: model.contextLoading || dreamRequesting || model.memoryReviewStatus?.running == true
            ) {
                dreamRequesting = true
                Task {
                    defer { dreamRequesting = false }
                    try? await model.triggerDream()
                }
            }

            VaultIconButton(
                symbol: "arrow.clockwise",
                isActive: false,
                help: "刷新记忆库",
                accessibilityLabel: "刷新",
                accessibilityID: "settings.memory.refresh",
                disabled: model.contextLoading
            ) {
                Task { await model.loadContext() }
            }
        }
    }

    private func vaultExplorerSidebar(folders: [DreamMemorySection], activeID: String?, colors: MemoryNotebookPalette) -> some View {
        VStack(spacing: 8) {
            explorerToolbar
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)

            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoMoPalette.muted)
                    TextField("搜索笔记、项目、人物…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(MoMoPalette.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(MoMoPalette.line, lineWidth: 0.7)
                }
                .padding(.horizontal, 12)
            }

            if let error = model.memoryError {
                HStack(spacing: 8) {
                    Text(error)
                        .phoneText(.caption)
                        .foregroundStyle(MoMoPalette.failure)
                        .lineLimit(2)
                    Spacer()
                    Button("重试") {
                        Task { await model.loadContext() }
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 14)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if model.contextLoading && vault.activeMemories.isEmpty {
                        ProgressView("正在读取记忆")
                            .padding(32)
                            .frame(maxWidth: .infinity)
                    } else if folders.isEmpty {
                        ContentUnavailableView(
                            vault.activeMemories.isEmpty ? "还没有记忆" : "没有匹配的笔记",
                            systemImage: vault.activeMemories.isEmpty ? "folder" : "magnifyingglass",
                            description: Text(vault.activeMemories.isEmpty ? "点击右上角即可整理或刷新。" : "换个关键词试试。")
                        )
                        .padding(.top, 32)
                    } else {
                        let entries = buildFlatEntries(folders: folders, activeID: activeID)
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(entries) { entry in
                                switch entry {
                                case let .folder(sectionID, title, itemCount, isExpanded):
                                    DesktopVaultFolderRow(
                                        sectionID: sectionID,
                                        title: title,
                                        itemCount: itemCount,
                                        isExpanded: isExpanded,
                                        accent: colors.tabAccent(sectionID),
                                        onToggle: { toggleFolder(sectionID) }
                                    )
                                    .equatable()
                                    .padding(.top, 3)

                                case let .note(memory, title, symbol, shortJournalDate, childCount, isExpanded, isSelected, underFolder):
                                    DesktopOutlineRow(
                                        memoryID: memory.id,
                                        kind: memory.kind,
                                        title: title,
                                        symbol: symbol,
                                        shortJournalDate: shortJournalDate,
                                        rawMarkdown: memory.text,
                                        isSelected: isSelected,
                                        childCount: childCount,
                                        isExpanded: isExpanded,
                                        underFolder: underFolder,
                                        accent: colors.tabAccent(memory.kind),
                                        onActivate: {
                                            let wasSelected = activeID == memory.id
                                            readerBackStack.removeAll()
                                            readerForwardStack.removeAll()
                                            selectedMemoryID = memory.id
                                            if childCount > 0 {
                                                if wasSelected && isExpanded {
                                                    expandedParentIDs.remove(memory.id)
                                                } else if !isExpanded {
                                                    expandedParentIDs.insert(memory.id)
                                                }
                                            }
                                        },
                                        onOpenPopup: { inspecting = memory },
                                        onDelete: { deletingMemory = memory }
                                    )
                                    .equatable()
                                    .id(memory.id)

                                case let .childNote(parentID, child, title, symbol, isSelected, underFolder):
                                    DesktopOutlineChildRow(
                                        rowKey: "\(parentID)::\(child.id)",
                                        childID: child.id,
                                        kind: child.kind,
                                        title: title,
                                        symbol: symbol,
                                        rawMarkdown: child.text,
                                        isSelected: isSelected,
                                        underFolder: underFolder,
                                        accent: colors.tabAccent(child.kind),
                                        onSelect: {
                                            readerBackStack.removeAll()
                                            readerForwardStack.removeAll()
                                            selectedMemoryID = child.id
                                        },
                                        onOpenPopup: { inspecting = child },
                                        onDelete: { deletingMemory = child }
                                    )
                                    .equatable()
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 20)
                    }
                }
                .onChange(of: revealInExplorerID) {
                    guard let target = revealInExplorerID else { return }
                    revealInExplorerID = nil
                    proxy.scrollTo(target)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func documentWorkspacePane(
        active: ContextMemory?,
        folders: [DreamMemorySection],
        wide: Bool,
        paneWidth: CGFloat,
        colors: MemoryNotebookPalette
    ) -> some View {
        if let memory = active {
            let siblings = siblingItems(for: memory, folders: folders)
            let outgoing = vault.childrenByParentID[memory.id] ?? []
            let incoming = vault.backlinksByTargetID[memory.id] ?? []
            let sourceMap = model.transcriptSnapshot.sourceByIDRevision
            let contentWidth = max(180, min(740, floor(paneWidth - 76)))

            let backAction: (() -> Void)? = {
                if let prevID = readerBackStack.last {
                    return {
                        _ = readerBackStack.popLast()
                        readerForwardStack.append(memory.id)
                        selectedMemoryID = prevID
                        revealInExplorerID = prevID
                    }
                }
                if !wide {
                    return { selectedMemoryID = nil }
                }
                return nil
            }()
            let forwardAction: (() -> Void)? = (!readerBackStack.isEmpty || !readerForwardStack.isEmpty) ? {
                guard let nextID = readerForwardStack.popLast() else { return }
                readerBackStack.append(memory.id)
                selectedMemoryID = nextID
                revealInExplorerID = nextID
            } : nil
            let backText: String? = readerBackStack.isEmpty ? (!wide ? "目录" : nil) : "后退"

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("reader.top")

                        ClientMemoryContent(
                            memory: memory,
                            allMemories: vault.activeMemories,
                            siblingItems: siblings,
                            precomputedOutgoing: outgoing,
                            precomputedIncoming: incoming,
                            onSelectSibling: { next in
                                readerBackStack.removeAll()
                                readerForwardStack.removeAll()
                                selectedMemoryID = next.id
                                revealInExplorerID = next.id
                            },
                            onSelectLinkedMemory: { target in
                                navigateToNote(target.id, currentID: memory.id)
                            },
                            backLabel: backText,
                            onBack: backAction,
                            canGoForward: !readerForwardStack.isEmpty,
                            onForward: forwardAction,
                            onDelete: { deletingMemory = memory },
                            borderless: true,
                            sourceLookup: { ev in
                                sourceMap["\(ev.sourceId)|\(ev.sourceRevision)"]
                            },
                            onOpenSource: { rec in
                                readingSource = rec
                            },
                            onInstruct: model.taskStore != nil ? { prompt in
                                try await Self.dispatchInstruction(prompt, model: model)
                            } : nil
                        )
                        .environment(\.openURL, OpenURLAction { url in
                            if let next = DreamMemoryLinkResolver.resolve(url: url, in: vault.activeMemories), next.id != memory.id {
                                navigateToNote(next.id, currentID: memory.id)
                                return .handled
                            }
                            return .systemAction
                        })
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(.vertical, 26)
                    }
                    .frame(width: paneWidth)
                }
                .onChange(of: memory.id) {
                    scrollProxy.scrollTo("reader.top", anchor: .top)
                }
            }
            .background(MoMoPalette.paper)
        } else {
            ContentUnavailableView(
                vault.activeMemories.isEmpty ? "记忆库为空" : "选择一篇笔记",
                systemImage: "doc.text",
                description: Text(vault.activeMemories.isEmpty ? "日常对话与录音经 Dream 整理后会归档在这里。" : "从左侧文件树选择项目、简报或人物笔记。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MoMoPalette.paper)
        }
    }
}

private enum VaultSidebarEntry: Identifiable {
    case folder(sectionID: String, title: String, itemCount: Int, isExpanded: Bool)
    case note(
        memory: ContextMemory,
        title: String,
        symbol: String,
        shortJournalDate: String?,
        childCount: Int,
        isExpanded: Bool,
        isSelected: Bool,
        underFolder: Bool
    )
    case childNote(
        parentID: String,
        child: ContextMemory,
        title: String,
        symbol: String,
        isSelected: Bool,
        underFolder: Bool
    )

    var id: String {
        switch self {
        case .folder(let sectionID, _, _, _):
            return "folder:\(sectionID)"
        case .note(let memory, _, _, _, _, _, _, _):
            return memory.id
        case .childNote(let parentID, let child, _, _, _, _):
            return "child:\(parentID):\(child.id)"
        }
    }
}

private struct VaultHoverSurfaceModifier: ViewModifier {
    let isSelected: Bool
    var hoverOpacity: Double = 0.55
    var cornerRadius: CGFloat = 6
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                isSelected
                    ? MoMoPalette.surface
                    : (hovered ? MoMoPalette.surface.opacity(hoverOpacity) : .clear),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovered = $0 }
    }
}

private struct VaultIconButton: View {
    let symbol: String
    let isActive: Bool
    let help: String
    let accessibilityLabel: String
    var accessibilityID: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? MoMoPalette.ink : MoMoPalette.muted)
                .frame(width: 26, height: 26)
                .modifier(VaultHoverSurfaceModifier(isSelected: isActive, hoverOpacity: 0.65, cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)

        if let accessibilityID {
            button.accessibilityIdentifier(accessibilityID)
        } else {
            button
        }
    }
}

private struct DesktopVaultFolderRow: View, Equatable {
    let sectionID: String
    let title: String
    let itemCount: Int
    let isExpanded: Bool
    let accent: Color
    let onToggle: () -> Void

    nonisolated static func == (lhs: DesktopVaultFolderRow, rhs: DesktopVaultFolderRow) -> Bool {
        lhs.sectionID == rhs.sectionID
            && lhs.title == rhs.title
            && lhs.itemCount == rhs.itemCount
            && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MoMoPalette.muted.opacity(0.85))
                    .frame(width: 11)
                    .accessibilityHidden(true)

                Image(systemName: DreamMemoryCategory.folderSymbol(for: sectionID))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(MoMoPalette.ink.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(itemCount)")
                    .font(.system(size: 10.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(MoMoPalette.muted)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(VaultHoverSurfaceModifier(isSelected: false, hoverOpacity: 0.55, cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remote.memoryFolder.\(sectionID)")
    }
}

private struct DesktopOutlineRow: View, Equatable {
    let memoryID: String
    let kind: String
    let title: String
    let symbol: String
    let shortJournalDate: String?
    let rawMarkdown: String
    let isSelected: Bool
    let childCount: Int
    let isExpanded: Bool
    let underFolder: Bool
    let accent: Color
    let onActivate: () -> Void
    var onOpenPopup: (() -> Void)? = nil
    let onDelete: () -> Void

    nonisolated static func == (lhs: DesktopOutlineRow, rhs: DesktopOutlineRow) -> Bool {
        lhs.memoryID == rhs.memoryID
            && lhs.title == rhs.title
            && lhs.symbol == rhs.symbol
            && lhs.shortJournalDate == rhs.shortJournalDate
            && lhs.isSelected == rhs.isSelected
            && lhs.childCount == rhs.childCount
            && lhs.isExpanded == rhs.isExpanded
            && lhs.underFolder == rhs.underFolder
    }

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 6) {
                if childCount > 0 {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(MoMoPalette.muted)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(isSelected ? accent : MoMoPalette.muted.opacity(0.85))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? MoMoPalette.ink : MoMoPalette.ink.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if childCount > 0 {
                    Text("\(childCount)")
                        .font(.system(size: 10.5, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(MoMoPalette.muted)
                        .accessibilityHidden(true)
                } else if let date = shortJournalDate {
                    Text(date)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(MoMoPalette.muted.opacity(0.8))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 5)
                        .accessibilityHidden(true)
                }
            }
            .modifier(VaultHoverSurfaceModifier(isSelected: isSelected, hoverOpacity: 0.55, cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.leading, underFolder ? 14 : 0)
        .overlay(alignment: .leading) {
            if underFolder {
                Rectangle()
                    .fill(MoMoPalette.line.opacity(0.75))
                    .frame(width: 1)
                    .padding(.leading, 9)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("remote.memoryRow." + memoryID)
        .contextMenu {
            Button("复制 Markdown", systemImage: "doc.on.doc") {
                MemoryCardDigest.copyToPasteboard(rawMarkdown)
            }
            if let onOpenPopup {
                Button("在独立窗口预览", systemImage: "macwindow") {
                    onOpenPopup()
                }
            }
            Divider()
            Button(kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive, action: onDelete)
        }
    }
}

private struct DesktopOutlineChildRow: View, Equatable {
    let rowKey: String
    let childID: String
    let kind: String
    let title: String
    let symbol: String
    let rawMarkdown: String
    let isSelected: Bool
    let underFolder: Bool
    let accent: Color
    let onSelect: () -> Void
    var onOpenPopup: (() -> Void)? = nil
    let onDelete: () -> Void

    nonisolated static func == (lhs: DesktopOutlineChildRow, rhs: DesktopOutlineChildRow) -> Bool {
        lhs.rowKey == rhs.rowKey
            && lhs.title == rhs.title
            && lhs.symbol == rhs.symbol
            && lhs.isSelected == rhs.isSelected
            && lhs.underFolder == rhs.underFolder
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(isSelected ? accent : MoMoPalette.muted.opacity(0.75))
                    .frame(width: 12)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? MoMoPalette.ink : MoMoPalette.muted)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
            }
            .modifier(VaultHoverSurfaceModifier(isSelected: isSelected, hoverOpacity: 0.5, cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.leading, underFolder ? 29 : 15)
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                if underFolder {
                    Rectangle()
                        .fill(MoMoPalette.line.opacity(0.75))
                        .frame(width: 1)
                        .padding(.leading, 9)
                }
                Rectangle()
                    .fill(MoMoPalette.line.opacity(0.75))
                    .frame(width: 1)
                    .padding(.leading, underFolder ? 23 : 9)
            }
            .accessibilityHidden(true)
        }
        .contextMenu {
            Button("复制 Markdown", systemImage: "doc.on.doc") {
                MemoryCardDigest.copyToPasteboard(rawMarkdown)
            }
            if let onOpenPopup {
                Button("在独立窗口预览", systemImage: "macwindow") {
                    onOpenPopup()
                }
            }
            Divider()
            Button(kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive, action: onDelete)
        }
    }
}

private struct DesktopMemoryDetail: View {
    let model: DesktopModel
    @State var memory: ContextMemory
    @State private var navigationStack: [ContextMemory] = []
    @State private var forwardStack: [ContextMemory] = []
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var forgetting = false
    @State private var error: String?
    @State private var source: ContextSource?

    private var vault: MemoryVaultSnapshot {
        model.vaultSnapshot
    }

    private func push(_ next: ContextMemory) {
        guard next.id != memory.id else { return }
        navigationStack.append(memory)
        forwardStack.removeAll()
        memory = next
    }

    var body: some View {
        let backAction: (() -> Void)? = navigationStack.last.map { prev in
            {
                _ = navigationStack.popLast()
                forwardStack.append(memory)
                memory = prev
            }
        }
        let forwardAction: (() -> Void)? = (!navigationStack.isEmpty || !forwardStack.isEmpty) ? {
            guard let next = forwardStack.popLast() else { return }
            navigationStack.append(memory)
            memory = next
        } : nil
        let siblings = vault.siblingsByMemoryID[memory.id] ?? [memory]
        let outgoing = vault.childrenByParentID[memory.id] ?? []
        let incoming = vault.backlinksByTargetID[memory.id] ?? []
        let sourceMap = model.transcriptSnapshot.sourceByIDRevision

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ClientMemoryContent(
                    memory: memory,
                    allMemories: vault.activeMemories,
                    siblingItems: siblings,
                    precomputedOutgoing: outgoing,
                    precomputedIncoming: incoming,
                    onSelectSibling: {
                        navigationStack.removeAll()
                        forwardStack.removeAll()
                        memory = $0
                    },
                    onSelectLinkedMemory: { push($0) },
                    backLabel: "后退",
                    onBack: backAction,
                    canGoForward: !forwardStack.isEmpty,
                    onForward: forwardAction,
                    onDelete: { confirming = true },
                    onClose: { dismiss() },
                    borderless: true,
                    sourceLookup: { ev in
                        sourceMap["\(ev.sourceId)|\(ev.sourceRevision)"]
                    },
                    onOpenSource: { rec in
                        source = rec
                    },
                    onInstruct: model.taskStore != nil ? { prompt in
                        try await DesktopMemory.dispatchInstruction(prompt, model: model)
                    } : nil
                )

                if let error {
                    Text(error).foregroundStyle(MoMoPalette.failure).padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(width: 560, height: 480)
        .background(MoMoPalette.paper)
        .environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: vault.activeMemories), next.id != memory.id {
                push(next)
                return .handled
            }
            return .systemAction
        })
        .confirmationDialog(
            memory.kind == "person" ? "删除该人物档案？" : "忘记这条记忆？",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(memory.kind == "person" ? "删除" : "忘记", role: .destructive) {
                forgetting = true
                Task {
                    defer { forgetting = false }
                    do { try await model.forgetMemory(memory); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text(memory.kind == "person" ? "删除后 Dream 不会再次自动生成该说话人档案。" : "原始录音和聊天记录仍保留。")
        }
        .sheet(item: $source) { source in
            DesktopSourceReader(model: model, source: source, close: { self.source = nil }, onDiscuss: { self.source = nil; dismiss() })
                .frame(width: 600, height: 520)
                .background(MoMoPalette.canvas)
        }
    }
}
