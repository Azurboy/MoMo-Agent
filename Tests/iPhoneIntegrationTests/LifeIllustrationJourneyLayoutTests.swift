import MapKit
import MoMoAgentClient
import XCTest
@testable import MoMoAgent

final class LifeIllustrationJourneyLayoutTests: XCTestCase {
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

    private func item(index: Int, points: [LifeIllustrationRoutePoint] = []) -> LifeIllustration {
        LifeIllustration(id: "stop-\(index)", windowStart: Double(index * 200 + 100),
            windowEnd: Double(index * 200 + 200), logicalDay: "2026-11-05", timezone: "Asia/Shanghai",
            place: "停留点", assetSha256: String(repeating: "a", count: 64), thumbnailSha256: String(repeating: "b", count: 64),
            width: 1024, height: 1024, sourceIds: ["source"], createdAt: 1, updatedAt: 1,
            latitude: 39.9 + Double(index) * 0.1, longitude: 116.4 + Double(index) * 0.1,
            placeStart: Double(index * 200 + 100), placeEnd: Double(index * 200 + 200), routePoints: points)
    }
}
