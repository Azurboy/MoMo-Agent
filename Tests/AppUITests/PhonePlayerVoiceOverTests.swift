import XCTest

@MainActor
final class PhonePlayerVoiceOverTests: XCTestCase {
    func testVoiceOverSwipesAdjustPausedTimelineAudioAndSpeakBothTimes() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("The public XCUIVoiceOverService requires iOS 27 or later.")
        }
        continueAfterFailure = false
        let voiceOver = XCUIDevice.shared.voiceOverService
        let initiallyEnabled = voiceOver.isEnabled
        let app = XCUIApplication()
        var utterances: [String] = []
        // Teardown also covers an XCTest assertion that aborts before Swift unwinds.
        addTeardownBlock { @MainActor in
            defer { app.terminate() }
            self.restoreVoiceOver(voiceOver, enabled: initiallyEnabled)
        }
        defer {
            let speech = XCTAttachment(string: utterances.joined(separator: "\n"))
            speech.name = "player-voiceover-actual-utterances"
            speech.lifetime = .keepAlways
            add(speech)
            attach(app, name: "player-voiceover-final-state")
            restoreVoiceOver(voiceOver, enabled: initiallyEnabled)
        }
        if initiallyEnabled { try voiceOver.disable() }

        let runID = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let isolation = XCTAttachment(string: "runID=\(runID); initiallyVoiceOverEnabled=\(initiallyEnabled); official timeline fixture; no ASR, provider configuration or network flags; real VoiceOver service and one-finger gestures")
        isolation.name = "player-voiceover-isolation"
        isolation.lifetime = .keepAlways
        add(isolation)

        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap()
            app.buttons["welcome.start"].tap()
            wait("Defer initial pairing") { app.buttons["稍后配对"].exists }
            app.buttons["稍后配对"].tap()
        }
        let library = app.tabBars.buttons["转录"]
        wait("Library entry") { library.exists && library.isHittable }
        library.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window."))
        wait("Timeline populated") { rows.firstMatch.exists }
        let row = rows.element(boundBy: rows.count - 1)
        wait("Timeline row") { row.exists && row.isHittable }
        row.tap()
        let source = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                         "transcript.text.", "第一段记录讨论了时间线")).firstMatch
        wait("Real fixture transcript") { source.exists }
        let sourceID = source.identifier, sourceText = source.label
        let play = app.buttons["transcript.recording.play"]
        let progress = app.descendants(matching: .any).matching(identifier: "transcript.recording.play.seek").firstMatch
        wait("Native playback ready") { play.exists && play.isHittable && play.isEnabled }
        play.tap()
        wait("Native player is playing") { play.label == "暂停回听" && play.isEnabled }
        play.tap()
        wait("Native player is paused") { play.label == "继续回听" && play.isEnabled }
        let before = try times(progress)
        XCTAssertGreaterThan(before.total, before.current + 1, "The gesture must have an available forward position.")
        XCTAssertEqual(progress.label, "整段原音播放进度")
        assertReachable(progress, in: app)
        attach(app, name: "player-voiceover-before-enable")

        try voiceOver.enable()
        XCTAssertTrue(voiceOver.isEnabled, "Supported devices must enable real VoiceOver; failure is not a skip.")
        var spoken = try voiceOver.currentSpeech().utterance
        utterances.append("enabled: \(spoken)")
        for index in 0..<40 where !spoken.contains("整段原音播放进度") {
            spoken = try voiceOver.moveForward().utterance
            utterances.append("focus[\(index)]: \(spoken)")
        }
        XCTAssertTrue(spoken.contains("整段原音播放进度"), "VoiceOver must actually focus the adjustable waveform.")
        try assertSpokenTimes(before, service: voiceOver, utterances: &utterances)
        assertReachable(progress, in: app)
        attach(app, name: "player-voiceover-adjustable-focus")

        // These are physical single-finger VoiceOver adjustment gestures, not slider test APIs.
        app.swipeUp()
        wait("VoiceOver increment reaches the paused native player") {
            (progress.value as? String) != before.value && play.label == "继续回听" && play.isEnabled
        }
        let incremented = try times(progress)
        XCTAssertGreaterThan(incremented.current, before.current)
        XCTAssertEqual(incremented.total, before.total)
        try assertSpokenTimes(incremented, service: voiceOver, utterances: &utterances)
        attach(app, name: "player-voiceover-incremented-paused")

        app.swipeDown()
        wait("VoiceOver decrement reaches the paused native player") {
            (progress.value as? String) != incremented.value && play.label == "继续回听" && play.isEnabled
        }
        let decremented = try times(progress)
        XCTAssertLessThan(decremented.current, incremented.current)
        XCTAssertEqual(decremented.total, before.total)
        try assertSpokenTimes(decremented, service: voiceOver, utterances: &utterances)
        XCTAssertTrue(voiceOver.isEnabled)
        XCTAssertFalse(app.staticTexts["transcript.recording.play.failure"].exists)
        assertReachable(progress, in: app)
        attach(app, name: "player-voiceover-decremented-paused")

        // Follow the real active target back through the mini player, rather than assuming
        // that an unchanged detail card proves playback kept the same source.
        try voiceOver.disable()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let mini = app.buttons["playback.mini.open"]
        wait("The same paused target survives navigation") { mini.exists && mini.isHittable }
        XCTAssertEqual(app.buttons["playback.mini.toggle"].label, "继续回听")
        mini.tap()
        let restoredSource = app.staticTexts[sourceID]
        wait("The active player opens its original timeline source") { restoredSource.exists }
        XCTAssertEqual(restoredSource.label, sourceText)
        XCTAssertEqual(play.label, "继续回听")
        XCTAssertEqual(try times(progress), decremented, "Navigation must neither seek nor start paused audio.")
    }

    @available(iOS 27.0, *)
    private func restoreVoiceOver(_ service: XCUIVoiceOverService, enabled: Bool) {
        do {
            if service.isEnabled != enabled {
                if enabled { try service.enable() } else { try service.disable() }
            }
            XCTAssertEqual(service.isEnabled, enabled, "Restore the original system VoiceOver state.")
        } catch { XCTFail("Could not restore the original VoiceOver state: \(error)") }
    }

    @available(iOS 27.0, *)
    private func assertSpokenTimes(_ expected: PlayerTimes, service: XCUIVoiceOverService,
                                  utterances: inout [String]) throws {
        var speech = ""
        var speechError: Error?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            do {
                speech = try service.currentSpeech().utterance
                return speech.contains(expected.currentText) && speech.contains(expected.totalText) && speech.contains("共")
            } catch { speechError = error; return true }
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        utterances.append("value[\(expected.value)]: \(speech)")
        if let speechError { throw speechError }
        XCTAssertEqual(result, .completed, "Actual VoiceOver speech must contain current and total time: \(speech)")
    }

    private struct PlayerTimes: Equatable {
        let value: String
        let currentText: String
        let totalText: String
        let current: Int
        let total: Int
    }

    private func times(_ element: XCUIElement) throws -> PlayerTimes {
        let value = try XCTUnwrap(element.value as? String)
        let parts = value.components(separatedBy: "，共 ")
        XCTAssertEqual(parts.count, 2, "Expected actual current/total playback time, got \(value)")
        guard parts.count == 2 else { throw ValueError.invalidTime }
        func seconds(_ text: String) throws -> Int {
            let fields = try text.split(separator: ":", omittingEmptySubsequences: false).map {
                guard let value = Int($0) else { throw ValueError.invalidTime }
                return value
            }
            guard (2...3).contains(fields.count), fields.allSatisfy({ $0 >= 0 }),
                  fields.suffix(2).allSatisfy({ $0 < 60 }) else { throw ValueError.invalidTime }
            return fields.reduce(0) { $0 * 60 + $1 }
        }
        return try PlayerTimes(value: value, currentText: parts[0], totalText: parts[1],
                               current: seconds(parts[0]), total: seconds(parts[1]))
    }

    private func assertReachable(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.isHittable)
        let visible = element.frame.intersection(app.frame)
        XCTAssertGreaterThanOrEqual(visible.width + 0.000001, 44)
        XCTAssertGreaterThanOrEqual(visible.height + 0.000001, 44)
    }

    private func wait(_ description: String, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, description)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private enum ValueError: Error { case invalidTime }
}
