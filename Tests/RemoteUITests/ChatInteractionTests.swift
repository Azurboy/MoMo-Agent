import XCTest
import UIKit

@MainActor final class ChatInteractionTests: XCTestCase {
    func testVoiceInputKeepsDraftWhenCancelledOrLeavingChat() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = "5F12C378-A804-4E20-A46D-213FE37495AB"
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "chat"
        app.launchEnvironment["MOMO_UI_TEST_AVATAR_UNAVAILABLE"] = "1"
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        defer { app.terminate() }
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) { app.buttons["welcome.skip"].tap() }
        if app.buttons["welcome.start"].waitForExistence(timeout: 5) { app.buttons["welcome.start"].tap() }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 5) { app.buttons["onboarding.finish"].tap() }
        let input = app.textFields["remote.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 30), app.debugDescription)
        input.tap(); input.typeText("Keep this draft")
        let start = app.buttons["assistant.voice.start"]
        let cancel = app.buttons["assistant.voice.cancel"]
        let finish = app.buttons["assistant.voice.finish"]
        XCTAssertGreaterThanOrEqual(start.frame.width, 44)
        capture(app, "Voice input beside the editable draft")

        start.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(finish.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["remote.send"].exists)
        XCTAssertFalse(input.exists, "Keep the existing draft out of the recording panel.")
        capture(app, "Recording panel with draft hidden")
        cancel.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep this draft")

        start.tap()
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        app.buttons["remote.settings"].tap()
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(cancel.exists)
        XCTAssertEqual(input.value as? String, "Keep this draft")

        start.tap()
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(cancel.exists)
        XCTAssertEqual(input.value as? String, "Keep this draft")
        capture(app, "Draft retained after backgrounding")

        app.terminate()
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let deny = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允许"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 5), springboard.debugDescription)
        deny.tap()
        XCTAssertTrue(app.buttons["打开设置"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep this draft")
        XCTAssertFalse(finish.exists)
        capture(app, "Microphone permission denial preserves the draft")
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:19277/test/status")!)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(receipt["submission_attempts"] as? Int, 0, "Dictation must not submit a message.")
    }

    func testChatDeliveryKeyboardAndDesktopHandoff() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = "5F12C378-A804-4E20-A46D-213FE37495AB"
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "chat"
        app.launchEnvironment["MOMO_UI_TEST_AVATAR_UNAVAILABLE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.buttons["welcome.skip"].waitForExistence(timeout: 15) {
            app.buttons["welcome.skip"].tap()
            XCTAssertTrue(app.buttons["welcome.start"].waitForExistence(timeout: 10)); app.buttons["welcome.start"].tap()
        }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 15) { app.buttons["onboarding.finish"].tap() }
        let input = app.textFields["remote.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 30), app.debugDescription)
        let avatar = app.buttons["personalAgent.avatar"]
        XCTAssertEqual(app.buttons.matching(identifier: "personalAgent.avatar").count, 1)
        XCTAssertEqual(avatar.frame.width, 144, accuracy: 1)
        XCTAssertGreaterThan(avatar.frame.midY, app.buttons["remote.settings"].frame.midY + 80)
        XCTAssertGreaterThan(try darkFraction(avatar.screenshot().image), 0.025, "Native MoMo must be visible when WebKit is unavailable")
        capture(app, "Large centered native MoMo before the first message")
        XCTAssertFalse(app.buttons["remote.memories"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["remote.status"].exists)
        input.tap(); input.typeText("发送失败测试")
        app.buttons["remote.send"].tap()
        let retry = app.buttons["发送失败，点击重试"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "Message failure beside retained outgoing bubble")
        retry.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "消息已收到")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(app.staticTexts["助理正在回复"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["remote.status"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "处理好了")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "personalAgent.avatar").count, 1)
        XCTAssertEqual(avatar.frame.width, 84, accuracy: 1)
        XCTAssertEqual(avatar.frame.midX, app.frame.midX, accuracy: 3)
        XCTAssertLessThan(abs(avatar.frame.midY - app.buttons["remote.settings"].frame.midY), 20)
        XCTAssertGreaterThan(try darkFraction(avatar.screenshot().image), 0.025)
        if #available(iOS 26, *) {
            let viewport = app.webViews["assistant.transcript"].firstMatch
            XCTAssertLessThan(viewport.frame.minY, app.staticTexts["personalAgent.name"].frame.maxY)
        }
        capture(app, "Aligned compact native MoMo after the first reply")
        capture(app, "Completed conversation bubbles without progress")
        input.tap(); input.typeText("保留这个草稿")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let transcript = app.descendants(matching: .any)["assistant.transcript"].firstMatch
        XCTAssertTrue(transcript.exists)
        transcript.swipeDown()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in !app.keyboards.firstMatch.exists }, object: nil)], timeout: 5)
        XCTAssertEqual(input.value as? String, "保留这个草稿")
        capture(app, "Keyboard dismissed with draft retained")
        app.buttons["remote.settings"].tap()
        XCTAssertTrue(app.buttons["settings.mac"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["settings.memories"].exists)
        capture(app, "Settings without duplicate memory entry")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["remote.desktop"].tap()
        let control = app.buttons["desktop.takeControl"]
        XCTAssertTrue(control.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["desktop.preview"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "Desktop preview before taking control")
        control.tap()
        let state = app.staticTexts["desktop.controlState"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in state.label.contains("你正在控制") }, object: nil)], timeout: 10)
        app.descendants(matching: .any)["desktop.preview"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try await Task.sleep(for: .milliseconds(500))
        control.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in state.label.contains("MoMo 使用中") }, object: nil)], timeout: 10)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:19277/test/status")!)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(receipt["submission_attempts"] as? Int, 2)
        XCTAssertEqual(receipt["unique_operations"] as? Int, 1)
        XCTAssertGreaterThan(receipt["input_count"] as? Int ?? 0, 0)
        XCTAssertEqual(receipt["owner"] as? String, "agent")
        capture(app, "Human control explicitly returned to agent")
        app.buttons["关闭"].firstMatch.tap()
    }
    private func darkFraction(_ image: UIImage) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let dark = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 90 && bytes[$0 + 1] < 90 && bytes[$0 + 2] < 90 && bytes[$0 + 3] > 200 }.count
        return Double(dark) / Double(width * height)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
