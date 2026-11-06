import XCTest

@MainActor
final class PhoneTimelineJourneyTests: XCTestCase {
    func testContinuousSpeechMergesAndSpeakerChangeStartsAnotherRow() {
        let app = launch(timelineFixture: "turns")
        latestWindow(app).tap()
        let text = app.staticTexts["同一个人的连续发言，短暂停顿后仍放在一起。"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let other = app.staticTexts["这里换了一个人，应该另起一行。"].firstMatch
        XCTAssertTrue(other.exists)
        XCTAssertGreaterThan(other.frame.minY, text.frame.maxY)
        let speaker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker.")).firstMatch
        speaker.tap()
        app.buttons["speaker.choose.owner"].tap()
        let owned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "我"), object: speaker)
        XCTAssertEqual(XCTWaiter.wait(for: [owned], timeout: 10), .completed)
        XCTAssertTrue(text.exists)
        speaker.tap()
        app.buttons["这不是我"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "说话人 1"), object: speaker)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        XCTAssertTrue(text.exists)
        XCTAssertTrue(other.exists)
        attach(app, name: "continuous-speech-and-speaker-turns")
    }

    func testUnknownSpeakerCanBeCorrectedBesideTheTime() {
        let app = launch()
        latestWindow(app).tap()
        let speaker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker.")).firstMatch
        XCTAssertTrue(speaker.waitForExistence(timeout: 10))
        let span = String(speaker.identifier.dropFirst("transcript.speaker.".count))
        let time = app.staticTexts["transcript.time.\(span)"]
        let play = app.buttons["transcript.play.\(span)"]
        XCTAssertTrue(time.exists)
        XCTAssertGreaterThan(speaker.frame.minX, time.frame.maxX)
        XCTAssertEqual(speaker.frame.midY, time.frame.midY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(speaker.frame.height, 44)
        XCTAssertLessThanOrEqual(speaker.frame.maxX, play.frame.minX)
        XCTAssertEqual(speaker.value as? String, "说话人")
        attach(app, name: "speaker-beside-time-unknown")
        speaker.tap()
        XCTAssertTrue(app.buttons["speaker.choose.owner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["speaker.choose.owner"].isEnabled)
        attach(app, name: "speaker-unknown-actions-enabled")
        app.buttons["speaker.choose.owner"].tap()
        let owned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "我"), object: speaker)
        XCTAssertEqual(XCTWaiter.wait(for: [owned], timeout: 8), .completed)
        attach(app, name: "speaker-beside-time-confirmed")
        speaker.tap()
        app.buttons["这不是我"].tap()
        let unknown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "说话人 1"), object: speaker)
        XCTAssertEqual(XCTWaiter.wait(for: [unknown], timeout: 8), .completed)
        speaker.tap()
        app.buttons["speaker.new.add"].tap()
        let name = "来自项目讨论组的小林同事"
        XCTAssertTrue(app.textFields["speaker.new.name"].waitForExistence(timeout: 5))
        app.textFields["speaker.new.name"].tap()
        app.textFields["speaker.new.name"].typeText(name)
        XCTAssertEqual(app.textFields["speaker.new.name"].value as? String, name)
        attach(app, name: "speaker-name-before-save")
        XCTAssertTrue(app.buttons["speaker.new.save"].isHittable)
        app.buttons["speaker.new.save"].tap()
        attach(app, name: "speaker-name-after-save")
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: speaker)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 8), .completed, app.debugDescription)
        XCTAssertLessThanOrEqual(speaker.frame.maxX, play.frame.minX)
        XCTAssertTrue(play.isHittable)
        attach(app, name: "speaker-beside-time-long-name")
        speaker.tap()
        app.buttons["撤销标记"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "说话人 1"), object: speaker)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 8), .completed)
        speaker.tap()
        let known = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "speaker.choose.", name)).firstMatch
        XCTAssertTrue(known.waitForExistence(timeout: 5))
        attach(app, name: "speaker-picker-existing-person")
        known.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: speaker)], timeout: 8), .completed)
        app.tabBars.buttons["聊天"].tap()
        XCTAssertTrue(app.buttons["remote.settings"].waitForExistence(timeout: 10))
        app.buttons["remote.settings"].tap()
        let profiles = app.buttons["settings.speakers"]
        for _ in 0..<4 where !profiles.isHittable { app.swipeUp() }
        profiles.tap()
        XCTAssertTrue(app.navigationBars["人物与声纹"].waitForExistence(timeout: 5))
        attach(app, name: "speaker-profiles")
        app.buttons["管理\(name)"].tap()
        app.buttons["改名"].tap()
        let field = app.textFields["speaker.rename.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: name.count) + "林同事")
        XCTAssertEqual(field.value as? String, "林同事")
        app.buttons["speaker.rename.save"].tap()
        XCTAssertTrue(app.staticTexts["林同事"].waitForExistence(timeout: 8), app.debugDescription)
        attach(app, name: "speaker-profile-renamed")
        app.buttons["管理林同事"].tap()
        app.buttons["删除人物与声纹"].tap()
        app.buttons["删除林同事"].tap()
        XCTAssertFalse(app.staticTexts["林同事"].waitForExistence(timeout: 2))
    }

    func testChronologicalTimelineStartsAtBottomAndKeepsEarlierPositionAfterRefreshAndTabSwitch() {
        let app = launch(timelineFixture: "scroll")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window."))
        let latest = rows.matching(NSPredicate(format: "label CONTAINS %@", "19:00")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 15))
        attach(app, name: "timeline-initial-position")
        XCTAssertTrue(latest.isHittable, "The newest record must be visible on entry.")
        let initialPager = app.scrollViews["timeline.dayPager"]
        XCTAssertEqual(initialPager.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(initialPager.frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(latest.frame.minX, initialPager.frame.minX + 24, accuracy: 1,
                       "The first page must align before any swipe.")
        XCTAssertEqual(latest.frame.maxX, initialPager.frame.maxX - 24, accuracy: 1)
        let dateBar = app.buttons["timeline.datePicker"]
        XCTAssertTrue(dateBar.isHittable)
        XCTAssertFalse(app.buttons["library.watchStatus"].exists)
        let pinnedY = dateBar.frame.minY
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "间隔约")).firstMatch.exists)
        attach(app, name: "timeline-latest-at-bottom")
        let earliest = rows.matching(NSPredicate(format: "label CONTAINS %@", "08:00")).firstMatch
        let pager = app.scrollViews["timeline.dayPager"]
        for _ in 0..<8 {
            if earliest.exists && earliest.isHittable { break }
            pager.swipeDown()
        }
        XCTAssertTrue(earliest.exists && earliest.isHittable, "Earlier times must be above the latest record.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "间隔约")).firstMatch.exists)
        // A hittable first row may still be partially clipped; finish reaching the top.
        pager.swipeDown()
        XCTAssertTrue(dateBar.isHittable)
        XCTAssertEqual(dateBar.frame.minY, pinnedY, accuracy: 1)
        let readingY = earliest.frame.minY - dateBar.frame.maxY
        assertPositionStays(earliest, below: dateBar, relativeY: readingY)
        pager.swipeDown() // Pull to refresh after reaching the oldest record.
        XCTAssertTrue(earliest.isHittable)
        // Compare the reading position inside the viewport after refresh.
        let stayed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            earliest.exists && earliest.isHittable && abs(earliest.frame.minY - dateBar.frame.maxY - readingY) < 4
        }, object: earliest)
        XCTAssertEqual(XCTWaiter.wait(for: [stayed], timeout: 8), .completed)
        assertPositionStays(earliest, below: dateBar, relativeY: readingY)
        XCTAssertEqual(dateBar.frame.minY, pinnedY, accuracy: 1)
        app.tabBars.buttons["聊天"].tap()
        app.tabBars.buttons["转录"].tap()
        XCTAssertTrue(earliest.isHittable, "Returning to the transcript tab must preserve manual reading.")
        attach(app, name: "timeline-earliest-position-preserved")
    }

    func testPagingBackToTodayKeepsTheLatestAndManualReadingPositions() {
        let app = launch(timelineFixture: "scroll")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window."))
        let latest = rows.matching(NSPredicate(format: "label CONTAINS %@", "19:00")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 15))
        attach(app, name: "today-initial-position")
        XCTAssertTrue(latest.isHittable)
        let pager = app.scrollViews["timeline.dayPager"]
        let date = app.buttons["timeline.datePicker"]
        let latestY = latest.frame.minY - date.frame.maxY
        for _ in 0..<2 {
            pager.swipeRight()
            wait(date, contains: "昨天")
            assertVisibleRowInsets(in: app)
            pager.swipeLeft()
            wait(date, contains: "今天")
            assertVisibleRowInsets(in: app)
            assertPositionStays(latest, below: date, relativeY: latestY)
        }
        let earliest = rows.matching(NSPredicate(format: "label CONTAINS %@", "08:00")).firstMatch
        for _ in 0..<8 {
            if earliest.exists && earliest.isHittable { break }
            pager.swipeDown()
        }
        pager.swipeDown()
        XCTAssertTrue(earliest.isHittable)
        let readingY = earliest.frame.minY - date.frame.maxY
        app.buttons["timeline.previousDay"].tap()
        wait(date, contains: "昨天")
        assertVisibleRowInsets(in: app)
        app.tabBars.buttons["聊天"].tap()
        app.tabBars.buttons["转录"].tap()
        assertVisibleRowInsets(in: app)
        app.buttons["timeline.nextDay"].tap()
        wait(date, contains: "今天")
        assertPositionStays(earliest, below: date, relativeY: readingY)
        attach(app, name: "today-keeps-manual-reading-after-paging")
    }

    private func assertVisibleRowInsets(in app: XCUIApplication) {
        let pager = app.scrollViews["timeline.dayPager"]
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window."))
        guard let row = rows.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("The selected day must show a transcript row.")
            return
        }
        XCTAssertEqual(row.frame.minX, pager.frame.minX + 24, accuracy: 1)
        XCTAssertEqual(row.frame.maxX, pager.frame.maxX - 24, accuracy: 1)
    }

    private func assertPositionStays(_ row: XCUIElement, below date: XCUIElement, relativeY: CGFloat) {
        XCTAssertTrue(row.exists)
        let jumped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard row.exists, date.exists else { return true }
            let frame = row.frame
            return frame.isEmpty || abs(frame.minY - date.frame.maxY - relativeY) > 6
        }, object: nil)
        jumped.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [jumped], timeout: 3), .completed,
            "A settled day must not move vertically during its asynchronous reload.")
    }

    func testDailyPagingAndNativeDatePickerKeepCompactStatusAvailable() {
        let app = launch()
        XCTAssertTrue(app.buttons["timeline.datePicker"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["timeline.datePicker"].label.contains("今天"))
        XCTAssertFalse(app.buttons["timeline.nextDay"].isEnabled)
        XCTAssertFalse(app.buttons["library.watchStatus"].exists)
        app.buttons["timeline.previousDay"].tap()
        wait(app.buttons["timeline.datePicker"], contains: "昨天")
        XCTAssertFalse(app.buttons["library.watchStatus"].exists)
        // Available text remains readable while an optional summary is unavailable.
        let yesterday = latestWindow(app)
        XCTAssertTrue(yesterday.waitForExistence(timeout: 5))
        yesterday.tap()
        XCTAssertTrue(app.navigationBars["转录详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "昨天讨论了这周的安排")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["转录详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        attach(app, name: "timeline-yesterday")
        app.buttons["timeline.nextDay"].tap()
        wait(app.buttons["timeline.datePicker"], contains: "今天")
        app.buttons["timeline.datePicker"].tap()
        XCTAssertTrue(app.navigationBars["选择日期"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["timeline.calendar"].exists)
        attach(app, name: "timeline-native-date-picker")
        app.buttons["昨天"].tap()
        wait(app.buttons["timeline.datePicker"], contains: "昨天")
        app.buttons["timeline.datePicker"].tap()
        app.buttons["取消"].tap()
        wait(app.buttons["timeline.datePicker"], contains: "昨天")
    }

    func testHorizontalSwipesChangeOnlyTheDay() {
        let app = launch()
        let date = app.buttons["timeline.datePicker"]
        XCTAssertTrue(date.waitForExistence(timeout: 15))
        app.scrollViews["timeline.dayPager"].swipeRight()
        wait(date, contains: "昨天")
        app.scrollViews["timeline.dayPager"].swipeLeft()
        wait(date, contains: "今天")
        XCTAssertTrue(latestWindow(app).isHittable)
    }

    func testMergedWindowDetailPlaybackWithoutMacConnection() {
        let app = launch()
        let row = latestWindow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["已转录"].exists)
        attach(app, name: "timeline-activity-today")
        row.tap()
        XCTAssertTrue(app.navigationBars["转录详情"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["timeline.detail.more"].exists)
        XCTAssertFalse(app.buttons["transcript.more.export"].exists)
        XCTAssertFalse(app.buttons["transcript.more.retention"].exists)
        XCTAssertFalse(app.buttons["recording.files.restore"].exists)
        attach(app, name: "timeline-detail-initial-layout")
        let first = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "第一段记录讨论了时间线")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let second = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "第二段记录接着讨论播放器")).firstMatch
        if !second.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(second.waitForExistence(timeout: 5), "Nearby speech from both capture sessions must be readable together.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "说话约")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["timeline.summary"].exists, "No configured API means no summary area.")
        let play = app.buttons["transcript.recording.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        wait(play, contains: "暂停回听")
        play.tap()
        wait(play, contains: "继续回听")
        attach(app, name: "timeline-multiple-recordings-detail")
        XCTAssertFalse(app.buttons["transcript.discuss"].isEnabled,
                       "This unpaired fixture can read and play recordings; discussion requires the remote Agent.")
        app.tabBars.buttons["聊天"].tap()
        XCTAssertTrue(app.buttons["remote.connect"].waitForExistence(timeout: 5))
    }

    func testShortContentAppearsAtItsTimeWithoutAnExpansionControl() {
        let app = launch()
        let pager = app.scrollViews["timeline.dayPager"]
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        let short = app.staticTexts["嗯"]
        for _ in 0..<8 {
            if short.exists && short.isHittable { break }
            pager.swipeDown()
        }
        XCTAssertTrue(short.exists && short.isHittable)
        XCTAssertFalse(app.buttons["timeline.scattered.toggle"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).count, 2,
                       "The short sentence has a normal time node; the punctuation-only interval has none.")
        XCTAssertFalse(app.staticTexts["……。"].exists)
        attach(app, name: "timeline-short-content-at-its-time")
        short.tap()
        XCTAssertTrue(app.navigationBars["转录详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["嗯"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transcript.recording.play"].exists)
        XCTAssertFalse(app.staticTexts["本机转写已就绪"].exists)
    }

    func testTimelineWithoutGeneratedImagesHasNoIllustrationControls() {
        let app = launch()
        XCTAssertFalse(app.buttons["timeline.journal"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "lifeIllustration.inline.")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["lifeIllustration.strip"].firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "lifeIllustration.stamp.")).firstMatch.exists)
    }

    private func launch(timelineFixture: String = "1") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = timelineFixture
        app.launchEnvironment["MOMO_UI_TEST_WATCH_STATUS"] = "recording"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        addTeardownBlock { app.terminate() }
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap()
            app.buttons["welcome.start"].tap()
            XCTAssertTrue(app.buttons["稍后配对"].waitForExistence(timeout: 5))
            app.buttons["稍后配对"].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["转录"].waitForExistence(timeout: 15))
        app.tabBars.buttons["转录"].tap()
        return app
    }
    private func latestWindow(_ app: XCUIApplication) -> XCUIElement {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        return rows.element(boundBy: rows.count - 1)
    }
    private func wait(_ element: XCUIElement, contains text: String) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 8), .completed)
    }
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
