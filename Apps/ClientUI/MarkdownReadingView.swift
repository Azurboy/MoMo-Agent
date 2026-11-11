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
        #if os(macOS)
        return handwriting ? 13.5 : PhoneTextStyle.body.size
        #else
        return handwriting ? 14.5 : PhoneTextStyle.body.size
        #endif
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
        #if os(macOS)
        switch style {
        case .heading: return 16
        case .subheading: return 14.5
        case .section: return 13.5
        default: return 13.5
        }
        #else
        switch style {
        case .heading: return 17
        case .subheading: return 15.5
        case .section: return 14.5
        default: return 14.5
        }
        #endif
    }
}
