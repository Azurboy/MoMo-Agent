import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ReconciliationTests {
    @Test func appliedReceiptAndDeletionOutrankLateTransportFailureAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
            Issue.record("Expected durable receipt"); return
        }
        #expect(try await !store.controlWasApplied(.receipt(receipt)))
        try await store.markReceiptSent(receiptID: receipt.receiptID)
        #expect(try await !store.controlWasApplied(.receipt(receipt)), "Submission is not an application acknowledgement")
        try await store.applyReceipt(ReceiptApplied(receipt: receipt))
        let reopened = try archive(fixture, receiver: receiver)
        #expect(try await reopened.controlWasApplied(.receipt(receipt)))
        let wrongReceipt = try Receipt(receiverDeviceID: receiver, libraryInstanceID: reopened.libraryInstanceID,
            chunkID: receipt.chunkID, audioSHA256: receipt.audioSHA256, manifestSHA256: receipt.manifestSHA256)
        #expect(try await !reopened.controlWasApplied(.receipt(wrongReceipt)))
        let deletion = try await reopened.deleteSession(id: envelope.manifest.sessionID)
        #expect(try await !reopened.controlWasApplied(.deleteSession(deletion)))
        try await reopened.applyDeletionAcknowledgement(DeleteApplied(deletionID: deletion.deletionID, deviceID: fixture.deviceID))
        let restarted = try archive(fixture, receiver: receiver)
        #expect(try await restarted.controlWasApplied(.deleteSession(deletion)))
    }

    @Test(arguments: [false, true])
    func failedSubmittedResponseRequeuesAcrossRestart(replayAfterFileLoss: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let response = try await store.receiveReconcileRequest(request)
        let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try await store.markReconcileResponseSubmitted(messageID: response.messageID)
        #expect(try await store.pendingReconcileResponses().isEmpty)
        let restarted = try archive(fixture, receiver: receiver)
        #expect(try await restarted.requeueReconcileResponse(response) == .requeued)
        #expect(try await restarted.requeueReconcileResponse(response) == .requeued)
        if replayAfterFileLoss { try FileManager.default.removeItem(at: lease.audioURL) }
        let reopened = try archive(fixture, receiver: receiver)
        let pending = try await reopened.pendingReconcileResponses()
        let retry = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(try retry.matches(request))
        if replayAfterFileLoss {
            #expect(retry.results.map(\.state) == [.missing])
            #expect(retry.messageID != response.messageID)
        } else { #expect(retry == response) }
        try await reopened.markReconcileResponseSubmitted(messageID: retry.messageID)
        #expect(try await reopened.pendingReconcileResponses().isEmpty)
    }

    @Test func lateFailureOfReplacedResponseDoesNotChangeCurrentSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let original = try await store.receiveReconcileRequest(request)
        try await store.markReconcileResponseSubmitted(messageID: original.messageID)
        let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        try FileManager.default.removeItem(at: lease.audioURL)
        let replacement = try await store.receiveReconcileRequest(request)
        #expect(replacement.messageID != original.messageID)
        #expect(replacement.results.map(\.state) == [.missing])
        try await store.markReconcileResponseSubmitted(messageID: replacement.messageID)
        let restarted = try archive(fixture, receiver: receiver)
        #expect(try await restarted.requeueReconcileResponse(original) == .superseded)
        let nonCanonical = try ReconcileResponse(requestID: replacement.requestID, requestSHA256: replacement.requestSHA256,
            sourceDeviceID: replacement.sourceDeviceID, receiverDeviceID: replacement.receiverDeviceID,
            libraryInstanceID: replacement.libraryInstanceID, results: replacement.results)
        #expect(try await restarted.requeueReconcileResponse(nonCanonical) == .superseded)
        let unknown = try ReconcileResponse(requestID: UUID(), requestSHA256: replacement.requestSHA256,
            sourceDeviceID: replacement.sourceDeviceID, receiverDeviceID: replacement.receiverDeviceID,
            libraryInstanceID: replacement.libraryInstanceID, results: replacement.results)
        #expect(try await restarted.requeueReconcileResponse(unknown) == .unknown)
        let altered = try ReconcileResponse(messageID: replacement.messageID, requestID: replacement.requestID,
            requestSHA256: replacement.requestSHA256, sourceDeviceID: replacement.sourceDeviceID,
            receiverDeviceID: replacement.receiverDeviceID, libraryInstanceID: replacement.libraryInstanceID, results: original.results)
        #expect(try await restarted.requeueReconcileResponse(altered) == .unknown, "A conflicting payload cannot retire the canonical message ID.")
        let wrongHash = try ReconcileResponse(requestID: replacement.requestID, requestSHA256: String(repeating: "f", count: 64),
            sourceDeviceID: replacement.sourceDeviceID, receiverDeviceID: replacement.receiverDeviceID,
            libraryInstanceID: replacement.libraryInstanceID, results: replacement.results)
        #expect(try await restarted.requeueReconcileResponse(wrongHash) == .unknown)
        #expect(try await restarted.pendingReconcileResponses().isEmpty)
        #expect(try await restarted.requeueReconcileResponse(replacement) == .requeued)
        // Neither a stale failure nor a stale submission callback can clear this valid retry.
        #expect(try await restarted.requeueReconcileResponse(original) == .superseded)
        try await restarted.markReconcileResponseSubmitted(messageID: original.messageID)
        #expect(try await restarted.pendingReconcileResponses() == [replacement])
    }

    @Test func versionOneTenThreeCanonicalResponseRetiresOldFailureWithoutMetadataHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let original = try await store.receiveReconcileRequest(request)
        #expect(original.results.map(\.state) == [.unknown])
        try await store.markReconcileResponseSubmitted(messageID: original.messageID)
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
            Issue.record("Expected the real original to commit before the legacy response replacement"); return
        }
        let replacement = try ReconcileResponse(requestID: request.messageID, requestSHA256: request.requestSHA256,
            sourceDeviceID: request.sourceDeviceID, receiverDeviceID: receiver, libraryInstanceID: store.libraryInstanceID,
            results: [ReconcileResult(chunkID: envelope.manifest.chunkID, state: .received(receipt))])
        // Persist exactly the old canonical-row update; no new response-generation helper or history proof runs.
        try await store.installVersionOneTenThreeResponse(replacement)
        #expect(try await store.hasNoSupersededResponseMetadata())
        let restarted = try archive(fixture, receiver: receiver)
        #expect(try await restarted.requeueReconcileResponse(original) == .superseded)
        #expect(try await restarted.pendingReconcileResponses().isEmpty)
        #expect(try await restarted.pendingReceipts() == [receipt], "Retirement is not ReceiptApplied.")
        #expect(try await !restarted.reconciliationReceiptApplied(chunkID: envelope.manifest.chunkID))
        #expect(try await restarted.requeueReconcileResponse(replacement) == .requeued)
        #expect(try await restarted.pendingReconcileResponses() == [replacement])
    }

    @Test func receivedResponseAndReceiptAppliedReplaySurviveRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID()
        let store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
            Issue.record("Expected durable receipt"); return
        }
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let response = try await store.receiveReconcileRequest(request)
        #expect(try response.matches(request))
        #expect(response.results.map(\.state) == [.received(receipt)])
        #expect(try await store.pendingReconcileResponses() == [response])
        try await store.markReconcileResponseSubmitted(messageID: response.messageID)
        #expect(try await store.pendingReconcileResponses().isEmpty)

        let reopened = try archive(fixture, receiver: receiver)
        #expect(try await reopened.receiveReconcileRequest(request) == response)
        #expect(try await reopened.pendingReconcileResponses() == [response])
        let applied = ReceiptApplied(receipt: receipt)
        try await reopened.applyReceipt(applied)
        try await reopened.applyReceipt(applied)
        let restarted = try archive(fixture, receiver: receiver)
        try await restarted.applyReceipt(applied)
        #expect(try await restarted.pendingReceipts().isEmpty)
        #expect(try await restarted.receiveReconcileRequest(request) == response)
        #expect(try await restarted.reconciliationReceiptApplied(chunkID: envelope.manifest.chunkID))
    }

    @Test func requestsBindReceiverLibrarySourceSessionAndBothHashes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let item = try ReconcileChunkIdentity(envelope: envelope)
        let wrongReceiver = try ReconcileRequest(sourceDeviceID: fixture.deviceID, receiverDeviceID: UUID(), libraryInstanceID: store.libraryInstanceID, items: [item])
        await #expect(throws: ArchiveReconciliationError.receiverMismatch) { try await store.receiveReconcileRequest(wrongReceiver) }
        let wrongLibrary = try ReconcileRequest(sourceDeviceID: fixture.deviceID, receiverDeviceID: receiver, libraryInstanceID: UUID(), items: [item])
        await #expect(throws: ArchiveReconciliationError.libraryMismatch) { try await store.receiveReconcileRequest(wrongLibrary) }
        #expect(try await store.pendingReconcileResponses().isEmpty)

        let wrongSource = try ReconcileRequest(sourceDeviceID: UUID(), receiverDeviceID: receiver, libraryInstanceID: store.libraryInstanceID, items: [item])
        #expect(try await store.receiveReconcileRequest(wrongSource).results.map(\.state) == [.conflict])
        let changedHash = ContentHash.sha256(Data("other content".utf8))
        for changed in [
            try ReconcileChunkIdentity(sessionID: UUID(), chunkID: item.chunkID, audioSHA256: item.audioSHA256, manifestSHA256: item.manifestSHA256),
            try ReconcileChunkIdentity(sessionID: item.sessionID, chunkID: item.chunkID, audioSHA256: changedHash, manifestSHA256: item.manifestSHA256),
            try ReconcileChunkIdentity(sessionID: item.sessionID, chunkID: item.chunkID, audioSHA256: item.audioSHA256, manifestSHA256: changedHash)
        ] {
            let value = try ReconcileRequest(sourceDeviceID: fixture.deviceID, receiverDeviceID: receiver, libraryInstanceID: store.libraryInstanceID, items: [changed])
            #expect(try await store.receiveReconcileRequest(value).results.map(\.state) == [.conflict])
        }
        let original = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let response = try await store.receiveReconcileRequest(original)
        let conflict = try ReconcileRequest(messageID: original.messageID, sourceDeviceID: UUID(), receiverDeviceID: receiver, libraryInstanceID: store.libraryInstanceID, items: [item])
        await #expect(throws: ArchiveReconciliationError.conflictingRequest(original.messageID)) { try await store.receiveReconcileRequest(conflict) }
        #expect(try await store.receiveReconcileRequest(original) == response)
    }

    @Test(arguments: [false, true])
    func queuedSuccessIsReplacedWhenAudioOrManifestDisappears(removeManifest: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let initial = try await store.receiveReconcileRequest(request)
        let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        let removed = removeManifest ? lease.audioURL.appendingPathExtension("manifest.json") : lease.audioURL
        try FileManager.default.removeItem(at: removed)
        let pending = try await store.pendingReconcileResponses()
        let missing = try #require(pending.first)
        #expect(missing.messageID != initial.messageID)
        #expect(missing.results.map(\.state) == [.missing])
        #expect(try missing.matches(request))
        // A delayed admission callback for the previous snapshot cannot clear the replacement.
        try await store.markReconcileResponseSubmitted(messageID: initial.messageID)
        #expect(try await store.pendingReconcileResponses() == [missing])
        let reopened = try archive(fixture, receiver: receiver)
        #expect(try await reopened.receiveReconcileRequest(request) == missing)
        #expect(try await reopened.pendingReceipts().isEmpty)
        #expect(try await reopened.recordings().first?.audioState == .missingUnexpected)
    }

    @Test func expiredDeletedAndUnknownAreExplicitAndNeverCarryReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
            Issue.record("Expected accepted"); return
        }
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let received = try await store.receiveReconcileRequest(request)
        try await store.applyReceipt(ReceiptApplied(receipt: receipt))
        let job = try #require(await store.claimAnalysisJob(configurationHash: "reconciliation-test"))
        _ = try await store.commitTranscript(ticket: job, spans: fixture.spans(job))
        _ = try await store.expireAudio(olderThan: envelope.manifest.sealedAt.addingTimeInterval(1), replayFloors: [fixture.epochID: envelope.manifest.frames.end])
        let expired = try await store.pendingReconcileResponses()
        #expect(expired.first?.results.map(\.state) == [.expired])
        #expect(expired.first?.messageID != received.messageID)
        guard case .expired = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else { Issue.record("Expired audio must not be restored by retransmission"); return }
        #expect(try await store.pendingReceipts().isEmpty)
        let deletion = try await store.deleteSession(id: fixture.sessionID)
        let deleted = try await store.receiveReconcileRequest(request)
        #expect(deleted.results.map(\.state) == [.deleted(deletion)])
        #expect(try deleted.matches(request))
        let unseen = try fixture.envelope()
        let deletedUnseen = try self.request(store, fixture: fixture, receiver: receiver, envelopes: [unseen])
        #expect(try await store.receiveReconcileRequest(deletedUnseen).results.map(\.state) == [.deleted(deletion)])
        let unknown = try ReconcileChunkIdentity(sessionID: UUID(), chunkID: UUID(), audioSHA256: envelope.manifest.audioSHA256, manifestSHA256: envelope.manifestSHA256)
        let unknownRequest = try ReconcileRequest(sourceDeviceID: fixture.deviceID, receiverDeviceID: receiver, libraryInstanceID: store.libraryInstanceID, items: [unknown])
        #expect(try await store.receiveReconcileRequest(unknownRequest).results.map(\.state) == [.unknown])
        let reopened = try archive(fixture, receiver: receiver)
        #expect(try await reopened.receiveReconcileRequest(request) == deleted)
        try await reopened.applyReceipt(ReceiptApplied(receipt: receipt))
        #expect(try await reopened.pendingReceipts().isEmpty)
    }

    @Test func corruptAndSymlinkedAudioCannotBeConfirmedWhileHealthyItemsStillReconcile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        var envelopes: [ManifestEnvelope] = []
        for index in 0..<3 {
            let envelope = try fixture.envelope(startFrame: Int64(index * 1600), sequence: Int64(index))
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
            envelopes.append(envelope)
        }
        let corrupt = try await store.acquireAudioLease(chunkID: envelopes[0].manifest.chunkID)
        let symlink = try await store.acquireAudioLease(chunkID: envelopes[1].manifest.chunkID)
        await store.releaseAudioLease(id: corrupt.id)
        await store.releaseAudioLease(id: symlink.id)
        try Data("bad audio".utf8).write(to: corrupt.audioURL)
        let outside = fixture.root.appendingPathComponent("outside.wav")
        try fixture.audio.write(to: outside)
        try FileManager.default.removeItem(at: symlink.audioURL)
        try FileManager.default.createSymbolicLink(at: symlink.audioURL, withDestinationURL: outside)
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: envelopes)
        let response = try await store.receiveReconcileRequest(request)
        #expect(response.results[0].state == .missing)
        #expect(response.results[1].state == .missing)
        guard case .received(let receipt) = response.results[2].state else { Issue.record("Healthy item must still receive its receipt"); return }
        #expect(receipt.matches(envelopes[2]))
        #expect(try Data(contentsOf: outside) == fixture.audio)
    }

    @Test func fullPageFitsWireBudgetAndOutboxReadIsBounded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        var envelopes: [ManifestEnvelope] = []
        for index in 0..<ReconciliationLimits.maximumItems {
            let envelope = try fixture.envelope(startFrame: Int64(index * 1600), sequence: Int64(index))
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
            envelopes.append(envelope)
        }
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: envelopes)
        let response = try await store.receiveReconcileRequest(request)
        #expect(try response.matches(request))
        #expect(response.results.count == 16)
        #expect(try WireJSON.encode(ControlMessage.reconcileResponse(response)).count <= 16_384)
        let another = try self.request(store, fixture: fixture, receiver: receiver, envelopes: [envelopes[0]])
        _ = try await store.receiveReconcileRequest(another)
        #expect(try await store.pendingReconcileResponses(limit: 1).count == 1)
        await #expect(throws: ArchiveError.invalidQuery) { try await store.pendingReconcileResponses(limit: 33) }
    }

    @Test func preAudioControlIdentityIsEnforcedAndUnknownResponseBecomesReceived() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        try await store.receiveMark(CaptureMark(sessionID: fixture.sessionID, epochID: fixture.epochID,
            sourceDeviceID: fixture.deviceID, sourceFrame: 0))
        let request = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let unknown = try await store.receiveReconcileRequest(request)
        #expect(unknown.results.map(\.state) == [.unknown])
        let wrongSource = try ReconcileRequest(sourceDeviceID: UUID(), receiverDeviceID: receiver,
            libraryInstanceID: store.libraryInstanceID, items: request.items)
        #expect(try await store.receiveReconcileRequest(wrongSource).results.map(\.state) == [.conflict])
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let response = try await store.receiveReconcileRequest(request)
        #expect(response.messageID != unknown.messageID)
        guard case .received(let receipt) = response.results[0].state else { Issue.record("Received file must replace the earlier unknown snapshot"); return }
        #expect(receipt.matches(envelope))
        try await store.setReconciliationExpiryPending(chunkID: envelope.manifest.chunkID)
        let pendingExpiry = try await store.receiveReconcileRequest(request)
        #expect(pendingExpiry.results.map(\.state) == [.expired])
        #expect(pendingExpiry.messageID != response.messageID)
    }

    @Test func stagedPendingInboxItemReconcilesAsReceivedImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receiver = UUID(), store = try archive(fixture, receiver: receiver)
        let envelope = try fixture.envelope()
        // Stage into Inbox without calling commitReceivedChunk yet (simulating Watch reconcile arriving ahead of inbox drain).
        _ = try fixture.deliver(envelope, to: store)
        let req = try request(store, fixture: fixture, receiver: receiver, envelopes: [envelope])
        let response = try await store.receiveReconcileRequest(req)
        guard case .received(let receipt) = response.results.first?.state else {
            Issue.record("Expected uncommitted Inbox item to commit on demand and return .received"); return
        }
        #expect(receipt.matches(envelope))
        #expect(try store.inbox.pendingItems().isEmpty)
    }

    private func archive(_ fixture: Fixture, receiver: UUID) throws -> ArchiveStore {
        try ArchiveStore(rootURL: fixture.root.appendingPathComponent("Library"), receiverDeviceID: receiver)
    }

    private func request(_ store: ArchiveStore, fixture: Fixture, receiver: UUID, envelopes: [ManifestEnvelope]) throws -> ReconcileRequest {
        try ReconcileRequest(sourceDeviceID: fixture.deviceID, receiverDeviceID: receiver,
            libraryInstanceID: store.libraryInstanceID, items: envelopes.map { try ReconcileChunkIdentity(envelope: $0) })
    }
}

private extension ArchiveStore {
    func installVersionOneTenThreeResponse(_ response: ReconcileResponse) throws {
        try database.execute("UPDATE reconcile_requests SET response=?,response_id=?,pending=0 WHERE id=?", [
            .blob(try WireJSON.encode(response)), .text(response.messageID.uuidString), .text(response.requestID.uuidString)
        ])
    }

    func hasNoSupersededResponseMetadata() throws -> Bool {
        try database.rows("SELECT key FROM metadata WHERE key LIKE 'superseded_reconcile_response.%' LIMIT 1").isEmpty
    }

    func reconciliationReceiptApplied(chunkID: UUID) throws -> Bool {
        try database.rows("SELECT receipt_applied FROM chunks WHERE id=?", [.text(chunkID.uuidString)]).first?.integer(0) == 1
    }

    func setReconciliationExpiryPending(chunkID: UUID) throws {
        try database.execute("UPDATE chunks SET retention='expiry_pending' WHERE id=?", [.text(chunkID.uuidString)])
    }
}
