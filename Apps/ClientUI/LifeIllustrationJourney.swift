import MapKit
import MoMoAgentClient
import SwiftUI

extension LifeIllustration {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    func clock(_ timestamp: Double) -> String {
        var format = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        format.timeZone = TimeZone(identifier: timezone) ?? .current
        return Date(timeIntervalSince1970: timestamp).formatted(format)
    }

    var stayCaption: String {
        guard let placeStart, let placeEnd else { return clock(windowStart) + "–" + clock(windowEnd) }
        return clock(placeStart) + "–" + clock(placeEnd)
    }
}

struct IllustrationJourneyStop: Identifiable, Equatable {
    let id: String
    let illustrations: [LifeIllustration]

    var primary: LifeIllustration { illustrations[0] }

    var coordinate: CLLocationCoordinate2D? {
        illustrations.lazy.compactMap(\.coordinate).first
    }

    var place: String? {
        illustrations.lazy
            .compactMap { $0.place?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var startTime: Double {
        illustrations.compactMap(\.placeStart).min() ?? illustrations.map(\.windowStart).min() ?? 0
    }

    var endTime: Double {
        illustrations.compactMap(\.placeEnd).max() ?? illustrations.map(\.windowEnd).max() ?? 0
    }

    var stayCaption: String {
        primary.clock(startTime) + "–" + primary.clock(endTime)
    }

    func contains(id itemID: String) -> Bool {
        illustrations.contains { $0.id == itemID }
    }

    static func group(items: [LifeIllustration]) -> [Self] {
        let sorted = items.sorted { $0.windowStart < $1.windowStart }
        let allWaypoints = sorted.flatMap(\.routePoints).filter { $0.kind == "waypoint" }.sorted { $0.timestamp < $1.timestamp }
        var groups: [[LifeIllustration]] = []

        for item in sorted {
            guard var current = groups.last, let previous = current.last else {
                groups.append([item])
                continue
            }
            if shouldMerge(current: current, previous: previous, next: item, waypoints: allWaypoints) {
                current.append(item)
                groups[groups.count - 1] = current
            } else {
                groups.append([item])
            }
        }
        return groups.map { Self(id: $0[0].id, illustrations: $0) }
    }

    private static func shouldMerge(
        current: [LifeIllustration],
        previous: LifeIllustration,
        next: LifeIllustration,
        waypoints: [LifeIllustrationRoutePoint]
    ) -> Bool {
        if let anchor = current.lazy.compactMap(\.coordinate).first, let candidate = next.coordinate {
            let anchorPoint = MKMapPoint(anchor)
            guard anchorPoint.distance(to: MKMapPoint(candidate)) <= 160 else { return false }
            let gapStart = previous.placeEnd ?? previous.windowEnd
            let gapEnd = next.placeStart ?? next.windowStart
            let wanderedAway = waypoints.contains { point in
                guard point.timestamp >= gapStart, point.timestamp <= gapEnd else { return false }
                let coord = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                return CLLocationCoordinate2DIsValid(coord) && anchorPoint.distance(to: MKMapPoint(coord)) > 400
            }
            return !wanderedAway
        }
        if current.allSatisfy({ $0.coordinate == nil }), next.coordinate == nil {
            let lhs = previous.place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rhs = next.place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !lhs.isEmpty && lhs == rhs
        }
        return false
    }
}

struct IllustrationJourneyLeg: Identifiable {
    let origin: IllustrationJourneyStop
    let destination: IllustrationJourneyStop
    let coordinates: [CLLocationCoordinate2D]
    var id: String { origin.id + "/" + destination.id }
    var timeCaption: String? {
        guard let departure = origin.illustrations.last?.placeEnd,
              let arrival = destination.illustrations.first?.placeStart,
              arrival >= departure else { return nil }
        return origin.primary.clock(departure) + " → " + destination.primary.clock(arrival)
    }

    static func make(items: [LifeIllustration]) -> [Self] {
        make(stops: IllustrationJourneyStop.group(items: items), allItems: items)
    }

    static func make(stops: [IllustrationJourneyStop], allItems: [LifeIllustration]) -> [Self] {
        let located = stops.filter { $0.coordinate != nil }
        let points = allItems.flatMap(\.routePoints).sorted { $0.timestamp < $1.timestamp }
        return zip(located, located.dropFirst()).compactMap { origin, destination in
            guard let from = origin.coordinate, let to = destination.coordinate,
                  MKMapPoint(from).distance(to: MKMapPoint(to)) > 30 else { return nil }
            let start = origin.illustrations.last?.placeEnd ?? origin.endTime
            let end = destination.illustrations.first?.placeStart ?? destination.startTime
            let waypoints = points.filter { $0.kind == "waypoint" && $0.timestamp >= start && $0.timestamp <= end }
            var coordinates = [from]
            for point in waypoints {
                let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                if let last = coordinates.last, MKMapPoint(last).distance(to: MKMapPoint(coordinate)) > 30 {
                    coordinates.append(coordinate)
                }
            }
            coordinates.append(to)
            return Self(origin: origin, destination: destination, coordinates: coordinates)
        }
    }
}

struct JourneyMapCommand: Equatable {
    enum Action: Equatable {
        case zoomIn
        case zoomOut
        case fitAll
    }
    let id: Int
    let action: Action
}

struct JourneyProjection: Equatable {
    var pins: [String: CGPoint] = [:]
    var callouts = JourneyCalloutProjection()
    var mapLoaded = false
    var mapFailed = false
    var cameraCustomized = false
}

struct JourneyCalloutProjection: Equatable {
    private(set) var pins: [String: CGPoint] = [:]
    private(set) var cameraCustomized = false

    mutating func update(pins: [String: CGPoint], cameraCustomized: Bool, cameraMoving: Bool) {
        // Re-solving collision avoidance at every camera frame makes cards jump between valid arrangements.
        guard !cameraMoving || self.pins.isEmpty else { return }
        self.pins = pins
        self.cameraCustomized = cameraCustomized
    }
}

struct JourneyCallout: Identifiable {
    let stop: IllustrationJourneyStop
    let number: Int
    let pin: CGPoint
    let frame: CGRect
    let right: Bool
    let compact: Bool
    var id: String { stop.id }
    var item: LifeIllustration { stop.primary }

    static func cardHeight(for stop: IllustrationJourneyStop, compact: Bool = false) -> CGFloat {
        if compact {
            return stop.illustrations.count > 1 ? 66 : 56
        }
        return stop.illustrations.count > 1 ? 124 : 98
    }

    static func selectFittingStops(
        from stops: [IllustrationJourneyStop],
        focusedID: String,
        size: CGSize
    ) -> [IllustrationJourneyStop] {
        guard stops.count > 3 else { return stops }
        let available = max(120, size.height - 34)
        let avgHeight: CGFloat = 62
        let maxCount = max(3, Int((available + 6) / (avgHeight + 6)))
        guard stops.count > maxCount else { return stops }

        var chosenIndices = Set<Int>([0, stops.count - 1])
        if let focusIdx = stops.firstIndex(where: { $0.contains(id: focusedID) }) {
            chosenIndices.insert(focusIdx)
        }
        let slotsNeeded = max(0, maxCount - chosenIndices.count)
        if slotsNeeded > 0 {
            for step in 1...slotsNeeded {
                let idx = Int(round(Double(step) * Double(stops.count - 1) / Double(slotsNeeded + 1)))
                chosenIndices.insert(min(stops.count - 1, max(0, idx)))
            }
        }
        return chosenIndices.sorted().map { stops[$0] }
    }

    static func layout(items: [LifeIllustration], allItems: [LifeIllustration], pins: [String: CGPoint], size: CGSize) -> [Self] {
        let stops = IllustrationJourneyStop.group(items: items)
        let allStops = IllustrationJourneyStop.group(items: allItems)
        return layout(stops: stops, allStops: allStops, pins: pins, size: size)
    }

    static func layout(
        stops: [IllustrationJourneyStop],
        allStops: [IllustrationJourneyStop],
        pins: [String: CGPoint],
        size: CGSize
    ) -> [Self] {
        guard !stops.isEmpty else { return [] }
        let ordered = stops.sorted { (pins[$0.id]?.y ?? 0) < (pins[$1.id]?.y ?? 0) }
        let fullHeights = ordered.map { Self.cardHeight(for: $0, compact: false) }
        let available = max(120, size.height - 34)
        let compact = ordered.count >= 4 || (fullHeights.reduce(0, +) + CGFloat(max(0, ordered.count - 1)) * 12 > available)
        let width = compact ? min(182, size.width * 0.46) : min(202, size.width * 0.51)
        let heights = ordered.map { Self.cardHeight(for: $0, compact: compact) }
        let rawSpacing: CGFloat = compact ? 8 : 12
        let maxFittableSpacing = ordered.count > 1
            ? max(4, floor((available - heights.reduce(0, +)) / CGFloat(ordered.count - 1)))
            : rawSpacing
        let spacing = min(rawSpacing, maxFittableSpacing)

        var positions: [CGFloat] = []
        for (idx, stop) in ordered.enumerated() {
            let h = heights[idx]
            let bottom = max(12, size.height - h - 22)
            var y = min(bottom, max(12, (pins[stop.id]?.y ?? 0) + (compact ? 22 : 30)))
            if idx > 0 {
                y = max(y, positions[idx - 1] + heights[idx - 1] + spacing)
            }
            positions.append(y)
        }
        if let lastIdx = positions.indices.last {
            let lastBottom = max(12, size.height - heights[lastIdx] - 22)
            if positions[lastIdx] > lastBottom {
                positions[lastIdx] = lastBottom
                for index in positions.indices.dropLast().reversed() {
                    positions[index] = max(12, min(positions[index], positions[index + 1] - heights[index] - spacing))
                }
            }
        }

        struct Candidate {
            let y: CGFloat
            let cost: CGFloat
            let previous: Int?
        }
        let pinClearanceX: CGFloat = compact ? -14 : -18
        let pinClearanceY: CGFloat = compact ? -10 : -15
        var rows: [[Candidate]] = []
        for (rowIdx, stop) in ordered.enumerated() {
            let height = heights[rowIdx]
            let bottom = max(12, size.height - height - 22)
            let globalIndex = allStops.firstIndex(where: { $0.id == stop.id }) ?? rowIdx
            let x: CGFloat = globalIndex.isMultiple(of: 2) ? size.width - width - 14 : 14
            let previous = rows.last ?? []
            let prevHeight: CGFloat = rowIdx > 0 ? heights[rowIdx - 1] : 0
            var candidates: [Candidate] = []
            var previousIndex = 0
            var best: Int?
            for y in stride(from: CGFloat(12), through: bottom, by: 4) {
                while previousIndex < previous.count && previous[previousIndex].y + prevHeight + spacing <= y {
                    if best == nil || previous[previousIndex].cost < previous[best!].cost { best = previousIndex }
                    previousIndex += 1
                }
                let frame = CGRect(x: x, y: y, width: width, height: height).insetBy(dx: pinClearanceX, dy: pinClearanceY)
                guard !pins.values.contains(where: { frame.contains($0) }), rows.isEmpty || best != nil else { continue }
                let pinY = pins[stop.id]?.y ?? size.height / 2
                let distance = abs(y + height / 2 - pinY)
                candidates.append(Candidate(y: y, cost: distance + (best.map { previous[$0].cost } ?? 0), previous: best))
            }
            rows.append(candidates)
        }
        if let last = rows.last, var cursor = last.indices.min(by: { last[$0].cost < last[$1].cost }) {
            for index in rows.indices.reversed() {
                positions[index] = rows[index][cursor].y
                if let previous = rows[index][cursor].previous { cursor = previous }
            }
        }
        return ordered.enumerated().map { rowIdx, stop in
            let height = heights[rowIdx]
            let globalIndex = allStops.firstIndex(where: { $0.id == stop.id }) ?? rowIdx
            let right = globalIndex.isMultiple(of: 2)
            return Self(
                stop: stop,
                number: globalIndex + 1,
                pin: pins[stop.id] ?? .zero,
                frame: CGRect(x: right ? size.width - width - 14 : 14, y: max(12, positions[rowIdx]), width: width, height: height),
                right: right,
                compact: compact
            )
        }
    }
}

struct JourneyPebble: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY))
            path.addCurve(to: CGPoint(x: rect.maxX - 2, y: rect.midY - 2.5),
                control1: CGPoint(x: rect.minX + 3, y: rect.minY - 3.5),
                control2: CGPoint(x: rect.maxX - 2, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY),
                control1: CGPoint(x: rect.maxX + 2.5, y: rect.maxY + 3.5),
                control2: CGPoint(x: rect.minX - 5, y: rect.maxY + 1))
            path.closeSubpath()
        }
    }
}

func journeySmoothedPoints(_ raw: [CGPoint], seed: Int = 0) -> [CGPoint] {
    var deduped: [CGPoint] = []
    for point in raw {
        if let last = deduped.last, hypot(point.x - last.x, point.y - last.y) < 4.0 { continue }
        deduped.append(point)
    }
    guard deduped.count >= 2 else { return deduped }

    var waved: [CGPoint] = [deduped[0]]
    for index in 1..<deduped.count {
        let start = deduped[index - 1], end = deduped[index]
        let dx = end.x - start.x, dy = end.y - start.y
        let dist = hypot(dx, dy)
        if dist > 64 {
            let nx = -dy / dist, ny = dx / dist
            let sign: CGFloat = (seed + index).isMultiple(of: 2) ? 1 : -1
            let amp = min(18, max(7, dist * 0.09)) * sign
            waved.append(CGPoint(x: start.x + dx * 0.34 + nx * amp, y: start.y + dy * 0.34 + ny * amp))
            waved.append(CGPoint(x: start.x + dx * 0.68 - nx * amp * 0.55, y: start.y + dy * 0.68 - ny * amp * 0.55))
        }
        waved.append(end)
    }

    let passes = waved.count <= 8 ? 2 : 1
    var smoothed = waved
    for _ in 0..<passes {
        guard smoothed.count >= 3 else { break }
        var next = [smoothed[0]]
        for index in 0..<(smoothed.count - 1) {
            let a = smoothed[index], b = smoothed[index + 1]
            if index > 0 {
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
            }
            if index + 1 < smoothed.count - 1 {
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
        }
        next.append(smoothed[smoothed.count - 1])
        smoothed = next
    }
    return smoothed
}

func journeyCurve(_ raw: [CGPoint], seed: Int = 0) -> Path {
    let points = journeySmoothedPoints(raw, seed: seed)
    return Path { path in
        guard let first = points.first else { return }
        path.move(to: first)
        for index in 1..<points.count {
            let before = points[max(0, index - 2)]
            let start = points[index - 1]
            let end = points[index]
            let after = points[min(points.count - 1, index + 1)]
            let tension: CGFloat = 0.21
            path.addCurve(to: end,
                control1: CGPoint(x: start.x + (end.x - before.x) * tension, y: start.y + (end.y - before.y) * tension),
                control2: CGPoint(x: end.x - (after.x - start.x) * tension, y: end.y - (after.y - start.y) * tension))
        }
    }
}

func journeyRouteSample(_ raw: [CGPoint], seed: Int = 0, fraction: CGFloat) -> (point: CGPoint, angle: CGFloat)? {
    let points = journeySmoothedPoints(raw, seed: seed)
    guard points.count >= 2 else { return nil }
    var lengths: [CGFloat] = [0]
    var total: CGFloat = 0
    for index in 1..<points.count {
        total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        lengths.append(total)
    }
    guard total > 1 else { return nil }
    let target = min(max(0.05, fraction), 0.95) * total
    for index in 1..<points.count where lengths[index] >= target {
        let segStart = lengths[index - 1]
        let segLen = max(0.001, lengths[index] - segStart)
        let t = (target - segStart) / segLen
        let a = points[index - 1], b = points[index]
        let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        return (point, atan2(b.y - a.y, b.x - a.x))
    }
    let a = points[points.count - 2], b = points[points.count - 1]
    return (b, atan2(b.y - a.y, b.x - a.x))
}

func journeyCardConnector(pin: CGPoint, frame: CGRect, right: Bool) -> (path: Path, anchor: CGPoint) {
    let sideX = right ? frame.minX : frame.maxX
    let clampedX = min(max(pin.x + (right ? 18 : -18), frame.minX + 28), frame.maxX - 28)
    let clampedY = min(max(pin.y + (pin.y < frame.midY ? -10 : 10), frame.minY + 24), frame.maxY - 24)
    let verticalGap = pin.y < frame.minY - 6 ? frame.minY - pin.y : (pin.y > frame.maxY + 6 ? pin.y - frame.maxY : 0)
    let horizontalGap = right ? (frame.minX - pin.x) : (pin.x - frame.maxX)

    let anchor: CGPoint
    let control1: CGPoint
    let control2: CGPoint

    if horizontalGap >= 16 {
        anchor = CGPoint(x: sideX, y: clampedY)
        let spanX = anchor.x - pin.x
        let spanY = anchor.y - pin.y
        let bowY: CGFloat = abs(spanY) < 16 ? (pin.y < frame.midY ? -18 : 18) : 0
        control1 = CGPoint(x: pin.x + spanX * 0.36, y: pin.y + spanY * 0.12 + bowY)
        control2 = CGPoint(x: anchor.x - spanX * 0.44, y: anchor.y - spanY * 0.04 + bowY * 0.35)
    } else if verticalGap > 0 {
        let topEdge = pin.y < frame.midY
        anchor = CGPoint(x: clampedX, y: topEdge ? frame.minY : frame.maxY)
        let spanY = anchor.y - pin.y
        let bowX: CGFloat = right ? -24 : 24
        control1 = CGPoint(x: pin.x + bowX, y: pin.y + spanY * 0.38)
        control2 = CGPoint(x: anchor.x + bowX * 0.45, y: anchor.y - spanY * 0.46)
    } else {
        anchor = CGPoint(x: sideX, y: clampedY)
        let outward: CGFloat = right ? -26 : 26
        control1 = CGPoint(x: pin.x + outward, y: (pin.y + anchor.y) * 0.5)
        control2 = CGPoint(x: anchor.x + outward * 0.85, y: anchor.y)
    }

    let path = Path { p in
        p.move(to: pin)
        p.addCurve(to: anchor, control1: control1, control2: control2)
    }
    return (path, anchor)
}

/// Computes world-space (`MKMapPoint`) trajectory vertices once per route update so panning and
/// zooming translate/scale the exact same Earth-anchored curve 1:1 with MapKit's vector tiles.
func journeyWorldCurvePoints(
    _ coordinates: [CLLocationCoordinate2D],
    isRoadFitted: Bool,
    seed: Int = 0
) -> [MKMapPoint] {
    var deduped: [MKMapPoint] = []
    deduped.reserveCapacity(coordinates.count)
    for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
        let point = MKMapPoint(coordinate)
        if let last = deduped.last, hypot(point.x - last.x, point.y - last.y) < 2.0 { continue }
        deduped.append(point)
    }
    guard deduped.count >= 2 else { return deduped }

    if isRoadFitted {
        // Real MKDirections street polylines already trace roads; apply one light corner-smoothing pass
        // without injecting synthetic lateral waves that would drift off streets when zooming.
        guard deduped.count >= 3 else { return deduped }
        var smoothed: [MKMapPoint] = [deduped[0]]
        smoothed.reserveCapacity(deduped.count * 2)
        for index in 0..<(deduped.count - 1) {
            let a = deduped[index], b = deduped[index + 1]
            if index > 0 {
                smoothed.append(MKMapPoint(x: a.x * 0.85 + b.x * 0.15, y: a.y * 0.85 + b.y * 0.15))
            }
            if index + 1 < deduped.count - 1 {
                smoothed.append(MKMapPoint(x: a.x * 0.15 + b.x * 0.85, y: a.y * 0.15 + b.y * 0.85))
            }
        }
        smoothed.append(deduped[deduped.count - 1])
        return smoothed
    }

    var waved: [MKMapPoint] = [deduped[0]]
    for index in 1..<deduped.count {
        let start = deduped[index - 1], end = deduped[index]
        let dx = end.x - start.x, dy = end.y - start.y
        let dist = hypot(dx, dy)
        if dist > 120 {
            let nx = -dy / dist, ny = dx / dist
            let sign: Double = (seed + index).isMultiple(of: 2) ? 1 : -1
            let amp = dist * 0.085 * sign
            waved.append(MKMapPoint(x: start.x + dx * 0.34 + nx * amp, y: start.y + dy * 0.34 + ny * amp))
            waved.append(MKMapPoint(x: start.x + dx * 0.68 - nx * amp * 0.55, y: start.y + dy * 0.68 - ny * amp * 0.55))
        }
        waved.append(end)
    }

    var control = waved
    for _ in 0..<(waved.count <= 8 ? 2 : 1) {
        guard control.count >= 3 else { break }
        var next = [control[0]]
        for index in 0..<(control.count - 1) {
            let a = control[index], b = control[index + 1]
            if index > 0 {
                next.append(MKMapPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
            }
            if index + 1 < control.count - 1 {
                next.append(MKMapPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
        }
        next.append(control[control.count - 1])
        control = next
    }

    // Sample Catmull-Rom cubic segments into dense world-space vertices for crisp MKOverlayRenderer strokes.
    var dense: [MKMapPoint] = [control[0]]
    let tension = 0.21
    let subdivisions = 8
    for index in 1..<control.count {
        let before = control[max(0, index - 2)]
        let start = control[index - 1]
        let end = control[index]
        let after = control[min(control.count - 1, index + 1)]
        let c1 = MKMapPoint(x: start.x + (end.x - before.x) * tension, y: start.y + (end.y - before.y) * tension)
        let c2 = MKMapPoint(x: end.x - (after.x - start.x) * tension, y: end.y - (after.y - start.y) * tension)
        for step in 1...subdivisions {
            let t = Double(step) / Double(subdivisions)
            let u = 1.0 - t
            let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
            let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
            dense.append(MKMapPoint(x: x, y: y))
        }
    }
    return dense
}

func journeyWorldRouteSample(_ points: [MKMapPoint], fraction: Double) -> (point: MKMapPoint, angle: Double)? {
    guard points.count >= 2 else { return nil }
    var lengths: [Double] = [0]
    lengths.reserveCapacity(points.count)
    var total = 0.0
    for index in 1..<points.count {
        total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        lengths.append(total)
    }
    guard total > 1 else { return nil }
    let target = min(max(0.05, fraction), 0.95) * total
    for index in 1..<points.count where lengths[index] >= target {
        let segStart = lengths[index - 1]
        let segLen = max(0.001, lengths[index] - segStart)
        let t = (target - segStart) / segLen
        let a = points[index - 1], b = points[index]
        let point = MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        return (point, atan2(b.y - a.y, b.x - a.x))
    }
    let a = points[points.count - 2], b = points[points.count - 1]
    return (b, atan2(b.y - a.y, b.x - a.x))
}
