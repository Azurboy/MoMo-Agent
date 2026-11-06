import XCTest

@MainActor
final class PhoneWatchStatusTests: XCTestCase {
    func testFailureBannerCanBeDismissedWithoutBlockingNavigation() {
        let app = launch(status: "paused", statusFailure: true)
        let failure = app.staticTexts["app.failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let dismiss = app.buttons["app.failure.dismiss"]
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertLessThan(failure.frame.maxY, app.tabBars.firstMatch.frame.minY)
        attach(app, name: "dismissible-status-banner")
        app.tabBars.buttons["转录"].tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        dismiss.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: failure)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["timeline.datePicker"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.watchStatus"].exists)
    }

    func testLibraryOmitsRedundantStatusBanner() {
        let app = launch(status: "paused")
        XCTAssertTrue(app.tabBars.buttons["转录"].waitForExistence(timeout: 15))
        app.tabBars.buttons["转录"].tap()
        XCTAssertTrue(app.buttons["timeline.datePicker"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.watchStatus"].exists)
        XCTAssertFalse(app.buttons["library.earphoneStatus"].exists)
        attach(app, name: "library-clean-header")
    }

    func testRecordingStatusOpensCardFromChat() {
        let app = launch(status: "recording")
        let shortcut = app.buttons["assistant.watchStatus"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 15))
        XCTAssertTrue(shortcut.label.contains("手表正在录音"))
        XCTAssertEqual(shortcut.value as? String, "绿色")
        XCTAssertTrue(shortcut.isHittable)
        let avatar = app.buttons["personalAgent.avatar"]
        XCTAssertTrue(avatar.exists)
        XCTAssertGreaterThan(avatar.frame.midY, app.frame.height * 0.25)
        XCTAssertLessThan(avatar.frame.midY, app.frame.height * 0.6)
        XCTAssertGreaterThan(shortcut.frame.midX, avatar.frame.midX)
        XCTAssertGreaterThan(shortcut.frame.midY, avatar.frame.midY)
        XCTAssertEqual(app.buttons.matching(identifier: "personalAgent.avatar").count, 1)
        assertMoMoVisible(app)
        attach(app, name: "watch-status-chat")
        shortcut.tap()
        XCTAssertTrue(app.staticTexts["assistant.watchStatus.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["转录"].exists, "The badge first presents a small status popover in chat.")
        XCTAssertTrue(app.staticTexts["assistant.watchStatus.sync"].exists)
        attach(app, name: "watch-status-popover")
        app.buttons["assistant.watchStatus.openLibrary"].tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["timeline.datePicker"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.watchStatus"].exists)
        attach(app, name: "watch-status-recording-row")
        app.tabBars.buttons["聊天"].tap()
        XCTAssertTrue(app.buttons["assistant.watchStatus"].waitForExistence(timeout: 5))
        assertMoMoVisible(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        assertMoMoVisible(app)
        attach(app, name: "momo-green-status-after-foreground")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["personalAgent.name"].waitForExistence(timeout: 15))
        assertMoMoVisible(app)
        attach(app, name: "momo-green-status-after-relaunch")
    }

    func testStaleStatusDoesNotClaimRecording() {
        let app = launch(status: "stale")
        let shortcut = app.buttons["assistant.watchStatus"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 15))
        XCTAssertTrue(shortcut.label.contains("手表状态待更新"))
        XCTAssertEqual(shortcut.value as? String, "黄色")
        shortcut.tap()
        XCTAssertTrue(app.staticTexts["assistant.watchStatus.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["assistant.watchStatus.title"].label, "手表状态待更新")
        attach(app, name: "watch-status-stale")
    }

    func testMutedStatusOpensCardFromChat() {
        let app = launch(status: "paused")
        let shortcut = app.buttons["assistant.watchStatus"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 15))
        XCTAssertEqual(shortcut.value as? String, "黄色")
        shortcut.tap()
        XCTAssertTrue(app.staticTexts["assistant.watchStatus.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["assistant.watchStatus.title"].label, "手表已静音")
        attach(app, name: "watch-status-muted")
    }

    private func launch(status: String, statusFailure: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_WATCH_STATUS"] = status
        if statusFailure { app.launchEnvironment["MOMO_UI_TEST_STATUS_FAILURE"] = "1" }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        addTeardownBlock { app.terminate() }
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap()
        }
        if app.buttons["welcome.start"].waitForExistence(timeout: 5) {
            app.buttons["welcome.start"].tap()
            XCTAssertTrue(app.buttons["稍后配对"].waitForExistence(timeout: 5))
            app.buttons["稍后配对"].tap()
            if app.tabBars.buttons["聊天"].waitForExistence(timeout: 10) {
                app.tabBars.buttons["聊天"].tap()
            }
        }
        return app
    }

    private func assertMoMoVisible(_ app: XCUIApplication) {
        XCTAssertEqual(app.staticTexts["personalAgent.name"].label, "MoMo")
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.personalAgentHasVisiblePixels() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed,
                       "The Watch badge cannot substitute for actual Avatar pixels.")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
