import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

@Suite struct RecordingReconciliationTests {
    @Test func pagesSurviveRestartAndKeepTheirOriginalHighWater() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunks = try await addChunks(17, fixture: fixture, store: store)
        let first = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        #expect(first.items.count == ReconciliationLimits.maximumItems)
        let reopened = try fixture.store()
        #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: first.sourceDeviceID, beginNewRound: true) == first)
        let added = try await addChunks(1, startingAt: 17, fixture: fixture, store: reopened)
        let firstResponse = try response(first) { _ in .unknown }
        _ = try await reopened.applyReconciliationResponse(firstResponse)
        let second = try #require(await reopened.nextReconciliationRequest(sourceDeviceID: first.sourceDeviceID))
        #expect(second.items.map(\.chunkID) == [chunks[16].envelope.manifest.chunkID])
        #expect(!second.items.contains { $0.chunkID == added[0].envelope.manifest.chunkID })
        #expect(try await reopened.applyReconciliationResponse(firstResponse).ignored)
        _ = try await reopened.applyReconciliationResponse(self.response(second) { _ in .unknown })
        #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: first.sourceDeviceID) == nil)
        #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: first.sourceDeviceID, beginNewRound: true) != nil)
        let replay = try await reopened.pendingFileReplays()
        #expect(replay.count == 16)
        try await reopened.fileReplaysScheduled(replay)
        #expect(try await reopened.pendingFileReplays().count == 1)
    }

    @Test func receiptAndAppliedReplayKeepTheirIdentityAfterAudioCleanup() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        #expect(try await store.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == nil)
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        let receipt = try fixture.receipt()
        let original = try await store.applyReconciliationResponse(response(request) { _ in .received(receipt) })
        let applied = try #require(original.receiptApplications.first)
        #expect(try await store.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == receipt)
        #expect(try await store.cleanupAcknowledgedChunks() == [chunk.envelope.manifest.chunkID])
        let reopened = try fixture.store()
        #expect(try await reopened.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == receipt)
        let retry = try #require(await reopened.nextReconciliationRequest(sourceDeviceID: request.sourceDeviceID, beginNewRound: true))
        #expect(retry.messageID != request.messageID && retry.items == request.items)
        let repeated = try await reopened.applyReconciliationResponse(response(retry) { _ in .received(receipt) })
        #expect(repeated.receiptApplications == [applied])
        #expect(try await reopened.controlBatch(kind: .receipt, after: 0).map(\.message) == [.receiptApplied(applied)])
        #expect(!FileManager.default.fileExists(atPath: chunk.audioURL.path))
        let unavailable = try #require(await reopened.nextReconciliationRequest(sourceDeviceID: request.sourceDeviceID, beginNewRound: true))
        let result = try await reopened.applyReconciliationResponse(response(unavailable) { _ in .missing })
        #expect(result.retryChunkIDs.isEmpty && result.unavailableChunkIDs == [chunk.envelope.manifest.chunkID])
        #expect(try await reopened.chunk(id: chunk.envelope.manifest.chunkID)?.state == .removed)
        #expect(try await reopened.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == nil)
    }

    @Test func deletedTailFinishesOldRoundBeforeRequestedFreshRoundCanStart() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunks = try await addChunks(17, fixture: fixture, store: store)
        let original = fixture.envelope.manifest
        let tail = try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(),
            sourceDeviceID: original.sourceDeviceID, sourceBuild: "reconciliation-tests", sequence: 0,
            frames: FrameRange(start: 0, count: 160), timebaseHz: 16_000,
            wallClockAnchor: original.wallClockAnchor, timezoneOffset: 0,
            codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 160,
            byteCount: original.byteCount, audioSHA256: original.audioSHA256, sourceKind: .fixture))
        _ = try await store.sealChunk(audioAt: fixture.source, envelope: tail)
        try await store.prepareDeletion(DeleteSession(sessionID: tail.manifest.sessionID, generation: 1),
            deviceID: original.sourceDeviceID)

        let first = try #require(await store.nextReconciliationRequest(sourceDeviceID: original.sourceDeviceID))
        #expect(first.items.count == 16)
        _ = try await store.applyReconciliationResponse(response(first) { _ in .missing })
        let second = try #require(await store.nextReconciliationRequest(sourceDeviceID: original.sourceDeviceID))
        #expect(second.items.map(\.chunkID) == [chunks[16].envelope.manifest.chunkID])
        #expect(try await store.nextReconciliationRequest(sourceDeviceID: original.sourceDeviceID, beginNewRound: true) == second)
        _ = try await store.applyReconciliationResponse(response(second) { _ in .unknown })
        #expect(try await store.reconciliationRoundIsComplete() == false)

        // The first pass advances past deleted row 18; it must not consume the caller's fresh-round request.
        #expect(try await store.nextReconciliationRequest(sourceDeviceID: original.sourceDeviceID, beginNewRound: true) == nil)
        #expect(try await store.reconciliationRoundIsComplete())
        let reopened = try fixture.store()
        let fresh = try #require(await reopened.nextReconciliationRequest(sourceDeviceID: original.sourceDeviceID, beginNewRound: true))
        #expect(fresh.messageID != first.messageID && fresh.items == first.items)
        #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: original.sourceDeviceID) == fresh)
    }

    @Test func missingAndConflictNeverEraseOrResendAnInvalidOriginal() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunks = try await addChunks(3, fixture: fixture, store: store)
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        let damaged = chunks[1]
        try Data([0, 1]).write(to: damaged.audioURL)
        let conflict = chunks[2]
        let result = try await store.applyReconciliationResponse(response(request) {
            $0.chunkID == conflict.envelope.manifest.chunkID ? .conflict : .missing
        })
        #expect(result.retryChunkIDs == [chunks[0].envelope.manifest.chunkID])
        #expect(result.unavailableChunkIDs == [damaged.envelope.manifest.chunkID])
        #expect(result.conflictingChunkIDs == [conflict.envelope.manifest.chunkID])
        #expect(try await store.chunk(id: damaged.envelope.manifest.chunkID)?.state == .damaged)
        #expect(try await store.pendingChunkBatch(after: 0).map { $0.chunk.envelope.manifest.chunkID } == result.retryChunkIDs)
        #expect(try await store.cleanupAcknowledgedChunks().isEmpty)
        #expect(try Data(contentsOf: damaged.audioURL) == Data([0, 1]))
        #expect(try ContentHash.sha256(fileAt: conflict.audioURL) == conflict.envelope.manifest.audioSHA256)
    }

    @Test func fullIdentityValidationPrecedesEffectsAndOldLibraryRepliesCannotRebind() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        let wrong = try fixture.receipt(audioHash: String(repeating: "0", count: 64))
        await #expect(throws: RecordingReconciliationError.responseMismatch) {
            try await store.applyReconciliationResponse(response(request) { _ in .received(wrong) })
        }
        let unrelated = try DeleteSession(sessionID: UUID(), generation: 1)
        await #expect(throws: RecordingReconciliationError.responseMismatch) {
            try await store.applyReconciliationResponse(response(request) { _ in .deleted(unrelated) })
        }
        #expect(try await store.pendingReceiptApplications().isEmpty)
        let receipt = try fixture.receipt()
        _ = try await store.applyReceipt(receipt)
        let newLibrary = UUID()
        await #expect(throws: RecordingError.receiverMismatch) {
            try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: newLibrary)
        }
        try await store.replaceReceiverAfterUserConfirmation(deviceID: fixture.receiverID, libraryInstanceID: newLibrary)
        #expect(try await store.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == nil)
        let stale = try await store.applyReconciliationResponse(response(request) { _ in .received(receipt) })
        #expect(stale.ignored)
        #expect(try await store.cleanupAcknowledgedChunks().isEmpty)
        #expect(try await store.boundReceiver()?.libraryInstanceID == newLibrary)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == fixture.envelope.manifest.audioSHA256)
        let newRequest = try #require(await store.nextReconciliationRequest(sourceDeviceID: request.sourceDeviceID))
        #expect(newRequest.libraryInstanceID == newLibrary && newRequest.messageID != request.messageID)
    }

    @Test func deletionResponsePersistsBarrierBeforeRuntimeStopsAndCleansCapture() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        let deletion = try DeleteSession(sessionID: fixture.envelope.manifest.sessionID, generation: 1)
        let outcome = try await store.applyReconciliationResponse(response(request) { _ in .deleted(deletion) })
        let scoped = try #require(outcome.deletions.first)
        #expect(scoped.deletionID == deletion.deletionID && scoped.libraryInstanceID == fixture.libraryID)
        let reopened = try fixture.store()
        #expect(try await reopened.pendingDeletions() == [scoped])
        #expect(try await reopened.pendingDeletionApplications().isEmpty)
        #expect(try await reopened.cleanupAcknowledgedChunks().isEmpty)
        #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        _ = try await reopened.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
        #expect(!FileManager.default.fileExists(atPath: chunk.audioURL.path))
        #expect(try await reopened.pendingDeletionApplications().count == 1)
    }

    @Test func expirationDoesNotAuthorizeWatchCleanupOrAutomaticRetransmission() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        _ = try await store.applyReceipt(fixture.receipt())
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        let outcome = try await store.applyReconciliationResponse(response(request) { _ in .expired })
        #expect(outcome.unavailableChunkIDs == [chunk.envelope.manifest.chunkID])
        let reopened = try fixture.store()
        #expect(try await reopened.cleanupAcknowledgedChunks().isEmpty)
        #expect(try await reopened.pendingChunks().isEmpty)
        #expect(try await reopened.pendingChunkBatch(after: 0).isEmpty)
        #expect(try await reopened.pendingReceiptApplications().isEmpty)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        #expect(try await reopened.queueSummary(sessionID: fixture.envelope.manifest.sessionID).pendingChunkCount == 1)
    }

    @Test func filePagesAreBoundedAndAdvancePastUnconfirmedHead() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunks = try await addChunks(9, fixture: fixture, store: store)
        var cursor: Int64 = 0
        var received: [UUID] = []
        for count in [4, 4, 1] {
            let page = try await store.pendingChunkBatch(after: cursor)
            #expect(page.count == count)
            cursor = try #require(page.last).sequence
            received += page.map { $0.chunk.envelope.manifest.chunkID }
        }
        #expect(received == chunks.map { $0.envelope.manifest.chunkID })
        #expect(try await store.pendingChunkBatch(after: cursor).isEmpty)
        await #expect(throws: RecordingReconciliationError.invalidCursor) { try await store.pendingChunkBatch(after: 0, limit: 5) }
    }

    @Test(arguments: [ReconcileItemState.missing, .expired, .conflict])
    func lateReceiptCannotOverrideNegativeReconciliation(state: ReconcileItemState) async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let receipt = try fixture.receipt()
        let originalApplication = try await store.applyReceipt(receipt)
        let first = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        _ = try await store.applyReconciliationResponse(response(first) { _ in state })
        let reopened = try fixture.store()
        // A successfully submitted retransmission still cannot clear the receipt barrier.
        try await reopened.fileReplaysScheduled([chunk.envelope.manifest.chunkID])
        await #expect(throws: RecordingError.receiptNeedsReconciliation(chunk.envelope.manifest.chunkID)) {
            try await reopened.applyReceipt(receipt)
        }
        #expect(try await reopened.pendingReceiptApplications().isEmpty)
        #expect(try await reopened.controlBatch(kind: .receipt, after: 0).isEmpty)
        #expect(try await reopened.cleanupAcknowledgedChunks().isEmpty)
        #expect(try await reopened.applyReconciliationResponse(response(first) { _ in .received(receipt) }).ignored)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == fixture.envelope.manifest.audioSHA256)
        let fresh = try #require(await reopened.nextReconciliationRequest(sourceDeviceID: first.sourceDeviceID, beginNewRound: true))
        let result = try await reopened.applyReconciliationResponse(response(fresh) { _ in .received(receipt) })
        #expect(result.receiptApplications == [originalApplication])
        #expect(try await reopened.pendingReceiptApplications() == [originalApplication])
        #expect(try await reopened.cleanupAcknowledgedChunks() == [chunk.envelope.manifest.chunkID])
    }

    @Test func routineSyncSkipsConfirmedHistoryUntilDailyAuditAndSurvivesRestart() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunks = try await addChunks(200, fixture: fixture, store: store)
        var receipts: [UUID: Receipt] = [:]
        for chunk in chunks {
            let receipt = try Receipt(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
                chunkID: chunk.envelope.manifest.chunkID, audioSHA256: chunk.envelope.manifest.audioSHA256,
                manifestSHA256: chunk.envelope.manifestSHA256)
            receipts[receipt.chunkID] = receipt
            _ = try await store.applyReceipt(receipt)
        }
        _ = try await store.cleanupAcknowledgedChunks()
        let source = fixture.envelope.manifest.sourceDeviceID, now = Date(timeIntervalSince1970: 2_000_000)
        var audited = 0
        while let request = try await store.nextReconciliationRequest(sourceDeviceID: source, preferPending: true, now: now) {
            audited += request.items.count
            _ = try await store.applyReconciliationResponse(response(request) { .received(try #require(receipts[$0.chunkID])) }, now: now)
        }
        #expect(audited == 200)
        let reopened = try fixture.store()
        for wake in 1...100 {
            #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true,
                preferPending: true, now: now.addingTimeInterval(Double(wake) * 60)) == nil)
        }
        let added = try await addChunks(17, startingAt: 200, fixture: fixture, store: reopened)
        let request = try #require(await reopened.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true,
            preferPending: true, now: now.addingTimeInterval(8_000)))
        #expect(request.items.map(\.chunkID) == added.prefix(16).map { $0.envelope.manifest.chunkID })
        let resumed = try fixture.store()
        // Expiry or a caller asking for a full audit must not change an unfinished round's scope.
        #expect(try await resumed.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true,
            now: now.addingTimeInterval(90_000)) == request)
        _ = try await resumed.applyReconciliationResponse(response(request) { _ in .unknown }, now: now.addingTimeInterval(90_000))
        let tail = try #require(await resumed.nextReconciliationRequest(sourceDeviceID: source, preferPending: true,
            now: now.addingTimeInterval(90_000)))
        #expect(tail.items.map(\.chunkID) == [added.last!.envelope.manifest.chunkID])
        _ = try await resumed.applyReconciliationResponse(response(tail) { _ in .unknown }, now: now.addingTimeInterval(90_000))
        let daily = try #require(await resumed.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true,
            preferPending: true, now: now.addingTimeInterval(90_000)))
        #expect(daily.items.map(\.chunkID) == chunks.prefix(16).map { $0.envelope.manifest.chunkID })
    }

    @Test func pendingAuditRetainsReceiptHoldsAndReceiverChangeRequiresFullHistory() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        _ = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        _ = try await store.applyReceipt(fixture.receipt())
        _ = try await store.cleanupAcknowledgedChunks()
        let source = fixture.envelope.manifest.sourceDeviceID, now = Date()
        let first = try #require(await store.nextReconciliationRequest(sourceDeviceID: source, preferPending: true, now: now))
        _ = try await store.applyReconciliationResponse(response(first) { _ in .missing }, now: now)
        let held = try #require(await store.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true,
            preferPending: true, now: now.addingTimeInterval(60)))
        #expect(held.items == first.items)
        _ = try await store.applyReconciliationResponse(response(held) { _ in .received(try fixture.receipt()) }, now: now.addingTimeInterval(60))
        #expect(try await store.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true,
            preferPending: true, now: now.addingTimeInterval(120)) == nil)
        try await store.replaceReceiverAfterUserConfirmation(deviceID: fixture.receiverID, libraryInstanceID: UUID())
        let rebound = try #require(await store.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true,
            preferPending: true, now: now.addingTimeInterval(180)))
        #expect(rebound.items == first.items)
        #expect(rebound.libraryInstanceID != fixture.libraryID)
    }

    @Test func schemaSixMigrationRetainsInFlightFullAuditAndOriginalAudio() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let source = fixture.envelope.manifest.sourceDeviceID
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: source))
        let database = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        try database.execute("ALTER TABLE reconciliation_round DROP COLUMN full_history")
        try database.execute("ALTER TABLE reconciliation_round DROP COLUMN history_audited_at")
        try database.execute("PRAGMA user_version=6")
        let reopened = try fixture.store()
        #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: source, preferPending: true) == request)
        _ = try await reopened.applyReconciliationResponse(response(request) { _ in .received(try fixture.receipt()) })
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true, preferPending: true) == nil)
    }

    @Test func unknownForInflightReadyChunkDoesNotBlockSubsequentDirectReceipt() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let chunks = try await addChunks(2, fixture: fixture, store: store)
        let acknowledged = chunks[0], inflight = chunks[1]
        let acknowledgedReceipt = try Receipt(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
            chunkID: acknowledged.envelope.manifest.chunkID, audioSHA256: acknowledged.envelope.manifest.audioSHA256,
            manifestSHA256: acknowledged.envelope.manifestSHA256)
        let inflightReceipt = try Receipt(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
            chunkID: inflight.envelope.manifest.chunkID, audioSHA256: inflight.envelope.manifest.audioSHA256,
            manifestSHA256: inflight.envelope.manifestSHA256)
        _ = try await store.applyReceipt(acknowledgedReceipt)
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID))
        let outcome = try await store.applyReconciliationResponse(response(request) { _ in .unknown })
        #expect(outcome.retryChunkIDs == chunks.map { $0.envelope.manifest.chunkID })
        // An already-acknowledged chunk that the receiver now reports as unknown must hold direct receipts until reconciliation confirms it.
        await #expect(throws: RecordingError.receiptNeedsReconciliation(acknowledged.envelope.manifest.chunkID)) {
            try await store.applyReceipt(acknowledgedReceipt)
        }
        // An unacknowledged .ready chunk whose initial transfer was still in flight when .unknown arrived must accept its direct Receipt immediately.
        let applied = try await store.applyReceipt(inflightReceipt)
        #expect(applied.receipt == inflightReceipt)
        #expect(try await store.confirmedReceipt(chunkID: inflight.envelope.manifest.chunkID) == inflightReceipt)
        #expect(try await store.cleanupAcknowledgedChunks() == [inflight.envelope.manifest.chunkID])
    }

    @Test func prunedHistoricalRequestsAndPrunedChunksNeverPoisonDuplicateReconciliationResponses() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let source = fixture.envelope.manifest.sourceDeviceID
        // Seal 40 chunks (3 full pages of 16, 16, 8) and close their capture epoch so terminal pruning is eligible.
        let chunks = try await addChunks(40, fixture: fixture, store: store)
        var receipts: [UUID: Receipt] = [:]
        for chunk in chunks {
            receipts[chunk.envelope.manifest.chunkID] = try Receipt(
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID,
                chunkID: chunk.envelope.manifest.chunkID,
                audioSHA256: chunk.envelope.manifest.audioSHA256,
                manifestSHA256: chunk.envelope.manifestSHA256
            )
        }

        let ended = try CaptureEpochEnded(
            sessionID: fixture.envelope.manifest.sessionID,
            epochID: fixture.envelope.manifest.epochID,
            sourceDeviceID: source,
            endFrame: Int64(40 * 160),
            reason: .stopped
        )
        try await store.recordEpochEnded(ended)
        try await store.markControlPreserved(.epochEnded(ended), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)

        // Simulate interactive inline replies advancing Watch through all 3 pages while WatchConnectivity
        // also queues duplicate transferUserInfo ReconcileResponses that arrive after pruneHistoricalLedger.
        var duplicateResponses: [ReconcileResponse] = []
        let auditNow = fixture.envelope.manifest.sealedAt.addingTimeInterval(30 * 86_400)
        while let request = try await store.nextReconciliationRequest(sourceDeviceID: source, now: auditNow) {
            let reply = try response(request) { item in
                .received(try #require(receipts[item.chunkID]))
            }
            duplicateResponses.append(reply)
            let outcome = try await store.applyReconciliationResponse(reply, now: auditNow)
            #expect(!outcome.ignored)
        }
        #expect(duplicateResponses.count == 3)
        _ = try await store.cleanupAcknowledgedChunks()
        // Mark all ReceiptApplied deliveries confirmed so old removed chunks can be pruned too.
        for applied in try await store.pendingReceiptApplications() {
            try await store.markControlPreserved(
                .receiptApplied(applied),
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID
            )
        }
        _ = try await store.pruneHistoricalLedger(
            now: auditNow,
            retentionInterval: 14 * 86_400,
            minimumRetainedChunks: 4,
            retainedProcessedRequests: 1
        )

        // Late duplicate ReconcileResponses for pruned requests AND pruned chunks must return ignored=true, never throw!
        for staleReply in duplicateResponses {
            let staleOutcome = try await store.applyReconciliationResponse(staleReply, now: auditNow)
            #expect(staleOutcome.ignored)
        }

        // Seal fresh chunks afterward and verify reconciliation continues without head-of-line blockage.
        let freshChunks = try await addChunks(2, startingAt: 40, fixture: fixture, store: store)
        let freshRequest = try #require(await store.nextReconciliationRequest(
            sourceDeviceID: source,
            beginNewRound: true,
            preferPending: true,
            now: auditNow.addingTimeInterval(60)
        ))
        #expect(freshRequest.items.map(\.chunkID) == freshChunks.map { $0.envelope.manifest.chunkID })
        let freshReply = try response(freshRequest) { item in
            let chunk = try #require(freshChunks.first { $0.envelope.manifest.chunkID == item.chunkID })
            return .received(try Receipt(
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID,
                chunkID: item.chunkID,
                audioSHA256: chunk.envelope.manifest.audioSHA256,
                manifestSHA256: chunk.envelope.manifestSHA256
            ))
        }
        let freshOutcome = try await store.applyReconciliationResponse(freshReply, now: auditNow.addingTimeInterval(60))
        #expect(!freshOutcome.ignored)
        #expect(freshOutcome.receiptApplications.count == 2)
        #expect(try await store.cleanupAcknowledgedChunks().count == 2)
    }

    @Test func pendingOnlyReconciliationSkipsRemovedHistoryAndPreemptsIdleFullAudit() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try await boundStore(fixture)
        let source = fixture.envelope.manifest.sourceDeviceID
        let historical = try await addChunks(32, fixture: fixture, store: store)
        for chunk in historical {
            let receipt = try Receipt(
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID,
                chunkID: chunk.envelope.manifest.chunkID,
                audioSHA256: chunk.envelope.manifest.audioSHA256,
                manifestSHA256: chunk.envelope.manifestSHA256
            )
            _ = try await store.applyReceipt(receipt)
        }
        _ = try await store.cleanupAcknowledgedChunks()

        // Start a full-history round and complete its first page so cursor < highWater with full_history=1.
        let now = Date()
        let fullPageOne = try #require(await store.nextReconciliationRequest(sourceDeviceID: source, beginNewRound: true, now: now))
        #expect(fullPageOne.items.count == 16)
        _ = try await store.applyReconciliationResponse(response(fullPageOne) { item in
            let chunk = try #require(historical.first { $0.envelope.manifest.chunkID == item.chunkID })
            return .received(try Receipt(
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID,
                chunkID: item.chunkID,
                audioSHA256: chunk.envelope.manifest.audioSHA256,
                manifestSHA256: chunk.envelope.manifestSHA256))
        }, now: now)

        // Seal 3 active ready chunks: pending-only mode must preempt the historical crawl and jump straight to them.
        let active = try await addChunks(3, startingAt: 32, fixture: fixture, store: store)
        #expect(try await store.pendingChunkPage(after: 0, limit: 32).count == 3)
        let fastRequest = try #require(await store.nextReconciliationRequest(
            sourceDeviceID: source,
            beginNewRound: true,
            preferPending: true,
            allowHistoricalAudit: false,
            now: now.addingTimeInterval(5)
        ))
        #expect(fastRequest.items.map(\.chunkID) == active.map { $0.envelope.manifest.chunkID })
        _ = try await store.applyReconciliationResponse(response(fastRequest) { item in
            let chunk = try #require(active.first { $0.envelope.manifest.chunkID == item.chunkID })
            return .received(try Receipt(
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID,
                chunkID: item.chunkID,
                audioSHA256: chunk.envelope.manifest.audioSHA256,
                manifestSHA256: chunk.envelope.manifestSHA256))
        }, now: now.addingTimeInterval(5))
        _ = try await store.cleanupAcknowledgedChunks()

        // Once pending chunks are drained, historical audit resumes cleanly.
        let idleAudit = try #require(await store.nextReconciliationRequest(
            sourceDeviceID: source,
            beginNewRound: true,
            preferPending: true,
            allowHistoricalAudit: true,
            now: now.addingTimeInterval(10)
        ))
        #expect(idleAudit.items.map(\.chunkID) == historical.prefix(16).map { $0.envelope.manifest.chunkID })
    }

    private func boundStore(_ fixture: RecordingFixture) async throws -> RecordingStore {
        let store = try fixture.store()
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        return store
    }

    private func response(_ request: ReconcileRequest, state: (ReconcileChunkIdentity) throws -> ReconcileItemState) throws -> ReconcileResponse {
        try ReconcileResponse(requestID: request.messageID, requestSHA256: request.requestSHA256,
            sourceDeviceID: request.sourceDeviceID, receiverDeviceID: request.receiverDeviceID, libraryInstanceID: request.libraryInstanceID,
            results: request.items.map { try ReconcileResult(chunkID: $0.chunkID, state: state($0)) })
    }
}

func removeSchemaFiveTables(_ database: RecordingDatabase) throws {
    for table in ["control_deliveries", "control_positions"] { try database.execute("DROP TABLE IF EXISTS \(table)") }
    for table in ["reconciliation_receipt_holds", "reconciliation_file_actions", "reconciliation_round", "reconciliation_requests", "recording_status"] {
        try database.execute("DROP TABLE \(table)")
    }
}

private func addChunks(_ count: Int, startingAt offset: Int = 0, fixture: RecordingFixture, store: RecordingStore) async throws -> [RecordedChunk] {
    var chunks: [RecordedChunk] = []
    let original = fixture.envelope.manifest
    for index in offset..<(offset + count) {
        let data = Data((0..<320).map { UInt8(($0 + index * 7) % 251) })
        let source = fixture.root.appendingPathComponent("source-\(index).pcm")
        try data.write(to: source)
        let manifest = try ChunkManifest(sessionID: original.sessionID, epochID: original.epochID,
            sourceDeviceID: original.sourceDeviceID, sourceBuild: "reconciliation-tests", sequence: Int64(index),
            frames: FrameRange(start: Int64(index * 160), count: 160), timebaseHz: 16_000,
            wallClockAnchor: original.wallClockAnchor, timezoneOffset: original.timezoneOffset,
            codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 160,
            byteCount: Int64(data.count), audioSHA256: ContentHash.sha256(data), sourceKind: .fixture)
        chunks.append(try await store.sealChunk(audioAt: source, envelope: ManifestEnvelope(manifest: manifest)))
    }
    return chunks
}
