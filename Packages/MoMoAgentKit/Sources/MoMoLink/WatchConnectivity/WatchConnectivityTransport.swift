#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
import Foundation
import os
@preconcurrency import WatchConnectivity
import MoMoContracts

private struct FileQueueDiagnostic: Encodable {
    struct Transfer: Encodable {
        let chunkID: UUID
        let completedUnits: Int64
        let totalUnits: Int64
        let transferring: Bool
        let attemptID: UUID?
        let startedAt: Date?
        let lastProgressAt: Date?
        let cancellationRequestedAt: Date?
        let retryNotBefore: Date?
    }
    let observedAt: Date
    let activated: Bool
    let reachable: Bool
    let peerAvailable: Bool
    let hasPendingContent: Bool
    let outstandingControls: Int
    let outstandingFiles: Int
    let audioBlockChunkID: UUID?
    let audioBlockRetryAfter: TimeInterval
    let audioBlockOffset: Int64
    let audioBlockPhase: String
    let audioBlockLastProgressAt: Date?
    let transfers: [Transfer]
}

@MainActor public final class WatchConnectivityTransport: NSObject, WCSessionDelegate {
    let session: WCSession
    private var submissions = LinkSubmissionState(maximumOutstandingFiles: LinkSubmissionState.bulkMaximumOutstandingFiles)
    private var controlSubmissions = LinkControlSubmissionState()
    private var interactiveControls = LinkControlSubmissionState(maximumOutstandingCount: 16)
    private var fileAttempts = FileAttemptLedger()
    private var controlGeneration: UUID { fileAttempts.controlGeneration }
    private let attemptsURL: URL?
    private let controlScopeID: UUID?
    private var attemptJournalFailure: TransportFailure?
    private var attemptJournalNeedsSave = true
    private var coalescedAttemptsDirty = false
    private var coalescedAttemptsFlushTask: Task<Void, Never>?
    private var receivedStatuses = LinkStatusReceiveState()
    private var publishedStatuses = LinkStatusReceiveState()
    private var lastStatusRequest: TimeInterval = -.infinity
    private var lastViewingStatusRequest: TimeInterval = -.infinity
    private var lastPublishedWatchStatus: WatchCaptureStatus?
    private var lastPublishedPhoneStatusMetadata: [String: Any]?
    private let diagnosticsURL: URL?
    private let controlDiagnosticsURL: URL?
    private var controlDiagnostic = ControlTransferDiagnostic()
    private var lastDiagnosticsAt: TimeInterval = -.infinity
    nonisolated let logger = Logger(subsystem: "com.momoagent.link", category: "ControlTransfer")
    public private(set) var activation: LinkActivation = .inactive
    private nonisolated let preserveFile: @Sendable (URL, ManifestEnvelope) throws -> Void
    nonisolated let preserveControl: @Sendable (ControlMessage) throws -> Void
    nonisolated let receiveAudioBlock: (@Sendable (AudioBlock) async throws -> AudioBlockReply)?
    private nonisolated let statusReplyProvider: (@Sendable (Bool) async throws -> StatusSnapshot)?
    private nonisolated let controlReplyProvider: (@Sendable (ControlMessage) async throws -> ControlMessage?)?
    var audioBlockTask: Task<Void, Never>?
    var activeAudioBlockGate: AudioBlockReplyGate?
    var audioBlockChunkID: UUID?
    var resumableAudioBlockChunkID: UUID?
    var audioBlockBackoff = LinkRetryBackoff()
    var audioBlockRetryAt: TimeInterval = 0
    var audioBlockGeneration: UUID?
    var audioBlockOffset: Int64 = 0
    var audioBlockPhase = "idle"
    var audioBlockLastProgressAt: Date?
    nonisolated let event: @Sendable (LinkEvent) -> Void
    #if os(iOS)
    private nonisolated let selectedWatch = SelectedWatchEventClock()
    #endif

    public init(preserveFile: @escaping @Sendable (URL, ManifestEnvelope) throws -> Void,
                preserveControl: @escaping @Sendable (ControlMessage) throws -> Void,
                event: @escaping @Sendable (LinkEvent) -> Void, diagnosticsURL: URL? = nil,
                receiveAudioBlock: (@Sendable (AudioBlock) async throws -> AudioBlockReply)? = nil,
                statusReplyProvider: (@Sendable (Bool) async throws -> StatusSnapshot)? = nil,
                controlReplyProvider: (@Sendable (ControlMessage) async throws -> ControlMessage?)? = nil,
                controlScopeID: UUID? = nil) throws {
        guard WCSession.isSupported() else { throw LinkError.unsupported }
        self.session = .default
        self.preserveFile = preserveFile
        self.preserveControl = preserveControl
        self.event = event
        self.receiveAudioBlock = receiveAudioBlock
        self.statusReplyProvider = statusReplyProvider
        self.controlReplyProvider = controlReplyProvider
        self.diagnosticsURL = diagnosticsURL
        self.controlDiagnosticsURL = diagnosticsURL?.deletingLastPathComponent().appendingPathComponent("control-transfer-diagnostic.json")
        self.attemptsURL = diagnosticsURL?.deletingLastPathComponent().appendingPathComponent("file-transfer-attempts.json")
        self.controlScopeID = controlScopeID
        super.init()
        do { try restoreControlDiagnostic() }
        catch { logger.notice("Control diagnostic history unavailable: \(String(describing: error), privacy: .public)") }
        do { try loadAttempts() }
        catch { self.attemptJournalFailure = TransportFailure(error) }
        session.delegate = self
    }

    public func activate() {
        do { try recoverAttemptsIfNeeded() }
        catch { event(.failed(TransportFailure(error))) }
        #if os(iOS)
        event(.selectedWatchChanged(selectedWatch.select(activation: .activating,
            peerState: .notPaired, directoryURL: nil)))
        #endif
        controlSubmissions.allowReplay()
        interactiveControls.allowReplay()
        submissions.allowFileReplay()
        submissions.seedCompletedFromLedger(fileAttempts)
        activation = .activating
        submissions.update(activation: .activating, isReachable: false)
        session.activate()
    }

    /// Reconcile retained outboxes after relaunch, foreground return, or an explicit receiver change.
    public func allowControlReplay() {
        controlSubmissions.allowReplay()
        interactiveControls.allowReplay()
    }

    public func allowAudioBlockReplay() {
        audioBlockRetryAt = 0
        audioBlockBackoff.reset()
    }

    public var resumableAudioBlockChunk: UUID? { resumableAudioBlockChunkID }

    public func hasSubmittedFileTransfer(chunkID: UUID) -> Bool {
        submissions.hasSubmittedFileTransfer(chunkID: chunkID)
    }

    public func refreshFileQueue() throws {
        _ = try refreshOutstanding()
    }

    /// A user-confirmed receiver change invalidates old-peer custody, including late callbacks.
    public func resetPeerControlState() throws {
        cancelAudioBlockTransfer()
        resumableAudioBlockChunkID = nil
        try recoverAttemptsIfNeeded()
        var next = fileAttempts
        next.resetPeer()
        attemptJournalNeedsSave = true
        try saveAttempts(next)
        controlSubmissions = LinkControlSubmissionState()
        interactiveControls = LinkControlSubmissionState(maximumOutstandingCount: 16)
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo["control"] is Data { transfer.cancel() }
    }
    public func allowControlReplay(_ message: ControlMessage) throws {
        try controlSubmissions.allowReplay(message)
        try interactiveControls.allowReplay(message)
    }
    public func allowFileReplay() {
        submissions.allowFileReplay()
        var next = fileAttempts
        next.clearCompletedSubmissions()
        if next != fileAttempts {
            try? saveAttempts(next, immediate: false)
        }
    }
    public func allowFileReplay(chunkIDs: [UUID]) {
        guard !chunkIDs.isEmpty else { return }
        submissions.allowFileReplay(chunkIDs: chunkIDs)
        var next = fileAttempts
        next.clearCompletedSubmissions(chunkIDs: chunkIDs)
        if next != fileAttempts {
            try? saveAttempts(next, immediate: false)
        }
    }
    public func confirmFileDelivery(_ receipt: Receipt) throws {
        try recoverAttemptsIfNeeded()
        let mayHaveLiveTransfer = submissions.hasOutstandingFileTransfer(chunkID: receipt.chunkID)
            || fileAttempts.attempts[receipt.chunkID]?.outstanding == true
        let transfers = (mayHaveLiveTransfer && session.activationState == .activated) ? try refreshOutstanding() : []
        try submissions.confirmFileDelivery(receipt)
        var next = fileAttempts
        next.confirm(chunkID: receipt.chunkID)
        try saveAttempts(next, immediate: false)
        if audioBlockChunkID == receipt.chunkID { cancelAudioBlockTransfer() }
        if resumableAudioBlockChunkID == receipt.chunkID { resumableAudioBlockChunkID = nil }
        for (transfer, envelope) in transfers where envelope.manifest.chunkID == receipt.chunkID {
            // Only the caller's validated durable receipt can retire a live system copy.
            // Its eventual cancellation callback must not turn a saved file into a failure.
            transfer.cancel()
            logger.notice("Retired confirmed system file copy; chunk=\(receipt.chunkID.uuidString, privacy: .public)")
        }
    }

    /// A bounded ledger lookup can retire acknowledged copies retained across process death.
    public func outstandingFileEnvelopes() throws -> [ManifestEnvelope] {
        guard session.activationState == .activated else { throw LinkError.notActivated }
        return Array(try refreshOutstanding().prefix(submissions.maximumOutstandingCount).map(\.1))
    }

    public func audioBlockRecoveryCandidates() throws -> [UUID] {
        _ = try refreshOutstanding()
        return fileAttempts.attempts.values.filter { fileAttempts.allowsAudioBlockRecovery(chunkID: $0.chunkID) }
            .sorted { $0.lastProgressAt < $1.lastProgressAt }.prefix(4).map(\.chunkID)
    }

    func allowsAudioBlockRecovery(_ envelope: ManifestEnvelope) throws -> Bool {
        _ = try refreshOutstanding()
        guard let attempt = fileAttempts.attempts[envelope.manifest.chunkID] else { return false }
        guard attempt.manifestSHA256 == envelope.manifestSHA256 else {
            throw LinkError.conflictingTransfer(envelope.manifest.chunkID)
        }
        return fileAttempts.allowsAudioBlockRecovery(chunkID: envelope.manifest.chunkID)
    }

    func allowsInteractiveAudioBlockTransfer(_ envelope: ManifestEnvelope) throws -> Bool {
        _ = try refreshOutstanding()
        guard try fileAttempts.allowsInteractiveAudioBlock(for: envelope) else { return false }
        return try submissions.allowsInteractiveAudioBlock(envelope)
    }

    /// The recording owner validates each original before retiring its stalled system copy.
    public func stalledFileAttempts(maximumValidationBytes: Int64,
                                   allowAudioBlockRecovery: Bool = false,
                                   allowInteractiveFastPath: Bool = false) throws -> [(FileTransferAttempt, ManifestEnvelope)] {
        let transfers = try refreshOutstanding()
        let eligible = Set(transfers.filter { $0.1.manifest.byteCount <= maximumValidationBytes }.map { $0.1.manifest.chunkID })
        let blockRecoveryReady = allowAudioBlockRecovery && session.isReachable && peerState == .available
        let stallLease = blockRecoveryReady ? FileAttemptLedger.lease : FileAttemptLedger.backgroundLease
        let fastLease: TimeInterval? = (blockRecoveryReady && allowInteractiveFastPath)
            ? FileAttemptLedger.interactiveZeroProgressLease : nil
        let interactiveLease: TimeInterval? = (blockRecoveryReady && allowInteractiveFastPath)
            ? FileAttemptLedger.interactiveStallLease : nil
        return fileAttempts.stalledCandidates(now: Date(), limit: LinkSubmissionState.maximumOutstandingFiles,
            eligibleChunkIDs: eligible, stallLease: stallLease, interactiveZeroProgressLease: fastLease,
            interactiveStallLease: interactiveLease).compactMap { candidate in
                transfers.first(where: { $0.1.manifest.chunkID == candidate.chunkID }).map { (candidate, $0.1) }
            }
    }

    public func retireStalledFileAttempt(_ candidate: FileTransferAttempt,
                                         allowAudioBlockRecovery: Bool = false,
                                         allowInteractiveFastPath: Bool = false) throws {
        let transfers = try refreshOutstanding()
        let blockRecoveryReady = allowAudioBlockRecovery && session.isReachable && peerState == .available
        let stallLease = blockRecoveryReady ? FileAttemptLedger.lease : FileAttemptLedger.backgroundLease
        let fastLease: TimeInterval? = (blockRecoveryReady && allowInteractiveFastPath)
            ? FileAttemptLedger.interactiveZeroProgressLease : nil
        let interactiveLease: TimeInterval? = (blockRecoveryReady && allowInteractiveFastPath)
            ? FileAttemptLedger.interactiveStallLease : nil
        var next = fileAttempts
        guard next.requestCancellation(candidate, now: Date(), stallLease: stallLease,
                                       interactiveZeroProgressLease: fastLease,
                                       interactiveStallLease: interactiveLease) else { return } // Progress may have advanced during validation.
        try saveAttempts(next)
        submissions.retireFileAttempt(chunkID: candidate.chunkID)
        for (transfer, envelope) in transfers where envelope.manifest.chunkID == candidate.chunkID {
            transfer.cancel()
        }
        logger.notice("Retired stalled SDK attempt; chunk=\(candidate.chunkID.uuidString, privacy: .public); original remains pending")
    }

    /// Call only after the durable store validates the peer's application acknowledgement.
    public func confirmControlDelivery(_ message: ControlMessage) throws {
        try controlSubmissions.confirmDelivery(message)
        try interactiveControls.confirmDelivery(message)
        guard session.activationState == .activated else { return }
        let expected = try WireJSON.encode(message)
        for transfer in session.outstandingUserInfoTransfers {
            if transfer.userInfo["protocol_version"] as? Int == 1,
               transfer.userInfo["control"] as? Data == expected { transfer.cancel() }
        }
    }

    /// A durable inbox reply can arrive while a previously emitted failure is awaiting ledger I/O.
    public func controlDeliveryIsConfirmed(_ message: ControlMessage) throws -> Bool {
        try controlSubmissions.deliveryIsConfirmed(message)
    }

    public func stopRetryingControl(_ message: ControlMessage) throws {
        try controlSubmissions.stopRetrying(message)
        try interactiveControls.stopRetrying(message)
    }

    /// The caller restores only snapshots accepted by its store's identity checks.
    public func seedReceivedStatus(_ snapshot: StatusSnapshot) throws {
        try validateStatusRole(snapshot, fromPeer: true)
        try receivedStatuses.seed(snapshot)
    }

    /// Sends replaceable state. Success means accepted by WCSession, never peer delivery or durable receipt.
    @discardableResult public func updateStatus(_ snapshot: StatusSnapshot) throws -> Bool {
        guard session.activationState == .activated else { throw LinkError.notActivated }
        try validateStatusRole(snapshot, fromPeer: false)
        let metadata = try LinkWireFormat.statusMetadata(snapshot)
        guard peerState == .available else { return false }
        var next = publishedStatuses
        guard try next.accept(snapshot) else { return false }
        try session.updateApplicationContext(metadata)
        var sendImmediately = true
        if case .watch(let report) = snapshot.payload {
            sendImmediately = lastPublishedWatchStatus?.activity != report.activity
                || lastPublishedWatchStatus?.sessionID != report.sessionID
                || lastPublishedWatchStatus?.epochID != report.epochID
                || report.pendingChunkCount > (lastPublishedWatchStatus?.pendingChunkCount ?? 0)
            lastPublishedWatchStatus = report
        } else {
            lastPublishedPhoneStatusMetadata = metadata
        }
        if sendImmediately, session.isReachable {
            session.sendMessage(metadata, replyHandler: nil, errorHandler: { @Sendable _ in })
        }
        publishedStatuses = next
        return true
    }

    public var peerState: LinkPeerState {
        #if os(iOS)
        if !session.isPaired { return .notPaired }
        return session.isWatchAppInstalled ? .available : .companionNotInstalled
        #else
        return session.isCompanionAppInstalled ? .available : .companionNotInstalled
        #endif
    }

    /// Refresh the source observation; replaying a cached context cannot establish live recording.
    public func requestPeerStatus(viewing: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let lastAllowed = viewing ? lastViewingStatusRequest : lastStatusRequest
        guard session.activationState == .activated, session.isReachable,
              peerState == .available, now - lastAllowed >= 5 else { return }
        lastStatusRequest = now
        if viewing { lastViewingStatusRequest = now }
        // A reply uses this request's live conversation; it does not require another reverse send.
        session.sendMessage(LinkWireFormat.statusRequestMetadata(viewing: viewing), replyHandler: { @Sendable [weak self] metadata in
            self?.receivePeerStatusReply(metadata)
        }, errorHandler: { @Sendable [weak self] error in
            let failure = TransportFailure(error)
            self?.logger.notice("Peer status request deferred: \(failure.domain, privacy: .public) / \(failure.code)")
        })
    }

    @discardableResult public func transferFile(at url: URL, envelope: ManifestEnvelope) throws -> Bool {
        try transferFileResult(at: url, envelope: envelope) == .submitted
    }

    @discardableResult public func transferFileResult(at url: URL, envelope: ManifestEnvelope,
                                                      refreshQueue: Bool = true) throws -> FileSubmissionResult {
        if refreshQueue { try refreshOutstanding() }
        guard audioBlockChunkID != envelope.manifest.chunkID else { return .alreadySubmitted }
        if session.isReachable, resumableAudioBlockChunkID == envelope.manifest.chunkID { return .retryLater }
        guard peerState == .available else { return .deferred }
        if let blocked = try submissions.precheckReservation(envelope) { return blocked }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            event(.audioBlockSourceInvalid(chunkID: envelope.manifest.chunkID))
            return .alreadySubmitted
        }
        guard try fileAttempts.canAdmit(envelope, now: Date()) else {
            return session.outstandingFileTransfers.contains { ($0.file.metadata?["chunk_id"] as? String) == envelope.manifest.chunkID.uuidString }
                ? .alreadySubmitted : .retryLater
        }
        let result = try submissions.reserve(envelope)
        guard result == .submitted else { return result }
        var next = fileAttempts
        let attemptID = try next.begin(envelope, now: Date())
        do { try saveAttempts(next) }
        catch { submissions.retireFileAttempt(chunkID: envelope.manifest.chunkID); throw error }
        var metadata = LinkWireFormat.fileMetadata(envelope)
        metadata["file_attempt_id"] = attemptID.uuidString
        session.transferFile(url, metadata: metadata)
        return .submitted
    }

    public func refreshControlQueue() throws {
        guard session.activationState == .activated else { throw LinkError.notActivated }
        try controlSubmissions.reconcile(validatedOutstandingControls())
    }

    @discardableResult public func transferControl(_ message: ControlMessage) throws -> ControlSubmissionResult {
        // A foreground attempt alone cannot advance the durable outbox; wait for its preserved reply.
        try transferControlRoutes(message).background
    }

    @discardableResult public func transferControlRoutes(
        _ message: ControlMessage,
        refreshQueue: Bool = true,
        allowInteractive: Bool = true
    ) throws -> (background: ControlSubmissionResult, interactive: ControlSubmissionResult) {
        guard peerState == .available else { return (.deferred, .deferred) }
        guard session.activationState == .activated else { throw LinkError.notActivated }
        try recoverAttemptsIfNeeded()
        if attemptJournalNeedsSave {
            try saveAttempts(fileAttempts, immediate: true) // Persist the peer epoch before reserving or enqueueing an attempt.
        }
        var metadata = try LinkWireFormat.controlMetadata(message)
        metadata["control_generation"] = controlGeneration.uuidString
        let routes = try reserveControlRoutes(message,
            outstanding: refreshQueue ? validatedOutstandingControls() : nil,
            isReachable: allowInteractive && session.isReachable)
        let generation = controlGeneration
        if routes.background == .submitted { session.transferUserInfo(metadata) }
        if routes.interactive == .submitted {
            // The foreground route can recover even while the background queue is full or cooling down.
            let gate = LinkReplyGate<ControlTransferReply>()
            Task { @MainActor [weak self] in
                guard let self, self.controlGeneration == generation else { return }
                do {
                    let result = try await withCheckedThrowingContinuation { continuation in
                        guard gate.install(continuation) else { return }
                        gate.startDeadline(failure: ControlTransferReplyFailure.localDeadline)
                        self.session.sendMessage(metadata, replyHandler: { @Sendable [weak self, session = self.session] reply in
                            let preserved = self?.ingestInteractiveControlReply(reply) ?? (reply["control_preserved"] as? Bool == true)
                            let observation = Self.controlObservation(session)
                            if !gate.finish(.success(ControlTransferReply(preserved: preserved, observation: observation))), preserved {
                                // A late persisted-Inbox reply still proves custody without finishing a newer attempt.
                                Task { @MainActor in
                                    guard let self else { return }
                                    self.recordControlDiagnostic(message, generation: generation, route: .interactive,
                                        outcome: .lateInboxPreserved, observation: observation)
                                    guard self.controlGeneration == generation else { return }
                                    do { try self.confirmControlDelivery(message); self.event(.controlTransportFinished(message: message, failure: nil)) }
                                    catch { self.event(.failed(TransportFailure(error))) }
                                }
                            }
                        }, errorHandler: { @Sendable [weak self, session = self.session] error in
                            let failure = TransportFailure(error), observation = Self.controlObservation(session)
                            if !gate.finish(.failure(ControlTransferReplyFailure.sdk(failure, observation))) {
                                Task { @MainActor in
                                    self?.recordControlDiagnostic(message, generation: generation, route: .interactive,
                                        outcome: .lateSDKError, observation: observation, failure: failure)
                                }
                            }
                        })
                    }
                    self.recordControlDiagnostic(message, generation: generation, route: .interactive,
                        outcome: result.preserved ? .inboxPreserved : .inboxRejected, observation: result.observation)
                    guard self.controlGeneration == generation else { return }
                    self.completeInteractive(message, failed: !result.preserved)
                } catch {
                    let failure: TransportFailure, observation: ControlTransferDiagnostic.Observation
                    let outcome: ControlTransferDiagnostic.Outcome
                    switch error {
                    case ControlTransferReplyFailure.sdk(let value, let captured):
                        failure = value; observation = captured; outcome = .sdkError
                    case ControlTransferReplyFailure.localDeadline:
                        failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.messageReplyTimedOut.rawValue))
                        observation = Self.controlObservation(self.session); outcome = .localDeadline
                    default:
                        failure = TransportFailure(error); observation = Self.controlObservation(self.session); outcome = .localError
                    }
                    self.recordControlDiagnostic(message, generation: generation, route: .interactive,
                        outcome: outcome, observation: observation, failure: failure)
                    guard self.controlGeneration == generation else { return }
                    self.completeInteractive(message, failed: true, failure: failure)
                }
            }
        }
        return routes
    }

    func reserveControlRoutes(_ message: ControlMessage, outstanding: [ControlMessage]?, isReachable: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws
        -> (background: ControlSubmissionResult, interactive: ControlSubmissionResult) {
        if let outstanding {
            try controlSubmissions.reconcile(outstanding, now: now)
        }
        if try controlSubmissions.deliveryIsConfirmed(message) {
            return (.alreadySubmitted, .alreadySubmitted)
        }
        let interactive = isReachable ? try interactiveControls.reserve(message, now: now) : .deferred
        // A live request owns this attempt. Admit a background copy only after it fails,
        // not alongside every foreground request. SDK backlog still cannot block this route.
        if interactive == .submitted || interactive == .alreadySubmitted {
            return (.deferred, interactive)
        }
        if isReachable, interactive != .retryLater, !interactiveControls.isRecoveringChannel {
            return (.deferred, interactive) // An occupied foreground window is not a failed attempt.
        }
        let background = try controlSubmissions.reserve(message, now: now)
        return (background, interactive)
    }

    @discardableResult func finishInteractive(_ message: ControlMessage, failed: Bool) -> Bool {
        do {
            let deliveryFailed = try interactiveControls.didFinish(message, failed: failed, channelFailure: failed)
            if !deliveryFailed {
                // This reply is sent only after ControlInbox.preserve succeeds, not after business application.
                try confirmControlDelivery(message)
                event(.controlTransportFinished(message: message, failure: nil))
            }
            return deliveryFailed
        }
        catch { event(.failed(TransportFailure(error))); return false }
    }

    private func completeInteractive(_ message: ControlMessage, failed: Bool, failure: TransportFailure? = nil) {
        guard finishInteractive(message, failed: failed) else { return }
        if let failure {
            logger.error("Immediate control \(Self.controlKind(message), privacy: .public): \(failure.domain, privacy: .public) / \(failure.code), underlying=\(failure.underlyingDomain ?? "none", privacy: .public) / \(failure.underlyingCode ?? 0), reachable=\(self.session.isReachable)")
        }
        guard session.activationState == .activated, peerState == .available else {
            if let failure { event(.controlTransportFinished(message: message, failure: failure)) }
            return
        }
        do {
            // Channel cooldown prevents re-entering the immediate route here.
            let fallback = try transferControl(message)
            if fallback == .deferred || fallback == .retryLater, let failure {
                event(.controlTransportFinished(message: message, failure: failure))
            } else { event(.controlSubmissionChanged) }
        } catch { event(.failed(TransportFailure(error))) }
    }

    public func cancelTransfers(sessionID: UUID) throws {
        cancelAudioBlockTransfer()
        resumableAudioBlockChunkID = nil
        for transfer in session.outstandingFileTransfers {
            let envelope = try LinkWireFormat.fileEnvelope(transfer.file.metadata)
            if envelope.manifest.sessionID == sessionID { transfer.cancel() }
        }
        try refreshOutstanding()
    }

    public var isReachable: Bool { session.activationState == .activated && session.isReachable }
    public var hasPendingContent: Bool { session.hasContentPending }
    public var hasRetryableControls: Bool { controlSubmissions.hasRetryableControls || interactiveControls.hasRetryableControls }
    public var hasDueControlRetries: Bool { controlSubmissions.hasDueControlRetries() || interactiveControls.hasDueControlRetries() }
    public var hasRetryableFiles: Bool { submissions.hasRetryableFiles }
    public var hasDueFileRetries: Bool { submissions.hasDueFileRetries() }
    public var outstandingFileCount: Int { session.outstandingFileTransfers.count }

    public func nextRetryDelay(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        let blockDelay: TimeInterval? = (audioBlockTask == nil && audioBlockRetryAt > now && session.isReachable)
            ? (audioBlockRetryAt - now) : nil
        return [
            blockDelay,
            submissions.nextRetryDelay(now: now),
            controlSubmissions.nextRetryDelay(now: now),
            session.isReachable ? interactiveControls.nextRetryDelay(now: now) : nil
        ].compactMap { $0 }.min()
    }

    @discardableResult private func refreshOutstanding() throws -> [(WCSessionFileTransfer, ManifestEnvelope)] {
        try recoverAttemptsIfNeeded()
        submissions.update(activation: session.activationState == .activated ? .activated : .inactive, isReachable: session.isReachable)
        var transfers: [(WCSessionFileTransfer, ManifestEnvelope)] = []
        for transfer in session.outstandingFileTransfers {
            do { transfers.append((transfer, try LinkWireFormat.fileEnvelope(transfer.file.metadata))) }
            catch {
                guard error is LinkError || error is ContractError || error is DecodingError else { throw error }
                // Cancel only the unusable SDK copy. The durable recording still owns retry and deletion.
                transfer.cancel()
                logger.error("Cancelled file transfer with unreadable system metadata; outstanding=\(self.session.outstandingFileTransfers.count)")
            }
        }
        var next = fileAttempts
        let observations = transfers.map { transfer, envelope in
            let attemptID = (transfer.file.metadata?["file_attempt_id"] as? String).flatMap(UUID.init(uuidString:))
            return FileTransferObservation(envelope: envelope, attemptID: attemptID,
                completedUnits: transfer.progress.completedUnitCount)
        }
        let preservedChunkID = audioBlockChunkID ?? resumableAudioBlockChunkID
        try next.reconcileSnapshot(observations, now: Date(), preservingAudioBlockChunkID: preservedChunkID)
        for (transfer, envelope) in transfers {
            if next.attempts[envelope.manifest.chunkID]?.cancellationRequestedAt != nil {
                submissions.retireFileAttempt(chunkID: envelope.manifest.chunkID)
                transfer.cancel() // A persisted cancellation can outlive process death.
            }
        }
        if next != fileAttempts { try saveAttempts(next, immediate: false) }
        try submissions.reconcile(transfers.map(\.1))
        persistQueueDiagnostic(transfers)
        return transfers
    }

    private func saveAttempts(_ next: FileAttemptLedger, immediate: Bool = true) throws {
        // A journal error pauses sync admission, never capture or receipt persistence in the recording store.
        if let attemptJournalFailure { throw attemptJournalFailure }
        if !immediate && !attemptJournalNeedsSave {
            guard next != fileAttempts else { return }
            fileAttempts = next
            guard attemptsURL != nil else { return }
            coalescedAttemptsDirty = true
            if coalescedAttemptsFlushTask == nil {
                coalescedAttemptsFlushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.flushCoalescedAttempts()
                }
            }
            return
        }
        coalescedAttemptsFlushTask?.cancel()
        coalescedAttemptsFlushTask = nil
        guard attemptJournalNeedsSave || coalescedAttemptsDirty || next != fileAttempts else { return }
        if let attemptsURL {
            try FileAttemptJournal.save(next, at: attemptsURL)
        }
        fileAttempts = next
        attemptJournalNeedsSave = false
        coalescedAttemptsDirty = false
    }

    private func flushCoalescedAttempts() {
        coalescedAttemptsFlushTask = nil
        guard coalescedAttemptsDirty, attemptJournalFailure == nil else { return }
        do {
            if let attemptsURL {
                try FileAttemptJournal.save(fileAttempts, at: attemptsURL)
            }
            attemptJournalNeedsSave = false
            coalescedAttemptsDirty = false
        } catch {
            attemptJournalFailure = TransportFailure(error)
            event(.failed(TransportFailure(error)))
        }
    }

    private func recoverAttemptsIfNeeded() throws {
        if attemptJournalFailure != nil { try loadAttempts() }
    }

    private func loadAttempts() throws {
        coalescedAttemptsFlushTask?.cancel()
        coalescedAttemptsFlushTask = nil
        coalescedAttemptsDirty = false
        if let attemptsURL {
            let loaded = try FileAttemptJournal.load(at: attemptsURL)
            fileAttempts = loaded.ledger
            attemptJournalNeedsSave = !FileManager.default.fileExists(atPath: attemptsURL.path)
            if loaded.recoveredCorruption {
                logger.error("Rebuilt unreadable attempt journal; prior cache preserved, old callbacks rejected, recordings unchanged")
            }
        }
        if let controlScopeID {
            let prior = fileAttempts
            fileAttempts.bindControlScope(controlScopeID)
            if prior != fileAttempts { attemptJournalNeedsSave = true }
        }
        submissions.seedCompletedFromLedger(fileAttempts)
        attemptJournalFailure = nil
    }

    func persistQueueDiagnostic(_ transfers: [(WCSessionFileTransfer, ManifestEnvelope)], force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let diagnosticsURL, force || now - lastDiagnosticsAt >= 30 else { return }
        lastDiagnosticsAt = now
        let snapshot = FileQueueDiagnostic(observedAt: Date(), activated: session.activationState == .activated,
            reachable: session.isReachable, peerAvailable: peerState == .available,
            hasPendingContent: session.hasContentPending, outstandingControls: session.outstandingUserInfoTransfers.count,
            outstandingFiles: transfers.count, audioBlockChunkID: audioBlockChunkID,
            audioBlockRetryAfter: max(0, audioBlockRetryAt - now),
            audioBlockOffset: audioBlockOffset, audioBlockPhase: audioBlockPhase,
            audioBlockLastProgressAt: audioBlockLastProgressAt,
            transfers: transfers.prefix(submissions.maximumOutstandingCount).map { transfer, envelope in
                let attempt = fileAttempts.attempts[envelope.manifest.chunkID]
                return FileQueueDiagnostic.Transfer(chunkID: envelope.manifest.chunkID,
                    completedUnits: transfer.progress.completedUnitCount, totalUnits: transfer.progress.totalUnitCount,
                    transferring: transfer.isTransferring, attemptID: attempt?.attemptID,
                    startedAt: attempt?.startedAt, lastProgressAt: attempt?.lastProgressAt,
                    cancellationRequestedAt: attempt?.cancellationRequestedAt, retryNotBefore: attempt?.retryNotBefore)
            })
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: diagnosticsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            let failure = error as NSError
            logger.error("File queue diagnostic write failed: \(failure.domain, privacy: .public) / \(failure.code)")
        }
    }

    private func validatedOutstandingControls() throws -> [ControlMessage] {
        var messages: [ControlMessage] = []
        for transfer in session.outstandingUserInfoTransfers {
            do {
                let message = try LinkWireFormat.controlMessage(transfer.userInfo)
                let generation = (transfer.userInfo["control_generation"] as? String).flatMap(UUID.init(uuidString:))
                if !fileAttempts.acceptsControlCallback(generation: generation) { transfer.cancel() }
                messages.append(message) // Retain its occupied SDK slot until it really exits.
            }
            catch {
                guard error is LinkError || error is ContractError || error is DecodingError else { throw error }
                transfer.cancel()
                // Live SDK copies remain in reconcile's budget; backoff and durable outboxes are retained.
                controlSubmissions.allowReplay()
                logger.error("Cancelled control transfer with unreadable system metadata; outstanding=\(self.session.outstandingUserInfoTransfers.count)")
            }
        }
        return messages
    }

    private nonisolated static func controlObservation(_ session: WCSession) -> ControlTransferDiagnostic.Observation {
        .init(observedAt: Date(), activated: session.activationState == .activated, reachable: session.isReachable)
    }

    private func restoreControlDiagnostic() throws {
        guard let controlDiagnosticsURL, FileManager.default.fileExists(atPath: controlDiagnosticsURL.path) else { return }
        let size = try controlDiagnosticsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 65_536 else { throw LinkError.invalidMetadata }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(ControlTransferDiagnostic.self, from: Data(contentsOf: controlDiagnosticsURL))
        guard saved.entries.count <= ControlTransferDiagnostic.maximumEntries else { throw LinkError.invalidMetadata }
        controlDiagnostic = saved
    }

    private func recordControlDiagnostic(_ message: ControlMessage, generation: UUID?, route: ControlTransferDiagnostic.Route,
        outcome: ControlTransferDiagnostic.Outcome, observation: ControlTransferDiagnostic.Observation,
        failure: TransportFailure? = nil) {
        guard let controlDiagnosticsURL else { return }
        controlDiagnostic.append(message: message, generation: generation, route: route, outcome: outcome,
                                 observation: observation, failure: failure)
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(controlDiagnostic).write(to: controlDiagnosticsURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            let failure = error as NSError
            logger.error("Control diagnostic write failed: \(failure.domain, privacy: .public) / \(failure.code)")
        }
    }

    public nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let activated = activationState == .activated
        let failure = error.map(TransportFailure.init)
        #if os(iOS)
        let selection = captureSelection(session, activation: failure == nil && activated ? .activated : .inactive)
        event(.selectedWatchChanged(selection))
        // Capture the selected Watch's cached context before an actor hop can cross another activation.
        if activated && failure == nil { receiveSelectedStatus(session.receivedApplicationContext, origin: .restoredApplicationContext) }
        #endif
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let failure, self.peerState == .available {
                self.activation = .failed
                self.event(.activationChanged(.failed))
                self.event(.failed(failure))
            } else {
                self.activation = activated ? .activated : .inactive
                self.event(.activationChanged(self.activation))
                #if os(watchOS)
                if activated { self.restoreApplicationContext() }
                #endif
            }
        }
    }

    public nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            let envelope = try LinkWireFormat.fileEnvelope(file.metadata)
            // Apple removes the temporary file after this delegate returns.
            try preserveFile(file.fileURL, envelope)
            event(.filePreserved(chunkID: envelope.manifest.chunkID))
        } catch { event(.failed(TransportFailure(error))) }
    }

    public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        do {
            try preserveControl(LinkWireFormat.controlMessage(userInfo))
            event(.controlPreserved)
        } catch { event(.failed(TransportFailure(error))) }
    }

    public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard reachable, self.session.isReachable else {
                self.activeAudioBlockGate?.finish(.failure(LinkError.notReachable))
                return
            }
            self.interactiveControls.allowReplay()
            self.allowAudioBlockReplay()
            #if os(iOS)
            if let metadata = self.lastPublishedPhoneStatusMetadata, self.session.activationState == .activated,
               self.session.isReachable, self.peerState == .available {
                self.session.sendMessage(metadata, replyHandler: nil, errorHandler: { @Sendable _ in })
            }
            #endif
            self.requestPeerStatus()
            self.event(.controlSubmissionChanged)
        }
    }

    public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        _ = receiveInteractive(message)
    }

    public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                                   replyHandler: @escaping ([String: Any]) -> Void) {
        if message["status_request"] != nil, let statusReplyProvider {
            let viewing: Bool
            do {
                guard let requested = try LinkWireFormat.statusRequestViewing(message) else { throw LinkError.invalidMetadata }
                viewing = requested
            } catch {
                replyHandler(["status_reply_failed": true])
                event(.failed(TransportFailure(error)))
                return
            }
            let reply = LinkReplyHandler(replyHandler)
            // This request already has a reply route; do not also publish context and an unsolicited message.
            Task {
                do {
                    let snapshot = try await statusReplyProvider(viewing)
                    reply.send(try LinkWireFormat.statusMetadata(snapshot))
                    logger.notice("Status returned in request reply; build=\(snapshot.sourceBuild, privacy: .public)")
                } catch {
                    reply.send(["status_reply_failed": true])
                    event(.failed(TransportFailure(error)))
                }
            }
            return
        }
        if let header = message["audio_block_header"] as? Data,
           let payload = message["audio_block_payload"] as? Data {
            receiveBinaryAudioBlock(header: header, payload: payload, replyHandler: replyHandler)
            return
        }
        if let data = message["audio_block"] as? Data {
            receiveAudioBlockData(data, replyHandler: replyHandler)
            return
        }
        if message["control"] != nil, let controlReplyProvider {
            let incoming: ControlMessage
            do {
                incoming = try LinkWireFormat.controlMessage(message)
                try preserveControl(incoming)
                event(.controlPreserved)
            } catch {
                event(.failed(TransportFailure(error)))
                replyHandler(["control_preserved": false])
                return
            }
            let reply = LinkReplyHandler(replyHandler)
            Task {
                do {
                    let response = try await controlReplyProvider(incoming)
                    reply.send(try LinkWireFormat.controlReplyMetadata(preserved: true, reply: response))
                } catch {
                    reply.send(["control_preserved": true])
                    event(.failed(TransportFailure(error)))
                }
            }
            return
        }
        let preserved = receiveInteractive(message)
        replyHandler(["control_preserved": preserved])
    }

    @discardableResult
    public nonisolated func ingestInteractiveControlReply(_ reply: [String: Any]) -> Bool {
        guard reply["control_preserved"] as? Bool == true else { return false }
        do {
            if let response = try LinkWireFormat.controlReplyMessage(reply) {
                try preserveControl(response)
                event(.controlPreserved)
            }
        } catch {
            event(.failed(TransportFailure(error)))
        }
        return true
    }

    private nonisolated func receivePeerStatusReply(_ metadata: [String: Any]) {
        // Older peers still refresh application context and return only control_preserved.
        guard metadata["status_snapshot"] != nil else { return }
        #if os(iOS)
        receiveSelectedStatus(metadata, origin: .applicationContextCallback)
        #else
        do {
            let snapshot = try LinkWireFormat.statusSnapshot(metadata)
            Task { @MainActor [weak self] in self?.receiveStatus(snapshot, origin: .applicationContextCallback) }
        } catch { event(.failed(TransportFailure(error))) }
        #endif
    }

    private nonisolated func receiveInteractive(_ metadata: [String: Any]) -> Bool {
        do {
            if try LinkWireFormat.statusRequestViewing(metadata) != nil {
                event(.statusRefreshRequested)
            } else if metadata["control"] != nil {
                try preserveControl(LinkWireFormat.controlMessage(metadata))
                event(.controlPreserved)
            } else {
                #if os(iOS)
                receiveSelectedStatus(metadata, origin: .applicationContextCallback)
                #else
                let snapshot = try LinkWireFormat.statusSnapshot(metadata)
                Task { @MainActor [weak self] in
                    self?.receiveStatus(snapshot, origin: .applicationContextCallback)
                }
                #endif
            }
            return true
        } catch { event(.failed(TransportFailure(error))); return false }
    }

    public nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard !applicationContext.isEmpty else { return }
        #if os(iOS)
        receiveSelectedStatus(applicationContext, origin: .applicationContextCallback)
        #else
        do {
            // Decode before the actor hop; an untyped property-list dictionary is not Sendable.
            let snapshot = try LinkWireFormat.statusSnapshot(applicationContext)
            Task { @MainActor [weak self] in
                self?.receiveStatus(snapshot, origin: .applicationContextCallback)
            }
        } catch { event(.failed(TransportFailure(error))) }
        #endif
    }

    #if os(iOS)
    private nonisolated func captureSelection(_ session: WCSession, activation: LinkActivation) -> SelectedWatchContext {
        let peer: LinkPeerState = !session.isPaired ? .notPaired
            : session.isWatchAppInstalled ? .available : .companionNotInstalled
        return selectedWatch.select(activation: activation, peerState: peer,
            directoryURL: activation == .activated ? session.watchDirectoryURL : nil)
    }

    private nonisolated func receiveSelectedStatus(_ metadata: [String: Any], origin: StatusReceptionOrigin) {
        guard !metadata.isEmpty else { return }
        let context = selectedWatch.receive()
        do {
            let snapshot = try LinkWireFormat.statusSnapshot(metadata)
            guard snapshot.sourceRole == .watch else { throw LinkError.unexpectedStatusRole }
            // The Archive owns validation and revision gates. Even an old scope can retain historical status.
            event(.selectedWatchStatusReceived(snapshot, origin: origin, context: context))
        } catch { event(.selectedWatchStatusFailed(TransportFailure(error), context: context)) }
    }
    #endif

    private func restoreApplicationContext() {
        let metadata = session.receivedApplicationContext
        guard !metadata.isEmpty else { return }
        do {
            receiveStatus(try LinkWireFormat.statusSnapshot(metadata), origin: .restoredApplicationContext)
        } catch { event(.failed(TransportFailure(error))) }
    }

    private func receiveStatus(_ snapshot: StatusSnapshot, origin: StatusReceptionOrigin) {
        do {
            try validateStatusRole(snapshot, fromPeer: true)
            guard try receivedStatuses.accept(snapshot) else { return }
            event(.statusReceived(snapshot, origin: origin))
        } catch { event(.failed(TransportFailure(error))) }
    }

    private func validateStatusRole(_ snapshot: StatusSnapshot, fromPeer: Bool) throws {
        #if os(iOS)
        let valid = fromPeer ? snapshot.sourceRole == .watch : snapshot.sourceRole == .phone
        #else
        let valid = fromPeer ? snapshot.sourceRole == .phone : snapshot.sourceRole == .watch
        #endif
        guard valid else { throw LinkError.unexpectedStatusRole }
    }

    public nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?) {
        let observation = Self.controlObservation(session)
        let generation = (userInfoTransfer.userInfo["control_generation"] as? String).flatMap(UUID.init(uuidString:))
        do {
            let message = try LinkWireFormat.controlMessage(userInfoTransfer.userInfo)
            let failure = error.map(TransportFailure.init)
            if failure != nil { userInfoTransfer.cancel() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordControlDiagnostic(message, generation: generation, route: .background,
                    outcome: failure == nil ? .sdkCompleted : .sdkError, observation: observation, failure: failure)
                guard self.fileAttempts.acceptsControlCallback(generation: generation) else {
                    self.event(.controlSubmissionChanged)
                    return
                }
                do {
                    let failed = try self.controlSubmissions.didFinish(message, failed: failure != nil,
                        channelFailure: failure.map(Self.isControlChannelFailure) ?? false)
                    if let failure {
                        self.logger.error("Background control \(Self.controlKind(message), privacy: .public): \(failure.domain, privacy: .public) / \(failure.code), underlying=\(failure.underlyingDomain ?? "none", privacy: .public) / \(failure.underlyingCode ?? 0), deliveryFailed=\(failed), reachable=\(session.isReachable), outstanding=\(session.outstandingUserInfoTransfers.count)")
                    }
                    self.event(.controlTransportFinished(message: message, failure: failed ? failure : nil))
                } catch { self.event(.failed(TransportFailure(error))) }
            }
        } catch {
            userInfoTransfer.cancel()
            let failure = TransportFailure(error)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.fileAttempts.acceptsControlCallback(generation: generation) else {
                    self.event(.controlSubmissionChanged)
                    return
                }
                self.controlSubmissions.allowReplay()
                self.event(.failed(failure))
            }
        }
    }

    public static func isTransientChannelFailure(_ failure: TransportFailure) -> Bool {
        if failure.isTransientLinkFailure { return true }
        let blockDomain = (AudioBlockTransferError.timedOut as NSError).domain
        if failure.domain == blockDomain {
            return failure.code != (AudioBlockTransferError.invalidSource as NSError).code
        }
        guard failure.domain == WCErrorDomain, let code = WCError.Code(rawValue: failure.code) else { return false }
        return switch code {
        case .genericError, .sessionNotActivated, .sessionInactive, .notReachable,
             .messageReplyTimedOut, .deliveryFailed, .transferTimedOut:
            true
        default:
            false
        }
    }

    static func isControlChannelFailure(_ failure: TransportFailure) -> Bool {
        guard failure.domain == WCErrorDomain, let code = WCError.Code(rawValue: failure.code) else { return false }
        return switch code {
        case .genericError, .sessionNotActivated, .sessionInactive, .notReachable, .deliveryFailed, .transferTimedOut: true
        default: false
        }
    }

    private static func controlKind(_ message: ControlMessage) -> String {
        ControlTransferDiagnostic.kind(message)
    }

    public nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        do {
            let envelope = try LinkWireFormat.fileEnvelope(fileTransfer.file.metadata)
            let attemptID = (fileTransfer.file.metadata?["file_attempt_id"] as? String).flatMap(UUID.init(uuidString:))
            let failure = error.map(TransportFailure.init)
            if failure != nil { fileTransfer.cancel() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.fileAttempts.acceptsFileCallback(chunkID: envelope.manifest.chunkID, attemptID: attemptID) else {
                    self.event(.fileTransportFinished(chunkID: envelope.manifest.chunkID, failure: nil))
                    return
                }
                var next = self.fileAttempts
                next.finish(chunkID: envelope.manifest.chunkID, attemptID: attemptID, succeededAt: failure == nil ? Date() : nil)
                do { try self.saveAttempts(next, immediate: false) }
                catch { self.event(.failed(TransportFailure(error))) }
                let deliveryFailed = self.submissions.didFinish(chunkID: envelope.manifest.chunkID, failed: failure != nil)
                if let failure, deliveryFailed {
                    self.logger.error("Background file: \(failure.domain, privacy: .public) / \(failure.code), underlying=\(failure.underlyingDomain ?? "none", privacy: .public) / \(failure.underlyingCode ?? 0), reachable=\(session.isReachable), outstanding=\(session.outstandingFileTransfers.count)")
                }
                self.event(.fileTransportFinished(chunkID: envelope.manifest.chunkID, failure: deliveryFailed ? failure : nil))
            }
        } catch { fileTransfer.cancel(); event(.failed(TransportFailure(error))) }
    }

    #if os(iOS)
    public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        event(.selectedWatchChanged(captureSelection(session, activation: .inactive)))
        Task { @MainActor [weak self] in
            self?.activation = .inactive
            self?.event(.activationChanged(.inactive))
        }
    }

    public nonisolated func sessionDidDeactivate(_ session: WCSession) {
        event(.selectedWatchChanged(captureSelection(session, activation: .inactive)))
        Task { @MainActor [weak self] in self?.activate() }
    }

    public nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        event(.selectedWatchChanged(captureSelection(session,
            activation: session.activationState == .activated ? .activated : .inactive)))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.peerState == .available, self.activation != .activated { self.activate() }
            else { self.event(.activationChanged(self.activation)) }
        }
    }
    #endif
}
#endif
