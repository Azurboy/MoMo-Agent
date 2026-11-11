import SwiftUI
import MoMoAgentClient

struct RemoteMemoryView: View {
    let sync: PhoneContextSync
    var taskStore: RemoteTaskStore? = nil
    var onSelectBriefingCard: ((DreamBriefingCard) -> Void)? = nil
    @State private var forgetting: ContextMemory?
    @State private var searchQuery = ""
    @State private var expandedFolderIDs: Set<String>? = nil
    @Environment(\.colorScheme) private var scheme

    private var allMemories: [ContextMemory] { sync.memories.filter { $0.status != "forgotten" } }

    private var directoryFolders: [DreamMemorySection] {
        DreamMemoryCategory.directoryFolders(from: allMemories)
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sections: [DreamMemorySection] {
        let q = trimmedQuery
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

    private var allFoldersExpanded: Bool {
        let current = expandedFolderIDs ?? DreamMemoryCategory.defaultExpandedFolderIDs(for: directoryFolders)
        return !directoryFolders.isEmpty && directoryFolders.allSatisfy { current.contains($0.id) }
    }

    private func toggleAllFolders() {
        withAnimation(.easeInOut(duration: 0.16)) {
            if allFoldersExpanded {
                expandedFolderIDs = []
            } else {
                expandedFolderIDs = DreamMemoryCategory.defaultExpandedFolderIDs(for: directoryFolders)
            }
        }
    }

    private func isFolderExpanded(_ folderID: String) -> Bool {
        if !trimmedQuery.isEmpty {
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

    private func searchSnippet(for memory: ContextMemory, query: String) -> String? {
        guard !query.isEmpty else { return nil }
        for rawLine in memory.text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("# ") else { continue }
            if line.localizedStandardContains(query) {
                return MemoryCardDigest.cleanInlineNoise(
                    line.replacingOccurrences(of: #"^[#>*\-\d.\s]+"#, with: "", options: .regularExpression)
                )
            }
        }
        return nil
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
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
                                systemImage: allMemories.isEmpty ? "brain" : "magnifyingglass"
                            )
                        } description: {
                            Text(
                                allMemories.isEmpty
                                    ? (sync.isSyncing ? "正在读取记忆…" : "下拉即可同步记忆。")
                                    : "试试其他关键词。"
                            )
                        }
                        .accessibilityIdentifier("remote.memoryEmpty")
                        syncStatusFooter
                    }
                    .padding(16)
                }
                .refreshable {
                    await sync.refresh()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            let showHeader = sections.count > 1 || section.id != "core"
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
                                                    .padding(.leading, 34)
                                            }
                                            directoryNoteRow(memory, colors: colors)
                                        }
                                    }
                                    .padding(.leading, showHeader ? 12 : 0)
                                    .overlay(alignment: .leading) {
                                        if showHeader {
                                            Rectangle()
                                                .fill(colors.line.opacity(0.75))
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
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await sync.refresh()
                }
            }
        }
        .background(colors.desk.ignoresSafeArea())
        .tint(colors.ink)
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(colors.desk, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "搜索笔记、项目、人物…"
        )
        .toolbar {
            if directoryFolders.count > 1 && trimmedQuery.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allFoldersExpanded ? "全部折叠" : "全部展开",
                           systemImage: allFoldersExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                        toggleAllFolders()
                    }
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
    private func directoryNoteRow(_ memory: ContextMemory, colors: MemoryNotebookPalette) -> some View {
        let matchedSnippet = searchSnippet(for: memory, query: trimmedQuery)

        NavigationLink {
            RemoteMemoryDetail(sync: sync, taskStore: taskStore, memoryID: memory.id)
        } label: {
            if let matchedSnippet {
                let digest = MemoryCardDigest.cached(for: memory)
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: digest.badge.symbol)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(colors.tabAccent(memory.kind))
                        .frame(width: 14)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(digest.title)
                                .font(.system(size: 14.5, weight: .regular))
                                .foregroundStyle(colors.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let date = digest.dateBadge {
                                Text(date)
                                    .font(.system(size: 11, weight: .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(colors.secondaryInk)
                            }
                        }
                        Text(matchedSnippet)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.secondaryInk)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            } else {
                MemoryCardView(memory: memory)
            }
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

private struct RemoteMemoryDetail: View {
    let sync: PhoneContextSync
    var taskStore: RemoteTaskStore? = nil
    let memoryID: String
    @State private var pushedLinkedMemoryID: String? = nil
    @State private var showingInstructionBar = false
    @State private var instructionDraft = ""
    @State private var submittingInstruction = false
    @State private var instructionReceipt: String? = nil
    @State private var instructionError: String? = nil
    @State private var confirmingForget = false
    @State private var forgetInFlight = false
    @FocusState private var instructionFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var parentOpenURL

    private var activeMemories: [ContextMemory] {
        sync.memories.filter { $0.status != "forgotten" }
    }

    private var memory: ContextMemory? {
        activeMemories.first { $0.id == memoryID }
    }

    private func folderBreadcrumbTitle(for kind: String) -> String {
        switch kind {
        case "project": return "在研项目"
        case "briefing": return "晨间简报"
        case "topic": return "专题活页"
        case "person": return "人物档案"
        case "journal": return "每日日志"
        default: return "核心记忆"
        }
    }

    private func openLinked(_ nextID: String) {
        guard nextID != memoryID else { return }
        pushedLinkedMemoryID = nextID
    }

    private var canInstruct: Bool {
        taskStore != nil
    }

    private func submitInstruction() {
        guard let memory, let store = taskStore else { return }
        let trimmed = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !submittingInstruction else { return }
        let fullPrompt = MemoryCardDigest.buildInstructionPrompt(for: memory, instruction: trimmed)
        submittingInstruction = true
        instructionError = nil

        let previousDraft = store.draft
        store.setDraft(fullPrompt)
        defer {
            if !previousDraft.isEmpty {
                store.setDraft(previousDraft)
            }
        }
        do {
            try store.enqueue()
            instructionDraft = ""
            instructionFieldFocused = false
            withAnimation(.easeInOut(duration: 0.16)) {
                showingInstructionBar = false
                instructionReceipt = "已交给 MoMo 修改记忆与说话人，完成后自动同步"
            }
            submittingInstruction = false
            Task {
                await store.refresh(userInitiated: true)
                for delay in [6, 10, 15, 22] {
                    try? await Task.sleep(for: .seconds(delay))
                    await sync.refresh()
                }
            }
        } catch {
            submittingInstruction = false
            instructionError = error.localizedDescription
        }
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)

        Group {
            if let memory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ClientMemoryContent(
                            memory: memory,
                            allMemories: activeMemories,
                            onSelectLinkedMemory: { openLinked($0.id) },
                            borderless: true,
                            showsInlineTopBar: false,
                            showsInlineInstructionBar: false
                        )
                        if let failure = sync.failure {
                            Text(failure)
                                .phoneText(.metadata)
                                .foregroundStyle(MoMoPalette.failure)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationDestination(item: $pushedLinkedMemoryID) { targetID in
            RemoteMemoryDetail(sync: sync, taskStore: taskStore, memoryID: targetID)
        }
        .environment(\.openURL, OpenURLAction { url in
            if DreamMemoryLinkResolver.isMemoryURL(url) {
                if let next = DreamMemoryLinkResolver.resolve(url: url, in: sync.memories), next.id != memoryID {
                    openLinked(next.id)
                }
                return .handled
            }
            parentOpenURL(url)
            return .handled
        })
        .safeAreaInset(edge: .bottom) {
            bottomInstructionOverlay(colors: colors)
        }
        .background(colors.paper.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(colors.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let memory {
                    Text(folderBreadcrumbTitle(for: memory.kind))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(colors.secondaryInk)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let memory {
                    if canInstruct {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showingInstructionBar.toggle()
                                instructionError = nil
                            }
                            if showingInstructionBar {
                                instructionFieldFocused = true
                            } else {
                                instructionFieldFocused = false
                            }
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(showingInstructionBar ? colors.tabAccent(memory.kind) : colors.ink)
                        }
                        .accessibilityLabel("指令修改")
                        .accessibilityIdentifier("remote.memoryInstructToggle")
                    }

                    Menu {
                        Button {
                            MemoryCardDigest.copyToPasteboard(memory.text)
                        } label: {
                            Label("复制 Markdown", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: memory.text) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", systemImage: "trash", role: .destructive) {
                            confirmingForget = true
                        }
                        .accessibilityIdentifier("remote.forgetMemory")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
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

    @ViewBuilder
    private func bottomInstructionOverlay(colors: MemoryNotebookPalette) -> some View {
        if showingInstructionBar, let memory {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(colors.tabAccent(memory.kind))
                    TextField("告诉 MoMo 怎么改（如：这段是 shengli 说的）…", text: $instructionDraft, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(size: 14.5))
                        .focused($instructionFieldFocused)
                        .disabled(submittingInstruction)
                        .onSubmit {
                            submitInstruction()
                        }
                        .accessibilityIdentifier("remote.memoryInstructInput")

                    if submittingInstruction {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            submitInstruction()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(
                                    instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? colors.secondaryInk.opacity(0.35)
                                        : colors.ink
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("发送修改指令")
                        .accessibilityIdentifier("remote.memoryInstructSend")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(colors.line, lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)

                if let instructionError {
                    Text(instructionError)
                        .font(.footnote)
                        .foregroundStyle(MoMoPalette.failure)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else if let receipt = instructionReceipt {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(MoMoPalette.success)
                Text(receipt)
                    .font(.footnote)
                    .foregroundStyle(colors.ink)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        instructionReceipt = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.secondaryInk)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(colors.line, lineWidth: 0.7)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
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
