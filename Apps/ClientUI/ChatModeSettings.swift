import SwiftUI
import MoMoAgentClient

struct ChatModeSettings: View {
    let store: RemoteTaskStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: ChatMode?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("聊天模式")
                Spacer()
                if let mode {
                    Picker("聊天模式", selection: Binding(get: { mode }, set: { choice in
                        Task { await update(choice) }
                    })) {
                        Text("标准").tag(ChatMode.standard)
                        Text("创作").tag(ChatMode.creator)
                    }
                    .pickerStyle(.menu).labelsHidden().disabled(busy)
                    .accessibilityIdentifier("settings.chatMode")
                } else if busy {
                    ProgressView().controlSize(.small)
                }
            }
            Text("选择「创作」后，在聊天里告诉 MoMo 想加什么功能。个人扩展保存在 Mac 上。")
                .font(.footnote).foregroundStyle(.secondary)
            if let failure {
                HStack {
                    Text(verbatim: failure).font(.footnote)
                    Button("重试") { Task { await update() } }.disabled(busy)
                }
            }
        }
        .task(id: ObjectIdentifier(store)) { await update() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await update() } }
        }
    }

    @MainActor private func update(_ selection: ChatMode? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            mode = try await store.chatMode(setting: selection)
            failure = nil
        } catch is CancellationError {
        } catch AgentClientError.http(status: 404, code: _, message: _, retryAfter: _) {
            failure = String(localized: "请更新 Mac 上的 MoMo 以使用创作模式。")
        } catch {
            failure = error.localizedDescription
        }
    }
}
