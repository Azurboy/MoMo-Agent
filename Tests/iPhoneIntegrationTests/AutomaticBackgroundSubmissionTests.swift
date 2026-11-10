import XCTest
import MoMoArchive
import MoMoSpeech
@testable import MoMoAgent

@MainActor
final class AutomaticBackgroundSubmissionTests: XCTestCase {
    func testCPUBackgroundContinuesUntilCriticalHeatAndPreservesLowPowerPolicy() {
        let background = PhoneBackgroundTasks { throw BackgroundTranscriptionError.runtimeUnavailable }
        XCTAssertEqual(background.policy, .cpu)
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious] {
            XCTAssertTrue(PhoneBackgroundTasks.allowsProcessing(lowPower: false, thermalState: state))
            XCTAssertFalse(PhoneBackgroundTasks.allowsProcessing(lowPower: true, thermalState: state))
            XCTAssertNil(PhoneBackgroundTasks.processingConstraint(foreground: true, lowPower: true, thermalState: state))
            XCTAssertEqual(PhoneBackgroundTasks.processingConstraint(foreground: false, lowPower: true, thermalState: state), .lowPower)
        }
        XCTAssertFalse(PhoneBackgroundTasks.allowsProcessing(lowPower: false, thermalState: .critical))
        XCTAssertFalse(PhoneBackgroundTasks.allowsProcessing(lowPower: true, thermalState: .critical))
        XCTAssertEqual(PhoneBackgroundTasks.processingConstraint(foreground: true, lowPower: false, thermalState: .critical), .thermalPressure)
        XCTAssertEqual(PhoneBackgroundTasks.processingConstraint(foreground: true, lowPower: true, thermalState: .critical), .thermalPressure)
    }

    func testResourceReasonExplainsHistoryDeferralWithoutRelabelingActiveWork() {
        XCTAssertEqual(PhoneBackgroundTasks.processingConstraint(lowPower: false, thermalState: .critical), .thermalPressure)
        XCTAssertEqual(PhoneBackgroundTasks.processingConstraint(lowPower: true, thermalState: .critical), .thermalPressure)
        XCTAssertEqual(PhoneBackgroundTasks.processingConstraint(lowPower: true, thermalState: .serious), .lowPower)
        XCTAssertNil(PhoneBackgroundTasks.processingConstraint(lowPower: false, thermalState: .serious))
        XCTAssertEqual(PhoneBackgroundTasks.processingConstraint(lowPower: true, thermalState: .nominal), .lowPower)
        XCTAssertNil(PhoneBackgroundTasks.processingConstraint(lowPower: false, thermalState: .fair))
        var snapshot = MoMoAgent.TranscriptionSnapshot(phase: .queued, userPaused: false, activeSessionID: nil,
            completedWindows: 0, failureCode: nil, execution: nil, batch: nil, nativeInFlight: false)
        snapshot.historicalResourceConstraint = .thermalPressure
        XCTAssertEqual(TimelinePresentation.resourceExplanation(snapshot), "手机温度过高，历史录音将在降温后自动继续整理")
        snapshot.historicalResourceConstraint = .lowPower
        XCTAssertEqual(TimelinePresentation.resourceExplanation(snapshot), "低电量模式已开启，历史录音将在关闭后自动继续整理")
        snapshot.historicalResourceConstraint = nil
        XCTAssertNil(TimelinePresentation.resourceExplanation(snapshot))
        let active = MoMoAgent.TranscriptionSnapshot(phase: .transcribing, userPaused: false, activeSessionID: UUID(),
            completedWindows: 0, failureCode: nil, execution: nil, batch: nil, nativeInFlight: true,
            historicalResourceConstraint: .thermalPressure)
        XCTAssertNil(TimelinePresentation.resourceExplanation(active))
    }

    func testCoolingClearsTheReasonAndPreservesAnExplicitUserPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoResourceRecovery-\(UUID())").standardizedFileURL
        addTeardownBlock { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let directory = try XCTUnwrap(Bundle.main.url(forResource: "Speech", withExtension: nil))
        let speech = try SpeechEngine(bundle: SpeechModelBundle.load(from: directory), configuration: SpeechConfiguration(),
            recognitionBackend: .sherpaCoreML)
        let coordinator = try MoMoAgent.TranscriptionCoordinator(archive: archive, speech: speech, startSuspended: false)
        await coordinator.setHistoricalWorkAllowed(false, constraint: .thermalPressure)
        let hot = await coordinator.snapshot()
        XCTAssertEqual(hot.historicalResourceConstraint, .thermalPressure)
        await coordinator.setHistoricalWorkAllowed(true)
        let cooled = await coordinator.runUntilIdle()
        XCTAssertNil(cooled.snapshot.historicalResourceConstraint)
        XCTAssertEqual(cooled.snapshot.phase, .idle)
        try await coordinator.pauseByUser()
        await coordinator.setHistoricalWorkAllowed(false, constraint: .thermalPressure)
        await coordinator.setHistoricalWorkAllowed(true)
        let paused = await coordinator.snapshot()
        XCTAssertTrue(paused.userPaused)
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertNil(paused.historicalResourceConstraint)
    }

    func testLateSubmissionIsCancelledBeforeAResumedRequestUsesTheSameIdentifier() async throws {
        let submitting = expectation(description: "First system submission started")
        let gate = SubmissionGate(entered: submitting)
        var cancellations = 0
        var failures = 0
        let submission = AutomaticBackgroundSubmission(eligible: { true }, submit: { await gate.submit() },
            cancel: { cancellations += 1 }, failure: { failures += 1 })
        let first = Task { await submission.request() }
        await fulfillment(of: [submitting], timeout: 5)
        submission.cancelByUser()
        XCTAssertEqual(cancellations, 1)
        // A new request waits behind the old API call, which can finish after cancellation.
        await submission.request()
        let before = await gate.calls
        XCTAssertEqual(before, 1)
        await gate.finishFirst()
        await first.value
        let after = await gate.calls
        XCTAssertEqual(after, 2)
        XCTAssertEqual(cancellations, 2)
        XCTAssertEqual(failures, 0)
    }

    func testCancellationDuringEligibilityPreventsSubmission() async throws {
        let preparing = expectation(description: "Eligibility pending")
        let gate = SubmissionGate(entered: preparing)
        var cancellations = 0
        let submission = AutomaticBackgroundSubmission(eligible: { await gate.submit(); return true }, submit: {
            XCTFail("The cancelled request must not be submitted")
        }, cancel: { cancellations += 1 }, failure: { XCTFail("Cancellation is not a scheduler failure") })
        let first = Task { await submission.request() }
        await fulfillment(of: [preparing], timeout: 5)
        submission.cancelByUser()
        await gate.finishFirst()
        await first.value
        XCTAssertEqual(cancellations, 1)
    }

    func testReverifiesPendingSubmissionAfterCooldownWithoutSpammingWithinWindow() async {
        var now = 100.0
        let counter = SubmissionCounter()
        let submission = AutomaticBackgroundSubmission(
            eligible: { true },
            submit: { await counter.increment() },
            cancel: {},
            failure: { XCTFail("Unexpected failure") },
            uptime: { now }
        )
        await submission.request()
        let firstCount = await counter.value
        XCTAssertEqual(firstCount, 1)
        now = 130.0
        await submission.request()
        let withinCooldownCount = await counter.value
        XCTAssertEqual(withinCooldownCount, 1, "Requests within 60s must reuse verified pending state")
        now = 165.0
        await submission.request()
        let afterCooldownCount = await counter.value
        XCTAssertEqual(afterCooldownCount, 2, "Requests after 60s must re-verify scheduler state in case iOS dropped the BGTaskRequest")
    }
}

private actor SubmissionCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor SubmissionGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    func submit() async {
        calls += 1
        guard calls == 1 else { return }
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func finishFirst() { continuation?.resume(); continuation = nil }
}
