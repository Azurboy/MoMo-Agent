import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MarkdownReadingView: View, Equatable {
    let markdown: String
    let accessibilityID: String
    var handwriting: Bool = false
    var plainTextOnly: Bool = false

    var body: some View {
        #if os(macOS)
        MacMarkdownReaderHost(
            markdown: markdown,
            accessibilityID: accessibilityID,
            handwriting: handwriting,
            plainTextOnly: plainTextOnly
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        let document = MarkdownDocument.cached(markdown)
        VStack(alignment: .leading, spacing: 0) {
            if plainTextOnly {
                Text(markdown)
                    .modifier(MarkdownReadingTypography(style: .body, handwriting: handwriting))
                    .lineSpacing(handwriting ? 4 : PhoneTextStyle.body.extraLeading)
                    .accessibilityIdentifier("\(accessibilityID).block.original")
            } else {
                switch document {
                case .success(let document):
                    let firstID = document.blocks.first?.id
                    let lastID = document.blocks.last?.id
                    ForEach(document.blocks) { block in
                        MarkdownBlockView(block: block,
                            isFirst: block.id == firstID,
                            isLast: block.id == lastID,
                            accessibilityID: "\(accessibilityID).block.\(block.id)",
                            handwriting: handwriting)
                    }
                case .failure:
                    Text("排版暂不可用，以下显示原文。")
                        .phoneText(.metadata).foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                    Text(markdown).modifier(MarkdownReadingTypography(style: .body, handwriting: handwriting))
                        .lineSpacing(handwriting ? 4 : PhoneTextStyle.body.extraLeading)
                        .accessibilityIdentifier("\(accessibilityID).block.original")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityID)
        #endif
    }
}

#if os(macOS)
enum MacMarkdownRenderer {
    final class RenderedDocument: NSObject, @unchecked Sendable {
        let key: String
        let markdown: String
        let attributedString: NSAttributedString
        let quoteCharRanges: [NSRange]

        init(key: String, markdown: String, attributedString: NSAttributedString, quoteCharRanges: [NSRange]) {
            self.key = key
            self.markdown = markdown
            self.attributedString = attributedString
            self.quoteCharRanges = quoteCharRanges
        }
    }

    private nonisolated(unsafe) static let renderedCache: NSCache<NSString, RenderedDocument> = {
        let cache = NSCache<NSString, RenderedDocument>()
        cache.countLimit = 512
        return cache
    }()

    private nonisolated(unsafe) static let heightCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 2048
        return cache
    }()

    private static let dynamicLinkColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.54, green: 0.73, blue: 0.93, alpha: 1.0)
            : NSColor(srgbRed: 0.18, green: 0.39, blue: 0.62, alpha: 1.0)
    }

    private static let dynamicCodeBackground = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(white: 1.0, alpha: 0.09)
            : NSColor(white: 0.0, alpha: 0.055)
    }

    nonisolated static func makeKey(markdown: String, handwriting: Bool, plainTextOnly: Bool) -> String {
        var hasher = Hasher()
        hasher.combine(handwriting)
        hasher.combine(plainTextOnly)
        hasher.combine(markdown.utf8.count)
        hasher.combine(markdown)
        return "\(markdown.utf8.count):\(handwriting ? 1 : 0):\(plainTextOnly ? 1 : 0):\(hasher.finalize())"
    }

    nonisolated static func prewarm(_ markdown: String, handwriting: Bool = true, plainTextOnly: Bool = false) {
        _ = render(markdown: markdown, handwriting: handwriting, plainTextOnly: plainTextOnly)
    }

    nonisolated static func cachedHeight(forKey key: String, width: Int) -> CGFloat? {
        guard width > 0 else { return nil }
        let hKey = "\(key)#\(width)" as NSString
        guard let num = heightCache.object(forKey: hKey) else { return nil }
        return CGFloat(num.doubleValue)
    }

    nonisolated static func storeHeight(_ height: CGFloat, forKey key: String, width: Int) {
        guard width > 0, height > 0 else { return }
        let hKey = "\(key)#\(width)" as NSString
        heightCache.setObject(NSNumber(value: Double(height)), forKey: hKey)
    }

    nonisolated static func render(markdown: String, handwriting: Bool, plainTextOnly: Bool) -> RenderedDocument {
        let key = makeKey(markdown: markdown, handwriting: handwriting, plainTextOnly: plainTextOnly)
        let nsKey = key as NSString
        if let hit = renderedCache.object(forKey: nsKey), hit.markdown == markdown {
            return hit
        }

        let inkColor = NSColor(named: "PhoneInk") ?? .labelColor
        let mutedColor = NSColor(named: "PhoneMuted") ?? .secondaryLabelColor

        if plainTextOnly {
            let fontSize: CGFloat = handwriting ? 13.8 : PhoneTextStyle.body.size
            let style = NSMutableParagraphStyle()
            style.lineSpacing = handwriting ? 4.8 : 4.5
            style.paragraphSpacing = 6.0
            let attr = NSAttributedString(
                string: markdown,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: inkColor,
                    .paragraphStyle: style,
                ]
            )
            let doc = RenderedDocument(key: key, markdown: markdown, attributedString: attr, quoteCharRanges: [])
            renderedCache.setObject(doc, forKey: nsKey)
            return doc
        }

        switch MarkdownDocument.cached(markdown) {
        case .success(let parsed) where !parsed.blocks.isEmpty:
            let out = NSMutableAttributedString()
            var quoteRanges: [NSRange] = []
            let total = parsed.blocks.count
            let indentStep: CGFloat = 18.0

            for (index, block) in parsed.blocks.enumerated() {
                let isFirst = index == 0
                let isLast = index == total - 1

                let (fontSize, baseWeight): (CGFloat, NSFont.Weight) = {
                    if block.isCode {
                        return (12.5, .regular)
                    }
                    if handwriting {
                        switch block.headingLevel {
                        case 1: return (16.5, .semibold)
                        case 2: return (15.0, .semibold)
                        case .some: return (14.0, .medium)
                        case .none: return (13.8, .regular)
                        }
                    } else {
                        switch block.headingLevel {
                        case 1: return (PhoneTextStyle.heading.size, .medium)
                        case 2: return (PhoneTextStyle.subheading.size, .medium)
                        case .some: return (PhoneTextStyle.section.size, .medium)
                        case .none: return (PhoneTextStyle.body.size, .regular)
                        }
                    }
                }()

                let quoteIndent: CGFloat = block.isQuote ? 13.0 : 0.0
                let nestedListIndent = CGFloat(max(0, block.listDepth - 1)) * indentStep
                let firstLineIndent = quoteIndent + nestedListIndent
                let bodyIndent = block.listDepth > 0 ? (firstLineIndent + indentStep) : firstLineIndent

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.firstLineHeadIndent = firstLineIndent
                paragraphStyle.headIndent = bodyIndent
                if block.listDepth > 0 {
                    paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: bodyIndent)]
                    paragraphStyle.defaultTabInterval = indentStep
                }
                paragraphStyle.lineSpacing = handwriting
                    ? (block.headingLevel != nil ? 2.5 : 5.0)
                    : (block.headingLevel != nil ? 2.0 : 4.5)
                paragraphStyle.paragraphSpacingBefore = (block.headingLevel != nil && !isFirst) ? 10.0 : 0.0
                paragraphStyle.paragraphSpacing = isLast
                    ? 0.0
                    : (block.headingLevel != nil ? 5.0 : (block.listDepth > 0 ? 4.5 : 7.0))

                let blockStart = out.length

                if block.listDepth > 0 {
                    let markerText = (block.listMarker ?? "•") + "\t"
                    let markerFont = NSFont.monospacedDigitSystemFont(ofSize: max(12, fontSize - 0.5), weight: .regular)
                    out.append(NSAttributedString(
                        string: markerText,
                        attributes: [
                            .font: markerFont,
                            .foregroundColor: mutedColor,
                            .paragraphStyle: paragraphStyle,
                        ]
                    ))
                }

                for run in block.text.runs {
                    let slice = String(block.text[run.range].characters)
                    guard !slice.isEmpty else { continue }
                    let inlineIntent = run.inlinePresentationIntent ?? []
                    let isCode = block.isCode || inlineIntent.contains(.code)
                    let isBold = inlineIntent.contains(.stronglyEmphasized)
                    let isItalic = inlineIntent.contains(.emphasized)

                    let runFont: NSFont = {
                        if isCode {
                            return NSFont.monospacedSystemFont(
                                ofSize: max(12, fontSize - 1.0),
                                weight: isBold ? .semibold : .regular
                            )
                        }
                        let base = NSFont.systemFont(
                            ofSize: fontSize,
                            weight: isBold ? .semibold : baseWeight
                        )
                        if isItalic {
                            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                        }
                        return base
                    }()

                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: runFont,
                        .foregroundColor: run.link != nil ? dynamicLinkColor : (block.isQuote ? mutedColor : inkColor),
                        .paragraphStyle: paragraphStyle,
                    ]
                    if isCode && !block.isCode {
                        attrs[.backgroundColor] = dynamicCodeBackground
                    }
                    if inlineIntent.contains(.strikethrough) {
                        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if let url = run.link {
                        attrs[.link] = url
                        attrs[.cursor] = NSCursor.pointingHand
                    }
                    out.append(NSAttributedString(string: slice, attributes: attrs))
                }

                let contentEnd = out.length
                if block.isQuote && contentEnd > blockStart {
                    quoteRanges.append(NSRange(location: blockStart, length: contentEnd - blockStart))
                }

                if !isLast {
                    out.append(NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: fontSize, weight: baseWeight),
                            .paragraphStyle: paragraphStyle,
                        ]
                    ))
                }
            }

            let doc = RenderedDocument(key: key, markdown: markdown, attributedString: out, quoteCharRanges: quoteRanges)
            renderedCache.setObject(doc, forKey: nsKey)
            return doc

        default:
            let fontSize: CGFloat = handwriting ? 13.8 : PhoneTextStyle.body.size
            let style = NSMutableParagraphStyle()
            style.lineSpacing = handwriting ? 4.8 : 4.5
            let fallback = NSAttributedString(
                string: markdown,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: inkColor,
                    .paragraphStyle: style,
                ]
            )
            let doc = RenderedDocument(key: key, markdown: markdown, attributedString: fallback, quoteCharRanges: [])
            renderedCache.setObject(doc, forKey: nsKey)
            return doc
        }
    }
}

private struct MacMarkdownReaderHost: View {
    let markdown: String
    let accessibilityID: String
    let handwriting: Bool
    let plainTextOnly: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        MacMarkdownTextView(
            rendered: MacMarkdownRenderer.render(
                markdown: markdown,
                handwriting: handwriting,
                plainTextOnly: plainTextOnly
            ),
            accessibilityID: accessibilityID,
            onOpenURL: { url in
                openURL(url)
            }
        )
    }
}

private final class MacIntrinsicNSTextView: NSTextView {
    let txStorage: NSTextStorage
    let txLayoutManager: NSLayoutManager
    let txContainer: NSTextContainer

    var currentKey: String = ""
    var quoteCharRanges: [NSRange] = []
    var lastMeasuredWidth: CGFloat = -1
    var lastMeasuredHeight: CGFloat = 24

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        self.txStorage = storage
        self.txLayoutManager = layoutManager
        self.txContainer = container

        super.init(frame: .zero, textContainer: container)

        drawsBackground = false
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        usesFontPanel = false
        usesFindBar = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(rendered: MacMarkdownRenderer.RenderedDocument, accessibilityID: String) {
        if self.accessibilityIdentifier() != accessibilityID {
            self.setAccessibilityIdentifier(accessibilityID)
        }
        guard currentKey != rendered.key else { return }
        currentKey = rendered.key
        quoteCharRanges = rendered.quoteCharRanges
        lastMeasuredWidth = -1
        if selectedRange().length > 0 {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        txStorage.setAttributedString(rendered.attributedString)
        needsDisplay = true
    }

    func measuredHeight(forWidth rawWidth: CGFloat) -> CGFloat {
        let width = floor(max(120, rawWidth))
        if abs(lastMeasuredWidth - width) < 0.5, lastMeasuredHeight > 0 {
            return lastMeasuredHeight
        }
        if let cached = MacMarkdownRenderer.cachedHeight(forKey: currentKey, width: Int(width)) {
            if abs(txContainer.containerSize.width - width) >= 0.5 {
                txContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            lastMeasuredWidth = width
            lastMeasuredHeight = cached
            return cached
        }
        txContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        txLayoutManager.ensureLayout(for: txContainer)
        let used = txLayoutManager.usedRect(for: txContainer)
        let resolved = max(18, ceil(used.height + 2))
        lastMeasuredWidth = width
        lastMeasuredHeight = resolved
        MacMarkdownRenderer.storeHeight(resolved, forKey: currentKey, width: Int(width))
        return resolved
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let w = floor(max(120, newSize.width))
        if abs(txContainer.containerSize.width - w) >= 0.5 {
            txContainer.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !quoteCharRanges.isEmpty else { return }
        let barColor = NSColor(named: "PhoneLine") ?? .separatorColor
        barColor.setFill()
        let totalLen = txStorage.length
        for charRange in quoteCharRanges {
            guard charRange.location >= 0, NSMaxRange(charRange) <= totalLen else { continue }
            let glyphRange = txLayoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let rect = txLayoutManager.boundingRect(forGlyphRange: glyphRange, in: txContainer)
            guard rect.height > 1 else { continue }
            let barRect = NSRect(x: 0.5, y: rect.minY + 1, width: 2.5, height: max(4, rect.height - 2))
            if barRect.intersects(dirtyRect) {
                NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
            }
        }
    }
}

private struct MacMarkdownTextView: NSViewRepresentable {
    let rendered: MacMarkdownRenderer.RenderedDocument
    let accessibilityID: String
    let onOpenURL: (URL) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: (URL) -> Void

        init(onOpenURL: @escaping (URL) -> Void) {
            self.onOpenURL = onOpenURL
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                onOpenURL(url)
                return true
            }
            if let str = link as? String, let url = URL(string: str) {
                onOpenURL(url)
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeNSView(context: Context) -> MacIntrinsicNSTextView {
        let view = MacIntrinsicNSTextView()
        view.delegate = context.coordinator
        view.apply(rendered: rendered, accessibilityID: accessibilityID)
        return view
    }

    func updateNSView(_ nsView: MacIntrinsicNSTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        nsView.apply(rendered: rendered, accessibilityID: accessibilityID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacIntrinsicNSTextView, context: Context) -> CGSize? {
        nsView.apply(rendered: rendered, accessibilityID: accessibilityID)
        guard let proposedWidth = proposal.width,
              proposedWidth.isFinite,
              proposedWidth > 1 else {
            // Short-circuit unconstrained / ideal horizontal probing in O(1).
            return CGSize(width: 320, height: max(20, nsView.lastMeasuredHeight))
        }
        let width = floor(max(120, proposedWidth))
        let height = nsView.measuredHeight(forWidth: width)
        return CGSize(width: width, height: height)
    }
}
#else
private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block
    let isFirst: Bool
    let isLast: Bool
    let accessibilityID: String
    let handwriting: Bool
    @ScaledMetric(relativeTo: .body) private var indent = 14.0
    @ScaledMetric(relativeTo: .body) private var paragraphSpacing = 5.0
    @ScaledMetric(relativeTo: .body) private var listSpacing = 3.0
    @ScaledMetric(relativeTo: .headline) private var headingSpacing = 3.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if block.listDepth > 0 {
                Text(block.listMarker ?? "")
                    .font(.system(size: listMarkerSize, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(MoMoPalette.muted)
                    .frame(minWidth: indent, alignment: .trailing)
            }
            Text(block.text)
                .modifier(MarkdownReadingTypography(style: textStyle, handwriting: handwriting))
                .lineSpacing(handwriting ? 4.0 : (block.headingLevel == nil ? 5 : 2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(block.headingLevel == nil ? [] : .isHeader)
                .accessibilityIdentifier(accessibilityID)
        }
        .padding(.leading, Double(max(0, block.listDepth - 1)) * indent)
        .padding(.leading, block.isQuote ? 12 : 0)
        .overlay(alignment: .leading) {
            if block.isQuote {
                RoundedRectangle(cornerRadius: 1)
                    .fill(MoMoPalette.line)
                    .frame(width: 2.5)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, block.headingLevel != nil && !isFirst ? headingSpacing + 6 : 0)
        .padding(.bottom, isLast ? 0 : (block.headingLevel != nil ? headingSpacing + 1 : (block.listDepth > 0 ? listSpacing + 1 : paragraphSpacing + 1)))
    }

    private var listMarkerSize: CGFloat {
        handwriting ? 14.5 : PhoneTextStyle.body.size
    }

    private var textStyle: PhoneTextStyle {
        if block.isCode { return .code }
        switch block.headingLevel {
        case 1: return .heading
        case 2: return .subheading
        case .some: return .section
        case .none: return .body
        }
    }
}

private struct MarkdownReadingTypography: ViewModifier {
    let style: PhoneTextStyle
    let handwriting: Bool

    func body(content: Content) -> some View {
        if handwriting {
            if style == .code {
                content.phoneText(.code).foregroundStyle(MoMoPalette.ink)
            } else {
                content
                    .font(.system(size: size, weight: editorialWeight))
                    .foregroundStyle(MoMoPalette.ink)
            }
        } else {
            content.phoneText(style)
        }
    }

    private var editorialWeight: Font.Weight {
        switch style {
        case .heading, .subheading: return .semibold
        case .section: return .medium
        default: return .regular
        }
    }

    private var size: CGFloat {
        switch style {
        case .heading: return 17
        case .subheading: return 15.5
        case .section: return 14.5
        default: return 14.5
        }
    }
}
#endif
