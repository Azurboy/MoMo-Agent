import SwiftUI
import CoreText
import Observation
import OSLog
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

@MainActor @Observable
final class MoMoHandwritingFont {
    static let shared = MoMoHandwritingFont()
    private(set) var regularName: String?
    private(set) var emphasizedName: String?

    private init() {
        refreshAvailableFonts()
        // Asset discovery and registration run once, without blocking the first page draw.
        Task.detached(priority: .userInitiated) {
            Self.registerLocalAssets()
            await self.refreshAvailableFonts()
            let descriptors = ["HanziPenSC-W3", "HanziPenSC-W5"].map {
                CTFontDescriptorCreateWithAttributes([
                    kCTFontNameAttribute: $0,
                    kCTFontDownloadableAttribute: true
                ] as CFDictionary)
            }
            let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { state, _ in
                if state == .didMatch || state == .didFinish {
                    Task { @MainActor in self.refreshAvailableFonts() }
                } else if state == .didFailWithError {
                    Logger(subsystem: "com.momoagent.client", category: "Handwriting")
                        .notice("System handwriting activation unavailable; keeping the installed fallback.")
                }
                return true
            }
            if !started {
                Logger(subsystem: "com.momoagent.client", category: "Handwriting")
                    .notice("System handwriting matching could not start.")
            }
        }
    }

    private func refreshAvailableFonts() {
        let fallbacks = ["Klee-Medium", "YuppySC-Regular", "STKaitiSC-Regular", "Kaiti SC", "Noteworthy-Light"]
        regularName = Self.availableName(in: ["HanziPenSC-W3", "HanziPenSC-W5"] + fallbacks)
        emphasizedName = Self.availableName(in: ["HanziPenSC-W5", "HanziPenSC-W3"] + fallbacks)
    }

    private static func availableName(in names: [String]) -> String? {
        for name in names {
            #if os(macOS)
            if let font = NSFont(name: name, size: 18) { return font.fontName }
            #else
            if let font = UIFont(name: name, size: 18) { return font.fontName }
            #endif
        }
        return nil
    }

    private nonisolated static func registerLocalAssets() {
        #if os(macOS) || targetEnvironment(simulator)
        let filenames: Set<String> = ["hanzipen.ttc", "klee.ttc", "yuppysc-regular.otf", "kaiti.ttc"]
        var registered: Set<String> = []
        for version in [8, 7] {
            let root = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_Font\(version)", isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path),
                  let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files {
                let name = url.lastPathComponent.lowercased()
                guard filenames.contains(name), !registered.contains(name) else { continue }
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    registered.insert(name)
                } else if let failure = error?.takeRetainedValue(),
                          CFErrorGetCode(failure) != CTFontManagerError.alreadyRegistered.rawValue {
                    Logger(subsystem: "com.momoagent.client", category: "Handwriting")
                        .notice("Local handwriting registration failed: \(String(describing: failure), privacy: .public)")
                }
            }
        }
        #endif
    }
}

private struct MoMoHandwritingModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let relativeTo: Font.TextStyle
    @ScaledMetric private var fallbackSize: CGFloat
    @Environment(\.legibilityWeight) private var legibilityWeight

    init(size: CGFloat, weight: Font.Weight, relativeTo: Font.TextStyle) {
        self.size = size
        self.weight = weight
        self.relativeTo = relativeTo
        _fallbackSize = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
    }

    func body(content: Content) -> some View {
        let fonts = MoMoHandwritingFont.shared
        let weight = legibilityWeight == .bold ? Font.Weight.bold : weight
        let emphasized = [Font.Weight.medium, .semibold, .bold, .heavy, .black].contains(weight)
        let name = emphasized ? fonts.emphasizedName : fonts.regularName
        content
            .font(name.map { Font.custom($0, size: size, relativeTo: relativeTo).weight(weight) }
                  ?? .system(size: fallbackSize, weight: weight, design: .serif))
            .tracking(0.4)
    }
}

extension View {
    func momoHandwriting(size: CGFloat, weight: Font.Weight = .regular,
                         relativeTo: Font.TextStyle = .body) -> some View {
        modifier(MoMoHandwritingModifier(size: size, weight: weight, relativeTo: relativeTo))
    }

    func memoryNotebookPage(borderless: Bool = false) -> some View {
        self.padding(.horizontal, borderless ? 0 : 22)
            .padding(.vertical, borderless ? 0 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if !borderless {
                    MemoryNotebookPaper()
                }
            }
    }
}

struct MemoryNotebookPalette {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }
    var paper: Color { MoMoPalette.paper }
    var stackedPaper: Color { MoMoPalette.paper }
    var desk: Color { MoMoPalette.canvas }
    var surface: Color { MoMoPalette.surface }
    var line: Color { MoMoPalette.line }
    var ink: Color { MoMoPalette.ink }
    var secondaryInk: Color { MoMoPalette.muted }
    var margin: Color { MoMoPalette.failure }

    func tab(_ kind: String) -> Color {
        MoMoPalette.surface
    }

    func tabAccent(_ kind: String) -> Color {
        switch kind {
        case "briefing": dark ? Self.rgb(0x9C95DC) : Self.rgb(0x6B63B5)
        case "project": dark ? Self.rgb(0x7BA4CF) : Self.rgb(0x4A78A8)
        case "journal": dark ? Self.rgb(0x72B59D) : Self.rgb(0x3F8A71)
        case "person": dark ? Self.rgb(0xCFA082) : Self.rgb(0xA66E4E)
        case "topic": dark ? Self.rgb(0x76AAB8) : Self.rgb(0x467F91)
        default: dark ? Self.rgb(0x9A9A96) : Self.rgb(0x6E6E6A)
        }
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private struct MemoryNotebookPaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colors.paper)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(colors.line, lineWidth: 0.7)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct MemoryBinderTab: View {
    let category: DreamMemoryCategory
    let isSelected: Bool

    var body: some View {
        let pill = Text(category.title)
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? MoMoPalette.canvas : MoMoPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? MoMoPalette.ink : MoMoPalette.surface, in: Capsule())

        #if os(macOS)
        pill
            .frame(minHeight: 30)
            .contentShape(Capsule())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        #else
        pill
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        #endif
    }
}

private final class CachedMemoryCardDigestBox: NSObject {
    let digest: MemoryCardDigest
    init(_ digest: MemoryCardDigest) { self.digest = digest }
}

struct MemoryCardDigest: Equatable, Sendable {
    let badge: (title: String, symbol: String)
    let dateBadge: String?
    let sourceNote: String?
    let statusBadge: String?
    let title: String
    let highlights: [String]
    let sectionPills: [String]
    let linkedPaths: [String]
    let cleanedNotebookMarkdown: String
    let isNotebookMarkdown: Bool

    private nonisolated(unsafe) static let cache: NSCache<NSString, CachedMemoryCardDigestBox> = {
        let c = NSCache<NSString, CachedMemoryCardDigestBox>()
        c.countLimit = 1024
        return c
    }()

    private static let stampRegex = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:[–—-]\d{1,2})?)\s*(?:录音\s*)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?:\s+v\d+(?:[–—-]\d+)?)?\s*(?:[（(]([^）)]*)[）)])?\s*[：:]?\s*"#
    )
    private static let dateInHeadingRegex = try? NSRegularExpression(pattern: #"\b(20\d{2}-\d{2}-\d{2})\b"#)
    private static let boldHeaderRegex = try? NSRegularExpression(
        pattern: #"^\*\*【?([^】*]+)】?\*\*\s*(?:[（(](\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:[–—-]\d{1,2})?)[）)])?\s*[：:]\s*"#
    )
    private static let leadDateRegex = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:[–—-]\d{1,2})?)\s+"#
    )
    private static let sourceLinkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(momoagent://source/[^)]+\)"#)
    private static let timeLabelRegex = try? NSRegularExpression(pattern: #"\[(\d{1,2}:\d{2})\s*原音\]"#)
    private static let uuidWithTagRegex = try? NSRegularExpression(
        pattern: #"(?:录音\s*)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?:\s+v\d+(?:[–—-]\d+)?)?"#
    )
    private static let hexEpochRegex = try? NSRegularExpression(
        pattern: #"(?<![0-9a-fA-F])[0-9a-fA-F]{8}\s+17[89]\d{7}(?:[–—-]\d{4,10})?(?![0-9])"#
    )
    private static let epochRegex = try? NSRegularExpression(
        pattern: #"(?<![0-9a-fA-F])17[89]\d{7}(?:[–—-]\d{4,10})?(?![0-9])"#
    )
    private static let disclaimerRegex = try? NSRegularExpression(
        pattern: #"[（(]\s*(?:归属\s*/\s*执行未核|归属未核|执行未核)\s*[）)]\s*[：:]?"#
    )
    private static let multiSpaceRegex = try? NSRegularExpression(pattern: #"\s{2,}"#)
    private static let notebookRefRegex = try? NSRegularExpression(
        pattern: #"`((?:projects|topics|people|journal)/[^`\s]+\.md|BRIEFING\.md|MEMORY\.md|USER\.md)`"#
    )
    private static let bareUUIDRegex = try? NSRegularExpression(
        pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    )

    static func cached(for memory: ContextMemory) -> MemoryCardDigest {
        let key = "\(memory.id)|\(memory.revision)|\(memory.status)|\(memory.text.utf8.count)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit.digest
        }
        let built = MemoryCardDigest(memory: memory)
        cache.setObject(CachedMemoryCardDigestBox(built), forKey: key)
        return built
    }

    static func == (lhs: MemoryCardDigest, rhs: MemoryCardDigest) -> Bool {
        lhs.badge.title == rhs.badge.title
            && lhs.dateBadge == rhs.dateBadge
            && lhs.title == rhs.title
            && lhs.highlights == rhs.highlights
            && lhs.sectionPills == rhs.sectionPills
    }

    init(memory: ContextMemory) {
        self.badge = DreamMemoryCategory.badge(for: memory)
        self.isNotebookMarkdown = ["briefing", "project", "journal", "person", "topic"].contains(memory.kind)
            || (memory.path?.lowercased().hasSuffix(".md") == true)
        if memory.status == "stale" {
            self.statusBadge = "原文已改变"
        } else if memory.basis == "inferred" {
            self.statusBadge = "模型推断"
        } else {
            self.statusBadge = nil
        }

        let trimmed = memory.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var extractedDate: String? = nil
        var extractedNote: String? = nil
        var bodyText = trimmed

        if let regex = Self.stampRegex,
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let stampRange = Range(match.range, in: trimmed),
           let dateRange = Range(match.range(at: 1), in: trimmed) {
            let remainder = String(trimmed[stampRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                extractedDate = String(trimmed[dateRange])
                if let noteRange = Range(match.range(at: 2), in: trimmed) {
                    let note = String(trimmed[noteRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !note.isEmpty && !note.contains("未核") {
                        extractedNote = note
                    }
                }
                bodyText = remainder
            }
        }

        if isNotebookMarkdown {
            let lines = bodyText.components(separatedBy: .newlines)
            var rawHeading: String? = nil
            var sections: [String] = []
            var bullets: [String] = []
            var paragraphs: [String] = []

            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("```") else { continue }
                if line.hasPrefix("# ") && rawHeading == nil {
                    rawHeading = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("## ") || line.hasPrefix("### ") {
                    if sections.count < 4 {
                        var sec = String(line.drop(while: { $0 == "#" || $0 == " " }))
                        if sec.hasPrefix("卡片：") || sec.hasPrefix("卡片:") || sec.hasPrefix("建议：") || sec.hasPrefix("建议:") {
                            sec = String(sec.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        }
                        sec = sec.replacingOccurrences(of: "（注绝对日期）", with: "")
                        let cleanSec = Self.cleanInlineNoise(sec)
                        if !cleanSec.isEmpty && !sections.contains(cleanSec) {
                            sections.append(cleanSec)
                        }
                    }
                    continue
                }
                if line.hasPrefix("- 纹样：") || line.hasPrefix("- 纹样:") || line.hasPrefix("- 语境：") || line.hasPrefix("- 语境:") {
                    continue
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    if bullets.count < 3 {
                        let item = Self.cleanInlineNoise(String(line.dropFirst(2)))
                        if !item.isEmpty {
                            bullets.append(item)
                        }
                    }
                } else if !line.hasPrefix("#") && paragraphs.count < 3 {
                    let para = Self.cleanInlineNoise(line)
                    if !para.isEmpty {
                        paragraphs.append(para)
                    }
                }
            }

            var resolvedHeading: String
            if let rawHeading, !rawHeading.isEmpty {
                resolvedHeading = rawHeading
            } else if let meaningfulSec = sections.first(where: { sec in
                !sec.contains("来源与边界") && !sec.contains("本批来源") && !sec.contains("整理进度") && !sec.contains("当前卡点") && !sec.contains("当前共识") && !sec.contains("当前脉络")
            }) {
                resolvedHeading = meaningfulSec.replacingOccurrences(
                    of: #"^\d{1,2}:\d{2}(?:[–—-]\d{1,2}:\d{2})?\s*[·•—–:：-]?\s*"#,
                    with: "",
                    options: .regularExpression
                )
            } else if let rawPath = memory.path, !rawPath.isEmpty {
                resolvedHeading = Self.humanizeNotebookPath(rawPath)
            } else {
                resolvedHeading = Self.badgeTitleFallback(for: memory.kind)
            }
            if extractedDate == nil,
               let dateRegex = Self.dateInHeadingRegex,
               let m = dateRegex.firstMatch(in: resolvedHeading, range: NSRange(resolvedHeading.startIndex..., in: resolvedHeading)),
               let r = Range(m.range(at: 1), in: resolvedHeading) {
                extractedDate = String(resolvedHeading[r])
                let stripped = resolvedHeading
                    .replacingOccurrences(of: extractedDate!, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ·•-—–:："))
                if !stripped.isEmpty {
                    resolvedHeading = stripped
                }
            }
            self.title = Self.cleanInlineNoise(resolvedHeading)
            let candidateHighlights = bullets.isEmpty ? paragraphs : bullets
            self.highlights = Array(candidateHighlights.prefix(2))
            self.sectionPills = Array(sections.prefix(4))
            var refs: [String] = []
            if let regex = Self.notebookRefRegex {
                for match in regex.matches(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)) {
                    if let r = Range(match.range(at: 1), in: bodyText) {
                        let ref = String(bodyText[r])
                        if !refs.contains(ref) {
                            refs.append(ref)
                        }
                    }
                }
            }
            self.linkedPaths = refs
            self.cleanedNotebookMarkdown = Self.cleanNotebookMarkdownForDetail(bodyText)
        } else {
            var working = bodyText
            var explicitTitle: String? = nil

            if let regex = Self.boldHeaderRegex,
               let m = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
               let fullRange = Range(m.range, in: working),
               let titleRange = Range(m.range(at: 1), in: working) {
                explicitTitle = Self.cleanInlineNoise(String(working[titleRange]))
                if extractedDate == nil, let dRange = Range(m.range(at: 2), in: working) {
                    extractedDate = String(working[dRange])
                }
                working = String(working[fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if extractedDate == nil,
                      let regex = Self.leadDateRegex,
                      let m = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
                      let fullRange = Range(m.range, in: working),
                      let dRange = Range(m.range(at: 1), in: working) {
                let rem = String(working[fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rem.isEmpty {
                    extractedDate = String(working[dRange])
                    working = rem
                }
            }

            let cleanedBody = Self.cleanInlineNoise(working)
            let clauses = cleanedBody
                .components(separatedBy: CharacterSet(charactersIn: "；;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let explicitTitle, !explicitTitle.isEmpty {
                self.title = explicitTitle
                if clauses.count > 1 {
                    self.highlights = Array(clauses.prefix(2))
                } else {
                    let sentences = Self.splitSentences(cleanedBody)
                    self.highlights = Array(sentences.prefix(2))
                }
            } else if clauses.count >= 2 {
                self.title = clauses[0]
                self.highlights = Array(clauses.dropFirst().prefix(2))
            } else {
                let sentences = Self.splitSentences(cleanedBody)
                if sentences.count >= 2 {
                    self.title = sentences[0]
                    self.highlights = Array(sentences.dropFirst().prefix(2))
                } else {
                    self.title = cleanedBody.isEmpty ? trimmed : cleanedBody
                    self.highlights = []
                }
            }
            self.sectionPills = []
            self.linkedPaths = []
            self.cleanedNotebookMarkdown = bodyText
        }

        self.dateBadge = extractedDate
        self.sourceNote = extractedNote
    }

    private final class CachedChildrenMapBox: NSObject {
        let map: [String: [ContextMemory]]
        init(_ map: [String: [ContextMemory]]) { self.map = map }
    }

    private nonisolated(unsafe) static let childrenMapCache: NSCache<NSString, CachedChildrenMapBox> = {
        let cache = NSCache<NSString, CachedChildrenMapBox>()
        cache.countLimit = 8
        return cache
    }()

    static func memoriesSignature(_ memories: [ContextMemory]) -> String {
        var hasher = Hasher()
        hasher.combine(memories.count)
        for item in memories {
            hasher.combine(item.id)
            hasher.combine(item.revision)
            hasher.combine(item.status)
            hasher.combine(item.kind)
            hasher.combine(item.path)
            hasher.combine(item.text.utf8.count)
        }
        return "\(memories.count):\(hasher.finalize())"
    }

    static func linkedChildrenMap(for allMemories: [ContextMemory]) -> [String: [ContextMemory]] {
        let active = allMemories.filter { $0.status != "forgotten" }
        guard !active.isEmpty else { return [:] }
        let key = memoriesSignature(active) as NSString
        if let hit = childrenMapCache.object(forKey: key) {
            return hit.map
        }
        var built: [String: [ContextMemory]] = [:]
        built.reserveCapacity(active.count)
        for parent in active {
            let digest = cached(for: parent)
            guard !digest.linkedPaths.isEmpty else { continue }
            var children: [ContextMemory] = []
            for relPath in digest.linkedPaths {
                let encoded = relPath
                    .split(separator: "/")
                    .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                    .joined(separator: "/")
                guard let url = URL(string: "momoagent://memory/\(encoded)"),
                      let target = DreamMemoryLinkResolver.resolve(url: url, in: active),
                      target.id != parent.id,
                      !children.contains(where: { $0.id == target.id }) else { continue }
                children.append(target)
            }
            if !children.isEmpty {
                built[parent.id] = children
            }
        }
        childrenMapCache.setObject(CachedChildrenMapBox(built), forKey: key)
        return built
    }

    private nonisolated(unsafe) static let backlinksMapCache: NSCache<NSString, CachedChildrenMapBox> = {
        let cache = NSCache<NSString, CachedChildrenMapBox>()
        cache.countLimit = 8
        return cache
    }()

    static func linkedChildren(for parent: ContextMemory, in allMemories: [ContextMemory]) -> [ContextMemory] {
        linkedChildrenMap(for: allMemories)[parent.id] ?? []
    }

    static func backlinksMap(for allMemories: [ContextMemory]) -> [String: [ContextMemory]] {
        let active = allMemories.filter { $0.status != "forgotten" }
        guard !active.isEmpty else { return [:] }
        let key = memoriesSignature(active) as NSString
        if let hit = backlinksMapCache.object(forKey: key) {
            return hit.map
        }
        let outgoing = linkedChildrenMap(for: active)
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        var incoming: [String: [ContextMemory]] = [:]
        for (sourceID, targets) in outgoing {
            guard let source = byID[sourceID] else { continue }
            for target in targets where target.id != sourceID {
                var list = incoming[target.id] ?? []
                if !list.contains(where: { $0.id == source.id }) {
                    list.append(source)
                }
                incoming[target.id] = list
            }
        }
        for (targetID, sources) in incoming {
            incoming[targetID] = DreamMemoryCategory.sortMemories(sources)
        }
        backlinksMapCache.setObject(CachedChildrenMapBox(incoming), forKey: key)
        return incoming
    }

    static func backlinks(for target: ContextMemory, in allMemories: [ContextMemory]) -> [ContextMemory] {
        backlinksMap(for: allMemories)[target.id] ?? []
    }
}

struct MemoryVaultRowMeta: Equatable, Sendable {
    let title: String
    let symbol: String
    let badgeTitle: String
    let dateBadge: String?
    let shortJournalDate: String?
}

struct MemoryVaultSnapshot: Equatable, Sendable {
    let activeMemories: [ContextMemory]
    let byID: [String: ContextMemory]
    let rowMetaByID: [String: MemoryVaultRowMeta]
    let searchTextByID: [String: String]
    let folders: [DreamMemorySection]
    let defaultExpandedFolderIDs: Set<String>
    let flatVisibleItems: [ContextMemory]
    let siblingsByMemoryID: [String: [ContextMemory]]
    let childrenByParentID: [String: [ContextMemory]]
    let backlinksByTargetID: [String: [ContextMemory]]
    let briefingDocument: DreamBriefingDocument?

    static let empty = MemoryVaultSnapshot(
        activeMemories: [],
        byID: [:],
        rowMetaByID: [:],
        searchTextByID: [:],
        folders: [],
        defaultExpandedFolderIDs: [],
        flatVisibleItems: [],
        siblingsByMemoryID: [:],
        childrenByParentID: [:],
        backlinksByTargetID: [:],
        briefingDocument: nil
    )

    nonisolated static func build(from memories: [ContextMemory]) -> MemoryVaultSnapshot {
        let active = memories.filter { $0.status != "forgotten" }
        guard !active.isEmpty else { return .empty }

        var byID: [String: ContextMemory] = [:]
        byID.reserveCapacity(active.count)
        var rowMetaByID: [String: MemoryVaultRowMeta] = [:]
        rowMetaByID.reserveCapacity(active.count)
        var searchTextByID: [String: String] = [:]
        searchTextByID.reserveCapacity(active.count)

        for item in active {
            byID[item.id] = item
            let digest = MemoryCardDigest.cached(for: item)
            let shortDate: String? = (item.kind == "journal") ? digest.dateBadge.map { String($0.suffix(5)) } : nil
            rowMetaByID[item.id] = MemoryVaultRowMeta(
                title: digest.title,
                symbol: digest.badge.symbol,
                badgeTitle: digest.badge.title,
                dateBadge: digest.dateBadge,
                shortJournalDate: shortDate
            )
            searchTextByID[item.id] = "\(digest.title)\n\(digest.badge.title)\n\(item.text)".lowercased()
            if digest.isNotebookMarkdown {
                _ = MarkdownDocument.cached(digest.cleanedNotebookMarkdown)
                #if os(macOS)
                MacMarkdownRenderer.prewarm(digest.cleanedNotebookMarkdown, handwriting: true, plainTextOnly: false)
                #endif
            } else {
                #if os(macOS)
                MacMarkdownRenderer.prewarm(item.text, handwriting: true, plainTextOnly: true)
                #endif
            }
        }

        let folders = DreamMemoryCategory.directoryFolders(from: active)
        let defaultExpanded = DreamMemoryCategory.defaultExpandedFolderIDs(for: folders)
        let flatItems = folders.flatMap(\.items)

        var siblingsByID: [String: [ContextMemory]] = [:]
        siblingsByID.reserveCapacity(active.count)
        for folder in folders {
            let group = folder.items.count > 1 ? folder.items : (flatItems.count > 1 ? flatItems : folder.items)
            for item in folder.items {
                siblingsByID[item.id] = group
            }
        }

        let childrenMap = MemoryCardDigest.linkedChildrenMap(for: active)
        let backlinksMap = MemoryCardDigest.backlinksMap(for: active)
        let briefing = DreamBriefingDocument.resolve(from: active)

        return MemoryVaultSnapshot(
            activeMemories: active,
            byID: byID,
            rowMetaByID: rowMetaByID,
            searchTextByID: searchTextByID,
            folders: folders,
            defaultExpandedFolderIDs: defaultExpanded,
            flatVisibleItems: flatItems,
            siblingsByMemoryID: siblingsByID,
            childrenByParentID: childrenMap,
            backlinksByTargetID: backlinksMap,
            briefingDocument: briefing
        )
    }

    func filteredFolders(matching rawQuery: String) -> [DreamMemorySection] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return folders }
        return folders.compactMap { folder in
            let matches = folder.items.filter { item in
                (searchTextByID[item.id] ?? "").contains(q)
            }
            return matches.isEmpty
                ? nil
                : DreamMemorySection(id: folder.id, title: folder.title, subtitle: folder.subtitle, items: matches)
        }
    }
}

extension MemoryCardDigest {

    static func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func buildInstructionPrompt(for memory: ContextMemory, instruction: String) -> String {
        let digest = cached(for: memory)
        let location = memory.path ?? "\(memory.kind)/\(memory.id)"
        return """
        请针对记忆笔记 `\(location)`（标题：\(digest.title)）执行以下修改与溯源纠偏指令：
        「\(instruction.trimmingCharacters(in: .whitespacesAndNewlines))」
        请使用原生工具完成闭环：
        1. 若涉及说话人归属或原音核对，先用 `search_recordings` / `read_recording` 找到对应录音 `source_id` 与精确 `span_ids`，调用 `relabel_recording_speakers` 修正说话人标签并同步回写 iPhone 声纹库（若原标签已是具名人物或“我”、仅局部片段被串轨误标，务必传精确 `span_ids` 且 `scope="selection"`，避免误改同场其他发言；若原标签为整组匿名 `[说话人 N]` 可用 `scope="cluster"`）；
        2. 用 `read_memory_notebook` / `write_memory_notebook` / `update_core_memory` 同步修改当前笔记以及所有关联的 `journal/*.md`、`projects/*.md`、`people/*.md`、`topics/*.md`、`BRIEFING.md` 与 `MEMORY.md`，顺手清除正文中残留的 `remaining_parts` 或 `revision` 等内部调试字样。
        """
    }

    #if os(macOS)
    static func shareText(_ text: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [text])
        let anchor = NSRect(x: contentView.bounds.maxX - 48, y: contentView.bounds.maxY - 64, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }
    #endif

    private static func badgeTitleFallback(for kind: String) -> String {
        switch kind {
        case "briefing": return "晨间简报"
        case "project": return "在研项目活页"
        case "journal": return "每日生活日志"
        case "person": return "人物脉络笔记"
        case "topic": return "主题活页笔记"
        case "user": return "关于你的偏好"
        default: return "核心记忆"
        }
    }

    private static func splitSentences(_ text: String) -> [String] {
        text.components(separatedBy: "。")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix("。") ? $0 : $0 + "。" }
    }

    private static func replace(_ regex: NSRegularExpression?, in string: String, with template: String) -> String {
        guard let regex else { return string }
        return regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template)
    }

    static func cleanInlineNoise(_ raw: String) -> String {
        var s = raw
        if s.contains("momoagent://source/") {
            s = replace(sourceLinkRegex, in: s, with: "[$1]")
        }
        if s.contains("原音]") {
            s = replace(timeLabelRegex, in: s, with: "[$1]")
        }
        if s.contains("-") {
            s = replace(uuidWithTagRegex, in: s, with: "")
        }
        if s.contains("178") || s.contains("179") {
            s = replace(hexEpochRegex, in: s, with: "")
            s = replace(epochRegex, in: s, with: "")
        }
        if s.contains("未核") {
            s = replace(disclaimerRegex, in: s, with: "")
        }
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = replace(multiSpaceRegex, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func humanizeNotebookPath(_ relPath: String) -> String {
        let lower = relPath.lowercased()
        if lower == "briefing.md" { return "晨间简报" }
        if lower == "memory.md" { return "核心记忆" }
        if lower == "user.md" { return "关于你" }
        let parts = relPath.split(separator: "/")
        let filename = String(parts.last ?? Substring(relPath))
        let stem = filename.replacingOccurrences(of: #"\.md$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let knownTitles: [String: String] = [
            "ai-user-research": "AI访谈与用研平台",
            "diary-study": "日记法",
            "recruitment-freeze": "招募冻结",
            "ceo-communication": "CEO沟通机制",
            "industry-interviewer": "行业主持人",
            "emotion-understanding": "情绪理解",
            "overview": "在研项目总览",
            "momo-agent": "MoMo智能体",
            "fgd": "焦点小组(FGD)",
        ]
        if let mapped = knownTitles[stem.lowercased()] {
            return mapped
        }
        if parts.first?.lowercased() == "people" {
            return stem
        }
        return stem.replacingOccurrences(of: "-", with: " ")
    }

    static func cleanNotebookMarkdownForDetail(_ markdown: String) -> String {
        var s = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading # H1 line when body content follows (header margin renders digest.title),
        // and strip legacy internal ingestion boilerplate sections (## 来源与边界 / remaining_parts=).
        let rawLines = s.components(separatedBy: .newlines)
        var filteredLines: [String] = []
        filteredLines.reserveCapacity(rawLines.count)
        var skippingBoilerplateSection = false
        for (idx, rawLine) in rawLines.enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if idx == 0 && trimmedLine.hasPrefix("# ") && rawLines.count > 1 {
                continue
            }
            if trimmedLine.hasPrefix("## ") || trimmedLine.hasPrefix("### ") {
                let headingTitle = String(trimmedLine.drop(while: { $0 == "#" || $0 == " " }))
                if headingTitle == "来源与边界" || headingTitle == "本批来源与边界" || headingTitle == "整理进度" {
                    skippingBoilerplateSection = true
                    continue
                }
                skippingBoilerplateSection = false
            }
            if skippingBoilerplateSection {
                continue
            }
            if trimmedLine.contains("remaining_parts=") || trimmedLine.contains("不代表读完该录音") || trimmedLine.contains("不代表复读了整场录音") {
                continue
            }
            filteredLines.append(rawLine)
        }
        let joined = filteredLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            s = joined
        }
        if s.contains("momoagent://source/") {
            s = replace(sourceLinkRegex, in: s, with: "`⏱ $1`")
        }
        if s.contains("`"), let regex = notebookRefRegex {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
            for match in matches {
                guard var fullRange = Range(match.range, in: s),
                      let pathRange = Range(match.range(at: 1), in: s) else { continue }
                let relPath = String(s[pathRange])
                let encoded = relPath
                    .split(separator: "/")
                    .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                    .joined(separator: "/")
                let friendly = Self.humanizeNotebookPath(relPath)
                let prefixSlice = s[..<fullRange.lowerBound]
                let lineStart = prefixSlice.lastIndex(of: "\n") ?? s.startIndex
                let linePrefix = String(s[lineStart..<fullRange.lowerBound])
                if linePrefix.hasSuffix(" · ") || linePrefix.hasSuffix(" ·") {
                    if let dotRange = linePrefix.range(of: #"\s*·\s*$"#, options: .regularExpression) {
                        let distance = linePrefix.distance(from: dotRange.lowerBound, to: linePrefix.endIndex)
                        let adjustedLower = s.index(fullRange.lowerBound, offsetBy: -distance)
                        fullRange = adjustedLower..<fullRange.upperBound
                    }
                    s.replaceSubrange(fullRange, with: "  [[\(friendly)]](momoagent://memory/\(encoded))")
                } else {
                    s.replaceSubrange(fullRange, with: "[[\(friendly)]](momoagent://memory/\(encoded))")
                }
            }
        }
        if s.contains("-") {
            s = replace(bareUUIDRegex, in: s, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MemoryCardView: View {
    let memory: ContextMemory
    var childCount: Int = 0
    var isExpanded: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let digest = MemoryCardDigest.cached(for: memory)
        let colors = MemoryNotebookPalette(scheme: scheme)
        HStack(alignment: .center, spacing: 9) {
            if childCount > 0 {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(colors.secondaryInk)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: digest.badge.symbol)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(colors.tabAccent(memory.kind))
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }

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
                if let firstHighlight = digest.highlights.first, childCount == 0 {
                    Text(firstHighlight)
                        .font(.system(size: 12))
                        .foregroundStyle(colors.secondaryInk)
                        .lineLimit(1)
                }
            }

            if childCount > 0 {
                Text("\(childCount)")
                    .font(.system(size: 11.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(colors.secondaryInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(colors.surface, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([digest.badge.title, digest.dateBadge, digest.statusBadge, digest.title]
            .compactMap { $0 } + digest.highlights + [childCount > 0 ? (isExpanded ? "收起子项" : "展开子项") : "查看全文"]).joined(separator: "，"))
    }
}

private struct ObsidianTagFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 7
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                usedWidth = max(usedWidth, x)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += (x > 0 ? horizontalSpacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ClientMemoryContent: View {
    let memory: ContextMemory
    var allMemories: [ContextMemory] = []
    var siblingItems: [ContextMemory] = []
    var precomputedOutgoing: [ContextMemory]? = nil
    var precomputedIncoming: [ContextMemory]? = nil
    var onSelectSibling: ((ContextMemory) -> Void)? = nil
    var onSelectLinkedMemory: ((ContextMemory) -> Void)? = nil
    var backLabel: String? = nil
    var onBack: (() -> Void)? = nil
    var canGoForward: Bool = false
    var onForward: (() -> Void)? = nil
    var onOpenFullNotebook: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var borderless: Bool = false
    var sourceLookup: ((ContextMemory.Evidence) -> ContextSource?)? = nil
    var onOpenSource: ((ContextSource) -> Void)? = nil
    var onInstruct: ((String) async throws -> Void)? = nil
    @State private var showEvidence = false
    @State private var showBacklinks = true
    @State private var copied = false
    @State private var showingInstructionBar = false
    @State private var instructionDraft = ""
    @State private var submittingInstruction = false
    @State private var instructionReceipt: String? = nil
    @State private var instructionError: String? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    private var titleSize: CGFloat {
        #if os(macOS)
        return 22
        #else
        return 20
        #endif
    }

    private var plainBodySize: CGFloat {
        #if os(macOS)
        return 14
        #else
        return 15
        #endif
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

    var body: some View {
        let digest = MemoryCardDigest.cached(for: memory)
        let colors = MemoryNotebookPalette(scheme: scheme)
        let outgoingMemories = precomputedOutgoing ?? (allMemories.isEmpty ? [] : MemoryCardDigest.linkedChildren(for: memory, in: allMemories))
        let incomingMemories = precomputedIncoming ?? (allMemories.isEmpty ? [] : MemoryCardDigest.backlinks(for: memory, in: allMemories))

        VStack(alignment: .leading, spacing: 16) {
            // Obsidian-style top pane header: [< >] + Folder › Note breadcrumb + overflow
            HStack(alignment: .center, spacing: 6) {
                if onBack != nil || onForward != nil {
                    HStack(spacing: 2) {
                        Button {
                            onBack?()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(onBack != nil ? colors.ink : colors.secondaryInk.opacity(0.35))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onBack == nil)
                        .help(backLabel ?? "后退")
                        .accessibilityLabel(backLabel ?? "返回")

                        if onForward != nil {
                            Button {
                                onForward?()
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(canGoForward ? colors.ink : colors.secondaryInk.opacity(0.35))
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canGoForward)
                            .help("前进")
                            .accessibilityLabel("前进")
                        }
                    }
                    .padding(.horizontal, 2)
                    .background(colors.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // Breadcrumb path: Folder › Note
                HStack(spacing: 5) {
                    Image(systemName: DreamMemoryCategory.folderSymbol(for: memory.kind))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.tabAccent(memory.kind))
                    Text(folderBreadcrumbTitle(for: memory.kind))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(colors.secondaryInk)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(colors.secondaryInk.opacity(0.55))
                    Text(digest.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.ink)
                        .lineLimit(1)
                }
                .accessibilityHidden(true)

                Spacer(minLength: 6)

                if siblingItems.count > 1, let onSelectSibling {
                    MemoryPageStepper(
                        items: siblingItems,
                        selectedID: memory.id,
                        onSelect: onSelectSibling
                    )
                }

                if onInstruct != nil {
                    Button {
                        showingInstructionBar.toggle()
                        instructionError = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11, weight: .medium))
                            Text("指令修改")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(showingInstructionBar ? colors.ink : colors.secondaryInk)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(
                            showingInstructionBar ? colors.surface : colors.surface.opacity(0.75),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("通过自然语言指令让 MoMo 修改这篇记忆或纠正说话人")
                    .accessibilityIdentifier("remote.memoryInstructToggle")
                }

                if let onOpenFullNotebook {
                    Button(action: onOpenFullNotebook) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(colors.secondaryInk)
                            .frame(width: 26, height: 26)
                            .background(colors.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("在记忆库中打开")
                    .accessibilityLabel("在记忆库中打开")
                }

                Menu {
                    Button {
                        MemoryCardDigest.copyToPasteboard(memory.text)
                        copied = true
                    } label: {
                        Label(copied ? "已复制 Markdown" : "复制 Markdown", systemImage: "doc.on.doc")
                    }
                    #if os(macOS)
                    Button {
                        MemoryCardDigest.shareText(memory.text)
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    #else
                    ShareLink(item: memory.text) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    #endif
                    if let onDelete {
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label(memory.kind == "person" ? "删除该人物" : "忘记这条记忆", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.secondaryInk)
                        .frame(width: 26, height: 26)
                        .background(colors.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
                .accessibilityIdentifier("remote.inlineMemoryMore")

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(colors.secondaryInk)
                            .frame(width: 26, height: 26)
                            .background(colors.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                    .accessibilityLabel("关闭")
                }
            }

            // Document Title + Obsidian Properties Strip
            VStack(alignment: .leading, spacing: 10) {
                Text(digest.title)
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                // Subtle Obsidian-style inline Properties metadata bar (wraps cleanly instead of clipping)
                ObsidianTagFlowLayout(horizontalSpacing: 7, verticalSpacing: 6) {
                    obsidianPropertyTag(icon: digest.badge.symbol, label: digest.badge.title, accent: colors.tabAccent(memory.kind), colors: colors)

                    if let date = digest.dateBadge {
                        obsidianPropertyTag(icon: "calendar", label: date, accent: nil, colors: colors, monospaced: true)
                    }

                    if let rawPath = memory.path, !rawPath.isEmpty {
                        obsidianPropertyTag(icon: "link", label: rawPath, accent: nil, colors: colors, monospaced: true)
                    }

                    if !outgoingMemories.isEmpty || !digest.linkedPaths.isEmpty {
                        let count = max(outgoingMemories.count, digest.linkedPaths.count)
                        obsidianPropertyTag(icon: "arrow.up.right.square", label: "\(count) 个链接", accent: nil, colors: colors)
                    }

                    if !incomingMemories.isEmpty {
                        obsidianPropertyTag(icon: "arrow.turn.down.left", label: "\(incomingMemories.count) 处反向提及", accent: nil, colors: colors)
                    }

                    if !memory.evidence.isEmpty {
                        obsidianPropertyTag(icon: "waveform", label: "\(memory.evidence.count) 段原音", accent: nil, colors: colors)
                    }
                }

                if showingInstructionBar, let onInstruct {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(colors.tabAccent(memory.kind))
                            TextField("告诉 MoMo 怎么改（如：这个 OKR 是 shengli 说的，帮我纠正说话人和相关记忆）…", text: $instructionDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .disabled(submittingInstruction)
                                .onSubmit {
                                    submitMemoryInstruction(using: onInstruct)
                                }
                                .accessibilityIdentifier("remote.memoryInstructInput")

                            if submittingInstruction {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    submitMemoryInstruction(using: onInstruct)
                                } label: {
                                    Text("发送")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? colors.secondaryInk : MoMoPalette.canvas)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4.5)
                                        .background(
                                            instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                ? colors.surface
                                                : colors.ink,
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("remote.memoryInstructSend")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(colors.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(colors.line, lineWidth: 0.7)
                        }

                        if let instructionError {
                            Text(instructionError)
                                .font(.system(size: 11.5))
                                .foregroundStyle(MoMoPalette.failure)
                        }
                    }
                } else if let receipt = instructionReceipt {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MoMoPalette.success)
                        Text(receipt)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.secondaryInk)
                        Spacer()
                        Button {
                            instructionReceipt = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(colors.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(colors.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }

            Rectangle()
                .fill(colors.line.opacity(0.8))
                .frame(height: 0.6)
                .accessibilityHidden(true)

            // Main Markdown / Note Body
            if digest.isNotebookMarkdown {
                MarkdownReadingView(
                    markdown: digest.cleanedNotebookMarkdown,
                    accessibilityID: "remote.memoryText",
                    handwriting: true
                )
                .equatable()
            } else {
                if !digest.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(digest.highlights.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•")
                                    .foregroundStyle(colors.secondaryInk)
                                    .accessibilityHidden(true)
                                Text(point)
                                    .font(.system(size: plainBodySize))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .lineSpacing(4)
                }
                #if os(macOS)
                MarkdownReadingView(
                    markdown: memory.text,
                    accessibilityID: "remote.memoryText",
                    handwriting: true,
                    plainTextOnly: true
                )
                .equatable()
                #else
                Text(memory.text)
                    .font(.system(size: plainBodySize))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("remote.memoryText")
                #endif
            }

            // Obsidian Bidirectional Links Section: Outgoing Links + Backlinks (Linked Mentions)
            if !outgoingMemories.isEmpty || !digest.linkedPaths.isEmpty || !incomingMemories.isEmpty || !memory.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Rectangle()
                        .fill(colors.line.opacity(0.75))
                        .frame(height: 0.6)
                        .padding(.top, 6)
                        .accessibilityHidden(true)

                    // 1. Outgoing Links (出链 · 关联笔记)
                    if !outgoingMemories.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("关联笔记")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("\(outgoingMemories.count)")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(colors.secondaryInk)

                            FlowingWikiLinkRow(
                                memories: outgoingMemories,
                                colors: colors,
                                onSelect: { target in
                                    navigate(to: target)
                                }
                            )
                        }
                    } else if !digest.linkedPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("关联笔记")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(colors.secondaryInk)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(digest.linkedPaths, id: \.self) { relPath in
                                        let label = MemoryCardDigest.humanizeNotebookPath(relPath)
                                        let encoded = relPath
                                            .split(separator: "/")
                                            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                                            .joined(separator: "/")
                                        Button {
                                            if let url = URL(string: "momoagent://memory/\(encoded)") {
                                                openURL(url)
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "doc.text")
                                                    .font(.system(size: 10.5))
                                                    .foregroundStyle(colors.secondaryInk)
                                                Text("[[\(label)]]")
                                                    .font(.system(size: 12, weight: .medium))
                                            }
                                            .foregroundStyle(colors.ink)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(colors.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    // 2. Backlinks / Linked Mentions (反向链接 · 被提及)
                    if !incomingMemories.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    showBacklinks.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: showBacklinks ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .frame(width: 11)
                                    Text("反向链接 · 被以下笔记提及")
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Text("\(incomingMemories.count)")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                    Spacer()
                                }
                                .foregroundStyle(colors.secondaryInk)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showBacklinks {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(incomingMemories) { sourceNote in
                                        let srcDigest = MemoryCardDigest.cached(for: sourceNote)
                                        Button {
                                            navigate(to: sourceNote)
                                        } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: srcDigest.badge.symbol)
                                                    .font(.system(size: 11.5, weight: .medium))
                                                    .foregroundStyle(colors.tabAccent(sourceNote.kind))
                                                    .frame(width: 16)
                                                    .padding(.top, 2)

                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack(spacing: 6) {
                                                        Text(srcDigest.title)
                                                            .font(.system(size: 13, weight: .medium))
                                                            .foregroundStyle(colors.ink)
                                                            .lineLimit(1)
                                                        Text(srcDigest.badge.title)
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(colors.secondaryInk)
                                                        if let d = srcDigest.dateBadge {
                                                            Text(d)
                                                                .font(.system(size: 10.5))
                                                                .monospacedDigit()
                                                                .foregroundStyle(colors.secondaryInk)
                                                        }
                                                    }
                                                    if let snippet = srcDigest.highlights.first {
                                                        Text(snippet)
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(colors.secondaryInk)
                                                            .lineLimit(1)
                                                    }
                                                }
                                                Spacer(minLength: 4)
                                                Image(systemName: "arrow.up.right")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(colors.secondaryInk.opacity(0.6))
                                                    .padding(.top, 3)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(colors.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    // 3. Collapsible Source Evidence (原音引证)
                    if !memory.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    showEvidence.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: showEvidence ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .frame(width: 11)
                                    Text("原音引证")
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Text("\(memory.evidence.count)")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                    Spacer()
                                }
                                .foregroundStyle(colors.secondaryInk)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showEvidence {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                                        VStack(alignment: .leading, spacing: 4) {
                                            #if os(macOS)
                                            MarkdownReadingView(
                                                markdown: evidence.quote,
                                                accessibilityID: "remote.memoryEvidence.\(evidence.sourceId)",
                                                handwriting: true,
                                                plainTextOnly: true
                                            )
                                            .equatable()
                                            #else
                                            Text(evidence.quote)
                                                .font(.system(size: 12.5))
                                                .lineSpacing(3)
                                                .textSelection(.enabled)
                                            #endif
                                            HStack(spacing: 8) {
                                                if let time = evidence.recordedAt {
                                                    Text(Date(timeIntervalSince1970: time), format: .dateTime.month().day().hour().minute())
                                                        .font(.caption2)
                                                        .monospacedDigit()
                                                }
                                                if let sourceLookup, let onOpenSource, let matchedSource = sourceLookup(evidence) {
                                                    Button {
                                                        onOpenSource(matchedSource)
                                                    } label: {
                                                        HStack(spacing: 3) {
                                                            Image(systemName: "waveform")
                                                                .font(.system(size: 10))
                                                            Text("打开转录原文")
                                                                .font(.system(size: 11, weight: .medium))
                                                        }
                                                        .foregroundStyle(colors.ink)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                        .padding(.leading, 10)
                                        .overlay(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 1)
                                                .fill(colors.line)
                                                .frame(width: 2)
                                                .accessibilityHidden(true)
                                        }
                                        .foregroundStyle(colors.secondaryInk)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(colors.ink)
        .memoryNotebookPage(borderless: borderless)
        .onChange(of: memory.id) {
            copied = false
            showingInstructionBar = false
            instructionDraft = ""
            instructionError = nil
            instructionReceipt = nil
        }
    }

    private func submitMemoryInstruction(using handler: @escaping (String) async throws -> Void) {
        let trimmed = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !submittingInstruction else { return }
        let fullPrompt = MemoryCardDigest.buildInstructionPrompt(for: memory, instruction: trimmed)
        submittingInstruction = true
        instructionError = nil
        Task {
            defer { submittingInstruction = false }
            do {
                try await handler(fullPrompt)
                instructionDraft = ""
                showingInstructionBar = false
                instructionReceipt = "已交给 MoMo 修正记忆与说话人（可在首页查看进度，完成后将自动同步）"
            } catch {
                instructionError = error.localizedDescription
            }
        }
    }

    private func navigate(to target: ContextMemory) {
        if let onSelectLinkedMemory {
            onSelectLinkedMemory(target)
        } else if let rawPath = target.path, !rawPath.isEmpty {
            let encoded = rawPath
                .split(separator: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            if let url = URL(string: "momoagent://memory/\(encoded)") {
                openURL(url)
            }
        }
    }

    private func obsidianPropertyTag(icon: String, label: String, accent: Color?, colors: MemoryNotebookPalette, monospaced: Bool = false) -> some View {
        HStack(spacing: 4.5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accent ?? colors.secondaryInk)
            Text(label)
                .font(.system(size: 11.5, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(colors.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(colors.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct FlowingWikiLinkRow: View {
    let memories: [ContextMemory]
    let colors: MemoryNotebookPalette
    let onSelect: (ContextMemory) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(memories) { item in
                    let digest = MemoryCardDigest.cached(for: item)
                    Button {
                        onSelect(item)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: digest.badge.symbol)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(colors.tabAccent(item.kind))
                            Text(digest.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(colors.ink)
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(colors.secondaryInk.opacity(0.7))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .background(colors.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct DreamMemorySection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let items: [ContextMemory]
}

enum DreamMemoryCategory: String, CaseIterable, Identifiable {
    case all
    case project
    case briefing
    case topic
    case person
    case journal
    case core

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "目录"
        case .project: return "在研项目"
        case .briefing: return "晨间简报"
        case .topic: return "主题"
        case .person: return "人物"
        case .journal: return "每日日志"
        case .core: return "核心记忆"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "list.bullet.indent"
        case .project: return "folder"
        case .briefing: return "sun.max"
        case .topic: return "doc.text"
        case .person: return "person.2"
        case .journal: return "calendar"
        case .core: return "brain"
        }
    }

    var isNotebookReaderCategory: Bool {
        switch self {
        case .project, .briefing, .topic, .person, .journal:
            return true
        case .core, .all:
            return false
        }
    }

    static func preferredInitialCategory(for memories: [ContextMemory]) -> DreamMemoryCategory {
        .all
    }

    private final class CachedFoldersBox: NSObject {
        let folders: [DreamMemorySection]
        init(_ folders: [DreamMemorySection]) { self.folders = folders }
    }

    private nonisolated(unsafe) static let directoryFoldersCache: NSCache<NSString, CachedFoldersBox> = {
        let cache = NSCache<NSString, CachedFoldersBox>()
        cache.countLimit = 8
        return cache
    }()

    static func directoryFolders(from memories: [ContextMemory]) -> [DreamMemorySection] {
        let active = memories.filter { $0.status != "forgotten" }
        guard !active.isEmpty else { return [] }
        let cacheKey = MemoryCardDigest.memoriesSignature(active) as NSString
        if let hit = directoryFoldersCache.object(forKey: cacheKey) {
            return hit.folders
        }
        let specs: [(id: String, title: String, subtitle: String?, filter: (ContextMemory) -> Bool)] = [
            ("project", "在研项目", "项目与关联专题、人物", { $0.kind == "project" }),
            ("briefing", "晨间简报", "今日焦点与未闭环事项", { $0.kind == "briefing" }),
            ("topic", "专题活页", "专项方法论与决策脉络", { $0.kind == "topic" }),
            ("person", "人物档案", "协作伙伴与说话人档案", { $0.kind == "person" }),
            ("journal", "每日日志", "按日归档的时空记录", { $0.kind == "journal" }),
            ("core", "核心记忆", "跨会话长期锚点与偏好", { $0.kind == "memory" || $0.kind == "user" }),
        ]
        var folders: [DreamMemorySection] = []
        for spec in specs {
            let matching = sortMemories(active.filter(spec.filter))
            if !matching.isEmpty {
                folders.append(DreamMemorySection(id: spec.id, title: spec.title, subtitle: spec.subtitle, items: matching))
            }
        }
        directoryFoldersCache.setObject(CachedFoldersBox(folders), forKey: cacheKey)
        return folders
    }

    static func defaultExpandedFolderIDs(for folders: [DreamMemorySection]) -> Set<String> {
        Set(folders.map(\.id))
    }

    static func category(for memory: ContextMemory) -> DreamMemoryCategory {
        switch memory.kind {
        case "project": return .project
        case "briefing": return .briefing
        case "topic": return .topic
        case "person": return .person
        case "journal": return .journal
        default: return .core
        }
    }

    func matches(_ memory: ContextMemory) -> Bool {
        switch self {
        case .all: return true
        case .briefing: return memory.kind == "briefing"
        case .project: return memory.kind == "project"
        case .journal: return memory.kind == "journal"
        case .person: return memory.kind == "person"
        case .topic: return memory.kind == "topic"
        case .core: return memory.kind == "memory" || memory.kind == "user"
        }
    }

    static func badge(for memory: ContextMemory) -> (title: String, symbol: String) {
        switch memory.kind {
        case "briefing": return ("晨间简报", "sun.max")
        case "project": return ("项目活页", "folder")
        case "journal": return ("每日日志", "calendar")
        case "person": return ("人物档案", "person")
        case "topic": return ("专题活页", "doc.text")
        case "user": return ("关于你", "person.crop.circle")
        default: return ("核心记忆", "brain")
        }
    }

    static func sortKey(for memory: ContextMemory) -> (Int, String) {
        let rank: Int
        switch memory.kind {
        case "briefing": rank = 0
        case "project": rank = 1
        case "journal": rank = 2
        case "topic": rank = 3
        case "person": rank = 4
        case "user": rank = 5
        default: rank = 6
        }
        let digest = MemoryCardDigest.cached(for: memory)
        let dateKey = Self.normalizedSortDate(digest.dateBadge)
        return (rank, dateKey)
    }

    private static func normalizedSortDate(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.count == 10 && raw.contains("-") { return raw }
        let parts = raw.split(separator: "/")
        if parts.count >= 2, let m = Int(parts[0]) {
            let dPart = parts[1].prefix(while: { $0.isNumber })
            if let d = Int(dPart) {
                return String(format: "2026-%02d-%02d", m, d)
            }
        }
        return raw
    }

    static func sections(from memories: [ContextMemory], category: DreamMemoryCategory) -> [DreamMemorySection] {
        let filtered = memories.filter { category.matches($0) }
        guard !filtered.isEmpty else { return [] }
        if category != .all {
            let ordered = sortMemories(filtered)
            return [DreamMemorySection(id: category.rawValue, title: category.title, subtitle: nil, items: ordered)]
        }
        let notebooks = sortMemories(filtered.filter { ["briefing", "project", "journal", "topic", "person"].contains($0.kind) })
        let coreItems = sortMemories(filtered.filter { !["briefing", "project", "journal", "topic", "person"].contains($0.kind) })
        if notebooks.isEmpty {
            return [DreamMemorySection(id: "core", title: "核心记忆", subtitle: nil, items: coreItems)]
        }
        var result: [DreamMemorySection] = [
            DreamMemorySection(
                id: "notebook",
                title: "手账活页",
                subtitle: nil,
                items: notebooks
            )
        ]
        if !coreItems.isEmpty {
            result.append(
                DreamMemorySection(
                    id: "core",
                    title: "核心记忆",
                    subtitle: nil,
                    items: coreItems
                )
            )
        }
        return result
    }

    static func sortMemories(_ items: [ContextMemory]) -> [ContextMemory] {
        // Keep stable relative order for items with identical kind and no date (e.g. UI layout fixtures)
        let indexed = Array(items.enumerated())
        return indexed.sorted { lhs, rhs in
            let lKey = sortKey(for: lhs.element)
            let rKey = sortKey(for: rhs.element)
            if lKey.0 != rKey.0 { return lKey.0 < rKey.0 }
            if !lKey.1.isEmpty && !rKey.1.isEmpty && lKey.1 != rKey.1 {
                return lKey.1 > rKey.1 // Newer dates first
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func folderSymbol(for id: String) -> String {
        switch id {
        case "project": return "folder"
        case "briefing": return "sun.max"
        case "topic": return "doc.text"
        case "person": return "person.2"
        case "journal": return "calendar"
        default: return "brain"
        }
    }
}

struct MemoryDirectoryFolderHeader: View {
    let section: DreamMemorySection
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(colors.secondaryInk)
                    .frame(width: 13)
                    .accessibilityHidden(true)

                Image(systemName: DreamMemoryCategory.folderSymbol(for: section.id))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.tabAccent(section.id))
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(section.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.ink)

                Spacer(minLength: 6)

                Text("\(section.items.count)")
                    .font(.system(size: 11.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(colors.secondaryInk)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remote.memoryFolder.\(section.id)")
    }
}

struct MemoryDirectoryChildRowLabel: View {
    let child: ContextMemory
    let isLast: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let digest = MemoryCardDigest.cached(for: child)
        let colors = MemoryNotebookPalette(scheme: scheme)
        HStack(spacing: 8) {
            Image(systemName: digest.badge.symbol)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(colors.tabAccent(child.kind))
                .frame(width: 14)
                .accessibilityHidden(true)

            Text(digest.title)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(colors.ink)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(digest.badge.title)
                .font(.system(size: 11))
                .foregroundStyle(colors.secondaryInk)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
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
            // Draw in one square coordinate space; the container only changes its uniform scale.
            let side = min(size.width, size.height)
            let w = 100.0
            let h = 100.0
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / w, y: side / h)
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
    var slotIndex: Int = 0

    private static let dateRegex = try? NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2})"#)

    static func dayToken(from headline: String) -> String {
        if let regex = dateRegex,
           let match = regex.firstMatch(in: headline, range: NSRange(headline.startIndex..., in: headline)),
           let r = Range(match.range(at: 1), in: headline) {
            return String(headline[r])
        }
        return headline
    }

    func persistenceKeys(headline: String) -> [String] {
        let day = Self.dayToken(from: headline)
        return [
            id,
            "\(headline)|\(id)",
            "\(headline)|\(title)",
            "\(headline)|slot-\(slotIndex)",
            "day|\(day)|slot-\(slotIndex)",
        ]
    }

    func isDismissed(in dismissedIDs: Set<String>, headline: String) -> Bool {
        persistenceKeys(headline: headline).contains(where: { dismissedIDs.contains($0) })
    }
}

enum DreamDismissedCardsStore {
    private static let key = "momo.dream.dismissedCardKeys.v1"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func markDismissed(_ card: DreamBriefingCard, headline: String, into binding: inout Set<String>) {
        let keys = card.persistenceKeys(headline: headline)
        for k in keys {
            binding.insert(k)
        }
        var stored = load()
        for k in keys {
            stored.insert(k)
        }
        UserDefaults.standard.set(Array(stored).sorted(), forKey: key)
    }
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
                        motif: motif,
                        slotIndex: idx
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
                } else if heading.contains("今日焦点") || heading.contains("今日脉络") || heading.contains("概览") {
                    mode = .overview
                } else if heading.contains("今日必办") || heading.contains("今日行动") || heading.contains("预热") || heading.contains("未闭环") || heading.contains("重点") {
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
                        motif: idx == 0 ? .memoryLoop : .voiceWave,
                        slotIndex: idx
                    )
                )
            }
        }

        let overview = MemoryCardDigest.cleanInlineNoise(
            overviewLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return DreamBriefingDocument(
            headline: MemoryCardDigest.cleanInlineNoise(headline),
            overview: overview.isEmpty ? "Dream 已在闲时为你整理好近期生活脉络与重点。" : overview,
            rawMarkdown: MemoryCardDigest.cleanNotebookMarkdownForDetail(markdown),
            cards: Array(cards.prefix(2))
        )
    }

    private final class CachedBriefingBox: NSObject {
        let text: String
        let document: DreamBriefingDocument
        init(text: String, document: DreamBriefingDocument) {
            self.text = text
            self.document = document
        }
    }

    private nonisolated(unsafe) static let briefingCache: NSCache<NSString, CachedBriefingBox> = {
        let cache = NSCache<NSString, CachedBriefingBox>()
        cache.countLimit = 8
        return cache
    }()

    static func resolve(from memories: [ContextMemory]) -> DreamBriefingDocument? {
        guard let briefing = memories.first(where: { $0.status != "forgotten" && $0.kind == "briefing" }) else {
            return nil
        }
        let cacheKey = "\(briefing.id)|\(briefing.revision)|\(briefing.text.utf8.count)" as NSString
        if let hit = briefingCache.object(forKey: cacheKey), hit.text == briefing.text {
            return hit.document
        }
        let parsed = parse(markdown: briefing.text)
        briefingCache.setObject(CachedBriefingBox(text: briefing.text, document: parsed), forKey: cacheKey)
        return parsed
    }
}

struct DreamHomeCardsSection: View {
    let document: DreamBriefingDocument
    @Binding var dismissedIDs: Set<String>
    var compact: Bool = false
    let onSelectCard: (DreamBriefingCard) -> Void
    let onOpenBriefing: () -> Void
    let onOpenNotebook: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var visibleCards: [DreamBriefingCard] {
        let allDismissed = dismissedIDs.union(DreamDismissedCardsStore.load())
        return document.cards.filter { !$0.isDismissed(in: allDismissed, headline: document.headline) }
    }

    var body: some View {
        if !visibleCards.isEmpty {
            LazyVGrid(columns: [GridItem(visibleCards.count == 1 ? .flexible() : .adaptive(minimum: 300), spacing: 10)], spacing: 8) {
                ForEach(visibleCards.prefix(2)) { card in
                    cardView(card)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func cardView(_ card: DreamBriefingCard) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Button {
                DreamDismissedCardsStore.markDismissed(card, headline: document.headline, into: &dismissedIDs)
                onSelectCard(card)
            } label: {
                HStack(spacing: 10) {
                    DreamDotMatrixArtwork(kind: card.motif, isDark: isDark)
                        .frame(width: compact ? 56 : 64, height: compact ? 56 : 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(card.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MoMoPalette.ink)
                            .lineLimit(2)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(card.subtitle)
                                .font(.system(size: 12))
                                .lineLimit(2)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .medium))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(MoMoPalette.muted)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.vertical, compact ? 8 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(DreamCardButtonStyle())
            .accessibilityIdentifier("assistant.suggestion.\(card.id)")
            .accessibilityLabel(card.title)
            .accessibilityHint(card.subtitle)
            .contextMenu {
                Button("查看晨间简报", systemImage: "doc.richtext", action: onOpenBriefing)
                Button("打开记忆笔记本", systemImage: "book.pages", action: onOpenNotebook)
                Button("暂时收起", systemImage: "eye.slash") {
                    DreamDismissedCardsStore.markDismissed(card, headline: document.headline, into: &dismissedIDs)
                }
            }

            Button {
                DreamDismissedCardsStore.markDismissed(card, headline: document.headline, into: &dismissedIDs)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted)
                    #if os(macOS)
                    .frame(width: 28, height: 28)
                    #else
                    .frame(width: 44, height: 44)
                    #endif
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起\(card.title)")
            .accessibilityIdentifier("assistant.dismissSuggestion.\(card.id)")
            .help("收起这张卡片")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MoMoPalette.line, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

private struct DreamCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(MoMoPalette.ink.opacity(configuration.isPressed ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

enum DreamMemoryLinkResolver {
    static func isMemoryURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "momoagent" && url.host?.lowercased() == "memory"
    }

    static func relativePath(from url: URL) -> String? {
        guard isMemoryURL(url) else { return nil }
        let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.isEmpty ? nil : decoded
    }

    static func resolve(url: URL, in memories: [ContextMemory]) -> ContextMemory? {
        guard let rel = relativePath(from: url) else { return nil }
        let active = memories.filter { $0.status != "forgotten" }
        let lowerRel = rel.lowercased()

        // 1. Exact path match
        if let exact = active.first(where: { $0.path?.lowercased() == lowerRel }) {
            return exact
        }
        if lowerRel == "briefing.md", let b = active.first(where: { $0.kind == "briefing" }) {
            return b
        }
        if lowerRel == "user.md", let u = active.first(where: { $0.kind == "user" }) {
            return u
        }
        if lowerRel == "memory.md", let m = active.first(where: { $0.kind == "memory" }) {
            return m
        }

        // 2. Match by category folder + stem or Chinese keywords
        let parts = rel.split(separator: "/")
        let folder = parts.count >= 2 ? String(parts[0]).lowercased() : ""
        let filename = String(parts.last ?? Substring(rel))
        let stem = filename.replacingOccurrences(of: #"\.md$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let targetKind: String? = switch folder {
        case "projects", "project": "project"
        case "topics", "topic": "topic"
        case "people", "person": "person"
        case "journal", "journals": "journal"
        default: nil
        }

        let candidates = targetKind != nil ? active.filter { $0.kind == targetKind } : active
        if let pathSuffixMatch = candidates.first(where: { ($0.path ?? "").lowercased().hasSuffix(filename.lowercased()) }) {
            return pathSuffixMatch
        }
        if let textMatch = candidates.first(where: { $0.text.localizedCaseInsensitiveContains(stem) }) {
            return textMatch
        }
        let stemTokens = stem.split(separator: "-").map(String.init).filter { $0.count >= 2 }
        let aliasMap: [String: [String]] = [
            "diary-study": ["日记法"],
            "ceo-communication": ["CEO", "沟通"],
            "industry-interviewer": ["行业主持人"],
            "overview": ["在研项目总览", "项目总览"],
            "ai-user-research": ["AI 访谈", "用研", "日记法"],
            "momo-agent": ["MoMo", "智能体"],
        ]
        if let aliases = aliasMap[stem.lowercased()] {
            if let aliasMatch = candidates.first(where: { item in aliases.contains(where: { item.text.localizedCaseInsensitiveContains($0) }) }) {
                return aliasMatch
            }
        }
        if !stemTokens.isEmpty,
           let tokenMatch = candidates.first(where: { item in stemTokens.contains(where: { item.text.localizedCaseInsensitiveContains($0) }) }) {
            return tokenMatch
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}

struct MemoryPageStepper: View {
    let items: [ContextMemory]
    let selectedID: String
    let onSelect: (ContextMemory) -> Void
    @Environment(\.colorScheme) private var scheme

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        if items.count > 1 {
            HStack(spacing: 1) {
                Button {
                    let prev = (currentIndex - 1 + items.count) % items.count
                    onSelect(items[prev])
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colors.ink)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("上一页")

                Menu {
                    ForEach(items) { item in
                        let digest = MemoryCardDigest.cached(for: item)
                        Button {
                            onSelect(item)
                        } label: {
                            if item.id == selectedID {
                                Label(digest.title, systemImage: "checkmark")
                            } else {
                                Text(digest.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2.5) {
                        Text("\(currentIndex + 1)/\(items.count)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .opacity(0.65)
                    }
                    .foregroundStyle(colors.secondaryInk)
                    .padding(.horizontal, 4)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换页面，当前第 \(currentIndex + 1) 页，共 \(items.count) 页")

                Button {
                    let next = (currentIndex + 1) % items.count
                    onSelect(items[next])
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colors.ink)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下一页")
            }
            .padding(.horizontal, 3)
            .background(colors.surface, in: Capsule())
        }
    }
}

struct MemoryNotePreviewSheet: View {
    @State var memory: ContextMemory
    let allMemories: [ContextMemory]
    var onOpenFullNotebook: (() -> Void)? = nil
    @State private var navigationStack: [ContextMemory] = []
    @State private var forwardStack: [ContextMemory] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var siblingMemories: [ContextMemory] {
        let active = allMemories.filter { $0.status != "forgotten" }
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

    private func pushMemory(_ next: ContextMemory) {
        guard next.id != memory.id else { return }
        navigationStack.append(memory)
        forwardStack.removeAll()
        memory = next
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let backAction: (() -> Void)? = navigationStack.last.map { prev in
            {
                _ = navigationStack.popLast()
                forwardStack.append(memory)
                memory = prev
            }
        }
        let forwardAction: (() -> Void)? = (!navigationStack.isEmpty || !forwardStack.isEmpty) ? {
            guard let next = forwardStack.popLast() else { return }
            navigationStack.append(memory)
            memory = next
        } : nil
        let openAllAction: (() -> Void)? = onOpenFullNotebook.map { action in
            {
                dismiss()
                action()
            }
        }

        Group {
            #if os(macOS)
            ScrollView {
                ClientMemoryContent(
                    memory: memory,
                    allMemories: allMemories,
                    siblingItems: siblingMemories,
                    onSelectSibling: {
                        navigationStack.removeAll()
                        forwardStack.removeAll()
                        memory = $0
                    },
                    onSelectLinkedMemory: { pushMemory($0) },
                    backLabel: "后退",
                    onBack: backAction,
                    canGoForward: !forwardStack.isEmpty,
                    onForward: forwardAction,
                    onOpenFullNotebook: openAllAction,
                    onClose: { dismiss() },
                    borderless: true
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .frame(width: 560, height: 480)
            .background(colors.paper)
            #else
            TabView(
                selection: Binding(
                    get: { memory.id },
                    set: { newID in
                        if let next = siblingMemories.first(where: { $0.id == newID }) {
                            navigationStack.removeAll()
                            forwardStack.removeAll()
                            memory = next
                        }
                    }
                )
            ) {
                ForEach(siblingMemories) { item in
                    ScrollView {
                        ClientMemoryContent(
                            memory: item,
                            allMemories: allMemories,
                            siblingItems: siblingMemories,
                            onSelectSibling: {
                                navigationStack.removeAll()
                                forwardStack.removeAll()
                                memory = $0
                            },
                            onSelectLinkedMemory: { pushMemory($0) },
                            backLabel: "后退",
                            onBack: backAction,
                            canGoForward: !forwardStack.isEmpty,
                            onForward: forwardAction,
                            onOpenFullNotebook: openAllAction,
                            onClose: { dismiss() },
                            borderless: true
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                    }
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(colors.paper.ignoresSafeArea())
            .presentationDragIndicator(.visible)
            #endif
        }
        .environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: allMemories), next.id != memory.id {
                pushMemory(next)
                return .handled
            }
            return .systemAction
        })
    }
}
