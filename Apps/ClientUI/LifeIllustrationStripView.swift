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
    var shortClockCaption: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let start = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: windowStart))
        let end = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: windowEnd))
        if start.minute == 0, end.minute == 0 {
            return String(format: "%02d–%02d", start.hour ?? 0, end.hour ?? 0)
        }
        return String(format: "%02d:%02d", start.hour ?? 0, start.minute ?? 0)
    }

    var stickerAngle: Double {
        let index = id.utf8.reduce(0) { ($0 + Int($1)) % 4 }
        return [-2.8, -1.6, 1.8, 2.6][index]
    }
}

struct LifeIllustrationStripView: View {
    let items: [LifeIllustration]
    let store: LifeIllustrationStore
    let open: (LifeIllustration) -> Void
    let showSource: (LifeIllustration) -> Void
    let failure: (String) -> Void

    private var margin: CGFloat {
        #if os(macOS)
        16
        #else
        24
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
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
                .padding(.horizontal, margin).padding(.vertical, 8)
            }
            .frame(height: 68)
        }
        .frame(maxWidth: .infinity)
        .background(MoMoPalette.canvas, ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lifeIllustration.strip")
    }
}

struct LifeIllustrationStampCard: View {
    let illustration: LifeIllustration
    let thumbnailURL: URL
    let index: Int
    let open: () -> Void
    let showSource: () -> Void
    let delete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(illustration.shortClockCaption)
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    Spacer(minLength: 8)
                    if let place = illustration.place, !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(place).font(.system(size: 8.5)).opacity(0.85)
                    } else {
                        Text(String(format: "№%02d", index + 1))
                            .font(.system(size: 8, design: .monospaced)).opacity(0.50)
                    }
                }
                .lineLimit(1).foregroundStyle(MoMoPalette.muted)
                .padding(.leading, 9).padding(.vertical, 7)
                .frame(width: 50, alignment: .leading)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 6))
                    path.addLine(to: CGPoint(x: 0, y: 46))
                }
                .stroke(MoMoPalette.line.opacity(0.85), style: StrokeStyle(lineWidth: 0.5, dash: [1.8, 2.4]))
                .frame(width: 0.5)
                LifeIllustrationImageView(url: thumbnailURL)
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(illustration.stickerAngle))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 104, height: 52)
            .background {
                PostageStampTicketShape().fill(LifeIllustrationPaper.fill(for: colorScheme))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.045), radius: 2.5, x: 0, y: 1)
            }
            .overlay { PostageStampTicketShape().stroke(MoMoPalette.line, lineWidth: 0.6) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "生活插画") + "，" + illustration.dateCaption)
        .accessibilityIdentifier("lifeIllustration.stamp.\(illustration.id)")
        .contextMenu {
            Button("查看依据", systemImage: "text.alignleft", action: showSource)
            Button("删除", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

struct PostageStampTicketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 3
        let radius: CGFloat = 1.9
        let teeth: [CGFloat] = [0.22, 0.41, 0.59, 0.78]
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + corner), control: CGPoint(x: rect.maxX, y: rect.minY))
            for tooth in teeth {
                let y = rect.minY + rect.height * tooth
                path.addLine(to: CGPoint(x: rect.maxX, y: y - radius))
                path.addArc(center: CGPoint(x: rect.maxX, y: y), radius: radius,
                            startAngle: .degrees(-90), endAngle: .degrees(-270), clockwise: true)
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - corner, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - corner), control: CGPoint(x: rect.minX, y: rect.maxY))
            for tooth in teeth.reversed() {
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
