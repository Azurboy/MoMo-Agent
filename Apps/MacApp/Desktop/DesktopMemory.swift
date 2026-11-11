import AppKit
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
    @State private var searching = false
    @State private var searchQuery = ""
    @State private var readingSource: ContextSource?
    @Environment(\.colorScheme) private var scheme

    private var vault: MemoryVaultSnapshot {
        model.vaultSnapshot
    }

    private var filteredTree: MemoryVaultTree {
        vault.filteredTree(matching: searchQuery)
    }

    private func showsSingleFlatCoreOnly(_ tree: MemoryVaultTree) -> Bool {
        tree.rootItems.isEmpty
            && tree.rootFolders.count == 1
            && tree.rootFolders[0].id == "core"
            && tree.rootFolders[0].subfolders.isEmpty
    }

    private func resolvedSelectedMemory(wide: Bool, tree: MemoryVaultTree) -> ContextMemory? {
        if let selectedMemoryID, let direct = vault.byID[selectedMemoryID] {
            return direct
        }
        guard wide else { return nil }
        return tree.flatOrderedItems.first
    }

    private var allFoldersExpanded: Bool {
        let current = expandedFolderIDs ?? vault.tree.defaultExpandedFolderIDs
        return !vault.tree.allFolderIDs.isEmpty && vault.tree.allFolderIDs.isSubset(of: current)
    }

    private func toggleAllFolders() {
        if allFoldersExpanded {
            expandedFolderIDs = []
        } else {
            expandedFolderIDs = vault.tree.allFolderIDs
        }
    }

    private func isFolderExpanded(_ folderID: String) -> Bool {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let current = expandedFolderIDs ?? vault.tree.defaultExpandedFolderIDs
        return current.contains(folderID)
    }

    private func toggleFolder(_ folderID: String) {
        var current = expandedFolderIDs ?? vault.tree.defaultExpandedFolderIDs
        if current.contains(folderID) {
            current.remove(folderID)
        } else {
            current.insert(folderID)
        }
        expandedFolderIDs = current
    }

    private func expandAncestorsIfNeeded(for memory: ContextMemory) {
        let segs = MemoryVaultTree.directorySegments(for: memory)
        guard !segs.isEmpty else { return }
        var current = expandedFolderIDs ?? vault.tree.defaultExpandedFolderIDs
        var changed = false
        var prefix = ""
        for seg in segs {
            prefix = prefix.isEmpty ? seg : "\(prefix)/\(seg)"
            let lowerPrefix = prefix.lowercased()
            for fid in vault.tree.allFolderIDs where fid.lowercased() == lowerPrefix {
                if current.insert(fid).inserted {
                    changed = true
                }
            }
        }
        if changed {
            expandedFolderIDs = current
        }
    }

    private func navigateToNote(_ targetID: String, currentID: String?) {
        guard targetID != currentID else { return }
        if let currentID {
            readerBackStack.append(currentID)
        }
        readerForwardStack.removeAll()
        if let target = vault.byID[targetID] {
            expandAncestorsIfNeeded(for: target)
        }
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

    fileprivate func buildFlatEntries(tree: MemoryVaultTree, activeID: String?) -> [VaultSidebarEntry] {
        let metaByID = vault.rowMetaByID
        var entries: [VaultSidebarEntry] = []
        entries.reserveCapacity(vault.activeMemories.count + tree.allFolderIDs.count)

        for memory in tree.rootItems {
            let meta = metaByID[memory.id]
            entries.append(.note(
                memory: memory,
                title: meta?.title ?? memory.id,
                symbol: meta?.symbol ?? "doc.text",
                shortJournalDate: meta?.shortJournalDate,
                isSelected: activeID == memory.id,
                depth: 0
            ))
        }

        let flatCoreOnly = showsSingleFlatCoreOnly(tree)

        func emitFolder(_ node: MemoryVaultFolderNode, showHeader: Bool) {
            let expanded = !showHeader || isFolderExpanded(node.id)
            if showHeader {
                entries.append(.folder(
                    sectionID: node.id,
                    title: node.name,
                    accentKind: node.accentKind,
                    depth: node.depth,
                    itemCount: node.totalItemCount,
                    isExpanded: expanded
                ))
            }
            guard expanded else { return }

            let childDepth = showHeader ? (node.depth + 1) : 0
            for sub in node.subfolders {
                emitFolder(sub, showHeader: true)
            }
            for memory in node.directItems {
                let meta = metaByID[memory.id]
                entries.append(.note(
                    memory: memory,
                    title: meta?.title ?? memory.id,
                    symbol: meta?.symbol ?? "doc.text",
                    shortJournalDate: meta?.shortJournalDate,
                    isSelected: activeID == memory.id,
                    depth: childDepth
                ))
            }
        }

        for root in tree.rootFolders {
            emitFolder(root, showHeader: !flatCoreOnly)
        }
        return entries
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let tree = filteredTree

        GeometryReader { geometry in
            let totalWidth = max(1, geometry.size.width)
            let totalHeight = max(1, geometry.size.height)
            let wide = totalWidth >= 680
            let active = resolvedSelectedMemory(wide: wide, tree: tree)
            let sidebarWidth: CGFloat = wide ? 268 : totalWidth
            let paneWidth: CGFloat = wide ? max(1, totalWidth - sidebarWidth - 1) : totalWidth

            HStack(spacing: 0) {
                if wide || active == nil {
                    vaultExplorerSidebar(tree: tree, activeID: active?.id)
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
                        tree: tree,
                        wide: wide,
                        colors: colors
                    )
                    .frame(width: paneWidth, height: totalHeight)
                }
            }
        }
        .background(MoMoPalette.paper)
        .task(id: isActive) {
            guard isActive else { return }
            await model.loadContextIfStale(maxAge: 6)
            while !Task.isCancelled {
                let retryDelay: Int = (model.memories.isEmpty && model.memoryError != nil) ? 2 : 8
                do { try await Task.sleep(for: .seconds(retryDelay)) } catch { return }
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

            if !vault.tree.allFolderIDs.isEmpty && !showsSingleFlatCoreOnly(vault.tree) {
                VaultIconButton(
                    symbol: allFoldersExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                    isActive: false,
                    help: allFoldersExpanded ? "全部折叠" : "全部展开",
                    accessibilityLabel: allFoldersExpanded ? "全部折叠" : "全部展开"
                ) {
                    toggleAllFolders()
                }
            }
        }
    }

    private func vaultExplorerSidebar(tree: MemoryVaultTree, activeID: String?) -> some View {
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

            if model.contextLoading && vault.activeMemories.isEmpty {
                ProgressView("正在读取记忆")
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if tree.isEmpty {
                ContentUnavailableView(
                    vault.activeMemories.isEmpty ? "还没有记忆" : "没有匹配的笔记",
                    systemImage: vault.activeMemories.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(vault.activeMemories.isEmpty ? "日常对话与录音沉淀后，MoMo 会在后台自动整理与归档。" : "换个关键词试试。")
                )
                .padding(.top, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                let entries = buildFlatEntries(tree: tree, activeID: activeID)
                MacVaultSidebarListView(
                    entries: entries,
                    revealMemoryID: revealInExplorerID,
                    onConsumedReveal: {
                        if revealInExplorerID != nil {
                            revealInExplorerID = nil
                        }
                    },
                    onToggleFolder: { sectionID in
                        toggleFolder(sectionID)
                    },
                    onActivateNote: { memory in
                        readerBackStack.removeAll()
                        readerForwardStack.removeAll()
                        selectedMemoryID = memory.id
                    },
                    onOpenPopup: { item in
                        inspecting = item
                    },
                    onDelete: { item in
                        deletingMemory = item
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func documentWorkspacePane(
        active: ContextMemory?,
        tree: MemoryVaultTree,
        wide: Bool,
        colors: MemoryNotebookPalette
    ) -> some View {
        if let memory = active {
            let outgoing = vault.childrenByParentID[memory.id] ?? []
            let incoming = vault.backlinksByTargetID[memory.id] ?? []
            let sourceMap = model.transcriptSnapshot.sourceByIDRevision

            let backAction: (() -> Void)? = {
                if let prevID = readerBackStack.last {
                    return {
                        _ = readerBackStack.popLast()
                        readerForwardStack.append(memory.id)
                        if let prev = vault.byID[prevID] {
                            expandAncestorsIfNeeded(for: prev)
                        }
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
                if let next = vault.byID[nextID] {
                    expandAncestorsIfNeeded(for: next)
                }
                selectedMemoryID = nextID
                revealInExplorerID = nextID
            } : nil
            let backText: String? = readerBackStack.isEmpty ? (!wide ? "目录" : nil) : "后退"

            VStack(spacing: 0) {
                DesktopNoteTopBar(
                    memory: memory,
                    backLabel: backText,
                    onBack: backAction,
                    canGoForward: !readerForwardStack.isEmpty,
                    onForward: forwardAction,
                    onDelete: { deletingMemory = memory },
                    onInstruct: model.taskStore != nil ? { prompt in
                        try await Self.dispatchInstruction(prompt, model: model)
                    } : nil,
                    colors: colors
                )

                Rectangle()
                    .fill(MoMoPalette.line.opacity(0.65))
                    .frame(height: 0.6)
                    .accessibilityHidden(true)

                MacNoteDocumentReader(
                    memory: memory,
                    outgoingMemories: outgoing,
                    incomingMemories: incoming,
                    onOpenLink: { url in
                        if url.scheme?.lowercased() == "momoagent", url.host?.lowercased() == "evidence" {
                            if let idx = Int(url.lastPathComponent),
                               memory.evidence.indices.contains(idx) {
                                let ev = memory.evidence[idx]
                                if let src = sourceMap["\(ev.sourceId)|\(ev.sourceRevision)"] {
                                    readingSource = src
                                }
                            }
                            return
                        }
                        if url.scheme?.lowercased() == "momoagent", url.host?.lowercased() == "memory-id" {
                            let targetID = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                            if vault.byID[targetID] != nil, targetID != memory.id {
                                navigateToNote(targetID, currentID: memory.id)
                            }
                            return
                        }
                        if let next = DreamMemoryLinkResolver.resolve(url: url, in: vault.activeMemories), next.id != memory.id {
                            navigateToNote(next.id, currentID: memory.id)
                            return
                        }
                        NSWorkspace.shared.open(url)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(MoMoPalette.paper)
        } else {
            ContentUnavailableView("选择一篇笔记", systemImage: "doc.text", description: Text("从左侧目录点击任一笔记或日志即可阅读。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MoMoPalette.paper)
        }
    }
}

// MARK: - Pinned Top Breadcrumb & Action Bar (Outside ScrollView)

private struct DesktopNoteTopBar: View {
    let memory: ContextMemory
    let backLabel: String?
    let onBack: (() -> Void)?
    let canGoForward: Bool
    let onForward: (() -> Void)?
    let onDelete: () -> Void
    let onInstruct: ((String) async throws -> Void)?
    let colors: MemoryNotebookPalette

    @State private var copied = false
    @State private var showingInstructionBar = false
    @State private var instructionDraft = ""
    @State private var submittingInstruction = false
    @State private var instructionReceipt: String? = nil
    @State private var instructionError: String? = nil

    private func submitInstruction(using handler: @escaping (String) async throws -> Void) {
        let trimmed = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !submittingInstruction else { return }
        let fullPrompt = MemoryCardDigest.buildInstructionPrompt(for: memory, instruction: trimmed)
        submittingInstruction = true
        instructionError = nil
        Task {
            defer { submittingInstruction = false }
            do {
                try await handler(fullPrompt)
                instructionDraft = ""
                showingInstructionBar = false
                instructionReceipt = "已交给 MoMo 修正记忆与说话人（可在首页查看进度，完成后将自动同步）"
            } catch {
                instructionError = error.localizedDescription
            }
        }
    }

    var body: some View {
        let digest = MemoryCardDigest.cached(for: memory)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                if onBack != nil || onForward != nil {
                    HStack(spacing: 2) {
                        Button {
                            onBack?()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(onBack != nil ? colors.ink : colors.secondaryInk.opacity(0.35))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onBack == nil)
                        .help(backLabel ?? "后退")
                        .accessibilityLabel(backLabel ?? "返回")

                        if onForward != nil {
                            Button {
                                onForward?()
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(canGoForward ? colors.ink : colors.secondaryInk.opacity(0.35))
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canGoForward)
                            .help("前进")
                            .accessibilityLabel("前进")
                        }
                    }
                    .padding(.horizontal, 2)
                    .background(colors.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                HStack(spacing: 5) {
                    Image(systemName: DreamMemoryCategory.folderSymbol(for: memory.kind))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.tabAccent(memory.kind))
                    Text(MemoryVaultTree.breadcrumbText(for: memory))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(colors.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(colors.secondaryInk.opacity(0.55))
                    Text(digest.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.ink)
                        .lineLimit(1)
                }
                .accessibilityHidden(true)

                Spacer(minLength: 6)

                if onInstruct != nil {
                    Button {
                        showingInstructionBar.toggle()
                        instructionError = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11, weight: .medium))
                            Text("指令修改")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(showingInstructionBar ? colors.ink : colors.secondaryInk)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(
                            showingInstructionBar ? colors.surface : colors.surface.opacity(0.75),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("通过自然语言指令让 MoMo 修改这篇记忆或纠正说话人")
                    .accessibilityIdentifier("remote.memoryInstructToggle")
                }

                Menu {
                    Button {
                        MemoryCardDigest.copyToPasteboard(memory.text)
                        copied = true
                    } label: {
                        Label(copied ? "已复制 Markdown" : "复制 Markdown", systemImage: "doc.on.doc")
                    }
                    Button {
                        MemoryCardDigest.shareText(memory.text)
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.secondaryInk)
                        .frame(width: 26, height: 26)
                        .background(colors.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
                .accessibilityIdentifier("remote.inlineMemoryMore")
            }

            if showingInstructionBar, let onInstruct {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(colors.tabAccent(memory.kind))
                        TextField("告诉 MoMo 怎么改（如：这个 OKR 是 shengli 说的，帮我纠正说话人和相关记忆）…", text: $instructionDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .disabled(submittingInstruction)
                            .onSubmit {
                                submitInstruction(using: onInstruct)
                            }
                            .accessibilityIdentifier("remote.memoryInstructInput")

                        if submittingInstruction {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                submitInstruction(using: onInstruct)
                            } label: {
                                Text("发送")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? colors.secondaryInk : MoMoPalette.canvas)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? colors.surface
                                            : colors.ink,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("remote.memoryInstructSend")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(colors.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(colors.line, lineWidth: 0.7)
                    }

                    if let instructionError {
                        Text(instructionError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MoMoPalette.failure)
                    }
                }
            } else if let receipt = instructionReceipt {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoMoPalette.success)
                    Text(receipt)
                        .font(.system(size: 12))
                        .foregroundStyle(colors.secondaryInk)
                    Spacer()
                    Button {
                        instructionReceipt = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(colors.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(colors.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .onChange(of: memory.id) {
            instructionError = nil
            instructionReceipt = nil
        }
    }
}

// MARK: - Native AppKit 120fps Vault Sidebar List (NSTableView in NSScrollView)

fileprivate enum VaultSidebarEntry: Identifiable, Equatable {
    case folder(
        sectionID: String,
        title: String,
        accentKind: String,
        depth: Int,
        itemCount: Int,
        isExpanded: Bool
    )
    case note(
        memory: ContextMemory,
        title: String,
        symbol: String,
        shortJournalDate: String?,
        isSelected: Bool,
        depth: Int
    )

    var id: String {
        switch self {
        case .folder(let sectionID, _, _, _, _, _):
            return "folder:\(sectionID)"
        case .note(let memory, _, _, _, _, _):
            return memory.id
        }
    }

    static func == (lhs: VaultSidebarEntry, rhs: VaultSidebarEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.folder(s1, t1, a1, d1, c1, e1), .folder(s2, t2, a2, d2, c2, e2)):
            return s1 == s2 && t1 == t2 && a1 == a2 && d1 == d2 && c1 == c2 && e1 == e2
        case let (.note(m1, t1, sym1, d1, sel1, dep1), .note(m2, t2, sym2, d2, sel2, dep2)):
            return m1.id == m2.id && m1.revision == m2.revision && t1 == t2 && sym1 == sym2
                && d1 == d2 && sel1 == sel2 && dep1 == dep2
        default:
            return false
        }
    }
}

private enum MacVaultPalette {
    static func nsAccent(for kind: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex: UInt32
            switch kind {
            case "briefing": hex = dark ? 0x9C95DC : 0x6B63B5
            case "project": hex = dark ? 0x7BA4CF : 0x4A78A8
            case "journal": hex = dark ? 0x72B59D : 0x3F8A71
            case "person": hex = dark ? 0xCFA082 : 0xA66E4E
            case "topic": hex = dark ? 0x76AAB8 : 0x467F91
            default: hex = dark ? 0x9A9A96 : 0x6E6E6A
            }
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
    }

    static var ink: NSColor { NSColor(named: "PhoneInk") ?? .labelColor }
    static var muted: NSColor { NSColor(named: "PhoneMuted") ?? .secondaryLabelColor }
    static var surface: NSColor { NSColor(named: "PhoneSurface") ?? .quaternaryLabelColor }
    static var line: NSColor { NSColor(named: "PhoneLine") ?? .separatorColor }
}

private final class MacVaultRowCellView: NSTableCellView {
    var entry: VaultSidebarEntry?
    var isHovered: Bool = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with entry: VaultSidebarEntry, hovered: Bool) {
        self.entry = entry
        self.isHovered = hovered
        switch entry {
        case let .folder(sectionID, title, _, _, itemCount, _):
            setAccessibilityLabel("\(title)、\(itemCount)")
            setAccessibilityIdentifier("remote.memoryFolder.\(sectionID)")
        case let .note(memory, title, _, _, _, _):
            setAccessibilityLabel(title)
            setAccessibilityIdentifier("remote.memoryRow.\(memory.id)")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let b = bounds
        let outerInset: CGFloat = 8
        let stepIndent: CGFloat = 14

        switch entry {
        case let .folder(sectionID, title, accentKind, depth, itemCount, isExpanded):
            if depth > 0 {
                MacVaultPalette.line.withAlphaComponent(0.75).setFill()
                for level in 0..<depth {
                    NSRect(x: outerInset + 9 + CGFloat(level) * stepIndent, y: 0, width: 1, height: b.height).fill()
                }
            }
            let indent = CGFloat(depth) * stepIndent
            let pillRect = NSRect(x: outerInset + indent, y: 1.5, width: max(10, b.width - outerInset * 2 - indent), height: max(10, b.height - 2.5))
            if isHovered {
                MacVaultPalette.surface.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6).fill()
            }

            let chevronName = isExpanded ? "chevron.down" : "chevron.right"
            drawSymbol(chevronName, pointSize: 9, weight: .semibold, color: MacVaultPalette.muted.withAlphaComponent(0.85), in: NSRect(x: pillRect.minX + 6, y: pillRect.minY, width: 11, height: pillRect.height))

            let folderSym = DreamMemoryCategory.folderSymbol(for: sectionID, depth: depth)
            drawSymbol(folderSym, pointSize: 11.5, weight: .medium, color: MacVaultPalette.nsAccent(for: accentKind), in: NSRect(x: pillRect.minX + 21, y: pillRect.minY, width: 15, height: pillRect.height))

            let countStr = "\(itemCount)" as NSString
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: MacVaultPalette.muted
            ]
            let countSize = countStr.size(withAttributes: countAttrs)
            let countX = pillRect.maxX - 7 - countSize.width
            countStr.draw(at: NSPoint(x: countX, y: pillRect.midY - countSize.height * 0.5), withAttributes: countAttrs)

            let titleX = pillRect.minX + 40
            let titleWidth = max(10, countX - titleX - 6)
            let weight: NSFont.Weight = depth == 0 ? .semibold : .medium
            drawTruncatedText(title, font: .systemFont(ofSize: 12.5, weight: weight), color: MacVaultPalette.ink.withAlphaComponent(0.9), in: NSRect(x: titleX, y: pillRect.minY, width: titleWidth, height: pillRect.height))

        case let .note(memory, title, symbol, shortJournalDate, isSelected, depth):
            if depth > 0 {
                MacVaultPalette.line.withAlphaComponent(0.75).setFill()
                for level in 0..<depth {
                    NSRect(x: outerInset + 9 + CGFloat(level) * stepIndent, y: 0, width: 1, height: b.height).fill()
                }
            }
            let indent = CGFloat(depth) * stepIndent
            let pillRect = NSRect(x: outerInset + indent, y: 0.5, width: max(10, b.width - outerInset * 2 - indent), height: max(10, b.height - 1))
            if isSelected {
                MacVaultPalette.surface.setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6).fill()
                MacVaultPalette.nsAccent(for: memory.kind).setFill()
                let barRect = NSRect(x: pillRect.minX, y: pillRect.minY + 5, width: 2.5, height: max(4, pillRect.height - 10))
                NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
            } else if isHovered {
                MacVaultPalette.surface.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6).fill()
            }

            let symColor = isSelected ? MacVaultPalette.nsAccent(for: memory.kind) : MacVaultPalette.muted.withAlphaComponent(0.85)
            drawSymbol(symbol, pointSize: 11, weight: .regular, color: symColor, in: NSRect(x: pillRect.minX + 8, y: pillRect.minY, width: 12, height: pillRect.height))

            var rightEdge = pillRect.maxX - 8
            if let date = shortJournalDate {
                let trail = date as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: MacVaultPalette.muted.withAlphaComponent(0.82)
                ]
                let sz = trail.size(withAttributes: attrs)
                rightEdge -= sz.width
                trail.draw(at: NSPoint(x: rightEdge, y: pillRect.midY - sz.height * 0.5), withAttributes: attrs)
                rightEdge -= 5
            }

            let titleX = pillRect.minX + 25
            let titleWidth = max(10, rightEdge - titleX)
            let titleColor = isSelected ? MacVaultPalette.ink : MacVaultPalette.ink.withAlphaComponent(0.88)
            drawTruncatedText(title, font: .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular), color: titleColor, in: NSRect(x: titleX, y: pillRect.minY, width: titleWidth, height: pillRect.height))
        }
    }

    private func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, in box: NSRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let sz = img.size
        let rect = NSRect(
            x: box.midX - sz.width * 0.5,
            y: box.midY - sz.height * 0.5,
            width: sz.width,
            height: sz.height
        )
        img.draw(in: rect)
    }

    private func drawTruncatedText(_ string: String, font: NSFont, color: NSColor, in box: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let ns = string as NSString
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let rect = NSRect(x: box.minX, y: floor(box.midY - lineH * 0.5), width: box.width, height: lineH + 2)
        ns.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

private final class MacVaultNSTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var onRowPrimaryClick: ((Int) -> Void)?
    var hoveredRow: Int = -1
    var isLiveScrollingNow: Bool = false
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func setHoveredRow(_ next: Int) {
        guard hoveredRow != next else { return }
        let old = hoveredRow
        hoveredRow = next
        if old >= 0, old < numberOfRows, let oldCell = view(atColumn: 0, row: old, makeIfNecessary: false) as? MacVaultRowCellView {
            oldCell.isHovered = false
        }
        if next >= 0, next < numberOfRows, let newCell = view(atColumn: 0, row: next, makeIfNecessary: false) as? MacVaultRowCellView {
            newCell.isHovered = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isLiveScrollingNow else { return }
        let pt = convert(event.locationInWindow, from: nil)
        setHoveredRow(row(at: pt))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(-1)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let clicked = row(at: pt)
        if clicked >= 0, event.modifierFlags.intersection([.control]).isEmpty {
            onRowPrimaryClick?(clicked)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let clicked = row(at: pt)
        guard clicked >= 0 else { return nil }
        return contextMenuProvider?(clicked)
    }
}

private struct MacVaultSidebarListView: NSViewRepresentable {
    let entries: [VaultSidebarEntry]
    let revealMemoryID: String?
    let onConsumedReveal: () -> Void
    let onToggleFolder: (String) -> Void
    let onActivateNote: (ContextMemory) -> Void
    let onOpenPopup: (ContextMemory) -> Void
    let onDelete: (ContextMemory) -> Void

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var entries: [VaultSidebarEntry] = []
        var onToggleFolder: (String) -> Void
        var onActivateNote: (ContextMemory) -> Void
        var onOpenPopup: (ContextMemory) -> Void
        var onDelete: (ContextMemory) -> Void
        weak var tableView: MacVaultNSTableView?
        private var scrollObservers: [NSObjectProtocol] = []

        init(
            onToggleFolder: @escaping (String) -> Void,
            onActivateNote: @escaping (ContextMemory) -> Void,
            onOpenPopup: @escaping (ContextMemory) -> Void,
            onDelete: @escaping (ContextMemory) -> Void
        ) {
            self.onToggleFolder = onToggleFolder
            self.onActivateNote = onActivateNote
            self.onOpenPopup = onOpenPopup
            self.onDelete = onDelete
        }

        deinit {
            for obs in scrollObservers {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func bindScrollNotifications(scrollView: NSScrollView, tableView: MacVaultNSTableView) {
            let nc = NotificationCenter.default
            scrollObservers.append(
                nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak tableView] _ in
                    MainActor.assumeIsolated {
                        tableView?.isLiveScrollingNow = true
                        tableView?.setHoveredRow(-1)
                    }
                }
            )
            scrollObservers.append(
                nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak tableView] _ in
                    MainActor.assumeIsolated {
                        tableView?.isLiveScrollingNow = false
                    }
                }
            )
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard entries.indices.contains(row) else { return 28 }
            switch entries[row] {
            case let .folder(_, _, _, depth, _, _): return depth == 0 ? 30 : 28
            case .note: return 28
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("VaultRowCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? MacVaultRowCellView) ?? {
                let c = MacVaultRowCellView(frame: .zero)
                c.identifier = id
                return c
            }()
            let hovered = (tableView as? MacVaultNSTableView)?.hoveredRow == row
            cell.configure(with: entries[row], hovered: hovered)
            return cell
        }

        func shouldSelectRow(_ row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        func handlePrimaryClick(row: Int) {
            guard entries.indices.contains(row) else { return }
            switch entries[row] {
            case let .folder(sectionID, _, _, _, _, _):
                onToggleFolder(sectionID)
            case let .note(memory, _, _, _, _, _):
                onActivateNote(memory)
            }
        }

        func buildContextMenu(for row: Int) -> NSMenu? {
            guard entries.indices.contains(row) else { return nil }
            let targetMemory: ContextMemory
            switch entries[row] {
            case .folder:
                return nil
            case let .note(memory, _, _, _, _, _):
                targetMemory = memory
            }
            let menu = NSMenu()
            let copyItem = NSMenuItem(title: "复制 Markdown", action: #selector(contextCopy(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = targetMemory
            menu.addItem(copyItem)

            let popupItem = NSMenuItem(title: "在独立窗口预览", action: #selector(contextOpenPopup(_:)), keyEquivalent: "")
            popupItem.target = self
            popupItem.representedObject = targetMemory
            menu.addItem(popupItem)

            menu.addItem(.separator())

            let deleteTitle = targetMemory.kind == "person" ? "删除该人物" : "忘记这条记忆"
            let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(contextDelete(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = targetMemory
            menu.addItem(deleteItem)
            return menu
        }

        @objc private func contextCopy(_ sender: NSMenuItem) {
            guard let mem = sender.representedObject as? ContextMemory else { return }
            MemoryCardDigest.copyToPasteboard(mem.text)
        }

        @objc private func contextOpenPopup(_ sender: NSMenuItem) {
            guard let mem = sender.representedObject as? ContextMemory else { return }
            onOpenPopup(mem)
        }

        @objc private func contextDelete(_ sender: NSMenuItem) {
            guard let mem = sender.representedObject as? ContextMemory else { return }
            onDelete(mem)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onToggleFolder: onToggleFolder,
            onActivateNote: onActivateNote,
            onOpenPopup: onOpenPopup,
            onDelete: onDelete
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 18, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false

        let tableView = MacVaultNSTableView()
        tableView.style = .plain
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("VaultMainColumn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        let coord = context.coordinator
        coord.entries = entries
        coord.tableView = tableView
        tableView.dataSource = coord
        tableView.delegate = coord
        tableView.onRowPrimaryClick = { [weak coord] row in
            coord?.handlePrimaryClick(row: row)
        }
        tableView.contextMenuProvider = { [weak coord] row in
            coord?.buildContextMenu(for: row)
        }

        scrollView.documentView = tableView
        coord.bindScrollNotifications(scrollView: scrollView, tableView: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.onToggleFolder = onToggleFolder
        coord.onActivateNote = onActivateNote
        coord.onOpenPopup = onOpenPopup
        coord.onDelete = onDelete

        guard let tableView = coord.tableView else { return }
        if coord.entries != entries {
            let oldEntries = coord.entries
            coord.entries = entries
            if oldEntries.count == entries.count,
               zip(oldEntries, entries).allSatisfy({ $0.id == $1.id }) {
                // Only selection/title changed in-place: update visible cells in O(visible) without touching scroll position!
                let visibleRange = tableView.rows(in: tableView.visibleRect)
                if visibleRange.length > 0 {
                    for row in visibleRange.location..<NSMaxRange(visibleRange) where entries.indices.contains(row) {
                        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MacVaultRowCellView {
                            cell.configure(with: entries[row], hovered: tableView.hoveredRow == row)
                        }
                    }
                }
            } else {
                tableView.reloadData()
            }
        }

        if let targetID = revealMemoryID {
            if let idx = entries.firstIndex(where: { entry in
                switch entry {
                case .folder: return false
                case .note(let m, _, _, _, _, _): return m.id == targetID
                }
            }) {
                tableView.scrollRowToVisible(idx)
            }
            DispatchQueue.main.async {
                onConsumedReveal()
            }
        }
    }
}

// MARK: - Native AppKit 120fps Tiled Note Document Reader (NSTextView as NSScrollView.documentView)

private enum MacFullNoteComposer {
    final class ComposedNote: NSObject, @unchecked Sendable {
        let key: String
        let memoryID: String
        let attributedString: NSAttributedString
        let quoteCharRanges: [NSRange]
        let ruleCharIndices: [Int]

        init(
            key: String,
            memoryID: String,
            attributedString: NSAttributedString,
            quoteCharRanges: [NSRange],
            ruleCharIndices: [Int]
        ) {
            self.key = key
            self.memoryID = memoryID
            self.attributedString = attributedString
            self.quoteCharRanges = quoteCharRanges
            self.ruleCharIndices = ruleCharIndices
        }
    }

    private nonisolated(unsafe) static let cache: NSCache<NSString, ComposedNote> = {
        let c = NSCache<NSString, ComposedNote>()
        c.countLimit = 256
        return c
    }()

    private static let linkColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.54, green: 0.73, blue: 0.93, alpha: 1.0)
            : NSColor(srgbRed: 0.18, green: 0.39, blue: 0.62, alpha: 1.0)
    }

    static func compose(
        memory: ContextMemory,
        outgoing: [ContextMemory],
        incoming: [ContextMemory]
    ) -> ComposedNote {
        var hasher = Hasher()
        hasher.combine(memory.id)
        hasher.combine(memory.revision)
        hasher.combine(memory.text.utf8.count)
        hasher.combine(outgoing.map(\.id))
        hasher.combine(incoming.map(\.id))
        let key = "\(memory.id)|\(memory.revision)|\(outgoing.count)|\(incoming.count)|\(hasher.finalize())"
        let nsKey = key as NSString
        if let hit = cache.object(forKey: nsKey) {
            return hit
        }

        let digest = MemoryCardDigest.cached(for: memory)
        let ink = MacVaultPalette.ink
        let muted = MacVaultPalette.muted

        let result = NSMutableAttributedString()
        var shiftedQuotes: [NSRange] = []
        var ruleIndices: [Int] = []

        // 1. Clean Obsidian-style Inline H1 Title + Quiet Optional Date
        let hasSeparateDate = (digest.dateBadge != nil) && !digest.title.contains(digest.dateBadge!)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineSpacing = 4
        titleStyle.paragraphSpacing = hasSeparateDate ? 6 : 20
        result.append(NSAttributedString(
            string: digest.title + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: ink,
                .paragraphStyle: titleStyle
            ]
        ))

        if let date = digest.dateBadge, hasSeparateDate {
            let dateStyle = NSMutableParagraphStyle()
            dateStyle.lineSpacing = 3
            dateStyle.paragraphSpacing = 18
            result.append(NSAttributedString(
                string: date + "\n",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: muted,
                    .paragraphStyle: dateStyle
                ]
            ))
        }
        ruleIndices.append(max(0, result.length - 1))

        // 3. Main Markdown Body
        let bodyMarkdown = digest.isNotebookMarkdown ? digest.cleanedNotebookMarkdown : memory.text
        let bodyRendered = MacMarkdownRenderer.render(
            markdown: bodyMarkdown,
            handwriting: true,
            plainTextOnly: !digest.isNotebookMarkdown
        )
        let bodyOffset = result.length
        result.append(bodyRendered.attributedString)
        for qr in bodyRendered.quoteCharRanges {
            shiftedQuotes.append(NSRange(location: qr.location + bodyOffset, length: qr.length))
        }

        // 4. Bidirectional Links & Evidence Footer
        let hasFooter = !outgoing.isEmpty || !digest.linkedPaths.isEmpty || !incoming.isEmpty || !memory.evidence.isEmpty
        if hasFooter {
            let sepStyle = NSMutableParagraphStyle()
            sepStyle.paragraphSpacingBefore = 18
            sepStyle.paragraphSpacing = 14
            result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: sepStyle]))
            ruleIndices.append(max(0, result.length - 1))

            let secHeaderStyle = NSMutableParagraphStyle()
            secHeaderStyle.paragraphSpacingBefore = 10
            secHeaderStyle.paragraphSpacing = 5

            // Outgoing Links
            if !outgoing.isEmpty {
                result.append(NSAttributedString(
                    string: "↗ 关联笔记  \(outgoing.count)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                        .foregroundColor: muted,
                        .paragraphStyle: secHeaderStyle
                    ]
                ))
                let outStyle = NSMutableParagraphStyle()
                outStyle.lineSpacing = 5
                outStyle.paragraphSpacing = 10
                let line = NSMutableAttributedString()
                for (idx, item) in outgoing.enumerated() {
                    if idx > 0 {
                        line.append(NSAttributedString(
                            string: "    ",
                            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: muted, .paragraphStyle: outStyle]
                        ))
                    }
                    let targetTitle = MemoryCardDigest.cached(for: item).title
                    let encodedID = item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.id
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                        .foregroundColor: linkColor,
                        .paragraphStyle: outStyle
                    ]
                    if let url = URL(string: "momoagent://memory-id/\(encodedID)") {
                        attrs[.link] = url
                    }
                    line.append(NSAttributedString(string: targetTitle, attributes: attrs))
                }
                line.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: outStyle]))
                result.append(line)
            } else if !digest.linkedPaths.isEmpty {
                result.append(NSAttributedString(
                    string: "↗ 关联笔记  \(digest.linkedPaths.count)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                        .foregroundColor: muted,
                        .paragraphStyle: secHeaderStyle
                    ]
                ))
                let outStyle = NSMutableParagraphStyle()
                outStyle.lineSpacing = 5
                outStyle.paragraphSpacing = 10
                let line = NSMutableAttributedString()
                for (idx, relPath) in digest.linkedPaths.enumerated() {
                    if idx > 0 {
                        line.append(NSAttributedString(string: "    ", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: outStyle]))
                    }
                    let friendly = MemoryCardDigest.humanizeNotebookPath(relPath)
                    let encoded = relPath
                        .split(separator: "/")
                        .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                        .joined(separator: "/")
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                        .foregroundColor: linkColor,
                        .paragraphStyle: outStyle
                    ]
                    if let url = URL(string: "momoagent://memory/\(encoded)") {
                        attrs[.link] = url
                    }
                    line.append(NSAttributedString(string: friendly, attributes: attrs))
                }
                line.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: outStyle]))
                result.append(line)
            }

            // Backlinks (Linked Mentions)
            if !incoming.isEmpty {
                result.append(NSAttributedString(
                    string: "↩ 反向链接 · 被以下笔记提及  \(incoming.count)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                        .foregroundColor: muted,
                        .paragraphStyle: secHeaderStyle
                    ]
                ))
                for backlink in incoming {
                    let bDigest = MemoryCardDigest.cached(for: backlink)
                    let encodedID = backlink.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? backlink.id
                    let titleRowStyle = NSMutableParagraphStyle()
                    titleRowStyle.paragraphSpacingBefore = 4
                    titleRowStyle.paragraphSpacing = bDigest.highlights.isEmpty ? 6 : 2

                    let itemStr = NSMutableAttributedString()
                    var linkAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: linkColor,
                        .paragraphStyle: titleRowStyle
                    ]
                    if let url = URL(string: "momoagent://memory-id/\(encodedID)") {
                        linkAttrs[.link] = url
                    }
                    itemStr.append(NSAttributedString(string: "[[\(bDigest.title)]]", attributes: linkAttrs))
                    itemStr.append(NSAttributedString(
                        string: "   \(bDigest.badge.title)\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                            .foregroundColor: muted,
                            .paragraphStyle: titleRowStyle
                        ]
                    ))
                    result.append(itemStr)

                    if let snippet = bDigest.highlights.first, !snippet.isEmpty {
                        let snipStyle = NSMutableParagraphStyle()
                        snipStyle.firstLineHeadIndent = 10
                        snipStyle.headIndent = 10
                        snipStyle.lineSpacing = 3
                        snipStyle.paragraphSpacing = 8
                        let clipped = snippet.count > 120 ? String(snippet.prefix(120)) + "…" : snippet
                        result.append(NSAttributedString(
                            string: clipped + "\n",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                                .foregroundColor: muted,
                                .paragraphStyle: snipStyle
                            ]
                        ))
                    }
                }
            }

            // Evidence links
            if !memory.evidence.isEmpty {
                result.append(NSAttributedString(
                    string: "⏱ 原音证据  \(memory.evidence.count)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                        .foregroundColor: muted,
                        .paragraphStyle: secHeaderStyle
                    ]
                ))
                let evStyle = NSMutableParagraphStyle()
                evStyle.lineSpacing = 4
                evStyle.paragraphSpacing = 6
                for (idx, ev) in memory.evidence.enumerated() {
                    let quoteSnippet = ev.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                    let shortQuote = quoteSnippet.count > 80 ? String(quoteSnippet.prefix(80)) + "…" : quoteSnippet
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: linkColor,
                        .paragraphStyle: evStyle
                    ]
                    if let url = URL(string: "momoagent://evidence/\(idx)") {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: "• 「\(shortQuote)」  [查看原音]\n", attributes: attrs))
                }
            }
        }

        let composed = ComposedNote(
            key: key,
            memoryID: memory.id,
            attributedString: result,
            quoteCharRanges: shiftedQuotes,
            ruleCharIndices: ruleIndices
        )
        cache.setObject(composed, forKey: nsKey)
        return composed
    }
}

private final class MacNoteDocumentTextView: NSTextView {
    var currentComposedKey: String = ""
    var currentMemoryID: String = ""
    var quoteCharRanges: [NSRange] = []
    var ruleCharIndices: [Int] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        let origin = textContainerOrigin
        let totalLen = ts.length
        let lineColor = MacVaultPalette.line

        if !ruleCharIndices.isEmpty {
            lineColor.withAlphaComponent(0.75).setFill()
            for charIdx in ruleCharIndices where charIdx >= 0 && charIdx < totalLen {
                let gIdx = lm.glyphIndexForCharacter(at: charIdx)
                let lineRect = lm.lineFragmentRect(forGlyphAt: gIdx, effectiveRange: nil)
                let y = origin.y + lineRect.maxY + 10
                let ruleRect = NSRect(x: origin.x, y: y, width: tc.containerSize.width, height: 0.7)
                if ruleRect.intersects(dirtyRect) {
                    ruleRect.fill()
                }
            }
        }

        if !quoteCharRanges.isEmpty {
            lineColor.setFill()
            for charRange in quoteCharRanges where charRange.location >= 0 && NSMaxRange(charRange) <= totalLen {
                let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                guard rect.height > 1 else { continue }
                let barRect = NSRect(
                    x: origin.x + 0.5,
                    y: origin.y + rect.minY + 1,
                    width: 2.5,
                    height: max(4, rect.height - 2)
                )
                if barRect.intersects(dirtyRect) {
                    NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
                }
            }
        }
    }
}

private final class MacNoteDocumentScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tv = documentView as? MacNoteDocumentTextView else { return }
        let vw = max(220, contentView.bounds.width)
        let readableWidth = max(180, min(740, floor(vw - 88)))
        let sideInset = max(28, floor((vw - readableWidth) * 0.5))
        if abs(tv.textContainerInset.width - sideInset) >= 0.5 || abs(tv.textContainerInset.height - 26) >= 0.5 {
            tv.textContainerInset = NSSize(width: sideInset, height: 26)
        }
        if abs(tv.frame.width - vw) >= 0.5 {
            tv.setFrameSize(NSSize(width: vw, height: tv.frame.height))
        }
    }
}

private struct MacNoteDocumentReader: NSViewRepresentable {
    let memory: ContextMemory
    let outgoingMemories: [ContextMemory]
    let incomingMemories: [ContextMemory]
    let onOpenLink: (URL) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenLink: (URL) -> Void
        weak var textView: MacNoteDocumentTextView?

        init(onOpenLink: @escaping (URL) -> Void) {
            self.onOpenLink = onOpenLink
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                onOpenLink(url)
                return true
            }
            if let str = link as? String, let url = URL(string: str) {
                onOpenLink(url)
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenLink: onOpenLink)
    }

    func makeNSView(context: Context) -> MacNoteDocumentScrollView {
        let scrollView = MacNoteDocumentScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = MacNoteDocumentTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.textContainerInset = NSSize(width: 44, height: 26)
        textView.textContainer?.containerSize = NSSize(width: 552, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityIdentifier("remote.memoryText")
        textView.delegate = context.coordinator

        context.coordinator.textView = textView
        scrollView.documentView = textView
        apply(to: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: MacNoteDocumentScrollView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView, in: scrollView)
    }

    private func apply(to textView: MacNoteDocumentTextView, in scrollView: MacNoteDocumentScrollView) {
        let composed = MacFullNoteComposer.compose(
            memory: memory,
            outgoing: outgoingMemories,
            incoming: incomingMemories
        )
        guard textView.currentComposedKey != composed.key else { return }
        let noteChanged = textView.currentMemoryID != composed.memoryID
        textView.currentComposedKey = composed.key
        textView.currentMemoryID = composed.memoryID
        textView.quoteCharRanges = composed.quoteCharRanges
        textView.ruleCharIndices = composed.ruleCharIndices
        if textView.selectedRange().length > 0 {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.textStorage?.setAttributedString(composed.attributedString)
        textView.needsDisplay = true
        if noteChanged {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

// MARK: - Small Toolbar Icon Button

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
                .background(isActive ? MoMoPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
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

// MARK: - Secondary Popup Detail Sheet

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
