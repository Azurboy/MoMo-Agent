import Foundation
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import MoMoAgentClient
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension AgentAttachment {
    var displayFormat: String {
        if kind == .image { return String(localized: "照片") }
        let suffix = (name as NSString).pathExtension.uppercased()
        return suffix.isEmpty ? String(localized: "文本") : String(suffix.prefix(8))
    }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
}

enum ClientAttachmentImportError: LocalizedError {
    case tooLarge, imageTooLarge, unreadable, unsupported, noText, tooMuchText
    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "这个文件超过 20 MB，请选择较小的文件。")
        case .imageTooLarge: String(localized: "照片压缩后仍然过大，请裁剪后再添加。")
        case .unreadable: String(localized: "无法读取这个文件，请重新选择。")
        case .unsupported: String(localized: "目前支持照片、PDF 和文本文件，请选择这些格式。")
        case .noText: String(localized: "这个 PDF 没有可提取的文字。请将需要阅读的页面作为照片添加。")
        case .tooMuchText: String(localized: "文件文字过多，请拆分后再添加。")
        }
    }
}

enum ClientAttachmentImporter {
    static let allowedTypes: [UTType] = [.image, .pdf, .plainText, .json, .sourceCode, .commaSeparatedText]

    nonisolated static func file(_ url: URL) throws -> AgentAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0 else { throw ClientAttachmentImportError.unreadable }
        guard size <= 20 * 1_048_576 else { throw ClientAttachmentImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 20 * 1_048_576 else { throw ClientAttachmentImportError.tooLarge }
        let type = properties.contentType ?? UTType(filenameExtension: url.pathExtension)
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
                guard count <= 48_000 else { throw ClientAttachmentImportError.tooMuchText }
                pages.append(page)
            }
            text = pages.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientAttachmentImportError.noText }
        } else {
            guard let type, type.conforms(to: .text) || type.conforms(to: .json),
                  let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else { throw ClientAttachmentImportError.unsupported }
            text = decoded
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientAttachmentImportError.unreadable }
        guard text.utf8.count <= 48_000 else { throw ClientAttachmentImportError.tooMuchText }
        return AgentAttachment(name: url.lastPathComponent, kind: .document, mediaType: type?.preferredMIMEType ?? "text/plain", byteCount: data.count, text: text)
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
    let attachment: AgentAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text(attachment.name).font(.headline).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            content.frame(minWidth: 520, minHeight: 400)
        }.background(MoMoPalette.canvas)
        #else
        NavigationStack {
            content
                .background(MoMoPalette.canvas)
                .phoneSoftTopEdge()
                .navigationTitle(attachment.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let data = attachment.data ?? attachment.preview, let image = platformImage(from: data) {
            GeometryReader { geometry in
                image.resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else if let text = attachment.text {
            ScrollView {
                Text(text).phoneText(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        } else {
            VStack(spacing: 8) {
                Text(attachment.name).phoneText(.heading)
                Text(attachment.displaySize).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
