import SwiftUI
import MoMoArchive

private struct SpeakerRematchProgress: Equatable {
    enum Stage: Equatable {
        case preparing
        case matching(completed: Int, total: Int, updatedSessions: Int, remainingSeconds: Int?)
        case finalizing(total: Int, updatedSessions: Int)
    }

    var stage: Stage

    var fractionCompleted: Double? {
        switch stage {
        case .preparing:
            return nil
        case .matching(let completed, let total, _, _):
            guard total > 0 else { return 1 }
            return min(1, max(0, Double(completed) / Double(total)))
        case .finalizing:
            return 1
        }
    }

    var titleText: String {
        switch stage {
        case .preparing:
            return String(localized: "正在建立声纹特征库，扫描历史录音…")
        case .matching(let completed, let total, _, _):
            return String(localized: "正在重匹配历史录音 \(completed) / \(total) 场")
        case .finalizing:
            return String(localized: "正在同步最新转录结果…")
        }
    }

    var detailText: String {
        switch stage {
        case .preparing:
            return String(localized: "正在聚合全部人物正负样本与声学聚类特征，请稍候…")
        case .matching(let completed, let total, let updatedSessions, let remainingSeconds):
            let eta: String
            if completed == 0 {
                eta = String(localized: "正在估算剩余时间…")
            } else if let sec = remainingSeconds {
                if sec <= 2 {
                    eta = String(localized: "即将完成…")
                } else if sec < 60 {
                    eta = String(localized: "预计还需约 \(sec) 秒")
                } else {
                    let mins = sec / 60
                    let rem = sec % 60
                    eta = rem > 0
                        ? String(localized: "预计还需约 \(mins) 分 \(rem) 秒")
                        : String(localized: "预计还需约 \(mins) 分钟")
                }
            } else {
                eta = String(localized: "正在估算剩余时间…")
            }
            let pct = total > 0 ? Int((Double(completed) / Double(total) * 100).rounded()) : 100
            return String(localized: "已完成 \(pct)% · 已更新 \(updatedSessions) 场 · \(eta)")
        case .finalizing(let total, let updatedSessions):
            return String(localized: "已扫描完 \(total) 场录音（更新 \(updatedSessions) 场），即将完成…")
        }
    }
}

struct SpeakerProfilesView: View {
    let archive: ArchiveStore
    var onSpeakersChanged: (() async -> Void)? = nil
    @State private var people: [SpeakerProfile] = []
    @State private var editing: SpeakerProfile?
    @State private var deleting: SpeakerProfile?
    @State private var loaded = false
    @State private var busy = false
    @State private var rematchProgress: SpeakerRematchProgress?
    @State private var rematchTask: Task<Void, Never>?
    @State private var rematchMessage: String?
    @State private var failure: String?

    private var isMutating: Bool { busy || rematchProgress != nil }

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
                        }
                        .disabled(isMutating)
                        .accessibilityLabel("管理\(person.name)")
                    }.accessibilityElement(children: .contain)
                }
            } footer: {
                Text("在转录中点说话人，确认或纠正姓名。确认后会基于声纹自动匹配当前及全部历史录音中的同一说话人。")
            }
            if !people.isEmpty {
                Section {
                    if let progress = rematchProgress {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(progress.titleText)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(MoMoPalette.ink)
                                    .monospacedDigit()
                                Spacer(minLength: 4)
                                if case .matching = progress.stage {
                                    Button("停止", role: .cancel) {
                                        rematchTask?.cancel()
                                    }
                                    .font(.footnote.weight(.medium))
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("speaker.rematch.cancel")
                                }
                            }
                            if let fraction = progress.fractionCompleted {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .tint(MoMoPalette.ink)
                            }
                            Text(progress.detailText)
                                .font(.caption)
                                .foregroundStyle(MoMoPalette.muted)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("speaker.rematch.progress")
                    } else {
                        Button {
                            startFullRematch()
                        } label: {
                            Label("重新匹配全部历史录音", systemImage: "waveform.badge.magnifyingglass")
                                .foregroundStyle(MoMoPalette.ink)
                        }
                        .disabled(isMutating)
                        .accessibilityIdentifier("speaker.rematch.all")
                    }
                } footer: {
                    if let rematchMessage, rematchProgress == nil {
                        Label(rematchMessage, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(MoMoPalette.muted)
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
        .phoneSoftTopEdge()
        .navigationTitle("人物与声纹")
        .navigationBarTitleDisplayMode(.inline)
        .tint(MoMoPalette.ink)
        .task { await reload() }
        .onDisappear { rematchTask?.cancel() }
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

    private func startFullRematch() {
        guard !isMutating else { return }
        rematchMessage = nil
        failure = nil
        rematchProgress = SpeakerRematchProgress(stage: .preparing)
        rematchTask = Task { @MainActor in
            let startedAt = ContinuousClock.now
            var completed = 0
            var total = 0
            var updatedSessions = 0
            defer {
                rematchProgress = nil
                rematchTask = nil
            }
            do {
                let plan = try await archive.prepareFullSpeakerRematch()
                try Task.checkCancellation()
                total = plan.sessionIDs.count
                if total == 0 {
                    await reload()
                    rematchMessage = String(localized: "当前还没有包含声纹记录的历史录音。")
                    return
                }
                rematchProgress = SpeakerRematchProgress(
                    stage: .matching(completed: 0, total: total, updatedSessions: 0, remainingSeconds: nil)
                )
                let batchSize = 4
                let matchingStartedAt = ContinuousClock.now
                var index = 0
                while index < total {
                    try Task.checkCancellation()
                    let end = min(total, index + batchSize)
                    let slice = Array(plan.sessionIDs[index..<end])
                    let deltaUpdated = try await archive.rematchSpeakerSessionsStep(slice)
                    completed = end
                    updatedSessions += deltaUpdated
                    let elapsed = matchingStartedAt.duration(to: ContinuousClock.now)
                    let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
                    let remainingCount = total - completed
                    let etaSeconds: Int?
                    if remainingCount <= 0 {
                        etaSeconds = 0
                    } else if completed > 0, elapsedSeconds >= 0.05 {
                        let perSession = elapsedSeconds / Double(completed)
                        etaSeconds = max(1, Int(ceil(perSession * Double(remainingCount))))
                    } else {
                        etaSeconds = nil
                    }
                    rematchProgress = SpeakerRematchProgress(
                        stage: .matching(
                            completed: completed,
                            total: total,
                            updatedSessions: updatedSessions,
                            remainingSeconds: etaSeconds
                        )
                    )
                    index = end
                    await Task.yield()
                }
                rematchProgress = SpeakerRematchProgress(
                    stage: .finalizing(total: total, updatedSessions: updatedSessions)
                )
                let matched = try await archive.matchedSpeakerObservationCount()
                try? await archive.projectPendingDocuments(includeUnchanged: false)
                await reload()
                await onSpeakersChanged?()
                let totalElapsed = startedAt.duration(to: ContinuousClock.now)
                let totalSec = max(1, Int(round(Double(totalElapsed.components.seconds) + Double(totalElapsed.components.attoseconds) * 1e-18)))
                rematchMessage = String(
                    localized: "已完成 \(total) 场历史录音重匹配（更新 \(updatedSessions) 场，共覆盖 \(matched) 段语音，耗时 \(totalSec) 秒）。"
                )
            } catch is CancellationError {
                if updatedSessions > 0 {
                    try? await archive.projectPendingDocuments(includeUnchanged: false)
                    await reload()
                    await onSpeakersChanged?()
                }
                if completed > 0 {
                    rematchMessage = String(
                        localized: "已停止重匹配（已处理 \(completed) / \(total) 场，已更新 \(updatedSessions) 场录音）。"
                    )
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func update(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isMutating else { return }
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
