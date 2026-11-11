import Foundation

/// Foundation owns Markdown syntax; this value only maps its block semantics to reading layout.
struct MarkdownDocument {
    struct Block: Identifiable {
        let id: Int
        let text: AttributedString
        let headingLevel: Int?
        let listDepth: Int
        let listMarker: String?
        let isQuote: Bool
        let isCode: Bool

        var plainText: String { String(text.characters) }
    }

    let blocks: [Block]

    private final class CachedDocumentBox: NSObject {
        let markdown: String
        let result: Result<MarkdownDocument, Error>
        init(markdown: String, result: Result<MarkdownDocument, Error>) {
            self.markdown = markdown
            self.result = result
        }
    }

    private final class CachedPreviewBox: NSObject {
        let markdown: String
        let limit: Int
        let preview: String
        init(markdown: String, limit: Int, preview: String) {
            self.markdown = markdown
            self.limit = limit
            self.preview = preview
        }
    }

    private nonisolated(unsafe) static let documentCache: NSCache<NSString, CachedDocumentBox> = {
        let cache = NSCache<NSString, CachedDocumentBox>()
        cache.countLimit = 512
        return cache
    }()

    private nonisolated(unsafe) static let previewCache: NSCache<NSString, CachedPreviewBox> = {
        let cache = NSCache<NSString, CachedPreviewBox>()
        cache.countLimit = 1024
        return cache
    }()

    private static func fastKey(for markdown: String, extra: Int = 0) -> NSString {
        var hasher = Hasher()
        hasher.combine(extra)
        hasher.combine(markdown.utf8.count)
        hasher.combine(markdown)
        return "\(markdown.utf8.count):\(extra):\(hasher.finalize())" as NSString
    }

    static func cached(_ markdown: String) -> Result<MarkdownDocument, Error> {
        let key = fastKey(for: markdown)
        if let hit = documentCache.object(forKey: key), hit.markdown == markdown {
            return hit.result
        }
        let parsed = Result { try MarkdownDocument(markdown) }
        documentCache.setObject(CachedDocumentBox(markdown: markdown, result: parsed), forKey: key)
        return parsed
    }

    static func plainTextPreview(_ markdown: String, limit: Int = 256) -> String {
        let cacheKey = fastKey(for: markdown, extra: limit)
        if let hit = previewCache.object(forKey: cacheKey), hit.limit == limit, hit.markdown == markdown {
            return hit.preview
        }
        let plain: String
        if case .success(let document) = cached(markdown), !document.blocks.isEmpty {
            plain = document.blocks.map(\.plainText).joined(separator: "  ")
        } else {
            plain = markdown
        }
        let formatted = String(plain.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit))
        previewCache.setObject(CachedPreviewBox(markdown: markdown, limit: limit, preview: formatted), forKey: cacheKey)
        return formatted
    }

    init(_ markdown: String) throws {
        let attributed = try AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
        var result: [Block] = []
        var seenListItems = Set<Int>()
        // Slicing by this attribute keeps inline emphasis and links in the same paragraph.
        for (intent, range) in attributed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            var heading: Int?
            var listDepth = 0
            var item: PresentationIntent.IntentType?
            var ordered = false
            var foundNearestList = false
            var quote = false
            var code = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .listItem: if item == nil { item = component }
                case .orderedList, .unorderedList:
                    listDepth += 1
                    if !foundNearestList {
                        ordered = component.kind == .orderedList
                        foundNearestList = true
                    }
                case .blockQuote: quote = true
                case .codeBlock: code = true
                default: break
                }
            }
            var marker: String?
            if let item, seenListItems.insert(item.identity).inserted,
               case .listItem(let ordinal) = item.kind {
                marker = ordered ? "\(ordinal)." : "•"
            }
            result.append(Block(id: components.first?.identity ?? -(result.count + 1),
                text: AttributedString(attributed[range]), headingLevel: heading,
                listDepth: listDepth, listMarker: marker, isQuote: quote, isCode: code))
        }
        blocks = result
    }
}
