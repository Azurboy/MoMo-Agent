import SwiftUI
import UniformTypeIdentifiers
import MoMoAgentClient
#if os(macOS)
import AppKit
#else
import MoMoSpeech
import PhotosUI
import UIKit
#endif

struct ClientPrimaryButton: ButtonStyle {
    var isLoading = false
    @Environment(\.isEnabled) private var enabled
    #if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView().controlSize(.small)
                    #if os(macOS)
                    .environment(\.colorScheme, colorScheme == .dark ? .light : .dark)
                    #else
                    .tint(MoMoPalette.canvas)
                    #endif
                    .accessibilityHidden(true)
            }
            configuration.label
        }.phoneText(.body).frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(MoMoPalette.canvas)
            .background(MoMoPalette.ink.opacity(isLoading ? 1 : enabled ? (configuration.isPressed ? 0.8 : 1) : 0.3), in: Capsule())
            .contentShape(Capsule())
    }
}

struct ClientComposer: View {
    @Binding var text: String
    var store: RemoteTaskStore? = nil
    var inputID = "remote.input"
    var sendID = "remote.send"
    var prompt: LocalizedStringKey = "发消息给 MoMo"
    var onCompose: () -> Void = {}
    var onPreviewAttachment: ((AgentAttachment) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    #if !os(macOS)
    var speech: SpeechEngine? = nil
    var stopPlayback: () async -> Void = {}
    var voiceInputEnabled = true
    #endif
    let send: () -> Void
    @FocusState private var focused: Bool
    @State private var showingFiles = false
    @State private var importingAttachments = false
    #if !os(macOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = ChatVoiceInput()
    @Environment(EarphoneCaptureRuntime.self) private var earphone: EarphoneCaptureRuntime?
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var cameraFailure: ChatCameraFailure?
    @State private var cameraRequest: Task<Void, Never>?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    #endif
    private var attachments: [AgentAttachment] { store?.draftAttachments ?? [] }
    private var voiceIsActive: Bool {
        #if os(macOS)
        false
        #else
        voice.isActive
        #endif
    }
    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && !importingAttachments && !voiceIsActive
    }
    var body: some View {
        composerBody
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: ClientAttachmentImporter.allowedTypes, allowsMultipleSelection: true) { result in
                do {
                    let urls = try result.get()
                    guard urls.count + attachments.count <= 4 else {
                        onError?(String(localized: "一次最多添加 4 个附件。"))
                        return
                    }
                    importingAttachments = true
                    Task {
                        defer { importingAttachments = false }
                        do {
                            let values = try await Task.detached(priority: .userInitiated) { try urls.map(ClientAttachmentImporter.file) }.value
                            try store?.addAttachments(values)
                        } catch { onError?(error.localizedDescription) }
                    }
                } catch { onError?(error.localizedDescription) }
            }
            #if !os(macOS)
            .photosPicker(isPresented: $showingPhotos, selection: $selectedPhotos,
                maxSelectionCount: max(1, 4 - attachments.count), matching: .images)
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                importingAttachments = true
                Task {
                    defer { importingAttachments = false }
                    do {
                        var values: [AgentAttachment] = []
                        for item in items {
                            guard let bytes = try await item.loadTransferable(type: Data.self) else { throw ClientAttachmentImportError.unreadable }
                            let value = try await Task.detached(priority: .userInitiated) { try ClientAttachmentImporter.image(bytes) }.value
                            values.append(value)
                        }
                        try store?.addAttachments(values)
                    } catch { onError?(error.localizedDescription) }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                ChatCameraPicker(completion: receiveCameraPhoto).ignoresSafeArea()
            }
            .alert("无法使用相机", isPresented: Binding(get: { cameraFailure != nil }, set: { if !$0 { cameraFailure = nil } }), presenting: cameraFailure) { failure in
                if failure == .denied {
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { failure in Text(failure.message) }
            .onChange(of: store.map(ObjectIdentifier.init)) { voice.cancel() }
            .onChange(of: voiceInputEnabled) { if !voiceInputEnabled { voice.cancel() } }
            .onChange(of: scenePhase) { if scenePhase == .background { voice.cancel() } }
            .onDisappear { cameraRequest?.cancel(); voice.cancel() }
            .onAppear {
                // The capture runtime lives as long as the app, so the hooks hold it directly.
                let earphone = earphone
                voice.sessionWillActivate = { await earphone?.yieldAudioSession() }
                voice.sessionDidDeactivate = { earphone?.reclaimAudioSession() }
            }
            #endif
    }

    @ViewBuilder private var composerBody: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                ClientAttachmentStrip(attachments: attachments, remove: { store?.removeAttachment($0) },
                                      preview: { onPreviewAttachment?($0) })
            }
            if importingAttachments {
                Text("正在读取附件…").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    .padding(.horizontal, 18).padding(.top, 8)
            }
            inputField
                .onKeyPress(.return, phases: .down) { key in
                    guard key.modifiers.contains(.shift),
                          let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                          !editor.hasMarkedText() else { return .ignored }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                .onSubmit { if canSend { send() } }
                .padding(.horizontal, 18).padding(.top, attachments.isEmpty && !importingAttachments ? 18 : 6)
            HStack {
                if store != nil { attachmentButton }
                Spacer()
                sendControl
            }.padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(MoMoPalette.line, lineWidth: 1) }
        .tint(MoMoPalette.ink)
        #else
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty {
                ClientAttachmentStrip(attachments: attachments, remove: { store?.removeAttachment($0) },
                                      preview: { onPreviewAttachment?($0) })
            }
            if importingAttachments {
                Text("正在读取附件…").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.top, 4)
            }
            if voice.isActive {
                ChatVoiceInputView(voice: voice)
                    .buttonStyle(.plain)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    if store != nil { attachmentButton }
                    inputField.padding(.leading, store == nil ? 16 : 2).padding(.vertical, 12)
                    voiceButton
                    sendControl
                }
            }
            if let failure = voice.failure {
                HStack(alignment: .top, spacing: 8) {
                    Text(failure).phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    if voice.permissionDenied {
                        Button("打开设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.phoneText(.caption)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("assistant.voice.failure")
            }
        }
        .padding(4)
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 26))
        .tint(MoMoPalette.ink)
        #endif
    }

    @ViewBuilder private var attachmentButton: some View {
        #if os(macOS)
        Button {
            showingFiles = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MoMoPalette.ink)
                .frame(width: 32, height: 32)
                .background(MoMoPalette.ink.opacity(0.06), in: Circle())
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(importingAttachments || attachments.count >= 4)
        .help("添加照片或文件")
        .accessibilityLabel("添加照片或文件")
        .accessibilityIdentifier("assistant.attachments")
        #else
        Menu {
            Button("拍照", systemImage: "camera") { openCamera() }
                .accessibilityIdentifier("assistant.attachments.camera")
            Button("照片图库", systemImage: "photo.on.rectangle") { focused = false; showingPhotos = true }
            Button("选择文件", systemImage: "doc") { focused = false; showingFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MoMoPalette.ink)
                .frame(width: 32, height: 32)
                .background(MoMoPalette.ink.opacity(0.06), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(importingAttachments || cameraRequest != nil || attachments.count >= 4)
        .accessibilityLabel("拍照或添加照片和文件")
        .accessibilityIdentifier("assistant.attachments")
        #endif
    }

    #if !os(macOS)
    private var voiceButton: some View {
        Button {
            guard let speech else {
                voice.failure = ChatVoiceFailure.unavailable.localizedDescription
                return
            }
            focused = false
            onCompose()
            voice.start(recognize: { try await speech.dictate(samples: $0, attempt: $1) },
                        stopPlayback: stopPlayback) { result in
                text = text.isEmpty ? result : text + "\n" + result
                focused = true
            }
        } label: {
            Image(systemName: "mic").font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!voiceInputEnabled || importingAttachments || cameraRequest != nil)
        .accessibilityLabel("语音输入")
        .accessibilityIdentifier("assistant.voice.start")
    }

    private func openCamera() {
        guard cameraRequest == nil, !importingAttachments, attachments.count < 4 else { return }
        focused = false
        cameraRequest = Task {
            defer { cameraRequest = nil }
            let failure = await ChatCameraPicker.authorizationFailure()
            guard !Task.isCancelled else { return }
            if let failure { cameraFailure = failure }
            else { showingCamera = true }
        }
    }

    private func receiveCameraPhoto(_ result: Result<UIImage?, ChatAttachmentImportError>) {
        showingCamera = false
        do {
            guard let image = try result.get() else { return }
            importingAttachments = true
            Task {
                defer { importingAttachments = false }
                do {
                    let value = try await Task.detached(priority: .userInitiated) { try ChatAttachmentImporter.cameraImage(image) }.value
                    try store?.addAttachments([value])
                } catch { onError?(error.localizedDescription) }
            }
        } catch { onError?(error.localizedDescription) }
    }
    #endif

    private var inputField: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .phoneText(.body)
            .lineLimit(1...5).textFieldStyle(.plain).accessibilityIdentifier(inputID)
            .focused($focused)
            .onChange(of: focused) { if focused { onCompose() } }
            .onChange(of: text) { if focused { onCompose() } }
    }
    private var sendControl: some View {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).background(MoMoPalette.ink.opacity(canSend ? 1 : 0.12), in: Circle())
                    .foregroundStyle(canSend ? MoMoPalette.canvas : MoMoPalette.muted)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }.buttonStyle(.plain)
                .disabled(!canSend).accessibilityLabel("发送给 MoMo").accessibilityIdentifier(sendID)
                #if os(macOS)
                .keyboardShortcut(.return, modifiers: .command)
                #endif
    }
}

struct ClientMemoryContent: View {
    let memory: ContextMemory

    private var isNotebookMarkdown: Bool {
        ["briefing", "journal", "person", "topic"].contains(memory.kind)
    }

    private var headerTitle: String {
        if memory.status == "stale" { return "原文已改变，暂不作为当前记忆" }
        switch memory.kind {
        case "briefing": return "Dream · 晨间简报（Markdown）"
        case "journal": return "Dream · 每日生活日志（Markdown）"
        case "person": return "Dream · 人物脉络活页（Markdown）"
        case "topic": return "Dream · 主题与项目活页（Markdown）"
        case "user": return "关于你（USER.md）"
        default:
            if memory.basis == "hermes" { return "MoMo 的记忆（MEMORY.md）" }
            if memory.basis == "inferred" { return "模型推断" }
            return "根据录音中的陈述"
        }
    }

    private var headerIcon: String {
        if memory.status == "stale" { return "clock.badge.exclamationmark" }
        switch memory.kind {
        case "briefing": return "sun.max"
        case "journal": return "calendar.day.timeline.left"
        case "person": return "person.text.rectangle"
        case "topic": return "doc.richtext"
        case "user": return "person.crop.circle"
        default: return "quote.bubble"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(headerTitle, systemImage: headerIcon)
                .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
            if isNotebookMarkdown {
                MarkdownReadingView(markdown: memory.text, accessibilityID: "remote.memoryText")
            } else {
                Text(memory.text)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).accessibilityIdentifier("remote.memoryText")
            }
            ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                VStack(alignment: .leading, spacing: 6) {
                    Text(evidence.quote).phoneText(.metadata).textSelection(.enabled)
                    if let time = evidence.recordedAt { Text(Date(timeIntervalSince1970: time), format: .dateTime.month().day().hour().minute()).phoneText(.caption) }
                }.foregroundStyle(MoMoPalette.muted)
            }
        }.phoneText(.body)
    }
}

enum DreamMemoryCategory: String, CaseIterable, Identifiable {
    case all
    case briefing
    case journal
    case person
    case topic
    case core

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .briefing: return "晨间简报"
        case .journal: return "每日日志"
        case .person: return "人物"
        case .topic: return "主题"
        case .core: return "核心记忆"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .briefing: return "sun.max"
        case .journal: return "calendar"
        case .person: return "person.2"
        case .topic: return "folder"
        case .core: return "sparkles"
        }
    }

    func matches(_ memory: ContextMemory) -> Bool {
        switch self {
        case .all: return true
        case .briefing: return memory.kind == "briefing"
        case .journal: return memory.kind == "journal"
        case .person: return memory.kind == "person"
        case .topic: return memory.kind == "topic"
        case .core: return memory.kind == "memory" || memory.kind == "user"
        }
    }

    static func badge(for memory: ContextMemory) -> (title: String, symbol: String) {
        switch memory.kind {
        case "briefing": return ("晨间简报", "sun.max.fill")
        case "journal": return ("生活日志", "calendar")
        case "person": return ("人物活页", "person.fill")
        case "topic": return ("主题活页", "doc.text.fill")
        case "user": return ("关于你", "person.crop.circle")
        default: return ("核心记忆", "sparkles")
        }
    }
}

enum DreamDotMatrixKind: String, CaseIterable, Sendable {
    case memoryLoop = "记忆回环"
    case voiceWave = "声音片段"
    case relationWeave = "关系交汇"
    case lifeFlow = "生活流向"
    case slowDown = "慢下来"
    case fragmentLink = "片段关联"

    static func parse(_ raw: String, fallbackIndex: Int = 0) -> Self {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for item in Self.allCases where trimmed.contains(item.rawValue) {
            return item
        }
        let defaults: [Self] = [.memoryLoop, .voiceWave, .relationWeave, .lifeFlow, .slowDown, .fragmentLink]
        return defaults[abs(fallbackIndex) % defaults.count]
    }

    enum PaletteTheme {
        case lavender, sage, blue
    }

    var theme: PaletteTheme {
        switch self {
        case .memoryLoop, .lifeFlow: return .lavender
        case .voiceWave, .slowDown: return .sage
        case .relationWeave, .fragmentLink: return .blue
        }
    }

    func surfaceColor(isDark: Bool) -> Color {
        switch (theme, isDark) {
        case (.lavender, false): return Color(red: 0.945, green: 0.941, blue: 0.969) // #F1F0F7
        case (.lavender, true):  return Color(red: 0.145, green: 0.141, blue: 0.192)
        case (.sage, false):     return Color(red: 0.929, green: 0.957, blue: 0.941) // #EDF4F0
        case (.sage, true):      return Color(red: 0.122, green: 0.165, blue: 0.145)
        case (.blue, false):     return Color(red: 0.937, green: 0.953, blue: 0.969) // #EFF3F7
        case (.blue, true):      return Color(red: 0.125, green: 0.153, blue: 0.188)
        }
    }

    func dotColor(isDark: Bool) -> Color {
        switch (theme, isDark) {
        case (.lavender, false): return Color(red: 0.525, green: 0.545, blue: 0.706) // #868BB4
        case (.lavender, true):  return Color(red: 0.655, green: 0.678, blue: 0.847)
        case (.sage, false):     return Color(red: 0.431, green: 0.612, blue: 0.561) // #6E9C8F
        case (.sage, true):      return Color(red: 0.545, green: 0.745, blue: 0.686)
        case (.blue, false):     return Color(red: 0.498, green: 0.600, blue: 0.690) // #7F99B0
        case (.blue, true):      return Color(red: 0.604, green: 0.718, blue: 0.816)
        }
    }

    func titleColor(isDark: Bool) -> Color {
        switch (theme, isDark) {
        case (.lavender, false): return Color(red: 0.196, green: 0.192, blue: 0.239) // #32313D
        case (.sage, false):     return Color(red: 0.161, green: 0.220, blue: 0.192) // #293831
        case (.blue, false):     return Color(red: 0.169, green: 0.204, blue: 0.239)
        case (_, true):          return Color(red: 0.945, green: 0.945, blue: 0.965)
        }
    }

    func subtitleColor(isDark: Bool) -> Color {
        switch (theme, isDark) {
        case (.lavender, false): return Color(red: 0.427, green: 0.416, blue: 0.490) // #6D6A7D
        case (.sage, false):     return Color(red: 0.361, green: 0.451, blue: 0.408) // #5C7368
        case (.blue, false):     return Color(red: 0.373, green: 0.439, blue: 0.502)
        case (_, true):          return Color(red: 0.675, green: 0.682, blue: 0.733)
        }
    }
}

struct DreamDotMatrixArtwork: View {
    let kind: DreamDotMatrixKind
    let isDark: Bool

    var body: some View {
        Canvas { context, size in
            let color = kind.dotColor(isDark: isDark)
            let w = size.width
            let h = size.height
            let cx = w * 0.5
            let cy = h * 0.5

            func drawDot(x: Double, y: Double, r: Double, alpha: Double = 0.88) {
                guard r > 0.2, x >= 2, x <= w - 2, y >= 2, y <= h - 2 else { return }
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(min(1, max(0.15, alpha)))))
            }

            switch kind {
            case .memoryLoop:
                // Twisted Möbius ribbon (fqvSG)
                let uSteps = 56
                let vSteps = 9
                for ui in 0..<uSteps {
                    let u = Double(ui) / Double(uSteps) * (.pi * 2.0)
                    for vi in 0..<vSteps {
                        let v = (Double(vi) / Double(vSteps - 1)) * 2.0 - 1.0
                        let halfU = u * 0.5
                        let radius = 1.0 + 0.36 * v * cos(halfU)
                        let x3d = radius * cos(u)
                        let y3d = radius * sin(u)
                        let z3d = 0.38 * v * sin(halfU)
                        let px = cx + x3d * (w * 0.33) + z3d * (w * 0.08)
                        let py = cy + y3d * (h * 0.26) - z3d * (h * 0.24)
                        let depth = 0.65 + 0.35 * sin(u + v * 0.8)
                        drawDot(x: px, y: py, r: 0.75 + 0.75 * depth, alpha: 0.42 + 0.50 * depth)
                    }
                }
            case .voiceWave:
                // Acoustic wave density field (rfOp1)
                let cols = 38
                let rows = 13
                for ci in 0..<cols {
                    let nx = (Double(ci) / Double(cols - 1)) * 2.0 - 1.0
                    let env = exp(-nx * nx * 2.1) * (0.68 + 0.32 * cos(nx * 4.2))
                    let centerShift = sin(nx * 2.8) * (h * 0.08)
                    for ri in 0..<rows {
                        let ny = (Double(ri) / Double(rows - 1)) * 2.0 - 1.0
                        let dist = abs(ny)
                        guard dist <= env * 1.15 else { continue }
                        let px = w * 0.08 + Double(ci) / Double(cols - 1) * (w * 0.84)
                        let py = cy + centerShift + ny * (h * 0.34)
                        let strength = max(0.15, (1.0 - dist / max(0.2, env)) * env)
                        drawDot(x: px, y: py, r: 0.65 + 1.05 * strength, alpha: 0.35 + 0.60 * strength)
                    }
                }
            case .relationWeave:
                // Intersecting orbital rings (wLyUi)
                for centerOffset in [-w * 0.11, w * 0.11] {
                    for ring in 0..<5 {
                        let rf = 0.65 + Double(ring) * 0.11
                        let steps = 44
                        for si in 0..<steps {
                            let a = Double(si) / Double(steps) * (.pi * 2.0)
                            let px = cx + centerOffset + cos(a) * (w * 0.25 * rf)
                            let py = cy + sin(a) * (h * 0.28 * rf)
                            let s = 0.55 + 0.45 * cos(a * 2.0)
                            drawDot(x: px, y: py, r: 0.7 + 0.65 * s, alpha: 0.35 + 0.50 * s)
                        }
                    }
                }
            case .lifeFlow:
                // Sinusoidal flowing stream (kChIE)
                let cols = 42
                let strands = 8
                for ci in 0..<cols {
                    let t = Double(ci) / Double(cols - 1)
                    let baseY = cy + sin(t * .pi * 2.0 - 0.5) * (h * 0.22)
                    for si in 0..<strands {
                        let offset = (Double(si) / Double(strands - 1) - 0.5) * (h * 0.26)
                        let px = w * 0.08 + t * (w * 0.84)
                        let py = baseY + offset * (0.65 + 0.35 * sin(t * .pi))
                        let fade = sin(t * .pi)
                        drawDot(x: px, y: py, r: 0.7 + 0.75 * fade, alpha: 0.30 + 0.58 * fade)
                    }
                }
            case .slowDown:
                // Open concentric breathing arcs (J9NdA7)
                for ring in 0..<6 {
                    let frac = 0.38 + Double(ring) * 0.12
                    let steps = 48
                    for si in 0..<steps {
                        let a = Double(si) / Double(steps) * (.pi * 2.0)
                        let gap = abs(sin(a))
                        guard gap > 0.18 else { continue }
                        let px = cx + cos(a) * (w * 0.38 * frac)
                        let py = cy + sin(a) * (h * 0.38 * frac)
                        drawDot(x: px, y: py, r: 0.75 + 0.55 * (1.0 - Double(ring) * 0.12), alpha: 0.35 + 0.50 * gap)
                    }
                }
            case .fragmentLink:
                // Clustered density islands (PL8FL)
                let centers = [
                    (cx - w * 0.22, cy + h * 0.06),
                    (cx, cy - h * 0.08),
                    (cx + w * 0.22, cy + h * 0.05)
                ]
                let cols = 34
                let rows = 12
                for ci in 0..<cols {
                    let px = w * 0.08 + Double(ci) / Double(cols - 1) * (w * 0.84)
                    for ri in 0..<rows {
                        let py = h * 0.14 + Double(ri) / Double(rows - 1) * (h * 0.72)
                        var density = 0.0
                        for (ix, iy) in centers {
                            let dx = (px - ix) / (w * 0.18)
                            let dy = (py - iy) / (h * 0.26)
                            density += exp(-(dx * dx + dy * dy))
                        }
                        guard density > 0.28 else { continue }
                        let clamped = min(1.0, density * 0.75)
                        drawDot(x: px, y: py, r: 0.65 + 0.95 * clamped, alpha: 0.30 + 0.60 * clamped)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct DreamBriefingCard: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let prompt: String
    let motif: DreamDotMatrixKind
}

struct DreamBriefingDocument: Equatable, Sendable {
    let headline: String
    let overview: String
    let rawMarkdown: String
    let cards: [DreamBriefingCard]

    static func parse(markdown: String) -> DreamBriefingDocument {
        let lines = markdown.components(separatedBy: .newlines)
        var headline = "晨间简报"
        var overviewLines: [String] = []
        var cards: [DreamBriefingCard] = []

        enum SectionMode {
            case intro
            case overview
            case preheat
            case card(title: String, motif: String?, context: String?, body: [String])
            case other
        }
        var mode: SectionMode = .intro
        var preheatBullets: [String] = []

        func flushCard() {
            if case let .card(rawTitle, rawMotif, rawContext, bodyLines) = mode {
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                let idx = cards.count
                let motif = DreamDotMatrixKind.parse(rawMotif ?? "", fallbackIndex: idx)
                let subtitle = (rawContext?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "结合近期上下文继续推进"
                let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = body.isEmpty ? "请帮我围绕「\(title)」继续梳理并推进。" : body
                cards.append(
                    DreamBriefingCard(
                        id: "dream-card-\(idx)-\(title)",
                        title: title,
                        subtitle: subtitle,
                        prompt: prompt,
                        motif: motif
                    )
                )
            }
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                headline = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                flushCard()
                let heading = trimmed.replacingOccurrences(of: #"^#{2,3}\s*"#, with: "", options: .regularExpression)
                if heading.hasPrefix("卡片：") || heading.hasPrefix("卡片:") || heading.hasPrefix("建议：") || heading.hasPrefix("建议:") {
                    let cardTitle = heading.replacingOccurrences(of: #"^(卡片|建议)[：:]\s*"#, with: "", options: .regularExpression)
                    mode = .card(title: cardTitle, motif: nil, context: nil, body: [])
                } else if heading.contains("今日脉络") || heading.contains("概览") {
                    mode = .overview
                } else if heading.contains("预热") || heading.contains("未闭环") || heading.contains("重点") {
                    mode = .preheat
                } else {
                    mode = .other
                }
                continue
            }

            switch mode {
            case .intro, .overview:
                if !trimmed.isEmpty && !trimmed.hasPrefix("```") {
                    overviewLines.append(trimmed.replacingOccurrences(of: #"^[-*]\s*"#, with: "", options: .regularExpression))
                }
            case .preheat:
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    preheatBullets.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                }
            case .card(let title, var motif, var context, var body):
                if trimmed.hasPrefix("- 纹样：") || trimmed.hasPrefix("- 纹样:") {
                    motif = trimmed.replacingOccurrences(of: #"^-\s*纹样[：:]\s*"#, with: "", options: .regularExpression)
                } else if trimmed.hasPrefix("- 语境：") || trimmed.hasPrefix("- 语境:") || trimmed.hasPrefix("- 来源：") || trimmed.hasPrefix("- 背景：") {
                    context = trimmed.replacingOccurrences(of: #"^-\s*(语境|来源|背景)[：:]\s*"#, with: "", options: .regularExpression)
                } else if !trimmed.hasPrefix("```") {
                    if !trimmed.isEmpty || !body.isEmpty {
                        body.append(trimmed)
                    }
                }
                mode = .card(title: title, motif: motif, context: context, body: body)
            case .other:
                break
            }
        }
        flushCard()

        if cards.isEmpty {
            for (idx, bullet) in preheatBullets.prefix(2).enumerated() {
                let shortTitle = String(bullet.prefix(16))
                cards.append(
                    DreamBriefingCard(
                        id: "dream-preheat-\(idx)",
                        title: shortTitle,
                        subtitle: "晨间简报待跟进线索",
                        prompt: "围绕晨间简报里的这条线索帮我继续梳理和推进：\(bullet)",
                        motif: idx == 0 ? .memoryLoop : .voiceWave
                    )
                )
            }
        }

        let overview = overviewLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return DreamBriefingDocument(
            headline: headline,
            overview: overview.isEmpty ? "Dream 已在闲时为你整理好近期生活脉络与重点。" : overview,
            rawMarkdown: markdown,
            cards: Array(cards.prefix(2))
        )
    }

    static func resolve(from memories: [ContextMemory]) -> DreamBriefingDocument? {
        let active = memories.filter { $0.status != "forgotten" }
        if let briefing = active.first(where: { $0.kind == "briefing" }) {
            return parse(markdown: briefing.text)
        }
        // Fallback: if BRIEFING.md hasn't been written yet, synthesize up to 2 cards from recent journal/topic/person notes
        let notebookItems = active.filter { ["journal", "topic", "person"].contains($0.kind) }
        guard !notebookItems.isEmpty else { return nil }
        var synthesized: [DreamBriefingCard] = []
        for (idx, item) in notebookItems.prefix(2).enumerated() {
            let lines = item.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let heading = lines.first?.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) ?? "近期脉络整理"
            let excerpt = lines.dropFirst().first { !$0.hasPrefix("#") } ?? heading
            let subtitle: String
            let motif: DreamDotMatrixKind
            switch item.kind {
            case "journal":
                subtitle = "回顾近期每日日志"
                motif = .lifeFlow
            case "person":
                subtitle = "串联人物协作上下文"
                motif = .relationWeave
            default:
                subtitle = "接着推进主题活页"
                motif = idx == 0 ? .memoryLoop : .voiceWave
            }
            synthesized.append(
                DreamBriefingCard(
                    id: "synth-\(item.id)",
                    title: String(heading.prefix(16)),
                    subtitle: subtitle,
                    prompt: "请结合我的「\(heading)」笔记（\(excerpt.prefix(80))），帮我梳理下一步重点。",
                    motif: motif
                )
            )
        }
        return DreamBriefingDocument(
            headline: "Dream 活页脉络",
            overview: "已根据近期对话与录音整理出 \(notebookItems.count) 篇 Markdown 活页笔记。",
            rawMarkdown: notebookItems.map(\.text).joined(separator: "\n\n---\n\n"),
            cards: synthesized
        )
    }
}

struct DreamHomeCardsSection: View {
    let document: DreamBriefingDocument
    @Binding var dismissedIDs: Set<String>
    let onSelectCard: (DreamBriefingCard) -> Void
    let onOpenBriefing: () -> Void
    let onOpenNotebook: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var visibleCards: [DreamBriefingCard] {
        document.cards.filter { !dismissedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpenBriefing) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MoMoPalette.ink)
                    Text(document.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MoMoPalette.ink)
                    Text("·")
                        .foregroundStyle(MoMoPalette.muted)
                    Text(document.overview)
                        .font(.system(size: 12))
                        .foregroundStyle(MoMoPalette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MoMoPalette.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(MoMoPalette.line, lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assistant.dreamBriefingBanner")

            if visibleCards.count == 1, let single = visibleCards.first {
                singleCardView(single)
            } else if visibleCards.count >= 2 {
                HStack(spacing: 12) {
                    ForEach(visibleCards.prefix(2)) { card in
                        dualCardView(card)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func dualCardView(_ card: DreamBriefingCard) -> some View {
        Button {
            dismissedIDs.insert(card.id)
            onSelectCard(card)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                DreamDotMatrixArtwork(kind: card.motif, isDark: isDark)
                    .frame(height: 86)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.horizontal, 8)
                Spacer(minLength: 8)
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(card.motif.titleColor(isDark: isDark))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text(card.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(card.motif.subtitleColor(isDark: isDark))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(card.motif.subtitleColor(isDark: isDark))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, minHeight: 192, maxHeight: 204, alignment: .topLeading)
            .background(card.motif.surfaceColor(isDark: isDark), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("assistant.suggestion.\(card.id)")
        .contextMenu {
            Button("查看晨间简报", systemImage: "doc.richtext", action: onOpenBriefing)
            Button("打开记忆笔记本", systemImage: "book.pages", action: onOpenNotebook)
            Button("暂时收起", systemImage: "eye.slash") {
                dismissedIDs.insert(card.id)
            }
        }
    }

    private func singleCardView(_ card: DreamBriefingCard) -> some View {
        Button {
            dismissedIDs.insert(card.id)
            onSelectCard(card)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(card.motif.titleColor(isDark: isDark))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(card.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(card.motif.subtitleColor(isDark: isDark))
                            .lineLimit(2)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(card.motif.subtitleColor(isDark: isDark))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DreamDotMatrixArtwork(kind: card.motif, isDark: isDark)
                    .frame(width: 118, height: 84)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 152)
            .background(card.motif.surfaceColor(isDark: isDark), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("assistant.suggestion.\(card.id)")
        .contextMenu {
            Button("查看晨间简报", systemImage: "doc.richtext", action: onOpenBriefing)
            Button("打开记忆笔记本", systemImage: "book.pages", action: onOpenNotebook)
            Button("暂时收起", systemImage: "eye.slash") {
                dismissedIDs.insert(card.id)
            }
        }
    }
}
