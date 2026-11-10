import SwiftUI
import MoMoAgentClient

struct RemoteMemoryView: View {
    let sync: PhoneContextSync
    var onSelectBriefingCard: ((DreamBriefingCard) -> Void)? = nil
    @State private var forgetting: ContextMemory?
    @State private var selectedCategory: DreamMemoryCategory? = nil
    @State private var selectedMemoryID: String? = nil
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

    private var sections: [DreamMemorySection] {
        DreamMemoryCategory.sections(from: allMemories, category: activeCategory)
    }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !allMemories.isEmpty {
                    categoryFilterStrip
                }
                if sync.hasLegacyChanges {
                    Text("旧版待同步修改已保留，请核对当前记忆后重新修改。")
                        .phoneText(.metadata).foregroundStyle(colors.secondaryInk)
                }
                if let failure = sync.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                }
                if sections.isEmpty {
                    ContentUnavailableView {
                        Label(allMemories.isEmpty ? "还没有记忆" : "暂无笔记", systemImage: "text.book.closed")
                    } description: {
                        Text(sync.isSyncing ? "正在读取记忆…" : "轻触右上角即可整理或同步。")
                    }.accessibilityIdentifier("remote.memoryEmpty")
                } else if activeCategory.isNotebookReaderCategory, let memory = activeReaderMemory {
                    VStack(alignment: .leading, spacing: 12) {
                        MemoryBinderPageSwitcher(
                            items: currentReaderItems,
                            selectedID: memory.id,
                            onSelect: { selectedMemoryID = $0.id }
                        )
                        ClientMemoryContent(memory: memory)
                            .contextMenu {
                                Button("忘记这条记忆", role: .destructive) { forgetting = memory }
                            }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        if let next = DreamMemoryLinkResolver.resolve(url: url, in: allMemories) {
                            selectedCategory = DreamMemoryCategory.category(for: next)
                            selectedMemoryID = next.id
                            return .handled
                        }
                        return .systemAction
                    })
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                if sections.count > 1 {
                                    HStack(spacing: 6) {
                                        Text(section.title)
                                            .momoHandwriting(size: 17, weight: .semibold, relativeTo: .headline)
                                            .foregroundStyle(colors.ink)
                                            .accessibilityAddTraits(.isHeader)
                                        Text("\(section.items.count)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(colors.secondaryInk)
                                    }
                                    .padding(.top, 2)
                                }
                                ForEach(section.items) { memory in
                                    NavigationLink {
                                        RemoteMemoryDetail(sync: sync, memoryID: memory.id)
                                    } label: {
                                        MemoryPreviewRow(memory: memory)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("remote.memoryRow." + memory.id)
                                    .contextMenu {
                                        Button("忘记这条记忆", role: .destructive) { forgetting = memory }
                                    }
                                }
                            }
                        }
                    }
                }

                syncStatusFooter
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(colors.desk.ignoresSafeArea())
        .tint(colors.ink)
        .navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
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
                        .disabled(sync.isSyncing).accessibilityIdentifier("remote.syncMemory")
                }
            }
        }
        .alert("忘记这条记忆？", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            if let memory = forgetting {
                Button("忘记", role: .destructive) { Task { await sync.forget(memory) }; forgetting = nil }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("连接 Mac 后删除这条记忆。原始录音与聊天记录仍保留。") }
        .task { await sync.refresh() }
    }

    private var categoryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(visibleCategories) { category in
                    let isSelected = activeCategory == category
                    Button {
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
    @State private var confirmingForget = false
    @State private var forgetInFlight = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var memory: ContextMemory? { sync.memories.first { $0.id == memoryID && $0.status != "forgotten" } }
    private var siblingMemories: [ContextMemory] {
        guard let memory else { return [] }
        let active = sync.memories.filter { $0.status != "forgotten" && $0.kind == memory.kind }
        return DreamMemoryCategory.sortMemories(active)
    }

    var body: some View {
        ScrollView {
            if let memory {
                VStack(alignment: .leading, spacing: 14) {
                    if ["project", "briefing", "topic", "person", "journal"].contains(memory.kind) {
                        MemoryBinderPageSwitcher(
                            items: siblingMemories,
                            selectedID: memory.id,
                            onSelect: { memoryID = $0.id }
                        )
                    }
                    ClientMemoryContent(memory: memory)
                    if let failure = sync.failure {
                        Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: sync.memories) {
                memoryID = next.id
                return .handled
            }
            return .systemAction
        })
        .background(MemoryNotebookPalette(scheme: scheme).desk.ignoresSafeArea())
        .navigationTitle(memory.map { MemoryCardDigest.cached(for: $0).title } ?? "记忆详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let memory {
                    Menu {
                        ShareLink(item: memory.text) { Label("分享", systemImage: "square.and.arrow.up") }
                        Button("忘记这条记忆", role: .destructive) { confirmingForget = true }
                            .accessibilityIdentifier("remote.forgetMemory")
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("记忆操作").accessibilityIdentifier("remote.memoryActions")
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
        } message: { Text("连接 Mac 后删除这条记忆。原始录音与聊天记录仍保留。") }
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
