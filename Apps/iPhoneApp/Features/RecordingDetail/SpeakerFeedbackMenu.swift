import SwiftUI
import MoMoArchive

struct SpeakerFeedbackMenu: View {
    let speaker: String?
    let attribution: SpeakerAttribution?
    let source: SourceReference
    var additionalSources: [SourceReference] = []
    let archive: ArchiveStore
    let changed: () async -> Void
    @State private var choosing = false

    private var displayName: String {
        guard let speaker, speaker != String(localized: "说话人未确定") else { return String(localized: "说话人") }
        return speaker
    }

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 4) {
                Text(displayName).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.medium)).accessibilityHidden(true)
            }
            .phoneText(.caption)
            .foregroundStyle(attribution?.isUser == true ? MoMoPalette.success : (attribution?.personID != nil ? MoMoPalette.ink : MoMoPalette.muted))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(attribution?.isUser == true ? MoMoPalette.successBackground : MoMoPalette.ink.opacity(0.045), in: Capsule())
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("说话人"))
        .accessibilityValue(Text(displayName))
        .accessibilityIdentifier("transcript.speaker.\(source.spanID)")
        .sheet(isPresented: $choosing) {
            SpeakerPicker(archive: archive, sources: [source] + additionalSources,
                speaker: displayName, attribution: attribution, changed: changed)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct SpeakerPicker: View {
    let archive: ArchiveStore
    let sources: [SourceReference]
    let speaker: String
    let attribution: SpeakerAttribution?
    let changed: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [SpeakerProfile] = []
    @State private var wholeGroup = true
    @State private var groupCount = 0
    @State private var name = ""
    @State private var naming = false
    @State private var search = ""
    @FocusState private var nameFocused: Bool
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { correct(.owner) } label: {
                        profileRow(name: String(localized: "我"), selected: attribution?.isUser == true)
                    }.accessibilityIdentifier("speaker.choose.owner")
                    if people.count > 10 {
                        TextField("搜索人物", text: $search).accessibilityIdentifier("speaker.search")
                    }
                    ForEach(people.filter { !$0.isUser && (search.isEmpty || $0.name.localizedStandardContains(search)) }) { person in
                        Button { correct(.knownPerson(person.id)) } label: {
                            profileRow(name: person.name, selected: attribution?.personID == person.id)
                        }.accessibilityIdentifier("speaker.choose.\(person.id)")
                    }
                } header: { Text("这是谁") }
                if groupCount > sources.count {
                    Section {
                        Picker("应用范围", selection: $wholeGroup) {
                            Text("这个说话人（\(groupCount) 段）").tag(true)
                            Text("仅这段").tag(false)
                        }.pickerStyle(.menu)
                    }
                }
                Section {
                    if naming {
                        TextField("姓名", text: $name).textContentType(.name)
                            .focused($nameFocused).submitLabel(.done)
                            .onAppear { nameFocused = true }
                            .onSubmit { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { correct(.person(name)) } }
                            .accessibilityIdentifier("speaker.new.name")
                    } else {
                        Button("添加人物", systemImage: "person.badge.plus") { naming = true }
                            .accessibilityIdentifier("speaker.new.add")
                    }
                }
                Section {
                    if let personID = attribution?.personID {
                        Button("这不是\(speaker)", role: .destructive) { correct(.notPerson(personID)) }
                    }
                    if attribution != nil {
                        Button("撤销标记", systemImage: "arrow.uturn.backward") { correct(.clear) }
                    }
                }
            }
            // The transcript chip uses .plain; reset the inherited style so Form rows
            // activate across their full native hit area.
            .buttonStyle(.automatic)
            .disabled(!loaded || saving)
            .tint(MoMoPalette.ink)
            .phoneSoftTopEdge()
            .navigationTitle("说话人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                if naming {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { correct(.person(name)) }
                            .disabled(!loaded || saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("speaker.new.save")
                    }
                }
            }
            .overlay { if !loaded && failure == nil || saving { ProgressView() } }
            .task {
                wholeGroup = attribution?.confirmed != true
                do {
                    people = try await archive.speakerProfiles()
                    loaded = true
                    let preview = try await archive.speakerFeedbackPreview(sources)
                    groupCount = preview.count
                } catch { failure = error.localizedDescription }
            }
            .alert("声纹未更新", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil; if !loaded { dismiss() } }
            } message: { Text(failure ?? "") }
        }
    }

    private func profileRow(name: String, selected: Bool) -> some View {
        HStack {
            Text(name).foregroundStyle(MoMoPalette.ink)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(MoMoPalette.ink).accessibilityLabel("当前说话人") }
        }.contentShape(Rectangle())
    }

    private func correct(_ feedback: SpeakerFeedback) {
        guard !saving else { return }
        nameFocused = false
        saving = true
        let notifyChanged = changed
        Task {
            do {
                try await archive.correctSpeakers(
                    sources,
                    feedback: feedback,
                    scope: wholeGroup ? .cluster : .selection,
                    deferGlobalRematch: true
                )
                saving = false
                dismiss()
                await notifyChanged()
            } catch {
                saving = false
                failure = error.localizedDescription
            }
        }
    }
}
