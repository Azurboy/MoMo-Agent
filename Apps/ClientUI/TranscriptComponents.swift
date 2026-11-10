import SwiftUI

/// The phone timeline's presentation, shared with the desktop source adapter.
struct ClientTranscriptRow<Detail: View>: View {
    let time: String
    let preview: String
    let status: String?
    let connected: Bool
    let isFinal: Bool
    var continuesFromPrevious = false
    var bottomSpacing: CGFloat = 26
    @ViewBuilder let detail: () -> Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle().fill(MoMoPalette.line).frame(width: 1, height: 17)
                    .opacity(continuesFromPrevious ? 1 : 0)
                Circle().strokeBorder(MoMoPalette.muted, lineWidth: 1.5)
                    .background(isFinal ? Color.clear : MoMoPalette.ink, in: Circle()).frame(width: 8, height: 8)
                if connected { Rectangle().fill(MoMoPalette.line).frame(width: 1) }
            }.frame(width: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                ViewThatFits(in: .horizontal) {
                    HStack { Text(time).phoneText(.menu).monospacedDigit(); Spacer(minLength: 8); state }
                    VStack(alignment: .leading, spacing: 4) { Text(time).phoneText(.menu).monospacedDigit(); state }
                }
                detail()
                if !preview.isEmpty {
                    Text(preview).phoneText(.menu).foregroundStyle(MoMoPalette.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 10).padding(.bottom, bottomSpacing)
        }
        .foregroundStyle(MoMoPalette.ink)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
    }

    @ViewBuilder private var state: some View {
        if let status { Text(status).phoneText(.caption).foregroundStyle(MoMoPalette.muted) }
        else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(MoMoPalette.muted) }
    }
}
