import XCTest
import UIKit

@MainActor
final class PhonePlayerReducedMotionTests: XCTestCase {
    private var originalMotionValue: String?
    private var restoredMotion = false

    func testSystemReduceMotionKeepsTimelinePlaybackSeekAndMiniPlayerUsable() throws {
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let app = XCUIApplication()
        // Register before the first possible settings mutation. A failed assertion
        // must not leave the next test with a different system accessibility setting.
        addTeardownBlock { @MainActor in
            defer { app.terminate(); settings.terminate() }
            if let originalValue = self.originalMotionValue, !self.restoredMotion {
                do { try self.restore(originalValue, in: settings); self.restoredMotion = true }
                catch { XCTFail("Could not restore system Reduce Motion: \(error)") }
            }
        }
        defer {
            if app.state == .runningForeground { attach(app, name: "reduce-motion-player-final-state") }
            if let originalValue = originalMotionValue, !restoredMotion {
                do { try restore(originalValue, in: settings); restoredMotion = true }
                catch { XCTFail("Could not restore system Reduce Motion: \(error)") }
            }
        }

        let toggle = try openReduceMotion(in: settings)
        let originalValue = try switchValue(toggle)
        originalMotionValue = originalValue
        attach(settings, name: "reduce-motion-system-original-\(originalValue)")
        if originalValue == "0" { toggle.control.tap() }
        try wait("The real Settings switch must be enabled") { toggle.hasValue("1") }
        try wait("UIKit must observe the real system setting") { UIAccessibility.isReduceMotionEnabled }
        attach(settings, name: "reduce-motion-system-enabled")

        let runID = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "1"
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        let evidence = XCTAttachment(string: "runID=\(runID); originalSettingsSwitch=\(originalValue); system Reduce Motion enabled through com.apple.Preferences UI and confirmed by public UIKit getter; formal timeline fixture, no ASR/provider/network flags or SwiftUI environment override")
        evidence.name = "reduce-motion-system-and-fixture"
        evidence.lifetime = .keepAlways; add(evidence)

        let library = app.tabBars.buttons["转录"]
        try wait("Library entry") { library.exists && library.isHittable }
        library.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        try wait("Timeline row") { row.exists && row.isHittable }
        row.tap()
        let source = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                         "transcript.text.", "第一段记录讨论了时间线")).firstMatch
        try wait("Official timeline source") { source.exists }
        let sourceID = source.identifier, sourceText = source.label
        let play = app.buttons["transcript.recording.play"]
        let seek = app.descendants(matching: .any).matching(identifier: "transcript.recording.play.seek").firstMatch
        try wait("Native playback ready") { play.exists && play.isHittable && play.isEnabled }
        play.tap()
        try wait("Real audio playing") { play.label == "暂停回听" && play.isEnabled }
        play.tap()
        try wait("Real audio paused") { play.label == "继续回听" && play.isEnabled }
        let before = try times(seek)
        assertReachable(seek, in: app)
        attach(app, name: "reduce-motion-player-paused")

        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        try wait("A real waveform drag seeks while remaining paused") {
            (seek.value as? String) != before.value && play.label == "继续回听" && play.isEnabled
        }
        let sought = try times(seek)
        XCTAssertGreaterThan(sought.current, before.current)
        XCTAssertEqual(sought.total, before.total)
        XCTAssertEqual(Double(sought.current), Double(sought.total) * 0.5, accuracy: 1.5,
                       "The real audio position must follow the gesture's midpoint, allowing displayed whole seconds.")
        play.tap()
        try wait("Resume advances the native audio clock") {
            play.label == "暂停回听" && play.isEnabled && (seek.value as? String) != sought.value
        }
        play.tap()
        try wait("Playback pauses after real clock advancement") { play.label == "继续回听" && play.isEnabled }
        let paused = try times(seek)
        XCTAssertGreaterThan(paused.current, sought.current)
        XCTAssertEqual(paused.total, before.total)
        XCTAssertFalse(app.staticTexts["transcript.recording.play.failure"].exists)
        XCTAssertTrue(UIAccessibility.isReduceMotionEnabled)
        attach(app, name: "reduce-motion-player-seek-and-resume")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let mini = app.buttons["playback.mini.open"]
        try wait("Paused target remains in the mini player") { mini.exists && mini.isHittable }
        XCTAssertEqual(app.buttons["playback.mini.toggle"].label, "继续回听")
        attach(app, name: "reduce-motion-mini-same-paused-target")
        mini.tap()
        let restoredSource = app.staticTexts[sourceID]
        try wait("Mini player opens its actual source") { restoredSource.exists }
        XCTAssertEqual(restoredSource.label, sourceText)
        XCTAssertEqual(play.label, "继续回听")
        XCTAssertEqual(try times(seek), paused)
        XCTAssertTrue(UIAccessibility.isReduceMotionEnabled)
        attach(app, name: "reduce-motion-player-source-preserved")

        let stillEnabled = try openReduceMotion(in: settings)
        XCTAssertEqual(try switchValue(stillEnabled), "1", "The actual system setting must stay enabled throughout playback.")
        attach(settings, name: "reduce-motion-system-after-player")
        try restore(originalValue, in: settings)
        restoredMotion = true
    }

    private func openReduceMotion(in settings: XCUIApplication) throws -> MotionSwitch {
        settings.activate()
        attach(settings, name: "reduce-motion-settings-entry")
        // These visible labels are verified in the iOS 27 runtime's
        // AccessibilitySettings.bundle/{en,zh_CN}.lproj/Accessibility.strings.
        let toggle = settings.switches.matching(NSPredicate(format: "label IN %@", ["Reduce Motion", "减弱动态效果"])).firstMatch
        let motionPage = settings.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", ["Motion", "动态效果"], ["Motion", "动态效果"])).firstMatch
        if motionPage.exists && toggle.exists && toggle.isHittable { return try motionSwitch(in: toggle) }
        func isRoot() -> Bool {
            // iOS 27 keeps the large Settings title outside the root navigation bar.
            settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["Settings", "设置"])).firstMatch.exists
                && settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["General", "通用"])).firstMatch.exists
        }
        for _ in 0..<8 {
            if isRoot() { break }
            let bar = settings.navigationBars.firstMatch
            try wait("An actual Settings navigation bar") { bar.exists }
            let previousTitle = bar.identifier
            let back = bar.buttons.element(boundBy: 0)
            try wait("The visible Settings back button") { back.exists && back.isHittable && back.isEnabled }
            back.tap()
            try wait("Settings back navigation completes") { isRoot() || settings.navigationBars.firstMatch.identifier != previousTitle }
        }
        try wait("Settings root") { isRoot() }
        try openRow(["Accessibility", "辅助功能", "无障碍"], in: settings)
        try wait("Accessibility page") {
            settings.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", ["Accessibility", "辅助功能", "无障碍"], ["Accessibility", "辅助功能", "无障碍"])).firstMatch.exists
        }
        try openRow(["Motion", "动态效果"], in: settings)
        try wait("The actual Motion page and Reduce Motion switch") {
            motionPage.exists && toggle.exists && toggle.isHittable && toggle.isEnabled
        }
        return try motionSwitch(in: toggle)
    }

    private func openRow(_ labels: [String], in settings: XCUIApplication) throws {
        let row = settings.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        // The Settings app may preserve its previous scroll position. Only real
        // UI scrolling is used; no private Settings URL or preferences mutation.
        for direction in [true, false] {
            for _ in 0..<8 {
                if row.exists && row.isHittable { row.tap(); return }
                if direction { settings.swipeUp() } else { settings.swipeDown() }
            }
        }
        attach(settings, name: "reduce-motion-settings-row-unavailable")
        throw TestFailure.unavailableSettingsRow(labels.joined(separator: "/"))
    }

    @MainActor
    private struct MotionSwitch {
        let group: XCUIElement
        let control: XCUIElement

        func hasValue(_ value: String) -> Bool {
            (group.value as? String) == value && (control.value as? String) == value
        }
    }

    private func motionSwitch(in group: XCUIElement) throws -> MotionSwitch {
        // iOS 27 exposes the labelled row as a composite Switch. Its centre is
        // empty space; only its unique direct child is the actual native control.
        let controls = group.children(matching: .switch)
        guard controls.count == 1 else { throw TestFailure.condition("Exactly one direct native Reduce Motion switch") }
        let control = controls.element(boundBy: 0)
        try wait("The actual native Reduce Motion control is reachable") {
            control.exists && control.isHittable && control.isEnabled
        }
        return MotionSwitch(group: group, control: control)
    }

    private func switchValue(_ toggle: MotionSwitch) throws -> String {
        let value = try XCTUnwrap(toggle.group.value as? String)
        guard (value == "0" || value == "1"), toggle.hasValue(value) else {
            throw TestFailure.invalidSwitchValue("group=\(value), control=\(String(describing: toggle.control.value))")
        }
        return value
    }

    private func restore(_ value: String, in settings: XCUIApplication) throws {
        let toggle = try openReduceMotion(in: settings)
        if try switchValue(toggle) != value { toggle.control.tap() }
        try wait("Restore the actual original Settings switch") { toggle.hasValue(value) }
        try wait("UIKit observes the restored system value") { UIAccessibility.isReduceMotionEnabled == (value == "1") }
        attach(settings, name: "reduce-motion-system-restored-\(value)")
    }

    private struct PlayerTimes: Equatable {
        let value: String
        let current: Int
        let total: Int
    }

    private func times(_ element: XCUIElement) throws -> PlayerTimes {
        let value = try XCTUnwrap(element.value as? String)
        let parts = value.components(separatedBy: "，共 ")
        guard parts.count == 2 else { throw TestFailure.invalidTime(value) }
        func seconds(_ text: String) throws -> Int {
            let fields = try text.split(separator: ":", omittingEmptySubsequences: false).map {
                guard let value = Int($0) else { throw TestFailure.invalidTime(text) }
                return value
            }
            guard (2...3).contains(fields.count), fields.allSatisfy({ $0 >= 0 }),
                  fields.suffix(2).allSatisfy({ $0 < 60 }) else { throw TestFailure.invalidTime(text) }
            return fields.reduce(0) { $0 * 60 + $1 }
        }
        return try PlayerTimes(value: value, current: seconds(parts[0]), total: seconds(parts[1]))
    }

    private func assertReachable(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.isHittable)
        let visible = element.frame.intersection(app.frame)
        XCTAssertGreaterThanOrEqual(visible.width + 0.000001, 44)
        XCTAssertGreaterThanOrEqual(visible.height + 0.000001, 44)
    }

    private func wait(_ description: String, condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 15) == .completed else {
            throw TestFailure.condition(description)
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private enum TestFailure: Error {
        case unavailableSettingsRow(String), invalidSwitchValue(String), invalidTime(String), condition(String)
    }
}
