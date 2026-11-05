import XCTest
import UIKit

@MainActor
final class LifeIllustrationJourneyTests: XCTestCase {
    func testRealGeneratedImagesInTimelineViewerAndSettings() throws {
        continueAfterFailure = false
        let app = launch(appearance: .light)
        defer { app.terminate() }
        let firstStamp = app.buttons["lifeIllustration.stamp.sample-morning"]
        try assertJournalStrip(app)
        attach(app, name: "01_iphone_timeline_inline")
        firstStamp.tap()
        assertMap(app)
        attach(app, name: "02_iphone_journey_map")
        assertMapZoomAndReset(app)
        app.buttons["lifeIllustration.map.card.sample-night"].tap()
        let caption = app.staticTexts["lifeIllustration.viewer.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["lifeIllustration.viewer.share"].exists)
        XCTAssertTrue(caption.label.contains("20:15–20:50"))
        XCTAssertEqual(app.staticTexts["lifeIllustration.viewer.page"].label, "04 / 04")
        XCTAssertFalse(app.staticTexts["lifeIllustration.viewer.summary"].label.isEmpty)
        XCTAssertTrue(app.buttons["lifeIllustration.viewer.thumb.sample-morning"].exists)
        attach(app, name: "03_iphone_detail_zoom")
        attach(app, name: "02_iphone_fullscreen_viewer")
        assertViewerInteractions(app, picture: firstStamp)
        app.buttons["library.more"].tap()
        app.buttons["设置"].tap()
        let row = app.buttons["settings.lifeIllustrations"]
        for _ in 0..<5 {
            if row.exists && row.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.switches["lifeIllustration.settings.enabled"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["lifeIllustration.settings.subscription"].label, "Codex 订阅可用")
        attach(app, name: "03_iphone_settings_row")
    }

    private func assertViewerInteractions(_ app: XCUIApplication, picture: XCUIElement) {
        XCTAssertEqual(app.staticTexts["lifeIllustration.viewer.page"].label, "04 / 04")
        let caption = app.staticTexts["lifeIllustration.viewer.caption"]
        let viewer = app.descendants(matching: .any)["lifeIllustration.viewer.image"]
        XCTAssertGreaterThanOrEqual(viewer.frame.width, 300)
        let zoom = viewer.scrollViews.firstMatch
        XCTAssertTrue(zoom.exists)
        let image = zoom.images.firstMatch
        let originalWidth = image.frame.width
        XCTAssertGreaterThanOrEqual(originalWidth, 300)
        XCTAssertEqual(image.frame.width, image.frame.height, accuracy: 1)
        zoom.pinch(withScale: 2, velocity: 1)
        let enlarged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            image.frame.width > originalWidth * 1.3
        }, object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [enlarged], timeout: 5), .completed)
        XCTAssertTrue(caption.exists)
        zoom.pinch(withScale: 0.1, velocity: -2)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(image.frame.width - originalWidth) < 1
        }, object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        zoom.doubleTap()
        let doubleEnlarged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            image.frame.width > originalWidth * 2
        }, object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [doubleEnlarged], timeout: 5), .completed)
        zoom.doubleTap()
        let doubleRestored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(image.frame.width - originalWidth) < 1
        }, object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [doubleRestored], timeout: 5), .completed)
        let lastCaption = caption.label
        viewer.swipeRight()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", lastCaption), object: caption)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        // Verify smooth direct thumbnail switching in the viewer strip
        app.buttons["lifeIllustration.viewer.thumb.sample-morning"].tap()
        let jumpedFirst = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "01 / 04"),
            object: app.staticTexts["lifeIllustration.viewer.page"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [jumpedFirst], timeout: 5), .completed)
        app.swipeDown()
        XCTAssertTrue(app.buttons["lifeIllustration.map.close"].waitForExistence(timeout: 5))
        app.buttons["lifeIllustration.map.close"].tap()
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        XCTAssertTrue(picture.isHittable)
        picture.tap()
        // Verify tapping an individual sticker inside the multi-image stop opens that exact moment
        app.buttons["lifeIllustration.map.sticker.sample-code"].tap()
        XCTAssertTrue(app.buttons["lifeIllustration.viewer.close"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["lifeIllustration.viewer.page"].label, "02 / 04")
        app.buttons["lifeIllustration.viewer.close"].tap()
        app.buttons["lifeIllustration.map.close"].tap()
        XCTAssertTrue(picture.isHittable)
        picture.tap()
        app.buttons["lifeIllustration.map.card.sample-night"].tap()
        app.buttons["lifeIllustration.viewer.source"].tap()
        XCTAssertTrue(app.navigationBars["转录详情"].waitForExistence(timeout: 5))
        app.navigationBars["转录详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        app.buttons["timeline.search.toggle"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["lifeIllustration.strip"].firstMatch.exists)
        app.buttons["timeline.search.toggle"].tap()
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
    }

    func testDarkTimelineAndViewer() throws {
        continueAfterFailure = false
        let app = launch(appearance: .dark)
        defer { app.terminate() }
        let firstStamp = app.buttons["lifeIllustration.stamp.sample-morning"]
        try assertJournalStrip(app)
        try assertDarkCanvas(app)
        attach(app, name: "01b_iphone_timeline_inline_dark")
        firstStamp.tap()
        assertMap(app)
        attach(app, name: "02b_iphone_journey_map_dark")
        app.buttons["lifeIllustration.map.card.sample-night"].tap()
        XCTAssertTrue(app.staticTexts["lifeIllustration.viewer.caption"].waitForExistence(timeout: 5))
        try assertDarkCanvas(app)
        attach(app, name: "02b_iphone_fullscreen_viewer_dark")
        attach(app, name: "03b_iphone_detail_zoom_dark")
        assertViewerInteractions(app, picture: firstStamp)
    }

    private func assertMap(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["lifeIllustration.map.close"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["lifeIllustration.map.loading"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 30), .completed)
        XCTAssertFalse(app.staticTexts["地图暂不可用 · 已保留定位连线"].exists)
        XCTAssertFalse(app.staticTexts["低功耗定位 · 道路连线为估算"].exists)
        XCTAssertFalse(app.staticTexts["今日行程手帐"].exists)
        // Single-page map: never paginate into multiple pages
        XCTAssertFalse(app.buttons["上一页"].exists)
        XCTAssertFalse(app.buttons["下一页"].exists)
        XCTAssertTrue(app.buttons["lifeIllustration.map.zoomIn"].isHittable)
        XCTAssertTrue(app.buttons["lifeIllustration.map.zoomOut"].isHittable)
        let firstStop = app.descendants(matching: .any)["lifeIllustration.map.card.sample-morning"].firstMatch
        let secondStop = app.buttons["lifeIllustration.map.card.sample-outdoor"]
        let thirdStop = app.buttons["lifeIllustration.map.card.sample-night"]
        let cards = [firstStop, secondStop, thirdStop]
        for card in cards {
            XCTAssertTrue(card.exists)
            XCTAssertTrue(app.frame.contains(card.frame))
        }
        // Multi-image stop at 望京工作室 exposes both sticker buttons
        XCTAssertTrue(app.buttons["lifeIllustration.map.sticker.sample-morning"].isHittable)
        XCTAssertTrue(app.buttons["lifeIllustration.map.sticker.sample-code"].isHittable)
        XCTAssertFalse(cards[0].frame.intersects(cards[1].frame))
        XCTAssertFalse(cards[1].frame.intersects(cards[2].frame))
        XCTAssertFalse(cards[0].frame.intersects(cards[2].frame))
        XCTAssertGreaterThan(cards[0].frame.minX, cards[1].frame.minX)
        XCTAssertGreaterThan(cards[2].frame.minX, cards[1].frame.minX)
        XCTAssertTrue(secondStop.label.contains("亮马河畔步道"))
        XCTAssertTrue(thirdStop.label.contains("东四胡同书房"))
    }

    private func assertMapZoomAndReset(_ app: XCUIApplication) {
        let zoomIn = app.buttons["lifeIllustration.map.zoomIn"]
        XCTAssertTrue(zoomIn.isHittable)
        zoomIn.tap()
        let fitAll = app.buttons["lifeIllustration.map.fitAll"]
        XCTAssertTrue(fitAll.waitForExistence(timeout: 5))
        fitAll.tap()
        let resetDone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: fitAll)
        XCTAssertEqual(XCTWaiter.wait(for: [resetDone], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["lifeIllustration.map.card.sample-night"].waitForExistence(timeout: 5))
    }

    private func launch(appearance: XCUIDevice.Appearance) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "life-illustrations"
        app.launchEnvironment["MOMO_UI_TEST_WATCH_STATUS"] = "paused"
        app.launchEnvironment["MOMO_UI_TEST_APPEARANCE"] = appearance == .dark ? "dark" : "light"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap()
            app.buttons["welcome.start"].tap()
            XCTAssertTrue(app.buttons["稍后配对"].waitForExistence(timeout: 5))
            app.buttons["稍后配对"].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["转录"].waitForExistence(timeout: 20))
        app.tabBars.buttons["转录"].tap()
        return app
    }

    private func assertDarkCanvas(_ app: XCUIApplication) throws {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let rgba = try pixel(image, x: image.width - 12, y: image.height / 2)
        XCTAssertLessThan(rgba[0], 64, "The exported dark screenshot must actually have a dark canvas.")
        XCTAssertLessThan(rgba[1], 64)
        XCTAssertLessThan(rgba[2], 64)
    }

    private func assertJournalStrip(_ app: XCUIApplication) throws {
        let strip = app.descendants(matching: .any)["lifeIllustration.strip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 30))
        XCTAssertEqual(strip.frame.width, app.frame.width - 48, accuracy: 1)
        XCTAssertGreaterThanOrEqual(strip.frame.height, 70)
        XCTAssertLessThanOrEqual(strip.frame.height, 84)
        let cards = ["sample-morning", "sample-code"].map {
            app.buttons["lifeIllustration.stamp.\($0)"]
        }
        for (index, card) in cards.enumerated() {
            XCTAssertTrue(card.isHittable)
            XCTAssertEqual(card.frame.width, 144, accuracy: 1)
            XCTAssertGreaterThanOrEqual(card.frame.height, 50)
            XCTAssertLessThanOrEqual(card.frame.height, 64)
            XCTAssertEqual(card.frame.minY, cards[0].frame.minY, accuracy: 1)
            XCTAssertEqual(card.frame.minX, 24 + CGFloat(index) * 154, accuracy: 1)
            XCTAssertGreaterThanOrEqual(card.frame.minY, strip.frame.minY)
            XCTAssertLessThanOrEqual(card.frame.maxY, strip.frame.maxY)
            // Meaningful text instead of repetitive xx–xx clock slots or №01
            XCTAssertFalse(card.label.contains("№"))
            XCTAssertFalse(card.label.contains("11–14"))
            XCTAssertFalse(card.label.contains("14–17"))
        }
        XCTAssertTrue(cards[0].label.contains("草图纸"))
        XCTAssertTrue(cards[1].label.contains("积木"))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window."))
        let preceding = rows.matching(NSPredicate(format: "label CONTAINS %@", "坐在台灯旁喝茶")).firstMatch
        let following = rows.matching(NSPredicate(format: "label CONTAINS %@", "明天再继续")).firstMatch
        XCTAssertTrue(preceding.isHittable)
        XCTAssertTrue(following.isHittable)
        XCTAssertEqual(preceding.frame.maxY, following.frame.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(following.frame.maxY, strip.frame.minY)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "lifeIllustration.inline.")).firstMatch.exists)
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let x = Int((preceding.frame.minX + 6) * scale)
        for y in stride(from: preceding.frame.maxY - 12, through: following.frame.minY + 6, by: 3) {
            let line = try pixel(image, x: x, y: Int(y * scale))
            let canvas = try pixel(image, x: x + Int(4 * scale), y: Int(y * scale))
            XCTAssertGreaterThan(abs(Int(line[0]) - Int(canvas[0])), 8)
        }
        // Verify the strip scrolls with timeline content instead of sticking as a fixed bottom overlay.
        let bottomY = strip.frame.minY
        preceding.swipeDown()
        XCTAssertTrue(!strip.exists || strip.frame.minY > bottomY + 40)
        for _ in 0..<4 {
            if strip.exists && cards[0].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(cards[0].isHittable)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgba
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
