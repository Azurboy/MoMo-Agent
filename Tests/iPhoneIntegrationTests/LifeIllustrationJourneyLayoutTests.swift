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

    func testWorldRouteCurveRemainsLockedUnderMapPanAndZoomTransforms() {
        let coords = [
            CLLocationCoordinate2D(latitude: 39.9960, longitude: 116.4740),
            CLLocationCoordinate2D(latitude: 39.9720, longitude: 116.4680),
            CLLocationCoordinate2D(latitude: 39.9502, longitude: 116.4628)
        ]
        let roadPoints = journeyWorldCurvePoints(coords, isRoadFitted: true, seed: 0)
        let fallbackPoints = journeyWorldCurvePoints(coords, isRoadFitted: false, seed: 0)
        XCTAssertGreaterThanOrEqual(roadPoints.count, 4)
        XCTAssertGreaterThan(fallbackPoints.count, roadPoints.count)
        XCTAssertEqual(roadPoints.first?.x ?? 0, MKMapPoint(coords[0]).x, accuracy: 0.01)
        XCTAssertEqual(roadPoints.last?.y ?? 0, MKMapPoint(coords[2]).y, accuracy: 0.01)
        XCTAssertEqual(fallbackPoints.first?.x ?? 0, MKMapPoint(coords[0]).x, accuracy: 0.01)
        XCTAssertEqual(fallbackPoints.last?.y ?? 0, MKMapPoint(coords[2]).y, accuracy: 0.01)

        // Verify exact 1:1 pan & zoom invariance: projecting world vertices through two camera
        // transforms produces identical relative displacements as the underlying map tiles.
        let originA = MKMapPoint(coords[0])
        let scaleA = 0.05
        let originB = MKMapPoint(x: originA.x + 2_400, y: originA.y - 1_800)
        let scaleB = 0.125
        for worldPt in fallbackPoints {
            let screenA = CGPoint(x: (worldPt.x - originA.x) * scaleA, y: (worldPt.y - originA.y) * scaleA)
            let screenB = CGPoint(x: (worldPt.x - originB.x) * scaleB, y: (worldPt.y - originB.y) * scaleB)
            let expectedX = (screenA.x / scaleA + (originA.x - originB.x)) * scaleB
            let expectedY = (screenA.y / scaleA + (originA.y - originB.y)) * scaleB
            XCTAssertEqual(screenB.x, expectedX, accuracy: 1e-6)
            XCTAssertEqual(screenB.y, expectedY, accuracy: 1e-6)
        }
        XCTAssertNotNil(journeyWorldRouteSample(fallbackPoints, fraction: 0.52))
    }

    func testDreamBriefingMarkdownParserExtractsMorningCardsAndMotifs() {
        let markdown = """
        # 晨间简报 · 2026-11-10

        ## 今日脉络
        昨晚在望京工作室敲定了同步协议与人物声纹整理方案，今天上午重点推进收尾。

        ## 重点预热与未闭环线索
        - 小林下午四点前同步接口清单

        ## 卡片：跟进小林接口清单
        - 纹样：关系交汇
        - 语境：承接昨晚工作室讨论

        请帮我结合昨晚录音里和小林敲定的接口边界，列一份下午联调的检查清单。

        ## 卡片：梳理周末出行安排
        - 纹样：声音片段
        - 语境：上次聊到的出行计划

        帮我把这周提到的周末出行地点和时间整理成待办。
        """
        let doc = DreamBriefingDocument.parse(markdown: markdown)
        XCTAssertEqual(doc.headline, "晨间简报 · 2026-11-10")
        XCTAssertTrue(doc.overview.contains("望京工作室"))
        XCTAssertEqual(doc.cards.count, 2)
        XCTAssertEqual(doc.cards[0].title, "跟进小林接口清单")
        XCTAssertEqual(doc.cards[0].subtitle, "承接昨晚工作室讨论")
        XCTAssertEqual(doc.cards[0].motif, .relationWeave)
        XCTAssertTrue(doc.cards[0].prompt.contains("联调的检查清单"))
        XCTAssertEqual(doc.cards[1].title, "梳理周末出行安排")
        XCTAssertEqual(doc.cards[1].motif, .voiceWave)
    }

    private func item(index: Int, points: [LifeIllustrationRoutePoint] = []) -> LifeIllustration {
        LifeIllustration(id: "stop-\(index)", windowStart: Double(index * 200 + 100),
            windowEnd: Double(index * 200 + 200), logicalDay: "2026-11-05", timezone: "Asia/Shanghai",
            place: "停留点", assetSha256: String(repeating: "a", count: 64), thumbnailSha256: String(repeating: "b", count: 64),
            width: 1024, height: 1024, sourceIds: ["source"], createdAt: 1, updatedAt: 1,
            latitude: 39.9 + Double(index) * 0.1, longitude: 116.4 + Double(index) * 0.1,
            placeStart: Double(index * 200 + 100), placeEnd: Double(index * 200 + 200), routePoints: points)
    }

    func testMemoryCardDigestAndSectionGroupingExtractsCleanHierarchy() throws {
        func makeMemory(id: String, text: String, kind: String, basis: String) throws -> ContextMemory {
            let payload: [String: Any] = [
                "id": id,
                "text": text,
                "kind": kind,
                "basis": basis,
                "status": "current",
                "revision": 1,
                "evidence": []
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return try JSONDecoder().decode(ContextMemory.self, from: data)
        }

        let journal = try makeMemory(
            id: "hermes-journal-1",
            text: """
            # 2026-11-10 · 日记法规则细化与团队沟通线索

            ## 时空与事件脉络
            - [12:06 原音](momoagent://source/48c48995-8cfe-43e9-991e-e5f41497cd40/bb55ee74?version=82&generation=0)：围绕日记法继续讨论活动起止日期。
            - [15:37 原音](momoagent://source/1d2d40a0-d487-4b26-9dbd-b650a448a8f9/58a037f9?version=39&generation=0)：跟进安克项目测试反馈。

            ## 承诺与待办对账
            - 待与书雅确认补答窗口规则。
            """,
            kind: "journal",
            basis: "dream"
        )
        let journalDigest = MemoryCardDigest(memory: journal)
        XCTAssertEqual(journalDigest.badge.title, "生活日志")
        XCTAssertEqual(journalDigest.dateBadge, "2026-11-10")
        XCTAssertEqual(journalDigest.title, "日记法规则细化与团队沟通线索")
        XCTAssertEqual(journalDigest.sectionPills, ["时空与事件脉络", "承诺与待办对账"])
        XCTAssertEqual(journalDigest.highlights.first, "[12:06]：围绕日记法继续讨论活动起止日期。")
        XCTAssertTrue(journalDigest.cleanedNotebookMarkdown.contains("`⏱ 12:06 原音`"))
        XCTAssertFalse(journalDigest.cleanedNotebookMarkdown.contains("momoagent://source"))

        let legacyCore = try makeMemory(
            id: "hermes-memory-legacy",
            text: "10/28 3d1a1f88-6daf-441c-b358-b2baad897def（归属/执行未核）：v435称微调不用客户数据（与e0b5c310 1792738925有差异）；议补追问/去最低5轮；1793179516–9634伊利澄清计轮致早跳。",
            kind: "memory",
            basis: "hermes"
        )
        let coreDigest = MemoryCardDigest(memory: legacyCore)
        XCTAssertEqual(coreDigest.dateBadge, "10/28")
        XCTAssertFalse(coreDigest.title.contains("3d1a1f88"))
        XCTAssertFalse(coreDigest.title.contains("1792738925"))
        XCTAssertFalse(coreDigest.title.contains("归属/执行未核"))
        XCTAssertEqual(coreDigest.highlights.count, 2)
        XCTAssertFalse(coreDigest.highlights.joined().contains("1793179516"))

        let sections = DreamMemoryCategory.sections(from: [legacyCore, journal], category: .all)
        XCTAssertEqual(sections.map { $0.id }, ["notebook", "core"])
        XCTAssertEqual(sections[0].items.map { $0.id }, ["hermes-journal-1"])
        XCTAssertEqual(sections[1].items.map { $0.id }, ["hermes-memory-legacy"])
    }
}
