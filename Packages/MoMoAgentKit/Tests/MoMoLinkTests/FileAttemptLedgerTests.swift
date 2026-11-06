import Foundation
import Testing
import MoMoContracts
@testable import MoMoLink

struct FileAttemptLedgerTests {
    @Test func SDKSnapshotAdoptsADifferentRealAttemptWhenTheJournalAttemptHasExited() throws {
        let file = try envelope(), start = Date(timeIntervalSince1970: 1_000), actualID = UUID()
        var journal = FileAttemptLedger()
        let absentID = try journal.begin(file, now: start)
        journal.finish(chunkID: file.manifest.chunkID, attemptID: absentID)
        let now = start.addingTimeInterval(1_000)
        try journal.reconcileSnapshot([FileTransferObservation(envelope: file, attemptID: actualID, completedUnits: 3)], now: now)
        let actual = try #require(journal.attempts[file.manifest.chunkID])
        #expect(actual.outstanding && actual.attemptID == actualID)
        #expect(actual.startedAt == now && actual.lastProgressAt == now && actual.completedUnits == 3)
        #expect(journal.stalledCandidate(now: now) == nil)
        #expect(journal.stalledCandidate(now: now.addingTimeInterval(901))?.attemptID == actualID)
        #expect(!journal.acceptsFileCallback(chunkID: file.manifest.chunkID, attemptID: absentID))
    }

    @Test func duplicateSDKCopiesKeepTheCurrentAttemptAcrossSnapshotOrderChanges() throws {
        let file = try envelope(), start = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        let current = try journal.begin(file, now: start), other = UUID()
        for second in [100.0, 300, 901] {
            let oldCopy = FileTransferObservation(envelope: file, attemptID: other, completedUnits: Int64(second))
            let selected = FileTransferObservation(envelope: file, attemptID: current, completedUnits: 0)
            let snapshot = second == 300 ? [selected, oldCopy] : [oldCopy, selected]
            try journal.reconcileSnapshot(snapshot, now: start.addingTimeInterval(second))
            #expect(journal.attempts[file.manifest.chunkID]?.attemptID == current)
        }
        #expect(journal.stalledCandidate(now: start.addingTimeInterval(901))?.attemptID == current)
        #expect(!journal.acceptsFileCallback(chunkID: file.manifest.chunkID, attemptID: other))
    }

    @Test func aJournalWriteBeforeTheSDKCallCannotInventAnOutstandingSDKCopyAfterRestart() throws {
        let file = try envelope(), now = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        let unsubmitted = try journal.begin(file, now: now)
        journal = try JSONDecoder().decode(FileAttemptLedger.self, from: JSONEncoder().encode(journal))
        try journal.reconcileSnapshot([], now: now.addingTimeInterval(1))
        #expect(journal.attempts[file.manifest.chunkID]?.outstanding == false)
        #expect(try journal.canAdmit(file, now: now.addingTimeInterval(1)))
        let fresh = try journal.begin(file, now: now.addingTimeInterval(1))
        #expect(fresh != unsubmitted)
        #expect(!journal.acceptsFileCallback(chunkID: file.manifest.chunkID, attemptID: unsubmitted))
    }

    @Test func blockRecoveryRequiresStallCancellationAndActualSystemExit() throws {
        let file = try envelope(), id = file.manifest.chunkID, start = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        #expect(!journal.allowsAudioBlockRecovery(chunkID: id))
        let attempt = try journal.begin(file, now: start)
        #expect(!journal.allowsAudioBlockRecovery(chunkID: id))
        let candidate = try #require(journal.stalledCandidate(now: start.addingTimeInterval(901)))
        let cancelled = journal.requestCancellation(candidate, now: start.addingTimeInterval(901))
        #expect(cancelled)
        #expect(!journal.allowsAudioBlockRecovery(chunkID: id), "cancel() alone does not stop the old route")
        journal.finish(chunkID: id, attemptID: attempt)
        #expect(journal.allowsAudioBlockRecovery(chunkID: id))
        journal = try JSONDecoder().decode(FileAttemptLedger.self, from: JSONEncoder().encode(journal))
        #expect(journal.allowsAudioBlockRecovery(chunkID: id))
        journal.reconcileOutstanding([], now: start.addingTimeInterval(2_000), preservingAudioBlockChunkID: id)
        #expect(journal.allowsAudioBlockRecovery(chunkID: id), "Active AudioBlock recovery survives cooldown sweep")
        journal.confirm(chunkID: id)
        #expect(!journal.allowsAudioBlockRecovery(chunkID: id))
    }

    @Test func interactiveZeroProgressLeaseRetiresOnlyUnstartedCopiesWithoutTouchingProgressingOnes() throws {
        let stuck = try envelope(), moving = try envelope(), start = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        let stuckID = try journal.begin(stuck, now: start)
        let movingID = try journal.begin(moving, now: start)
        try journal.observe(envelope: moving, attemptID: movingID, completedUnits: 1, now: start.addingTimeInterval(5))
        let at91 = start.addingTimeInterval(91)
        #expect(journal.stalledCandidate(now: at91) == nil)
        let fastCandidate = try #require(journal.stalledCandidate(
            now: at91, interactiveZeroProgressLease: FileAttemptLedger.interactiveZeroProgressLease))
        #expect(fastCandidate.attemptID == stuckID)
        let cancelled = journal.requestCancellation(
            fastCandidate, now: at91, interactiveZeroProgressLease: FileAttemptLedger.interactiveZeroProgressLease)
        #expect(cancelled)
        #expect(journal.stalledCandidate(now: start.addingTimeInterval(500),
                                         interactiveZeroProgressLease: FileAttemptLedger.interactiveZeroProgressLease) == nil)
    }

    @Test func backgroundLeasePreservesUnreachableQueueUntilLongWatchdogOrReachableFastPath() throws {
        let queued = try envelope(), start = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        let attemptID = try journal.begin(queued, now: start)

        // Discretionary watchOS background transfers routinely sit unstarted past 15 minutes while recording.
        let at20Minutes = start.addingTimeInterval(20 * 60)
        #expect(journal.stalledCandidate(now: at20Minutes, stallLease: FileAttemptLedger.backgroundLease) == nil)

        // Raising the wrist / opening the app immediately unlocks the 90s interactive AudioBlock handover.
        let fastCandidate = try #require(journal.stalledCandidate(
            now: at20Minutes,
            stallLease: FileAttemptLedger.lease,
            interactiveZeroProgressLease: FileAttemptLedger.interactiveZeroProgressLease))
        #expect(fastCandidate.attemptID == attemptID)
        let prematureCancel = journal.requestCancellation(
            fastCandidate, now: at20Minutes, stallLease: FileAttemptLedger.backgroundLease)
        #expect(!prematureCancel)

        // If the Watch stays unreachable for the full background watchdog window, a wedged slot still self-heals.
        let at6Hours = start.addingTimeInterval(FileAttemptLedger.backgroundLease + 1)
        let backgroundCandidate = try #require(journal.stalledCandidate(
            now: at6Hours,
            stallLease: FileAttemptLedger.backgroundLease))
        #expect(backgroundCandidate.attemptID == attemptID)
        let watchdogCancel = journal.requestCancellation(
            backgroundCandidate, now: at6Hours, stallLease: FileAttemptLedger.backgroundLease)
        #expect(watchdogCancel)
    }

    private func envelope() throws -> ManifestEnvelope {
        try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
            sourceBuild: "lease-tests", sequence: 0, frames: FrameRange(start: 0, count: 8), timebaseHz: 16_000,
            wallClockAnchor: Date(), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
            decodedFrameCount: 8, byteCount: 16, audioSHA256: ContentHash.sha256(Data(repeating: 0, count: 16)), sourceKind: .fixture))
    }

    @Test func legacyAdoptionAndRepeatedReachabilityDoNotRenewThePersistedLease() throws {
        let envelope = try envelope(), start = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        try journal.observe(envelope: envelope, attemptID: nil, completedUnits: 0, now: start)
        for second in [100.0, 300, 899] {
            try journal.observe(envelope: envelope, attemptID: nil, completedUnits: 0, now: start.addingTimeInterval(second))
        }
        journal = try JSONDecoder().decode(FileAttemptLedger.self, from: JSONEncoder().encode(journal))
        #expect(journal.stalledCandidate(now: start.addingTimeInterval(899)) == nil)
        #expect(journal.stalledCandidate(now: start.addingTimeInterval(901))?.lastProgressAt == start)
        #expect(journal.stalledCandidate(now: start.addingTimeInterval(-1)) == nil)
    }

    @Test func realByteProgressInvalidatesAPreviouslySelectedCancellation() throws {
        let envelope = try envelope(), start = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        let attemptID = try journal.begin(envelope, now: start)
        let stale = try #require(journal.stalledCandidate(now: start.addingTimeInterval(901)))
        try journal.observe(envelope: envelope, attemptID: attemptID, completedUnits: 1, now: start.addingTimeInterval(902))
        let cancelledWhileProgressing = journal.requestCancellation(stale, now: start.addingTimeInterval(903))
        #expect(!cancelledWhileProgressing)
        #expect(journal.stalledCandidate(now: start.addingTimeInterval(1_500)) == nil)
        #expect(journal.stalledCandidate(now: start.addingTimeInterval(1_803))?.completedUnits == 1)
    }

    @Test func cancellationWaitsForActualSDKExitThenRotatesAndRejectsLateCallbacks() throws {
        let original = try envelope(), nextFile = try envelope(), start = Date(timeIntervalSince1970: 1_000)
        var journal = FileAttemptLedger()
        let oldID = try journal.begin(original, now: start)
        let cancelledAt = start.addingTimeInterval(901)
        let candidate = try #require(journal.stalledCandidate(now: cancelledAt))
        let cancelled = journal.requestCancellation(candidate, now: cancelledAt)
        #expect(cancelled)
        journal = try JSONDecoder().decode(FileAttemptLedger.self, from: JSONEncoder().encode(journal))
        #expect(!journal.acceptsFileCallback(chunkID: original.manifest.chunkID, attemptID: oldID))
        #expect(try !journal.canAdmit(original, now: start.addingTimeInterval(2_000)), "Cancel does not free a live SDK slot.")
        journal.reconcileOutstanding([], now: cancelledAt)
        #expect(try !journal.canAdmit(original, now: cancelledAt.addingTimeInterval(299)))
        #expect(try journal.canAdmit(nextFile, now: cancelledAt))
        let newID = try journal.begin(original, now: cancelledAt.addingTimeInterval(301))
        #expect(newID != oldID)
        journal.finish(chunkID: original.manifest.chunkID, attemptID: newID)
        journal.reconcileOutstanding([], now: cancelledAt.addingTimeInterval(302))
        #expect(!journal.acceptsFileCallback(chunkID: original.manifest.chunkID, attemptID: oldID))
        #expect(journal.acceptsFileCallback(chunkID: original.manifest.chunkID, attemptID: newID))
        journal.confirm(chunkID: original.manifest.chunkID)
        #expect(!journal.acceptsFileCallback(chunkID: original.manifest.chunkID, attemptID: newID))
        #expect(!journal.acceptsFileCallback(chunkID: original.manifest.chunkID, attemptID: nil))
    }

    @Test func fourStalledSDKCopiesCannotBeReplacedBeforeAnActualSlotExits() throws {
        let files = try (0..<5).map { _ in try envelope() }, start = Date(timeIntervalSince1970: 1_000)
        var state = LinkSubmissionState(), journal = FileAttemptLedger()
        state.update(activation: .activated, isReachable: false)
        for file in files.prefix(4) {
            #expect(try state.reserve(file, now: 0) == .submitted)
            _ = try journal.begin(file, now: start)
        }
        let candidate = try #require(journal.stalledCandidate(now: start.addingTimeInterval(901)))
        let cancelled = journal.requestCancellation(candidate, now: start.addingTimeInterval(901))
        #expect(cancelled)
        state.retireFileAttempt(chunkID: candidate.chunkID)
        try state.reconcile(Array(files.prefix(4)), now: 901)
        #expect(try state.reserve(files[4], now: 901) == .deferred)
        let remaining = files.prefix(4).filter { $0.manifest.chunkID != candidate.chunkID }
        try state.reconcile(remaining, now: 902)
        #expect(try state.reserve(files[4], now: 902) == .submitted)
        #expect(!journal.acceptsFileCallback(chunkID: candidate.chunkID, attemptID: candidate.attemptID))
    }

    @Test func peerEpochSurvivesRestartAndOldBackgroundCallbacksCannotReenterANewLibrary() throws {
        var journal = FileAttemptLedger()
        let old = journal.controlGeneration
        #expect(journal.acceptsControlCallback(generation: nil))
        journal.resetPeer()
        let current = journal.controlGeneration
        journal = try JSONDecoder().decode(FileAttemptLedger.self, from: JSONEncoder().encode(journal))
        #expect(!journal.acceptsControlCallback(generation: old))
        #expect(!journal.acceptsControlCallback(generation: nil))
        #expect(journal.acceptsControlCallback(generation: current))
        let scope = UUID()
        journal.bindControlScope(scope)
        #expect(journal.controlGeneration == current)
        journal.bindControlScope(UUID())
        #expect(!journal.acceptsControlCallback(generation: current))
    }

    @Test func formalReceiptDuringCancellationStillWinsAfterTheSDKCopyExits() throws {
        let file = try envelope()
        var state = LinkSubmissionState()
        state.update(activation: .activated, isReachable: true)
        #expect(try state.reserve(file, now: 0) == .submitted)
        state.retireFileAttempt(chunkID: file.manifest.chunkID)
        try state.reconcile([file], now: 901)
        let receipt = try Receipt(receiverDeviceID: UUID(), libraryInstanceID: UUID(), chunkID: file.manifest.chunkID,
            audioSHA256: file.manifest.audioSHA256, manifestSHA256: file.manifestSHA256)
        try state.confirmFileDelivery(receipt)
        try state.reconcile([], now: 902)
        let lateFailure = state.didFinish(chunkID: file.manifest.chunkID, failed: true, now: 903)
        #expect(!lateFailure)
        #expect(try state.reserve(file, now: 10_000) == .alreadySubmitted)
    }

    @Test func corruptAttemptCacheIsPreservedAndRebuiltWithoutChangingAnOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attempt-journal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attempts.json"), original = root.appendingPathComponent("original")
        try Data([1, 2, 3]).write(to: original)
        let invalid = Data("{bad-journal".utf8)
        try invalid.write(to: url)
        let loaded = try FileAttemptJournal.load(at: url)
        #expect(loaded.recoveredCorruption)
        #expect(!loaded.ledger.acceptsControlCallback(generation: nil))
        #expect(try Data(contentsOf: original) == Data([1, 2, 3]))
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("invalid-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == invalid)
        #expect(try FileAttemptJournal.load(at: url).ledger == loaded.ledger)
        var journal = loaded.ledger
        let file = try envelope(), now = Date()
        try journal.observe(envelope: file, attemptID: nil, completedUnits: 0, now: now)
        #expect(journal.stalledCandidate(now: now.addingTimeInterval(1)) == nil)
    }
}
