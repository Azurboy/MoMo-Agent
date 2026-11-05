import MapKit
import MoMoAgentClient
import SwiftUI

struct LifeIllustrationJourneyMapView: View {
    let store: LifeIllustrationStore
    let initialID: String
    var close: (() -> Void)? = nil
    let showSource: (LifeIllustration) -> Void
    @State private var detail: LifeIllustration?
    @State private var projection = JourneyProjection()
    @State private var page = 0
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var items: [LifeIllustration] {
        let day = store.items.first { $0.id == initialID }?.logicalDay
        return store.items.filter { $0.logicalDay == day }.sorted { $0.windowStart < $1.windowStart }
    }

    private var dayTimeSpan: String? {
        guard let first = items.first, let last = items.last else { return nil }
        return "\(first.clock(first.placeStart ?? first.windowStart))–\(last.clock(last.placeEnd ?? last.windowEnd))"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let capacity = max(1, min(3, Int((geometry.size.height - 32) / 146)))
                let pageCount = max(1, (items.count + capacity - 1) / capacity)
                let visible = Array(items.dropFirst(min(page, pageCount - 1) * capacity).prefix(capacity))
                mapContent(visible: visible, size: geometry.size)
                    .overlay(alignment: .bottom) {
                        if pageCount > 1 {
                            HStack(spacing: 20) {
                                Button("上一页", systemImage: "chevron.left") { page -= 1 }
                                    .disabled(page == 0)
                                Text("\(min(page + 1, pageCount)) / \(pageCount)").monospacedDigit()
                                Button("下一页", systemImage: "chevron.right") { page += 1 }
                                    .disabled(page + 1 >= pageCount)
                            }
                            .labelStyle(.iconOnly).font(.caption)
                            .padding(10).background(.regularMaterial, in: Capsule()).padding(.bottom, 12)
                        }
                    }
                    .onAppear {
                        page = (items.firstIndex { $0.id == initialID } ?? 0) / capacity
                    }
            }
            .background(JourneyPalette.canvas(for: colorScheme))
            .navigationTitle(items.first?.logicalDay ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark", action: closeMap).labelStyle(.iconOnly)
                        .accessibilityIdentifier("lifeIllustration.map.close")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(items.first?.logicalDay ?? "")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MoMoPalette.ink)
                        if let span = dayTimeSpan {
                            Text(span)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(MoMoPalette.muted)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("lifeIllustration.map")
        #if os(iOS)
        .fullScreenCover(item: $detail) { item in
            LifeIllustrationViewer(store: store, initialID: item.id) { source in
                detail = nil
                closeMap()
                showSource(source)
            }
        }
        #else
        .sheet(item: $detail) { item in
            if let url = store.imageURL(for: item, thumbnail: false) {
                ScrollView {
                    VStack(spacing: 20) {
                        LifeIllustrationMetadata(illustration: item, position: (items.firstIndex { $0.id == item.id } ?? 0) + 1, count: items.count)
                        LifeIllustrationZoomView(url: url).frame(width: 480, height: 480)
                            .modifier(LifeIllustrationPlate())
                        LifeIllustrationDetailView(illustration: item, previous: previous(item)) { detail = nil; showSource(item); closeMap() }
                    }.padding(24)
                }
                .frame(minWidth: 560, minHeight: 680)
                .toolbar {
                    Button("关闭", systemImage: "xmark") { detail = nil }
                    Button("上一幅", systemImage: "chevron.left") { moveDetail(-1) }
                        .disabled(item.id == items.first?.id)
                    Button("下一幅", systemImage: "chevron.right") { moveDetail(1) }
                        .disabled(item.id == items.last?.id)
                    ShareLink(item: url)
                    Button("删除", systemImage: "trash", role: .destructive) { delete(item) }
                }
            }
        }
        #endif
        .onChange(of: items.map(\.id)) { _, ids in
            if ids.isEmpty { closeMap() }
            if let detail, !ids.contains(detail.id) { self.detail = nil }
        }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func closeMap() {
        if let close { close() } else { dismiss() }
    }

    #if os(macOS)
    private func moveDetail(_ offset: Int) {
        guard let detail, let index = items.firstIndex(where: { $0.id == detail.id }), items.indices.contains(index + offset) else { return }
        self.detail = items[index + offset]
    }
    #endif

    private func previous(_ item: LifeIllustration) -> LifeIllustration? {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index > 0 else { return nil }
        return items[index - 1]
    }

    private func mapContent(visible: [LifeIllustration], size: CGSize) -> some View {
        let geographic = items.contains { $0.coordinate != nil }
        let legs = IllustrationJourneyLeg.make(items: items)
        let pins = geographic ? projection.pins : Dictionary(uniqueKeysWithValues: visible.enumerated().map { index, item in
            (item.id, CGPoint(x: index.isMultiple(of: 2) ? size.width * 0.20 : size.width * 0.82,
                y: 44 + CGFloat(index) * max(150, (size.height - 200) / CGFloat(max(1, visible.count - 1)))))
        })
        let cards = JourneyCallout.layout(items: visible, allItems: items, pins: pins, size: size)
        return ZStack {
            if geographic {
                LifeIllustrationMapSurface(items: items, legs: legs) { value in
                    if projection != value { projection = value }
                }
                .saturation(colorScheme == .dark ? 1.55 : 1.32)
                .contrast(colorScheme == .dark ? 1.07 : 1.03)
                .brightness(colorScheme == .dark ? 0.08 : 0.01)
                .overlay {
                    if colorScheme == .dark {
                        Color(red: 0.09, green: 0.14, blue: 0.22)
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                    } else {
                        Color(red: 1.0, green: 0.96, blue: 0.88)
                            .opacity(0.10)
                            .blendMode(.softLight)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                JourneyPalette.canvas(for: colorScheme)
            }
            JourneyInkLayer(cards: cards, pins: pins, projection: projection, legs: legs, geographic: geographic)
                .allowsHitTesting(false).accessibilityHidden(true)
            ForEach(cards) { card in
                storyCard(card)
                    .frame(width: card.frame.width, height: card.frame.height)
                    .position(x: card.frame.midX, y: card.frame.midY)
            }
        }
        .clipped()
        .overlay(alignment: .topTrailing) {
            if geographic && !projection.mapLoaded && !projection.mapFailed {
                ProgressView("载入地图").labelStyle(.iconOnly)
                    .padding(12).background(.regularMaterial, in: Circle()).padding(12)
                    .accessibilityIdentifier("lifeIllustration.map.loading")
            }
        }
    }

    private func storyCard(_ card: JourneyCallout) -> some View {
        let accent = JourneyPalette.stopAccent(number: card.number, scheme: colorScheme)
        let selected = card.item.id == initialID
        return Button { detail = card.item } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                    Text(card.item.stayCaption)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(JourneyPalette.cardMuted(for: colorScheme))
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let place = card.item.place, !place.isEmpty {
                            Text(place)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(JourneyPalette.cardInk(for: colorScheme))
                                .lineLimit(1)
                        }
                        Text(card.item.summary ?? card.item.caption)
                            .font(.system(size: 12))
                            .foregroundStyle(JourneyPalette.cardBody(for: colorScheme))
                            .lineSpacing(2)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = store.imageURL(for: card.item) {
                        LifeIllustrationImageView(url: url)
                            .frame(width: 58, height: 58)
                            .rotationEffect(.degrees(card.item.stickerAngle))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(JourneyPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accent.opacity(selected ? 0.62 : 0.28), lineWidth: selected ? 1.4 : 1.0)
            }
            .shadow(color: JourneyPalette.cardShadow(for: colorScheme), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lifeIllustration.map.card.\(card.id)")
        .contextMenu {
            Button("查看转录", systemImage: "text.alignleft") { closeMap(); showSource(card.item) }
            Button("删除", systemImage: "trash", role: .destructive) { delete(card.item) }
        }
    }

    private func delete(_ item: LifeIllustration) {
        Task {
            do { try await store.delete(item) }
            catch { failure = error.localizedDescription }
        }
    }
}

private enum JourneyPalette {
    static func canvas(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.16, blue: 0.22)
            : Color(red: 0.968, green: 0.960, blue: 0.936)
    }

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.165, green: 0.195, blue: 0.255).opacity(0.96)
            : Color(red: 0.994, green: 0.989, blue: 0.975).opacity(0.97)
    }

    static func cardInk(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.97, green: 0.96, blue: 0.94)
            : Color(red: 0.13, green: 0.14, blue: 0.16)
    }

    static func cardBody(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.86, green: 0.88, blue: 0.92)
            : Color(red: 0.24, green: 0.25, blue: 0.28)
    }

    static func cardMuted(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.68, green: 0.74, blue: 0.83)
            : Color(red: 0.45, green: 0.47, blue: 0.50)
    }

    static func cardShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.03, green: 0.05, blue: 0.10).opacity(0.38)
            : Color(red: 0.16, green: 0.14, blue: 0.10).opacity(0.10)
    }

    static func routeCasing(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.97, green: 0.95, blue: 0.91).opacity(0.86)
            : Color(red: 0.995, green: 0.990, blue: 0.975).opacity(0.95)
    }

    static func routeRibbon(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.99, green: 0.50, blue: 0.36)
            : Color(red: 0.89, green: 0.36, blue: 0.25)
    }

    static func stopAccent(number: Int, scheme: ColorScheme) -> Color {
        let light: [Color] = [
            Color(red: 0.89, green: 0.36, blue: 0.25), // Warm Coral Vermilion
            Color(red: 0.19, green: 0.57, blue: 0.48), // River Sage Emerald
            Color(red: 0.28, green: 0.44, blue: 0.72), // Storybook Cobalt
            Color(red: 0.82, green: 0.53, blue: 0.18), // Sunlit Ochre
        ]
        let dark: [Color] = [
            Color(red: 0.99, green: 0.52, blue: 0.38),
            Color(red: 0.32, green: 0.78, blue: 0.66),
            Color(red: 0.48, green: 0.65, blue: 0.95),
            Color(red: 0.95, green: 0.68, blue: 0.32),
        ]
        let palette = scheme == .dark ? dark : light
        return palette[max(0, number - 1) % palette.count]
    }
}

private struct JourneyInkLayer: View {
    let cards: [JourneyCallout]
    let pins: [String: CGPoint]
    let projection: JourneyProjection
    let legs: [IllustrationJourneyLeg]
    let geographic: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let casing = JourneyPalette.routeCasing(for: colorScheme)
            let ribbon = JourneyPalette.routeRibbon(for: colorScheme)
            let cream = Color(red: 0.995, green: 0.990, blue: 0.976)

            // 1. Curved organic route ribbons with warm casing and directional chevrons
            let routeEntries: [(points: [CGPoint], seed: Int)] = geographic
                ? legs.enumerated().compactMap { index, leg in projection.routes[leg.id].map { ($0, index) } }
                : [(cards.map(\.pin), 0)]

            for (points, seed) in routeEntries where points.count >= 2 {
                let path = journeyCurve(points, seed: seed)
                context.stroke(path, with: .color(casing), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(ribbon), style: StrokeStyle(lineWidth: 4.8, lineCap: .round, lineJoin: .round))
                if let sample = journeyRouteSample(points, seed: seed, fraction: 0.52) {
                    let mid = sample.point, angle = sample.angle
                    var chevron = Path()
                    chevron.move(to: CGPoint(x: mid.x - 5.5 * cos(angle - 0.62), y: mid.y - 5.5 * sin(angle - 0.62)))
                    chevron.addLine(to: CGPoint(x: mid.x + 1.5 * cos(angle), y: mid.y + 1.5 * sin(angle)))
                    chevron.addLine(to: CGPoint(x: mid.x - 5.5 * cos(angle + 0.62), y: mid.y - 5.5 * sin(angle + 0.62)))
                    context.stroke(chevron, with: .color(cream), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }

            // 2. Compact transit time pills hugging the curved route (with short curved stem only when nudged)
            var badges: [CGRect] = []
            for (legIndex, leg) in legs.enumerated() {
                guard let caption = leg.timeCaption,
                      let points = projection.routes[leg.id], points.count >= 2 else { continue }

                var chosen: (badgeCenter: CGPoint, routeAnchor: CGPoint)?
                outer: for fraction: CGFloat in [0.48, 0.36, 0.64, 0.25, 0.75, 0.18, 0.82] {
                    guard let sample = journeyRouteSample(points, seed: legIndex, fraction: fraction) else { continue }
                    let anchor = sample.point
                    let nx = -sin(sample.angle), ny = cos(sample.angle)
                    for offset: CGFloat in [0, 26, -26, 48, -48, 72, -72, 96, -96] {
                        let candidate = CGPoint(
                            x: min(size.width - 52, max(52, anchor.x + nx * offset)),
                            y: min(size.height - 24, max(16, anchor.y + ny * offset))
                        )
                        let hitRect = CGRect(x: candidate.x - 48, y: candidate.y - 12, width: 96, height: 24)
                        let clearOfCards = !cards.contains { $0.frame.insetBy(dx: -4, dy: -4).intersects(hitRect) }
                        let clearOfBadges = !badges.contains { $0.insetBy(dx: -6, dy: -4).intersects(hitRect) }
                        let clearOfPins = !pins.values.contains { hitRect.insetBy(dx: -12, dy: -10).contains($0) }
                        if clearOfCards && clearOfBadges && clearOfPins {
                            chosen = (candidate, anchor)
                            break outer
                        }
                    }
                }

                if let chosen {
                    let pill = CGRect(x: chosen.badgeCenter.x - 48, y: chosen.badgeCenter.y - 10.5, width: 96, height: 21)
                    badges.append(pill)
                    let dist = hypot(chosen.badgeCenter.x - chosen.routeAnchor.x, chosen.badgeCenter.y - chosen.routeAnchor.y)
                    if dist > 10 {
                        let mid = CGPoint(
                            x: (chosen.routeAnchor.x + chosen.badgeCenter.x) * 0.5 - (chosen.badgeCenter.y - chosen.routeAnchor.y) * 0.22,
                            y: (chosen.routeAnchor.y + chosen.badgeCenter.y) * 0.5 + (chosen.badgeCenter.x - chosen.routeAnchor.x) * 0.22
                        )
                        var stem = Path()
                        stem.move(to: chosen.routeAnchor)
                        stem.addQuadCurve(to: chosen.badgeCenter, control: mid)
                        context.stroke(stem, with: .color(casing), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                        context.stroke(stem, with: .color(ribbon.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                    let pillPath = Path(roundedRect: pill, cornerRadius: 10.5)
                    context.fill(pillPath, with: .color(JourneyPalette.cardFill(for: colorScheme)))
                    context.stroke(pillPath, with: .color(ribbon.opacity(0.38)), lineWidth: 0.9)
                    context.draw(
                        Text(caption)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(JourneyPalette.cardInk(for: colorScheme)),
                        at: chosen.badgeCenter
                    )
                }
            }

            // 3. Silky S-curved card connectors + vibrant colored enamel pebble stop pins
            for card in cards {
                guard let pin = pins[card.id], CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24).contains(pin) else { continue }
                let accent = JourneyPalette.stopAccent(number: card.number, scheme: colorScheme)
                let connector = journeyCardConnector(pin: pin, frame: card.frame, right: card.right)

                context.stroke(connector.path, with: .color(casing.opacity(0.9)), style: StrokeStyle(lineWidth: 4.2, lineCap: .round))
                context.stroke(connector.path, with: .color(accent.opacity(0.88)), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))

                let dotRect = CGRect(x: connector.anchor.x - 3.2, y: connector.anchor.y - 3.2, width: 6.4, height: 6.4)
                context.fill(Path(ellipseIn: dotRect), with: .color(accent))
                context.stroke(Path(ellipseIn: dotRect), with: .color(cream), lineWidth: 1.2)

                let pinRect = CGRect(x: pin.x - 14, y: pin.y - 11.5, width: 28, height: 23)
                let shadowRect = pinRect.offsetBy(dx: 0, dy: 2)
                context.fill(JourneyPebble().path(in: shadowRect), with: .color(.black.opacity(colorScheme == .dark ? 0.34 : 0.15)))

                let pebble = JourneyPebble().path(in: pinRect)
                context.fill(pebble, with: .color(accent))
                context.stroke(pebble, with: .color(cream), lineWidth: 2.0)
                context.draw(
                    Text("\(card.number)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(cream),
                    at: pin
                )
            }
        }
    }
}
