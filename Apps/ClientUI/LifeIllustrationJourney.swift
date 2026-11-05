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
        guard let placeStart, let placeEnd else { return caption }
        return clock(placeStart) + "–" + clock(placeEnd)
    }
}

struct IllustrationJourneyLeg: Identifiable {
    let origin: LifeIllustration
    let destination: LifeIllustration
    let coordinates: [CLLocationCoordinate2D]
    var id: String { origin.id + "/" + destination.id }
    var timeCaption: String? {
        guard let departure = origin.placeEnd, let arrival = destination.placeStart, arrival >= departure else { return nil }
        return origin.clock(departure) + " → " + destination.clock(arrival)
    }

    static func make(items: [LifeIllustration]) -> [Self] {
        let stops = items.filter { $0.coordinate != nil }
        let points = items.flatMap(\.routePoints).sorted { $0.timestamp < $1.timestamp }
        return zip(stops, stops.dropFirst()).compactMap { origin, destination in
            guard let from = origin.coordinate, let to = destination.coordinate,
                  MKMapPoint(from).distance(to: MKMapPoint(to)) > 30 else { return nil }
            let start = origin.placeEnd ?? origin.windowEnd
            let end = destination.placeStart ?? destination.windowStart
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

struct JourneyProjection: Equatable {
    var pins: [String: CGPoint] = [:]
    var routes: [String: [CGPoint]] = [:]
    var fitted: Set<String> = []
    var mapLoaded = false
    var mapFailed = false
}

struct JourneyCallout: Identifiable {
    let item: LifeIllustration
    let number: Int
    let pin: CGPoint
    let frame: CGRect
    let right: Bool
    var id: String { item.id }

    static func layout(items: [LifeIllustration], allItems: [LifeIllustration], pins: [String: CGPoint], size: CGSize) -> [Self] {
        let width = min(220, size.width * 0.55)
        let height: CGFloat = 112
        let bottom = max(12, size.height - height - 22)
        let ordered = items.sorted { (pins[$0.id]?.y ?? 0) < (pins[$1.id]?.y ?? 0) }
        var positions = ordered.map { item in min(bottom, max(12, (pins[item.id]?.y ?? 0) + 38)) }
        for index in positions.indices.dropFirst() {
            positions[index] = max(positions[index], positions[index - 1] + height + 14)
        }
        if let last = positions.last, last > bottom {
            positions[positions.count - 1] = bottom
            for index in positions.indices.dropLast().reversed() {
                positions[index] = min(positions[index], positions[index + 1] - height - 14)
            }
        }
        struct Candidate {
            let y: CGFloat
            let cost: CGFloat
            let previous: Int?
        }
        var rows: [[Candidate]] = []
        for item in ordered {
            let index = allItems.firstIndex(where: { $0.id == item.id }) ?? 0
            let x: CGFloat = index.isMultiple(of: 2) ? size.width - width - 14 : 14
            let previous = rows.last ?? []
            var candidates: [Candidate] = []
            var previousIndex = 0
            var best: Int?
            for y in stride(from: CGFloat(12), through: bottom, by: 4) {
                while previousIndex < previous.count && previous[previousIndex].y + height + 14 <= y {
                    if best == nil || previous[previousIndex].cost < previous[best!].cost { best = previousIndex }
                    previousIndex += 1
                }
                let frame = CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -26, dy: -24)
                guard !pins.values.contains(where: { frame.contains($0) }), rows.isEmpty || best != nil else { continue }
                let pinY = pins[item.id]?.y ?? size.height / 2
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
        return zip(ordered, positions).map { item, y in
            let index = allItems.firstIndex(where: { $0.id == item.id }) ?? 0
            let right = index.isMultiple(of: 2)
            return Self(item: item, number: index + 1, pin: pins[item.id] ?? .zero,
                frame: CGRect(x: right ? size.width - width - 14 : 14, y: max(12, y), width: width, height: height), right: right)
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

    // Subdivide overly long straight chords with a subtle hand-drawn wave so routes never look ruler-straight.
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
        let spanX = anchor.x - pin.x
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
