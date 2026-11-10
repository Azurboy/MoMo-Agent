import CoreLocation
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
    @State private var resolvedPlaces: [String: String] = [:]
    @State private var mapCommand: JourneyMapCommand?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var items: [LifeIllustration] {
        let day = store.items.first { $0.id == initialID }?.logicalDay
        return store.items.filter { $0.logicalDay == day }.sorted { $0.windowStart < $1.windowStart }
    }

    private var stops: [IllustrationJourneyStop] {
        IllustrationJourneyStop.group(items: items)
    }

    private var dayTimeSpan: String? {
        guard let first = stops.first, let last = stops.last else { return nil }
        return "\(first.primary.clock(first.startTime))–\(last.primary.clock(last.endTime))"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                mapContent(size: geometry.size)
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
        .task(id: stops.map { "\($0.id):\($0.place ?? "")" }.joined(separator: "|")) {
            await resolveMissingPlaceNames()
        }
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

    private func displayPlace(for stop: IllustrationJourneyStop) -> String? {
        if let place = stop.place, !place.isEmpty { return place }
        if let resolved = resolvedPlaces[stop.id], !resolved.isEmpty { return resolved }
        if let pointTitle = stop.illustrations.flatMap(\.routePoints)
            .compactMap({ $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return pointTitle
        }
        return nil
    }

    private func resolveMissingPlaceNames() async {
        let geocoder = CLGeocoder()
        for stop in stops {
            if Task.isCancelled { return }
            guard stop.place == nil, resolvedPlaces[stop.id] == nil, let coord = stop.coordinate else { continue }
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(
                    CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                )
                guard !Task.isCancelled, let placemark = placemarks.first,
                      let title = JourneyPlaceFormatter.format(placemark) else { continue }
                resolvedPlaces[stop.id] = title
            } catch {
                continue
            }
        }
    }

    private func sendMapCommand(_ action: JourneyMapCommand.Action) {
        mapCommand = JourneyMapCommand(id: (mapCommand?.id ?? 0) + 1, action: action)
    }

    private func visibleStops(in size: CGSize, callouts: JourneyCalloutProjection) -> [IllustrationJourneyStop] {
        let pins = callouts.pins
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24)
        let candidates: [IllustrationJourneyStop]
        if callouts.cameraCustomized, !pins.isEmpty {
            candidates = stops.filter { stop in
                guard let pin = pins[stop.id] else { return false }
                return viewport.contains(pin)
            }
        } else {
            candidates = stops
        }
        return JourneyCallout.selectFittingStops(from: candidates, focusedID: initialID, size: size)
    }

    @ViewBuilder
    private func mapContent(size: CGSize) -> some View {
        let geographic = stops.contains { $0.coordinate != nil }
        if !geographic {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        Button { detail = item } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.clock(item.windowStart) + "–" + item.clock(item.windowEnd))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(JourneyPalette.cardMuted(for: colorScheme))
                                    Text(item.summary ?? item.caption)
                                        .font(.system(size: 13))
                                        .foregroundStyle(JourneyPalette.cardInk(for: colorScheme))
                                        .lineSpacing(3)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let url = store.imageURL(for: item) {
                                    LifeIllustrationImageView(url: url)
                                        .frame(width: 68, height: 68)
                                        .rotationEffect(.degrees(item.stickerAngle))
                                }
                            }
                            .padding(14)
                            .modifier(JourneyCardSurface(selected: item.id == initialID))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("lifeIllustration.map.card.\(item.id)")
                    }
                }
                .padding(20)
            }
            .background(JourneyPalette.canvas(for: colorScheme))
        } else {
            let legs = IllustrationJourneyLeg.make(stops: stops, allItems: items)
            let visible = visibleStops(in: size, callouts: projection.callouts)
            let cards = JourneyCallout.layout(stops: visible, allStops: stops, pins: projection.callouts.pins, size: size)
            let placeTitles = Dictionary(uniqueKeysWithValues: stops.compactMap { stop -> (String, String)? in
                guard let place = displayPlace(for: stop), !place.isEmpty else { return nil }
                return (stop.id, place)
            })
            ZStack {
                LifeIllustrationMapSurface(
                    stops: stops,
                    legs: legs,
                    cards: cards,
                    placeTitles: placeTitles,
                    isDark: colorScheme == .dark,
                    command: mapCommand,
                    onSelectStop: { stop in
                        detail = stop.illustrations.first { $0.id == initialID } ?? stop.primary
                    }
                ) { value in
                    if projection != value {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { projection = value }
                    }
                }
                .accessibilityIdentifier("lifeIllustration.map.surface")
                .brightness(colorScheme == .dark ? 0.03 : 0)
                ForEach(cards) { card in
                    storyCard(card)
                        .frame(width: card.frame.width, height: card.frame.height)
                        .position(x: card.frame.midX, y: card.frame.midY)
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if !projection.mapLoaded && !projection.mapFailed {
                    ProgressView("载入地图").labelStyle(.iconOnly)
                        .padding(12).background(.regularMaterial, in: Circle()).padding(12)
                        .accessibilityIdentifier("lifeIllustration.map.loading")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                mapZoomControls
                    .padding(.trailing, 14)
                    .padding(.bottom, 16)
            }
        }
    }

    private var mapZoomControls: some View {
        VStack(spacing: 0) {
            Button {
                sendMapCommand(.zoomIn)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JourneyPalette.cardInk(for: colorScheme))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("放大地图")
            .accessibilityIdentifier("lifeIllustration.map.zoomIn")

            Rectangle()
                .fill(JourneyPalette.cardBorder(for: colorScheme, selected: false))
                .frame(width: 22, height: 0.7)

            Button {
                sendMapCommand(.zoomOut)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JourneyPalette.cardInk(for: colorScheme))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("缩小地图")
            .accessibilityIdentifier("lifeIllustration.map.zoomOut")

            if projection.cameraCustomized {
                Rectangle()
                    .fill(JourneyPalette.cardBorder(for: colorScheme, selected: false))
                    .frame(width: 22, height: 0.7)

                Button {
                    sendMapCommand(.fitAll)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(JourneyPalette.cardInk(for: colorScheme))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("适应全天行程")
                .accessibilityIdentifier("lifeIllustration.map.fitAll")
            }
        }
        .background(JourneyPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(JourneyPalette.cardBorder(for: colorScheme, selected: false), lineWidth: 0.8)
        }
        .shadow(color: JourneyPalette.cardShadow(for: colorScheme), radius: 8, y: 2)
    }

    @ViewBuilder
    private func storyCard(_ card: JourneyCallout) -> some View {
        let stop = card.stop
        let focused = stop.illustrations.first { $0.id == initialID } ?? stop.primary
        let isFocusedStop = stop.contains(id: initialID)
        let placeTitle = displayPlace(for: stop)

        if card.compact {
            compactStoryCard(card: card, stop: stop, focused: focused, isFocusedStop: isFocusedStop, placeTitle: placeTitle)
        } else if stop.illustrations.count == 1 {
            Button { detail = focused } label: {
                VStack(alignment: .leading, spacing: 5) {
                    cardHeader(place: placeTitle, stay: stop.stayCaption, count: 1)
                    HStack(spacing: 8) {
                        Text(focused.summary ?? focused.caption)
                            .font(.system(size: 11))
                            .foregroundStyle(JourneyPalette.cardBody(for: colorScheme))
                            .lineSpacing(1.8)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let url = store.imageURL(for: focused) {
                            LifeIllustrationImageView(url: url)
                                .frame(width: 50, height: 50)
                                .rotationEffect(.degrees(focused.stickerAngle))
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(JourneyCardSurface(selected: isFocusedStop))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lifeIllustration.map.card.\(card.id)")
            .contextMenu {
                Button("查看转录", systemImage: "text.alignleft") { closeMap(); showSource(focused) }
                Button("删除", systemImage: "trash", role: .destructive) { delete(focused) }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Button { detail = focused } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        cardHeader(place: placeTitle, stay: stop.stayCaption, count: stop.illustrations.count)
                        Text(focused.summary ?? focused.caption)
                            .font(.system(size: 10.5))
                            .foregroundStyle(JourneyPalette.cardBody(for: colorScheme))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                multiStickerRow(stop: stop, iconSize: 42)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(JourneyCardSurface(selected: isFocusedStop))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lifeIllustration.map.card.\(card.id)")
        }
    }

    @ViewBuilder
    private func compactStoryCard(
        card: JourneyCallout,
        stop: IllustrationJourneyStop,
        focused: LifeIllustration,
        isFocusedStop: Bool,
        placeTitle: String?
    ) -> some View {
        if stop.illustrations.count == 1 {
            Button { detail = focused } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((placeTitle?.isEmpty == false ? placeTitle! : focused.stampExcerpt))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(JourneyPalette.cardInk(for: colorScheme))
                            .lineLimit(1)
                        Text(stop.stayCaption)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(JourneyPalette.cardMuted(for: colorScheme))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = store.imageURL(for: focused) {
                        LifeIllustrationImageView(url: url)
                            .frame(width: 38, height: 38)
                            .rotationEffect(.degrees(focused.stickerAngle))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .modifier(JourneyCardSurface(selected: isFocusedStop))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lifeIllustration.map.card.\(card.id)")
            .contextMenu {
                Button("查看转录", systemImage: "text.alignleft") { closeMap(); showSource(focused) }
                Button("删除", systemImage: "trash", role: .destructive) { delete(focused) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { detail = focused } label: {
                    cardHeader(place: placeTitle ?? focused.stampExcerpt, stay: stop.stayCaption, count: stop.illustrations.count)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                multiStickerRow(stop: stop, iconSize: 30)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(JourneyCardSurface(selected: isFocusedStop))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lifeIllustration.map.card.\(card.id)")
        }
    }

    @ViewBuilder
    private func multiStickerRow(stop: IllustrationJourneyStop, iconSize: CGFloat) -> some View {
        let content = HStack(spacing: 6) {
            ForEach(stop.illustrations) { item in
                Button { detail = item } label: {
                    if let url = store.imageURL(for: item) {
                        LifeIllustrationImageView(url: url)
                            .frame(width: iconSize, height: iconSize)
                            .rotationEffect(.degrees(item.stickerAngle))
                            .padding(3)
                            .background(
                                JourneyPalette.thumbnailChip(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(JourneyPalette.cardBorder(for: colorScheme, selected: item.id == initialID), lineWidth: 0.7)
                            }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.stampExcerpt)
                .accessibilityIdentifier("lifeIllustration.map.sticker.\(item.id)")
                .contextMenu {
                    Button("查看转录", systemImage: "text.alignleft") { closeMap(); showSource(item) }
                    Button("删除", systemImage: "trash", role: .destructive) { delete(item) }
                }
            }
        }
        if stop.illustrations.count > 3 {
            ScrollView(.horizontal, showsIndicators: false) { content }
        } else {
            content
        }
    }

    private func cardHeader(place: String?, stay: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let place, !place.isEmpty {
                Text(place)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JourneyPalette.cardInk(for: colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(count > 1 ? "\(stay) · \(count)" : stay)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(JourneyPalette.cardMuted(for: colorScheme))
                .fixedSize()
        }
    }

    private func delete(_ item: LifeIllustration) {
        Task {
            do { try await store.delete(item) }
            catch { failure = error.localizedDescription }
        }
    }
}

enum JourneyPlaceFormatter {
    static func format(_ placemark: CLPlacemark) -> String? {
        let aoi = placemark.areasOfInterest?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subLocality = placemark.subLocality?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locality = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines)
        let admin = placemark.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let aoi, !aoi.isEmpty {
            if let subLocality, !subLocality.isEmpty, !aoi.contains(subLocality) {
                return "\(subLocality) · \(aoi)"
            }
            return aoi
        }

        if var rawName = placemark.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty {
            for prefix in [admin, locality].compactMap({ $0 }) where !prefix.isEmpty && rawName.count > prefix.count {
                if rawName.hasPrefix(prefix) { rawName.removeFirst(prefix.count) }
            }
            rawName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawName.isEmpty {
                if let subLocality, !subLocality.isEmpty, !rawName.contains(subLocality) {
                    return "\(subLocality) · \(rawName)"
                }
                return rawName
            }
        }

        let fallback = [subLocality, placemark.thoroughfare].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return fallback.isEmpty ? locality : fallback
    }
}

private struct JourneyCardSurface: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(JourneyPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(JourneyPalette.cardBorder(for: colorScheme, selected: selected), lineWidth: selected ? 1.2 : 0.8)
            }
            .shadow(color: JourneyPalette.cardShadow(for: colorScheme), radius: 10, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private enum JourneyPalette {
    static func canvas(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.114, green: 0.110, blue: 0.104)
            : Color(red: 0.969, green: 0.961, blue: 0.941)
    }

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.148, green: 0.143, blue: 0.136).opacity(0.95)
            : Color(red: 0.992, green: 0.988, blue: 0.976).opacity(0.96)
    }

    static func thumbnailChip(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.195, green: 0.188, blue: 0.178)
            : Color(red: 0.968, green: 0.960, blue: 0.942)
    }

    static func cardBorder(for scheme: ColorScheme, selected: Bool) -> Color {
        if scheme == .dark {
            return Color(red: 0.94, green: 0.92, blue: 0.88).opacity(selected ? 0.38 : 0.14)
        }
        return Color(red: 0.14, green: 0.13, blue: 0.11).opacity(selected ? 0.34 : 0.13)
    }

    static func cardInk(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.965, green: 0.953, blue: 0.930)
            : Color(red: 0.105, green: 0.100, blue: 0.094)
    }

    static func cardBody(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.83, green: 0.81, blue: 0.77)
            : Color(red: 0.24, green: 0.23, blue: 0.21)
    }

    static func cardMuted(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.64, green: 0.61, blue: 0.57)
            : Color(red: 0.45, green: 0.43, blue: 0.39)
    }

    static func cardShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.36)
            : Color(red: 0.12, green: 0.10, blue: 0.08).opacity(0.09)
    }

    static func routeCasing(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.095, green: 0.090, blue: 0.084).opacity(0.92)
            : Color(red: 0.992, green: 0.988, blue: 0.976).opacity(0.94)
    }

    static func routeRibbon(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.925, green: 0.902, blue: 0.855)
            : Color(red: 0.175, green: 0.162, blue: 0.146)
    }

    static func connectorStem(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.88, green: 0.85, blue: 0.80).opacity(0.62)
            : Color(red: 0.22, green: 0.20, blue: 0.18).opacity(0.60)
    }

    static func pinFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.935, green: 0.914, blue: 0.872)
            : Color(red: 0.145, green: 0.136, blue: 0.125)
    }

    static func pinRim(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.13, green: 0.12, blue: 0.11)
            : Color(red: 0.992, green: 0.988, blue: 0.976)
    }

    static func pinText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.11, blue: 0.10)
            : Color(red: 0.985, green: 0.978, blue: 0.960)
    }
}
