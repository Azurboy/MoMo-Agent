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

    func memoryNotebookPage() -> some View {
        self.padding(.leading, 32).padding(.trailing, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MemoryNotebookPaper())
    }
}

struct MemoryNotebookPalette {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }
    var paper: Color { dark ? Self.rgb(0x1E1C19) : Self.rgb(0xFBF7EE) }
    var desk: Color { dark ? Self.rgb(0x141310) : Self.rgb(0xEEE8DD) }
    var ink: Color { dark ? Self.rgb(0xF3EBDD) : Self.rgb(0x302B25) }
    var secondaryInk: Color { dark ? Self.rgb(0xC9BDAA) : Self.rgb(0x695C4B) }
    var margin: Color { dark ? Self.rgb(0xD29C85) : Self.rgb(0x9E5040) }

    func tab(_ kind: String) -> Color {
        switch kind {
        case "briefing": dark ? Self.rgb(0x665333) : Self.rgb(0xEBD9AF)
        case "project": dark ? Self.rgb(0x5E4934) : Self.rgb(0xEED6B8)
        case "journal": dark ? Self.rgb(0x405446) : Self.rgb(0xD6E0CA)
        case "person": dark ? Self.rgb(0x674941) : Self.rgb(0xEACDC0)
        case "topic": dark ? Self.rgb(0x42545F) : Self.rgb(0xCFDEE4)
        default: dark ? Self.rgb(0x554A60) : Self.rgb(0xDFD5E5)
        }
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private struct MemoryNotebookPaper: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colors.paper)
            .overlay {
                Canvas { context, size in
                    var rules = Path()
                    for y in stride(from: 32.0, through: size.height - 8, by: 24.0) {
                        rules.move(to: CGPoint(x: 16, y: y))
                        rules.addLine(to: CGPoint(x: size.width - 14, y: y))
                    }
                    context.stroke(rules, with: .color(colors.secondaryInk.opacity(contrast == .increased ? 0.14 : 0.08)), lineWidth: 0.5)
                    var margin = Path()
                    margin.move(to: CGPoint(x: 20, y: 0))
                    margin.addLine(to: CGPoint(x: 20, y: size.height))
                    context.stroke(margin, with: .color(colors.margin.opacity(0.28)), lineWidth: 0.7)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(colors.secondaryInk.opacity(contrast == .increased ? 0.45 : 0.14), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct MemoryBinderTab: View {
    let category: DreamMemoryCategory
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        Text(category.title)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? colors.ink : colors.secondaryInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                isSelected ? colors.paper : colors.paper.opacity(0.45),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? colors.margin.opacity(0.55) : colors.secondaryInk.opacity(0.14),
                    lineWidth: isSelected ? 1 : 0.5
                )
            }
            .contentShape(Capsule())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let cleanedNotebookMarkdown: String
    let isNotebookMarkdown: Bool

    private nonisolated(unsafe) static let cache: NSCache<NSString, CachedMemoryCardDigestBox> = {
        let c = NSCache<NSString, CachedMemoryCardDigestBox>()
        c.countLimit = 256
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
        let key = "\(memory.id)|\(memory.revision)|\(memory.status)|\(memory.text.count)" as NSString
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

            var resolvedHeading = rawHeading ?? Self.badgeTitleFallback(for: memory.kind)
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
            self.cleanedNotebookMarkdown = bodyText
        }

        self.dateBadge = extractedDate
        self.sourceNote = extractedNote
    }

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

    static func cleanNotebookMarkdownForDetail(_ markdown: String) -> String {
        var s = markdown
        if s.contains("momoagent://source/") {
            s = replace(sourceLinkRegex, in: s, with: "`⏱ $1`")
        }
        if s.contains("`"), let regex = notebookRefRegex {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
            for match in matches {
                guard let fullRange = Range(match.range, in: s),
                      let pathRange = Range(match.range(at: 1), in: s) else { continue }
                let relPath = String(s[pathRange])
                let encoded = relPath
                    .split(separator: "/")
                    .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                    .joined(separator: "/")
                s.replaceSubrange(fullRange, with: "[📔 \(relPath)](momoagent://memory/\(encoded))")
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let digest = MemoryCardDigest.cached(for: memory)
        let colors = MemoryNotebookPalette(scheme: scheme)
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(colors.tab(memory.kind))
                .frame(width: 4)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(digest.title)
                        .momoHandwriting(size: 16, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(colors.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = digest.dateBadge {
                        Text(date)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(colors.secondaryInk)
                    }
                }
                if let firstHighlight = digest.highlights.first {
                    Text(firstHighlight)
                        .font(.subheadline)
                        .foregroundStyle(colors.secondaryInk)
                        .lineLimit(1)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(colors.secondaryInk.opacity(0.6))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(colors.secondaryInk.opacity(0.12), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([digest.badge.title, digest.dateBadge, digest.statusBadge, digest.title]
            .compactMap { $0 } + digest.highlights + ["查看全文"]).joined(separator: "，"))
    }
}

struct ClientMemoryContent: View {
    let memory: ContextMemory
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let digest = MemoryCardDigest.cached(for: memory)
        let colors = MemoryNotebookPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 14) {
            if let date = digest.dateBadge {
                HStack {
                    Spacer()
                    Text(date)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(colors.secondaryInk)
                }
            }

            if digest.isNotebookMarkdown {
                MarkdownReadingView(markdown: digest.cleanedNotebookMarkdown,
                                    accessibilityID: "remote.memoryText", handwriting: true)
            } else {
                if !digest.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(digest.title)
                            .momoHandwriting(size: 18, weight: .semibold, relativeTo: .headline)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(digest.highlights.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("·").accessibilityHidden(true)
                                Text(point).fixedSize(horizontal: false, vertical: true)
                            }.momoHandwriting(size: 15)
                        }
                    }.lineSpacing(4)
                }
                Text(memory.text)
                    .momoHandwriting(size: 15)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("remote.memoryText")
            }

            ForEach(Array(memory.evidence.enumerated()), id: \.offset) { _, evidence in
                VStack(alignment: .leading, spacing: 4) {
                    Text(evidence.quote).momoHandwriting(size: 14).lineSpacing(4).textSelection(.enabled)
                    if let time = evidence.recordedAt {
                        Text(Date(timeIntervalSince1970: time), format: .dateTime.month().day().hour().minute())
                            .font(.caption2)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(colors.margin.opacity(0.45)).frame(width: 2).accessibilityHidden(true) }
                .foregroundStyle(colors.secondaryInk)
            }
        }
        .foregroundStyle(colors.ink)
        .memoryNotebookPage()
    }
}

struct DreamMemorySection: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let items: [ContextMemory]
}

enum DreamMemoryCategory: String, CaseIterable, Identifiable {
    case project
    case briefing
    case topic
    case person
    case journal
    case core
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: return "在研项目"
        case .briefing: return "晨间简报"
        case .topic: return "主题"
        case .person: return "人物"
        case .journal: return "每日日志"
        case .core: return "核心记忆"
        case .all: return "目录"
        }
    }

    var symbol: String {
        switch self {
        case .project: return "folder.badge.gearshape"
        case .briefing: return "sun.max"
        case .topic: return "folder"
        case .person: return "person.2"
        case .journal: return "calendar"
        case .core: return "sparkles"
        case .all: return "list.bullet"
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
        for candidate: DreamMemoryCategory in [.project, .briefing, .topic, .person, .journal] {
            if memories.contains(where: { candidate.matches($0) }) {
                return candidate
            }
        }
        return .all
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
        case "briefing": return ("晨间简报", "sun.max.fill")
        case "project": return ("项目活页", "folder.fill.badge.gearshape")
        case "journal": return ("生活日志", "calendar")
        case "person": return ("人物活页", "person.fill")
        case "topic": return ("主题活页", "doc.text.fill")
        case "user": return ("关于你", "person.crop.circle")
        default: return ("核心记忆", "sparkles")
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

    static func resolve(from memories: [ContextMemory]) -> DreamBriefingDocument? {
        let active = memories.filter { $0.status != "forgotten" }
        guard let briefing = active.first(where: { $0.kind == "briefing" }) else {
            return nil
        }
        return parse(markdown: briefing.text)
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

struct MemoryBinderPageSwitcher: View {
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    let isSelected = item.id == selectedID
                                    let digest = MemoryCardDigest.cached(for: item)
                                    let pillLabel = (item.kind == "journal" ? (digest.dateBadge ?? digest.title) : digest.title)
                                    Button {
                                        onSelect(item)
                                    } label: {
                                        Text(pillLabel)
                                            .momoHandwriting(size: 13.5, weight: isSelected ? .semibold : .regular)
                                            .lineLimit(1)
                                            .foregroundStyle(isSelected ? colors.paper : colors.ink)
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 6)
                                            .frame(minHeight: 34)
                                            .background(
                                                isSelected ? colors.ink : colors.paper,
                                                in: Capsule()
                                            )
                                            .overlay {
                                                Capsule()
                                                    .strokeBorder(colors.secondaryInk.opacity(isSelected ? 0 : 0.18), lineWidth: 0.5)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                    .accessibilityIdentifier("remote.memoryPagePill.\(index)")
                                }
                            }
                        }
                        .onChange(of: selectedID) { _, newID in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Button {
                            let prev = (currentIndex - 1 + items.count) % items.count
                            onSelect(items[prev])
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(colors.ink)
                                .frame(width: 32, height: 32)
                                .background(colors.paper, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("上一页")

                        Text("\(currentIndex + 1)/\(items.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(colors.secondaryInk)
                            .frame(minWidth: 28)

                        Button {
                            let next = (currentIndex + 1) % items.count
                            onSelect(items[next])
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(colors.ink)
                                .frame(width: 32, height: 32)
                                .background(colors.paper, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("下一页")
                    }
                }
            }
        }
    }
}

struct MemoryNotePreviewSheet: View {
    @State var memory: ContextMemory
    let allMemories: [ContextMemory]
    var onOpenFullNotebook: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var siblingMemories: [ContextMemory] {
        let active = allMemories.filter { $0.status != "forgotten" && $0.kind == memory.kind }
        return DreamMemoryCategory.sortMemories(active)
    }

    var body: some View {
        let colors = MemoryNotebookPalette(scheme: scheme)
        let digest = MemoryCardDigest.cached(for: memory)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MemoryBinderPageSwitcher(
                        items: siblingMemories,
                        selectedID: memory.id,
                        onSelect: { memory = $0 }
                    )
                    ClientMemoryContent(memory: memory)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .background(colors.desk)
            .navigationTitle(digest.title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let onOpenFullNotebook {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            dismiss()
                            onOpenFullNotebook()
                        } label: {
                            Label("全部手账", systemImage: "book.pages")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let next = DreamMemoryLinkResolver.resolve(url: url, in: allMemories) {
                memory = next
                return .handled
            }
            return .systemAction
        })
        #if os(macOS)
        .frame(width: 540, height: 480)
        #endif
    }
}
