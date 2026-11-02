import XCTest

@MainActor
final class SettingsHierarchyTests: XCTestCase {
    /// Opt-in read-only acceptance on an already paired personal device.
    func testLiveSettingsNavigation() throws {
        guard ProcessInfo.processInfo.environment["MOMO_LIVE_SETTINGS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires an explicitly selected, already paired device")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        try inspectSettings(app)
    }

    /// Uses the loopback-only serve_chat_interaction_fixture.py manifest.
    func testSyntheticSettingsNavigation() throws {
#if targetEnvironment(simulator)
        guard let runID = ProcessInfo.processInfo.environment["MOMO_SETTINGS_FIXTURE_RUN_ID"], UUID(uuidString: runID) != nil else {
            throw XCTSkip("Requires a fresh loopback fixture manifest with the same run ID")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "chat"
        app.launch()
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap(); app.buttons["welcome.start"].tap()
        }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 30) {
            app.buttons["onboarding.finish"].tap()
        }
        try inspectSettings(app)
#else
        throw XCTSkip("Synthetic acceptance is simulator-only")
#endif
    }

    private func inspectSettings(_ app: XCUIApplication) throws {
        if app.tabBars.buttons["聊天"].exists { app.tabBars.buttons["聊天"].tap() }
        let entry = app.buttons["remote.settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.buttons["settings.mac"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings.advanced"].exists)
        capture(app, "Settings — original phone surfaces")
        app.buttons["settings.mac"].tap()
        XCTAssertTrue(app.navigationBars["Mac 连接"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["remote.deviceState"].exists)
        XCTAssertFalse(app.buttons["remote.connectionDetails"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "remote.pairDevice").count, 1)
        capture(app, "Connection — inline status and network")
        app.buttons["remote.manualConnection"].tap()
        XCTAssertTrue(app.textViews["remote.connectionJSON"].waitForExistence(timeout: 10))
        // Do not capture the existing configuration or device credentials.
        back(app)
        back(app)
        app.buttons["settings.memories"].tap()
        XCTAssertTrue(app.navigationBars["记忆"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["完成"].exists)
        let details = app.descendants(matching: .any)["remote.memorySyncDetails"].firstMatch
        if details.exists {
            details.tap()
            let detailContent = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label CONTAINS %@ OR label CONTAINS %@", "最近同步", "批录音待整理", "份录音需核对")).firstMatch
            XCTAssertTrue(detailContent.waitForExistence(timeout: 10))
        }
        else { XCTAssertTrue(app.descendants(matching: .any)["remote.memorySyncStatus"].exists) }
        capture(app, "Memory — inline sync status")
        back(app)
        if app.buttons["settings.notifications"].exists {
            app.buttons["settings.notifications"].tap()
            XCTAssertTrue(app.navigationBars["通知"].waitForExistence(timeout: 10))
            capture(app, "通知")
            back(app)
        }
        for (identifier, title) in [("health", "健康"), ("visits", "到访地点"), ("calendar", "日历"), ("reminders", "提醒事项"),
                                    ("speech.model", "转录模型"), ("speech.language", "识别语言"), ("speech.detection", "语音检测"), ("storage", "储存空间")] {
            let row = app.buttons["settings." + identifier]
            for _ in 0..<5 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable, identifier)
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), title)
            if identifier == "storage" {
                XCTAssertTrue(app.descendants(matching: .any)["storage.retention.current"].waitForExistence(timeout: 30))
            }
            capture(app, title)
            if identifier == "storage" {
                app.swipeUp(); app.swipeUp()
                XCTAssertTrue(app.descendants(matching: .any)["storage.total"].waitForExistence(timeout: 10))
                capture(app, "储存空间 — 统计与设备空间")
            }
            back(app)
        }
        app.swipeDown(); app.swipeDown()
        capture(app, "Settings — after repeated navigation")
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}


@MainActor
final class MemoryReadingTests: XCTestCase {
    func testPreviewFullTextAndReversibleActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = "5F12C378-A804-4E20-A46D-213FE37495AB"
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "chat"
        app.launchEnvironment["MOMO_UI_TEST_AVATAR_UNAVAILABLE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) { app.buttons["welcome.skip"].tap() }
        if app.buttons["welcome.start"].waitForExistence(timeout: 5) { app.buttons["welcome.start"].tap() }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 10) { app.buttons["onboarding.finish"].tap() }
        XCTAssertTrue(app.buttons["remote.settings"].waitForExistence(timeout: 30))
        app.buttons["remote.settings"].tap()
        XCTAssertTrue(app.buttons["settings.mac"].waitForExistence(timeout: 10))
        capture(app, "settings-overview")
        app.buttons["settings.memories"].tap()
        let row = app.buttons["remote.memoryRow.memory-layout-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(row.label.contains("0fcdf941"))
        XCTAssertTrue(row.label.contains("查看全文"))
        capture(app, "memory-list")
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .trait])
        row.tap()
        let original = app.staticTexts["remote.memoryText"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.label.contains("0fcdf941-b14c-4087-ad0e-a3eab9495fe2 v78"))
        capture(app, "memory-detail-original")
        app.buttons["remote.memoryActions"].tap()
        app.buttons["忘记这条记忆"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(original.exists)
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let longRow = app.buttons["remote.memoryRow.memory-layout-4"]
        for _ in 0..<4 where !longRow.isHittable { app.swipeUp() }
        longRow.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.label.hasSuffix("全文末尾保留标记。"))
        let initialTextTop = original.frame.minY
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertLessThan(original.frame.minY, initialTextTop, "The long memory must actually scroll beneath the navigation bar.")
        capture(app, "memory-full-text-scroll")

    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
