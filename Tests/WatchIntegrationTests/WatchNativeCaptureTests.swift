import AVFAudio
import Foundation
import Observation
import SwiftUI
import XCTest
import MoMoContracts
import MoMoLink
import WatchConnectivity
@testable import MoMoRecording
@testable import MoMoAgentWatch

#if DEBUG && targetEnvironment(simulator)
@MainActor
final class WatchNativeCaptureTests: XCTestCase {
    func testMacOriginRejectsCredentialsAndPlaintextOutsideLoopback() throws {
        let valid = try WatchMacLink.origin(for: "  https://momo.example.test:8443/ ")
        XCTAssertEqual(valid.host, "momo.example.test")
        XCTAssertEqual(valid.port, 8443)
        XCTAssertNoThrow(try WatchMacLink.origin(for: "http://127.0.0.1:8080"))
        for address in ["http://momo.example.test", "https://user:secret@momo.example.test",
                        "https://momo.example.test/api", "https://momo.example.test/?key=abc", "https://momo.example.test/#abc"] {
            XCTAssertThrowsError(try WatchMacLink.origin(for: address), address)
        }
    }

    func testSavedMacReceiverKeepsOriginalUntilMatchingMacReceiptAfterRelaunch() async throws {
        let runID = UUID()
        let fixture = try WatchComposition.makeSimulatorTest(runID: runID)
        let store = try RecordingStore(rootURL: fixture.rootURL)
        let device = UUID()
        let phone = UUID()
        let phoneLibrary = UUID()
        try await store.bindReceiver(deviceID: phone, libraryInstanceID: phoneLibrary)
        let bytes = Data(repeating: 1, count: 320)
        let source = fixture.rootURL.appendingPathComponent("before-receiver-change.pcm")
        try bytes.write(to: source)
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: device, sourceBuild: "test",
            sequence: 0, frames: FrameRange(start: 0, count: 160), timebaseHz: 16_000,
            wallClockAnchor: Date(), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000,
            channels: 1, decodedFrameCount: 160, byteCount: 320,
            audioSHA256: ContentHash.sha256(bytes), sourceKind: .fixture))
        let chunk = try await store.sealChunk(audioAt: source, envelope: envelope)
        let chunkID = envelope.manifest.chunkID
        let stale = try Receipt(receiverDeviceID: phone, libraryInstanceID: phoneLibrary, chunkID: chunkID,
                                audioSHA256: envelope.manifest.audioSHA256, manifestSHA256: envelope.manifestSHA256)
        _ = try await store.applyReceipt(stale)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        try controls.preserve(.receipt(stale))
        let grant = WatchMacLink.Grant(id: UUID(), origin: try WatchMacLink.origin(for: "https://mac.example.test"),
                                       token: "fixture-watch-token", receiver: UUID(), library: UUID())
        // Simulate process termination between atomically saving the selection and binding the ledger.
        try JSONEncoder().encode(grant).write(to: fixture.rootURL.appendingPathComponent("mac-receiver.json"))
        let restored = try WatchComposition.makeSimulatorTest(runID: runID).runtime
        XCTAssertEqual(restored.macLink.grant, grant)
        try await restored.macLink.restoreReceiver()
        await restored.handleLinkEvent(.controlPreserved)
        XCTAssertEqual(try controls.pending(), [.receipt(stale)])
        let request = WatchMacLink.uploadRequest(for: grant, envelope: envelope)
        XCTAssertEqual(request.url?.path, "/api/watch/chunks/" + chunkID.uuidString.lowercased())
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-watch-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-MoMo-Manifest"), envelope.manifestData.base64EncodedString())
        let wrongHash = try Receipt(receiverDeviceID: grant.receiver, libraryInstanceID: grant.library, chunkID: chunkID,
                                    audioSHA256: envelope.manifest.audioSHA256, manifestSHA256: ContentHash.sha256(Data()))
        for untrusted in [stale, wrongHash] {
            do {
                try await restored.macLink.acknowledge(WireJSON.encode(untrusted), for: chunkID, grant: grant)
                XCTFail("Only a receipt for this receiver, library and both content hashes can release the original.")
            } catch WatchMacLink.Failure.invalidReceipt {
                XCTAssertEqual(untrusted, stale)
            } catch RecordingError.receiptMismatch {
                XCTAssertEqual(untrusted, wrongHash)
            }
            let cleaned = try await store.cleanupAcknowledgedChunks()
            XCTAssertTrue(cleaned.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        }
        let valid = try Receipt(receiverDeviceID: grant.receiver, libraryInstanceID: grant.library, chunkID: chunkID,
                                audioSHA256: envelope.manifest.audioSHA256, manifestSHA256: envelope.manifestSHA256)
        try await restored.macLink.acknowledge(WireJSON.encode(valid), for: chunkID, grant: grant)
        let reopened = try RecordingStore(rootURL: fixture.rootURL)
        let confirmed = try await reopened.confirmedReceipt(chunkID: chunkID)
        XCTAssertEqual(confirmed, valid)
        let cleaned = try await reopened.cleanupAcknowledgedChunks()
        XCTAssertEqual(cleaned, [chunkID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.audioURL.path))
    }

    func testPairedMacHTTPUploadReturnsDurableReceipt() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let owner = environment["MOMO_MAC_TEST_OWNER"], let origin = environment["MOMO_MAC_TEST_ORIGIN"] else {
            throw XCTSkip("Start an isolated MobileWeb server and supply its owner and public loopback URLs.")
        }
        let ownerURL = try WatchMacLink.origin(for: owner)
        let publicURL = try WatchMacLink.origin(for: origin)
        XCTAssertEqual(ownerURL.host, "127.0.0.1")
        XCTAssertEqual(publicURL.host, "127.0.0.1")
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        let store = try RecordingStore(rootURL: fixture.rootURL)
        await runtime.bootstrap()
        let device = try XCTUnwrap(UUID(uuidString: String(contentsOf: fixture.rootURL.appendingPathComponent("device-id"), encoding: .utf8)))
        let frames = 16000
        let source = fixture.rootURL.appendingPathComponent("watch-test.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = buffer.frameCapacity
        let pcm = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<frames { pcm[i] = Float(sin(Double(i) * 2 * Double.pi * 440 / 16000)) * 0.2 }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            let output = try AVAudioFile(forWriting: source, settings: settings)
            try output.write(from: buffer)
        }
        let bytes = try Data(contentsOf: source)
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: device, sourceBuild: "watch-http-test",
            sequence: 0, frames: FrameRange(start: 0, count: Int64(frames)), timebaseHz: 16_000,
            wallClockAnchor: Date(), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
            decodedFrameCount: Int64(frames), byteCount: Int64(bytes.count), audioSHA256: ContentHash.sha256(bytes), sourceKind: .watch))
        let chunk = try await store.sealChunk(audioAt: source, envelope: envelope)

        var invite = URLRequest(url: ownerURL.appendingPathComponent("invite"))
        invite.httpMethod = "POST"
        invite.setValue("application/json", forHTTPHeaderField: "Content-Type")
        invite.setValue(owner, forHTTPHeaderField: "Origin")
        invite.httpBody = Data(#"{"role":"watch"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: invite)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let code = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String)
        try await runtime.connectMac(address: origin, code: code)
        let bound = try XCTUnwrap(runtime.macLink.grant)
        let deadline = ContinuousClock.now + .seconds(90)
        while FileManager.default.fileExists(atPath: chunk.audioURL.path) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        let reopened = try RecordingStore(rootURL: fixture.rootURL)
        let receipt = try await reopened.confirmedReceipt(chunkID: envelope.manifest.chunkID)
        XCTAssertEqual(receipt?.receiverDeviceID, bound.receiver, runtime.macLink.problem ?? "Mac receipt unavailable")
        XCTAssertEqual(receipt?.libraryInstanceID, bound.library)
        XCTAssertEqual(receipt?.manifestSHA256, envelope.manifestSHA256)
        XCTAssertEqual(receipt?.audioSHA256, envelope.manifest.audioSHA256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.audioURL.path))
    }

    func testColdGrantPublishesBindingWithoutStartingCaptureAndBoundsStatusWrites() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), archiveRecovery: { _ in
            XCTFail("Cold status must not open historical audio."); return RecordingRecoveryReport()
        })
        let runtime = fixture.runtime, store = try RecordingStore(rootURL: fixture.rootURL)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let receiver = UUID(), library = UUID()
        try controls.preserve(.receiverIdentity(ReceiverIdentity(messageID: UUID(), receiverDeviceID: receiver, libraryInstanceID: library)))
        var reports: [StatusSnapshot] = []
        runtime.statusPublisher = { reports.append($0) }
        runtime.beginConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        for _ in 0..<3 { _ = await runtime.drainBackgroundConnectivity() }
        XCTAssertEqual(reports.count, 1)
        let reply = try await runtime.statusSnapshot()
        guard case .watch(let status) = reply.payload else { return XCTFail("Expected Watch status") }
        XCTAssertEqual(status.receiverLibraryInstanceID, library)
        XCTAssertEqual(status.activity, .idle)
        XCTAssertNil(status.lastSampleFrame)
        XCTAssertEqual(reply.sourceStoreInstanceID, reports.first?.sourceStoreInstanceID)
        XCTAssertGreaterThan(reply.revision, try XCTUnwrap(reports.first?.revision))
        let bound = try await store.boundReceiver()
        XCTAssertEqual(bound?.libraryInstanceID, library)
        XCTAssertFalse(runtime.captureReady)
        XCTAssertNil(runtime.epochID)
        runtime.endConnectivityGrant()
    }

    func testColdGrantChecksInboxBeforeDelayedActivationEventAndKeepsRecoveryScheduled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delayed-activation-\(UUID())")
        let store = try RecordingStore(rootURL: root)
        let controls = try ControlInbox(directory: root.appendingPathComponent("ControlInbox"))
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in throw CaptureTestError.archiveUnavailable },
            preserveControl: { try controls.preserve($0) }, event: { _ in })
        let runtime = WatchRuntime(store: store, encoderDirectory: root.appendingPathComponent("Encoding"),
            sourceDeviceID: UUID(), sourceBuild: "activation-order-test", controls: controls, transport: transport,
            archiveRecovery: { _ in XCTFail("A cold grant must not scan historical audio."); return RecordingRecoveryReport() })
        runtime.configureSimulatorTestCapture()
        // This saved receipt cannot be applied until the receiver identity arrives.
        try controls.preserve(.receipt(Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(), chunkID: UUID(),
            audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))))
        var wakes = 0
        runtime.onBackgroundRetryNeeded = { wakes += 1 }
        runtime.beginConnectivityGrant()
        // Advance the transport, but deliberately hold its event before the runtime's actor hop.
        transport.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while transport.activation != .activated, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(transport.activation, .activated)
        let result = await runtime.drainBackgroundConnectivity()
        XCTAssertEqual(result, .pending, "Transport activation alone must not finish a cold grant.")
        XCTAssertGreaterThan(wakes, 0, "Durable Inbox work must be observed before the delayed event.")
        runtime.endConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        XCTAssertTrue(try controls.hasPending())
        XCTAssertFalse(runtime.captureReady)
        XCTAssertNil(runtime.epochID)
    }

    func testColdGrantExpirationBeforeFirstScanRequestsAnotherWake() throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        var wakes = 0
        fixture.runtime.onBackgroundRetryNeeded = { wakes += 1 }
        fixture.runtime.beginConnectivityGrant()
        fixture.runtime.endConnectivityGrant()
        XCTAssertGreaterThan(wakes, 0, "Unknown local work cannot be treated as an empty outbox.")
        XCTAssertFalse(fixture.runtime.captureReady)
        XCTAssertNil(fixture.runtime.epochID)
    }

    func testColdGrantExpirationAfterEmptyScanStillRetriesUnpublishedBinding() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        var wakes = 0
        fixture.runtime.onBackgroundRetryNeeded = { wakes += 1 }
        fixture.runtime.beginConnectivityGrant()
        _ = await fixture.runtime.drainBackgroundConnectivity()
        wakes = 0
        fixture.runtime.endConnectivityGrant()
        XCTAssertGreaterThan(wakes, 0, "A checked empty Inbox does not prove that the binding summary was sent.")
        XCTAssertFalse(fixture.runtime.captureReady)
    }

    func testColdStatusPublicationExpiredDuringAwaitDoesNotCompleteTheNextGrant() async throws {
        let publishing = expectation(description: "First cold publication is suspended")
        let gate = RecoverySleeper(expectations: [publishing])
        addTeardownBlock { await gate.cancelAll() }
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        var publications = 0, wakes = 0
        runtime.onBackgroundRetryNeeded = { wakes += 1 }
        runtime.statusPublisher = { _ in
            publications += 1
            if publications == 1 { try await gate.sleep(.seconds(1)) }
        }
        runtime.beginConnectivityGrant()
        let first = Task { await runtime.handleLinkEvent(.activationChanged(.activated)) }
        await fulfillment(of: [publishing], timeout: 5)
        runtime.endConnectivityGrant()
        XCTAssertGreaterThan(wakes, 0)
        runtime.beginConnectivityGrant()
        await gate.releaseNext()
        await first.value
        _ = await runtime.drainBackgroundConnectivity()
        XCTAssertEqual(publications, 2, "A completed publication from an expired grant cannot satisfy a newer grant.")
        XCTAssertFalse(runtime.captureReady)
        runtime.endConnectivityGrant()
    }

    func testColdConnectivityGrantDrainsBoundedPagesWithoutHistoricalRecoveryOrMicrophone() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), archiveRecovery: { _ in
            XCTFail("A WC background grant must not recover the entire recording archive.")
            return RecordingRecoveryReport()
        })
        let runtime = fixture.runtime
        let store = try RecordingStore(rootURL: fixture.rootURL)
        let inbox = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let receiver = UUID(), library = UUID()
        try await store.bindReceiver(deviceID: receiver, libraryInstanceID: library)
        let deviceID = try XCTUnwrap(UUID(uuidString: String(contentsOf: fixture.rootURL.appendingPathComponent("device-id"), encoding: .utf8)))
        var writer = try PCM16SegmentWriter(directory: fixture.rootURL.appendingPathComponent("cold-grant-audio"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: deviceID, sourceBuild: "cold-grant-test",
            sourceKind: .fixture, targetFrames: 160, wallClockAnchor: Date(), timezoneOffset: 0)
        for _ in 0..<8 {
            let chunk = try XCTUnwrap(writer.append(Array(repeating: 1, count: 160)).first)
            _ = try await store.sealChunk(audioAt: chunk.audioURL, envelope: chunk.envelope)
            try inbox.preserve(.receipt(Receipt(receiverDeviceID: receiver, libraryInstanceID: library,
                chunkID: chunk.envelope.manifest.chunkID, audioSHA256: chunk.envelope.manifest.audioSHA256,
                manifestSHA256: chunk.envelope.manifestSHA256)))
        }
        runtime.beginConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        XCTAssertEqual(try inbox.pending().count, 4)
        let firstPending = try await store.pendingChunkCount()
        XCTAssertEqual(firstPending, 4)
        _ = await runtime.drainBackgroundConnectivity()
        await runtime.handleLinkEvent(.controlPreserved)
        XCTAssertEqual(try inbox.pending().count, 4, "The four-message budget is exhausted; later events must not reset it.")
        XCTAssertFalse(runtime.captureReady)
        XCTAssertEqual(runtime.archiveState, .idle)
        XCTAssertNil(runtime.epochID)
        runtime.endConnectivityGrant()
        runtime.beginConnectivityGrant()
        _ = await runtime.drainBackgroundConnectivity()
        XCTAssertTrue(try inbox.pending().isEmpty)
        let secondPending = try await store.pendingChunkCount()
        XCTAssertEqual(secondPending, 0)
        XCTAssertNil(runtime.epochID)
        runtime.endConnectivityGrant()
    }

    func testEmptyBackgroundPassStillAppliesALateReceiptWithinTheSameGrant() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime, store = try RecordingStore(rootURL: fixture.rootURL)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let receiver = UUID(), library = UUID(), device = UUID()
        try await store.bindReceiver(deviceID: receiver, libraryInstanceID: library)
        var writer = try PCM16SegmentWriter(directory: fixture.rootURL.appendingPathComponent("late-grant-source"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: device, sourceBuild: "late-grant-test",
            sourceKind: .fixture, targetFrames: 160, wallClockAnchor: Date(), timezoneOffset: 0)
        let segment = try XCTUnwrap(writer.append(Array(repeating: 1, count: 160)).first)
        let chunk = try await store.sealChunk(audioAt: segment.audioURL, envelope: segment.envelope)
        runtime.beginConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        XCTAssertTrue(try controls.pending().isEmpty)
        try controls.preserve(.receipt(Receipt(receiverDeviceID: receiver, libraryInstanceID: library,
            chunkID: chunk.envelope.manifest.chunkID, audioSHA256: chunk.envelope.manifest.audioSHA256,
            manifestSHA256: chunk.envelope.manifestSHA256)))
        await runtime.handleLinkEvent(.controlPreserved)
        let pending = try await store.pendingChunkCount()
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(try controls.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        XCTAssertFalse(runtime.captureReady)
        XCTAssertNil(runtime.epochID)
        runtime.endConnectivityGrant()
    }

    func testBackgroundCompletionPollingDoesNotRepeatBlockedInboxWork() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let receiver = UUID(), library = UUID()
        try controls.preserve(.receipt(Receipt(receiverDeviceID: receiver, libraryInstanceID: library,
            chunkID: UUID(), audioSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64))))
        var wakes = 0
        runtime.onBackgroundRetryNeeded = { wakes += 1 }
        runtime.statusPublisher = { _ in }
        runtime.beginConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        XCTAssertGreaterThan(wakes, 0)
        let firstPassWakes = wakes
        for _ in 0..<100 { _ = await runtime.drainBackgroundConnectivity() }
        XCTAssertEqual(wakes, firstPassWakes, "Waiting for WC must not rescan the blocked inbox on every poll.")
        XCTAssertEqual(try controls.pending().count, 1)

        runtime.endConnectivityGrant()
        runtime.beginConnectivityGrant()
        let beforeNewGrant = wakes
        _ = await runtime.drainBackgroundConnectivity()
        XCTAssertGreaterThan(wakes, beforeNewGrant, "A new grant must retry durable work even without a new event.")
        try controls.preserve(.receiverIdentity(ReceiverIdentity(messageID: UUID(), receiverDeviceID: receiver,
            libraryInstanceID: library)))
        await runtime.handleLinkEvent(.controlPreserved)
        XCTAssertTrue(try controls.pending().isEmpty, "An arriving identity must immediately unblock the saved receipt.")
        runtime.endConnectivityGrant()
    }

    func testActiveDrainRetriesBlockedWorkOncePerDrainAndOnNewEvents() async throws {
        let firstRetry = expectation(description: "Initial reconciliation found the blocked receipt")
        let sleeper = RecoverySleeper(expectations: [firstRetry])
        addTeardownBlock { await sleeper.cancelAll() }
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), recoverySleep: { try await sleeper.sleep($0) })
        let runtime = fixture.runtime
        let inbox = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let receiver = UUID(), library = UUID()
        try inbox.preserve(.receipt(Receipt(receiverDeviceID: receiver, libraryInstanceID: library, chunkID: UUID(),
            audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))))
        await runtime.bootstrap()
        await fulfillment(of: [firstRetry], timeout: 5)
        XCTAssertFalse(runtime.requiresConstrainedConnectivityGrant)

        var retries = 0
        runtime.onBackgroundRetryNeeded = { retries += 1 }
        let drainID = UUID()
        _ = await runtime.drainActiveConnectivity(for: drainID)
        XCTAssertGreaterThan(retries, 0)
        let firstPassRetries = retries
        for _ in 0..<100 { _ = await runtime.drainActiveConnectivity(for: drainID) }
        XCTAssertEqual(retries, firstPassRetries)
        XCTAssertEqual(try inbox.pending().count, 1)
        _ = await runtime.drainActiveConnectivity(for: UUID())
        XCTAssertGreaterThan(retries, firstPassRetries)

        try inbox.preserve(.receiverIdentity(ReceiverIdentity(messageID: UUID(), receiverDeviceID: receiver, libraryInstanceID: library)))
        await runtime.handleLinkEvent(.controlPreserved)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testUnchangedBackgroundInboxCursorDoesNotRewriteItsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-write-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try ControlInbox(directory: root)
        _ = try inbox.loadBackgroundPage(limit: 4)
        let position = root.appendingPathComponent(".background-position")
        // Keep the original inode alive so repeated atomic replacement cannot recycle it.
        // Read fresh filesystem attributes rather than URL resource values or a synthetic date.
        let original = try FileHandle(forReadingFrom: position)
        defer { try? original.close() }
        let before = try FileManager.default.attributesOfItem(atPath: position.path)
        let originalFile = try XCTUnwrap(before[.systemFileNumber] as? NSNumber)
        let originalDate = try XCTUnwrap(before[.modificationDate] as? Date)
        let reopened = try ControlInbox(directory: root)
        for _ in 0..<100 { _ = try reopened.loadBackgroundPage(limit: 4) }
        let after = try FileManager.default.attributesOfItem(atPath: position.path)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, originalFile, "An unchanged cursor must keep the same file.")
        XCTAssertEqual(after[.modificationDate] as? Date, originalDate)

        for _ in 0..<5 {
            try inbox.preserve(.receiverIdentity(ReceiverIdentity(messageID: UUID(), receiverDeviceID: UUID(), libraryInstanceID: UUID())))
        }
        let first = try reopened.loadBackgroundPage(limit: 4)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(try String(contentsOf: position, encoding: .utf8), first.scannedThrough)
        let second = try inbox.loadBackgroundPage(limit: 4)
        XCTAssertEqual(second.messages.count, 1)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(try String(contentsOf: position, encoding: .utf8), "")
    }

    func testLocalInboxAloneRequestsAnotherBackgroundWakeWithoutStartingCapture() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        // Identity has not arrived; this receipt must wait durably even when there is no queued audio.
        try controls.preserve(.receipt(Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(), chunkID: UUID(),
            audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))))
        var wakes = 0
        runtime.onBackgroundRetryNeeded = { wakes += 1 }
        runtime.beginConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        runtime.endConnectivityGrant()
        XCTAssertTrue(try controls.hasPending())
        XCTAssertGreaterThan(wakes, 0)
        XCTAssertFalse(runtime.captureReady)
        XCTAssertNil(runtime.epochID)
    }

    func testInboxPreservedAfterColdGrantEndsStillRequestsAnotherWake() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        runtime.beginConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        runtime.endConnectivityGrant()
        var wakes = 0
        runtime.onBackgroundRetryNeeded = { wakes += 1 }
        try controls.preserve(.receipt(Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(), chunkID: UUID(),
            audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))))
        await runtime.handleLinkEvent(.controlPreserved)
        XCTAssertGreaterThan(wakes, 0)
        XCTAssertTrue(try controls.hasPending())
        XCTAssertFalse(runtime.captureReady)
        XCTAssertNil(runtime.epochID)
    }

    func testGrantExpirationDuringLedgerAwaitKeepsReceiptRecoveryScheduled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grant-expiration-\(UUID())")
        let store = try RecordingStore(rootURL: root)
        let controls = try ControlInbox(directory: root.appendingPathComponent("ControlInbox"))
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in throw CaptureTestError.archiveUnavailable },
            preserveControl: { try controls.preserve($0) }, event: { _ in })
        let runtime = WatchRuntime(store: store, encoderDirectory: root.appendingPathComponent("Encoding"),
            sourceDeviceID: UUID(), sourceBuild: "grant-expiration-test", controls: controls, transport: transport)
        runtime.configureSimulatorTestCapture()
        let receiver = UUID(), library = UUID()
        try await store.bindReceiver(deviceID: receiver, libraryInstanceID: library)
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("source"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "grant-expiration-test", sourceKind: .fixture,
            targetFrames: 160, wallClockAnchor: Date(), timezoneOffset: 0)
        let segment = try XCTUnwrap(writer.append(Array(repeating: 1, count: 160)).first)
        let chunk = try await store.sealChunk(audioAt: segment.audioURL, envelope: segment.envelope)
        try controls.preserve(.receipt(Receipt(receiverDeviceID: receiver, libraryInstanceID: library,
            chunkID: chunk.envelope.manifest.chunkID, audioSHA256: chunk.envelope.manifest.audioSHA256,
            manifestSHA256: chunk.envelope.manifestSHA256)))
        let barrier = SyncLedgerTestBarrier()
        let holding = Task.detached { await store.holdSyncTestBarrier(barrier) }
        defer { barrier.release.signal() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        var wakes = 0
        runtime.onBackgroundRetryNeeded = { wakes += 1 }
        runtime.beginConnectivityGrant()
        let draining = Task { @MainActor in
            await runtime.handleLinkEvent(.activationChanged(.activated))
        }
        let position = controls.directory.appendingPathComponent(".background-position")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: position.path), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: position.path), "Inbox page must be read before expiring the grant.")
        // The ledger actor is occupied; expiration occurs before its first reconciliation await can return.
        runtime.endConnectivityGrant()
        barrier.release.signal()
        await holding.value
        await draining.value
        XCTAssertGreaterThan(wakes, 0)
        XCTAssertTrue(try controls.pending().isEmpty)
        let applications = try await store.pendingReceiptApplications()
        XCTAssertEqual(applications.map(\.receipt.chunkID), [chunk.envelope.manifest.chunkID])
        XCTAssertFalse(runtime.captureReady)
        XCTAssertNil(runtime.epochID)
    }

    func testLegacyAndForeignDeletionCannotRemoveAnOriginalAfterReceiverChange() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime, store = try RecordingStore(rootURL: fixture.rootURL)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let receiver = UUID(), oldLibrary = UUID(), newLibrary = UUID()
        try await store.bindReceiver(deviceID: receiver, libraryInstanceID: oldLibrary)
        var writer = try PCM16SegmentWriter(directory: fixture.rootURL.appendingPathComponent("scope-source"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "deletion-scope-test",
            sourceKind: .fixture, targetFrames: 160, wallClockAnchor: Date(), timezoneOffset: 0)
        let segment = try XCTUnwrap(writer.append(Array(repeating: 1, count: 160)).first)
        let chunk = try await store.sealChunk(audioAt: segment.audioURL, envelope: segment.envelope)
        try await store.replaceReceiverAfterUserConfirmation(deviceID: receiver, libraryInstanceID: newLibrary)
        let legacy = try DeleteSession(sessionID: chunk.envelope.manifest.sessionID, generation: 1)
        try controls.preserve(.deleteSession(legacy))
        try controls.preserve(.deleteSession(legacy.scoped(receiverDeviceID: receiver, libraryInstanceID: oldLibrary)))
        runtime.beginConnectivityGrant()
        await runtime.handleLinkEvent(.activationChanged(.activated))
        let pending = try await store.pendingChunkCount()
        XCTAssertEqual(pending, 1)
        XCTAssertTrue(try controls.pending().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        XCTAssertNil(runtime.epochID)
        runtime.endConnectivityGrant()
    }

    func testBackgroundInboxPageAdvancesAcrossReopeningWithoutDiscardingBlockedMessages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("background-inbox-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let inbox = try ControlInbox(directory: root)
        for _ in 0..<9 {
            try inbox.preserve(.receiverIdentity(ReceiverIdentity(messageID: UUID(), receiverDeviceID: UUID(), libraryInstanceID: UUID())))
        }
        let first = try inbox.loadBackgroundPage(limit: 4)
        let reopened = try ControlInbox(directory: root)
        let second = try reopened.loadBackgroundPage(limit: 4)
        let third = try reopened.loadBackgroundPage(limit: 4)
        XCTAssertEqual(first.messages.count, 4)
        XCTAssertEqual(second.messages.count, 4)
        XCTAssertEqual(third.messages.count, 1)
        XCTAssertNotEqual(first.scannedThrough, second.scannedThrough)
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(try reopened.pending().count, 9)
        XCTAssertEqual(try reopened.loadBackgroundPage(limit: 4).scannedThrough, first.scannedThrough)
    }

    func testSyncAcknowledgesCommittedAudioWhileHistoricalValidationIsStillPending() async throws {
        let checking = expectation(description: "Historical validation is held")
        let gate = RecoverySleeper(expectations: [checking])
        addTeardownBlock { await gate.cancelAll() }
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), archiveRecovery: { store in
            try await gate.sleep(.seconds(1))
            return try await store.recover()
        })
        let store = try RecordingStore(rootURL: fixture.rootURL)
        var writer = try PCM16SegmentWriter(directory: fixture.rootURL.appendingPathComponent("sync-during-validation"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "recovery-sync-test", sourceKind: .fixture,
            wallClockAnchor: Date(), timezoneOffset: 0)
        _ = try writer.append([Int16](repeating: 0, count: 160))
        let sealed = try XCTUnwrap(writer.finish())
        let chunk = try await store.sealChunk(audioAt: sealed.audioURL, envelope: sealed.envelope)
        let receiver = UUID(), library = UUID()
        try await store.bindReceiver(deviceID: receiver, libraryInstanceID: library)
        let bootstrap = Task { await fixture.runtime.bootstrap() }
        addTeardownBlock { bootstrap.cancel(); _ = await bootstrap.result }
        await fulfillment(of: [checking], timeout: 5)
        XCTAssertTrue(fixture.runtime.captureReady)
        XCTAssertFalse(fixture.runtime.ready)
        let receipt = try Receipt(receiverDeviceID: receiver, libraryInstanceID: library,
            chunkID: chunk.envelope.manifest.chunkID, audioSHA256: chunk.envelope.manifest.audioSHA256,
            manifestSHA256: chunk.envelope.manifestSHA256)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        try controls.preserve(.receipt(receipt))
        await fixture.runtime.handleLinkEvent(.controlPreserved)
        XCTAssertTrue(try controls.pending().isEmpty)
        let current = try await store.chunk(id: receipt.chunkID)
        XCTAssertEqual(current?.state, .removed)
        XCTAssertFalse(fixture.runtime.ready)
        await gate.releaseNext()
        await bootstrap.value
        XCTAssertTrue(fixture.runtime.ready)
        XCTAssertNil(fixture.runtime.archiveFailure)
    }

    func testReceiptWithoutLocalManifestDoesNotRemainInInboxOrProduceAnApplicationAcknowledgement() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime, store = try RecordingStore(rootURL: fixture.rootURL)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let receiver = UUID(), library = UUID()
        try await store.bindReceiver(deviceID: receiver, libraryInstanceID: library)
        await runtime.bootstrap()
        let receipt = try Receipt(receiverDeviceID: receiver, libraryInstanceID: library, chunkID: UUID(),
            audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))
        try controls.preserve(.receipt(receipt))
        await runtime.handleLinkEvent(.controlPreserved)
        XCTAssertTrue(try controls.pending().isEmpty)
        let applications = try await store.controlBatch(kind: .receipt, after: 0, limit: 32)
        XCTAssertTrue(applications.isEmpty)
        XCTAssertNil(runtime.syncFailure)
    }

    func testHistoricalValidationDoesNotBlockStartingNativeCapture() async throws {
        let checking = expectation(description: "Historical validation is held")
        let gate = RecoverySleeper(expectations: [checking])
        addTeardownBlock { await gate.cancelAll() }
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), archiveRecovery: { store in
            try await gate.sleep(.seconds(1))
            return try await store.recover()
        })
        let runtime = fixture.runtime, store = try RecordingStore(rootURL: fixture.rootURL)
        addTeardownBlock { if await runtime.sessionID != nil { try await runtime.stop() } }
        let bootstrap = Task { await runtime.bootstrap() }
        addTeardownBlock { bootstrap.cancel(); _ = await bootstrap.result }
        await fulfillment(of: [checking], timeout: 5)
        XCTAssertTrue(runtime.captureReady)
        XCTAssertFalse(runtime.ready)
        XCTAssertTrue(runtime.isRecoveringArchive)
        XCTAssertNil(runtime.epochID, "Opening a fresh archive must not start the microphone.")

        var reported: [WatchCaptureActivity] = []
        let recordingReport = expectation(description: "Live microphone is reported before history validation completes")
        runtime.statusPublisher = { snapshot in
            guard case .watch(let status) = snapshot.payload else { return }
            reported.append(status.activity)
            if status.activity == .recording { recordingReport.fulfill() }
        }
        recordingReport.assertForOverFulfill = false
        await runtime.handleLinkEvent(.activationChanged(.activated))

        try await runtime.start()
        try await waitForFrames(1_600, in: runtime, timeout: .seconds(15))
        await fulfillment(of: [recordingReport], timeout: 5)
        XCTAssertTrue(reported.contains(.preparing) || reported.contains(.idle))
        let epoch = try XCTUnwrap(runtime.epochID)
        XCTAssertFalse(runtime.ready, "Real input must arrive before historical validation finishes.")
        await gate.releaseNext()
        await bootstrap.value
        XCTAssertTrue(runtime.ready)
        XCTAssertEqual(runtime.epochID, epoch)
        let open = try await store.isCaptureEpochOpen(epoch)
        XCTAssertTrue(open, "Historical recovery must not close the newly running writer.")
        XCTAssertNil(runtime.failure)
        XCTAssertNil(runtime.syncFailure)
        XCTAssertNil(runtime.archiveFailure)
    }

    func testSavedRecordingWaitsForTapButCanStartBeforeHistoricalValidationFinishes() async throws {
        let checking = expectation(description: "Historical validation is held after reading saved state")
        let gate = RecoverySleeper(expectations: [checking])
        addTeardownBlock { await gate.cancelAll() }
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), archiveRecovery: { store in
            try await gate.sleep(.seconds(1))
            return try await store.recover()
        })
        let runtime = fixture.runtime, store = try RecordingStore(rootURL: fixture.rootURL)
        let session = UUID(), oldEpoch = UUID()
        try await store.saveIntent(.recording, sessionID: session)
        try await store.beginEpoch(sessionID: session, epochID: oldEpoch, sourceDeviceID: UUID())
        addTeardownBlock { if await runtime.sessionID != nil { try await runtime.stop() } }
        let foreground = Task { await runtime.foreground() }
        addTeardownBlock { foreground.cancel(); _ = await foreground.result }
        await fulfillment(of: [checking], timeout: 5)
        XCTAssertTrue(runtime.captureReady)
        XCTAssertNil(runtime.sessionID)
        XCTAssertEqual(runtime.elapsedSeconds, 0)
        XCTAssertNil(runtime.epochID, "Opening the app must leave a stopped writer waiting for the start tap.")
        let oldIntent = try await store.intent(sessionID: session)
        XCTAssertEqual(oldIntent, .stopped)
        let readyReport = expectation(description: "A new process is ready to start a fresh recording")
        runtime.statusPublisher = { snapshot in
            guard case .watch(let status) = snapshot.payload else { return }
            if status.activity == .idle { readyReport.fulfill() }
        }
        readyReport.assertForOverFulfill = false
        await runtime.handleLinkEvent(.activationChanged(.activated))
        await fulfillment(of: [readyReport], timeout: 5)
        try await runtime.start()
        try await waitForFrames(1_600, in: runtime, timeout: .seconds(15))
        let newEpoch = try XCTUnwrap(runtime.epochID)
        XCTAssertNotEqual(runtime.sessionID, session)
        XCTAssertNotEqual(newEpoch, oldEpoch)
        XCTAssertFalse(runtime.ready)
        let oldOpen = try await store.isCaptureEpochOpen(oldEpoch)
        XCTAssertFalse(oldOpen)
        await gate.releaseNext()
        await foreground.value
        let newOpen = try await store.isCaptureEpochOpen(newEpoch)
        XCTAssertTrue(newOpen)
        XCTAssertEqual(runtime.captureState.activity, .recording)
        XCTAssertNil(runtime.syncFailure)
    }

    func testOpeningAppDoesNotStartSavedRecordingOrUnmute() async throws {
        for intent in [CaptureIntent.recording, .paused] {
            let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
            let runtime = fixture.runtime, store = try RecordingStore(rootURL: fixture.rootURL)
            try await store.saveIntent(intent, sessionID: UUID())
            addTeardownBlock { if await runtime.sessionID != nil { try await runtime.stop() } }
            await runtime.bootstrap()
            XCTAssertTrue(runtime.captureReady)
            XCTAssertNil(runtime.epochID, "Sync-only bootstrap must never activate input.")
            XCTAssertNil(runtime.sessionID)
            XCTAssertEqual(runtime.elapsedSeconds, 0)
            XCTAssertEqual(runtime.captureState.intent, .stopped)
            await runtime.foreground()
            await runtime.handleAudioEvent(.interruptionEnded(shouldResume: true))
            await runtime.handleAudioEvent(.mediaServicesReset)
            XCTAssertNil(runtime.epochID, "Foregrounding alone must not start capture.")
            XCTAssertTrue(runtime.requiresStartTap)
            XCTAssertEqual(runtime.captureState.intent, .stopped)
        }
    }

    func testHistoricalValidationFailureDoesNotDisableNativeCapture() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), archiveRecovery: { _ in
            throw CaptureTestError.archiveUnavailable
        })
        let runtime = fixture.runtime
        addTeardownBlock { if await runtime.sessionID != nil { try await runtime.stop() } }
        await runtime.bootstrap()
        XCTAssertTrue(runtime.captureReady)
        XCTAssertFalse(runtime.ready)
        XCTAssertEqual(runtime.archiveState, .failed)
        XCTAssertNil(runtime.failure)
        XCTAssertNotNil(runtime.archiveFailure)
        try await runtime.start()
        try await waitForFrames(1_600, in: runtime, timeout: .seconds(15))
        XCTAssertEqual(runtime.captureState.activity, .recording)
    }

    func testStartupDoesNotApplyIncomingReceiptsBeforeLocalRecoveryAndReportsReadyDuringSynchronization() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        let store = try RecordingStore(rootURL:fixture.rootURL)
        let controls = try ControlInbox(directory:fixture.rootURL.appendingPathComponent("ControlInbox"))
        var writer = try PCM16SegmentWriter(directory:fixture.rootURL.appendingPathComponent("startup-recording"),
            sessionID:UUID(),epochID:UUID(),sourceDeviceID:UUID(),sourceBuild:"startup-test",
            sourceKind:.fixture,wallClockAnchor:Date(),timezoneOffset:0)
        _ = try writer.append([Int16](repeating:0,count:160))
        let encoded = try XCTUnwrap(writer.finish())
        let chunk = try await store.sealChunk(audioAt:encoded.audioURL,envelope:encoded.envelope)
        let identity = ReceiverIdentity(messageID:UUID(),receiverDeviceID:UUID(),libraryInstanceID:UUID())
        let receipt = try Receipt(receiverDeviceID:identity.receiverDeviceID,libraryInstanceID:identity.libraryInstanceID,
            chunkID:encoded.envelope.manifest.chunkID,audioSHA256:encoded.envelope.manifest.audioSHA256,
            manifestSHA256:encoded.envelope.manifestSHA256)
        try controls.preserve(.receiverIdentity(identity))
        try controls.preserve(.receipt(receipt))
        await runtime.handleLinkEvent(.controlPreserved)
        XCTAssertFalse(runtime.ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath:chunk.audioURL.path))
        XCTAssertEqual(try controls.pending().count,2,"Controls must wait for local recovery.")
        await runtime.bootstrap()
        XCTAssertTrue(runtime.ready)
        XCTAssertEqual(runtime.archiveState,.ready)
        XCTAssertFalse(runtime.isRecoveringArchive)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try controls.pending()).isEmpty, ContinuousClock.now < deadline {
            _ = await runtime.drainBackgroundConnectivity()
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertTrue(try controls.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:chunk.audioURL.path))
        XCTAssertNil(runtime.epochID,"Synchronization must never activate the microphone.")
        XCTAssertNil(runtime.failure)
    }

    func testArchiveReadyDoesNotRemainInRecoveryWhileBacklogRetryIsScheduled() async throws {
        let first = expectation(description:"Backlog retry scheduled after archive recovery")
        let sleeper = RecoverySleeper(expectations:[first])
        addTeardownBlock { await sleeper.cancelAll() }
        let fixture = try WatchComposition.makeSimulatorTest(runID:UUID(),recoverySleep:{ try await sleeper.sleep($0) })
        let runtime = fixture.runtime, store = try RecordingStore(rootURL:fixture.rootURL)
        let original = fixture.rootURL.appendingPathComponent("retained.pcm"), bytes = Data(repeating:0,count:320)
        try bytes.write(to:original)
        let envelope = try ManifestEnvelope(manifest:ChunkManifest(sessionID:UUID(),epochID:UUID(),sourceDeviceID:UUID(),
            sourceBuild:"backlog-test",sequence:0,frames:FrameRange(start:0,count:160),timebaseHz:16000,
            wallClockAnchor:Date(),timezoneOffset:0,codec:.pcmInt16,sampleRate:16000,channels:1,
            decodedFrameCount:160,byteCount:320,audioSHA256:ContentHash.sha256(bytes),sourceKind:.fixture))
        _ = try await store.sealChunk(audioAt:original,envelope:envelope)
        runtime.onBackgroundRetryNeeded = {
            XCTAssertTrue(runtime.ready)
            XCTAssertFalse(runtime.isRecoveringArchive,"Background synchronization cannot keep the recording controls in archive recovery.")
        }
        await runtime.bootstrap()
        await fulfillment(of:[first],timeout:5)
        XCTAssertEqual(runtime.pendingChunkCount,1)
        XCTAssertNil(runtime.epochID)
    }

    func testPendingAudioAutomaticallyRetriesAndDrainsReceiptWithoutUserInteraction() async throws {
        let first = expectation(description: "First recovery interval")
        let second = expectation(description: "Backed off recovery interval")
        let sleeper = RecoverySleeper(expectations: [first, second])
        addTeardownBlock { await sleeper.cancelAll() }
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID(), recoverySleep: { try await sleeper.sleep($0) })
        let runtime = fixture.runtime
        await runtime.bootstrap()
        let store = try RecordingStore(rootURL: fixture.rootURL)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let identity = ReceiverIdentity(messageID: UUID(), receiverDeviceID: UUID(), libraryInstanceID: UUID())
        try await store.bindReceiver(deviceID: identity.receiverDeviceID, libraryInstanceID: identity.libraryInstanceID)
        var writer = try PCM16SegmentWriter(directory: fixture.rootURL.appendingPathComponent("retry-encoder"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "automatic-recovery-test",
            sourceKind: .fixture, targetFrames: 160, wallClockAnchor: Date(), timezoneOffset: 0)
        let segment = try XCTUnwrap(writer.append(Array(repeating: 0, count: 160)).first)
        _ = try writer.finish()
        let chunk = try await store.sealChunk(audioAt: segment.audioURL, envelope: segment.envelope)
        var backgroundRequests = 0
        runtime.onBackgroundRetryNeeded = { backgroundRequests += 1 }
        await runtime.handleLinkEvent(.activationChanged(.inactive))
        await fulfillment(of: [first], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        await sleeper.releaseNext()
        await fulfillment(of: [second], timeout: 5)
        let receipt = try Receipt(receiverDeviceID: identity.receiverDeviceID, libraryInstanceID: identity.libraryInstanceID,
            chunkID: segment.envelope.manifest.chunkID, audioSHA256: segment.envelope.manifest.audioSHA256,
            manifestSHA256: segment.envelope.manifestSHA256)
        try controls.preserve(.receipt(receipt))
        // No foreground, refresh button or link event follows the durable delivery.
        await sleeper.releaseNext()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while runtime.pendingChunkCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(runtime.pendingChunkCount, 0)
        XCTAssertNil(runtime.epochID)
        XCTAssertNil(runtime.syncFailure)
        XCTAssertGreaterThanOrEqual(backgroundRequests, 2)
        let delays = await sleeper.durations
        XCTAssertEqual(delays, [.seconds(30), .seconds(60)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        XCTAssertTrue(try controls.pending().isEmpty)
    }

    func testReceiptBeforeIdentityWaitsWithoutErrorThenAppliesAndCleansOriginal() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        await runtime.bootstrap()
        let store = try RecordingStore(rootURL: fixture.rootURL)
        let controls = try ControlInbox(directory: fixture.rootURL.appendingPathComponent("ControlInbox"))
        let source = fixture.rootURL.appendingPathComponent("receipt-test.pcm")
        let bytes = Data(repeating: 0, count: 320)
        try bytes.write(to: source)
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "tests",
            sequence: 0, frames: FrameRange(start: 0, count: 160), timebaseHz: 16_000,
            wallClockAnchor: Date(), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000,
            channels: 1, decodedFrameCount: 160, byteCount: 320,
            audioSHA256: ContentHash.sha256(bytes), sourceKind: .fixture))
        let chunk = try await store.sealChunk(audioAt: source, envelope: envelope)
        let identity = ReceiverIdentity(messageID: UUID(), receiverDeviceID: UUID(), libraryInstanceID: UUID())
        let receipt = try Receipt(receiverDeviceID: identity.receiverDeviceID,
            libraryInstanceID: identity.libraryInstanceID, chunkID: envelope.manifest.chunkID,
            audioSHA256: envelope.manifest.audioSHA256, manifestSHA256: envelope.manifestSHA256)
        try controls.preserve(.receipt(receipt))
        await runtime.handleLinkEvent(.controlPreserved)
        XCTAssertNil(runtime.syncFailure)
        XCTAssertNil(runtime.failure)
        XCTAssertEqual(try controls.pending(), [.receipt(receipt)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        let before = try await store.boundReceiver()
        XCTAssertNil(before)
        _ = await runtime.drainBackgroundConnectivity()
        XCTAssertEqual(runtime.pendingChunkCount, 1)
        XCTAssertNil(runtime.epochID, "Background synchronization must not start microphone capture.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        try controls.preserve(.receiverIdentity(identity))
        await runtime.handleLinkEvent(.controlPreserved)
        let receiver = try await store.boundReceiver()
        XCTAssertEqual(receiver?.libraryInstanceID, identity.libraryInstanceID)
        let applications = try await store.pendingReceiptApplications()
        XCTAssertEqual(applications.map(\.receipt), [receipt])
        XCTAssertTrue(try controls.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        XCTAssertNil(runtime.syncFailure)
    }

    func testTapMeterReceivesLiveTapPeaksWithoutWaitingForEncoderProgress() {
        let received = TapLevels()
        let relay = CaptureLevelRelay { received.append($0, at: $1) }
        relay.receive(rms: 0.1, at: 100)
        relay.receive(rms: 0.2, at: 100.025)
        relay.receive(rms: 0.9, at: 100.05)
        relay.receive(rms: 0.3, at: 100.075)
        XCTAssertTrue(received.values.map(\.rms) == [0.1])
        relay.receive(rms: 0.2, at: 100.1)
        XCTAssertTrue(received.values.map(\.rms) == [0.1, 0.9])

        // No encoder consumer or progress callback runs, including across a 60-second seal.
        for index in 5...2_800 { relay.receive(rms: 0.04, at: 100 + Double(index) / 40) }
        let levels = received.values
        XCTAssertTrue(levels.count == 701)
        XCTAssertTrue(levels.last?.uptime == 170)
        for (previous, next) in zip(levels, levels.dropFirst()) {
            XCTAssertTrue(next.uptime > previous.uptime)
            XCTAssertTrue(next.uptime - previous.uptime <= 0.126)
        }
    }

    func testTapMeterRejectsInvalidAndOldTapsAndResetsWithEachCapture() {
        let received = TapLevels()
        let relay = CaptureLevelRelay { received.append($0, at: $1) }
        relay.receive(rms: 0.1, at: 100)
        for time in [Double.nan, .infinity, -.infinity, -1, 99] { relay.receive(rms: 1, at: time) }
        for rms in [Float.nan, .infinity, -.infinity, -1] { relay.receive(rms: rms, at: 101) }
        XCTAssertTrue(received.values.count == 1)
        relay.receive(rms: 0, at: 100.1)
        XCTAssertTrue(received.values.map(\.rms) == [0.1, 0])
        let next = CaptureLevelRelay { received.append($0, at: $1) }
        next.receive(rms: 0.02, at: 1)
        XCTAssertTrue(received.values.last?.rms == 0.02)
        XCTAssertTrue(received.values.last?.uptime == 1)
    }

    func testProgressDeliveryCoalescesWithoutLosingSealedChunkOrWaitingForUI() async throws {
        let delivery = CaptureProgressDelivery()
        for index in 1...1_000 {
            delivery.receive(CaptureProgress(frames: Int64(index), uptime: Double(index),
                sealedChunkID: index == 30 ? UUID() : nil, normalizedLevel: 0.02))
        }
        let latest = try XCTUnwrap(delivery.take())
        XCTAssertEqual(latest.progress.frames, 1_000)
        XCTAssertNil(latest.progress.sealedChunkID)
        XCTAssertTrue(latest.hasSealedChunk, "A newer progress sample cannot swallow a durable chunk notification.")
        XCTAssertNotNil(delivery.lastReceivedAt)
        XCTAssertNil(delivery.take(), "The UI retains only the latest progress, not a replay backlog.")
        delivery.receive(CaptureProgress(frames: 1_001, uptime: 1_001, sealedChunkID: nil, normalizedLevel: 0))
        delivery.finish()
        var updates = delivery.updates.makeAsyncIterator()
        let finalSignal: Void? = await updates.next()
        XCTAssertNotNil(finalSignal)
        XCTAssertEqual(delivery.take()?.progress.frames, 1_001)
        let end: Void? = await updates.next()
        XCTAssertNil(end, "Completion drains the last update before ending the consumer.")
    }

    func testStatusRefreshRenewsAnUnchangedSourceObservation() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        await runtime.bootstrap()
        runtime.statusPublisher = { _ in } // Simulator has no paired WC peer.
        await runtime.handleLinkEvent(.activationChanged(.activated))
        var snapshots: [StatusSnapshot] = []
        let first = expectation(description: "First explicit source observation")
        let second = expectation(description: "Second explicit source observation")
        runtime.statusPublisher = { snapshot in
            snapshots.append(snapshot)
            if snapshots.count == 1 { first.fulfill() }
            if snapshots.count == 2 { second.fulfill() }
        }
        await runtime.handleLinkEvent(.statusRefreshRequested)
        await fulfillment(of: [first], timeout: 5)
        await runtime.handleLinkEvent(.statusRefreshRequested)
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(snapshots.count, 2)
        guard snapshots.count == 2 else { return }
        XCTAssertEqual(snapshots[0].payload, snapshots[1].payload)
        XCTAssertGreaterThan(snapshots[1].revision, snapshots[0].revision)
        XCTAssertGreaterThanOrEqual(snapshots[1].sampledAt, snapshots[0].sampledAt)
    }

    func testSuspendedStatusPublicationDoesNotBlockCaptureOrPause() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        await runtime.bootstrap()
        runtime.statusPublisher = { _ in } // Simulator has no paired WC peer.
        await runtime.handleLinkEvent(.activationChanged(.activated))
        let publishing = expectation(description: "Status publication is suspended")
        let gate = RecoverySleeper(expectations: [publishing])
        var publications = 0
        var lastActivity: WatchCaptureActivity?
        runtime.statusPublisher = { snapshot in
            publications += 1
            if case .watch(let status) = snapshot.payload { lastActivity = status.activity }
            if publications == 1 { try await gate.sleep(.seconds(1)) }
        }
        let start = Task { try await runtime.start() }
        addTeardownBlock {
            await gate.cancelAll()
            start.cancel(); _ = await start.result
            if await runtime.sessionID != nil { try await runtime.stop() }
        }
        await fulfillment(of: [publishing], timeout: 5)
        try await waitForFrames(16_000, in: runtime, timeout: .seconds(15))
        try await start.value
        let invalidations = TapLevels()
        withObservationTracking {
            _ = runtime.captureActivity
            _ = runtime.captureIntent
        } onChange: {
            invalidations.append(1, at: 0)
        }
        let frames = runtime.captureState.capturedFrames
        try await waitForFrames(frames + 8_000, in: runtime, timeout: .seconds(5))
        XCTAssertTrue(invalidations.values.isEmpty, "Frame progress must not invalidate phase-only recording controls.")
        XCTAssertEqual(publications, 1, "Repeated progress must coalesce while publication is suspended.")
        try await runtime.pause()
        XCTAssertEqual(invalidations.values.count, 1, "A real phase change must still update the recording controls.")
        XCTAssertEqual(runtime.captureState.intent, .paused)
        XCTAssertNil(runtime.epochID)
        XCTAssertEqual(publications, 1, "Saving the pause must not wait for status delivery.")
        await gate.releaseNext()
        let deadline = ContinuousClock.now + .seconds(5)
        while publications < 2, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(publications, 2, "One deferred publication must include the latest paused state.")
        XCTAssertEqual(lastActivity, .paused)
    }

    func testLiveMeterPublishesBeforeAnyEncoderConsumerRuns() async throws {
        let session = WatchAudioSession()
        try await session.activate()
        let engine = AudioCaptureEngine()
        let meter = CaptureMeter()
        let levels = expectation(description: "Three live meter updates without encoder progress")
        levels.expectedFulfillmentCount = 3
        do {
            let input = try engine.start(onLevel: { rms, uptime in
                Task { @MainActor in
                    meter.record(rms: rms, at: uptime)
                    levels.fulfill()
                }
            })
            // Leave the PCM stream unconsumed: a stalled encoder cannot gate metering.
            await fulfillment(of: [levels], timeout: 5)
            engine.stop()
            let health = engine.healthSnapshot
            XCTAssertGreaterThan(health.receivedFrames, 0)
            XCTAssertEqual(health.droppedBlocks, 0)
            var blocks = input.blocks.makeAsyncIterator()
            let first = try await blocks.next()
            XCTAssertFalse(try XCTUnwrap(first).mono.isEmpty)
            try await session.deactivate()
        } catch {
            engine.stop()
            try await session.deactivate()
            throw error
        }
    }

    func testMeterSeparatesQuietSpeechAndLoudInput() {
        XCTAssertEqual(CaptureMeter.strength(for: 0), 0)
        XCTAssertEqual(CaptureMeter.strength(for: .nan), 0)
        XCTAssertEqual(CaptureMeter.strength(for: .infinity), 0)
        XCTAssertEqual(CaptureMeter.strength(for: -1), 0)
        XCTAssertEqual(CaptureMeter.strength(for: 0.0001), 0)
        let quiet = CaptureMeter.strength(for: 0.0025)
        let soft = CaptureMeter.strength(for: 0.004)
        let speech = CaptureMeter.strength(for: 0.02)
        let loud = CaptureMeter.strength(for: 0.1)
        XCTAssertLessThan(quiet, 0.1)
        XCTAssertGreaterThan(soft, quiet + 0.1)
        XCTAssertGreaterThan(speech, soft + 0.3)
        XCTAssertGreaterThan(loud, speech + 0.35)
        XCTAssertEqual(loud, 1)
        XCTAssertEqual(CaptureMeter.strength(for: 2), 1)
    }

    func testMeterHistorySurvivesRepeatedForegroundWithoutOpeningMicrophone() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        await runtime.bootstrap()
        let meter = runtime.captureMeter
        for index in 0..<40 {
            meter.record(rms: 0.02, at: 100 + Double(index) / 10)
        }
        let history = meter.history
        XCTAssertEqual(history.count, 29)
        XCTAssertTrue(history.allSatisfy { $0 > 0 })

        for _ in 0..<3 {
            await runtime.foreground()
            XCTAssertTrue(runtime.captureMeter === meter)
            XCTAssertEqual(runtime.captureMeter.history, history,
                           "Returning to the foreground must not restart the visible history.")
        }
        meter.record(rms: 0.005, at: 104)
        XCTAssertNotEqual(meter.history, history)
        XCTAssertTrue(meter.history.dropLast(2).allSatisfy { $0 > 0 })
        XCTAssertNil(runtime.epochID, "This regression must not need microphone capture.")
    }

    func testQuietMeterStopsPublishingAndResumesForSpeech() {
        let meter = CaptureMeter()
        let invalidations = TapLevels()
        withObservationTracking { _ = meter.history } onChange: { invalidations.append(1, at: 0) }
        for index in 0..<600 { meter.record(rms: 0.0018, at: 100 + Double(index) / 10) }
        XCTAssertTrue(meter.history.allSatisfy { $0 == 0 })
        XCTAssertTrue(invalidations.values.isEmpty, "Idle dots do not need repeated SwiftUI updates.")
        meter.record(rms: 0.02, at: 160)
        XCTAssertEqual(invalidations.values.count, 1)
        XCTAssertGreaterThan(meter.history[28], 0)
        for index in 1...100 { meter.record(rms: 0, at: 160 + Double(index) / 10) }
        XCTAssertTrue(meter.history.allSatisfy { $0 == 0 }, "Invisible decay must settle instead of invalidating forever.")
        let settled = TapLevels()
        withObservationTracking { _ = meter.history } onChange: { settled.append(1, at: 0) }
        for index in 1...600 { meter.record(rms: 0, at: 170 + Double(index) / 10) }
        XCTAssertTrue(settled.values.isEmpty)
        meter.record(rms: 0.02, at: 231)
        XCTAssertEqual(settled.values.count, 1, "Speech must wake the meter immediately.")
    }

    func testMeterUsesCaptureTimeWithoutRestartingTheWaveformAfterCallbackGap() throws {
        let meter = CaptureMeter()
        meter.record(rms: 0.02, at: 100)
        let peak = try XCTUnwrap(meter.history.last)
        meter.record(rms: 0, at: 100.05)
        XCTAssertEqual(meter.history.last, peak, "Keep peaks within a 100ms display bucket.")
        meter.record(rms: 0, at: 100.2)
        XCTAssertEqual(meter.history[26], peak)
        XCTAssertEqual(meter.history[28], peak * 0.72 * 0.72, accuracy: 0.000001)

        let beforeInvalid = meter.history
        for time in [Double.nan, .infinity, -.infinity, -1, 99] {
            meter.record(rms: 1, at: time)
        }
        XCTAssertEqual(meter.history, beforeInvalid)
        meter.record(rms: 0.04, at: 104)
        XCTAssertEqual(Array(meter.history.dropLast()), Array(beforeInvalid.dropFirst()),
                       "The unlabelled envelope keeps the last observed samples across a suspended callback.")
        XCTAssertGreaterThan(meter.history[28], 0)
    }

    func testInactiveMeterSkipsHiddenSamplesAndWakesWithRetainedHistory() {
        let meter = CaptureMeter()
        for index in 0..<40 { meter.record(rms: 0.02, at: 100 + Double(index) / 10) }
        let visible = meter.history
        meter.setVisible(false)
        meter.record(rms: 0.1, at: 120)
        meter.record(rms: 0.03, at: 120.2)
        XCTAssertEqual(meter.history, visible, "Inactive UI keeps its last snapshot without publishing live meter changes.")
        meter.setVisible(true)
        XCTAssertEqual(meter.history, visible)
        meter.record(rms: 0.1, at: 121)
        XCTAssertNotEqual(meter.history, visible)
        XCTAssertTrue(meter.history.allSatisfy { $0 > 0 }, "Wake must not clear the left side and refill from the right.")
    }

    func testCoveredMeterCannotResumeDispatchOnlyBecauseTheAppBecomesActive() {
        let meter = CaptureMeter()
        meter.setPresented(false)
        meter.setVisible(false)
        meter.setVisible(true)
        XCTAssertFalse(meter.deliveryGate.isEnabled)
        meter.setPresented(true)
        XCTAssertTrue(meter.deliveryGate.isEnabled)
    }

    func testMeterResetStartsANewHistoryWithoutKeepingOldTimebase() {
        let meter = CaptureMeter()
        meter.record(rms: 0.1, at: 500)
        meter.reset()
        XCTAssertTrue(meter.history.allSatisfy { $0 == 0 })
        meter.record(rms: 0.02, at: 1)
        XCTAssertGreaterThan(meter.history[28], 0)
        XCTAssertTrue(meter.history.dropLast().allSatisfy { $0 == 0 })
    }

    func testDisplayMovesBetweenEncoderCallbacksWithoutMutatingCaptureHistory() throws {
        let meter = CaptureMeter()
        meter.record(rms: 0.1, at: 100)
        let captured = meter.history
        let first = meter.displayHistory(at: 100)
        let halfway = meter.displayHistory(at: 100.05)
        let next = meter.displayHistory(at: 100.1)
        XCTAssertEqual(first, captured)
        XCTAssertNotEqual(first, halfway, "The display must move before the next 200ms encoder callback.")
        XCTAssertNotEqual(halfway, next)
        XCTAssertEqual(halfway[27], (first[27] + next[27]) / 2, accuracy: 0.00001)
        XCTAssertEqual(meter.history, captured, "Drawing cannot invent or modify captured samples.")

        let beforeCallback = meter.displayHistory(at: 100.1999)
        meter.record(rms: 0, at: 100.2)
        let afterCallback = meter.displayHistory(at: 100.2)
        for (before, after) in zip(beforeCallback, afterCallback) {
            XCTAssertEqual(before, after, accuracy: 0.002, "A callback must not jump the whole field by two columns.")
        }
    }

    func testDisplayClockFreezesInactiveAndPreservesHistoryAtWake() {
        let meter = CaptureMeter()
        for index in 0..<40 { meter.record(rms: 0.02, at: 100 + Double(index) / 10) }
        meter.setVisible(false, at: 104)
        let frozen = meter.history
        XCTAssertEqual(meter.displayHistory(at: 105), frozen)
        XCTAssertEqual(meter.displayHistory(at: 120), frozen)
        meter.record(rms: 0.1, at: 120)
        meter.setVisible(true, at: 130)
        XCTAssertEqual(meter.displayHistory(at: 130), meter.history, "Wake starts with retained history, not an empty field.")
        XCTAssertTrue(meter.history.allSatisfy { $0 > 0 })
        let advancing = meter.displayHistory(at: 130.05)
        XCTAssertNotEqual(advancing, meter.history)
        meter.setVisible(true, at: 130.05)
        XCTAssertEqual(meter.displayHistory(at: 130.05), advancing, "A repeated foreground notification cannot reset display motion.")
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertEqual(meter.displayHistory(at: invalid), meter.history)
        }
    }

    func testRenderedDisplayChangesBeforeAnotherEncoderCallback() throws {
        let meter = CaptureMeter()
        meter.record(rms: 0.1, at: 100)
        let captured = meter.history
        var images: [Data] = []
        for (index, time) in [100.0, 100.05, 100.1, 100.15].enumerated() {
            let renderer = ImageRenderer(content: CaptureDotsFrame(history: meter.displayHistory(at: time))
                .environment(\.colorScheme, .dark)
                .frame(width: 184, height: 70).background(.black))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            images.append(try XCTUnwrap(image.pngData()))
            let attachment = XCTAttachment(image: image)
            attachment.name = "waveform-between-callbacks-\(index)"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(Set(images).count, images.count, "Each display frame must change without another audio callback.")
        XCTAssertEqual(meter.history, captured)
    }

    func testRenderedMeterSpansTheWidthInShortRecordingLayouts() throws {
        let meter = CaptureMeter()
        for index in 0..<40 { meter.record(rms: 0.1, at: 100 + Double(index) / 10) }
        for size in [CGSize(width: 200, height: 60), CGSize(width: 184, height: 70), CGSize(width: 162, height: 54)] {
            let view = CaptureDots(meter: meter, isRecording: true)
                .environment(\.scenePhase, .inactive)
                .environment(\.colorScheme, .dark)
                .frame(width: size.width, height: size.height)
                .background(.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "meter-width-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)

            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let visible = (0..<image.width).filter { x in
                (0..<image.height).contains { y in
                    let offset = (y * image.width + x) * 4
                    return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 90
                }
            }
            let left = try XCTUnwrap(visible.first)
            let right = try XCTUnwrap(visible.last)
            XCTAssertLessThan(Double(left) / 2, 8, "The dot field must reach the leading edge of its canvas.")
            XCTAssertLessThan(Double(image.width - 1 - right) / 2, 8,
                              "A short canvas must not squeeze the waveform into its center.")
        }
    }

    func testNativeMicrophoneRotatesAACPausesMarksResumesStopsAndReopens() async throws {
        continueAfterFailure = false
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        addTeardownBlock { if await runtime.sessionID != nil { try await runtime.stop() } }
        await runtime.bootstrap()
        XCTAssertTrue(runtime.ready, runtime.failure ?? "Watch bootstrap did not finish.")
        let started = ContinuousClock.now
        try await runtime.start()
        try await waitForFrames(65 * 16_000, in: runtime, timeout: .seconds(95))
        let session = try XCTUnwrap(runtime.sessionID)
        let firstEpoch = try XCTUnwrap(runtime.epochID)
        try await runtime.mark()
        try await runtime.pause()
        XCTAssertEqual(runtime.captureState.intent, .paused)
        XCTAssertNil(runtime.epochID)

        let store = try RecordingStore(rootURL: fixture.rootURL)
        let firstChunks = try await store.pendingChunks()
        XCTAssertGreaterThanOrEqual(firstChunks.count, 2, "The default 60-second boundary must be crossed by actual samples.")
        XCTAssertTrue(firstChunks.contains { $0.envelope.manifest.frames.count == 60 * 16_000 })
        let pausedSeconds = runtime.elapsedSeconds
        XCTAssertGreaterThanOrEqual(pausedSeconds, 65)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(runtime.elapsedSeconds, pausedSeconds, "Paused capture must not add wall-clock time.")

        try await runtime.resume()
        try await waitForFrames(3 * 16_000, in: runtime, timeout: .seconds(15))
        let secondEpoch = try XCTUnwrap(runtime.epochID)
        XCTAssertNotEqual(firstEpoch, secondEpoch)
        try await runtime.stop()
        XCTAssertEqual(runtime.captureState.intent, .stopped)
        XCTAssertNil(runtime.epochID)

        let chunks = try await store.pendingChunks()
        let events = try await store.pendingCaptureEvents()
        let marks = events.compactMap { message -> CaptureMark? in
            if case .captureMark(let mark) = message { return mark }
            return nil
        }
        let endings = events.compactMap { message -> CaptureEpochEnded? in
            if case .epochEnded(let end) = message { return end }
            return nil
        }
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.epochID, firstEpoch)
        XCTAssertEqual(Set(endings.map(\.epochID)), [firstEpoch, secondEpoch])
        XCTAssertTrue(endings.contains { $0.epochID == firstEpoch && $0.reason == .paused })
        XCTAssertTrue(endings.contains { $0.epochID == secondEpoch && $0.reason == .stopped })
        try validateAudio(chunks, endings: endings)
        let firstEnd = try XCTUnwrap(endings.first { $0.epochID == firstEpoch })
        let mark = try XCTUnwrap(marks.first)
        XCTAssertGreaterThan(mark.sourceFrame, 0)
        XCTAssertLessThanOrEqual(mark.sourceFrame, firstEnd.endFrame)
        let recordedFrames = chunks.reduce(Int64(0)) { $0 + $1.envelope.manifest.frames.count }
        XCTAssertEqual(runtime.elapsedSeconds, Double(recordedFrames) / 16_000, accuracy: 1.0 / 16_000)
        XCTAssertEqual(runtime.pendingChunkCount, chunks.count)

        let reopened = try RecordingStore(rootURL: fixture.rootURL)
        let recovery = try await reopened.recover()
        XCTAssertTrue(recovery.missing.isEmpty && recovery.damaged.isEmpty && recovery.unfinished.isEmpty)
        let restoredChunks = try await reopened.pendingChunks()
        XCTAssertEqual(restoredChunks.map { $0.envelope.manifest.chunkID }, chunks.map { $0.envelope.manifest.chunkID })
        let restoredEvents = try await reopened.pendingCaptureEvents()
        XCTAssertEqual(restoredEvents, events)
        let intent = try await reopened.intent(sessionID: session)
        XCTAssertEqual(intent, .stopped)
        let cleaned = try await reopened.cleanupAcknowledgedChunks()
        XCTAssertTrue(cleaned.isEmpty, "No receiver receipt exists; every original must remain on the Watch.")
        try validateAudio(restoredChunks, endings: endings)

        let elapsed = started.duration(to: ContinuousClock.now)
        let evidence: [String: Any] = [
            "scope": "watchOS_simulator_native_microphone_no_WC_delivery",
            "rootID": fixture.rootURL.lastPathComponent,
            "sessionID": session.uuidString,
            "actualCapturedFrames": recordedFrames,
            "sampleRate": 16_000,
            "wallClockElapsed": elapsed.description,
            "epochCount": endings.count,
            "markCount": marks.count,
            "unacknowledgedOriginalCount": restoredChunks.count,
            "chunks": chunks.map { chunk in
                let manifest = chunk.envelope.manifest
                return ["chunkID": manifest.chunkID.uuidString, "epochID": manifest.epochID.uuidString,
                        "start": manifest.frames.start, "count": manifest.frames.count,
                        "bytes": manifest.byteCount, "sha256": manifest.audioSHA256] as [String: Any]
            }
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "watch-native-capture-ledger-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRelaunchAfterMuteStartsAtZeroAndRetainsPreviousAudio() async throws {
        continueAfterFailure = false
        let audioDiagnostics = WatchAudioInputDiagnostics()
        defer {
            audioDiagnostics.close()
            do {
                let attachment = XCTAttachment(data: try audioDiagnostics.data(), uniformTypeIdentifier: "public.json")
                attachment.name = "watch-input-availability-diagnostics-no-audio"
                attachment.lifetime = .keepAlways
                add(attachment)
            } catch { XCTFail("Could not encode audio diagnostic metadata: \(error)") }
        }
        let runID = UUID()
        let fixture = try WatchComposition.makeSimulatorTest(runID: runID)
        let first = fixture.runtime
        addTeardownBlock { if await first.sessionID != nil { try await first.stop() } }
        await first.bootstrap()
        XCTAssertTrue(first.ready, first.failure ?? "Watch bootstrap did not finish.")
        audioDiagnostics.record("before_original_runtime_start")
        do { try await first.start() }
        catch {
            let original = error
            audioDiagnostics.record("original_runtime_start_failed", error: original)
            // Diagnose only after preserving the original failure. No tap, sample generation, or fallback.
            let probeSession = WatchAudioSession()
            do {
                try await probeSession.activate()
                audioDiagnostics.record("standalone_session_activated")
                let freshEngine = AVAudioEngine()
                audioDiagnostics.record("fresh_engine_immediate", engine: freshEngine)
                try await Task.sleep(for: .milliseconds(200))
                audioDiagnostics.record("fresh_engine_after_200ms", engine: freshEngine)
                try await Task.sleep(for: .milliseconds(800))
                audioDiagnostics.record("fresh_engine_after_1s", engine: freshEngine)
                freshEngine.stop()
            } catch { audioDiagnostics.record("standalone_probe_failed", error: error) }
            do { try await probeSession.deactivate() }
            catch { audioDiagnostics.record("standalone_deactivation_failed", error: error) }
            probeSession.close()
            audioDiagnostics.record("standalone_probe_finished")
            throw original
        }
        audioDiagnostics.record("original_runtime_started")
        try await waitForFrames(3 * 16_000, in: first, timeout: .seconds(15))
        try await first.mark()
        try await first.pause()
        let sessionID = try XCTUnwrap(first.sessionID)
        let duration = first.elapsedSeconds
        let restored = try WatchComposition.makeSimulatorTest(runID: runID).runtime
        addTeardownBlock { if await restored.sessionID != nil { try await restored.stop() } }
        await restored.bootstrap()
        XCTAssertTrue(restored.ready, restored.failure ?? "Restored Watch bootstrap did not finish.")
        XCTAssertNil(restored.sessionID)
        XCTAssertEqual(restored.captureState.intent, .stopped)
        XCTAssertEqual(restored.elapsedSeconds, 0)
        XCTAssertNil(restored.epochID)
        XCTAssertEqual(restored.captureState.capturedFrames, 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(restored.elapsedSeconds, 0)
        XCTAssertEqual(restored.pendingChunkCount, 1)
        let store = try RecordingStore(rootURL: fixture.rootURL)
        let retainedDuration = try await store.sealedDuration(sessionID: sessionID)
        XCTAssertEqual(retainedDuration, duration)
        let events = try await store.pendingCaptureEvents()
        XCTAssertEqual(events.filter { if case .captureMark = $0 { return true }; return false }.count, 1)
    }

    func testForegroundRecoversInterruptedRecordingWithoutEndNotificationAndWidgetResumeIsIdempotent() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime
        addTeardownBlock { if await runtime.sessionID != nil { try await runtime.stop() } }
        await runtime.bootstrap()
        XCTAssertTrue(runtime.ready)

        var latestSnapshot: WatchWidgetSnapshot?
        runtime.widgetPublisher = { snapshot in
            await MainActor.run { latestSnapshot = snapshot }
        }

        try await runtime.start()
        try await waitForFrames(16_000, in: runtime, timeout: .seconds(15))
        let activeSession = try XCTUnwrap(runtime.sessionID)
        let firstEpoch = try XCTUnwrap(runtime.epochID)

        await runtime.handleAudioEvent(.interruptionBegan)
        XCTAssertEqual(runtime.captureState.intent, .recording)
        XCTAssertEqual(runtime.captureState.activity, .interrupted)
        XCTAssertNil(runtime.epochID)

        let deadline = ContinuousClock.now + .seconds(2)
        while latestSnapshot?.activity != .interrupted, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let interruptedSnapshot = try XCTUnwrap(latestSnapshot)
        let resumeRequest = interruptedSnapshot.request(.resume)

        await runtime.foreground()
        try await waitForFrames(16_000, in: runtime, timeout: .seconds(15))
        XCTAssertEqual(runtime.sessionID, activeSession)
        XCTAssertNotEqual(runtime.epochID, firstEpoch)
        XCTAssertEqual(runtime.captureState.activity, .recording)

        let widgetHandled = try await runtime.performWidgetRequest(resumeRequest)
        XCTAssertTrue(widgetHandled)
        XCTAssertEqual(runtime.sessionID, activeSession)
        XCTAssertEqual(runtime.captureState.activity, .recording)
    }

    func testDismissedArchiveRepairBannerPersistsAcrossRelaunchesUntilNewIssueAppears() async throws {
        let runID = UUID()
        let first = try WatchComposition.makeSimulatorTest(runID: runID)
        let repairEpoch = first.rootURL
            .appendingPathComponent("Encoding/Repair/\(UUID().uuidString)/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repairEpoch, withIntermediateDirectories: true)
        try Data("damaged-audio".utf8).write(to: repairEpoch.appendingPathComponent("0.m4a"))

        await first.runtime.bootstrap()
        XCTAssertNotNil(first.runtime.archiveFailure)
        first.runtime.dismissFailure()
        XCTAssertNil(first.runtime.archiveFailure)

        let second = try WatchComposition.makeSimulatorTest(runID: runID)
        await second.runtime.bootstrap()
        XCTAssertNil(second.runtime.archiveFailure, "Previously dismissed repair issue must stay dismissed across relaunch.")

        try Data("new-damaged-audio".utf8).write(to: repairEpoch.appendingPathComponent("1.m4a"))
        let third = try WatchComposition.makeSimulatorTest(runID: runID)
        await third.runtime.bootstrap()
        XCTAssertNotNil(third.runtime.archiveFailure, "A newly introduced repair file must surface the banner again.")
    }

    private func waitForFrames(_ frames: Int64, in runtime: WatchRuntime, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while runtime.captureState.capturedFrames < frames {
            guard ContinuousClock.now < deadline else { throw CaptureTestError.samplesTimedOut }
            if runtime.captureState.activity == .failed || runtime.captureState.activity == .interrupted {
                XCTFail(runtime.failure ?? "The native microphone stopped before enough frames arrived.")
                throw CaptureTestError.captureStopped
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(runtime.captureState.activity, .recording)
        XCTAssertNotNil(runtime.captureState.lastSampleUptime)
    }

    private func validateAudio(_ chunks: [RecordedChunk], endings: [CaptureEpochEnded]) throws {
        for (epoch, group) in Dictionary(grouping: chunks, by: { $0.envelope.manifest.epochID }) {
            var end: Int64 = 0
            for chunk in group.sorted(by: { $0.envelope.manifest.frames.start < $1.envelope.manifest.frames.start }) {
                let manifest = chunk.envelope.manifest
                XCTAssertEqual(chunk.state, .ready)
                XCTAssertEqual(manifest.sourceKind, .fixture)
                XCTAssertEqual(manifest.codec, .aac)
                XCTAssertEqual(manifest.sampleRate, 16_000)
                XCTAssertEqual(manifest.frames.start, end, "Each epoch must have contiguous sealed frame coverage.")
                XCTAssertGreaterThan(manifest.frames.count, 0)
                XCTAssertEqual(try ContentHash.sha256(fileAt: chunk.audioURL), manifest.audioSHA256)
                let bytes = try chunk.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                XCTAssertEqual(bytes.map(Int64.init), manifest.byteCount)
                let audio = try AVAudioFile(forReading: chunk.audioURL)
                XCTAssertEqual(audio.length, manifest.decodedFrameCount + manifest.primingFrames + manifest.paddingFrames)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4_096))
                var decoded: Int64 = 0
                while decoded < audio.length {
                    let remaining = audio.length - audio.framePosition
                    try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining)))
                    guard buffer.frameLength > 0 else { throw CaptureTestError.unexpectedAudioEnd }
                    decoded += Int64(buffer.frameLength)
                }
                XCTAssertEqual(decoded, audio.length)
                end = manifest.frames.end
            }
            XCTAssertEqual(endings.first { $0.epochID == epoch }?.endFrame, end)
        }
    }
}

private enum CaptureTestError: Error { case samplesTimedOut, captureStopped, unexpectedAudioEnd, archiveUnavailable }

private final class SyncLedgerTestBarrier: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Ledger actor is held")
    let release = DispatchSemaphore(value: 0)
    func hold() { entered.fulfill(); release.wait() }
}

private extension RecordingStore {
    func holdSyncTestBarrier(_ barrier: SyncLedgerTestBarrier) { barrier.hold() }
}

private actor RecoverySleeper {
    let expectations: [XCTestExpectation]
    private(set) var durations: [Duration] = []
    private var waits: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(expectations: [XCTestExpectation]) { self.expectations = expectations }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waits[id] = continuation
                durations.append(duration)
                if durations.count <= expectations.count { expectations[durations.count - 1].fulfill() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseNext() {
        guard let id = waits.keys.first else { return }
        waits.removeValue(forKey: id)?.resume()
    }
    private func cancel(_ id: UUID) { waits.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func cancelAll() {
        let pending = waits.values
        waits.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}

/// Reads system state only. Notification callbacks never wait for the test or alter audio configuration.
private final class WatchAudioInputDiagnostics: @unchecked Sendable {
    private struct Port: Codable {
        let type: String
        let uid: String
        let channels: Int
        init(_ value: AVAudioSessionPortDescription) {
            type = value.portType.rawValue; uid = value.uid; channels = value.channels?.count ?? 0
        }
    }
    private struct Format: Codable {
        let sampleRate: Double?
        let channels: UInt32
        let commonFormat: UInt
        let interleaved: Bool
        init(_ value: AVAudioFormat) {
            sampleRate = value.sampleRate.isFinite ? value.sampleRate : nil
            channels = value.channelCount; commonFormat = value.commonFormat.rawValue; interleaved = value.isInterleaved
        }
    }
    private struct Event: Codable {
        let name: String
        let uptime: Double
        let permission: Int
        let category: String
        let mode: String
        let sampleRate: Double?
        let inputAvailable: Bool
        let inputChannels: Int
        let availableInputs: [Port]
        let routeInputs: [Port]
        let routeOutputs: [Port]
        let inputFormat: Format?
        let outputFormat: Format?
        let reason: UInt?
        let errorDomain: String?
        let errorCode: Int?
    }
    private let lock = NSLock()
    private var events: [Event] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.mediaServicesWereLostNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] value in
                let reason = (value.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    ?? (value.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                self?.record("notification:\(value.name.rawValue)", reason: reason)
            })
        }
    }

    func record(_ name: String, engine: AVAudioEngine? = nil, error: (any Error)? = nil, reason: UInt? = nil) {
        let session = AVAudioSession.sharedInstance()
        let failure = error.map { $0 as NSError }
        let input = engine?.inputNode
        let event = Event(name: name, uptime: ProcessInfo.processInfo.systemUptime,
            permission: AVAudioApplication.shared.recordPermission.rawValue,
            category: session.category.rawValue, mode: session.mode.rawValue,
            sampleRate: session.sampleRate.isFinite ? session.sampleRate : nil,
            inputAvailable: session.isInputAvailable, inputChannels: session.inputNumberOfChannels,
            availableInputs: (session.availableInputs ?? []).map(Port.init),
            routeInputs: session.currentRoute.inputs.map(Port.init), routeOutputs: session.currentRoute.outputs.map(Port.init),
            inputFormat: input.map { Format($0.inputFormat(forBus: 0)) },
            outputFormat: input.map { Format($0.outputFormat(forBus: 0)) }, reason: reason,
            errorDomain: failure?.domain, errorCode: failure?.code)
        lock.lock(); events.append(event); lock.unlock()
    }

    func close() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func data() throws -> Data {
        lock.lock(); let snapshot = events.sorted { $0.uptime < $1.uptime }; lock.unlock()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }
}
#endif

private final class TapLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(rms: Float, uptime: TimeInterval)] = []

    var values: [(rms: Float, uptime: TimeInterval)] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ rms: Float, at uptime: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        stored.append((rms, uptime))
    }
}
