import SwiftUI

struct MarkdownReadingView: View, Equatable {
    let markdown: String
    let accessibilityID: String
    var handwriting: Bool = false

    var body: some View {
        let document = Result { try MarkdownDocument(markdown) }
        VStack(alignment: .leading, spacing: 0) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block
    let isFirst: Bool
    let isLast: Bool
    let accessibilityID: String
    let handwriting: Bool
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var indent = 14.0
    @ScaledMetric(relativeTo: .body) private var paragraphSpacing = 5.0
    @ScaledMetric(relativeTo: .body) private var listSpacing = 3.0
    @ScaledMetric(relativeTo: .headline) private var headingSpacing = 3.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if block.listDepth > 0 {
                Text(block.listMarker ?? "")
                    .phoneText(.body).monospacedDigit()
                    .foregroundStyle(handwriting ? MemoryNotebookPalette(scheme: scheme).secondaryInk : MoMoPalette.muted)
                    .frame(minWidth: indent, alignment: .trailing)
            }
            Text(block.text)
                .modifier(MarkdownReadingTypography(style: textStyle, handwriting: handwriting))
                .lineSpacing(handwriting ? 1.5 : (block.headingLevel == nil ? 5 : 2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(block.headingLevel == nil ? [] : .isHeader)
                .accessibilityIdentifier(accessibilityID)
        }
        .padding(.leading, Double(max(0, block.listDepth - 1)) * indent)
        .padding(.leading, block.isQuote ? 10 : 0)
        .overlay(alignment: .leading) {
            if block.isQuote {
                Rectangle().fill(handwriting ? MemoryNotebookPalette(scheme: scheme).margin.opacity(0.5) : .secondary.opacity(0.4)).frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, block.headingLevel != nil && !isFirst ? headingSpacing + 2 : 0)
        .padding(.bottom, isLast ? 0 : (block.headingLevel != nil ? headingSpacing : (block.listDepth > 0 ? listSpacing : paragraphSpacing)))
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
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if handwriting {
            if style == .code {
                content.phoneText(.code).foregroundStyle(MemoryNotebookPalette(scheme: scheme).ink)
            } else {
                content.momoHandwriting(size: size, weight: style.weight, relativeTo: style.relativeStyle)
                    .foregroundStyle(MemoryNotebookPalette(scheme: scheme).ink)
            }
        } else {
            content.phoneText(style)
        }
    }

    private var size: CGFloat {
        switch style {
        case .heading: 14.5
        case .subheading: 13
        case .section: 12.5
        default: 12
        }
    }
}
