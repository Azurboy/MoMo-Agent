import Foundation
import XCTest
@testable import MoMoAgent

/// Controlled scheduler callbacks verify production identity/admission; they do not simulate iOS scheduling.
@MainActor
final class ContinuedBackgroundSubmissionTests: XCTestCase {
    func testRejectingPendingWorkReturnsItsBatchOnceWithoutAffectingAnotherIdentifier() async throws {
        let harness = ContinuedSchedulerHarness(), batch = UUID()
        let submission = harness.makeSubmission()
        try await submission.request(batchID: batch)
        let identifier = try XCTUnwrap(harness.registered.first)
        XCTAssertNil(submission.cancelPending(identifier: identifier + ".stale"))
        XCTAssertEqual(submission.cancelPending(identifier: identifier), batch)
        XCTAssertNil(submission.cancelPending(identifier: identifier))
        XCTAssertEqual(harness.cancelled, [identifier])
    }

    func testConcreteRegistrationPrecedesSubmissionAndOnlyMatchingBatchCanLaunchOnce() async throws {
        let harness = ContinuedSchedulerHarness()
        let submission = harness.makeSubmission()
        let batch = UUID()
        try await submission.request(batchID: batch)
        let identifier = try XCTUnwrap(harness.registered.first)
        XCTAssertEqual(harness.events, ["register:" + identifier, "submit:" + identifier])
        XCTAssertTrue(identifier.hasPrefix(PhoneBackgroundTasks.continuedPrefix))
        XCTAssertFalse(identifier.contains("*"))
        XCTAssertNotNil(UUID(uuidString: String(identifier.dropFirst(PhoneBackgroundTasks.continuedPrefix.count))))
        XCTAssertNil(submission.activeBatchID(for: identifier))
        XCTAssertNil(submission.claim(identifier: identifier + ".stale"))
        XCTAssertEqual(submission.claim(identifier: identifier), batch)
        XCTAssertEqual(submission.activeBatchID(for: identifier), batch)
        XCTAssertNil(submission.activeBatchID(for: identifier + ".stale"))
        XCTAssertNil(submission.claim(identifier: identifier), "Duplicate delivery must not start a second execution")
        submission.complete(identifier: identifier + ".stale")
        await assertBusy(submission)
        submission.complete(identifier: identifier)
        XCTAssertNil(submission.activeBatchID(for: identifier))
        try await submission.request(batchID: UUID())
        XCTAssertEqual(Set(harness.registered).count, 2, "A completed registration must never be registered twice")
    }

    func testRejectedRegistrationNeverSubmitsAndRetryHasANewIdentifier() async throws {
        let harness = ContinuedSchedulerHarness()
        harness.registrationAccepted = false
        let submission = harness.makeSubmission()
        do { try await submission.request(batchID: UUID()); XCTFail("Registration must fail") }
        catch BackgroundTranscriptionError.registrationFailed { }
        XCTAssertTrue(harness.submitted.isEmpty)
        XCTAssertTrue(harness.cancelled.isEmpty)
        harness.registrationAccepted = true
        try await submission.request(batchID: UUID())
        XCTAssertEqual(Set(harness.registered).count, 2)
        XCTAssertEqual(harness.submitted, [harness.registered[1]])
    }

    func testSubmissionFailureCancelsOnlyItsRegisteredIdentifierAndReleasesPendingBatch() async throws {
        let harness = ContinuedSchedulerHarness()
        harness.failSubmission = true
        let submission = harness.makeSubmission()
        do { try await submission.request(batchID: UUID()); XCTFail("Submission must fail") }
        catch ContinuedSchedulerFailure.rejected { }
        let failed = try XCTUnwrap(harness.registered.first)
        XCTAssertEqual(harness.cancelled, [failed])
        XCTAssertNil(submission.claim(identifier: failed))
        harness.failSubmission = false
        try await submission.request(batchID: UUID())
        XCTAssertEqual(Set(harness.registered).count, 2)
        XCTAssertEqual(harness.submitted, harness.registered)
    }

    func testLateSuccessAfterCancellationCannotClearOrCancelNewBatch() async throws {
        try await checkLateReplyAfterCancellation(fails: false)
    }

    func testLateFailureAfterCancellationCannotClearOrCancelNewBatch() async throws {
        try await checkLateReplyAfterCancellation(fails: true)
    }

    func testSubmissionFailureAfterDeliveryWaitsForGrantStopBeforeNextAdmission() async throws {
        let entered = expectation(description: "System submission is awaiting its callback")
        let gate = ContinuedSubmissionGate(entered: entered)
        let harness = ContinuedSchedulerHarness()
        let submission = harness.makeSubmission(gate: gate)
        let batch = UUID()
        let request = Task { try await submission.request(batchID: batch) }
        await fulfillment(of: [entered], timeout: 5)
        let identifier = try XCTUnwrap(harness.registered.first)
        XCTAssertEqual(submission.claim(identifier: identifier), batch)
        await gate.finish(fails: true)
        do { try await request.value; XCTFail("The delayed scheduler error must propagate") }
        catch ContinuedSchedulerFailure.rejected { }
        XCTAssertEqual(harness.failedAfterLaunch, [identifier])
        XCTAssertEqual(harness.cancelled, [identifier])
        submission.cancelPending()
        await assertBusy(submission)
        // PhoneBackgroundTasks calls this only from TranscriptionTaskGrant completion, after its stop barrier.
        submission.complete(identifier: identifier)
        try await submission.request(batchID: UUID())
        XCTAssertEqual(Set(harness.registered).count, 2)
    }

    func testCompletionBeforeSubmitReplyCannotAffectNextBatch() async throws {
        let entered = expectation(description: "First submission awaiting callback")
        let gate = ContinuedSubmissionGate(entered: entered)
        let harness = ContinuedSchedulerHarness()
        let submission = harness.makeSubmission(gate: gate)
        let firstBatch = UUID()
        let first = Task { try await submission.request(batchID: firstBatch) }
        await fulfillment(of: [entered], timeout: 5)
        let old = try XCTUnwrap(harness.registered.first)
        XCTAssertEqual(submission.claim(identifier: old), firstBatch)
        submission.complete(identifier: old)
        let newBatch = UUID()
        try await submission.request(batchID: newBatch)
        let new = harness.registered[1]
        await gate.finish(fails: false)
        try await first.value
        XCTAssertEqual(harness.cancelled, [old])
        XCTAssertEqual(submission.claim(identifier: new), newBatch)
    }

    func testCancellationDoesNotReleaseAnActiveGrantBeforeItsCompletion() async throws {
        let harness = ContinuedSchedulerHarness()
        let submission = harness.makeSubmission()
        let batch = UUID()
        try await submission.request(batchID: batch)
        let identifier = try XCTUnwrap(harness.registered.first)
        XCTAssertEqual(submission.claim(identifier: identifier), batch)
        submission.cancelPending()
        XCTAssertTrue(harness.cancelled.isEmpty, "A delivered grant must stop through its persistent execution barrier")
        await assertBusy(submission)
        submission.complete(identifier: identifier)
        try await submission.request(batchID: UUID())
    }

    func testPendingAgeAndExplicitCancellationTrackingAvoidFalseFailureOnLateDelivery() async throws {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ContinuedSchedulerHarness()
        let submission = ContinuedBackgroundSubmission(
            prefix: PhoneBackgroundTasks.continuedPrefix,
            register: { id in harness.registered.append(id); return true },
            submit: { id in await MainActor.run { harness.submitted.append(id) } },
            cancel: { id in harness.cancelled.append(id) },
            failedAfterLaunch: { id in harness.failedAfterLaunch.append(id) },
            now: { currentTime }
        )
        let batch = UUID()
        try await submission.request(batchID: batch)
        let identifier = try XCTUnwrap(harness.registered.first)
        XCTAssertEqual(submission.pendingAge ?? -1, 0, accuracy: 0.001)
        currentTime.addTimeInterval(16)
        XCTAssertEqual(submission.pendingAge ?? -1, 16, accuracy: 0.001)
        XCTAssertFalse(submission.wasCancelled(identifier: identifier))
        XCTAssertTrue(submission.cancelPending(batchID: batch))
        XCTAssertTrue(submission.wasCancelled(identifier: identifier))
        XCTAssertFalse(submission.wasCancelled(identifier: identifier + ".unknown"))
        XCTAssertNil(submission.pendingAge)
    }

    private func checkLateReplyAfterCancellation(fails: Bool) async throws {
        let entered = expectation(description: "First submission awaiting callback")
        let gate = ContinuedSubmissionGate(entered: entered)
        let harness = ContinuedSchedulerHarness()
        let submission = harness.makeSubmission(gate: gate)
        let first = Task { try await submission.request(batchID: UUID()) }
        await fulfillment(of: [entered], timeout: 5)
        let old = try XCTUnwrap(harness.registered.first)
        submission.cancelPending(identifier: old + ".unrelated")
        await assertBusy(submission)
        submission.cancelPending()
        XCTAssertNil(submission.claim(identifier: old), "A cancelled handler must reject late delivery")
        let newBatch = UUID()
        try await submission.request(batchID: newBatch)
        let new = harness.registered[1]
        await gate.finish(fails: fails)
        do { try await first.value; XCTAssertFalse(fails) }
        catch ContinuedSchedulerFailure.rejected { XCTAssertTrue(fails) }
        XCTAssertEqual(harness.cancelled, [old, old])
        XCTAssertEqual(submission.claim(identifier: new), newBatch)
        XCTAssertTrue(harness.failedAfterLaunch.isEmpty)
    }

    private func assertBusy(_ submission: ContinuedBackgroundSubmission,
                            file: StaticString = #filePath, line: UInt = #line) async {
        do { try await submission.request(batchID: UUID()); XCTFail("Another batch must not be admitted", file: file, line: line) }
        catch BackgroundTranscriptionError.alreadyRequested { }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}

private enum ContinuedSchedulerFailure: Error { case rejected }

@MainActor
private final class ContinuedSchedulerHarness {
    var registrationAccepted = true
    var failSubmission = false
    var registered: [String] = []
    var submitted: [String] = []
    var cancelled: [String] = []
    var failedAfterLaunch: [String] = []
    var events: [String] = []

    func makeSubmission(gate: ContinuedSubmissionGate? = nil) -> ContinuedBackgroundSubmission {
        ContinuedBackgroundSubmission(prefix: PhoneBackgroundTasks.continuedPrefix, register: { identifier in
            self.registered.append(identifier)
            self.events.append("register:" + identifier)
            return self.registrationAccepted
        }, submit: { identifier in
            try await self.recordSubmission(identifier)
            try await gate?.submit()
        }, cancel: { self.cancelled.append($0) }, failedAfterLaunch: { self.failedAfterLaunch.append($0) })
    }

    private func recordSubmission(_ identifier: String) throws {
        submitted.append(identifier)
        events.append("submit:" + identifier)
        if failSubmission { throw ContinuedSchedulerFailure.rejected }
    }
}

private actor ContinuedSubmissionGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Error>?
    private var calls = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    func submit() async throws {
        calls += 1
        guard calls == 1 else { return }
        try await withCheckedThrowingContinuation { continuation = $0; entered.fulfill() }
    }
    func finish(fails: Bool) {
        if fails { continuation?.resume(throwing: ContinuedSchedulerFailure.rejected) }
        else { continuation?.resume() }
        continuation = nil
    }
}
