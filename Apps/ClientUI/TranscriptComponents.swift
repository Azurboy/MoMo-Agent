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
                Text(preview).phoneText(.menu).foregroundStyle(MoMoPalette.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

struct ClientRecordingStatusCard: View {
    let title: String
    let subtitle: String
    let indicator: Color
    var showsDisclosure = true

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(indicator).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(title).phoneText(.menu).lineLimit(1).foregroundStyle(Color(white: 0.96))
                        .accessibilityIdentifier("watchStatus.title")
                }
                Text(subtitle).phoneText(.caption).foregroundStyle(Color(white: 0.66))
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 12)
            }.frame(maxWidth: .infinity, alignment: .leading)
            WatchSignalArtwork().frame(width: 72, height: 56).accessibilityHidden(true)
            if showsDisclosure {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(white: 0.66)).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.045)],
            startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09), lineWidth: 0.5) }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct WatchSignalArtwork: View {
    private static let shades = [0.30, 0.48, 0.68, 0.88]
    // Snap the five rings from the chosen reference onto a 2 pt grid once.
    private static let layers: [Path] = {
        let rotation = 22.0 * .pi / 180
        let cosine = cos(rotation), sine = sin(rotation)
        var pixels: [Int: Int] = [:]
        for ring in 0..<5 {
            let index = Double(ring)
            let width = 8 + index * 1.8, height = 16 + index * 9
            for angle in stride(from: 0.0, to: 2 * .pi, by: 0.025) {
                let x = cos(angle) * width / 2, y = sin(angle) * height / 2
                let column = Int(floor((15 + index * 10 + x * cosine - y * sine) / 2))
                let row = Int(floor((36 - index * 2 + x * sine + y * cosine) / 2))
                guard (0..<36).contains(column), (0..<28).contains(row) else { continue }
                let shade = min(3, max(0, Int((y / height + 0.5) * 4)))
                let cell = row * 36 + column
                pixels[cell] = max(pixels[cell] ?? 0, shade)
            }
        }
        return (0..<4).map { shade in
            var path = Path()
            for (cell, value) in pixels where value == shade {
                path.addRect(CGRect(x: (cell % 36) * 2, y: (cell / 36) * 2, width: 2, height: 2))
            }
            return path
        }
    }()

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 72, y: size.height / 56)
            for (index, path) in Self.layers.enumerated() {
                context.fill(path, with: .color(Color(white: Self.shades[index])),
                    style: FillStyle(antialiased: false))
            }
        }
    }
}
