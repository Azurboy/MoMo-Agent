import Foundation
import Testing
import MoMoContracts
import MoMoLink

private func linkEnvelope() throws -> ManifestEnvelope {
    try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "test", sequence: 0, frames: FrameRange(start: 0, count: 8), timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 8, byteCount: 16, audioSHA256: ContentHash.sha256(Data(repeating: 0, count: 16)), sourceKind: .fixture))
}

@Test func unattendedRecoveryBacksOffAndProgressRestartsTheShortInterval() {
    var backoff = LinkRetryBackoff()
    #expect((0..<7).map { _ in backoff.nextDelay() } == [30, 60, 120, 240, 300, 300, 300])
    backoff.reset()
    #expect(backoff.nextDelay() == 30)
}

@Test func repairingAnUnreadableSystemQueuePreservesHealthyCopiesAndChannelCooldown() throws {
    let messages = (0..<3).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    for message in messages { #expect(try state.reserve(message, now: 0) == .submitted) }
    try state.didFinish(messages[2], failed: true, channelFailure: true, now: 10)
    // The first SDK copy was cancelled after its metadata became unusable; its durable outbox remains.
    state.allowReplay()
    try state.reconcile([messages[1]])
    #expect(try state.reserve(messages[0], now: 20) == .deferred)
    #expect(try state.reserve(messages[1], now: 20) == .alreadySubmitted)
    #expect(try state.reserve(messages[0], now: 40) == .submitted)
    #expect(try state.reserve(messages[2], now: 40) == .deferred)
    #expect(try state.reserve(messages[1], now: 40) == .alreadySubmitted)
    try state.didFinish(messages[0], failed: false, now: 41)
    #expect(try state.reserve(messages[2], now: 41) == .submitted)
}

@Test func failedFileCoolsDownWithoutBlockingOtherFilesAndConfirmedTransfersStayComplete() throws {
    let failed = try linkEnvelope()
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: false)
    #expect(try state.reserve(failed, now: 100) == .submitted)
    state.didFinish(chunkID: failed.manifest.chunkID, failed: true, now: 100)
    #expect(state.hasRetryableFiles)
    #expect(try state.reserve(failed, now: 129) == .retryLater)
    let healthy = try (0..<4).map { _ in try linkEnvelope() }
    for file in healthy { #expect(try state.reserve(file, now: 101) == .submitted) }
    #expect(try state.reserve(failed, now: 130) == .deferred)
    state.didFinish(chunkID: healthy[0].manifest.chunkID, now: 130)
    #expect(try state.reserve(failed, now: 130) == .submitted)
    state.didFinish(chunkID: failed.manifest.chunkID, failed: true, now: 130)
    #expect(try state.reserve(failed, now: 189) == .retryLater)
    #expect(try state.reserve(failed, now: 190) == .submitted)
    state.didFinish(chunkID: failed.manifest.chunkID, now: 191)
    for file in [failed, healthy[0]] {
        try state.confirmFileDelivery(Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(),
            chunkID: file.manifest.chunkID, audioSHA256: file.manifest.audioSHA256,
            manifestSHA256: file.manifestSHA256))
    }
    #expect(!state.hasRetryableFiles)
    #expect(try state.reserve(failed, now: 500) == .alreadySubmitted)
    #expect(try state.reserve(healthy[0], now: 500) == .alreadySubmitted)
}

@Test func dueFileRetriesSignalCursorRewindWhenBackoffOrReceiptDeadlineMatures() throws {
    let failed = try linkEnvelope()
    let unacknowledged = try linkEnvelope()
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: false)
    #expect(try state.reserve(failed, now: 100) == .submitted)
    #expect(try state.reserve(unacknowledged, now: 100) == .submitted)
    state.didFinish(chunkID: failed.manifest.chunkID, failed: true, now: 100)
    #expect(!state.hasDueFileRetries(now: 129))
    #expect(state.hasDueFileRetries(now: 130))
    #expect(try state.reserve(failed, now: 130) == .submitted)
    #expect(!state.hasDueFileRetries(now: 130))
    state.didFinish(chunkID: unacknowledged.manifest.chunkID, failed: false, now: 130)
    #expect(!state.hasDueFileRetries(now: 249))
    #expect(state.nextRetryDelay(now: 200) == 50)
    #expect(state.hasDueFileRetries(now: 250))
    #expect(try state.reserve(unacknowledged, now: 250) == .submitted)
    let explicitReplay = try linkEnvelope()
    #expect(try state.reserve(explicitReplay, now: 260) == .submitted)
    state.didFinish(chunkID: explicitReplay.manifest.chunkID, failed: false, now: 261)
    #expect(!state.hasDueFileRetries(now: 262))
    state.allowFileReplay(chunkIDs: [explicitReplay.manifest.chunkID])
    #expect(state.hasDueFileRetries(now: 262))
}

@Test func repeatedReconciliationCanReplayOnlyItsResponseWithoutDuplicatingQueuedControls() throws {
    let first = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let second = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(first) == .submitted)
    #expect(try state.reserve(second) == .submitted)
    try state.didFinish(first, failed: false)
    try state.didFinish(second, failed: false)
    try state.allowReplay(first)
    #expect(try state.reserve(first) == .submitted)
    #expect(try state.reserve(second) == .alreadySubmitted)
    try state.allowReplay(first)
    #expect(try state.reserve(first) == .alreadySubmitted)
}

@Test func unreachablePhoneStillAllowsBackgroundFileSubmission() throws {
    let envelope = try linkEnvelope()
    var state = LinkSubmissionState()
    #expect(throws: LinkError.notActivated) { try state.shouldSubmit(envelope) }
    state.update(activation: .activated, isReachable: false)
    #expect(try state.shouldSubmit(envelope))
    #expect(try !state.shouldSubmit(envelope))
    #expect(throws: LinkError.notReachable) { try state.requireImmediateMessaging() }
    state.didFinish(chunkID: envelope.manifest.chunkID)
    #expect(try !state.shouldSubmit(envelope))
    state.allowFileReplay()
    #expect(try state.shouldSubmit(envelope))
}

@Test func metadataRoundTripPreservesOriginalManifestAndRejectsMismatchedIdentity() throws {
    let envelope = try linkEnvelope()
    let metadata = LinkWireFormat.fileMetadata(envelope)
    #expect(try LinkWireFormat.fileEnvelope(metadata) == envelope)
    var changed = metadata
    changed["chunk_id"] = "../../private"
    #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.fileEnvelope(changed) }
    changed["chunk_id"] = UUID().uuidString
    #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.fileEnvelope(changed) }
    #expect(throws: LinkError.controlMessageTooLarge) {
        try LinkWireFormat.controlMessage(["protocol_version": 1, "control": Data(repeating: 0, count: 16_385)])
    }
}

@Test func outstandingTransferReconciliationPreventsDuplicateSubmission() throws {
    let envelope = try linkEnvelope()
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: true)
    try state.reconcile([envelope])
    #expect(try !state.shouldSubmit(envelope))
    try state.reconcile([])
    #expect(try !state.shouldSubmit(envelope))
    state.allowFileReplay()
    #expect(try state.shouldSubmit(envelope))
}

@Test func outstandingFileBudgetIncludesTransfersRecoveredFromTheSystemQueue() throws {
    let limit = LinkSubmissionState.maximumOutstandingFiles
    let envelopes = try (0..<(limit + 1)).map { _ in try linkEnvelope() }
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: false)
    try state.reconcile(Array(envelopes.prefix(limit)))
    let full = try state.shouldSubmit(envelopes[limit])
    #expect(!full)
    state.didFinish(chunkID: envelopes[0].manifest.chunkID)
    let admitted = try state.shouldSubmit(envelopes[limit])
    #expect(admitted)
    let overLimit = try state.shouldSubmit(linkEnvelope())
    #expect(!overLimit)
    try state.reconcile(Array(repeating: envelopes[0], count: limit))
    let legacyDuplicateQueue = try state.shouldSubmit(envelopes[limit])
    #expect(!legacyDuplicateQueue)
    state.didFinish(chunkID: envelopes[0].manifest.chunkID)
    let stillOutstanding = try state.shouldSubmit(envelopes[0])
    #expect(!stillOutstanding)
    let freedSlot = try state.shouldSubmit(linkEnvelope())
    #expect(freedSlot)

    let bulkLimit = LinkSubmissionState.bulkMaximumOutstandingFiles
    #expect(bulkLimit == 12)
    var bulkState = LinkSubmissionState(maximumOutstandingFiles: bulkLimit)
    bulkState.update(activation: .activated, isReachable: false)
    for _ in 0..<bulkLimit {
        #expect(try bulkState.shouldSubmit(linkEnvelope()))
    }
    #expect(try !bulkState.shouldSubmit(linkEnvelope()))
}

@Test func controlQueueEnforcesCountAndEncodedByteBudgetAndRetriesOnlyFailedMessages() throws {
    let messages: [ControlMessage] = (0..<40).map { _ in .deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
    var state = LinkControlSubmissionState()
    var accepted: [ControlMessage] = []
    for message in messages {
        let result = try state.reserve(message)
        if case .submitted = result { accepted.append(message) }
    }
    #expect(accepted.count == 32)
    #expect(try accepted.reduce(0) { try $0 + WireJSON.encode($1).count } <= LinkWireFormat.maximumControlBytes)
    try state.didFinish(messages[0], failed: false)
    let completed = try state.reserve(messages[0])
    #expect(completed == .alreadySubmitted)
    let next = try state.reserve(messages[32])
    #expect(next == .submitted)
    try state.didFinish(messages[1], failed: true, now: 100)
    #expect(try state.reserve(messages[1], now: 129) == .retryLater)
    let retry = try state.reserve(messages[1], now: 130)
    #expect(retry == .submitted)
    state.allowReplay()
    let duplicate = try state.reserve(messages[1])
    #expect(duplicate == .alreadySubmitted)
    try state.reconcile([])
    let replay = try state.reserve(messages[0])
    #expect(replay == .submitted)
    state.allowReplay()
    try state.reconcile(Array(repeating: messages[0], count: 32))
    let legacyQueue = try state.reserve(messages[39])
    #expect(legacyQueue == .deferred)
}

@Test func failedControlBacksOffWithoutBlockingHealthyMessagesAndReplayCannotBypassIt() throws {
    let failed = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let healthy = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var state = LinkControlSubmissionState()
    #expect(try state.reserve(failed, now: 100) == .submitted)
    try state.didFinish(failed, failed: true, now: 100)
    #expect(state.hasRetryableControls)
    state.allowReplay()
    #expect(try state.reserve(failed, now: 129) == .retryLater)
    #expect(try state.reserve(healthy, now: 101) == .submitted)
    #expect(try state.reserve(failed, now: 130) == .submitted)
    try state.didFinish(failed, failed: true, now: 130)
    try state.allowReplay(failed)
    #expect(try state.reserve(failed, now: 189) == .retryLater)
    #expect(try state.reserve(failed, now: 190) == .submitted)
    try state.didFinish(failed, failed: false, now: 191)
    #expect(!state.hasRetryableControls)
    #expect(try state.reserve(failed, now: 500) == .alreadySubmitted)
    #expect(try state.reserve(healthy, now: 500) == .alreadySubmitted)
}

@Test func controlBatchStopsAtBytesBeforeThirtyTwoReceipts() throws {
    let m = try linkEnvelope().manifest
    var state = LinkControlSubmissionState()
    var batch = LinkControlBudget()
    var bytes = 0, count = 0
    for _ in 0..<40 {
        let receipt = try Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(), chunkID: m.chunkID,
                                  audioSHA256: m.audioSHA256, manifestSHA256: String(repeating: "a", count: 64))
        let message = ControlMessage.receiptApplied(ReceiptApplied(receipt: receipt))
        let included = try batch.include(message)
        let submitted = try state.reserve(message)
        if included {
            #expect(submitted == .submitted)
            bytes += try WireJSON.encode(message).count; count += 1
        } else { #expect(submitted == .deferred) }
    }
    #expect(count > 0 && count < 32)
    #expect(bytes <= LinkWireFormat.maximumControlBytes)
}

@Test func failedActivationFinishesCurrentGrantWithoutWaitingForFutureConnectivity() {
    #expect(LinkBackgroundDrain.result(activation: .failed, hasPendingContent: true, processing: false) == .failed)
    #expect(LinkBackgroundDrain.result(activation: .inactive, hasPendingContent: false, processing: false) == .failed)
    #expect(LinkBackgroundDrain.result(activation: .activating, hasPendingContent: false, processing: false) == .pending)
    #expect(LinkBackgroundDrain.result(activation: .activated, hasPendingContent: true, processing: false) == .pending)
    #expect(LinkBackgroundDrain.result(activation: .activated, hasPendingContent: false, processing: true) == .pending)
    #expect(LinkBackgroundDrain.result(activation: .activated, hasPendingContent: false, processing: false) == .completed)
}

@Test @MainActor func expirationAndDrainCleanupCompleteEachGrantOnceWithoutTouchingANewGrant() {
    let registry = LinkRefreshTasks<UUID>()
    let first = UUID(), second = UUID(), next = UUID()
    var firstCount = 0, secondCount = 0, nextCount = 0
    registry.insert(first) {
        firstCount += 1
        registry.completeAll()
    }
    registry.insert(second) { secondCount += 1 }
    registry.completeAll()
    registry.complete(first)
    registry.complete(second)
    #expect(firstCount == 1 && secondCount == 1 && registry.isEmpty)
    registry.insert(next) { nextCount += 1 }
    // An expiration already queued for the old task must not cancel the next OS grant.
    if registry.contains(first) { registry.completeAll() }
    #expect(nextCount == 0 && registry.contains(next))
    registry.completeAll()
    registry.completeAll()
    #expect(nextCount == 1 && registry.isEmpty)
}

@Test func scanFileBatchAdvancesPastUnacknowledgedHeadRetriesWithoutStarvingNewChunks() async throws {
    struct Item {
        let sequence: Int64
        let envelope: ManifestEnvelope
    }
    let items = try (1...48).map { Item(sequence: Int64($0), envelope: try linkEnvelope()) }
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: false)
    var now: TimeInterval = 100
    var cursor: Int64 = 0

    // Upload the first 32 chunks without receipts (e.g. companion update staged on iPhone).
    for _ in 0..<8 {
        let outcome = try #require(await scanFileBatch(
            after: cursor, maximumScanned: 32,
            hasDueRetries: { state.hasDueFileRetries(now: now) },
            sequenceOf: \.sequence,
            loadPage: { after in Array(items.filter { $0.sequence > after }.prefix(4)) },
            submit: { item in try state.reserve(item.envelope, now: now) }
        ))
        cursor = outcome.cursor
        for item in items where state.hasRetryableFiles == false || item.sequence <= cursor {
            _ = state.didFinish(chunkID: item.envelope.manifest.chunkID, now: now)
        }
        now += 1
    }
    #expect(cursor == 32)
    // Advance past the 120s receipt wait so chunks 1..32 constantly report due retries.
    now = 300
    #expect(state.hasDueFileRetries(now: now))

    var newlySubmitted: [Int64] = []
    for _ in 0..<4 {
        var batchSubmitted: [Item] = []
        let outcome = try #require(await scanFileBatch(
            after: cursor, maximumScanned: 32,
            hasDueRetries: { state.hasDueFileRetries(now: now) },
            sequenceOf: \.sequence,
            loadPage: { after in Array(items.filter { $0.sequence > after }.prefix(4)) },
            submit: { item in
                let result = try state.reserve(item.envelope, now: now)
                if result == .submitted { batchSubmitted.append(item) }
                return result
            }
        ))
        cursor = outcome.cursor
        newlySubmitted.append(contentsOf: batchSubmitted.map(\.sequence))
        for item in batchSubmitted {
            state.didFinish(chunkID: item.envelope.manifest.chunkID, now: now)
        }
    }
    #expect(newlySubmitted == Array(33...48))

    // Once the tail (48) has been reached, the next pass wraps around to 0 to service due retries.
    var wrappedSubmitted: [Int64] = []
    let wrappedOutcome = try #require(await scanFileBatch(
        after: cursor, maximumScanned: 32,
        hasDueRetries: { state.hasDueFileRetries(now: now) },
        sequenceOf: \.sequence,
        loadPage: { after in Array(items.filter { $0.sequence > after }.prefix(4)) },
        submit: { item in
            let result = try state.reserve(item.envelope, now: now)
            if result == .submitted { wrappedSubmitted.append(item.sequence) }
            return result
        }
    ))
    #expect(wrappedOutcome.wrapped)
    #expect(wrappedSubmitted == [1, 2, 3, 4])
}

@Test func controlReplyMetadataRoundTripsAndPreservesBackwardCompatibility() throws {
    let ackOnly = try LinkWireFormat.controlReplyMetadata(preserved: true)
    #expect(ackOnly["control_preserved"] as? Bool == true)
    #expect(try LinkWireFormat.controlReplyMessage(ackOnly) == nil)

    let identity = ControlMessage.receiverIdentity(ReceiverIdentity(
        messageID: UUID(), receiverDeviceID: UUID(), libraryInstanceID: UUID()))
    let withReply = try LinkWireFormat.controlReplyMetadata(preserved: true, reply: identity)
    #expect(withReply["control_preserved"] as? Bool == true)
    #expect(try LinkWireFormat.controlReplyMessage(withReply) == identity)

    let rejected = try LinkWireFormat.controlReplyMetadata(preserved: false, reply: identity)
    #expect(rejected["control_preserved"] as? Bool == false)
    #expect(try LinkWireFormat.controlReplyMessage(rejected) == nil)
}

@Test func precheckReservationAndSubmittedLookupMatchReserveAcrossLargeBacklog() async throws {
    let items = try (1...420).map { (sequence: Int64($0), envelope: try linkEnvelope()) }
    var state = LinkSubmissionState()
    state.update(activation: .activated, isReachable: false)
    let now: TimeInterval = 100

    // Simulate 380 chunks already uploaded via transferFile and awaiting durable receipts.
    for index in 0..<380 {
        let envelope = items[index].envelope
        #expect(!state.hasSubmittedFileTransfer(chunkID: envelope.manifest.chunkID))
        #expect(try state.precheckReservation(envelope, now: now) == nil)
        #expect(try state.reserve(envelope, now: now) == .submitted)
        #expect(state.hasSubmittedFileTransfer(chunkID: envelope.manifest.chunkID))
        #expect(try state.precheckReservation(envelope, now: now) == .alreadySubmitted)
        _ = state.didFinish(chunkID: envelope.manifest.chunkID, now: now)
        #expect(state.hasSubmittedFileTransfer(chunkID: envelope.manifest.chunkID))
        #expect(try state.precheckReservation(envelope, now: now) == .alreadySubmitted)
    }

    // Even from cursor 0, a single 512-row scan skips all 380 awaiting-receipt rows in memory and fills 4 slots.
    var submittedSequences: [Int64] = []
    let outcome = try #require(await scanFileBatch(
        after: 0, maximumScanned: 512,
        hasDueRetries: { state.hasDueFileRetries(now: now) },
        sequenceOf: \.sequence,
        loadPage: { after in Array(items.filter { $0.sequence > after }.prefix(4)) },
        submit: { item in
            if let blocked = try state.precheckReservation(item.envelope, now: now) { return blocked }
            let result = try state.reserve(item.envelope, now: now)
            if result == .submitted { submittedSequences.append(item.sequence) }
            return result
        }
    ))
    #expect(submittedSequences == [381, 382, 383, 384])
    #expect(outcome.cursor == 384)
    #expect(outcome.deferred)
    #expect(try state.precheckReservation(items[384].envelope, now: now) == .deferred)
}
