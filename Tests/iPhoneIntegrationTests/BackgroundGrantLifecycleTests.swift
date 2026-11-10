import Foundation
import SwiftUI
import UIKit
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

/// Controlled platform events test the adapter contract; they are not iOS scheduler acceptance.
@MainActor
final class BackgroundGrantLifecycleTests: XCTestCase {
    func testSceneContinuationEndsOnceAndAnOldExpirationCannotStopTheNextGrant() async throws {
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var stops = 0
        let continuation = PhoneTranscriptionContinuation(begin: { expiration in
            expirations.append(expiration)
            return UIBackgroundTaskIdentifier(rawValue: expirations.count)
        }, end: { ended.append($0) }, stop: { stops += 1 })
        continuation.start()
        continuation.start()
        XCTAssertEqual(expirations.count, 1)
        continuation.finish()
        continuation.start()
        expirations[0]()
        await Task.yield()
        XCTAssertTrue(continuation.isActive)
        XCTAssertEqual(stops, 0)
        await continuation.expire()
        await continuation.expire()
        continuation.finish()
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(continuation.isActive)
        XCTAssertEqual(ended.map(\.rawValue), [1, 2])
    }

    func testSceneContinuationReleasesOSTimeBeforeTheDurableStopAndCannotRestartDuringExpiration() async throws {
        let stopping = expectation(description: "Stop barrier")
        let gate = PreparationGate(entered: stopping)
        var starts = 0, ends = 0
        let continuation = PhoneTranscriptionContinuation(begin: { _ in
            starts += 1
            return UIBackgroundTaskIdentifier(rawValue: starts)
        }, end: { _ in ends += 1 }, stop: { await gate.wait() })
        continuation.start()
        let expired = Task { await continuation.expire() }
        await fulfillment(of: [stopping], timeout: 5)
        continuation.finish()
        continuation.start()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1, "The OS grant must end before waiting for cancellation.")
        XCTAssertFalse(continuation.isActive)
        await gate.open()
        await expired.value
        XCTAssertEqual(ends, 1)
    }

    func testExpirationCallbackReleasesOSTimeBeforeReturning() async throws {
        let stopping = expectation(description: "Stop barrier")
        let gate = PreparationGate(entered: stopping)
        var expiration: (@MainActor @Sendable () -> Void)?
        var ends = 0
        let continuation = PhoneTranscriptionContinuation(begin: { callback in
            expiration = callback
            return UIBackgroundTaskIdentifier(rawValue: 1)
        }, end: { _ in ends += 1 }, stop: { await gate.wait() })
        continuation.start()
        try XCTUnwrap(expiration)()
        XCTAssertEqual(ends, 1, "Returning from UIKit's callback with an active grant can terminate the app.")
        XCTAssertFalse(continuation.isActive)
        await fulfillment(of: [stopping], timeout: 5)
        try XCTUnwrap(expiration)()
        continuation.finish()
        XCTAssertEqual(ends, 1)
        await gate.open()
    }

    func testDeniedSceneContinuationDoesNotPretendToHaveBackgroundTime() {
        var ends = 0
        let continuation = PhoneTranscriptionContinuation(begin: { _ in .invalid },
            end: { _ in ends += 1 }, stop: { XCTFail("There is no grant to expire") })
        continuation.start()
        XCTAssertFalse(continuation.isActive)
        continuation.finish()
        XCTAssertEqual(ends, 0)
    }

    func testProcessLaunchWithoutSceneRestoresInboxAndQueuesReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoColdReceive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: device)
        let agent = try PhoneRemoteAgent(directory: root.appendingPathComponent("remote"), archive: archive, deviceID: device)
        let controls = try ControlInbox(directory: root.appendingPathComponent("controls"))
        let receiver = PhoneReceiveCoordinator(archive: archive, controls: controls,
            identity: ReceiverIdentity(messageID: UUID(), receiverDeviceID: device, libraryInstanceID: archive.libraryInstanceID))
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("encoder"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "cold-launch-test",
            sourceKind: .fixture, targetFrames: 160, wallClockAnchor: Date(), timezoneOffset: 0)
        let segment = try XCTUnwrap(writer.append(Array(repeating: 0, count: 160)).first)
        _ = try writer.finish()
        _ = try archive.inbox.preserve(fileURL: segment.audioURL, envelope: segment.envelope)
        let runtime = try PhoneRuntime(archive: archive, remoteAgent: agent, playback: AudioPlaybackController(archive: archive),
            receiver: receiver, transport: nil, speech: nil, speechFailure: nil)
        var creations = 0
        let bootstrap = PhoneBootstrap { _ in creations += 1; return runtime }
        bootstrap.launch()
        XCTAssertTrue(bootstrap.runtime === runtime, "The WC delegate must be installed during process launch, before any scene task.")
        bootstrap.launch()
        await runtime.start(backgroundOnly: true)
        XCTAssertEqual(creations, 1)
        XCTAssertTrue(runtime.ready)
        XCTAssertNil(runtime.failure)
        let receipts = try await archive.pendingReceipts()
        XCTAssertEqual(receipts.map(\.chunkID), [segment.envelope.manifest.chunkID])
        XCTAssertTrue(try archive.inbox.pendingItems().isEmpty)
        XCTAssertTrue(runtime.library.recordings.isEmpty, "A scene-free launch must not construct the library presentation.")
        await runtime.foreground()
        XCTAssertEqual(runtime.library.recordings.map(\.id), [segment.envelope.manifest.sessionID])
    }

    func testExpirationDuringPreparationEndsImmediatelyAndNeverAdmitsWork() async throws {
        let preparing = expectation(description: "Preparation started")
        let completed = expectation(description: "Expired before preparation ended")
        let gate = PreparationGate(entered: preparing)
        var results: [Bool] = []
        let grant = TranscriptionTaskGrant(prepare: { await gate.wait() }, start: { _ in
            XCTFail("Expired preparation must not admit an execution")
            throw TestFailure.stopFailed
        }, stop: { _, _ in XCTFail("No execution exists to stop") }) { success, _ in
            results.append(success)
            completed.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [preparing], timeout: 5)
        grant.expire(reason: .backgroundExpired)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(results, [false])
        await gate.open()
        await run.value
        XCTAssertEqual(results, [false])
        XCTAssertNil(grant.execution)
    }

    func testExpirationDuringAdmissionWaitsForStopBarrierAndCompletesOnce() async throws {
        let admitted = expectation(description: "Admission started")
        let stopping = expectation(description: "Stop barrier started")
        let completed = expectation(description: "System completion")
        let harness = GrantHarness(admitted: admitted, stopping: stopping)
        var completions: [(Bool, String?)] = []
        let grant = TranscriptionTaskGrant(start: { await harness.start($0) }, stop: { try await harness.stop($0, $1) }) { success, failure in
            completions.append((success, failure))
            completed.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [admitted], timeout: 5)
        grant.expire(reason: .systemEndedUnknown)
        XCTAssertTrue(completions.isEmpty)
        await harness.releaseAdmission()
        await fulfillment(of: [stopping], timeout: 5)
        XCTAssertTrue(completions.isEmpty, "The persistent stop barrier must precede system completion")
        await harness.deliverLateCompletion()
        await harness.releaseStop()
        await run.value
        await fulfillment(of: [completed], timeout: 5)
        grant.expire(reason: .systemEndedUnknown)
        await harness.deliverLateCompletion()
        await Task.yield()
        XCTAssertEqual(completions.count, 1)
        XCTAssertFalse(completions[0].0)
        XCTAssertNil(completions[0].1)
        let reasons = await harness.stopReasons
        XCTAssertEqual(reasons, [.systemEndedUnknown])
    }

    func testCompletionCanArriveBeforeAdmissionReturns() async throws {
        let admitted = expectation(description: "Admission started")
        let completed = expectation(description: "Early completion")
        let harness = GrantHarness(admitted: admitted, stopping: nil)
        var results: [Bool] = []
        let grant = TranscriptionTaskGrant(start: { await harness.start($0) }, stop: { try await harness.stop($0, $1) }) { success, _ in
            results.append(success)
            completed.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [admitted], timeout: 5)
        await harness.deliverLateCompletion()
        await fulfillment(of: [completed], timeout: 5)
        grant.expire(reason: .systemEndedUnknown)
        await harness.releaseAdmission()
        await run.value
        XCTAssertEqual(results, [true])
        let reasons = await harness.stopReasons
        XCTAssertTrue(reasons.isEmpty)
    }

    func testStopPersistenceFailureStillEndsSystemGrantAsFailure() async throws {
        let completed = expectation(description: "Failure completion")
        let handle = MoMoAgent.TranscriptionExecutionHandle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
        var results: [(Bool, String?)] = []
        let grant = TranscriptionTaskGrant(start: { _ in handle }, stop: { _, _ in throw TestFailure.stopFailed }) { success, failure in
            results.append((success, failure))
            completed.fulfill()
        }
        await grant.run()
        grant.expire(reason: .backgroundExpired)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].0)
        XCTAssertEqual(results[0].1, "archive_cancel_barrier_failed")
    }

    func testContinuedProgressNeverRegressesAndAdvancesDuringLongWindow() throws {
        let sessionID = UUID(), epochID = UUID()
        let totalFrames: Int64 = 300 * 16_000
        struct BatchWire: Encodable {
            let id: UUID
            let configurationFingerprint: String
            let state: TranscriptionBatchState
            let endReason: TranscriptionBatchEndReason?
            let execution: TranscriptionBatchExecution?
            let windowIDs: [String]
            let coverage: [TranscriptionBatchCoverage]
        }
        func makeBatch(state: TranscriptionBatchState = .running,
                       preparedSeconds: Int64,
                       completedSeconds: Int64) throws -> TranscriptionBatch {
            let frozen = [try FrameRange(start: 0, count: totalFrames)]
            let prepared = preparedSeconds > 0 ? [try FrameRange(start: 0, count: preparedSeconds * 16_000)] : []
            let completed = completedSeconds > 0 ? [try FrameRange(start: 0, count: completedSeconds * 16_000)] : []
            let wire = BatchWire(
                id: UUID(),
                configurationFingerprint: String(repeating: "a", count: 64),
                state: state,
                endReason: nil,
                execution: nil,
                windowIDs: ["w1", "w2"],
                coverage: [
                    TranscriptionBatchCoverage(
                        sessionID: sessionID,
                        epochID: epochID,
                        timebaseHz: 16_000,
                        frozen: frozen,
                        noSpeech: [],
                        prepared: prepared,
                        completed: completed,
                        removed: []
                    )
                ]
            )
            let data = try JSONEncoder().encode(wire)
            return try JSONDecoder().decode(TranscriptionBatch.self, from: data)
        }

        // Initial 1% (100 / 10_000) must not regress even on a 300-second batch with 0 completed seconds.
        var highWater: Int64 = 100
        var anchor: Int64 = 100
        let initial = PhoneBackgroundTasks.computeContinuedProgressUnits(
            batch: try makeBatch(preparedSeconds: 0, completedSeconds: 0),
            activeWorkInFlight: true,
            advanceHeartbeat: false,
            previousHighWater: highWater,
            previousBaseAnchor: anchor
        )
        XCTAssertGreaterThanOrEqual(initial.completedUnits, 100)
        highWater = initial.completedUnits
        anchor = initial.baseAnchor

        // Heartbeats during a 30-second window must monotonically advance without stalling or reaching 100%.
        for _ in 0..<15 {
            let step = PhoneBackgroundTasks.computeContinuedProgressUnits(
                batch: try makeBatch(preparedSeconds: 60, completedSeconds: 0),
                activeWorkInFlight: true,
                advanceHeartbeat: true,
                previousHighWater: highWater,
                previousBaseAnchor: anchor
            )
            XCTAssertGreaterThan(step.completedUnits, highWater)
            XCTAssertLessThan(step.completedUnits, PhoneBackgroundTasks.progressScale)
            highWater = step.completedUnits
            anchor = step.baseAnchor
        }

        let finished = PhoneBackgroundTasks.computeContinuedProgressUnits(
            batch: try makeBatch(state: .completed, preparedSeconds: 300, completedSeconds: 300),
            activeWorkInFlight: false,
            advanceHeartbeat: false,
            previousHighWater: highWater,
            previousBaseAnchor: anchor
        )
        XCTAssertEqual(finished.completedUnits, PhoneBackgroundTasks.progressScale)
    }

    func testMultiHourBatchProgressNeverStallsAcrossNinetySecondsOfHeartbeats() throws {
        let sessionID = UUID(), epochID = UUID()
        let totalFrames: Int64 = 9_613 * 16_000
        struct BatchWire: Encodable {
            let id: UUID
            let configurationFingerprint: String
            let state: TranscriptionBatchState
            let endReason: TranscriptionBatchEndReason?
            let execution: TranscriptionBatchExecution?
            let windowIDs: [String]
            let coverage: [TranscriptionBatchCoverage]
        }
        func makeMultiHourBatch(preparedSeconds: Int64, completedSeconds: Int64) throws -> TranscriptionBatch {
            let frozen = [try FrameRange(start: 0, count: totalFrames)]
            let prepared = [try FrameRange(start: 0, count: preparedSeconds * 16_000)]
            let completed = [try FrameRange(start: 0, count: completedSeconds * 16_000)]
            let wire = BatchWire(
                id: UUID(),
                configurationFingerprint: String(repeating: "b", count: 64),
                state: .running,
                endReason: nil,
                execution: nil,
                windowIDs: ["w1", "w2", "w3", "w4"],
                coverage: [
                    TranscriptionBatchCoverage(
                        sessionID: sessionID,
                        epochID: epochID,
                        timebaseHz: 16_000,
                        frozen: frozen,
                        noSpeech: [],
                        prepared: prepared,
                        completed: completed,
                        removed: []
                    )
                ]
            )
            let data = try JSONEncoder().encode(wire)
            return try JSONDecoder().decode(TranscriptionBatch.self, from: data)
        }

        // Exact regression for a 9,613s batch resumed at 4,925s completed / 4,995s prepared:
        // 80 consecutive 1.5s heartbeats (120 seconds) during a slow window must never stall.
        var highWater: Int64 = 100
        var anchor: Int64 = 100
        let batchAt4925 = try makeMultiHourBatch(preparedSeconds: 4_995, completedSeconds: 4_925)
        for tick in 0..<80 {
            let step = PhoneBackgroundTasks.computeContinuedProgressUnits(
                batch: batchAt4925,
                activeWorkInFlight: true,
                advanceHeartbeat: true,
                previousHighWater: highWater,
                previousBaseAnchor: anchor,
                baselinePreparedDuration: 4_995,
                baselineCompletedDuration: 4_925,
                targetSliceDuration: 120
            )
            XCTAssertGreaterThan(step.completedUnits, highWater, "Progress stalled on heartbeat tick \(tick)")
            XCTAssertLessThan(step.completedUnits, PhoneBackgroundTasks.progressScale)
            highWater = step.completedUnits
            anchor = step.baseAnchor
        }

        // Committing three 20s windows (4,925 -> 4,985) advances baseAnchor materially.
        let batchAt4985 = try makeMultiHourBatch(preparedSeconds: 4_995, completedSeconds: 4_985)
        let afterCommits = PhoneBackgroundTasks.computeContinuedProgressUnits(
            batch: batchAt4985,
            activeWorkInFlight: true,
            advanceHeartbeat: false,
            previousHighWater: highWater,
            previousBaseAnchor: anchor,
            baselinePreparedDuration: 4_995,
            baselineCompletedDuration: 4_925,
            targetSliceDuration: 120
        )
        XCTAssertGreaterThan(afterCommits.baseAnchor, 3_500)
        XCTAssertGreaterThanOrEqual(afterCommits.completedUnits, highWater)
    }

    func testProactiveSliceCompletionEndsGrantAsSuccessUnlessSystemExpirationArrivesDuringStop() async throws {
        let admitted1 = expectation(description: "Admitted 1")
        let stopping1 = expectation(description: "Proactive stop barrier")
        let completed1 = expectation(description: "Proactive completion")
        let harness1 = GrantHarness(admitted: admitted1, stopping: stopping1)
        var outcomes1: [(Bool, String?)] = []
        let grant1 = TranscriptionTaskGrant(start: { await harness1.start($0) }, stop: { try await harness1.stop($0, $1) }) { success, failure in
            outcomes1.append((success, failure))
            completed1.fulfill()
        }
        let run1 = Task { await grant1.run() }
        await fulfillment(of: [admitted1], timeout: 5)
        await harness1.releaseAdmission()
        await run1.value
        grant1.completeSlice(reason: .systemEndedUnknown)
        await fulfillment(of: [stopping1], timeout: 5)
        XCTAssertTrue(outcomes1.isEmpty, "Proactive slice completion must wait for durable SQLite stop barrier")
        await harness1.releaseStop()
        await fulfillment(of: [completed1], timeout: 5)
        XCTAssertEqual(outcomes1.count, 1)
        XCTAssertTrue(outcomes1[0].0)
        XCTAssertNil(outcomes1[0].1)
        XCTAssertTrue(grant1.completedProactively)
        XCTAssertEqual(grant1.endReason, .systemEndedUnknown)

        // If system expiration arrives while proactive stop is still in flight, report expired (false).
        let admitted2 = expectation(description: "Admitted 2")
        let stopping2 = expectation(description: "Contested stop barrier")
        let completed2 = expectation(description: "Contested completion")
        let harness2 = GrantHarness(admitted: admitted2, stopping: stopping2)
        var outcomes2: [(Bool, String?)] = []
        let grant2 = TranscriptionTaskGrant(start: { await harness2.start($0) }, stop: { try await harness2.stop($0, $1) }) { success, failure in
            outcomes2.append((success, failure))
            completed2.fulfill()
        }
        let run2 = Task { await grant2.run() }
        await fulfillment(of: [admitted2], timeout: 5)
        await harness2.releaseAdmission()
        await run2.value
        grant2.completeSlice(reason: .systemEndedUnknown)
        await fulfillment(of: [stopping2], timeout: 5)
        grant2.expire(reason: .systemEndedUnknown)
        await harness2.releaseStop()
        await fulfillment(of: [completed2], timeout: 5)
        XCTAssertEqual(outcomes2.count, 1)
        XCTAssertFalse(outcomes2[0].0)
        XCTAssertFalse(grant2.completedProactively)
    }

    func testProactiveSlicePolicyWaitsForCleanBoundaryOrHardSafetyDeadline() throws {
        let sessionID = UUID(), epochID = UUID()
        struct BatchWire: Encodable {
            let id: UUID
            let configurationFingerprint: String
            let state: TranscriptionBatchState
            let endReason: TranscriptionBatchEndReason?
            let execution: TranscriptionBatchExecution?
            let windowIDs: [String]
            let coverage: [TranscriptionBatchCoverage]
        }
        func makeRunningBatch(totalSeconds: Int64, completedSeconds: Int64) throws -> TranscriptionBatch {
            let wire = BatchWire(
                id: UUID(),
                configurationFingerprint: String(repeating: "c", count: 64),
                state: .running,
                endReason: nil,
                execution: nil,
                windowIDs: ["w1"],
                coverage: [
                    TranscriptionBatchCoverage(
                        sessionID: sessionID,
                        epochID: epochID,
                        timebaseHz: 16_000,
                        frozen: [try FrameRange(start: 0, count: totalSeconds * 16_000)],
                        noSpeech: [],
                        prepared: [try FrameRange(start: 0, count: totalSeconds * 16_000)],
                        completed: completedSeconds > 0 ? [try FrameRange(start: 0, count: completedSeconds * 16_000)] : [],
                        removed: []
                    )
                ]
            )
            return try JSONDecoder().decode(TranscriptionBatch.self, from: JSONEncoder().encode(wire))
        }

        let longBatch = try makeRunningBatch(totalSeconds: 9_613, completedSeconds: 5_005)
        // Never stops in foreground.
        XCTAssertFalse(PhoneBackgroundTasks.shouldCompleteContinuedSliceProactively(
            batch: longBatch, nativeInFlight: false, isAppInBackground: false,
            backgroundElapsedSeconds: 200, backgroundCompletedDelta: 80, backgroundPreparedDelta: 0,
            justCommittedWindow: true, thermalState: .nominal))
        // Keeps running before soft limit.
        XCTAssertFalse(PhoneBackgroundTasks.shouldCompleteContinuedSliceProactively(
            batch: longBatch, nativeInFlight: false, isAppInBackground: true,
            backgroundElapsedSeconds: 90, backgroundCompletedDelta: 80, backgroundPreparedDelta: 0,
            justCommittedWindow: true, thermalState: .nominal))
        // Mid-inference at 108s waits for window commit rather than cutting off mid-window.
        XCTAssertFalse(PhoneBackgroundTasks.shouldCompleteContinuedSliceProactively(
            batch: longBatch, nativeInFlight: true, isAppInBackground: true,
            backgroundElapsedSeconds: 108, backgroundCompletedDelta: 80, backgroundPreparedDelta: 0,
            justCommittedWindow: false, thermalState: .nominal))
        // Immediately completes slice once window commits past soft limit.
        XCTAssertTrue(PhoneBackgroundTasks.shouldCompleteContinuedSliceProactively(
            batch: longBatch, nativeInFlight: false, isAppInBackground: true,
            backgroundElapsedSeconds: 108, backgroundCompletedDelta: 80, backgroundPreparedDelta: 0,
            justCommittedWindow: true, thermalState: .nominal))
        // Hard safety limit stops before iOS scheduler expiration even if mid-flight.
        XCTAssertTrue(PhoneBackgroundTasks.shouldCompleteContinuedSliceProactively(
            batch: longBatch, nativeInFlight: true, isAppInBackground: true,
            backgroundElapsedSeconds: 130, backgroundCompletedDelta: 20, backgroundPreparedDelta: 0,
            justCommittedWindow: false, thermalState: .nominal))
        // Nearly finished batch (<= 22s remaining) is allowed to finish its final window before hard limit.
        let almostDoneBatch = try makeRunningBatch(totalSeconds: 120, completedSeconds: 104)
        XCTAssertFalse(PhoneBackgroundTasks.shouldCompleteContinuedSliceProactively(
            batch: almostDoneBatch, nativeInFlight: false, isAppInBackground: true,
            backgroundElapsedSeconds: 108, backgroundCompletedDelta: 84, backgroundPreparedDelta: 0,
            justCommittedWindow: true, thermalState: .nominal))
    }

    func testGrantFollowUpStageRunsAfterFirstStageCompletesAndHonorsExpirationBarrier() async throws {
        let stage1Admitted = expectation(description: "Stage 1 admitted")
        let stage2Admitted = expectation(description: "Stage 2 admitted")
        let stage2Stopping = expectation(description: "Stage 2 stop barrier")
        let grantCompleted = expectation(description: "Grant completed")
        let stage1 = GrantHarness(admitted: stage1Admitted, stopping: nil)
        let stage2 = GrantHarness(admitted: stage2Admitted, stopping: stage2Stopping)
        var outcomes: [(Bool, String?)] = []
        let grant = TranscriptionTaskGrant(
            start: { await stage1.start($0) },
            followUp: { await stage2.start($0) },
            stop: { execution, reason in try await stage2.stop(execution, reason) }
        ) { success, failure in
            outcomes.append((success, failure))
            grantCompleted.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [stage1Admitted], timeout: 5)
        await stage1.releaseAdmission()
        await run.value
        await stage1.deliverLateCompletion()
        await fulfillment(of: [stage2Admitted], timeout: 5)
        XCTAssertTrue(outcomes.isEmpty, "Grant must stay open while follow-up stage runs")
        grant.expire(reason: .backgroundExpired)
        await stage2.releaseAdmission()
        await fulfillment(of: [stage2Stopping], timeout: 5)
        XCTAssertTrue(outcomes.isEmpty, "Expiration during follow-up admission must await stop barrier")
        await stage2.releaseStop()
        await fulfillment(of: [grantCompleted], timeout: 5)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].0)
        XCTAssertNil(outcomes[0].1)
        let reasons = await stage2.stopReasons
        XCTAssertEqual(reasons, [.backgroundExpired])
    }

    func testTimelineDurationDisplaysHoursAndMinutesWithoutWholeHourStuckRounding() {
        let sec45 = TimelineDate.duration(45)
        let min2 = TimelineDate.duration(120)
        let near1Hr = TimelineDate.duration(3_580)
        let exact3Hr = TimelineDate.duration(10_800)
        let threeHr21Min = TimelineDate.duration(3 * 3_600 + 21 * 60)
        XCTAssertTrue(sec45.contains("45"))
        XCTAssertTrue(min2.contains("2"))
        XCTAssertFalse(near1Hr.contains("60"), "59m40s must roll over to 1 hour, not 60 minutes: \(near1Hr)")
        XCTAssertTrue(near1Hr.contains("1"))
        XCTAssertTrue(exact3Hr.contains("3") && !exact3Hr.contains("0"))
        XCTAssertTrue(threeHr21Min.contains("3") && threeHr21Min.contains("21"),
                      "Multi-hour remaining duration must show minute precision: \(threeHr21Min)")
    }

    func testReceivedAudioTranscriptionResumesQueuedArrivalsAfterProactiveBudgetStopAndSystemTaskHandoff() async throws {
        let firstStarted = expectation(description: "First grant started")
        let secondStarted = expectation(description: "Second grant started after proactive finite-budget stop")
        let thirdStarted = expectation(description: "Third grant started after system task finished")
        let runner = ReceivedAudioHarness(expectations: [firstStarted, secondStarted, thirdStarted])
        var osGrants = 0
        var osReleases = 0
        var allowNewGrant = true
        let received = ReceivedAudioTranscription(
            begin: { _ in
                osGrants += 1
                return { osReleases += 1 }
            },
            start: { finish in await runner.start(finish) },
            stop: { _, _ in },
            canStartNewGrant: { allowNewGrant }
        )
        received.request()
        await fulfillment(of: [firstStarted], timeout: 5)
        // Concurrent arrival while grant 1 is running, followed by proactive finite-budget stop (.backgroundExpired).
        received.request()
        await runner.finishCurrent(reason: .backgroundExpired)
        await fulfillment(of: [secondStarted], timeout: 5)
        XCTAssertEqual(osGrants, 2, "Queued arrival during proactive budget stop must acquire a fresh OS grant after releasing the first")
        XCTAssertEqual(osReleases, 1)

        // When OS background budget is exhausted, proactive stop releases cleanly without spin-looping.
        allowNewGrant = false
        received.request()
        await runner.finishCurrent(reason: .backgroundExpired)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(osGrants, 2)
        XCTAssertEqual(osReleases, 2)
        XCTAssertFalse(received.isActive)

        // Arrivals during an active BGProcessingTask / BGContinuedProcessingTask drain immediately once the system task finishes.
        allowNewGrant = true
        await received.handOffToSystemTask()
        received.request()
        XCTAssertFalse(received.isActive)
        received.systemTaskFinished()
        await fulfillment(of: [thirdStarted], timeout: 5)
        XCTAssertEqual(osGrants, 3)
        await runner.finishCurrent(reason: .completed)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(osReleases, 3)
    }

    private enum TestFailure: Error { case stopFailed }
}

private actor ReceivedAudioHarness {
    typealias Handle = MoMoAgent.TranscriptionExecutionHandle
    typealias Completion = MoMoAgent.TranscriptionExecutionCompletion
    private let expectations: [XCTestExpectation]
    private var runIndex = 0
    private var currentHandle: Handle?
    private var currentFinish: (@Sendable (Completion) -> Void)?

    init(expectations: [XCTestExpectation]) {
        self.expectations = expectations
    }

    func start(_ finish: @escaping @Sendable (Completion) -> Void) -> Handle {
        let handle = Handle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
        currentHandle = handle
        currentFinish = finish
        if runIndex < expectations.count {
            expectations[runIndex].fulfill()
        }
        runIndex += 1
        return handle
    }

    func finishCurrent(reason: TranscriptionBatchEndReason) {
        guard let handle = currentHandle, let finish = currentFinish else { return }
        currentHandle = nil
        currentFinish = nil
        finish(Completion(execution: handle, reason: reason, failureCode: nil))
    }
}

private actor PreparationGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private actor GrantHarness {
    typealias Handle = MoMoAgent.TranscriptionExecutionHandle
    typealias Completion = MoMoAgent.TranscriptionExecutionCompletion
    let handle = Handle(id: UUID(), origin: .continuedProcessing, batchExecution: nil)
    let admitted: XCTestExpectation
    let stopping: XCTestExpectation?
    var finish: (@Sendable (Completion) -> Void)?
    var admission: CheckedContinuation<Handle, Never>?
    var stopBarrier: CheckedContinuation<Void, Never>?
    private(set) var stopReasons: [TranscriptionBatchEndReason] = []

    init(admitted: XCTestExpectation, stopping: XCTestExpectation?) {
        self.admitted = admitted
        self.stopping = stopping
    }

    func start(_ finish: @escaping @Sendable (Completion) -> Void) async -> Handle {
        self.finish = finish
        return await withCheckedContinuation { continuation in
            admission = continuation
            admitted.fulfill()
        }
    }

    func releaseAdmission() { admission?.resume(returning: handle); admission = nil }

    func stop(_ execution: Handle, _ reason: TranscriptionBatchEndReason) async throws {
        stopReasons.append(reason)
        await withCheckedContinuation { continuation in
            stopBarrier = continuation
            stopping?.fulfill()
        }
    }

    func releaseStop() { stopBarrier?.resume(); stopBarrier = nil }
    func deliverLateCompletion() { finish?(Completion(execution: handle, reason: .completed, failureCode: nil)) }
}
