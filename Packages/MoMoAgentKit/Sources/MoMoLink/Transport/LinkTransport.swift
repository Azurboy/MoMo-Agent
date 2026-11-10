import Foundation
import MoMoContracts

public enum LinkActivation: String, Sendable { case inactive, activating, activated, failed }
public enum LinkPeerState: Sendable, Equatable { case available, notPaired, companionNotInstalled }
public enum FileSubmissionResult: Sendable, Equatable { case submitted, alreadySubmitted, deferred, retryLater }
public enum LinkError: Error, Equatable, Sendable {
    case unsupported, notActivated, notReachable, invalidMetadata, controlMessageTooLarge
    case conflictingTransfer(UUID)
    case statusSnapshotTooLarge, unexpectedStatusRole
    case fileAttemptNotReady
    case conflictingStatus(sourceDeviceID: UUID, sourceStoreInstanceID: UUID, revision: Int64)
}

public enum LinkEvent: Sendable {
    case activationChanged(LinkActivation)
    case statusRefreshRequested
    case fileTransportFinished(chunkID: UUID, failure: TransportFailure?)
    case filePreserved(chunkID: UUID)
    case audioBlockCommitted(chunkID: UUID)
    case audioBlockSourceInvalid(chunkID: UUID)
    case controlPreserved
    case controlSubmissionChanged
    case controlTransportFinished(message: ControlMessage, failure: TransportFailure?)
    case statusReceived(StatusSnapshot, origin: StatusReceptionOrigin)
    case selectedWatchChanged(SelectedWatchContext)
    case selectedWatchStatusReceived(StatusSnapshot, origin: StatusReceptionOrigin, context: SelectedWatchContext)
    case selectedWatchStatusFailed(TransportFailure, context: SelectedWatchContext)
    case failed(TransportFailure)
}

public struct TransportFailure: Error, Sendable, Equatable {
    public let domain: String
    public let code: Int
    public let message: String
    public let underlyingDomain: String?
    public let underlyingCode: Int?
    public var diagnosticDescription: String { "\(message)（\(domain) \(code)）" }
    public var isTransientLinkFailure: Bool {
        let notActivated = LinkError.notActivated as NSError
        let notReachable = LinkError.notReachable as NSError
        return (domain == notActivated.domain && code == notActivated.code)
            || (domain == notReachable.domain && code == notReachable.code)
    }
    public init(_ error: any Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
        message = error.localizedDescription
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        underlyingDomain = underlying?.domain
        underlyingCode = underlying?.code
    }
}

/// Tracks only system transport work; durable retry and deletion belong to the stores.
public struct LinkSubmissionState: Sendable {
    public static let maximumOutstandingFiles = 4
    public static let bulkMaximumOutstandingFiles = 12
    public static let initialReceiptWaitDelay: TimeInterval = 120
    public static let maximumReceiptWaitDelay: TimeInterval = 1_800
    public let maximumOutstandingCount: Int
    public private(set) var activation: LinkActivation = .inactive
    public private(set) var isReachable = false
    private var outstanding: [UUID: (hash: String, count: Int)] = [:]
    private var submitted: [UUID: String] = [:]
    private var retiring: Set<UUID> = []
    private var requestedReplays: Set<UUID> = []
    private var retryNotBefore: [UUID: TimeInterval] = [:]
    private var retryBackoffs: [UUID: LinkRetryBackoff] = [:]
    private struct ReceiptWait: Sendable {
        var deadline: TimeInterval?
        var delay: TimeInterval = LinkSubmissionState.initialReceiptWaitDelay
    }
    private var awaitingReceipts: [UUID: ReceiptWait] = [:]
    public var hasRetryableFiles: Bool { !retryNotBefore.isEmpty || awaitingReceipts.values.contains { $0.deadline != nil } }

    public func hasDueFileRetries(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if requestedReplays.contains(where: { id in outstanding[id] == nil && (retryNotBefore[id].map { now >= $0 } ?? true) }) {
            return true
        }
        if retryNotBefore.contains(where: { id, retryAt in outstanding[id] == nil && now >= retryAt }) {
            return true
        }
        return awaitingReceipts.contains { id, wait in
            outstanding[id] == nil && (wait.deadline.map { now >= $0 } ?? false)
        }
    }

    public func nextRetryDelay(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        let retry = retryNotBefore.compactMap { id, retryAt -> TimeInterval? in
            guard outstanding[id] == nil, retryAt > now else { return nil }
            return retryAt - now
        }.min()
        let wait = awaitingReceipts.compactMap { id, entry -> TimeInterval? in
            guard outstanding[id] == nil, let deadline = entry.deadline, deadline > now else { return nil }
            return deadline - now
        }.min()
        return [retry, wait].compactMap { $0 }.min()
    }

    public init(maximumOutstandingFiles: Int = Self.maximumOutstandingFiles) {
        self.maximumOutstandingCount = max(1, maximumOutstandingFiles)
    }
    /// Durable stores choose when a new activation, foreground pass, or explicit missing result permits replay.
    public mutating func allowFileReplay() { submitted.removeAll() }
    public mutating func allowFileReplay(chunkIDs: [UUID]) {
        for id in chunkIDs {
            submitted.removeValue(forKey: id)
            requestedReplays.insert(id)
        }
    }
    /// Restores completed transport attempts that are still awaiting formal application receipts across restarts.
    public mutating func seedCompletedFromLedger(
        _ ledger: FileAttemptLedger,
        nowWallClock: Date = Date(),
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        for (id, attempt) in ledger.attempts {
            guard !attempt.outstanding,
                  attempt.cancellationRequestedAt == nil,
                  let completedAt = attempt.completedAt,
                  outstanding[id] == nil else { continue }
            let waitDuration = min(
                Self.maximumReceiptWaitDelay,
                max(Self.initialReceiptWaitDelay, attempt.receiptWaitDelay ?? Self.initialReceiptWaitDelay)
            )
            let elapsed = max(0, nowWallClock.timeIntervalSince(completedAt))
            guard elapsed < waitDuration else { continue }
            submitted[id] = attempt.manifestSHA256
            awaitingReceipts[id] = ReceiptWait(
                deadline: nowUptime + (waitDuration - elapsed),
                delay: min(Self.maximumReceiptWaitDelay, waitDuration * 2)
            )
        }
    }
    /// Cancellation retires only this system attempt. The store still owns its pending original.
    public mutating func retireFileAttempt(chunkID: UUID) {
        retiring.insert(chunkID)
        submitted.removeValue(forKey: chunkID)
        awaitingReceipts.removeValue(forKey: chunkID)
        retryNotBefore.removeValue(forKey: chunkID)
        retryBackoffs.removeValue(forKey: chunkID)
        requestedReplays.insert(chunkID)
    }
    public mutating func update(activation: LinkActivation, isReachable: Bool) {
        self.activation = activation
        self.isReachable = isReachable
    }

    public mutating func reconcile(_ envelopes: [ManifestEnvelope], now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        var result: [UUID: (hash: String, count: Int)] = [:]
        for envelope in envelopes {
            let id = envelope.manifest.chunkID
            if let known = result[id], known.hash != envelope.manifestSHA256 { throw LinkError.conflictingTransfer(id) }
            if let known = submitted[id], known != envelope.manifestSHA256 { throw LinkError.conflictingTransfer(id) }
            result[id] = (envelope.manifestSHA256, (result[id]?.count ?? 0) + 1)
        }
        let completed = outstanding.keys.filter { result[$0] == nil }
        outstanding = result
        for (id, value) in result {
            if submitted[id] == nil, !retiring.contains(id) { awaitingReceipts[id] = ReceiptWait() }
            submitted[id] = value.hash
        }
        for id in completed {
            if retiring.remove(id) != nil {
                submitted.removeValue(forKey: id)
                awaitingReceipts.removeValue(forKey: id)
            } else { waitForReceipt(chunkID: id, now: now) }
        }
    }

    public mutating func shouldSubmit(_ envelope: ManifestEnvelope, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Bool {
        try reserve(envelope, now: now) == .submitted
    }

    public func precheckReservation(_ envelope: ManifestEnvelope,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> FileSubmissionResult? {
        guard activation == .activated else { throw LinkError.notActivated }
        let id = envelope.manifest.chunkID
        if let known = outstanding[id] {
            guard known.hash == envelope.manifestSHA256 else { throw LinkError.conflictingTransfer(id) }
            return .alreadySubmitted
        }
        if let known = submitted[id] {
            guard known == envelope.manifestSHA256 else { throw LinkError.conflictingTransfer(id) }
            if !requestedReplays.contains(id), !(awaitingReceipts[id]?.deadline.map { now >= $0 } ?? false) {
                return .alreadySubmitted
            }
        }
        if let retryAt = retryNotBefore[id], now < retryAt { return .retryLater }
        guard outstanding.values.reduce(0, { $0 + $1.count }) < maximumOutstandingCount else { return .deferred }
        return nil
    }

    public mutating func reserve(_ envelope: ManifestEnvelope, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> FileSubmissionResult {
        if let blocked = try precheckReservation(envelope, now: now) { return blocked }
        let id = envelope.manifest.chunkID
        // Reachability applies to interactive messages, not the background file queue.
        outstanding[id] = (envelope.manifestSHA256, 1)
        submitted[id] = envelope.manifestSHA256
        var receiptWait = awaitingReceipts[id] ?? ReceiptWait()
        receiptWait.deadline = nil
        awaitingReceipts[id] = receiptWait
        // A missing response may arrive before the old transfer's completion callback.
        // Consume its intent only when a new transfer can actually be admitted.
        requestedReplays.remove(id)
        retryNotBefore.removeValue(forKey: id)
        return .submitted
    }

    @discardableResult public mutating func didFinish(chunkID: UUID, failed: Bool = false,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        // A validated application receipt can precede a late transport callback.
        let alreadyConfirmed = submitted[chunkID] != nil && awaitingReceipts[chunkID] == nil
        let deliveryFailed = failed && !alreadyConfirmed
        if deliveryFailed {
            submitted.removeValue(forKey: chunkID)
            var backoff = retryBackoffs[chunkID] ?? LinkRetryBackoff()
            retryNotBefore[chunkID] = now + backoff.nextDelay()
            retryBackoffs[chunkID] = backoff
        } else {
            retryNotBefore.removeValue(forKey: chunkID)
            retryBackoffs.removeValue(forKey: chunkID)
        }
        if let known = outstanding[chunkID] {
            if !failed { submitted[chunkID] = known.hash }
            if known.count > 1 { outstanding[chunkID] = (known.hash, known.count - 1) }
            else { outstanding.removeValue(forKey: chunkID) }
        }
        if !failed, outstanding[chunkID] == nil { waitForReceipt(chunkID: chunkID, now: now) }
        return deliveryFailed
    }

    /// The store must first validate the receiver, library and complete receipt against its manifest.
    public mutating func confirmFileDelivery(_ receipt: Receipt) throws {
        let id = receipt.chunkID
        if let known = submitted[id] ?? outstanding[id]?.hash, known != receipt.manifestSHA256 { throw LinkError.conflictingTransfer(id) }
        submitted[id] = receipt.manifestSHA256
        retiring.remove(id)
        awaitingReceipts.removeValue(forKey: id)
        retryNotBefore.removeValue(forKey: id)
        retryBackoffs.removeValue(forKey: id)
        requestedReplays.remove(id)
    }

    public func allowsInteractiveAudioBlock(_ envelope: ManifestEnvelope) throws -> Bool {
        let id = envelope.manifest.chunkID
        if let known = outstanding[id]?.hash ?? submitted[id] {
            guard known == envelope.manifestSHA256 else { throw LinkError.conflictingTransfer(id) }
        }
        let alreadyConfirmed = submitted[id] != nil && awaitingReceipts[id] == nil
        return !alreadyConfirmed
    }

    public func hasSubmittedFileTransfer(chunkID: UUID) -> Bool {
        outstanding[chunkID] != nil || submitted[chunkID] != nil
    }

    public func hasOutstandingFileTransfer(chunkID: UUID) -> Bool {
        outstanding[chunkID] != nil
    }

    private mutating func waitForReceipt(chunkID: UUID, now: TimeInterval) {
        guard var wait = awaitingReceipts[chunkID], wait.deadline == nil else { return }
        // System completion alone cannot prove durable phone ingestion. Bound retries without duplicating live transfers.
        wait.deadline = now + wait.delay
        wait.delay = min(Self.maximumReceiptWaitDelay, wait.delay * 2)
        awaitingReceipts[chunkID] = wait
    }

    public func requireImmediateMessaging() throws {
        guard activation == .activated else { throw LinkError.notActivated }
        guard isReachable else { throw LinkError.notReachable }
    }
}

public struct FileBatchScanOutcome: Sendable, Equatable {
    public let cursor: Int64
    public let scanned: Int
    public let submittedAny: Bool
    public let wrapped: Bool
    public let deferred: Bool
}

/// Scans forward from `initialCursor` before wrapping once to `0` for due retries, preventing head-of-line starvation.
public func scanFileBatch<Entry>(
    isolation: isolated (any Actor)? = #isolation,
    after initialCursor: Int64,
    maximumScanned: Int,
    pageSize: Int = 4,
    hasDueRetries: () -> Bool,
    sequenceOf: (Entry) -> Int64,
    loadPage: (Int64) async throws -> [Entry]?,
    submit: (Entry) async throws -> FileSubmissionResult?
) async throws -> FileBatchScanOutcome? {
    var cursor = initialCursor
    var wrapped = cursor == 0
    var scanned = 0
    var submittedAny = false
    var deferred = false
    outer: while scanned < maximumScanned {
        guard let entries = try await loadPage(cursor) else { return nil }
        guard !entries.isEmpty else {
            cursor = 0
            if !wrapped, hasDueRetries() {
                wrapped = true
                continue outer
            }
            break
        }
        for entry in entries {
            guard scanned < maximumScanned else { break outer }
            guard let result = try await submit(entry) else { return nil }
            switch result {
            case .submitted:
                cursor = sequenceOf(entry); scanned += 1; submittedAny = true
            case .alreadySubmitted, .retryLater:
                cursor = sequenceOf(entry); scanned += 1
            case .deferred:
                deferred = true
                break outer
            }
        }
        if entries.count < pageSize {
            if !wrapped, hasDueRetries() {
                cursor = 0
                wrapped = true
                continue outer
            }
            break
        }
    }
    return FileBatchScanOutcome(cursor: cursor, scanned: scanned,
        submittedAny: submittedAny, wrapped: wrapped, deferred: deferred)
}

public enum LinkWireFormat {
    public static let maximumControlBytes = 16 * 1024

    public static func statusRequestMetadata(viewing: Bool = false) -> [String: Any] {
        viewing ? ["status_request": true, "viewing": true] : ["status_request": true]
    }

    /// Nil belongs to another channel. A malformed status request is a protocol error.
    public static func statusRequestViewing(_ metadata: [String: Any]) throws -> Bool? {
        guard metadata["status_request"] != nil else { return nil }
        guard metadata["status_request"] as? Bool == true,
              metadata.keys.allSatisfy({ $0 == "status_request" || $0 == "viewing" }) else {
            throw LinkError.invalidMetadata
        }
        guard let value = metadata["viewing"] else { return false }
        guard let viewing = value as? Bool else { throw LinkError.invalidMetadata }
        return viewing
    }

    public static func fileMetadata(_ envelope: ManifestEnvelope) -> [String: Any] {
        ["protocol_version": envelope.protocolVersion, "chunk_id": envelope.manifest.chunkID.uuidString,
         "source_device_id": envelope.manifest.sourceDeviceID.uuidString,
         "manifest": envelope.manifestData, "manifest_sha256": envelope.manifestSHA256]
    }

    public static func fileEnvelope(_ metadata: [String: Any]?) throws -> ManifestEnvelope {
        guard let metadata,
              let version = metadata["protocol_version"] as? Int,
              let idString = metadata["chunk_id"] as? String, let id = UUID(uuidString: idString),
              let deviceString = metadata["source_device_id"] as? String, let deviceID = UUID(uuidString: deviceString),
              let data = metadata["manifest"] as? Data, let hash = metadata["manifest_sha256"] as? String else { throw LinkError.invalidMetadata }
        let envelope = try ManifestEnvelope(manifestData: data, manifestSHA256: hash, protocolVersion: version)
        guard envelope.manifest.chunkID == id, envelope.manifest.sourceDeviceID == deviceID else { throw LinkError.invalidMetadata }
        return envelope
    }

    public static func controlMetadata(_ message: ControlMessage) throws -> [String: Any] {
        let data = try WireJSON.encode(message)
        guard data.count <= maximumControlBytes else { throw LinkError.controlMessageTooLarge }
        return ["protocol_version": 1, "control": data]
    }

    public static func controlMessage(_ metadata: [String: Any]) throws -> ControlMessage {
        guard let version = metadata["protocol_version"] as? Int, version == 1,
              let data = metadata["control"] as? Data else { throw LinkError.invalidMetadata }
        guard data.count <= maximumControlBytes else { throw LinkError.controlMessageTooLarge }
        return try WireJSON.decode(ControlMessage.self, from: data)
    }

    public static func controlReplyMetadata(preserved: Bool, reply: ControlMessage? = nil) throws -> [String: Any] {
        guard preserved, let reply else { return ["control_preserved": preserved] }
        var metadata = try controlMetadata(reply)
        metadata["control_preserved"] = true
        return metadata
    }

    public static func controlReplyMessage(_ metadata: [String: Any]) throws -> ControlMessage? {
        guard metadata["control"] != nil else { return nil }
        return try controlMessage(metadata)
    }
}
