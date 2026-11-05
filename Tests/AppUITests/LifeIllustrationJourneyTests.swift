import XCTest

@MainActor
final class LifeIllustrationJourneyTests: XCTestCase {
    func testRealGeneratedImagesInTimelineViewerAndSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "life-illustrations"
        app.launchEnvironment["MOMO_UI_TEST_WATCH_STATUS"] = "paused"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap()
            app.buttons["welcome.start"].tap()
            XCTAssertTrue(app.buttons["稍后配对"].waitForExistence(timeout: 5))
            app.buttons["稍后配对"].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["转录"].waitForExistence(timeout: 20))
        app.tabBars.buttons["转录"].tap()
        let picture = app.buttons["lifeIllustration.inline.sample-night"]
        XCTAssertTrue(picture.waitForExistence(timeout: 30))
        XCTAssertTrue(picture.isHittable)
        XCTAssertGreaterThan(picture.frame.height, 200)
        XCTAssertFalse(app.buttons["timeline.journal"].exists)
        XCTAssertTrue(app.staticTexts["明天再继续，今晚先休息。"].exists)
        // Keep both adjacent transcript rows in the evidence, rather than framing only the image.
        let desiredTop = app.frame.height * 0.46
        let delta = desiredTop - picture.frame.minY
        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        dragStart.press(forDuration: 0.1, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: delta)),
                        withVelocity: .slow, thenHoldForDuration: 0.6)
        attach(app, name: "01_iphone_timeline_inline")
        picture.tap()
        let caption = app.staticTexts["lifeIllustration.viewer.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["lifeIllustration.viewer.share"].exists)
        attach(app, name: "02_iphone_fullscreen_viewer")
        let lastCaption = caption.label
        app.swipeRight()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", lastCaption), object: caption)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        app.swipeDown()
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        XCTAssertTrue(picture.isHittable)
        picture.tap()
        XCTAssertTrue(app.buttons["lifeIllustration.viewer.close"].waitForExistence(timeout: 5))
        app.buttons["lifeIllustration.viewer.close"].tap()
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

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
