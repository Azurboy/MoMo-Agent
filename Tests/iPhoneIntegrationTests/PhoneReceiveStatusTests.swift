import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
@testable import MoMoLink
import MoMoRecording
@preconcurrency import WatchConnectivity
@testable import MoMoAgent

@MainActor
final class PhoneReceiveStatusTests: XCTestCase {
    func testRepeatedUnreachableFailuresNeverInterruptThePhoneOrAcknowledgePendingAudio() async throws {
        let fixture = try await Fixture(), coordinator = fixture.coordinator()
        let agent = try PhoneRemoteAgent(directory: fixture.root.appendingPathComponent("remote"), archive: fixture.archive, deviceID: fixture.receiver)
        let runtime = try PhoneRuntime(archive: fixture.archive, remoteAgent: agent,
            playback: AudioPlaybackController(archive: fixture.archive), receiver: coordinator,
            transport: nil, speech: nil, speechFailure: nil)
        for code in [WCError.Code.notReachable, .genericError, .messageReplyTimedOut] {
            let failure = TransportFailure(NSError(domain: WCErrorDomain, code: code.rawValue))
            for _ in 0..<10 {
                await coordinator.receive(.failed(failure))
                await coordinator.receive(.controlTransportFinished(message: .receipt(fixture.receipt), failure: failure))
                XCTAssertNil(runtime.failure)
                XCTAssertNil(runtime.syncFailure)
                runtime.dismissFailure()
            }
        }
        let failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.genericError.rawValue))
        let receipts = try await fixture.archive.pendingReceipts()
        XCTAssertEqual(receipts, [fixture.receipt], "Temporary unreachability must not acknowledge or discard the recording.")
        coordinator.onFailure("原音文件需要检查")
        await coordinator.receive(.failed(failure))
        XCTAssertEqual(runtime.failure, "原音文件需要检查")
    }

    func testUnreachableResponseStillRequeuesAndRetriesWithoutHidingOtherControlFailures() async throws {
        let fixture = try await Fixture()
        let response = try await fixture.archive.receiveReconcileRequest(fixture.request())
        try await fixture.archive.markReconcileResponseSubmitted(messageID: response.messageID)
        let first = expectation(description: "Unreachable response still schedules recovery")
        let second = expectation(description: "Unreachable recovery backs off")
        let sleeper = PhoneReceiptRecoverySleeper(expectations: [first, second])
        addTeardownBlock { await sleeper.cancelAll() }
        let coordinator = PhoneReceiveCoordinator(archive: fixture.archive, controls: fixture.controls, identity: fixture.identity,
            recoverySleep: { try await sleeper.sleep($0) })
        var banner: String?
        coordinator.onSyncFailure = { banner = $0 }
        let unreachable = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.notReachable.rawValue))
        await coordinator.receive(.controlTransportFinished(message: .reconcileResponse(response), failure: unreachable))
        XCTAssertNil(banner)
        let pending = try await fixture.archive.pendingReconcileResponses()
        XCTAssertEqual(pending, [response])
        await fulfillment(of: [first], timeout: 5)
        await sleeper.releaseNext()
        await fulfillment(of: [second], timeout: 5)
        let delays = await sleeper.durations
        XCTAssertEqual(delays, [.seconds(30), .seconds(60)])

        let genuine = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue))
        await coordinator.receive(.controlTransportFinished(message: .receipt(fixture.receipt), failure: genuine))
        let genuineBanner = try XCTUnwrap(banner)
        for _ in 0..<5 {
            await coordinator.receive(.controlTransportFinished(message: .reconcileResponse(response), failure: unreachable))
            XCTAssertEqual(banner, genuineBanner)
        }
        await coordinator.receive(.controlTransportFinished(message: .receipt(fixture.receipt), failure: nil))
        XCTAssertNil(banner)
        let stillPending = try await fixture.archive.pendingReconcileResponses()
        XCTAssertEqual(stillPending, [response])
    }

    func testUnreachablePresentationUsesTheErrorDomainAndCode() async throws {
        let fixture = try await Fixture(), coordinator = fixture.coordinator()
        var failure: String?, banner: String?
        coordinator.onFailure = { failure = $0 }
        coordinator.onSyncFailure = { banner = $0 }
        for error in [NSError(domain: "OtherDomain", code: 7007),
                      NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "7007 not reachable"])] {
            let diagnostic = TransportFailure(error)
            await coordinator.receive(.failed(diagnostic))
            await coordinator.receive(.controlTransportFinished(message: .receipt(fixture.receipt), failure: diagnostic))
            XCTAssertTrue(failure?.contains(diagnostic.diagnosticDescription) == true)
            XCTAssertTrue(banner?.contains(diagnostic.diagnosticDescription) == true)
        }
    }

    func testSupersededResponseFailureRetiresOnlyItsProvenOldPayload() async throws {
        let fixture = try await Fixture()
        try await fixture.archive.applyReceipt(ReceiptApplied(receipt: fixture.receipt))
        let request = try fixture.request()
        let old = try await fixture.archive.receiveReconcileRequest(request)
        try await fixture.archive.markReconcileResponseSubmitted(messageID: old.messageID)
        let lease = try await fixture.archive.acquireAudioLease(chunkID: fixture.envelope.manifest.chunkID)
        await fixture.archive.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        let current = try await fixture.archive.receiveReconcileRequest(request)
        XCTAssertNotEqual(old.messageID, current.messageID)
        try await fixture.archive.markReconcileResponseSubmitted(messageID: current.messageID)
        let sleeper = PhoneReceiptRecoverySleeper(expectations: [])
        addTeardownBlock { await sleeper.cancelAll() }
        let coordinator = PhoneReceiveCoordinator(archive: fixture.archive, controls: fixture.controls, identity: fixture.identity,
            recoverySleep: { try await sleeper.sleep($0) })
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        coordinator.attach(transport)
        var banner: String?
        coordinator.onSyncFailure = { banner = $0 }
        let failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue))
        let oldMessage = ControlMessage.reconcileResponse(old)
        _ = try transport.reserveControlRoutes(oldMessage, outstanding: [], isReachable: true)
        transport.finishInteractive(oldMessage, failed: true)
        XCTAssertTrue(transport.hasRetryableControls)
        await coordinator.receive(.controlTransportFinished(message: oldMessage, failure: failure))
        XCTAssertNil(banner)
        XCTAssertFalse(transport.hasRetryableControls)
        var pending = try await fixture.archive.pendingReconcileResponses()
        XCTAssertTrue(pending.isEmpty, "An obsolete failure cannot revive the submitted replacement.")

        let currentMessage = ControlMessage.reconcileResponse(current)
        await coordinator.receive(.controlTransportFinished(message: currentMessage, failure: failure))
        let currentFailure = try XCTUnwrap(banner)
        transport.finishInteractive(oldMessage, failed: true)
        await coordinator.receive(.controlTransportFinished(message: oldMessage, failure: failure))
        XCTAssertEqual(banner, currentFailure, "Retiring A cannot complete the still-failed B.")
        pending = try await fixture.archive.pendingReconcileResponses()
        XCTAssertEqual(pending, [current])

        // Any different response ID for the owned request is outside the canonical outbox.
        let nonCanonical = try ReconcileResponse(requestID: current.requestID, requestSHA256: current.requestSHA256,
            sourceDeviceID: current.sourceDeviceID, receiverDeviceID: current.receiverDeviceID,
            libraryInstanceID: current.libraryInstanceID, results: current.results)
        let nonCanonicalMessage = ControlMessage.reconcileResponse(nonCanonical)
        transport.finishInteractive(nonCanonicalMessage, failed: true)
        await coordinator.receive(.controlTransportFinished(message: nonCanonicalMessage, failure: failure))
        XCTAssertEqual(banner, currentFailure)
        XCTAssertFalse(transport.hasRetryableControls)
        // The canonical ID with different content is a conflict, not an obsolete attempt.
        let unknown = try ReconcileResponse(messageID: current.messageID, requestID: current.requestID,
            requestSHA256: current.requestSHA256, sourceDeviceID: current.sourceDeviceID,
            receiverDeviceID: current.receiverDeviceID, libraryInstanceID: current.libraryInstanceID, results: old.results)
        let unknownMessage = ControlMessage.reconcileResponse(unknown)
        transport.finishInteractive(unknownMessage, failed: true)
        await coordinator.receive(.controlTransportFinished(message: unknownMessage, failure: failure))
        await coordinator.receive(.controlTransportFinished(message: currentMessage, failure: nil))
        XCTAssertNotNil(banner, "An unknown failure must not be acknowledged as superseded.")
        XCTAssertTrue(transport.hasRetryableControls)
    }

    func testControlInboxReadFailureRetriesWithoutAnOutboundControlOrAnotherConnectivityEvent() async throws {
        let fixture = try await Fixture()
        try await fixture.archive.applyReceipt(ReceiptApplied(receipt: fixture.receipt))
        let first = expectation(description: "The retained control inbox requests recovery")
        let sleeper = PhoneReceiptRecoverySleeper(expectations: [first])
        addTeardownBlock { await sleeper.cancelAll() }
        let coordinator = PhoneReceiveCoordinator(archive: fixture.archive, controls: fixture.controls, identity: fixture.identity,
            recoverySleep: { try await sleeper.sleep($0) })
        let mark = try CaptureMark(sessionID: fixture.session, epochID: fixture.epoch, sourceDeviceID: fixture.source, sourceFrame: 1)
        try fixture.controls.preserve(.captureMark(mark))
        // A temporary filesystem failure prevents reading the cursor, while the message stays intact.
        let position = fixture.controls.directory.appendingPathComponent(".background-position")
        try FileManager.default.createDirectory(at: position, withIntermediateDirectories: false)
        await coordinator.reconcile()
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(try fixture.controls.pending(), [.captureMark(mark)])
        let receiptsBeforeRetry = try await fixture.archive.pendingReceiptCount()
        XCTAssertEqual(receiptsBeforeRetry, 0)
        try FileManager.default.removeItem(at: position)
        await sleeper.releaseNext()
        let deadline = ContinuousClock.now + .seconds(5)
        while try fixture.controls.hasPending(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(try fixture.controls.pending().isEmpty)
        let marks = try await fixture.archive.marks(sessionID: fixture.session)
        XCTAssertEqual(marks, [mark])
        let delays = await sleeper.durations
        XCTAssertEqual(delays, [.seconds(30)])
    }

    func testOriginalInboxCommitFailureRetriesBeforeAnyFormalReceiptExists() async throws {
        let fixture = try await Fixture()
        try await fixture.archive.applyReceipt(ReceiptApplied(receipt: fixture.receipt))
        var writer = try PCM16SegmentWriter(directory: fixture.root.appendingPathComponent("delayed-incoming"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: fixture.source, sourceBuild: "inbox-recovery-test",
            sourceKind: .watch, wallClockAnchor: Date(), timezoneOffset: 0)
        _ = try writer.append(Array(repeating: Int16(1), count: 160))
        let chunk = try XCTUnwrap(writer.finish())
        let item = try fixture.archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope)
        let original = item.directoryURL.appendingPathComponent("audio")
        let held = fixture.root.appendingPathComponent("temporarily-unavailable.pcm")
        try FileManager.default.moveItem(at: original, to: held)
        let first = expectation(description: "Uncommitted original schedules recovery")
        let second = expectation(description: "Committed original waits for ReceiptApplied")
        let sleeper = PhoneReceiptRecoverySleeper(expectations: [first, second])
        addTeardownBlock { await sleeper.cancelAll() }
        let coordinator = PhoneReceiveCoordinator(archive: fixture.archive, controls: fixture.controls, identity: fixture.identity,
            recoverySleep: { try await sleeper.sleep($0) })
        var received: [UUID] = []
        coordinator.onAudioReceived = { received.append($0) }
        await coordinator.reconcile()
        await fulfillment(of: [first], timeout: 5)
        let pendingBeforeRepair = try await fixture.archive.pendingReceiptCount()
        XCTAssertEqual(pendingBeforeRepair, 0)
        XCTAssertEqual(try fixture.archive.inbox.pendingItems().count, 1)
        XCTAssertTrue(received.isEmpty)
        try FileManager.default.moveItem(at: held, to: original)
        await sleeper.releaseNext()
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(received, [chunk.envelope.manifest.chunkID])
        XCTAssertTrue(try fixture.archive.inbox.pendingItems().isEmpty)
        let pendingReceipts = try await fixture.archive.pendingReceipts()
        let receipt = try XCTUnwrap(pendingReceipts.first)
        XCTAssertEqual(receipt.manifestSHA256, chunk.envelope.manifestSHA256)
        try fixture.controls.preserve(.receiptApplied(ReceiptApplied(receipt: receipt)))
        await sleeper.releaseNext()
        let deadline = ContinuousClock.now + .seconds(5)
        while try fixture.controls.hasPending(), ContinuousClock.now < deadline { await Task.yield() }
        let receiptsAfterApplication = try await fixture.archive.pendingReceiptCount()
        XCTAssertEqual(receiptsAfterApplication, 0)
        let delays = await sleeper.durations
        XCTAssertEqual(delays, [.seconds(30), .seconds(60)])
    }

    func testCancelledInboxDrainHandsItsPersistedWorkToAutomaticRecovery() async throws {
        let fixture = try await Fixture()
        try await fixture.archive.applyReceipt(ReceiptApplied(receipt: fixture.receipt))
        let first = expectation(description: "Cancelled caller leaves an independent recovery")
        let sleeper = PhoneReceiptRecoverySleeper(expectations: [first])
        addTeardownBlock { await sleeper.cancelAll() }
        let coordinator = PhoneReceiveCoordinator(archive: fixture.archive, controls: fixture.controls, identity: fixture.identity,
            recoverySleep: { try await sleeper.sleep($0) })
        let mark = try CaptureMark(sessionID: fixture.session, epochID: fixture.epoch, sourceDeviceID: fixture.source, sourceFrame: 1)
        try fixture.controls.preserve(.captureMark(mark))
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await coordinator.reconcile()
        }
        await caller.value
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(try fixture.controls.pending(), [.captureMark(mark)])
        await sleeper.releaseNext()
        let deadline = ContinuousClock.now + .seconds(5)
        while try fixture.controls.hasPending(), ContinuousClock.now < deadline { await Task.yield() }
        let marks = try await fixture.archive.marks(sessionID: fixture.session)
        XCTAssertEqual(marks, [mark])
        XCTAssertTrue(try fixture.controls.pending().isEmpty)
    }

    func testForeignReceiptFailureCannotReplaceCurrentWatchFailureOrReappearAfterClearingDisplayedStatus() async throws {
        let fixture = try await Fixture(), coordinator = fixture.coordinator()
        var writer = try PCM16SegmentWriter(directory: fixture.root.appendingPathComponent("other-watch"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "other-watch",
            sourceKind: .watch, wallClockAnchor: Date(), timezoneOffset: 0)
        _ = try writer.append([Int16](repeating: 0, count: 1600))
        let chunk = try XCTUnwrap(writer.finish())
        let item = try fixture.archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope)
        guard case .accepted(let foreign) = try await fixture.archive.commitReceivedChunk(item) else {
            XCTFail("Expected the other Watch's audio to remain archived"); return
        }
        let clock = try await fixture.selectWatch(on: coordinator)
        await coordinator.receive(.selectedWatchStatusReceived(try fixture.snapshot(revision: 1),
            origin: .applicationContextCallback, context: clock.receive()))
        var banner: String?
        coordinator.onSyncFailure = { banner = $0 }
        let failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue))
        await coordinator.receive(.controlTransportFinished(message: .receipt(fixture.receipt), failure: failure))
        let currentFailure = try XCTUnwrap(banner)
        await coordinator.receive(.controlTransportFinished(message: .receipt(foreign), failure: failure))
        XCTAssertEqual(banner, currentFailure)
        await coordinator.receive(.controlTransportFinished(message: .receipt(fixture.receipt), failure: nil))
        XCTAssertNil(banner)
        coordinator.clearDeletedStatus(sessionID: fixture.session)
        XCTAssertNil(coordinator.currentWatchStatus)
        await coordinator.receive(.controlTransportFinished(message: .receipt(foreign), failure: failure))
        XCTAssertNil(banner, "Clearing a displayed report must not forget which physical Watch is selected.")
        let pending = try await fixture.archive.pendingReceipts()
        XCTAssertEqual(pending.count, 2, "Retiring a transport error is not ReceiptApplied.")
        XCTAssertTrue(pending.contains(fixture.receipt) && pending.contains(foreign))
    }

    func testFullBackgroundQueueStillAllowsForegroundRecoveryWithoutAdvancingUnconfirmedOutbox() throws {
        let queued = (0..<32).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
        let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        let first = try transport.reserveControlRoutes(message, outstanding: queued, isReachable: true, now: 100)
        XCTAssertEqual(first.background, .deferred)
        XCTAssertEqual(first.interactive, .submitted)
        let repeated = try transport.reserveControlRoutes(message, outstanding: queued, isReachable: true, now: 101)
        XCTAssertEqual(repeated.background, .deferred)
        XCTAssertEqual(repeated.interactive, .alreadySubmitted)
        transport.finishInteractive(message, failed: false)
        let preserved = try transport.reserveControlRoutes(message, outstanding: queued, isReachable: true, now: 102)
        XCTAssertEqual(preserved.background, .alreadySubmitted)
        let next = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
        let stillFull = try transport.reserveControlRoutes(next, outstanding: queued, isReachable: false, now: 103)
        XCTAssertEqual(stillFull.background, .deferred, "The peer's inbox reply does not free queued system copies.")
        XCTAssertEqual(stillFull.interactive, .deferred)
    }

    func testFailedForegroundRecoveryAlsoBacksOffWithoutConsumingMoreOfTheDurableBacklog() throws {
        let queued = (0..<32).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
        let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        let first = try transport.reserveControlRoutes(message, outstanding: queued, isReachable: true)
        XCTAssertEqual(first.interactive, .submitted)
        transport.finishInteractive(message, failed: true)
        XCTAssertTrue(transport.hasRetryableControls)
        let unrelated = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
        let retry = try transport.reserveControlRoutes(unrelated, outstanding: queued, isReachable: true)
        XCTAssertEqual(retry.background, .deferred)
        XCTAssertEqual(retry.interactive, .deferred)
    }

    func testChannelCooldownUsesTypedSystemFailuresInsteadOfDescriptionsOrMessageErrors() {
        XCTAssertTrue(WatchConnectivityTransport.isControlChannelFailure(
            TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.genericError.rawValue))))
        XCTAssertTrue(WatchConnectivityTransport.isTransientChannelFailure(
            TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.genericError.rawValue))))
        XCTAssertTrue(WatchConnectivityTransport.isTransientChannelFailure(
            TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.messageReplyTimedOut.rawValue))))
        XCTAssertTrue(WatchConnectivityTransport.isTransientChannelFailure(TransportFailure(LinkError.notReachable)))
        XCTAssertFalse(WatchConnectivityTransport.isControlChannelFailure(
            TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue))))
        XCTAssertFalse(WatchConnectivityTransport.isTransientChannelFailure(
            TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue))))
        XCTAssertFalse(WatchConnectivityTransport.isControlChannelFailure(
            TransportFailure(NSError(domain: NSCocoaErrorDomain, code: WCError.Code.genericError.rawValue))))
    }

    func testSenderPublishesDeliveryOnlyAfterSuccessfulDurableInboxReply() async throws {
        let fixture = try await Fixture(), message = ControlMessage.receipt(fixture.receipt)
        let received = expectation(description: "Peer preserved the control")
        received.assertForOverFulfill = true
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { event in
            guard case .controlTransportFinished(let delivered, let failure) = event else {
                XCTFail("Unexpected event"); return
            }
            XCTAssertEqual(delivered, message)
            XCTAssertNil(failure)
            received.fulfill()
        })
        transport.finishInteractive(message, failed: true)
        transport.finishInteractive(message, failed: false)
        await fulfillment(of: [received], timeout: 5)
    }

    func testDurableInboxDeliveryClearsOnlyTransportFailureAndStillWaitsForReceiptApplication() async throws {
        let fixture = try await Fixture(), coordinator = fixture.coordinator()
        let message = ControlMessage.receipt(fixture.receipt)
        let transient = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.genericError.rawValue))
        let failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue))
        var banner: String?, fileFailure: String?
        coordinator.onSyncFailure = { banner = $0 }
        coordinator.onFailure = { fileFailure = $0 }
        coordinator.onFailure("保留原音错误")
        await coordinator.receive(.controlTransportFinished(message: message, failure: transient))
        XCTAssertNil(banner, "Transient background channel 7001 errors must retry silently without popping a banner.")
        await coordinator.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertNotNil(banner)
        await coordinator.receive(.controlTransportFinished(message: message, failure: nil))
        XCTAssertNil(banner)
        XCTAssertEqual(fileFailure, "保留原音错误")
        let pending = try await fixture.archive.pendingReceipts()
        XCTAssertEqual(pending, [fixture.receipt], "A preserved control is not ReceiptApplied and cannot release the original.")
        try fixture.controls.preserve(.receiptApplied(ReceiptApplied(receipt: fixture.receipt)))
        await coordinator.reconcile()
        let applied = try await fixture.archive.pendingReceipts()
        XCTAssertTrue(applied.isEmpty)
    }

    func testFailedOriginalRepairStillRefreshesAvailabilityWithoutPreparingPeaks() async throws {
        let fixture = try await Fixture(), coordinator = fixture.coordinator()
        let lease = try await fixture.archive.acquireAudioLease(chunkID: fixture.envelope.manifest.chunkID)
        let audioURL = lease.audioURL
        await fixture.archive.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: audioURL)
        let incoming = fixture.root.appendingPathComponent("damaged-repair.wav")
        try Data(repeating: 1, count: Int(fixture.envelope.manifest.byteCount)).write(to: incoming)
        _ = try fixture.archive.inbox.preserve(fileURL: incoming, envelope: fixture.envelope)
        var changes = 0, peaks = 0
        var failure: String?
        coordinator.onChanged = { changes += 1 }
        coordinator.onAudioReceived = { _ in peaks += 1 }
        coordinator.onFailure = { failure = $0 }
        await coordinator.reconcile()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(peaks, 0)
        XCTAssertNotNil(failure)
        let receipts = try await fixture.archive.pendingReceipts()
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRepeatedAudioOnlyWakesProcessingWhenItRestoresMissingOriginal() async throws {
        let fixture = try await Fixture(), coordinator = fixture.coordinator()
        let lease = try await fixture.archive.acquireAudioLease(chunkID: fixture.envelope.manifest.chunkID)
        let audioURL = lease.audioURL
        let audio = try Data(contentsOf: audioURL)
        await fixture.archive.releaseAudioLease(id: lease.id)
        var libraryRefreshes = 0, waveformPreparations = 0
        coordinator.onChanged = { libraryRefreshes += 1 }
        coordinator.onAudioReceived = { _ in waveformPreparations += 1 }
        for _ in 0..<50 {
            let incoming = fixture.root.appendingPathComponent("duplicate-\(UUID()).wav")
            try audio.write(to: incoming)
            _ = try fixture.archive.inbox.preserve(fileURL: incoming, envelope: fixture.envelope)
        }
        await coordinator.reconcile()
        XCTAssertEqual(libraryRefreshes, 0, "Unchanged retransmissions must not reload the library or restart ASR.")
        XCTAssertEqual(waveformPreparations, 0, "Existing peaks must not be scheduled again for duplicate bytes.")
        let receipts = try await fixture.archive.pendingReceipts()
        XCTAssertEqual(receipts, [fixture.receipt])
        libraryRefreshes = 0; waveformPreparations = 0
        try FileManager.default.removeItem(at: audioURL)
        let repair = fixture.root.appendingPathComponent("repair.wav")
        try audio.write(to: repair)
        _ = try fixture.archive.inbox.preserve(fileURL: repair, envelope: fixture.envelope)
        await coordinator.reconcile()
        XCTAssertEqual(libraryRefreshes, 1)
        XCTAssertEqual(waveformPreparations, 1)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
    }

    func testControlFailureRecoversIndependentlyAndAppliedReceiptRejectsLateFailureAfterRestart() async throws {
        let fixture = try await Fixture(), coordinator = fixture.coordinator()
        let agent = try PhoneRemoteAgent(directory: fixture.root.appendingPathComponent("remote"), archive: fixture.archive, deviceID: fixture.receiver)
        let runtime = try PhoneRuntime(archive: fixture.archive, remoteAgent: agent,
            playback: AudioPlaybackController(archive: fixture.archive), receiver: coordinator,
            transport: nil, speech: nil, speechFailure: nil)
        let message = ControlMessage.receipt(fixture.receipt)
        let failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "格式不支持"]))
        coordinator.onFailure("原音文件需要检查")
        await coordinator.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertTrue(runtime.syncFailure?.contains("WCErrorDomain 7010") == true)
        XCTAssertEqual(runtime.failure, "原音文件需要检查")
        let unrelated = ControlMessage.receiverIdentity(fixture.identity)
        await coordinator.receive(.controlTransportFinished(message: unrelated, failure: nil))
        XCTAssertNotNil(runtime.syncFailure)
        runtime.dismissFailure()
        XCTAssertNil(runtime.syncFailure)
        XCTAssertNil(runtime.failure)
        await coordinator.receive(.controlTransportFinished(message: unrelated, failure: nil))
        XCTAssertNil(runtime.syncFailure, "Unrelated completions must not re-pop a dismissed sync failure.")
        coordinator.onFailure("原音文件需要检查")
        await coordinator.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertNotNil(runtime.syncFailure)
        try fixture.controls.preserve(.receiptApplied(ReceiptApplied(receipt: fixture.receipt)))
        await coordinator.reconcile()
        XCTAssertNil(runtime.syncFailure)
        XCTAssertEqual(runtime.failure, "原音文件需要检查")
        let restarted = fixture.coordinator()
        var lateFailure: String?
        restarted.onSyncFailure = { lateFailure = $0 }
        restarted.onFailure = { lateFailure = $0 }
        await restarted.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertNil(lateFailure)
    }

    func testMaintenanceFailureStillLoadsRecordingsAndRecoveryKeepsUnrelatedFailure() async throws {
        let fixture = try await Fixture()
        let plan = try await fixture.archive.savePlan(operationID: UUID(), title: "旧资料", body: "测试", sources: [])
        let planURL = try await fixture.archive.planFileURL(id: plan.id, expectedRevision: plan.revision)
        try await fixture.archive.deletePlan(id: plan.id, expectedRevision: plan.revision)
        let external = fixture.root.appendingPathComponent("preserved.txt")
        try Data("preserved".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: planURL, withDestinationURL: external)
        let agent = try PhoneRemoteAgent(directory: fixture.root.appendingPathComponent("remote"), archive: fixture.archive, deviceID: fixture.receiver)
        let runtime = try PhoneRuntime(archive: fixture.archive, remoteAgent: agent,
            playback: AudioPlaybackController(archive: fixture.archive), receiver: fixture.coordinator(),
            transport: nil, speech: nil, speechFailure: nil)
        await runtime.start()
        XCTAssertTrue(runtime.ready)
        XCTAssertEqual(runtime.library.recordings.map(\.id), [fixture.session])
        XCTAssertNotNil(runtime.refreshFailure)
        let unrelatedFailure = try XCTUnwrap(runtime.failure)
        try FileManager.default.removeItem(at: planURL)
        await runtime.refresh()
        XCTAssertNil(runtime.refreshFailure)
        XCTAssertEqual(runtime.failure, unrelatedFailure)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "preserved")
    }

    func testReceiptAcknowledgementsAndEmptyPassesDoNotReloadTheWholeLibrary() async throws {
        let fixture = try await Fixture()
        let coordinator = fixture.coordinator()
        var changes = 0
        coordinator.onChanged = { changes += 1 }
        await coordinator.reconcile()
        XCTAssertEqual(changes, 0)
        try fixture.controls.preserve(.receiptApplied(ReceiptApplied(receipt: fixture.receipt)))
        await coordinator.reconcile()
        XCTAssertEqual(changes, 0)
        let pending = try await fixture.archive.pendingReceiptCount()
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(try fixture.controls.pending().isEmpty)
    }

    func testUnacknowledgedReceiptRetriesWithoutAnotherConnectivityEventAndStopsAfterApplication() async throws {
        let fixture = try await Fixture()
        let first = expectation(description: "First autonomous receipt retry")
        let second = expectation(description: "Receipt retry backs off")
        let sleeper = PhoneReceiptRecoverySleeper(expectations: [first,second])
        addTeardownBlock { await sleeper.cancelAll() }
        let coordinator = PhoneReceiveCoordinator(archive: fixture.archive, controls: fixture.controls, identity: fixture.identity,
            recoverySleep: { try await sleeper.sleep($0) })
        await coordinator.reconcile()
        await fulfillment(of: [first], timeout: 5)
        await sleeper.releaseNext()
        await fulfillment(of: [second], timeout: 5)
        try fixture.controls.preserve(.receiptApplied(ReceiptApplied(receipt: fixture.receipt)))
        // No foreground return or new WC event follows the durable inbox write.
        await sleeper.releaseNext()
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await fixture.archive.pendingReceipts()).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for:.milliseconds(10))
        }
        let pending = try await fixture.archive.pendingReceipts()
        XCTAssertTrue(pending.isEmpty)
        let delays = await sleeper.durations
        XCTAssertEqual(delays,[.seconds(30),.seconds(60)])
        XCTAssertTrue(try fixture.controls.pending().isEmpty)
    }

    func testInteractiveAcknowledgementRequiresSuccessfulDurablePreservation() async throws {
        let fixture = try await Fixture(), message = ControlMessage.receiverIdentity(ReceiverIdentity(messageID:UUID(),
            receiverDeviceID: UUID(), libraryInstanceID: UUID()))
        let transport = try WatchConnectivityTransport(preserveFile: { _,_ in },
            preserveControl: { try fixture.controls.preserve($0) }, event: { _ in })
        transport.session(WCSession.default,didReceiveMessage:try LinkWireFormat.controlMetadata(message),replyHandler: { reply in
            XCTAssertEqual(reply["control_preserved"] as? Bool,true)
            XCTAssertEqual(try? fixture.controls.pending(),[message])
        })
        let failed = try WatchConnectivityTransport(preserveFile: { _,_ in },
            preserveControl: { _ in throw CocoaError(.fileWriteOutOfSpace) }, event: { _ in })
        failed.session(WCSession.default,didReceiveMessage:try LinkWireFormat.controlMetadata(message),replyHandler: { reply in
            XCTAssertEqual(reply["control_preserved"] as? Bool,false)
        })
    }
    func testUnboundWatchStatusWaitsForIdentityWithoutErrorOrAcknowledgement() async throws {
        let fixture = try await Fixture()
        let coordinator = fixture.coordinator()
        let request = try fixture.request()
        try fixture.controls.preserve(.reconcileRequest(request))
        var failures: [String] = [], changes = 0
        coordinator.onStatusFailure = { if let message = $0 { failures.append(message) } }
        coordinator.onStatusChanged = { changes += 1 }
        await coordinator.receive(.statusReceived(try fixture.snapshot(revision: 1, receiverBound: false),
                                                  origin: .restoredApplicationContext))
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(try fixture.controls.pending() == [.reconcileRequest(request)])
        let status = try await fixture.archive.watchStatus(sessionID: fixture.session)
        let receipts = try await fixture.archive.pendingReceipts()
        XCTAssertNil(status)
        XCTAssertEqual(receipts, [fixture.receipt])
    }

    func testFailedResponseTransportRequeuesThePersistedResponseBeforeNextActivation() async throws {
        let fixture = try await Fixture()
        let request = try fixture.request()
        let response = try await fixture.archive.receiveReconcileRequest(request)
        try await fixture.archive.markReconcileResponseSubmitted(messageID: response.messageID)
        let coordinator = fixture.coordinator()
        let failure = TransportFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        await coordinator.receive(.controlTransportFinished(message: .reconcileResponse(response), failure: failure))
        let reopened = try ArchiveStore(rootURL: fixture.archive.rootURL, receiverDeviceID: fixture.receiver)
        let pending = try await reopened.pendingReconcileResponses()
        XCTAssertEqual(pending, [response])
        let receipts = try await reopened.pendingReceipts()
        XCTAssertEqual(receipts, [fixture.receipt])
    }

    func testCachedStatusRetainsHistoryWithoutDrainingControlsOrCreatingAcknowledgements() async throws {
        let fixture = try await Fixture()
        let coordinator = fixture.coordinator()
        var statusChanges = 0, reconcileChanges = 0
        var failures: [String] = []
        coordinator.onStatusChanged = { statusChanges += 1 }
        coordinator.onChanged = { reconcileChanges += 1 }
        coordinator.onStatusFailure = { if let message = $0 { failures.append(message) } }
        // A waiting control makes accidental reconciliation observable, even without a paired Watch.
        let request = try fixture.request()
        try fixture.controls.preserve(.reconcileRequest(request))
        let snapshot = try fixture.snapshot(revision: 4)
        await coordinator.receive(.statusReceived(snapshot, origin: .restoredApplicationContext))
        await coordinator.receive(.statusReceived(snapshot, origin: .applicationContextCallback))
        let cached = try await fixture.archive.watchStatus(sessionID: fixture.session)
        XCTAssertEqual(cached?.snapshot, snapshot)
        XCTAssertNil(cached?.observedAt)
        XCTAssertEqual(cached?.restored, true)
        XCTAssertEqual(statusChanges, 1)
        XCTAssertEqual(reconcileChanges, 0)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(try fixture.controls.pending(), [.reconcileRequest(request)])
        let responses = try await fixture.archive.pendingReconcileResponses()
        let receipts = try await fixture.archive.pendingReceipts()
        XCTAssertTrue(responses.isEmpty)
        XCTAssertEqual(receipts, [fixture.receipt])

        let newer = try fixture.snapshot(revision: 5)
        await coordinator.receive(.statusReceived(newer, origin: .applicationContextCallback))
        XCTAssertEqual(statusChanges, 2)
        XCTAssertEqual(reconcileChanges, 0)
        let observed = try await fixture.archive.watchStatus(sessionID: fixture.session)
        XCTAssertNotNil(observed?.observedAt)
    }

    func testWrongLibraryStatusCannotReplaceReportAndControlsSurviveCoordinatorRestart() async throws {
        let fixture = try await Fixture()
        let first = fixture.coordinator()
        let clock = try await fixture.selectWatch(on: first)
        let snapshot = try fixture.snapshot(revision: 3)
        await first.receive(.selectedWatchStatusReceived(snapshot, origin: .applicationContextCallback, context: clock.receive()))
        var failures: [String] = [], changes = 0
        first.onStatusFailure = { if let message = $0 { failures.append(message) } }
        first.onStatusChanged = { changes += 1 }
        let wrongLibrary = try fixture.snapshot(revision: 4, library: UUID())
        await first.receive(.selectedWatchStatusReceived(wrongLibrary, origin: .applicationContextCallback, context: clock.receive()))
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(failures[0].contains("ArchiveStatusError"))
        XCTAssertEqual(changes, 0)
        let request = try fixture.request()
        try fixture.controls.preserve(.reconcileRequest(request))

        let reopened = try ArchiveStore(rootURL: fixture.archive.rootURL, receiverDeviceID: fixture.receiver)
        let controls = try ControlInbox(directory: fixture.controls.directory)
        let second = PhoneReceiveCoordinator(archive: reopened, controls: controls, identity: fixture.identity)
        await second.reconcile()
        XCTAssertTrue(try controls.pending().isEmpty)
        let responses = try await reopened.pendingReconcileResponses()
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(try XCTUnwrap(responses.first).matches(request))
        XCTAssertEqual(responses.first?.results.map(\.state), [.received(fixture.receipt)])
        let report = try await reopened.watchStatus(sessionID: fixture.session)
        XCTAssertEqual(report?.snapshot, snapshot)
        let receipts = try await reopened.pendingReceipts()
        XCTAssertEqual(receipts, [fixture.receipt], "Neither a status nor a response submission is ReceiptApplied")
    }

    func testStatusRecoveryClearsItsBannerWithoutHidingOtherFailures() async throws {
        let fixture = try await Fixture()
        let coordinator = fixture.coordinator()
        let agent = try PhoneRemoteAgent(directory: fixture.root.appendingPathComponent("remote"), archive: fixture.archive, deviceID: fixture.receiver)
        let runtime = try PhoneRuntime(archive: fixture.archive, remoteAgent: agent,
            playback: AudioPlaybackController(archive: fixture.archive), receiver: coordinator,
            transport: nil, speech: nil, speechFailure: nil)
        let clock = try await fixture.selectWatch(on: coordinator)
        let snapshot = try fixture.snapshot(revision: 1)
        await coordinator.receive(.selectedWatchStatusReceived(snapshot, origin: .applicationContextCallback, context: clock.receive()))
        coordinator.onStatusFailure("状态连接失败")
        coordinator.onFailure("音频需要重试")
        XCTAssertEqual(runtime.statusFailure, "状态连接失败")
        await coordinator.receive(.selectedWatchStatusReceived(snapshot, origin: .applicationContextCallback, context: clock.receive()))
        XCTAssertNil(runtime.statusFailure)
        XCTAssertEqual(runtime.failure, "音频需要重试")
        runtime.dismissFailure()
        XCTAssertNil(runtime.failure)
        XCTAssertNil(runtime.statusFailure)
    }

    func testConfirmedInteractiveResponseMarksResponseSubmittedAndAvoidsReceiptStarvation() async throws {
        let fixture = try await Fixture()
        let response = try await fixture.archive.receiveReconcileRequest(fixture.request())
        let coordinator = fixture.coordinator()
        let message = ControlMessage.reconcileResponse(response)
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        coordinator.attach(transport)
        // Simulate Watch confirming durable interactive preservation of a ReconcileResponse while background transfer was deferred.
        transport.finishInteractive(message, failed: false)
        await coordinator.receive(.controlTransportFinished(message: message, failure: nil))
        let pendingResponses = try await fixture.archive.pendingReconcileResponses()
        XCTAssertTrue(pendingResponses.isEmpty)
    }

    func testInteractiveReconcileReplyDeliversReceiptsDuringStagedCompanionUpdate() async throws {
        let fixture = try await Fixture()
        let coordinator = fixture.coordinator()
        let clock = SelectedWatchEventClock()
        await coordinator.receive(.selectedWatchChanged(clock.select(
            activation: .activated, peerState: .companionNotInstalled, directoryURL: nil)))

        let phoneTransport = try WatchConnectivityTransport(
            preserveFile: { _, _ in },
            preserveControl: { try fixture.controls.preserve($0) },
            event: { _ in },
            controlReplyProvider: { [weak coordinator] message in
                await coordinator?.inlineControlReply(for: message)
            }
        )
        coordinator.attach(phoneTransport)

        let watchInbox = try ControlInbox(directory: fixture.root.appendingPathComponent("WatchControlInbox", isDirectory: true))
        let watchNotified = expectation(description: "watch control preserved")
        watchNotified.expectedFulfillmentCount = 2
        let watchTransport = try WatchConnectivityTransport(
            preserveFile: { _, _ in },
            preserveControl: { try watchInbox.preserve($0) },
            event: { if case .controlPreserved = $0 { watchNotified.fulfill() } }
        )

        let request = try fixture.request()
        let replied = expectation(description: "reconcile reply returned over interactive replyHandler")
        phoneTransport.session(WCSession.default,
            didReceiveMessage: try LinkWireFormat.controlMetadata(.reconcileRequest(request)),
            replyHandler: { reply in
                XCTAssertTrue(watchTransport.ingestInteractiveControlReply(reply))
                replied.fulfill()
            })
        await fulfillment(of: [replied], timeout: 5.0)

        let receivedOnWatch = try watchInbox.pending()
        XCTAssertEqual(receivedOnWatch.count, 1)
        guard case .reconcileResponse(let response) = try XCTUnwrap(receivedOnWatch.first) else {
            return XCTFail("Expected ReconcileResponse in Watch ControlInbox")
        }
        XCTAssertTrue(try response.matches(request))
        XCTAssertEqual(response.results.map(\.state), [.received(fixture.receipt)])
        let pendingOnPhone = try await fixture.archive.pendingReconcileResponses()
        XCTAssertTrue(pendingOnPhone.isEmpty, "Inline reply while companionNotInstalled must not leave unsubmitted responses spinning")
        XCTAssertTrue(try fixture.controls.pending().isEmpty)

        // Mismatched receiver during staged update also returns ReceiverIdentity inline.
        let wrongReceiverRequest = try ReconcileRequest(
            messageID: UUID(), sourceDeviceID: fixture.source,
            receiverDeviceID: UUID(), libraryInstanceID: fixture.archive.libraryInstanceID,
            items: request.items)
        let identityReplied = expectation(description: "identity reply returned over interactive replyHandler")
        phoneTransport.session(WCSession.default,
            didReceiveMessage: try LinkWireFormat.controlMetadata(.reconcileRequest(wrongReceiverRequest)),
            replyHandler: { reply in
                XCTAssertTrue(watchTransport.ingestInteractiveControlReply(reply))
                identityReplied.fulfill()
            })
        await fulfillment(of: [identityReplied, watchNotified], timeout: 5.0)
        XCTAssertTrue(try watchInbox.pending().contains(.receiverIdentity(fixture.identity)))
    }

    func testMultiPageInboxDrainKeepsCallbacksOnMainActorAndCoalescesNotifications() async throws {
        let fixture = try await Fixture()
        let coordinator = fixture.coordinator()
        var writer = try PCM16SegmentWriter(
            directory: fixture.root.appendingPathComponent("capture-batch"),
            sessionID: UUID(),
            epochID: UUID(),
            sourceDeviceID: fixture.source,
            sourceBuild: "status-test",
            sourceKind: .watch,
            targetFrames: 800,
            wallClockAnchor: Date(),
            timezoneOffset: 28800
        )
        var expectedChunkIDs: Set<UUID> = []
        for index in 0..<70 {
            let sealed = try XCTUnwrap(writer.append([Int16](repeating: Int16(index + 1), count: 800)).first)
            expectedChunkIDs.insert(sealed.envelope.manifest.chunkID)
            _ = try fixture.archive.inbox.preserve(fileURL: sealed.audioURL, envelope: sealed.envelope)
        }
        var receivedChunkIDs: [UUID] = []
        var changedCount = 0
        coordinator.onAudioReceived = { id in
            MainActor.assertIsolated()
            receivedChunkIDs.append(id)
        }
        coordinator.onChanged = {
            MainActor.assertIsolated()
            changedCount += 1
            _ = try? await fixture.archive.pendingReceiptCount()
        }
        await coordinator.reconcile()
        XCTAssertEqual(receivedChunkIDs.count, 70)
        XCTAssertEqual(Set(receivedChunkIDs), expectedChunkIDs)
        let remainingInbox = try await fixture.archive.listPendingInboxItems(limit: 10)
        XCTAssertTrue(remainingInbox.isEmpty)
        XCTAssertGreaterThanOrEqual(changedCount, 2)
        XCTAssertLessThanOrEqual(changedCount, 6)
    }
}

private actor PhoneReceiptRecoverySleeper {
    let expectations: [XCTestExpectation]
    private(set) var durations: [Duration] = []
    private var waits: [UUID: CheckedContinuation<Void, any Error>] = [:]
    init(expectations: [XCTestExpectation]) { self.expectations = expectations }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing:CancellationError()); return }
                waits[id] = continuation; durations.append(duration)
                if durations.count <= expectations.count { expectations[durations.count - 1].fulfill() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func releaseNext() {
        guard let id = waits.keys.first else { return }
        waits.removeValue(forKey:id)?.resume()
    }
    private func cancel(_ id: UUID) { waits.removeValue(forKey:id)?.resume(throwing:CancellationError()) }
    func cancelAll() {
        let pending = waits.values; waits.removeAll()
        for continuation in pending { continuation.resume(throwing:CancellationError()) }
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let archive: ArchiveStore
    let controls: ControlInbox
    let receiver = UUID(), source = UUID(), session = UUID(), epoch = UUID(), store = UUID()
    let envelope: ManifestEnvelope
    let receipt: Receipt
    var identity: ReceiverIdentity {
        ReceiverIdentity(messageID: receiver, receiverDeviceID: receiver, libraryInstanceID: archive.libraryInstanceID)
    }
    init() async throws {
        // Coordinators and reopened archives can retain SQLite until the host exits; the runner cleans up then.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoPhoneStatus-\(UUID())")
        archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: receiver)
        controls = try ControlInbox(directory: root.appendingPathComponent("controls"))
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("capture"),
            sessionID: session, epochID: epoch, sourceDeviceID: source, sourceBuild: "status-test",
            sourceKind: .watch, wallClockAnchor: Date(), timezoneOffset: 28800)
        _ = try writer.append([Int16](repeating: 0, count: 1600))
        let chunk = try XCTUnwrap(writer.finish())
        envelope = chunk.envelope
        let item = try archive.inbox.preserve(fileURL: chunk.audioURL, envelope: envelope)
        guard case .accepted(let receipt) = try await archive.commitReceivedChunk(item) else {
            throw ArchiveError.invalidInbox
        }
        self.receipt = receipt
    }
    func coordinator() -> PhoneReceiveCoordinator { PhoneReceiveCoordinator(archive: archive, controls: controls, identity: identity) }
    func selectWatch(on coordinator: PhoneReceiveCoordinator) async throws -> SelectedWatchEventClock {
        let directory = root.appendingPathComponent("selected-watch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = SelectedWatchEventClock()
        await coordinator.receive(.selectedWatchChanged(clock.select(activation: .activated,
            peerState: .available, directoryURL: directory)))
        return clock
    }
    func request() throws -> ReconcileRequest {
        try ReconcileRequest(sourceDeviceID: source, receiverDeviceID: receiver, libraryInstanceID: archive.libraryInstanceID,
            items: [ReconcileChunkIdentity(envelope: envelope)])
    }
    func snapshot(revision: Int64, library: UUID? = nil, receiverBound: Bool = true) throws -> StatusSnapshot {
        try StatusSnapshot(sourceDeviceID: source, sourceBuild: "status-test", sourceStoreInstanceID: store,
            revision: revision, sampledAt: Date(timeIntervalSince1970: Double(revision)),
            payload: .watch(WatchCaptureStatus(receiverLibraryInstanceID: receiverBound ? library ?? archive.libraryInstanceID : nil,
                sessionID: session, epochID: epoch, activity: .recording, capturedDuration: 30, sealedDuration: 0.1,
                pendingChunkCount: 1, pendingBytes: envelope.manifest.byteCount,
                lastSampleFrame: 480_000, timebaseHz: 16_000, lastSampleAge: 0.01)))
    }
}
