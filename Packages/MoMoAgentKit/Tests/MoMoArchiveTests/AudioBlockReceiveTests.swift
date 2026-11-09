import Foundation
import Testing
import MoMoContracts
import MoMoLink
@testable import MoMoArchive

struct AudioBlockReceiveTests {
    @Test func malformedBlockCannotWritePartialAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let valid = try block(fixture, store, envelope, offset: 0, payload: fixture.audio.prefix(100))
        var object = try #require(JSONSerialization.jsonObject(with: WireJSON.encode(valid)) as? [String: Any])
        object["payloadSHA256"] = String(repeating: "0", count: 64)
        let invalid = try WireJSON.decode(AudioBlock.self, from: JSONSerialization.data(withJSONObject: object))
        await #expect(throws: ContractError.invalidField("audio_block")) { try await store.receiveAudioBlock(invalid) }
        #expect(!FileManager.default.fileExists(atPath: partialDirectory(store, envelope).path))
        #expect(throws: ContractError.invalidField("audio_block")) {
            try block(fixture, store, envelope, offset: envelope.manifest.byteCount, payload: Data([0]))
        }
    }

    @Test func multiBlockOriginalSurvivesALostReplyAndAnotherProcessRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var audio = fixture.audio
        audio.append(Data(repeating: 0, count: 64_000))
        func put32(_ value: Int, at offset: Int) {
            var word = UInt32(value).littleEndian
            withUnsafeBytes(of: &word) { audio.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        put32(audio.count - 8, at: 4); put32(audio.count - 44, at: 40)
        let frames = Int64((audio.count - 44) / 2)
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, sourceBuild: "tests", sequence: 0, frames: FrameRange(start: 0, count: frames),
            timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 28800,
            codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: frames,
            byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture))
        let store = try fixture.store()
        let source = fixture.root.appendingPathComponent("large-sealed.wav")
        try audio.write(to: source)
        let lost = try block(fixture, store, envelope, offset: 0, payload: audio.prefix(AudioBlock.maximumPayloadBytes))
        _ = try await store.receiveAudioBlock(lost) // Simulate the sender never receiving this reply.
        let reopened = try fixture.store()
        let receipt = try await AudioBlockTransfer.send(file: source, envelope: envelope, receiverDeviceID: fixture.deviceID,
            libraryInstanceID: store.libraryInstanceID) { block in
                #expect(block.payload.count <= AudioBlock.maximumPayloadBytes)
                if !block.payload.isEmpty { #expect(block.offset >= Int64(AudioBlock.maximumPayloadBytes)) }
                return try await reopened.receiveAudioBlock(block)
            }
        #expect(receipt.matches(envelope))
        let lease = try await reopened.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        #expect(try Data(contentsOf: lease.audioURL) == audio)
        await reopened.releaseAudioLease(id: lease.id)
        guard case .duplicate(let duplicate) = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened, audio: audio)) else {
            Issue.record("Expected one committed original"); return
        }
        #expect(duplicate == receipt)
        #expect(try await reopened.pendingReceipts().count == 1)
    }

    @Test func senderRejectsAReplyThatCannotAdvanceWithoutConsumingTheOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let source = fixture.root.appendingPathComponent("kept-original.wav")
        try fixture.audio.write(to: source)
        await #expect(throws: AudioBlockTransferError.noProgress) {
            try await AudioBlockTransfer.send(file: source, envelope: envelope, receiverDeviceID: fixture.deviceID,
                libraryInstanceID: store.libraryInstanceID) { AudioBlockReply(block: $0, nextOffset: 0) }
        }
        #expect(try Data(contentsOf: source) == fixture.audio)
        #expect(try await store.pendingReceipts().isEmpty)
    }

    @Test func legacyPhoneStatusDoesNotAdvertiseTheNewRoute() throws {
        let legacy = try PhoneArchiveStatus(libraryInstanceID: UUID(), recordingCount: 0,
                                            pendingAnalysisCount: 0, pendingReceiptCount: 0)
        #expect(try WireJSON.decode(PhoneArchiveStatus.self, from: WireJSON.encode(legacy)).audioBlockVersion == nil)
        let current = try PhoneArchiveStatus(libraryInstanceID: UUID(), recordingCount: 0,
            pendingAnalysisCount: 0, pendingReceiptCount: 0, audioBlockVersion: AudioBlock.version)
        #expect(try WireJSON.decode(PhoneArchiveStatus.self, from: WireJSON.encode(current)).audioBlockVersion == 1)
    }

    @Test func restartDuplicateAndOutOfOrderBlocksKeepOneDurableOffset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let first = try block(fixture, store, envelope, offset: 0, payload: fixture.audio.prefix(1000))
        #expect(try await store.receiveAudioBlock(first).nextOffset == 1000)
        #expect(try await store.pendingReceipts().isEmpty)
        let reopened = try fixture.store()
        #expect(try await reopened.receiveAudioBlock(first).nextOffset == 1000)
        let future = try block(fixture, store, envelope, offset: 2000, payload: fixture.audio.subdata(in: 2000..<2100))
        #expect(try await reopened.receiveAudioBlock(future).nextOffset == 1000)
        let last = try block(fixture, store, envelope, offset: 1000, payload: fixture.audio.dropFirst(1000))
        let reply = try await reopened.receiveAudioBlock(last)
        let receipt = try #require(reply.receipt)
        #expect(receipt.matches(envelope))
        #expect(try await reopened.pendingReceipts() == [receipt])
        let probe = try block(fixture, store, envelope, offset: 0, payload: Data())
        #expect(try await fixture.store().receiveAudioBlock(probe).receipt == receipt)
        #expect(try await reopened.recordings().count == 1)
        #expect(try reopened.inbox.pendingItems().isEmpty)
    }

    @Test func aWriteWithoutItsCheckpointIsTruncatedBeforeResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.receiveAudioBlock(block(fixture, store, envelope, offset: 0, payload: fixture.audio.prefix(1000)))
        let partial = partialDirectory(store, envelope).appendingPathComponent("audio")
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 9, count: 300)); try handle.close()
        let probe = try block(fixture, store, envelope, offset: 0, payload: Data())
        #expect(try await fixture.store().receiveAudioBlock(probe).nextOffset == 1000)
        #expect(try Data(contentsOf: partial).count == 1000)
        #expect(try await store.pendingReceipts().isEmpty)
    }

    @Test func checksumFailureCannotCommitOrConfirmAndCanRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let wrong = try block(fixture, store, envelope, offset: 0, payload: Data(repeating: 1, count: fixture.audio.count))
        await #expect(throws: ArchiveError.checksumMismatch) { try await store.receiveAudioBlock(wrong) }
        #expect(try await store.pendingReceipts().isEmpty)
        #expect(try await store.recordings().isEmpty)
        let valid = try block(fixture, store, envelope, offset: 0, payload: fixture.audio)
        #expect(try await store.receiveAudioBlock(valid).receipt?.matches(envelope) == true)
    }

    @Test func backgroundAndBlockCopiesConvergeOnTheSameReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.receiveAudioBlock(block(fixture, store, envelope, offset: 0, payload: fixture.audio.prefix(1000)))
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
            Issue.record("Expected normal receive"); return
        }
        let probe = try block(fixture, store, envelope, offset: 0, payload: Data())
        #expect(try await store.receiveAudioBlock(probe).receipt == receipt)
        #expect(!FileManager.default.fileExists(atPath: partialDirectory(store, envelope).path))
        #expect(try await store.pendingReceipts().count == 1)
    }

    @Test func midStreamPayloadBlockShortCircuitsWhenBackgroundTransferAlreadyCommittedChunk() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.receiveAudioBlock(block(fixture, store, envelope, offset: 0, payload: fixture.audio.prefix(1000)))
        #expect(FileManager.default.fileExists(atPath: partialDirectory(store, envelope).path))
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
            Issue.record("Expected normal background receive"); return
        }
        let midStream = try block(fixture, store, envelope, offset: 1000, payload: fixture.audio.dropFirst(1000).prefix(500))
        let reply = try await store.receiveAudioBlock(midStream)
        #expect(reply.nextOffset == envelope.manifest.byteCount)
        #expect(reply.receipt == receipt)
        #expect(!FileManager.default.fileExists(atPath: partialDirectory(store, envelope).path))
        #expect(try await store.pendingReceipts().count == 1)
    }

    @Test func receiverMismatchDeletionAndForgedReceiptsCannotAuthorizeCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let foreign = try AudioBlock(receiverDeviceID: fixture.deviceID, libraryInstanceID: UUID(),
                                     envelope: envelope, offset: 0, payload: fixture.audio)
        await #expect(throws: ArchiveReconciliationError.receiverMismatch) { try await store.receiveAudioBlock(foreign) }
        let request = try block(fixture, store, envelope, offset: 0, payload: Data())
        let receipt = try Receipt(receiverDeviceID: fixture.deviceID, libraryInstanceID: UUID(), chunkID: envelope.manifest.chunkID,
                                  audioSHA256: envelope.manifest.audioSHA256, manifestSHA256: envelope.manifestSHA256)
        #expect(throws: (any Error).self) {
            try AudioBlockReply(block: request, nextOffset: envelope.manifest.byteCount, receipt: receipt).validate(for: request)
        }
        #expect(throws: (any Error).self) {
            try AudioBlockReply(block: request, nextOffset: envelope.manifest.byteCount).validate(for: request)
        }
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) { try await store.receiveAudioBlock(request) }
    }

    @Test func senderResumesAgainstTheActualReopenedArchiveAndClosesItsSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.receiveAudioBlock(block(fixture, store, envelope, offset: 0, payload: fixture.audio.prefix(1000)))
        let source = fixture.root.appendingPathComponent("sealed-original.wav")
        try fixture.audio.write(to: source)
        let reopened = try fixture.store()
        let receipt = try await AudioBlockTransfer.send(file: source, envelope: envelope, receiverDeviceID: fixture.deviceID,
            libraryInstanceID: store.libraryInstanceID) { block in
                #expect(block.payload.count <= AudioBlock.maximumPayloadBytes)
                if !block.payload.isEmpty { #expect(block.offset == 1000) }
                return try await reopened.receiveAudioBlock(block)
            }
        #expect(receipt.matches(envelope))
        #expect(try Data(contentsOf: source) == fixture.audio)
        #expect(try await reopened.pendingReceipts().count == 1)
    }

    private func block(_ fixture: Fixture, _ store: ArchiveStore, _ envelope: ManifestEnvelope,
                       offset: Int64, payload: Data) throws -> AudioBlock {
        try AudioBlock(receiverDeviceID: fixture.deviceID, libraryInstanceID: store.libraryInstanceID,
                       envelope: envelope, offset: offset, payload: payload)
    }
    private func partialDirectory(_ store: ArchiveStore, _ envelope: ManifestEnvelope) -> URL {
        store.inbox.rootURL.deletingLastPathComponent().appendingPathComponent("AudioBlockInbox/\(envelope.manifest.chunkID.uuidString)")
    }
}
