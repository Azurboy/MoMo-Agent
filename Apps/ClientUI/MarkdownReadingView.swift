import SwiftUI

struct MarkdownReadingView: View, Equatable {
    let markdown: String
    let accessibilityID: String

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
                        accessibilityID: "\(accessibilityID).block.\(block.id)")
                }
            case .failure:
                Text("排版暂不可用，以下显示原文。")
                    .phoneText(.metadata).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                Text(markdown).phoneText(.body)
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
    @ScaledMetric(relativeTo: .body) private var indent = 20.0
    @ScaledMetric(relativeTo: .body) private var paragraphSpacing = 16.0
    @ScaledMetric(relativeTo: .body) private var listSpacing = 6.0
    @ScaledMetric(relativeTo: .headline) private var headingSpacing = 8.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if block.listDepth > 0 {
                Text(block.listMarker ?? "")
                    .phoneText(.body).monospacedDigit()
                    .frame(minWidth: indent, alignment: .trailing)
            }
            Text(block.text)
                .phoneText(textStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(block.headingLevel == nil ? [] : .isHeader)
                .accessibilityIdentifier(accessibilityID)
        }
        .padding(.leading, Double(max(0, block.listDepth - 1)) * indent)
        .padding(.leading, block.isQuote ? 12 : 0)
        .overlay(alignment: .leading) {
            if block.isQuote {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, block.headingLevel != nil && !isFirst ? headingSpacing : 0)
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
