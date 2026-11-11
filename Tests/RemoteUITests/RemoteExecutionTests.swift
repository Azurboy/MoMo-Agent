import XCTest

@MainActor
final class RemoteExecutionTests: XCTestCase {
    func testRecordingMemoryAndTaskSurvivePhoneTermination() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = "F33D4EAE-9622-40DE-B23F-A6FDE416A074"
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "remote"
        app.launch()
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap(); app.buttons["welcome.start"].tap()
            XCTAssertTrue(app.buttons["onboarding.finish"].waitForExistence(timeout: 25), app.debugDescription)
            app.buttons["onboarding.finish"].tap()
        }
        let input = app.textFields["remote.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 45), app.debugDescription)
        app.buttons["remote.settings"].tap()
        app.buttons["settings.mac"].tap()
        app.buttons["remote.connectionDetails"].tap()
        let route = app.descendants(matching: .any)["remote.networkRoute"].firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in
            route.label.contains("WebRTC") || (route.value as? String)?.contains("WebRTC") == true
        }, object: nil)], timeout: 30)
        capture(app, "Native WebRTC data channel connected")
        app.navigationBars["网络详情"].buttons["BackButton"].tap()
        app.navigationBars["配对"].buttons["BackButton"].tap()
        if app.buttons["完成"].firstMatch.exists { app.buttons["完成"].firstMatch.tap() }
        let memory = app.tabBars.buttons["记忆"]
        XCTAssertTrue(memory.waitForExistence(timeout: 10)); memory.tap()
        let memoryText = app.staticTexts["remote.memoryText"].firstMatch
        XCTAssertTrue(memoryText.waitForExistence(timeout: 100), app.debugDescription)
        XCTAssertTrue(memoryText.label.contains("小林"))
        capture(app, "Mac organized recording memory")
        app.tabBars.buttons["聊天"].tap()
        input.tap(); input.typeText("请根据录音整理要给小林的方案，在 Mac 保存草稿。")
        app.buttons["remote.send"].tap()
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["remote.status"].exists)
        capture(app, "Conversation waiting without task progress")
        var release = URLRequest(url: URL(string: "http://127.0.0.1:18777/test/reply-ready")!)
        release.httpMethod = "POST"; release.httpBody = Data("{}".utf8)
        _ = try await URLSession.shared.data(for: release)
        let acknowledgement = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "我先读一下录音")).firstMatch
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 30), "The Mac model reply must reach the phone before completion")
        XCTAssertFalse(app.staticTexts["离开聊天不会停止 Mac 上的任务。"].exists)
        capture(app, "Actual acknowledgement without task details")
        XCUIDevice.shared.press(.home)
        app.terminate()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18777/test/phone-detached")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        _ = try await URLSession.shared.data(for: request)
        var completed = false
        for _ in 0..<45 {
            let (data,_) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18777/test/status")!)
            if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["artifact"] as? Bool == true { completed = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(completed, "Mac must create the real artifact while the phone process is absent")
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["remote.status"].exists)
        let output = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "方案草稿已保存在 Mac")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(acknowledgement.exists, "Keep the actual initial reply across relaunch")
        capture(app, "Same run restored with original recording citation")
        input.tap(); input.typeText("这是保留的草稿")
        app.terminate(); app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        XCTAssertEqual(input.value as? String, "这是保留的草稿")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
