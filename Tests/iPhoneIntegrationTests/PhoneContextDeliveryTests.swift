import UIKit
import XCTest
@testable import MoMoAgent

@MainActor final class PhoneContextDeliveryTests: XCTestCase {
    func testSuccessfulPassCanKeepFutureStickerChecksScheduledWithoutSpinningOrReportingFailure() async {
        let completed = expectation(description: "This background pass completed")
        var calls = 0, scheduled: [Bool] = []
        let delivery = PhoneContextDelivery(needsDelivery: { true }, deliver: { calls += 1 },
            prepare: {}, suspend: {}, cancel: {}, schedule: { scheduled.append($0) },
            begin: { _ in XCTFail("System supplied execution time"); return .invalid }, end: { _ in XCTFail() })
        delivery.requestWithSystemGrant(id: UUID()) { success in
            XCTAssertTrue(success, "Waiting for a future Mac result is not a failed OS task")
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(scheduled, [true, true])
        XCTAssertFalse(delivery.isActive)
    }

    func testSystemWakeUsesItsOwnGrantAndCompletesExactlyOnce() async {
        let completed = expectation(description: "System task completed")
        var dirty = true, completions: [Bool] = []
        let id = UUID()
        let delivery = PhoneContextDelivery(needsDelivery: { dirty }, deliver: { dirty = false },
            prepare: {}, suspend: {}, cancel: { XCTFail("Completed system work is not cancelled") },
            schedule: { _ in }, begin: { _ in XCTFail("The scheduler already supplied runtime"); return .invalid },
            end: { _ in XCTFail("No UIKit token exists") })
        delivery.requestWithSystemGrant(id: id) { completions.append($0); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        delivery.expireSystemGrant(id: id)
        XCTAssertEqual(completions, [true])
        XCTAssertFalse(delivery.isActive)
    }

    func testBackgroundChangeUploadsAndCoalescesChangesDuringUpload() async throws {
        let entered = expectation(description: "Upload started")
        let finished = expectation(description: "Transport released")
        let gate = AsyncStream<Void>.makeStream()
        var dirty = true, calls = 0, prepares = 0
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ends: [Int] = [], scheduled: [Bool] = []
        let delivery = PhoneContextDelivery(needsDelivery: { dirty }, deliver: {
            calls += 1
            if calls == 1 {
                entered.fulfill()
                for await _ in gate.stream { break }
            }
            try Task.checkCancellation()
            dirty = false
        }, prepare: { prepares += 1 }, suspend: { finished.fulfill() },
        cancel: {}, schedule: { scheduled.append($0) }, begin: {
            expirations.append($0); return UIBackgroundTaskIdentifier(rawValue: expirations.count)
        }, end: { ends.append($0.rawValue) })
        delivery.request()
        await fulfillment(of: [entered], timeout: 5)
        delivery.request(); delivery.request()
        XCTAssertEqual(prepares, 1)
        XCTAssertTrue(delivery.isActive)
        gate.continuation.yield(()); gate.continuation.finish()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(calls, 2, "Changes during one upload need one follow-up pass, not parallel sends")
        XCTAssertEqual(ends, [1])
        XCTAssertEqual(scheduled, [true, false])
        XCTAssertFalse(delivery.isActive)
    }

    func testDeniedBackgroundTimeKeepsPendingWorkForSystemRetry() {
        var scheduled = false
        let delivery = PhoneContextDelivery(needsDelivery: { true }, deliver: { XCTFail("No OS grant") },
            prepare: { XCTFail("Do not open a transport without OS time") }, suspend: {}, cancel: {},
            schedule: { scheduled = $0 }, begin: { _ in .invalid }, end: { _ in XCTFail("No token to end") })
        delivery.request()
        XCTAssertTrue(scheduled)
        XCTAssertFalse(delivery.isActive)
    }

    func testFailureDoesNotSpinOrAcknowledgePendingWork() async {
        let finished = expectation(description: "Failed delivery released transport")
        var attempts = 0, ends = 0, pending = false
        let delivery = PhoneContextDelivery(needsDelivery: { true }, deliver: {
            attempts += 1; throw URLError(.notConnectedToInternet)
        }, prepare: {}, suspend: { finished.fulfill() }, cancel: {}, schedule: { pending = $0 },
        begin: { _ in UIBackgroundTaskIdentifier(rawValue: 1) }, end: { _ in ends += 1 })
        delivery.request()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(ends, 1)
        XCTAssertTrue(pending)
    }

    func testExpirationEndsImmediatelyAndStaleCallbackCannotCancelNextUpload() async {
        let first = expectation(description: "First upload started")
        let second = expectation(description: "Replacement upload started")
        let released = expectation(description: "Transport released twice"); released.expectedFulfillmentCount = 2
        let gates = [AsyncStream<Void>.makeStream(), AsyncStream<Void>.makeStream()]
        var calls = 0, ends: [Int] = [], cancellations = 0
        var expirations: [@MainActor @Sendable () -> Void] = []
        let delivery = PhoneContextDelivery(needsDelivery: { true }, deliver: {
            calls += 1
            if calls == 1 { first.fulfill() } else { second.fulfill() }
            for await _ in gates[calls - 1].stream { break }
            try Task.checkCancellation()
        }, prepare: {}, suspend: { released.fulfill() }, cancel: { cancellations += 1 }, schedule: { _ in },
        begin: { expirations.append($0); return UIBackgroundTaskIdentifier(rawValue: expirations.count) },
        end: { ends.append($0.rawValue) })
        delivery.request()
        await fulfillment(of: [first], timeout: 5)
        expirations[0]()
        XCTAssertEqual(ends, [1])
        XCTAssertEqual(cancellations, 1)
        delivery.request()
        await fulfillment(of: [second], timeout: 5)
        expirations[0]()
        XCTAssertTrue(delivery.isActive)
        XCTAssertEqual(cancellations, 1)
        expirations[1]()
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(ends, [1, 2])
        for gate in gates { gate.continuation.finish() }
    }

    func testTimeBudgetCancelsSlowUploadAndRetainsRetry() async {
        let ended = expectation(description: "Deadline ended the grant")
        let gate = AsyncStream<Void>.makeStream()
        var cancelled = false, pending = false
        let delivery = PhoneContextDelivery(needsDelivery: { true }, deliver: {
            for await _ in gate.stream { break }
            try Task.checkCancellation()
        }, prepare: {}, suspend: {}, cancel: { cancelled = true }, schedule: { pending = $0 },
        begin: { _ in UIBackgroundTaskIdentifier(rawValue: 1) }, end: { _ in ended.fulfill() },
        budget: .milliseconds(30))
        delivery.request()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertTrue(cancelled)
        XCTAssertTrue(pending)
        XCTAssertFalse(delivery.isActive)
        gate.continuation.finish()
    }
}
