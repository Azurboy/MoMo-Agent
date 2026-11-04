import Foundation
import os
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoSpeech

@MainActor
final class TranscriptionBatchIntegrationTests: XCTestCase {
    func testUserContinuationPreparesAndTranscribesOpenRawAudioInBackground() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let received = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive, closeEpoch: false)
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration())
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine)
        let frozen = try await coordinator.prepareUserContinuationBatch()
        let batch = try XCTUnwrap(frozen)
        XCTAssertTrue(batch.windowIDs.isEmpty)
        XCTAssertGreaterThan(batch.totalDuration, 60)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        _ = try await coordinator.startBatch(id: batch.id, origin: .continuedProcessing) { result in
            completions.withLock { $0.append(result) }
        }
        let report = await coordinator.runUntilIdle()
        XCTAssertNil(report.snapshot.failureCode)
        XCTAssertGreaterThan(report.preparedBatches, 0)
        XCTAssertEqual(report.transcribedWindows, 1)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.completed])
        try await assertOfficialTranscript(received.sessionID, archive: archive)
        let finished = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(finished.completedDuration, batch.totalDuration, accuracy: 0.000001)
        let coverage = try await archive.recordingCoverage(sessionID: received.sessionID, configurationFingerprint: engine.configurationFingerprint)
        XCTAssertTrue(coverage.epochs.allSatisfy { $0.closedAtFrame == nil })
        let empty = try await coordinator.prepareUserContinuationBatch()
        XCTAssertNil(empty)
    }

    func testUserContinuationIncludesTheOnlyWindowAlreadyBeingTranscribed() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let received = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let gate = BatchNativeGate()
        defer { gate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: gate.observe)
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handoff = Task {
            defer { gate.release() }
            try await gate.waitForStart()
            let frozen = try await coordinator.prepareUserContinuationBatch()
            let batch = try XCTUnwrap(frozen)
            XCTAssertEqual(batch.windowIDs.count, 1)
            XCTAssertEqual(gate.returnedCount, 0, "Handoff must not wait for native inference.")
            _ = try await coordinator.startBatch(id: batch.id, origin: .continuedProcessing) { result in
                completions.withLock { $0.append(result) }
            }
            await coordinator.suspendForSystem()
            return batch
        }
        let report = await coordinator.runUntilIdle()
        gate.finishEvents()
        let batch = try await handoff.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertNil(report.snapshot.failureCode)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.completed])
        try await assertOfficialTranscript(received.sessionID, archive: archive)
        let finished = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(finished.completedDuration, batch.totalDuration, accuracy: 0.000001)
    }

    func testSceneContinuationKeepsNativeWorkUntilTheSystemGrantExpires() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        _ = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let gate = BatchNativeGate()
        defer { gate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: gate.observe)
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        let handle = try await coordinator.startBatch(id: batch.id, origin: .foreground) { result in
            completions.withLock { $0.append(result) }
        }
        let expiration = Task {
            defer { gate.release() }
            try await gate.waitForStart()
            await coordinator.suspendForSystem(continuingForeground: true)
            let continued = await coordinator.snapshot()
            XCTAssertTrue(continued.nativeInFlight)
            XCTAssertEqual(continued.execution, handle)
            XCTAssertTrue(completions.withLock { $0.isEmpty })
            let idle = await coordinator.finishForegroundContinuationIfIdle()
            XCTAssertFalse(idle)
            await coordinator.suspendForSystem()
            XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.interrupted])
            XCTAssertEqual(gate.returnedCount, 0, "Expiration must not wait for native inference to return.")
        }
        let report = await coordinator.runUntilIdle()
        gate.finishEvents()
        try await expiration.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertFalse(report.snapshot.nativeInFlight)
        XCTAssertEqual(report.snapshot.phase, .systemSuspended)
        XCTAssertEqual(report.transcribedWindows, 0)
    }

    func testContinuedBatchExpiresBeforeNativeReturnsAndReleasesDeletedAudio() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let received = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let gate = BatchNativeGate()
        defer { gate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: gate.observe)
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine)
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handle = try await coordinator.startBatch(id: batch.id, origin: .continuedProcessing) { result in
            completions.withLock { $0.append(result) }
        }
        let stopping = Task {
            defer { gate.release() }
            try await gate.waitForStart()
            // Scene background alone must not revoke an admitted Continued task.
            await coordinator.suspendForSystem()
            try require(completions.withLock { $0.isEmpty }, "scene_background_ended_grant")
            try await coordinator.stop(execution: handle, reason: .systemEndedUnknown)
            try await coordinator.stop(execution: handle, reason: .userPaused)
            let stopped = await coordinator.snapshot()
            try require(stopped.nativeInFlight && stopped.execution == nil, "expiry_waited_for_native")
            let persisted = try await archive.transcriptionBatch(id: batch.id)
            try require(persisted.state == .paused && persisted.endReason == .systemEndedUnknown, "expiry_barrier_missing")
            let callbacks = completions.withLock { $0 }
            try require(callbacks.count == 1 && callbacks[0].reason == .systemEndedUnknown && callbacks[0].failureCode == nil,
                        "expiry_completion_not_exactly_once")
            try require(gate.returnedCount == 0, "native_returned_before_expiry_assertions")
            _ = try await archive.deleteSession(id: received.sessionID)
            try require(received.audioURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "leased_audio_deleted_early")
        }
        let report = await coordinator.runUntilIdle()
        gate.finishEvents()
        try await stopping.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertEqual(gate.returnedCount, 1)
        XCTAssertFalse(report.snapshot.nativeInFlight)
        XCTAssertEqual(report.transcribedWindows, 0)
        XCTAssertEqual(report.snapshot.phase, .systemSuspended)
        XCTAssertFalse(received.audioURLs.contains { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(completions.withLock { $0.count }, 1)
        let summaries = try await archive.recordings()
        XCTAssertTrue(summaries.isEmpty)
    }

    func testManagedHandoffDoesNotWaitForOldNativeAndPausedBatchNeedsExplicitResume() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let first = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let second = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let gate = BatchNativeGate()
        defer { gate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: gate.observe)
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handoff = Task {
            defer { gate.release() }
            try await gate.waitForStart()
            guard let activeID = await coordinator.snapshot().activeSessionID else {
                throw TranscriptionIntegrationFailure.lifecycleInvariant("no_active_handoff_session")
            }
            let pendingID = activeID == first.sessionID ? second.sessionID : first.sessionID
            guard let batch = try await coordinator.freezeBatch() else {
                throw TranscriptionIntegrationFailure.lifecycleInvariant("no_pending_handoff_batch")
            }
            try require(batch.windowIDs.count == 1 && batch.coverage.contains { $0.sessionID == pendingID }, "handoff_froze_active_window")
            let handle = try await coordinator.startBatch(id: batch.id, origin: .continuedProcessing) { result in
                completions.withLock { $0.append(result) }
            }
            try require(gate.returnedCount == 0 && !gate.timedOut, "admission_waited_for_old_native")
            await coordinator.suspendForSystem()
            try await coordinator.stop(execution: handle, reason: .systemEndedUnknown)
            try require(gate.returnedCount == 0 && completions.withLock { $0.count } == 1, "pending_execution_not_stoppable")
            return (batch, activeID, pendingID)
        }
        let cancelled = await coordinator.runUntilIdle()
        gate.finishEvents()
        let (batch, activeID, pendingID) = try await handoff.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertEqual(cancelled.transcribedWindows, 0)
        XCTAssertEqual(gate.startedCount, 1)
        let paused = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(paused.state, .paused)

        // Foreground may resume unrelated automatic work, but cannot steal the paused batch member.
        await coordinator.resumeAfterSystemSuspension()
        _ = await coordinator.runUntilIdle()
        try await assertOfficialTranscript(activeID, archive: archive)
        let waiting = try await archive.recordings().first { $0.id == pendingID }
        XCTAssertEqual(waiting?.transcriptVersion, 0)
        XCTAssertEqual(gate.startedCount, 2)
        let resumed = try await coordinator.resumeBatch(id: batch.id)
        XCTAssertEqual(resumed.windowIDs, batch.windowIDs)
        XCTAssertEqual(resumed.totalDuration, batch.totalDuration)
        _ = try await coordinator.startBatch(id: batch.id, origin: .foreground) { result in
            completions.withLock { $0.append(result) }
        }
        _ = await coordinator.runUntilIdle()
        try await assertOfficialTranscript(pendingID, archive: archive)
        let finished = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.completedDuration, finished.totalDuration, accuracy: 0.000001)
        XCTAssertEqual(gate.startedCount, 3)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.systemEndedUnknown, .completed])
    }

    func testBackgroundAutomaticExpiryResumesInForegroundAndUserPauseRejectsAdmission() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let received = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let gate = BatchNativeGate()
        defer { gate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: gate.observe)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        try await coordinator.pauseByUser()
        do {
            _ = try await coordinator.startBackgroundAutomatic { result in completions.withLock { $0.append(result) } }
            XCTFail("A paused user must not admit a background task")
        } catch TranscriptionExecutionError.userPaused { }
        XCTAssertTrue(completions.withLock { $0.isEmpty })
        try await coordinator.resumeByUser()
        let handle = try await coordinator.startBackgroundAutomatic { result in completions.withLock { $0.append(result) } }
        let expiration = Task {
            defer { gate.release() }
            try await gate.waitForStart()
            try await coordinator.stop(execution: handle, reason: .backgroundExpired)
            let snapshot = await coordinator.snapshot()
            try require(snapshot.nativeInFlight && gate.returnedCount == 0, "automatic_expiry_waited_for_native")
            try require(completions.withLock { $0.count } == 1, "automatic_expiry_completion_missing")
        }
        let cancelled = await coordinator.runUntilIdle()
        gate.finishEvents()
        try await expiration.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertEqual(cancelled.transcribedWindows, 0)
        XCTAssertEqual(cancelled.snapshot.phase, .systemSuspended)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.backgroundExpired])
        let activeBatches = try await archive.activeTranscriptionBatches()
        XCTAssertTrue(activeBatches.isEmpty)
        await coordinator.resumeAfterSystemSuspension()
        _ = await coordinator.runUntilIdle()
        try await assertOfficialTranscript(received.sessionID, archive: archive)
        XCTAssertEqual(gate.startedCount, 2)
        XCTAssertEqual(completions.withLock { $0.count }, 1)
    }

    #if DEBUG
    func testUserPauseAndResumeDuringAdmissionRequiresExplicitBatchResume() async throws {
        try await verifyAdmissionABA(userPause: true)
    }

    func testSceneRoundTripDuringForegroundAdmissionRequiresExplicitBatchResume() async throws {
        try await verifyAdmissionABA(userPause: false)
    }

    private func verifyAdmissionABA(userPause: Bool) async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let received = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration()) { event in
            if case .nativeDecodeStarted = event { decodes.withLock { $0 += 1 } }
        }
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        let admissionGate = BatchClaimGate()
        let admitted = AsyncStream<Void>.makeStream()
        await coordinator.observeAdmissions {
            admitted.continuation.yield(())
            await admissionGate.wait()
        }
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let first = Task {
            defer { admitted.continuation.finish() }
            return try await coordinator.startBatch(id: batch.id, origin: userPause ? .continuedProcessing : .foreground) { result in
                completions.withLock { $0.append(result) }
            }
        }
        do {
            var iterator = admitted.stream.makeAsyncIterator()
            guard await iterator.next() != nil else {
                throw TranscriptionIntegrationFailure.lifecycleInvariant("admission_gate_not_reached")
            }
            let pending = await coordinator.snapshot()
            XCTAssertNil(pending.execution)
            let persisted = try await archive.transcriptionBatch(id: batch.id)
            XCTAssertEqual(persisted.state, .running, "The gate must follow the real SQLite admission")
            if userPause {
                try await coordinator.pauseByUser()
                try await coordinator.resumeByUser()
            } else {
                await coordinator.suspendForSystem()
                await coordinator.resumeAfterSystemSuspension()
            }
            await admissionGate.open()
            _ = try await first.value
            _ = await coordinator.runUntilIdle()
        } catch {
            await admissionGate.open()
            throw error
        }
        admitted.continuation.finish()
        let interrupted = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(interrupted.state, userPause ? .paused : .ready)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [userPause ? .userPaused : .interrupted])
        XCTAssertEqual(decodes.withLock { $0 }, 0)
        let summary = try await archive.recordings().first { $0.sessionID == received.sessionID }
        XCTAssertEqual(summary?.transcriptVersion, 0)

        // Explicitly resumed background admission ignores an ordinary scene round trip.
        _ = try await coordinator.resumeBatch(id: batch.id)
        let backgroundGate = BatchClaimGate()
        let backgroundAdmitted = AsyncStream<Void>.makeStream()
        await coordinator.observeAdmissions {
            backgroundAdmitted.continuation.yield(())
            await backgroundGate.wait()
        }
        let resumed = Task {
            defer { backgroundAdmitted.continuation.finish() }
            return try await coordinator.startBatch(id: batch.id, origin: .continuedProcessing) { result in
                completions.withLock { $0.append(result) }
            }
        }
        do {
            var iterator = backgroundAdmitted.stream.makeAsyncIterator()
            guard await iterator.next() != nil else {
                throw TranscriptionIntegrationFailure.lifecycleInvariant("background_admission_gate_not_reached")
            }
            await coordinator.suspendForSystem()
            await coordinator.resumeAfterSystemSuspension()
            await backgroundGate.open()
            _ = try await resumed.value
            _ = await coordinator.runUntilIdle()
        } catch {
            await backgroundGate.open()
            throw error
        }
        backgroundAdmitted.continuation.finish()
        try await assertOfficialTranscript(received.sessionID, archive: archive)
        XCTAssertEqual(decodes.withLock { $0 }, 1)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [userPause ? .userPaused : .interrupted, .completed])
        let complete = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(complete.state, .completed)
    }

    func testOldSuspendCannotInvalidateNewBackgroundGrant() async throws {
        try await verifyNewGrantDuringOldSuspend(sceneABA: false)
    }

    func testSceneABADuringOldSuspendKeepsNewBackgroundGrant() async throws {
        try await verifyNewGrantDuringOldSuspend(sceneABA: true)
    }

    private func verifyNewGrantDuringOldSuspend(sceneABA: Bool) async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        _ = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let nativeGate = BatchNativeGate()
        defer { nativeGate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: nativeGate.observe)
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        let survivor = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        try await prepareWindows(archive: archive, engine: engine)
        let oldContinuation = BatchClaimGate(), newClaim = BatchClaimGate()
        let stopped = AsyncStream<Void>.makeStream(), claimed = AsyncStream<Void>.makeStream()
        let firstFinish = OSAllocatedUnfairLock(initialState: true)
        await coordinator.observeStops { boundary in
            guard case .finished = boundary else { return }
            let first = firstFinish.withLock { value in let result = value; value = false; return result }
            guard first else { return }
            // The old execution has already ended durably, but its scene callback has not resumed.
            stopped.continuation.yield(())
            await oldContinuation.wait()
        }
        await coordinator.observeClaims { kind, sessionID in
            guard kind == .transcription, sessionID == survivor.sessionID else { return }
            claimed.continuation.yield(())
            await newClaim.wait()
        }
        _ = try await coordinator.startBatch(id: batch.id, origin: .foreground) { _ in }
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let insertion = Task {
            do {
                try await nativeGate.waitForStart()
                let suspension = Task { await coordinator.suspendForSystem() }
                var stopIterator = stopped.stream.makeAsyncIterator()
                guard await stopIterator.next() != nil else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("old_suspend_stop_not_finished")
                }
                if sceneABA { await coordinator.resumeAfterSystemSuspension() }
                let handle = try await coordinator.startBackgroundAutomatic { result in completions.withLock { $0.append(result) } }
                if sceneABA { await coordinator.suspendForSystem() }
                nativeGate.release()
                var claimIterator = claimed.stream.makeAsyncIterator()
                guard await claimIterator.next() != nil else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("new_grant_claim_not_reached")
                }
                await oldContinuation.open()
                await suspension.value
                let snapshot = await coordinator.snapshot()
                try require(snapshot.execution == handle, "old_suspend_replaced_new_grant")
                let recording = try await archive.recordings().first { $0.sessionID == survivor.sessionID }
                try require(recording?.transcriptionState == .processing, "old_suspend_invalidated_new_claim")
                try require(completions.withLock { $0.isEmpty }, "new_grant_ended_before_its_claim_returned")
                await newClaim.open()
            } catch {
                nativeGate.release()
                await oldContinuation.open()
                await newClaim.open()
                throw error
            }
        }
        let report = await coordinator.runUntilIdle()
        nativeGate.finishEvents()
        stopped.continuation.finish()
        claimed.continuation.finish()
        try await insertion.value
        XCTAssertFalse(nativeGate.timedOut)
        XCTAssertEqual(report.snapshot.phase, .systemSuspended)
        XCTAssertEqual(nativeGate.startedCount, 2)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.completed])
        try await assertOfficialTranscript(survivor.sessionID, archive: archive)
        let retained = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(retained.state, .ready)
    }

    func testForegroundReturnDuringSuspendBarrierDoesNotSuspendNewWork() async throws {
        try await verifyResumeDuringStopBarrier(userPause: false)
    }

    func testUserResumeDuringPauseBarrierDoesNotPauseNewWork() async throws {
        try await verifyResumeDuringStopBarrier(userPause: true)
    }

    private func verifyResumeDuringStopBarrier(userPause: Bool) async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        _ = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let nativeGate = BatchNativeGate()
        defer { nativeGate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: nativeGate.observe)
        try await prepareWindows(archive: archive, engine: engine)
        let states = OSAllocatedUnfairLock(initialState: (resumed: false, phases: [TranscriptionPhase]()))
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false) { snapshot in
            states.withLock { if $0.resumed { $0.phases.append(snapshot.phase) } }
        }
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        // This recording is outside the frozen batch and should keep automatic foreground behavior.
        let survivor = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        try await prepareWindows(archive: archive, engine: engine)
        let stopGate = BatchClaimGate()
        let started = AsyncStream<Void>.makeStream()
        await coordinator.observeStops { boundary in
            if case .started = boundary {
                started.continuation.yield(())
                await stopGate.wait()
            }
        }
        _ = try await coordinator.startBatch(id: batch.id, origin: .foreground) { _ in }
        let reversal = Task {
            do {
                try await nativeGate.waitForStart()
                let stopping = Task {
                    if userPause { try await coordinator.pauseByUser() }
                    else { await coordinator.suspendForSystem() }
                }
                var iterator = started.stream.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("stop_barrier_not_reached")
                }
                if userPause { try await coordinator.resumeByUser() }
                else { await coordinator.resumeAfterSystemSuspension() }
                states.withLock { $0.resumed = true }
                nativeGate.release()
                await stopGate.open()
                try await stopping.value
            } catch {
                nativeGate.release()
                await stopGate.open()
                throw error
            }
        }
        let report = await coordinator.runUntilIdle()
        nativeGate.finishEvents()
        started.continuation.finish()
        try await reversal.value
        XCTAssertFalse(nativeGate.timedOut)
        XCTAssertFalse(report.snapshot.userPaused)
        // The first frozen batch deliberately remains pending; only the unrelated recording can drain.
        let status = try await archive.contextStatus()
        XCTAssertGreaterThan(status.pendingAnalysisCount, 0)
        XCTAssertEqual(report.snapshot.phase, .queued)
        XCTAssertFalse(states.withLock { $0.phases.contains(userPause ? .paused : .systemSuspended) },
                       "A stale stop must not publish its old lifecycle state after resume")
        try await assertOfficialTranscript(survivor.sessionID, archive: archive)
        XCTAssertEqual(nativeGate.startedCount, 2)
        let retained = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(retained.state, userPause ? .paused : .ready)
        XCTAssertEqual(retained.windowIDs, batch.windowIDs)
        XCTAssertLessThan(retained.completedDuration, retained.totalDuration)
    }

    func testConcurrentStopsSharePersistentBarrierAndPreserveUserPause() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        _ = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let nativeGate = BatchNativeGate()
        defer { nativeGate.release() }
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration(), onEvent: nativeGate.observe)
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine)
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        let barrierGate = BatchClaimGate()
        let boundaries = AsyncStream<TranscriptionStopBoundary>.makeStream()
        await coordinator.observeStops { boundary in
            boundaries.continuation.yield(boundary)
            if case .started = boundary { await barrierGate.wait() }
        }
        let trace = OSAllocatedUnfairLock(initialState: [String]())
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handle = try await coordinator.startBatch(id: batch.id, origin: .continuedProcessing) { result in
            completions.withLock { $0.append(result) }
            trace.withLock { $0.append("completion") }
        }
        let stopping = Task {
            do {
                try await nativeGate.waitForStart()
                let expiration = Task {
                    try await coordinator.stop(execution: handle, reason: .systemEndedUnknown)
                    trace.withLock { $0.append("expiration-returned") }
                }
                var iterator = boundaries.stream.makeAsyncIterator()
                guard case .started? = await iterator.next() else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("first_stop_barrier_not_entered")
                }
                let pause = Task {
                    try await coordinator.pauseByUser()
                    trace.withLock { $0.append("pause-returned") }
                }
                guard case .joined? = await iterator.next() else {
                    throw TranscriptionIntegrationFailure.lifecycleInvariant("concurrent_stop_did_not_join")
                }
                let stillRunning = try await archive.transcriptionBatch(id: batch.id)
                try require(stillRunning.state == .running && completions.withLock { $0.isEmpty }, "completion_preceded_persistent_barrier")
                try require(trace.withLock { $0.isEmpty }, "concurrent_stop_returned_before_barrier")
                trace.withLock { $0.append("barrier-released") }
                await barrierGate.open()
                try await expiration.value
                try await pause.value
                let callbacks = completions.withLock { $0 }
                try require(callbacks.count == 1 && callbacks[0].reason == .systemEndedUnknown, "concurrent_stop_reason_changed")
                try require(nativeGate.returnedCount == 0 && !nativeGate.timedOut, "concurrent_stop_waited_for_native")
                nativeGate.release()
            } catch {
                await barrierGate.open()
                nativeGate.release()
                throw error
            }
        }
        let report = await coordinator.runUntilIdle()
        nativeGate.finishEvents()
        boundaries.continuation.finish()
        try await stopping.value
        XCTAssertFalse(nativeGate.timedOut)
        XCTAssertEqual(Array(trace.withLock { $0 }.prefix(2)), ["barrier-released", "completion"])
        XCTAssertEqual(trace.withLock { $0.count }, 4)
        XCTAssertEqual(report.snapshot.phase, .paused)
        XCTAssertTrue(report.snapshot.userPaused)
        XCTAssertEqual(report.transcribedWindows, 0)
        let persisted = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(persisted.state, .paused)
        XCTAssertEqual(persisted.endReason, .systemEndedUnknown)
    }

    func testBackgroundExpiryDuringClaimPersistsBarrierBeforeCompletion() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let received = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration()) { event in
            if case .nativeDecodeStarted = event { decodes.withLock { $0 += 1 } }
        }
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine)
        let gate = BatchClaimGate()
        let claimed = AsyncStream<Void>.makeStream()
        await coordinator.observeClaims { kind, _ in
            guard kind == .analysis else { return }
            claimed.continuation.yield(())
            await gate.wait()
        }
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handle = try await coordinator.startBackgroundAutomatic { result in completions.withLock { $0.append(result) } }
        let expiration = Task {
            do {
                for await _ in claimed.stream {
                    let before = await coordinator.snapshot()
                    try require(before.activeSessionID == nil && !before.nativeInFlight, "claim_already_handed_off")
                    try await coordinator.stop(execution: handle, reason: .backgroundExpired)
                    try require(completions.withLock { $0.count } == 1, "claim_expiry_completion_missing")
                    // A new durable attempt must be claimable before the old worker is allowed to return.
                    guard let replacement = try await archive.claimEpochAnalysis(configurationFingerprint: engine.configurationFingerprint) else {
                        throw TranscriptionIntegrationFailure.lifecycleInvariant("claim_attempt_not_invalidated_before_completion")
                    }
                    try await archive.cancelEpochAnalysis(ticket: replacement)
                    try require(decodes.withLock { $0 } == 0, "native_started_after_expiration")
                    await gate.open()
                    return
                }
                throw TranscriptionIntegrationFailure.lifecycleInvariant("claim_gate_not_reached")
            } catch {
                await gate.open()
                throw error
            }
        }
        let stopped = await coordinator.runUntilIdle()
        claimed.continuation.finish()
        try await expiration.value
        XCTAssertEqual(stopped.snapshot.phase, .systemSuspended)
        XCTAssertEqual(stopped.transcribedWindows, 0)
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.backgroundExpired])
        await coordinator.resumeAfterSystemSuspension()
        _ = await coordinator.runUntilIdle()
        try await assertOfficialTranscript(received.sessionID, archive: archive)
        XCTAssertEqual(decodes.withLock { $0 }, 1)
        _ = try await archive.deleteSession(id: received.sessionID)
        XCTAssertFalse(received.audioURLs.contains { FileManager.default.fileExists(atPath: $0.path) })
    }
    #endif

    func testYieldToPriorityWorkFinishesActiveNativeDecodeBeforeSwitchingToLiveChunk() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let first = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let second = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let gate = BatchNativeGate()
        defer { gate.release() }
        let outcomes = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics.Outcome]())
        let engine = try SpeechEngine(
            bundle: fixture.model,
            configuration: SpeechConfiguration(),
            onDiagnostics: { diag in outcomes.withLock { $0.append(diag.outcome) } },
            onEvent: gate.observe
        )
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        XCTAssertEqual(batch.windowIDs.count, 2)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handle = try await coordinator.startBatch(id: batch.id, origin: .foreground) { result in
            completions.withLock { $0.append(result) }
        }
        let preemption = Task { () -> UUID in
            defer { gate.release() }
            try await gate.waitForStart()
            let live = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
            try await coordinator.yieldToPriorityWork(execution: handle)
            XCTAssertTrue(completions.withLock { $0.isEmpty }, "Cooperative yield must wait for in-flight window commit.")
            return live.sessionID
        }
        let report = await coordinator.runUntilIdle()
        gate.finishEvents()
        let liveSessionID = try await preemption.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertNil(report.snapshot.failureCode)
        XCTAssertFalse(outcomes.withLock { $0.contains(.cancelled) }, "Cooperative yield must never cancel in-flight native inference.")
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.interrupted])
        try await assertOfficialTranscript(first.sessionID, archive: archive)
        try await assertOfficialTranscript(liveSessionID, archive: archive)
        let yieldedBatch = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(yieldedBatch.state, .ready)
        let secondSummary = try await archive.recordings().first { $0.id == second.sessionID }
        XCTAssertEqual(secondSummary?.transcriptVersion, 0)
    }

    #if DEBUG
    func testPriorityInterleavingProcessesLiveWatchChunksWithoutCancellingOrTearingDownBatch() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let first = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let second = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let gate = BatchNativeGate()
        defer { gate.release() }
        let outcomes = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics.Outcome]())
        let engine = try SpeechEngine(
            bundle: fixture.model,
            configuration: SpeechConfiguration(),
            onDiagnostics: { diag in outcomes.withLock { $0.append(diag.outcome) } },
            onEvent: gate.observe
        )
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let transcribedSessions = OSAllocatedUnfairLock(initialState: [UUID]())
        await coordinator.observeClaims { kind, sessionID in
            if kind == .transcription {
                transcribedSessions.withLock { $0.append(sessionID) }
            }
        }
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)
        XCTAssertEqual(batch.windowIDs.count, 2)
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handle = try await coordinator.startBatch(id: batch.id, origin: .foreground) { result in
            completions.withLock { $0.append(result) }
        }
        let arrival = Task { () -> UUID in
            defer { gate.release() }
            try await gate.waitForStart()
            let live = try await TranscriptionIntegrationScenario.ingest(
                fixture.chunks,
                archive: archive,
                wallClockAnchor: Date().addingTimeInterval(-120)
            )
            await coordinator.requestPriorityInterleaving(execution: handle)
            return live.sessionID
        }
        let report = await coordinator.runUntilIdle()
        gate.finishEvents()
        let liveSessionID = try await arrival.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertNil(report.snapshot.failureCode)
        XCTAssertFalse(outcomes.withLock { $0.contains(.cancelled) },
                       "In-place priority interleaving must never cancel in-flight native inference.")
        XCTAssertEqual(transcribedSessions.withLock { $0 }, [first.sessionID, liveSessionID, second.sessionID],
                       "Live Watch audio must interleave right after the active batch window and seamlessly return to the batch.")
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.completed],
                       "Batch execution must complete in a single uninterrupted run without stop/start churn.")
        try await assertOfficialTranscript(first.sessionID, archive: archive)
        try await assertOfficialTranscript(liveSessionID, archive: archive)
        try await assertOfficialTranscript(second.sessionID, archive: archive)
        let finishedBatch = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(finishedBatch.state, .completed)
    }

    func testContinuedProcessingInterleavesHotLiveAudioAndPipelinesBatchPreparationWithoutCancellation() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let first = try await TranscriptionIntegrationScenario.ingest(
            fixture.chunks,
            archive: archive,
            wallClockAnchor: Date().addingTimeInterval(-86_400)
        )
        let second = try await TranscriptionIntegrationScenario.ingest(
            fixture.chunks,
            archive: archive,
            wallClockAnchor: Date().addingTimeInterval(-82_800)
        )
        let gate = BatchNativeGate()
        defer { gate.release() }
        let outcomes = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics.Outcome]())
        let engine = try SpeechEngine(
            bundle: fixture.model,
            configuration: SpeechConfiguration(),
            continuousArchive: true,
            onDiagnostics: { diag in outcomes.withLock { $0.append(diag.outcome) } },
            onEvent: gate.observe
        )
        engine.setSceneForeground(false)
        engine.setBackgroundBudget(.elevatedSystemTask)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: true)
        let transcribedSessions = OSAllocatedUnfairLock(initialState: [UUID]())
        await coordinator.observeClaims { kind, sessionID in
            if kind == .transcription {
                transcribedSessions.withLock { $0.append(sessionID) }
            }
        }
        let frozen = try await coordinator.prepareUserContinuationBatch()
        let batch = try XCTUnwrap(frozen)
        XCTAssertTrue(batch.windowIDs.isEmpty, "Both batch sessions start as raw unprepared audio.")
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        let handle = try await coordinator.startBatch(id: batch.id, origin: .continuedProcessing) { result in
            completions.withLock { $0.append(result) }
        }
        let arrival = Task { () -> (liveID: UUID, morningID: UUID) in
            defer { gate.release() }
            try await gate.waitForStart()
            let morning = try await TranscriptionIntegrationScenario.ingest(
                fixture.chunks,
                archive: archive,
                wallClockAnchor: Date().addingTimeInterval(-10_800)
            )
            let live = try await TranscriptionIntegrationScenario.ingest(
                fixture.chunks,
                archive: archive,
                wallClockAnchor: Date().addingTimeInterval(-120)
            )
            await coordinator.requestPriorityInterleaving(execution: handle)
            return (live.sessionID, morning.sessionID)
        }
        let report = await coordinator.runUntilIdle()
        gate.finishEvents()
        let (liveSessionID, morningSessionID) = try await arrival.value
        XCTAssertFalse(gate.timedOut)
        XCTAssertNil(report.snapshot.failureCode)
        XCTAssertFalse(outcomes.withLock { $0.contains(.cancelled) },
                       "Continued processing live interleaving and batch VAD prefetch must never cancel native operations.")
        let order = transcribedSessions.withLock { $0 }
        XCTAssertEqual(order, [first.sessionID, liveSessionID, second.sessionID],
                       "Continued processing must interleave Tier-0 live Watch audio while ignoring older unreserved morning backlog.")
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.completed])
        try await assertOfficialTranscript(first.sessionID, archive: archive)
        try await assertOfficialTranscript(liveSessionID, archive: archive)
        try await assertOfficialTranscript(second.sessionID, archive: archive)
        let finishedBatch = try await archive.transcriptionBatch(id: batch.id)
        XCTAssertEqual(finishedBatch.state, .completed)
        let morningSummary = try await archive.recordings().first { $0.id == morningSessionID }
        XCTAssertEqual(morningSummary?.transcriptVersion, 0)
    }
    #endif

    func testBackgroundBatchRecoveryResumesReadyAndExpiredBatchesExceptUserPaused() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        _ = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let engine = try SpeechEngine(bundle: fixture.model, configuration: SpeechConfiguration())
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine)
        let frozen = try await coordinator.freezeBatch()
        let batch = try XCTUnwrap(frozen)

        // 1. Newly frozen `.ready` batch is excluded only while its continued request is pending, otherwise resumable.
        let skippedWhilePending = try await coordinator.resumeSystemEndedBatchForBackgroundProcessing(excludingBatchID: batch.id)
        XCTAssertNil(skippedWhilePending)
        let readyResumed = try await coordinator.resumeSystemEndedBatchForBackgroundProcessing()
        XCTAssertEqual(readyResumed, batch.id)

        // 2. `.ready` with `endReason == .backgroundExpired` (e.g. after a prior BGProcessingTask expired) must resume.
        let bgExec = try await archive.beginTranscriptionBatch(id: batch.id, origin: .backgroundProcessing)
        let bgExpired = try await archive.finishTranscriptionBatch(execution: bgExec, reason: .backgroundExpired)
        XCTAssertEqual(bgExpired.state, .ready)
        XCTAssertEqual(bgExpired.endReason, .backgroundExpired)
        let expiredResumed = try await coordinator.resumeSystemEndedBatchForBackgroundProcessing()
        XCTAssertEqual(expiredResumed, batch.id)

        // 3. `.paused` with `endReason == .userPaused` must never auto-resume in background.
        let contExec = try await archive.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        let userPaused = try await archive.finishTranscriptionBatch(execution: contExec, reason: .userPaused)
        XCTAssertEqual(userPaused.state, .paused)
        let notResumed = try await coordinator.resumeSystemEndedBatchForBackgroundProcessing()
        XCTAssertNil(notResumed)
    }

    func testFiniteBackgroundBudgetStopsAtCleanWindowBoundaryWithoutCancellingNextWindow() async throws {
        let fixture = try fixture()
        let archive = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let first = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let second = try await TranscriptionIntegrationScenario.ingest(fixture.chunks, archive: archive)
        let remainingSeconds = OSAllocatedUnfairLock<TimeInterval?>(initialState: 28.0)
        let outcomes = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics.Outcome]())
        let engine = try SpeechEngine(
            bundle: fixture.model,
            configuration: SpeechConfiguration(),
            onDiagnostics: { diag in
                outcomes.withLock { $0.append(diag.outcome) }
                if diag.operation == .transcribe && diag.outcome == .completed {
                    remainingSeconds.withLock { $0 = 9.0 }
                }
            },
            onEvent: { _ in }
        )
        try await prepareWindows(archive: archive, engine: engine)
        let coordinator = try TranscriptionCoordinator(
            archive: archive,
            speech: engine,
            remainingFiniteBackgroundSeconds: { remainingSeconds.withLock { $0 } }
        )
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionExecutionCompletion]())
        _ = try await coordinator.startBackgroundAutomatic(finiteBudget: true) { result in
            completions.withLock { $0.append(result) }
        }
        let report = await coordinator.runUntilIdle()
        XCTAssertEqual(report.transcribedWindows, 1)
        XCTAssertFalse(outcomes.withLock { $0.contains(.cancelled) })
        XCTAssertEqual(completions.withLock { $0.map(\.reason) }, [.backgroundExpired])
        try await assertOfficialTranscript(first.sessionID, archive: archive)
        let secondSummary = try await archive.recordings().first { $0.id == second.sessionID }
        XCTAssertEqual(secondSummary?.transcriptVersion, 0)
    }

    private func fixture() throws -> (root: URL, model: SpeechModelBundle, chunks: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoBatchIntegration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "Speech", withExtension: nil), "Prepare real Speech model resources before building")
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "zh", withExtension: "wav", subdirectory: "TestFixtures"),
                                  "Run Tests/Support/prepare-fixtures.py before building")
        XCTAssertEqual(try ContentHash.sha256(fileAt: audio), PhoneTranscriptionFixture.officialWAVSHA256)
        let model = try SpeechModelBundle.load(from: modelURL)
        try model.validate()
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: audio, directory: root.appendingPathComponent("capture"))
        let attachment = XCTAttachment(string: "Isolated batch test evidence: \(root.path)")
        attachment.lifetime = .keepAlways
        add(attachment)
        return (root, model, chunks)
    }

    private func assertOfficialTranscript(_ sessionID: UUID, archive: ArchiveStore) async throws {
        let document = try await archive.readTranscript(sessionID: sessionID)
        XCTAssertEqual(document.spans.count, 1)
        XCTAssertEqual(document.spans.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), "开放时间早上9点至下午5点。")
        XCTAssertEqual(document.spans.first?.sourceRanges.count, 2)
    }
}

// Prepares frozen members with the actual VAD and resampler, without starting ASR.
func prepareWindows(archive: ArchiveStore, engine: SpeechEngine) async throws {
    while let ticket = try await archive.claimEpochAnalysis(configurationFingerprint: engine.configurationFingerprint) {
        do {
            let result = try await engine.prepare(inputs: ticket.inputs.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) },
                resume: ticket.checkpoint.map { SpeechCheckpoint(sessionID: $0.sessionID, epochID: $0.epochID, sourceFrame: $0.sourceFrame,
                                                                 configurationFingerprint: $0.configurationFingerprint) },
                epochClosed: ticket.epochClosed, attempt: SpeechAttempt(id: ticket.attemptID))
            let windows = result.windows.map { window in
                ArchiveAnalysisWindow(id: window.id, sessionID: window.sessionID, epochID: window.epochID,
                    analysisAnchor: window.analysisAnchor, coreFrames: window.coreFrames, contextFrames: window.contextFrames,
                    modelCoreFrames: window.modelCoreFrames, modelContextFrames: window.modelContextFrames,
                    sources: window.sources.map { ArchiveWindowSource(chunkID: $0.chunkID, manifestSHA256: $0.manifestSHA256,
                        audioSHA256: $0.audioSHA256, sourceFrames: $0.sourceFrames) }, replayInputManifestHashes: window.replayInputManifestHashes,
                    configurationFingerprint: window.configurationFingerprint)
            }
            try await archive.commitAnalysisBatch(ticket: ticket, windows: windows, analyzedCoverage: result.analyzedCoverage,
                noSpeechCoverage: result.noSpeechCoverage,
                checkpoint: result.checkpoint.map { ArchiveCheckpoint(sessionID: $0.sessionID, epochID: $0.epochID,
                    sourceFrame: $0.sourceFrame, configurationFingerprint: $0.configurationFingerprint) },
                waitingForMoreAudio: result.waitingForMoreAudio)
        } catch {
            try await archive.cancelEpochAnalysis(ticket: ticket)
            throw error
        }
    }
}

private func require(_ condition: Bool, _ invariant: String) throws {
    guard condition else { throw TranscriptionIntegrationFailure.lifecycleInvariant(invariant) }
}

#if DEBUG
private actor BatchClaimGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
#endif

/// Blocks only the first real native decode, on Speech's native queue. The timeout is a failure, not a release signal.
private final class BatchNativeGate: Sendable {
    private struct State { var started = 0; var returned = 0; var timedOut = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let semaphore = DispatchSemaphore(value: 0)
    private let events = AsyncStream<Void>.makeStream()
    var startedCount: Int { state.withLock { $0.started } }
    var returnedCount: Int { state.withLock { $0.returned } }
    var timedOut: Bool { state.withLock { $0.timedOut } }

    func observe(_ event: SpeechExecutionEvent) {
        switch event {
        case .analysisPageReady: break
        case .nativeDecodeStarted:
            let first = state.withLock { $0.started += 1; return $0.started == 1 }
            guard first else { return }
            events.continuation.yield(())
            if semaphore.wait(timeout: .now() + 30) != .success { state.withLock { $0.timedOut = true } }
        case .nativeDecodeReturned:
            state.withLock { $0.returned += 1 }
        }
    }

    func waitForStart() async throws {
        for await _ in events.stream { return }
        throw TranscriptionIntegrationFailure.lifecycleInvariant("native_decode_not_started")
    }

    func release() { semaphore.signal() }
    func finishEvents() { events.continuation.finish() }
}
