import SwiftUI
import MoMoAgentClient

struct RemoteMemoryView: View {
    let sync: PhoneContextSync
    var onSelectBriefingCard: ((DreamBriefingCard) -> Void)? = nil
    @State private var forgetting: ContextMemory?
    @State private var showingSync = false
    @State private var selectedCategory: DreamMemoryCategory = .all
    @State private var dismissedBriefingCardIDs: Set<String> = []
    @State private var showingBriefingSheet = false
    @Environment(\.colorScheme) private var scheme

    private var allMemories: [ContextMemory] { sync.memories.filter { $0.status != "forgotten" } }
    private var sections: [DreamMemorySection] {
        DreamMemoryCategory.sections(from: allMemories, category: selectedCategory)
    }
    private var briefingDocument: DreamBriefingDocument? {
        DreamBriefingDocument.resolve(from: allMemories)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                syncStatus
                dreamStatusRow
                if !allMemories.isEmpty {
                    categoryFilterStrip
                }
                if sync.hasLegacyChanges {
                    Text("旧版待同步修改已保留，请核对当前记忆后重新修改。")
                        .phoneText(.metadata).foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk)
                }
                if let failure = sync.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                }
                if sections.isEmpty {
                    ContentUnavailableView {
                        Label(allMemories.isEmpty ? "还没有记忆" : "该分类下暂无笔记", systemImage: "text.book.closed")
                    } description: {
                        Text(sync.isSyncing ? "正在读取记忆…" : (allMemories.isEmpty ? "告诉 MoMo 想记住的事，或点击上方「立即 Dream 整理」。" : "Dream 会在闲时自动为你整理此分类的 Markdown 笔记。"))
                    }.accessibilityIdentifier("remote.memoryEmpty")
                } else {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                if sections.count > 1 || section.id == "notebook" {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(section.title)
                                                .momoHandwriting(size: 21, weight: .semibold, relativeTo: .headline)
                                                .foregroundStyle(MemoryNotebookPalette(scheme: scheme).ink)
                                                .accessibilityAddTraits(.isHeader)
                                            Text("\(section.items.count)")
                                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                                .foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background(MoMoPalette.ink.opacity(0.06), in: Capsule())
                                        }
                                        if let subtitle = section.subtitle {
                                            Text(subtitle)
                                                .phoneText(.caption)
                                                .foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk)
                                        }
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
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(MemoryNotebookPalette(scheme: scheme).desk.ignoresSafeArea())
        .tint(MemoryNotebookPalette(scheme: scheme).ink)
        .navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
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
        .sheet(isPresented: $showingBriefingSheet) {
            if let doc = briefingDocument {
                NavigationStack {
                    ScrollView {
                        MarkdownReadingView(markdown: MemoryCardDigest.cleanNotebookMarkdownForDetail(doc.rawMarkdown), accessibilityID: "remote.briefingSheetMarkdown", handwriting: true)
                            .memoryNotebookPage()
                            .padding(20)
                    }
                    .background(MemoryNotebookPalette(scheme: scheme).desk.ignoresSafeArea())
                    .navigationTitle(doc.headline)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showingBriefingSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
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

    private var dreamStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: (sync.memoryReview?.running == true || sync.isDreamRequesting) ? "sparkles" : "moon.stars")
                .accessibilityHidden(true)
            if sync.memoryReview?.running == true || sync.isDreamRequesting {
                Text("正在执行 Dream 闲时深度整理…")
            } else if let dream = sync.memoryReview?.dream {
                Text("上次 Dream · \(Date(timeIntervalSince1970: dream.at).formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Dream 将在空闲时自动整理 Markdown 笔记与人物声纹")
            }
            Spacer(minLength: 8)
            Button {
                Task { await sync.triggerDream() }
            } label: {
                Text("立即整理")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(MoMoPalette.ink.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sync.isSyncing || sync.isDreamRequesting || sync.memoryReview?.running == true)
        }
        .phoneText(.metadata)
        .foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk)
    }

    private var categoryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(DreamMemoryCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        selectedCategory = category
                    } label: {
                        MemoryBinderTab(category: category, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("remote.memoryCategory.\(category.rawValue)")
                }
            }
        }
    }

    private var syncStatus: some View {
        DisclosureGroup(isExpanded: $showingSync) {
            VStack(alignment: .leading, spacing: 8) {
                if let date = sync.lastSynced { PhoneSettingsValueRow(title: "最近同步", value: Text(date, style: .relative)) }
                if sync.memoryPending > 0 { Text("\(sync.memoryPending) 批录音待整理") }
                if sync.memoryNeedsReview > 0 { Text("\(sync.memoryNeedsReview) 份录音需核对，原文仍保留。") }
            }.phoneText(.metadata).foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk).padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                Text("录音同步")
                Spacer(minLength: 8)
                Text(sync.isSyncing ? String(localized: "正在同步") : sourceStatus)
            }.phoneText(.metadata).foregroundStyle(MemoryNotebookPalette(scheme: scheme).secondaryInk).frame(minHeight: 44)
        }.accessibilityIdentifier("remote.memorySyncDetails")
    }

    private var sourceStatus: String {
        if sync.pendingSources > 0 { return String(localized: "\(sync.pendingSources) 份待送达") }
        return sync.lastSourcesSent == nil ? String(localized: "尚未同步") : String(localized: "已送达 Mac")
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

    var body: some View {
        ScrollView {
            if let memory {
                VStack(alignment: .leading, spacing: 20) {
                    ClientMemoryContent(memory: memory)
                    if let failure = sync.failure {
                        Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
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
        .navigationTitle("记忆详情").navigationBarTitleDisplayMode(.inline)
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
