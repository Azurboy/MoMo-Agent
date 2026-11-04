import Foundation

/// One received input snapshot for sequential decoding. It never owns a window attempt or completion.
public struct TranscriptionInputLease: Sendable {
    public let inputs: [ArchivedAudioInput]
    public let sessionID: UUID
    public let epochID: UUID
    public let analysisAnchor: Int64
    public let expectedGeneration: Int64
    public let configurationFingerprint: String
    let leaseIDs: [UUID]

    public func contains(_ ticket: TranscriptionWindowTicket) -> Bool {
        matches(window: ticket.window, generation: ticket.expectedGeneration, inputs: ticket.inputs)
    }

    func matches(window: ArchiveAnalysisWindow, generation: Int64, inputs requested: [ArchivedAudioInput]) -> Bool {
        guard sessionID == window.sessionID, epochID == window.epochID,
              analysisAnchor == window.analysisAnchor, expectedGeneration == generation,
              configurationFingerprint == window.configurationFingerprint,
              requested.count <= inputs.count else { return false }
        return zip(requested, inputs).allSatisfy {
            $0.envelope.manifestSHA256 == $1.envelope.manifestSHA256 && $0.audioURL == $1.audioURL
        }
    }
}

extension ArchiveStore {
    public func acquireTranscriptionInputLease(ticket: TranscriptionWindowTicket) throws -> TranscriptionInputLease {
        try validateWindowTicket(ticket)
        guard let rate = ticket.inputs.first?.envelope.manifest.timebaseHz,
              rate.isFinite, rate > 0, rate <= 192_000 else { throw ArchiveError.invalidTranscript }
        let (pageEnd, overflow) = ticket.window.analysisAnchor.addingReportingOverflow(Int64(rate * 300))
        guard !overflow else { throw ArchiveError.invalidTranscript }
        let through = max(pageEnd, ticket.window.contextFrames.end)
        let inputs = try contiguousInputs(epochID: ticket.window.epochID, from: ticket.window.analysisAnchor, through: through)
        guard let end = inputs.last?.envelope.manifest.frames.end, end >= ticket.window.contextFrames.end else {
            throw ArchiveError.staleSource
        }
        let leases = try leaseInputs(inputs)
        return TranscriptionInputLease(inputs: inputs, sessionID: ticket.window.sessionID, epochID: ticket.window.epochID,
            analysisAnchor: ticket.window.analysisAnchor, expectedGeneration: ticket.expectedGeneration,
            configurationFingerprint: ticket.window.configurationFingerprint, leaseIDs: leases)
    }

    /// The caller must first await Speech's reader/native teardown, including on cancellation.
    public func releaseTranscriptionInputLease(_ lease: TranscriptionInputLease) throws {
        for id in lease.leaseIDs { audioLeases.removeValue(forKey: id) }
        try cleanDeletedFilesIfPending()
    }

    func canReuseInputLease(_ lease: TranscriptionInputLease, window: ArchiveAnalysisWindow,
                           generation: Int64, inputs: [ArchivedAudioInput]) -> Bool {
        lease.matches(window: window, generation: generation, inputs: inputs)
            && lease.leaseIDs.count == lease.inputs.count
            && zip(lease.leaseIDs, lease.inputs).allSatisfy { audioLeases[$0] == $1.envelope.manifest.chunkID }
    }
}
