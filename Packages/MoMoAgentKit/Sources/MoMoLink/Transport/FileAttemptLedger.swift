import Foundation
import MoMoContracts

/// Transport attempts never own the recording or authorize its deletion.
public struct FileTransferAttempt: Codable, Sendable, Equatable {
    public let chunkID: UUID
    public let manifestSHA256: String
    public let attemptID: UUID?
    public let startedAt: Date
    public var lastProgressAt: Date
    public var completedUnits: Int64
    public var outstanding: Bool
    public var cancellationRequestedAt: Date?
    public var retryNotBefore: Date?
    public var completedAt: Date? = nil
    public var receiptWaitDelay: TimeInterval? = nil
}

public struct FileTransferObservation: Sendable {
    public let envelope: ManifestEnvelope
    public let attemptID: UUID?
    public let completedUnits: Int64
    public init(envelope: ManifestEnvelope, attemptID: UUID?, completedUnits: Int64) {
        self.envelope = envelope; self.attemptID = attemptID; self.completedUnits = completedUnits
    }
}

/// A small restart-safe journal. Only actual SDK byte progress renews the lease.
public struct FileAttemptLedger: Codable, Sendable, Equatable {
    public static let lease: TimeInterval = 15 * 60
    public static let backgroundLease: TimeInterval = 6 * 60 * 60
    public static let interactiveZeroProgressLease: TimeInterval = 90
    public static let cooldown: TimeInterval = 5 * 60
    public private(set) var controlGeneration = UUID()
    public private(set) var acceptsLegacyControlCallbacks = true
    public private(set) var controlScopeID: UUID?
    public private(set) var attempts: [UUID: FileTransferAttempt] = [:]

    public init() {}

    public func acceptsControlCallback(generation: UUID?) -> Bool {
        generation.map { $0 == controlGeneration } ?? acceptsLegacyControlCallbacks
    }

    public mutating func resetPeer() {
        controlGeneration = UUID()
        acceptsLegacyControlCallbacks = false
        clearCompletedSubmissions()
    }

    public mutating func clearCompletedSubmissions(chunkIDs: [UUID]? = nil) {
        if let chunkIDs {
            for id in chunkIDs {
                guard var entry = attempts[id] else { continue }
                entry.completedAt = nil
                entry.receiptWaitDelay = nil
                if !entry.outstanding && entry.cancellationRequestedAt == nil && entry.retryNotBefore == nil {
                    attempts.removeValue(forKey: id)
                } else {
                    attempts[id] = entry
                }
            }
            return
        }
        for id in Array(attempts.keys) {
            guard var entry = attempts[id] else { continue }
            entry.completedAt = nil
            entry.receiptWaitDelay = nil
            if !entry.outstanding && entry.cancellationRequestedAt == nil && entry.retryNotBefore == nil {
                attempts.removeValue(forKey: id)
            } else {
                attempts[id] = entry
            }
        }
    }

    public mutating func bindControlScope(_ scopeID: UUID) {
        if let previous = controlScopeID, previous != scopeID { resetPeer() }
        controlScopeID = scopeID
    }

    public mutating func observe(envelope: ManifestEnvelope, attemptID: UUID?, completedUnits: Int64,
                                 now: Date) throws {
        let id = envelope.manifest.chunkID
        if let old = attempts[id] {
            guard old.manifestSHA256 == envelope.manifestSHA256 else { throw LinkError.conflictingTransfer(id) }
            // An old callback/snapshot cannot replace a newly admitted attempt.
            guard old.attemptID == attemptID else { return }
            var next = old
            if completedUnits > next.completedUnits {
                next.lastProgressAt = now
                next.completedUnits = completedUnits
            }
            next.outstanding = true
            attempts[id] = next
        } else {
            attempts[id] = FileTransferAttempt(chunkID: id, manifestSHA256: envelope.manifestSHA256,
                attemptID: attemptID, startedAt: now, lastProgressAt: now,
                completedUnits: max(0, completedUnits), outstanding: true)
        }
    }

    /// Resolve one complete SDK snapshot before changing the selected attempt. Duplicate copies cannot flip it.
    public mutating func reconcileSnapshot(_ observations: [FileTransferObservation], now: Date,
                                           preservingAudioBlockChunkID: UUID? = nil) throws {
        let grouped = Dictionary(grouping: observations, by: { $0.envelope.manifest.chunkID })
        for (id, copies) in grouped {
            guard let first = copies.first,
                  copies.allSatisfy({ $0.envelope.manifestSHA256 == first.envelope.manifestSHA256 }) else {
                throw LinkError.conflictingTransfer(id)
            }
            if let old = attempts[id], old.manifestSHA256 != first.envelope.manifestSHA256 {
                throw LinkError.conflictingTransfer(id)
            }
            let retained = attempts[id].flatMap { current in
                copies.filter { $0.attemptID == current.attemptID }.max { $0.completedUnits < $1.completedUnits }
            }
            let selected = retained ?? copies.sorted {
                ($0.attemptID?.uuidString ?? "") < ($1.attemptID?.uuidString ?? "")
            }[0]
            if retained == nil { attempts.removeValue(forKey: id) }
            try observe(envelope: selected.envelope, attemptID: selected.attemptID,
                completedUnits: selected.completedUnits, now: now)
        }
        reconcileOutstanding(Set(grouped.keys), now: now, preservingAudioBlockChunkID: preservingAudioBlockChunkID)
    }

    public mutating func reconcileOutstanding(_ chunkIDs: Set<UUID>, now: Date,
                                              preservingAudioBlockChunkID: UUID? = nil) {
        for id in attempts.keys where !chunkIDs.contains(id) {
            attempts[id]?.outstanding = false
            let old = attempts[id]
            if old?.cancellationRequestedAt != nil, old?.retryNotBefore.map({ now >= $0 }) == true {
                if id != preservingAudioBlockChunkID {
                    attempts.removeValue(forKey: id)
                }
            } else if old?.cancellationRequestedAt == nil, let completedAt = old?.completedAt {
                let retentionBudget = max(Self.lease, old?.receiptWaitDelay ?? Self.lease)
                if now.timeIntervalSince(completedAt) >= retentionBudget {
                    attempts.removeValue(forKey: id)
                }
            } else if old?.cancellationRequestedAt == nil, let progressAt = old?.lastProgressAt,
                      now.timeIntervalSince(progressAt) >= Self.lease {
                attempts.removeValue(forKey: id)
            }
        }
    }

    public func allowsAudioBlockRecovery(chunkID: UUID) -> Bool {
        guard let attempt = attempts[chunkID] else { return false }
        return attempt.cancellationRequestedAt != nil && !attempt.outstanding
    }

    public func canAdmit(_ envelope: ManifestEnvelope, now: Date) throws -> Bool {
        guard let prior = attempts[envelope.manifest.chunkID] else { return true }
        guard prior.manifestSHA256 == envelope.manifestSHA256 else { throw LinkError.conflictingTransfer(prior.chunkID) }
        guard !prior.outstanding else { return false }
        return prior.retryNotBefore.map { now >= $0 } ?? true
    }

    public mutating func begin(_ envelope: ManifestEnvelope, now: Date) throws -> UUID {
        guard try canAdmit(envelope, now: now) else { throw LinkError.fileAttemptNotReady }
        let priorWaitDelay = attempts[envelope.manifest.chunkID]?.receiptWaitDelay
        let attemptID = UUID()
        attempts[envelope.manifest.chunkID] = FileTransferAttempt(chunkID: envelope.manifest.chunkID,
            manifestSHA256: envelope.manifestSHA256, attemptID: attemptID, startedAt: now,
            lastProgressAt: now, completedUnits: 0, outstanding: true,
            completedAt: nil, receiptWaitDelay: priorWaitDelay)
        return attemptID
    }

    public func stalledCandidate(now: Date, eligibleChunkIDs: Set<UUID>? = nil,
                                 stallLease: TimeInterval = Self.lease,
                                 interactiveZeroProgressLease: TimeInterval? = nil) -> FileTransferAttempt? {
        let baseLease = max(Self.lease, stallLease)
        return attempts.values.filter {
            let requiredLease = ($0.completedUnits == 0 ? interactiveZeroProgressLease.map { min(baseLease, $0) } : nil) ?? baseLease
            return $0.outstanding && $0.cancellationRequestedAt == nil
                && now.timeIntervalSince($0.lastProgressAt) >= requiredLease
                && (eligibleChunkIDs?.contains($0.chunkID) ?? true)
        }.min { lhs, rhs in
            lhs.lastProgressAt == rhs.lastProgressAt ? lhs.chunkID.uuidString < rhs.chunkID.uuidString
                : lhs.lastProgressAt < rhs.lastProgressAt
        }
    }

    /// Persist this decision before calling SDK cancel. Keep the slot until the SDK actually drops it.
    public mutating func requestCancellation(_ candidate: FileTransferAttempt, now: Date,
                                             stallLease: TimeInterval = Self.lease,
                                             interactiveZeroProgressLease: TimeInterval? = nil) -> Bool {
        guard let current = attempts[candidate.chunkID], current == candidate,
              current.outstanding, current.cancellationRequestedAt == nil else { return false }
        let baseLease = max(Self.lease, stallLease)
        let requiredLease = (current.completedUnits == 0 ? interactiveZeroProgressLease.map { min(baseLease, $0) } : nil) ?? baseLease
        guard now.timeIntervalSince(current.lastProgressAt) >= requiredLease else { return false }
        attempts[candidate.chunkID]?.cancellationRequestedAt = now
        attempts[candidate.chunkID]?.retryNotBefore = now.addingTimeInterval(Self.cooldown)
        return true
    }

    public func acceptsFileCallback(chunkID: UUID, attemptID: UUID?) -> Bool {
        guard let current = attempts[chunkID] else { return false }
        return current.attemptID == attemptID && current.cancellationRequestedAt == nil
    }

    public mutating func finish(chunkID: UUID, attemptID: UUID?, succeededAt: Date? = nil) {
        guard attempts[chunkID]?.attemptID == attemptID else { return }
        attempts[chunkID]?.outstanding = false
        if let succeededAt {
            let waitDuration = attempts[chunkID]?.receiptWaitDelay.map {
                min(LinkSubmissionState.maximumReceiptWaitDelay, $0 * 2)
            } ?? LinkSubmissionState.initialReceiptWaitDelay
            attempts[chunkID]?.completedAt = succeededAt
            attempts[chunkID]?.receiptWaitDelay = waitDuration
        } else {
            attempts[chunkID]?.completedAt = nil
        }
    }

    public mutating func confirm(chunkID: UUID) { attempts.removeValue(forKey: chunkID) }
}
