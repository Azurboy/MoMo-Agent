import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import MoMoAgentClient

enum ChatAttachmentImportError: LocalizedError {
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

enum ChatAttachmentImporter {
    static let allowedTypes: [UTType] = {
        var types: [UTType] = [.image, .pdf, .html, .plainText, .json, .sourceCode, .commaSeparatedText]
        if let markdown = UTType(filenameExtension: "md"), !types.contains(markdown) {
            types.append(markdown)
        }
        return types
    }()

    nonisolated static func cameraImage(_ image: UIImage) throws -> AgentAttachment {
        try Task.checkCancellation()
        // UIImage.size is oriented, but measured in points; the attachment limit is in pixels.
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ChatAttachmentImportError.unreadable
        }
        return try autoreleasepool {
            // Resize before encoding; do not allocate a full-resolution JPEG on the main thread.
            let ratio = min(1, 1_536 / max(size.width, size.height))
            let bounds = CGRect(origin: .zero, size: CGSize(width: max(1, (size.width * ratio).rounded()),
                                                           height: max(1, (size.height * ratio).rounded())))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let bytes = UIGraphicsImageRenderer(size: bounds.size, format: format).jpegData(withCompressionQuality: 0.72) { _ in
                image.draw(in: bounds)
            }
            try Task.checkCancellation()
            // Keep this JPEG as the model input; only the preview needs another resize.
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ChatAttachmentImportError.unreadable
            }
            return try attachment(bytes, previewSource: source, name: String(localized: "拍摄照片.jpg"))
        }
    }

    nonisolated static func file(_ url: URL) throws -> AgentAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0 else { throw ChatAttachmentImportError.unreadable }
        guard size <= 20 * 1_048_576 else { throw ChatAttachmentImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 20 * 1_048_576 else { throw ChatAttachmentImportError.tooLarge }
        let ext = url.pathExtension.lowercased()
        let type = properties.contentType ?? UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return try image(data, name: url.lastPathComponent) }
        let text: String
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(data: data), !document.isLocked else { throw ChatAttachmentImportError.unreadable }
            guard document.pageCount <= 200 else { throw ChatAttachmentImportError.tooMuchText }
            var pages: [String] = [], count = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let page = document.page(at: index)?.string ?? ""
                count += page.utf8.count
                guard count <= 256_000 else { throw ChatAttachmentImportError.tooMuchText }
                pages.append(page)
            }
            text = pages.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatAttachmentImportError.noText }
        } else {
            let isKnownTextExt = ["md", "markdown", "html", "htm", "txt", "csv", "json"].contains(ext)
            let isSupportedType = type?.conforms(to: .text) == true || type?.conforms(to: .json) == true || type?.conforms(to: .html) == true || isKnownTextExt
            guard isSupportedType,
                  let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else { throw ChatAttachmentImportError.unsupported }
            text = decoded
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatAttachmentImportError.unreadable }
        guard text.utf8.count <= 256_000 else { throw ChatAttachmentImportError.tooMuchText }
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
        guard data.count <= 20 * 1_048_576 else { throw ChatAttachmentImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ChatAttachmentImportError.unreadable }
        let encoded = try jpeg(source, maximumPixels: 1_536, quality: 0.72)
        return try attachment(encoded, previewSource: source, name: name)
    }

    nonisolated private static func attachment(_ encoded: Data, previewSource: CGImageSource, name: String) throws -> AgentAttachment {
        guard encoded.count <= 1_048_576 else { throw ChatAttachmentImportError.imageTooLarge }
        return AgentAttachment(name: name, kind: .image, mediaType: "image/jpeg", byteCount: encoded.count,
            data: encoded, preview: try jpeg(previewSource, maximumPixels: 160, quality: 0.6))
    }

    nonisolated private static func jpeg(_ source: CGImageSource, maximumPixels: Int, quality: Double) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ChatAttachmentImportError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ChatAttachmentImportError.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ChatAttachmentImportError.unreadable }
        return output as Data
    }
}
