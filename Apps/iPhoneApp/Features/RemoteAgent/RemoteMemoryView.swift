import SwiftUI
import MoMoAgentClient

struct RemoteMemoryView: View {
    let sync: PhoneContextSync
    @State private var forgetting: ContextMemory?
    @State private var showingSync = false
    private var memories: [ContextMemory] { sync.memories.filter { $0.status != "forgotten" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                syncStatus
                if sync.hasLegacyChanges {
                    Text("旧版待同步修改已保留，请核对当前记忆后重新修改。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
                if let failure = sync.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                }
                if memories.isEmpty {
                    ContentUnavailableView {
                        Label("还没有记忆", systemImage: "text.book.closed")
                    } description: {
                        Text(sync.isSyncing ? "正在读取记忆…" : "告诉 MoMo 想记住的事。")
                    }.accessibilityIdentifier("remote.memoryEmpty")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(memories) { memory in
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
                            if memory.id != memories.last?.id { Divider() }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .phonePageSurface().tint(MoMoPalette.ink)
        .navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("同步录音与记忆", systemImage: "arrow.clockwise") { Task { await sync.refresh() } }
                    .disabled(sync.isSyncing).accessibilityIdentifier("remote.syncMemory")
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

    private var syncStatus: some View {
        DisclosureGroup(isExpanded: $showingSync) {
            VStack(alignment: .leading, spacing: 8) {
                if let date = sync.lastSynced { PhoneSettingsValueRow(title: "最近同步", value: Text(date, style: .relative)) }
                if sync.memoryPending > 0 { Text("\(sync.memoryPending) 批录音待整理") }
                if sync.memoryNeedsReview > 0 { Text("\(sync.memoryNeedsReview) 份录音需核对，原文仍保留。") }
            }.phoneText(.metadata).foregroundStyle(MoMoPalette.muted).padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                Text("录音同步")
                Spacer(minLength: 8)
                Text(sync.isSyncing ? String(localized: "正在同步") : sourceStatus)
            }.phoneText(.metadata).foregroundStyle(MoMoPalette.muted).frame(minHeight: 44)
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
        let preview = MemoryPreview(text: memory.text)
        VStack(alignment: .leading, spacing: 10) {
            if preview.date != nil || preview.sourceNote != nil || memory.kind == "user" || memory.status == "stale" || memory.basis == "inferred" {
                HStack(spacing: 8) {
                    if let date = preview.date { Text(date) }
                    if let note = preview.sourceNote { Text(note) }
                    if memory.kind == "user" { Text("关于你") }
                    if memory.status == "stale" {
                        Label("原文已改变", systemImage: "clock.badge.exclamationmark")
                    } else if memory.basis == "inferred" {
                        Text("模型推断")
                    }
                }.phoneText(.caption).foregroundStyle(MoMoPalette.muted)
            }
            Text(preview.text).phoneText(.body).lineLimit(4)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Text("查看全文")
                Image(systemName: "chevron.right").font(.caption2.weight(.medium)).accessibilityHidden(true)
            }.phoneText(.caption).foregroundStyle(MoMoPalette.muted)
        }
        .padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private struct RemoteMemoryDetail: View {
    let sync: PhoneContextSync
    let memoryID: String
    @State private var confirmingForget = false
    @State private var forgetInFlight = false
    @Environment(\.dismiss) private var dismiss
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
        .phonePageSurface().navigationTitle("记忆详情").navigationBarTitleDisplayMode(.inline)
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
