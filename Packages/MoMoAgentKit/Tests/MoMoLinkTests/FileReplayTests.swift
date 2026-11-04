import Foundation
import Testing
import MoMoContracts
@testable import MoMoLink

struct FileReplayTests {
    @Test func missingApplicationReceiptRetriesWithBackoffButNeverDuplicatesAnOutstandingFile() throws {
        let file = try makeEnvelope(), id = file.manifest.chunkID
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        #expect(try state.reserve(file, now: 0) == .submitted)
        #expect(try state.reserve(file, now: 1_000) == .alreadySubmitted)
        state.didFinish(chunkID: id, now: 1_000)
        #expect(state.hasRetryableFiles)
        #expect(try state.reserve(file, now: 1_119) == .alreadySubmitted)
        #expect(try state.reserve(file, now: 1_120) == .submitted)
        state.didFinish(chunkID: id, now: 1_121)
        #expect(try state.reserve(file, now: 1_360) == .alreadySubmitted)
        #expect(try state.reserve(file, now: 1_361) == .submitted)
        state.didFinish(chunkID: id, now: 1_362)
        #expect(try state.reserve(file, now: 1_841) == .alreadySubmitted)
        #expect(try state.reserve(file, now: 1_842) == .submitted)
        state.didFinish(chunkID: id, now: 1_843)
        #expect(try state.reserve(file, now: 2_802) == .alreadySubmitted)
        #expect(try state.reserve(file, now: 2_803) == .submitted)
        state.didFinish(chunkID: id, now: 2_804)
        #expect(try state.reserve(file, now: 4_603) == .alreadySubmitted)
        #expect(try state.reserve(file, now: 4_604) == .submitted)
        state.didFinish(chunkID: id, now: 4_605)
        #expect(try state.reserve(file, now: 6_404) == .alreadySubmitted)
        #expect(try state.reserve(file, now: 6_405) == .submitted)
    }

    @Test func completedAttemptPersistsAcrossRestartUntilReceiptDeadlineOrExplicitReplay() throws {
        let file = try makeEnvelope(), id = file.manifest.chunkID
        let start = Date(timeIntervalSince1970: 10_000)
        var ledger = FileAttemptLedger()
        let attemptID = try ledger.begin(file, now: start)
        ledger.finish(chunkID: id, attemptID: attemptID, succeededAt: start.addingTimeInterval(5))
        let persisted = try JSONDecoder().decode(FileAttemptLedger.self, from: JSONEncoder().encode(ledger))

        var restarted = LinkSubmissionState()
        restarted.update(activation: .activated, isReachable: false)
        restarted.seedCompletedFromLedger(persisted, nowWallClock: start.addingTimeInterval(25), nowUptime: 500)
        // 120s receipt wait minus 20s elapsed => 100s remaining (deadline at uptime 600).
        #expect(try restarted.reserve(file, now: 599) == .alreadySubmitted)
        #expect(try restarted.reserve(file, now: 600) == .submitted)

        var explicit = LinkSubmissionState()
        explicit.update(activation: .activated, isReachable: true)
        explicit.seedCompletedFromLedger(persisted, nowWallClock: start.addingTimeInterval(10), nowUptime: 100)
        explicit.allowFileReplay(chunkIDs: [id])
        #expect(try explicit.reserve(file, now: 101) == .submitted)
    }

    @Test func disappearingSystemTransferStillGetsAnApplicationReceiptDeadline() throws {
        let file = try makeEnvelope()
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        try state.reconcile([file], now: 0)
        try state.reconcile([], now: 10)
        #expect(try state.reserve(file, now: 129) == .alreadySubmitted)
        #expect(try state.reserve(file, now: 130) == .submitted)
    }

    @Test func validatedReceiptStopsRetryDespiteALateCompletionAndRejectsChangedIdentity() throws {
        let file = try makeEnvelope(), id = file.manifest.chunkID
        let receipt = try Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(), chunkID: id,
            audioSHA256: file.manifest.audioSHA256, manifestSHA256: file.manifestSHA256)
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: true)
        #expect(try state.reserve(file, now: 0) == .submitted)
        try state.confirmFileDelivery(receipt)
        let lateFailure = state.didFinish(chunkID: id, failed: true, now: 1)
        #expect(!lateFailure)
        try state.reconcile([], now: 2)
        #expect(!state.hasRetryableFiles)
        #expect(try state.reserve(file, now: 10_000) == .alreadySubmitted)
        let conflict = try makeEnvelope(chunkID: id)
        let wrong = try Receipt(receiverDeviceID: receipt.receiverDeviceID, libraryInstanceID: receipt.libraryInstanceID,
            chunkID: id, audioSHA256: conflict.manifest.audioSHA256, manifestSHA256: conflict.manifestSHA256)
        #expect(throws: LinkError.conflictingTransfer(id)) { try state.confirmFileDelivery(wrong) }
    }

    @Test func completedAndOutstandingFilesAreDistinctFromAFullQueue() throws {
        let files = try (0..<6).map { _ in try makeEnvelope() }
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        #expect(try state.reserve(files[0]) == .submitted)
        state.didFinish(chunkID: files[0].manifest.chunkID)
        for file in files[1...4] { #expect(try state.reserve(file) == .submitted) }
        #expect(try state.reserve(files[0]) == .alreadySubmitted)
        #expect(try state.reserve(files[1]) == .alreadySubmitted)
        #expect(try state.reserve(files[5]) == .deferred)
        state.didFinish(chunkID: files[1].manifest.chunkID)
        #expect(try state.reserve(files[5]) == .submitted)
    }

    @Test func restoredConfirmedCopiesStopFailingButKeepTheirSlotUntilTheSystemRetiresThem() throws {
        let files = try (0..<5).map { _ in try makeEnvelope() }
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        try state.reconcile(Array(files.prefix(4)), now: 0)
        for file in files.prefix(4) {
            try state.confirmFileDelivery(Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(),
                chunkID: file.manifest.chunkID, audioSHA256: file.manifest.audioSHA256,
                manifestSHA256: file.manifestSHA256))
        }
        #expect(try state.reserve(files[4], now: 1) == .deferred)
        try state.reconcile(Array(files[1...3]), now: 2)
        #expect(try state.reserve(files[4], now: 2) == .submitted)
        let retiredFailure = state.didFinish(chunkID: files[0].manifest.chunkID, failed: true, now: 3)
        #expect(!retiredFailure)
        #expect(!state.hasRetryableFiles)
        let unconfirmedFailure = state.didFinish(chunkID: files[4].manifest.chunkID, failed: true, now: 3)
        #expect(unconfirmedFailure)
        #expect(state.hasRetryableFiles)
    }

    @Test func successfulTransportWithoutReceiptDoesNotLoopOverTheFirstFourFiles() throws {
        let files = try (0..<8).map { _ in try makeEnvelope() }
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        var firstPass: [UUID] = []
        for file in files where try state.shouldSubmit(file) { firstPass.append(file.manifest.chunkID) }
        #expect(firstPass == Array(files.prefix(4)).map(\.manifest.chunkID))
        for id in firstPass { state.didFinish(chunkID: id) }
        try state.reconcile([])
        var secondPass: [UUID] = []
        for file in files where try state.shouldSubmit(file) { secondPass.append(file.manifest.chunkID) }
        #expect(secondPass == Array(files.suffix(4)).map(\.manifest.chunkID))
        for id in secondPass { state.didFinish(chunkID: id) }
        try state.reconcile([])
        for file in files { #expect(try !state.shouldSubmit(file)) }
    }

    @Test func failureAllowsRetryButExplicitReplayStillRespectsOutstandingLimit() throws {
        let files = try (0..<6).map { _ in try makeEnvelope() }
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        #expect(try state.shouldSubmit(files[0]))
        state.didFinish(chunkID: files[0].manifest.chunkID, failed: true, now: 100)
        #expect(try state.reserve(files[0], now: 129) == .retryLater)
        #expect(try state.shouldSubmit(files[0], now: 130))
        state.didFinish(chunkID: files[0].manifest.chunkID)
        for file in files[1...4] { #expect(try state.shouldSubmit(file)) }
        state.allowFileReplay(chunkIDs: [files[0].manifest.chunkID])
        #expect(try !state.shouldSubmit(files[0]))
        state.didFinish(chunkID: files[1].manifest.chunkID)
        #expect(try state.shouldSubmit(files[0]))
        #expect(try !state.shouldSubmit(files[1]))
        #expect(try !state.shouldSubmit(files[5]))
    }

    @Test func targetedMissingResponseDoesNotReplayHealthyFilesOrDuplicatePendingTransfer() throws {
        let first = try makeEnvelope(), second = try makeEnvelope()
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: true)
        #expect(try state.shouldSubmit(first))
        #expect(try state.shouldSubmit(second))
        state.didFinish(chunkID: first.manifest.chunkID)
        state.didFinish(chunkID: second.manifest.chunkID)
        state.allowFileReplay(chunkIDs: [first.manifest.chunkID])
        #expect(try state.shouldSubmit(first))
        #expect(try !state.shouldSubmit(second))
        state.allowFileReplay(chunkIDs: [first.manifest.chunkID])
        #expect(try !state.shouldSubmit(first))
        try state.reconcile([first])
        state.didFinish(chunkID: first.manifest.chunkID)
        #expect(try state.shouldSubmit(first))
        state.didFinish(chunkID: first.manifest.chunkID)
        #expect(try !state.shouldSubmit(first))
        state.allowFileReplay()
        #expect(try state.shouldSubmit(first))
        #expect(try state.shouldSubmit(second))
    }

    @Test func targetedReplaySurvivesOldSuccessQueueRefreshAndAFullQueueUntilNewAdmission() throws {
        let files = try (0..<5).map { _ in try makeEnvelope() }
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        for file in files.prefix(4) { #expect(try state.reserve(file) == .submitted) }
        let missing = files[0]
        state.allowFileReplay(chunkIDs: [missing.manifest.chunkID])
        try state.reconcile(Array(files.prefix(4)))
        #expect(try state.reserve(missing) == .alreadySubmitted)
        state.didFinish(chunkID: missing.manifest.chunkID)
        #expect(try state.reserve(files[4]) == .submitted)
        #expect(try state.reserve(missing) == .deferred)
        try state.reconcile(Array(files[1...4]))
        state.didFinish(chunkID: files[1].manifest.chunkID)
        #expect(try state.reserve(missing) == .submitted)
        #expect(try state.reserve(missing) == .alreadySubmitted)
        state.didFinish(chunkID: missing.manifest.chunkID)
        try state.reconcile(Array(files[2...4]))
        #expect(try state.reserve(missing) == .alreadySubmitted)
    }

    @Test func targetedReplaySurvivesACompletionAfterTheSystemQueueBecameEmpty() throws {
        let file = try makeEnvelope()
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: false)
        #expect(try state.reserve(file) == .submitted)
        state.allowFileReplay(chunkIDs: [file.manifest.chunkID])
        try state.reconcile([])
        state.didFinish(chunkID: file.manifest.chunkID)
        #expect(try state.reserve(file) == .submitted)
        state.didFinish(chunkID: file.manifest.chunkID)
        #expect(try state.reserve(file) == .alreadySubmitted)
    }

    @Test func completionFailureAfterQueueRefreshClearsSubmissionAndCompletedIdentityCannotMutate() throws {
        let first = try makeEnvelope()
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: true)
        #expect(try state.shouldSubmit(first))
        try state.reconcile([])
        state.didFinish(chunkID: first.manifest.chunkID, failed: true, now: 100)
        #expect(try state.reserve(first, now: 100) == .retryLater)
        #expect(try state.shouldSubmit(first, now: 130))
        state.didFinish(chunkID: first.manifest.chunkID)
        let conflict = try makeEnvelope(chunkID: first.manifest.chunkID)
        #expect(throws: LinkError.conflictingTransfer(first.manifest.chunkID)) { try state.shouldSubmit(conflict) }
        #expect(throws: LinkError.conflictingTransfer(first.manifest.chunkID)) { try state.reconcile([conflict]) }
    }

    private func makeEnvelope(chunkID: UUID = UUID()) throws -> ManifestEnvelope {
        try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(), chunkID: chunkID,
            sourceDeviceID: UUID(), sourceBuild: "file-replay-test", sequence: 0,
            frames: FrameRange(start: 0, count: 8), timebaseHz: 16000,
            wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmInt16,
            sampleRate: 16000, channels: 1, decodedFrameCount: 8, byteCount: 16,
            audioSHA256: ContentHash.sha256(Data(repeating: 0, count: 16)), sourceKind: .fixture))
    }
}
