import MapKit
import MoMoAgentClient
import XCTest
@testable import MoMoAgent

final class LifeIllustrationJourneyLayoutTests: XCTestCase {
    func testCalloutsStayFixedThroughoutZoomAndUpdateOnceCameraSettles() {
        let items = (0..<3).map { item(index: $0) }
        let size = CGSize(width: 402, height: 677)
        let pins = [items[0].id: CGPoint(x: 274, y: 162), items[1].id: CGPoint(x: 238, y: 318),
                    items[2].id: CGPoint(x: 137, y: 369)]
        var snapshot = JourneyCalloutProjection()
        snapshot.update(pins: pins, cameraCustomized: false, cameraMoving: false)
        let baseline = JourneyCallout.layout(items: items, allItems: items, pins: snapshot.pins, size: size)
        var lastPins = pins
        // Zoom in, reverse mid-gesture, and move pins across viewport/avoidance thresholds.
        for frame in 0..<180 {
            let amount = CGFloat(sin(Double(frame) / 12) * 400)
            lastPins = pins.mapValues { CGPoint(x: $0.x + amount, y: $0.y + amount * 0.7) }
            snapshot.update(pins: lastPins, cameraCustomized: true, cameraMoving: true)
            XCTAssertEqual(snapshot.pins, pins)
            XCTAssertFalse(snapshot.cameraCustomized)
            let cards = JourneyCallout.layout(items: items, allItems: items, pins: snapshot.pins, size: size)
            XCTAssertEqual(cards.map(\.id), baseline.map(\.id))
            XCTAssertEqual(cards.map(\.frame), baseline.map(\.frame))
            XCTAssertEqual(cards.map(\.compact), baseline.map(\.compact))
        }
        snapshot.update(pins: lastPins, cameraCustomized: true, cameraMoving: false)
        XCTAssertEqual(snapshot.pins, lastPins)
        XCTAssertTrue(snapshot.cameraCustomized)
    }

    func testFirstProjectionCanSeedDuringMotionAndFitAllCommitsItsVisibilityMode() {
        let initial = ["stop": CGPoint(x: 100, y: 200)]
        var snapshot = JourneyCalloutProjection()
        snapshot.update(pins: initial, cameraCustomized: true, cameraMoving: true)
        XCTAssertEqual(snapshot.pins, initial)
        snapshot.update(pins: ["stop": CGPoint(x: 300, y: 400)], cameraCustomized: false, cameraMoving: true)
        XCTAssertEqual(snapshot.pins, initial)
        XCTAssertTrue(snapshot.cameraCustomized)
        snapshot.update(pins: initial, cameraCustomized: false, cameraMoving: false)
        XCTAssertFalse(snapshot.cameraCustomized)
    }

    func testBeijingCardsLeaveEveryPinExposed() {
        let items = (0..<3).map { item(index: $0) }
        let pins = [items[0].id: CGPoint(x: 274, y: 162), items[1].id: CGPoint(x: 238, y: 318),
                    items[2].id: CGPoint(x: 137, y: 369)]
        let cards = JourneyCallout.layout(items: items, allItems: items, pins: pins, size: CGSize(width: 402, height: 677))
        for card in cards {
            XCTAssertFalse(pins.values.contains { card.frame.insetBy(dx: -16, dy: -14).contains($0) })
        }
    }

    func testCalloutsRemainSeparatedForCoincidentAndOffscreenPins() {
        let items = (0..<3).map { item(index: $0) }
        let size = CGSize(width: 402, height: 650)
        for coordinates in [[CGPoint(x: 200, y: 300)], [CGPoint(x: -500, y: -800)], [CGPoint(x: 900, y: 2000)]] {
            let pins = Dictionary(uniqueKeysWithValues: items.map { ($0.id, coordinates[0]) })
            let cards = JourneyCallout.layout(items: items, allItems: items, pins: pins, size: size)
            for card in cards { XCTAssertTrue(CGRect(origin: .zero, size: size).contains(card.frame)) }
            for (first, second) in zip(cards, cards.dropFirst()) {
                XCTAssertFalse(first.frame.intersects(second.frame))
                XCTAssertGreaterThanOrEqual(second.frame.minY - first.frame.maxY, 12)
            }
            XCTAssertTrue(cards[0].right)
            XCTAssertFalse(cards[1].right)
            XCTAssertTrue(cards[2].right)
        }
    }

    func testRouteUsesOnlyTransitWindowAndDeduplicatesDailySnapshots() {
        let points = [
            LifeIllustrationRoutePoint(latitude: 39.95, longitude: 116.45, timestamp: 190, kind: "waypoint"),
            LifeIllustrationRoutePoint(latitude: 39.96, longitude: 116.46, timestamp: 210, kind: "waypoint"),
            LifeIllustrationRoutePoint(latitude: 39.97, longitude: 116.47, timestamp: 310, kind: "waypoint")
        ]
        let origin = item(index: 0, points: points)
        let destination = item(index: 1, points: points)
        let legs = IllustrationJourneyLeg.make(items: [origin, destination])
        XCTAssertEqual(legs.count, 1)
        XCTAssertEqual(legs[0].coordinates.count, 3)
        XCTAssertEqual(legs[0].coordinates[1].latitude, 39.96)
        XCTAssertNotNil(legs[0].timeCaption)
    }

    func testConsecutiveMomentsAtSamePlaceGroupIntoMultiImageStop() {
        let morning = LifeIllustration(
            id: "studio-morning", windowStart: 100, windowEnd: 200, logicalDay: "2026-11-05",
            timezone: "Asia/Shanghai", place: "望京工作室",
            assetSha256: String(repeating: "a", count: 64), thumbnailSha256: String(repeating: "b", count: 64),
            width: 1024, height: 1024, sourceIds: ["s1"], createdAt: 1, updatedAt: 1,
            summary: "上午讨论架构边界", latitude: 39.9960, longitude: 116.4740, placeStart: 100, placeEnd: 195
        )
        let afternoon = LifeIllustration(
            id: "studio-afternoon", windowStart: 200, windowEnd: 300, logicalDay: "2026-11-05",
            timezone: "Asia/Shanghai", place: "望京工作室",
            assetSha256: String(repeating: "c", count: 64), thumbnailSha256: String(repeating: "d", count: 64),
            width: 1024, height: 1024, sourceIds: ["s2"], createdAt: 2, updatedAt: 2,
            summary: "下午继续整理接口", latitude: 39.9962, longitude: 116.4741, placeStart: 195, placeEnd: 295
        )
        let riverside = LifeIllustration(
            id: "river-walk", windowStart: 320, windowEnd: 420, logicalDay: "2026-11-05",
            timezone: "Asia/Shanghai", place: "亮马河畔步道",
            assetSha256: String(repeating: "e", count: 64), thumbnailSha256: String(repeating: "f", count: 64),
            width: 1024, height: 1024, sourceIds: ["s3"], createdAt: 3, updatedAt: 3,
            summary: "傍晚沿河散步看落叶", latitude: 39.9502, longitude: 116.4628, placeStart: 325, placeEnd: 410
        )

        let stops = IllustrationJourneyStop.group(items: [morning, afternoon, riverside])
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops[0].id, "studio-morning")
        XCTAssertEqual(stops[0].illustrations.map(\.id), ["studio-morning", "studio-afternoon"])
        XCTAssertEqual(stops[0].place, "望京工作室")
        XCTAssertEqual(stops[0].startTime, 100)
        XCTAssertEqual(stops[0].endTime, 295)
        XCTAssertEqual(stops[1].illustrations.map(\.id), ["river-walk"])

        let legs = IllustrationJourneyLeg.make(stops: stops, allItems: [morning, afternoon, riverside])
        XCTAssertEqual(legs.count, 1)
        XCTAssertEqual(legs[0].origin.id, "studio-morning")
        XCTAssertEqual(legs[0].destination.id, "river-walk")

        let pins = ["studio-morning": CGPoint(x: 260, y: 180), "river-walk": CGPoint(x: 190, y: 360)]
        let cards = JourneyCallout.layout(stops: stops, allStops: stops, pins: pins, size: CGSize(width: 402, height: 677))
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].frame.height, 124)
        XCTAssertEqual(cards[1].frame.height, 98)
        XCTAssertFalse(cards[0].frame.intersects(cards[1].frame))
    }

    func testSinglePageLayoutFitsManyStopsWithoutPagination() {
        let items = (0..<6).map { item(index: $0) }
        let stops = IllustrationJourneyStop.group(items: items)
        XCTAssertEqual(stops.count, 6)
        let size = CGSize(width: 402, height: 677)
        let pins = Dictionary(uniqueKeysWithValues: stops.enumerated().map { idx, stop in
            (stop.id, CGPoint(x: 196 + CGFloat((idx % 3) - 1) * 28, y: 95 + CGFloat(idx) * 92))
        })
        let fitted = JourneyCallout.selectFittingStops(from: stops, focusedID: stops[0].id, size: size)
        XCTAssertEqual(fitted.count, 6)
        let cards = JourneyCallout.layout(stops: fitted, allStops: stops, pins: pins, size: size)
        XCTAssertEqual(cards.count, 6)
        for card in cards {
            XCTAssertTrue(card.compact)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(card.frame))
        }
        for (first, second) in zip(cards, cards.dropFirst()) {
            XCTAssertFalse(first.frame.intersects(second.frame))
        }
    }

    private func item(index: Int, points: [LifeIllustrationRoutePoint] = []) -> LifeIllustration {
        LifeIllustration(id: "stop-\(index)", windowStart: Double(index * 200 + 100),
            windowEnd: Double(index * 200 + 200), logicalDay: "2026-11-05", timezone: "Asia/Shanghai",
            place: "停留点", assetSha256: String(repeating: "a", count: 64), thumbnailSha256: String(repeating: "b", count: 64),
            width: 1024, height: 1024, sourceIds: ["source"], createdAt: 1, updatedAt: 1,
            latitude: 39.9 + Double(index) * 0.1, longitude: 116.4 + Double(index) * 0.1,
            placeStart: Double(index * 200 + 100), placeEnd: Double(index * 200 + 200), routePoints: points)
    }
}
