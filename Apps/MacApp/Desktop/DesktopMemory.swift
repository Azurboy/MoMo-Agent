import SwiftUI
import WebKit
import MoMoAgentClient

struct DesktopMemory: View {
    @Bindable var model: DesktopModel
    @State private var listMode = true
    @State private var selectedMemoryID: String? = nil
    @State private var readerBackStack: [String] = []
    @State private var inspecting: ContextMemory?
    @State private var deletingMemory: ContextMemory?
    @State private var expandedFolderIDs: Set<String>? = nil
    @State private var collapsedParentIDs: Set<String> = []
    @State private var searching = false
    @State private var searchQuery = ""
    @State private var readingSource: ContextSource?
    @State private var webFailure: String?
    @State private var dreamRequesting = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorScheme) private var scheme

    private var allMemories: [ContextMemory] {
        model.memories.filter { $0.status != "forgotten" }
    }

    private var directoryFolders: [DreamMemorySection] {
        DreamMemoryCategory.directoryFolders(from: allMemories)
    }

    private var filteredFolders: [DreamMemorySection] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return directoryFolders }
        return directoryFolders.compactMap { folder in
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

    private func resolvedSelectedMemory(wide: Bool) -> ContextMemory? {
        let visibleItems = filteredFolders.flatMap(\.items)
        guard !visibleItems.isEmpty else { return nil }
        if let selectedMemoryID {
            if let direct = visibleItems.first(where: { $0.id == selectedMemoryID }) {
                return direct
            }
            if let anyMatch = allMemories.first(where: { $0.id == selectedMemoryID }) {
                return anyMatch
            }
        }
        return wide ? visibleItems.first : nil
    }

    private func siblingItems(for memory: ContextMemory) -> [ContextMemory] {
        if let folder = filteredFolders.first(where: { $0.items.contains(where: { $0.id == memory.id }) }),
           folder.items.count > 1 {
            return folder.items
        }
        let allVisible = filteredFolders.flatMap(\.items)
        return allVisible.count > 1 ? allVisible : [memory]
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
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedFolderIDs = current
        }
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let inStarMap = !listMode && !reducedMotion && webFailure == nil && !allMemories.isEmpty

        Group {
            if inStarMap {
                VStack(spacing: 0) {
                    headerToolbar(wide: true)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 10)
                    Divider()
                    MoMoMemoryGraphView(
                        memories: allMemories,
                        inspect: { id in inspecting = allMemories.first { $0.id == id } },
                        failure: { webFailure = $0 }
                    )
                }
            } else {
                GeometryReader { geometry in
                    let wide = geometry.size.width >= 700
                    let active = resolvedSelectedMemory(wide: wide)
                    HStack(spacing: 0) {
                        if wide || active == nil {
                            outlineSidebar(wide: wide, activeID: active?.id, colors: colors)
                                .frame(width: wide ? 296 : nil)
                                .frame(maxWidth: wide ? nil : .infinity)
                        }
                        if wide {
                            Divider()
                        }
                        if wide || active != nil {
                            readerPane(active: active, wide: wide, colors: colors)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .background(MoMoPalette.canvas)
        .task {
            await model.loadContext()
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
                    Task { try? await model.forgetMemory(target) }
                }
            }
        } message: {
            Text(deletingMemory?.kind == "person"
                 ? "删除后 Dream 不会再次自动生成该说话人档案。"
                 : "原始录音和聊天记录仍保留。")
        }
    }

    private func headerToolbar(wide: Bool) -> some View {
        HStack(spacing: 10) {
            Text("记忆")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(MoMoPalette.ink)
                .accessibilityAddTraits(.isHeader)

            if !allMemories.isEmpty {
                Text("\(allMemories.count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(MoMoPalette.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(MoMoPalette.surface, in: Capsule())
            }

            Spacer(minLength: 4)

            if listMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        searching.toggle()
                        if !searching { searchQuery = "" }
                    }
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(MoMoPalette.ink)
                .help(searching ? "关闭搜索" : "搜索记忆")
                .accessibilityLabel(searching ? "关闭搜索" : "搜索记忆")
            }

            Button {
                dreamRequesting = true
                Task {
                    defer { dreamRequesting = false }
                    try? await model.triggerDream()
                }
            } label: {
                Image(systemName: "sparkles")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(MoMoPalette.ink)
            .help("立即执行 Dream 闲时深度整理")
            .accessibilityLabel("立即 Dream 整理")
            .accessibilityIdentifier("settings.memory.dream")
            .disabled(model.contextLoading || dreamRequesting || model.memoryReviewStatus?.running == true)

            Button {
                listMode.toggle()
            } label: {
                Image(systemName: listMode ? "circle.hexagongrid" : "sidebar.left")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(MoMoPalette.ink)
            .accessibilityLabel(listMode ? "星图" : "目录")
            .accessibilityIdentifier("settings.memory.view")
            .disabled(reducedMotion)
            .help(reducedMotion ? "减少动态效果时使用目录视图" : (listMode ? "切换到记忆星图" : "切换到手账目录"))

            Button {
                Task { await model.loadContext() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(MoMoPalette.ink)
            .help("刷新记忆")
            .accessibilityLabel("刷新")
            .accessibilityIdentifier("settings.memory.refresh")
            .disabled(model.contextLoading)
        }
    }

    private func outlineSidebar(wide: Bool, activeID: String?, colors: MemoryNotebookPalette) -> some View {
        VStack(spacing: 12) {
            headerToolbar(wide: wide)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(MoMoPalette.muted)
                    TextField("搜索项目、简报、人物或记忆…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(MoMoPalette.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 16)
            }

            if let error = model.memoryError ?? webFailure {
                HStack(spacing: 8) {
                    Text(error)
                        .phoneText(.caption)
                        .foregroundStyle(MoMoPalette.failure)
                        .lineLimit(2)
                    Spacer()
                    Button("重试") {
                        webFailure = nil
                        Task { await model.loadContext() }
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 20)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if model.contextLoading && allMemories.isEmpty {
                        ProgressView("正在读取记忆")
                            .padding(32)
                            .frame(maxWidth: .infinity)
                    } else if filteredFolders.isEmpty {
                        ContentUnavailableView(
                            allMemories.isEmpty ? "还没有记忆" : "没有匹配的记录",
                            systemImage: allMemories.isEmpty ? "book.closed" : "magnifyingglass",
                            description: Text(allMemories.isEmpty ? "轻触右上角即可整理或刷新。" : "换个关键词试试。")
                        )
                        .padding(.top, 32)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(filteredFolders) { section in
                                let expanded = isFolderExpanded(section.id)
                                VStack(alignment: .leading, spacing: 2) {
                                    if filteredFolders.count > 1 || section.id != "core" {
                                        Button {
                                            toggleFolder(section.id)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: DreamMemoryCategory.folderSymbol(for: section.id))
                                                    .font(.system(size: 11.5, weight: .medium))
                                                    .foregroundStyle(colors.tabAccent(section.id))
                                                    .frame(width: 15)
                                                Text(section.title)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(MoMoPalette.muted)
                                                Spacer(minLength: 4)
                                                Text("\(section.items.count)")
                                                    .font(.system(size: 11, weight: .regular))
                                                    .monospacedDigit()
                                                    .foregroundStyle(MoMoPalette.muted)
                                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                                    .font(.system(size: 9.5, weight: .semibold))
                                                    .foregroundStyle(MoMoPalette.muted.opacity(0.75))
                                                    .frame(width: 12)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("remote.memoryFolder.\(section.id)")
                                    }

                                    if expanded {
                                        ForEach(section.items) { memory in
                                            outlineItemTree(memory: memory, activeID: activeID, colors: colors)
                                                .id(memory.id)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 24)
                    }
                }
                .onChange(of: activeID) {
                    guard let activeID else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(activeID)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func outlineItemTree(memory: ContextMemory, activeID: String?, colors: MemoryNotebookPalette) -> some View {
        let childMemories = MemoryCardDigest.linkedChildren(for: memory, in: allMemories)
        let isParentExpanded = !collapsedParentIDs.contains(memory.id)

        VStack(alignment: .leading, spacing: 2) {
            DesktopOutlineRow(
                memory: memory,
                isSelected: activeID == memory.id,
                childCount: childMemories.count,
                isExpanded: isParentExpanded,
                accent: colors.tabAccent(memory.kind),
                onSelect: {
                    readerBackStack.removeAll()
                    selectedMemoryID = memory.id
                },
                onToggleChildren: childMemories.isEmpty ? nil : {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isParentExpanded {
                            collapsedParentIDs.insert(memory.id)
                        } else {
                            collapsedParentIDs.remove(memory.id)
                        }
                    }
                },
                onDelete: { deletingMemory = memory }
            )

            if !childMemories.isEmpty && isParentExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(childMemories) { child in
                        DesktopOutlineChildRow(
                            child: child,
                            isSelected: activeID == child.id,
                            onSelect: {
                                readerBackStack.removeAll()
                                selectedMemoryID = child.id
                            },
                            onDelete: { deletingMemory = child }
                        )
                    }
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MoMoPalette.line)
                        .frame(width: 1.5)
                        .padding(.leading, 14)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func readerPane(active: ContextMemory?, wide: Bool, colors: MemoryNotebookPalette) -> some View {
        if let memory = active {
            let siblings = siblingItems(for: memory)
            let backAction: (() -> Void)? = {
                if let prevID = readerBackStack.last {
                    return {
                        _ = readerBackStack.popLast()
                        selectedMemoryID = prevID
                    }
                }
                if !wide {
                    return { selectedMemoryID = nil }
                }
                return nil
            }()
            let backText: String? = readerBackStack.isEmpty ? (!wide ? "目录" : nil) : "返回"

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ClientMemoryContent(
                        memory: memory,
                        siblingItems: siblings,
                        onSelectSibling: { next in
                            readerBackStack.removeAll()
                            selectedMemoryID = next.id
                        },
                        backLabel: backText,
                        onBack: backAction,
                        onDelete: { deletingMemory = memory }
                    )
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if let next = DreamMemoryLinkResolver.resolve(url: url, in: allMemories), next.id != memory.id {
                            readerBackStack.append(memory.id)
                            selectedMemoryID = next.id
                            return .handled
                        }
                        return .systemAction
                    })

                    let matchingSources = memory.evidence.compactMap { ev in
                        model.sources.first(where: { $0.id == ev.sourceId && $0.revision == ev.sourceRevision })
                    }
                    if !matchingSources.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(matchingSources) { rec in
                                Button {
                                    readingSource = rec
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "waveform")
                                            .font(.system(size: 11, weight: .medium))
                                        Text("查看原始转录")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(MoMoPalette.ink)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(MoMoPalette.surface, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        } else {
            ContentUnavailableView(
                allMemories.isEmpty ? "还没有记忆" : "选择一页手账",
                systemImage: "book.pages",
                description: Text(allMemories.isEmpty ? "日常对话与录音经整理后会归档在这里。" : "从左侧目录选择项目、简报或人物档案。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DesktopOutlineRow: View {
    let memory: ContextMemory
    let isSelected: Bool
    let childCount: Int
    let isExpanded: Bool
    let accent: Color
    let onSelect: () -> Void
    let onToggleChildren: (() -> Void)?
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        let digest = MemoryCardDigest.cached(for: memory)
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isSelected ? MoMoPalette.ink : accent)
                        .frame(width: 5.5, height: 5.5)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(digest.title)
                            .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(MoMoPalette.ink)
                            .lineLimit(1)

                        if let date = digest.dateBadge {
                            Text(date)
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(MoMoPalette.muted)
                        } else if let preview = digest.highlights.first {
                            Text(preview)
                                .font(.system(size: 11.5))
                                .foregroundStyle(MoMoPalette.muted)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("remote.memoryRow." + memory.id)

            if let onToggleChildren, childCount > 0 {
                Button(action: onToggleChildren) {
                    HStack(spacing: 2.5) {
                        Text("\(childCount)")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    .foregroundStyle(MoMoPalette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(MoMoPalette.canvas.opacity(isSelected ? 0.8 : 0), in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起关联页面" : "展开关联页面")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected
                ? MoMoPalette.surface
                : (isHovered ? MoMoPalette.surface.opacity(0.55) : .clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive, action: onDelete)
        }
    }
}

private struct DesktopOutlineChildRow: View {
    let child: ContextMemory
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        let digest = MemoryCardDigest.cached(for: child)
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Text(digest.title)
                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? MoMoPalette.ink : MoMoPalette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(digest.badge.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(MoMoPalette.muted.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? MoMoPalette.surface
                : (isHovered ? MoMoPalette.surface.opacity(0.5) : .clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(child.kind == "person" ? "删除该人物" : "忘记这条记忆", role: .destructive, action: onDelete)
        }
    }
}

private struct DesktopMemoryDetail: View {
    let model: DesktopModel
    @State var memory: ContextMemory
    @State private var navigationStack: [ContextMemory] = []
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var forgetting = false
    @State private var error: String?
    @State private var source: ContextSource?

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

    var body: some View {
        let backAction: (() -> Void)? = navigationStack.last.map { prev in
            {
                _ = navigationStack.popLast()
                memory = prev
            }
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ClientMemoryContent(
                    memory: memory,
                    siblingItems: siblingMemories,
                    onSelectSibling: {
                        navigationStack.removeAll()
                        memory = $0
                    },
                    backLabel: "返回",
                    onBack: backAction,
                    onDelete: { confirming = true },
                    onClose: { dismiss() }
                )
                .textSelection(.enabled)

                ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                    if let recording = model.sources.first(where: { $0.id == evidence.sourceId && $0.revision == evidence.sourceRevision }) {
                        Button("查看录音原文", systemImage: "waveform") { source = recording }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.leading, 6)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(MoMoPalette.failure).padding(.horizontal, 6)
                }
            }
            .padding(12)
        }
        .frame(width: 520, height: 470)
        .background(MoMoPalette.canvas)
        .environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: model.memories), next.id != memory.id {
                navigationStack.append(memory)
                memory = next
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
