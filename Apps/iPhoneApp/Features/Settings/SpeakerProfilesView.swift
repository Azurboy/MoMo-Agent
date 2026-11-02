import SwiftUI
import MoMoArchive

struct SpeakerProfilesView: View {
    let archive: ArchiveStore
    var onSpeakersChanged: (() async -> Void)? = nil
    @State private var people: [SpeakerProfile] = []
    @State private var editing: SpeakerProfile?
    @State private var deleting: SpeakerProfile?
    @State private var loaded = false
    @State private var busy = false
    @State private var rematchMessage: String?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                ForEach(people) { person in
                    HStack(spacing: 12) {
                        Image(systemName: person.isUser ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.title2).foregroundStyle(MoMoPalette.muted).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(person.name).foregroundStyle(MoMoPalette.ink)
                            Text("声纹样本 \(person.sampleCount) · 排除样本 \(person.correctionCount)")
                                .font(.caption).foregroundStyle(MoMoPalette.muted)
                        }
                        Spacer()
                        Menu {
                            if !person.isUser {
                                Button("改名", systemImage: "pencil") { editing = person }
                            }
                            Button("删除人物与声纹", systemImage: "trash", role: .destructive) { deleting = person }
                        } label: {
                            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("管理\(person.name)")
                    }.accessibilityElement(children: .contain)
                }
            } footer: {
                Text("在转录中点说话人，确认或纠正姓名。确认后会基于声纹自动匹配当前及全部历史录音中的同一说话人。")
            }
            if !people.isEmpty {
                Section {
                    Button {
                        update {
                            let matched = try await archive.rematchAllSpeakers()
                            rematchMessage = String(localized: "已完成全量声纹重匹配，共覆盖 \(matched) 段语音。")
                        }
                    } label: {
                        Label("重新匹配全部历史录音", systemImage: "waveform.badge.magnifyingglass")
                            .foregroundStyle(MoMoPalette.ink)
                    }
                    .accessibilityIdentifier("speaker.rematch.all")
                } footer: {
                    if let rematchMessage {
                        Text(rematchMessage)
                    }
                }
            }
        }
        .overlay {
            if !loaded && failure == nil { ProgressView() }
            else if loaded && people.isEmpty {
                ContentUnavailableView("还没有人物", systemImage: "person.2", description: Text("在转录中点说话人，选择「我」或填写姓名。"))
            }
        }
        .buttonStyle(.automatic)
        .disabled(busy)
        .phoneSoftTopEdge()
        .navigationTitle("人物与声纹")
        .navigationBarTitleDisplayMode(.inline)
        .tint(MoMoPalette.ink)
        .task { await reload() }
        .sheet(item: $editing) { person in
            SpeakerRenameView(person: person, archive: archive) {
                await reload()
                await onSpeakersChanged?()
            }
        }
        .confirmationDialog("删除人物与声纹？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { person in
            Button("删除\(person.name)", role: .destructive) { update { try await archive.forgetVoiceprint(personID: person.id) } }
        } message: { _ in Text("清除该人物的姓名标记与声纹样本，保留转录和原音。") }
        .alert("声纹未更新", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func reload() async {
        do { people = try await archive.speakerProfiles(); loaded = true }
        catch { failure = error.localizedDescription }
    }

    private func update(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                await reload()
                await onSpeakersChanged?()
            }
            catch { failure = error.localizedDescription }
        }
    }
}

private struct SpeakerRenameView: View {
    let person: SpeakerProfile
    let archive: ArchiveStore
    let changed: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("姓名", text: $name).textContentType(.name).focused($focused)
                    .submitLabel(.done).onSubmit { save() }.accessibilityIdentifier("speaker.rename.name")
            }
            .buttonStyle(.automatic)
            .phoneSoftTopEdge()
            .navigationTitle("改名").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("speaker.rename.save")
                }
            }
            .task { name = person.name; focused = true }
            .alert("声纹未更新", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }.presentationDetents([.medium])
    }

    private func save() {
        guard !saving else { return }
        let value = name
        focused = false
        saving = true
        Task {
            defer { saving = false }
            do {
                try await archive.renameVoiceprint(personID: person.id, name: value)
                await changed()
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}
