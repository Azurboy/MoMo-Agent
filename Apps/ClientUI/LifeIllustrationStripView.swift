import SwiftUI
import MoMoAgentClient

enum LifeIllustrationPaper {
    static func fill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.145, green: 0.141, blue: 0.135)
            : Color(red: 0.985, green: 0.978, blue: 0.960)
    }
}

extension LifeIllustration {
    var stampExcerpt: String {
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        if let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            return place
        }
        return caption
    }

    var stampPlaceLabel: String? {
        guard let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else {
            return nil
        }
        return place
    }

    var stampStartClock: String {
        let zone = TimeZone(identifier: timezone) ?? .current
        var clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        clock.timeZone = zone
        return Date(timeIntervalSince1970: windowStart).formatted(clock)
    }

    var stickerAngle: Double {
        let index = id.utf8.reduce(0) { ($0 + Int($1)) % 4 }
        return [-2.8, -1.6, 1.8, 2.6][index]
    }
}

/// Daily journal masthead rendered directly beneath the date bar like commemorative stamps at the top of a diary page.
struct LifeIllustrationStripView: View {
    let items: [LifeIllustration]
    let store: LifeIllustrationStore
    var horizontalMargin: CGFloat? = nil
    let open: (LifeIllustration) -> Void
    let showSource: (LifeIllustration) -> Void
    let failure: (String) -> Void

    private var margin: CGFloat {
        if let horizontalMargin { return horizontalMargin }
        #if os(macOS)
        return 16
        #else
        return 24
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if let url = store.imageURL(for: item) {
                            LifeIllustrationStampCard(illustration: item, thumbnailURL: url, index: index,
                                open: { open(item) }, showSource: { showSource(item) }, delete: {
                                    Task {
                                        do { try await store.delete(item) }
                                        catch { failure(error.localizedDescription) }
                                    }
                                })
                        }
                    }
                }
                .padding(.horizontal, margin)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(height: 106)
            GeometryReader { geometry in
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                }
                .stroke(MoMoPalette.line, style: StrokeStyle(lineWidth: 0.5, dash: [2.5, 3]))
            }
            .frame(height: 0.5)
            .padding(.horizontal, margin)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .background(MoMoPalette.canvas, ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lifeIllustration.strip")
    }
}

struct LifeIllustrationStampCard: View {
    static let cardWidth: CGFloat = 78
    static let cardHeight: CGFloat = 92

    let illustration: LifeIllustration
    let thumbnailURL: URL
    let index: Int
    let open: () -> Void
    let showSource: () -> Void
    let delete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var accessibilitySummary: String {
        "\(String(localized: "生活插画"))，\(illustration.stampStartClock)，\(illustration.stampExcerpt)"
    }

    private var artworkFrame: some View {
        let hasPlace = illustration.stampPlaceLabel != nil
        let artSize: CGFloat = hasPlace ? 48 : 54
        let frameHeight: CGFloat = hasPlace ? 54 : 62
        let matOpacity: Double = colorScheme == .dark ? 0.24 : 0.45
        return LifeIllustrationImageView(url: thumbnailURL)
            .frame(width: artSize, height: artSize)
            .rotationEffect(.degrees(illustration.stickerAngle))
            .frame(width: 64, height: frameHeight)
            .background(MoMoPalette.canvas.opacity(matOpacity), in: RoundedRectangle(cornerRadius: 2))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(MoMoPalette.line.opacity(0.5), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private var postmarkCaption: some View {
        if let place = illustration.stampPlaceLabel {
            VStack(spacing: 1) {
                Text(place)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(MoMoPalette.ink.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(illustration.stampStartClock)
                    .font(.system(size: 8.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(MoMoPalette.muted)
                    .lineLimit(1)
            }
            .frame(width: 64)
        } else {
            Text(illustration.stampStartClock)
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(MoMoPalette.muted)
                .lineLimit(1)
                .frame(width: 64)
                .frame(maxHeight: .infinity)
        }
    }

    var body: some View {
        let shadowOpacity: Double = colorScheme == .dark ? 0.28 : 0.05
        Button(action: open) {
            VStack(spacing: 4) {
                artworkFrame
                postmarkCaption
            }
            .padding(.top, 6)
            .padding(.bottom, 5)
            .padding(.horizontal, 7)
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .background {
                PostageStampTicketShape().fill(LifeIllustrationPaper.fill(for: colorScheme))
                    .shadow(color: .black.opacity(shadowOpacity), radius: 2.5, x: 0, y: 1)
            }
            .overlay { PostageStampTicketShape().stroke(MoMoPalette.line, lineWidth: 0.6) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("lifeIllustration.stamp.\(illustration.id)")
        .contextMenu {
            Button("查看依据", systemImage: "text.alignleft", action: showSource)
            Button("删除", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

struct PostageStampTicketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 3.5
        let radius: CGFloat = 1.75
        let horizontalTeeth: [CGFloat] = [0.18, 0.34, 0.50, 0.66, 0.82]
        let verticalTeeth: [CGFloat] = [0.16, 0.296, 0.432, 0.568, 0.704, 0.84]
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
            for tooth in horizontalTeeth {
                let x = rect.minX + rect.width * tooth
                path.addLine(to: CGPoint(x: x - radius, y: rect.minY))
                path.addArc(center: CGPoint(x: x, y: rect.minY), radius: radius,
                            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            }
            path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + corner), control: CGPoint(x: rect.maxX, y: rect.minY))
            for tooth in verticalTeeth {
                let y = rect.minY + rect.height * tooth
                path.addLine(to: CGPoint(x: rect.maxX, y: y - radius))
                path.addArc(center: CGPoint(x: rect.maxX, y: y), radius: radius,
                            startAngle: .degrees(-90), endAngle: .degrees(-270), clockwise: true)
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - corner, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            for tooth in horizontalTeeth.reversed() {
                let x = rect.minX + rect.width * tooth
                path.addLine(to: CGPoint(x: x + radius, y: rect.maxY))
                path.addArc(center: CGPoint(x: x, y: rect.maxY), radius: radius,
                            startAngle: .degrees(0), endAngle: .degrees(-180), clockwise: true)
            }
            path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - corner), control: CGPoint(x: rect.minX, y: rect.maxY))
            for tooth in verticalTeeth.reversed() {
                let y = rect.minY + rect.height * tooth
                path.addLine(to: CGPoint(x: rect.minX, y: y + radius))
                path.addArc(center: CGPoint(x: rect.minX, y: y), radius: radius,
                            startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
            }
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
            path.addQuadCurve(to: CGPoint(x: rect.minX + corner, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
