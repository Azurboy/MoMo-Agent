import XCTest
import UIKit

@MainActor
final class LifeIllustrationJourneyTests: XCTestCase {
    func testRealGeneratedImagesInTimelineViewerAndSettings() throws {
        continueAfterFailure = false
        let app = launch(appearance: .light)
        defer { app.terminate() }
        let picture = app.buttons["lifeIllustration.inline.sample-night"]
        XCTAssertTrue(picture.waitForExistence(timeout: 30))
        XCTAssertTrue(picture.isHittable)
        XCTAssertGreaterThanOrEqual(picture.frame.height, 44)
        XCTAssertLessThanOrEqual(picture.frame.height, 52)
        XCTAssertLessThanOrEqual(picture.frame.width, 260)
        XCTAssertLessThan(picture.frame.width, app.frame.width * 0.75)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window."))
        let preceding = rows.matching(NSPredicate(format: "label CONTAINS %@", "坐在台灯旁喝茶")).firstMatch
        let following = rows.matching(NSPredicate(format: "label CONTAINS %@", "明天再继续")).firstMatch
        XCTAssertEqual(picture.frame.minX, preceding.frame.minX + 26, accuracy: 1)
        XCTAssertEqual(picture.frame.minY, preceding.frame.maxY, accuracy: 1)
        XCTAssertEqual(picture.frame.maxY, following.frame.minY, accuracy: 1)
        XCTAssertFalse(app.buttons["timeline.journal"].exists)
        XCTAssertTrue(app.staticTexts["明天再继续，今晚先休息。"].exists)
        XCTAssertTrue(preceding.isHittable)
        XCTAssertTrue(following.isHittable)
        try assertConnectedSpine(app, beside: picture)
        attach(app, name: "01_iphone_timeline_inline")
        picture.tap()
        let caption = app.staticTexts["lifeIllustration.viewer.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["lifeIllustration.viewer.share"].exists)
        XCTAssertTrue(caption.label.contains("20:00–23:00"))
        XCTAssertEqual(app.staticTexts["lifeIllustration.viewer.page"].label, "03 / 03")
        attach(app, name: "02_iphone_fullscreen_viewer")
        assertViewerInteractions(app, picture: picture)
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
        let lastCaption = caption.label
        viewer.swipeRight()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", lastCaption), object: caption)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        app.swipeDown()
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        XCTAssertTrue(picture.isHittable)
        picture.tap()
        XCTAssertTrue(app.buttons["lifeIllustration.viewer.close"].waitForExistence(timeout: 5))
        app.buttons["lifeIllustration.viewer.close"].tap()
        XCTAssertTrue(picture.isHittable)
    }

    func testDarkTimelineAndViewer() throws {
        continueAfterFailure = false
        let app = launch(appearance: .dark)
        defer { app.terminate() }
        let picture = app.buttons["lifeIllustration.inline.sample-night"]
        XCTAssertTrue(picture.waitForExistence(timeout: 30))
        XCTAssertTrue(picture.isHittable)
        XCTAssertGreaterThanOrEqual(picture.frame.height, 44)
        XCTAssertLessThanOrEqual(picture.frame.height, 52)
        XCTAssertLessThanOrEqual(picture.frame.width, 260)
        try assertDarkCanvas(app)
        try assertConnectedSpine(app, beside: picture)
        attach(app, name: "01b_iphone_timeline_inline_dark")
        picture.tap()
        XCTAssertTrue(app.staticTexts["lifeIllustration.viewer.caption"].waitForExistence(timeout: 5))
        try assertDarkCanvas(app)
        attach(app, name: "02b_iphone_fullscreen_viewer_dark")
        assertViewerInteractions(app, picture: picture)
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

    private func assertConnectedSpine(_ app: XCUIApplication, beside picture: XCUIElement) throws {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let x = Int((picture.frame.minX - 20) * scale)
        for y in stride(from: picture.frame.minY + 2, to: picture.frame.maxY - 2, by: 8) {
            let line = try pixel(image, x: x, y: Int(y * scale))
            let canvas = try pixel(image, x: x + Int(4 * scale), y: Int(y * scale))
            XCTAssertGreaterThan(abs(Int(line[0]) - Int(canvas[0])), 8, "The timeline spine must pass through the entire illustration row.")
        }
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
