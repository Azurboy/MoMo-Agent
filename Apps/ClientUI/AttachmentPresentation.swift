import Foundation
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import MoMoAgentClient
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension AgentAttachment {
    var displayFormat: String {
        if kind == .image { return String(localized: "照片") }
        if isHTMLDocument { return "HTML" }
        if isMarkdownDocument { return "MD" }
        let suffix = (name as NSString).pathExtension.uppercased()
        return suffix.isEmpty ? String(localized: "文本") : String(suffix.prefix(8))
    }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
    var supportsRichDocumentPreview: Bool { text != nil && (isHTMLDocument || isMarkdownDocument) }

    var safeExportFilename: String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        if isHTMLDocument { return "deliverable.html" }
        if isMarkdownDocument { return "deliverable.md" }
        return kind == .image ? "image.jpg" : "attachment.txt"
    }

    func writeTemporaryExportFile() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-attachment-preview-\(id.uuidString.lowercased())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(safeExportFilename, isDirectory: false)
            if let data {
                try data.write(to: fileURL, options: .atomic)
                return fileURL
            }
            if let text {
                try Data(text.utf8).write(to: fileURL, options: .atomic)
                return fileURL
            }
            if let preview {
                try preview.write(to: fileURL, options: .atomic)
                return fileURL
            }
            return nil
        } catch {
            return nil
        }
    }
}

enum ClientAttachmentImportError: LocalizedError {
    case tooLarge, imageTooLarge, unreadable, unsupported, noText, tooMuchText
    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "这个文件超过 20 MB，请选择较小的文件。")
        case .imageTooLarge: String(localized: "照片压缩后仍然过大，请裁剪后再添加。")
        case .unreadable: String(localized: "无法读取这个文件，请重新选择。")
        case .unsupported: String(localized: "目前支持照片、PDF、HTML、Markdown 和文本文件，请选择这些格式。")
        case .noText: String(localized: "这个 PDF 没有可提取的文字。请将需要阅读的页面作为照片添加。")
        case .tooMuchText: String(localized: "文件文字过多，请拆分后再添加。")
        }
    }
}

enum ClientAttachmentImporter {
    static let allowedTypes: [UTType] = {
        var types: [UTType] = [.image, .pdf, .html, .plainText, .json, .sourceCode, .commaSeparatedText]
        if let markdown = UTType(filenameExtension: "md"), !types.contains(markdown) {
            types.append(markdown)
        }
        return types
    }()

    nonisolated static func file(_ url: URL) throws -> AgentAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0 else { throw ClientAttachmentImportError.unreadable }
        guard size <= 20 * 1_048_576 else { throw ClientAttachmentImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 20 * 1_048_576 else { throw ClientAttachmentImportError.tooLarge }
        let ext = url.pathExtension.lowercased()
        let type = properties.contentType ?? UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return try image(data, name: url.lastPathComponent) }
        let text: String
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(data: data), !document.isLocked else { throw ClientAttachmentImportError.unreadable }
            guard document.pageCount <= 200 else { throw ClientAttachmentImportError.tooMuchText }
            var pages: [String] = [], count = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let page = document.page(at: index)?.string ?? ""
                count += page.utf8.count
                guard count <= 256_000 else { throw ClientAttachmentImportError.tooMuchText }
                pages.append(page)
            }
            text = pages.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientAttachmentImportError.noText }
        } else {
            let isKnownTextExt = ["md", "markdown", "html", "htm", "txt", "csv", "json"].contains(ext)
            let isSupportedType = type?.conforms(to: .text) == true || type?.conforms(to: .json) == true || type?.conforms(to: .html) == true || isKnownTextExt
            guard isSupportedType,
                  let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else { throw ClientAttachmentImportError.unsupported }
            text = decoded
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientAttachmentImportError.unreadable }
        guard text.utf8.count <= 256_000 else { throw ClientAttachmentImportError.tooMuchText }
        let mediaType: String
        if ext == "html" || ext == "htm" || type?.conforms(to: .html) == true {
            mediaType = "text/html"
        } else if ext == "md" || ext == "markdown" {
            mediaType = "text/markdown"
        } else {
            mediaType = type?.preferredMIMEType ?? "text/plain"
        }
        return AgentAttachment(name: url.lastPathComponent, kind: .document, mediaType: mediaType, byteCount: data.count, text: text)
    }

    nonisolated static func image(_ data: Data, name: String = String(localized: "照片.jpg")) throws -> AgentAttachment {
        guard data.count <= 20 * 1_048_576 else { throw ClientAttachmentImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ClientAttachmentImportError.unreadable }
        let encoded = try jpeg(source, maximumPixels: 1_536, quality: 0.72)
        return try attachment(encoded, previewSource: source, name: name)
    }

    nonisolated private static func attachment(_ encoded: Data, previewSource: CGImageSource, name: String) throws -> AgentAttachment {
        guard encoded.count <= 1_048_576 else { throw ClientAttachmentImportError.imageTooLarge }
        return AgentAttachment(name: name, kind: .image, mediaType: "image/jpeg", byteCount: encoded.count,
            data: encoded, preview: try jpeg(previewSource, maximumPixels: 160, quality: 0.6))
    }

    nonisolated private static func jpeg(_ source: CGImageSource, maximumPixels: Int, quality: Double) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ClientAttachmentImportError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ClientAttachmentImportError.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ClientAttachmentImportError.unreadable }
        return output as Data
    }
}

struct ClientAttachmentStrip: View {
    let attachments: [AgentAttachment]
    let remove: (UUID) -> Void
    var preview: (AgentAttachment) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(attachments) { item in
                    ZStack(alignment: .topTrailing) {
                        Button { preview(item) } label: {
                            Group {
                                if let bytes = item.preview ?? item.data, let image = platformImage(from: bytes) {
                                    image.resizable().scaledToFit()
                                        .frame(width: 96, height: 96).accessibilityHidden(true)
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).font(.system(size: 12)).lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(item.displaySize).font(.system(size: 11)).foregroundStyle(MoMoPalette.muted)
                                        Spacer(minLength: 0)
                                        Text(item.displayFormat).font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(MoMoPalette.muted).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(MoMoPalette.canvas, in: RoundedRectangle(cornerRadius: 5))
                                    }.padding(10).frame(width: 96, height: 96)
                                }
                            }
                            .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MoMoPalette.muted.opacity(0.2), lineWidth: 0.5) }
                        }
                        .buttonStyle(.plain).accessibilityLabel("预览\(item.name)")
                        Button { remove(item.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .background(MoMoPalette.canvas, in: Circle())
                                .overlay { Circle().strokeBorder(MoMoPalette.muted.opacity(0.25), lineWidth: 0.5) }
                                .frame(width: 36, height: 36).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).offset(x: 14, y: -14)
                        .accessibilityLabel("移除\(item.name)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("assistant.attachment.\(item.id)")
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }.scrollIndicators(.hidden).frame(height: 116)
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }
}

struct ClientAttachmentPreview: View {
    private enum DocumentDisplayMode: String, CaseIterable, Identifiable {
        case preview
        case source
        var id: String { rawValue }
    }

    let attachment: AgentAttachment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var displayMode: DocumentDisplayMode = .preview
    @State private var exportURL: URL?

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(attachment.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(attachment.displaySize)
                    .font(.caption)
                    .foregroundStyle(MoMoPalette.muted)
                Spacer(minLength: 8)
                if attachment.supportsRichDocumentPreview {
                    Picker("显示方式", selection: $displayMode) {
                        Text("预览").tag(DocumentDisplayMode.preview)
                        Text("源码").tag(DocumentDisplayMode.source)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 132)
                    .accessibilityIdentifier("attachmentPreview.modePicker")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("attachmentPreview.share")
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content
                .frame(
                    minWidth: attachment.supportsRichDocumentPreview ? 760 : 520,
                    idealWidth: attachment.supportsRichDocumentPreview ? 860 : 600,
                    minHeight: attachment.supportsRichDocumentPreview ? 560 : 400,
                    idealHeight: attachment.supportsRichDocumentPreview ? 680 : 460
                )
        }
        .background(MoMoPalette.canvas)
        .onAppear { ensureExportFile() }
        .onDisappear { cleanupExportFile() }
        #else
        NavigationStack {
            VStack(spacing: 0) {
                if attachment.supportsRichDocumentPreview {
                    HStack(spacing: 12) {
                        Picker("显示方式", selection: $displayMode) {
                            Text("预览").tag(DocumentDisplayMode.preview)
                            Text("源码").tag(DocumentDisplayMode.source)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("attachmentPreview.modePicker")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    Divider().overlay(MoMoPalette.line)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(MoMoPalette.canvas)
            .phoneSoftTopEdge()
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let exportURL {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: exportURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享或导出文件")
                        .accessibilityIdentifier("attachmentPreview.share")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { ensureExportFile() }
        .onDisappear { cleanupExportFile() }
        #endif
    }

    private func ensureExportFile() {
        if exportURL == nil {
            exportURL = attachment.writeTemporaryExportFile()
        }
    }

    private func cleanupExportFile() {
        guard let exportURL else { return }
        let directory = exportURL.deletingLastPathComponent()
        self.exportURL = nil
        try? FileManager.default.removeItem(at: directory)
    }

    @ViewBuilder private var content: some View {
        if let data = attachment.data ?? attachment.preview, let image = platformImage(from: data) {
            GeometryReader { geometry in
                image.resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else if let text = attachment.text {
            if attachment.supportsRichDocumentPreview && displayMode == .preview {
                if attachment.isHTMLDocument {
                    SandboxedDocumentWebView(
                        mode: .html(SandboxedDocumentWebView.normalizedHTML(text)),
                        dark: colorScheme == .dark,
                        openExternalURL: { openURL($0) }
                    )
                    .accessibilityIdentifier("attachmentPreview.htmlWebView")
                } else if Bundle.main.url(forResource: "markdown-document", withExtension: "html", subdirectory: "Web") != nil {
                    SandboxedDocumentWebView(
                        mode: .markdown(text),
                        dark: colorScheme == .dark,
                        openExternalURL: { openURL($0) }
                    )
                    .accessibilityIdentifier("attachmentPreview.markdownWebView")
                } else {
                    sourceTextScrollView(text, monospaced: false)
                }
            } else {
                sourceTextScrollView(text, monospaced: attachment.supportsRichDocumentPreview)
            }
        } else {
            VStack(spacing: 8) {
                Text(attachment.name).phoneText(.heading)
                Text(attachment.displaySize).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceTextScrollView(_ text: String, monospaced: Bool) -> some View {
        ScrollView {
            Group {
                if monospaced {
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                } else {
                    Text(text).phoneText(.body)
                }
            }
            .foregroundStyle(MoMoPalette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("attachmentPreview.sourceText")
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }
}

#if os(macOS)
private typealias SandboxedWebRepresentable = NSViewRepresentable
#else
private typealias SandboxedWebRepresentable = UIViewRepresentable
#endif

struct SandboxedDocumentWebView: SandboxedWebRepresentable {
    enum Mode: Equatable {
        case html(String)
        case markdown(String)
    }

    let mode: Mode
    let dark: Bool
    var openExternalURL: (URL) -> Void = { _ in }

    static func normalizedHTML(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let hasViewport = lower.contains("name=\"viewport\"") || lower.contains("name='viewport'") || lower.contains("name=viewport")
        if hasViewport { return raw }
        let injectedMeta = "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        if let headRange = raw.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var copy = raw
            copy.insert(contentsOf: injectedMeta, at: headRange.upperBound)
            return copy
        }
        if lower.contains("<html"),
           let htmlRange = raw.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var copy = raw
            copy.insert(contentsOf: "<head>\(injectedMeta)</head>", at: htmlRange.upperBound)
            return copy
        }
        return """
        <!doctype html>
        <html>
        <head>\(injectedMeta)</head>
        <body>
        \(raw)
        </body>
        </html>
        """
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, dark: dark, openExternalURL: openExternalURL)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { updateWebView(webView, context: context) }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView, coordinator: coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { updateWebView(webView, context: context) }
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView, coordinator: coordinator) }
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if case .markdown = mode {
            configuration.userContentController.add(context.coordinator, name: "doc")
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        configureAppearance(web)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        context.coordinator.loadInitialContent()
        return web
    }

    private func updateWebView(_ web: WKWebView, context: Context) {
        configureAppearance(web)
        context.coordinator.openExternalURL = openExternalURL
        context.coordinator.update(mode: mode, dark: dark)
    }

    private func configureAppearance(_ web: WKWebView) {
        #if os(iOS)
        web.overrideUserInterfaceStyle = dark ? .dark : .light
        if case .markdown = mode {
            let canvas = UIColor(white: dark ? 22 / 255.0 : 250 / 255.0, alpha: 1)
            web.backgroundColor = canvas
            web.scrollView.backgroundColor = canvas
            web.underPageBackgroundColor = canvas
        }
        #else
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if case .markdown = mode {
            web.underPageBackgroundColor = NSColor(white: dark ? 22 / 255.0 : 250 / 255.0, alpha: 1)
        }
        #endif
    }

    private static func dismantle(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.webView = nil
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "doc")
        web.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var mode: Mode
        private var dark: Bool
        var openExternalURL: (URL) -> Void
        private var resourceDirectory: URL?
        private var markdownReady = false
        private var lastRenderedMarkdown: String?
        private var lastRenderedDark: Bool?

        init(mode: Mode, dark: Bool, openExternalURL: @escaping (URL) -> Void) {
            self.mode = mode
            self.dark = dark
            self.openExternalURL = openExternalURL
        }

        func loadInitialContent() {
            guard let webView else { return }
            markdownReady = false
            lastRenderedMarkdown = nil
            lastRenderedDark = nil
            switch mode {
            case .html(let html):
                resourceDirectory = nil
                webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
            case .markdown:
                if let url = Bundle.main.url(forResource: "markdown-document", withExtension: "html", subdirectory: "Web") {
                    let directory = url.deletingLastPathComponent()
                    resourceDirectory = directory
                    webView.loadFileURL(url, allowingReadAccessTo: directory)
                }
            }
        }

        func update(mode nextMode: Mode, dark nextDark: Bool) {
            let previousMode = mode
            mode = nextMode
            dark = nextDark
            switch (previousMode, nextMode) {
            case (.html(let oldHTML), .html(let newHTML)):
                if oldHTML != newHTML {
                    loadInitialContent()
                }
            case (.markdown, .markdown):
                flushMarkdownIfReady()
            default:
                loadInitialContent()
            }
        }

        private func flushMarkdownIfReady() {
            guard markdownReady, let webView, case .markdown(let markdown) = mode else { return }
            guard lastRenderedMarkdown != markdown || lastRenderedDark != dark else { return }
            lastRenderedMarkdown = markdown
            lastRenderedDark = dark
            webView.callAsyncJavaScript(
                "if (window.MoMoMarkdownDocument) window.MoMoMarkdownDocument.render({ markdown: markdown, dark: dark });",
                arguments: ["markdown": markdown, "dark": dark],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === webView, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                markdownReady = true
                flushMarkdownIfReady()
            case "link":
                if let raw = body["value"] as? String, let url = URL(string: raw) {
                    forwardExternalLinkIfSafe(url)
                }
            default:
                break
            }
        }

        private func forwardExternalLinkIfSafe(_ url: URL) {
            switch url.scheme?.lowercased() {
            case "https", "http":
                if url.host != nil { openExternalURL(url) }
            case "momoagent":
                if url.host == "source" { openExternalURL(url) }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            switch mode {
            case .html:
                if scheme == "about" || scheme == "blob" {
                    decisionHandler(.allow)
                    return
                }
                if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                    forwardExternalLinkIfSafe(url)
                }
                decisionHandler(.cancel)
            case .markdown:
                let isBundledDoc = url.isFileURL && url.deletingLastPathComponent() == resourceDirectory && navigationAction.navigationType == .other
                if isBundledDoc {
                    decisionHandler(.allow)
                } else {
                    if navigationAction.navigationType == .linkActivated {
                        forwardExternalLinkIfSafe(url)
                    }
                    decisionHandler(.cancel)
                }
            }
        }
    }
}
