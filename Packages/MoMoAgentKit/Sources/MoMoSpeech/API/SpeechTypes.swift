import Foundation
import MoMoContracts

public enum SpeechError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidModelManifest, modelHashMismatch(String), runtimeVersionMismatch
    case nativeInitialization, nativeResult, invalidAudio(String), inputGap(expected: Int64, actual: Int64)
    case audioRead(domain: String, code: Int)
    case incompatibleCheckpoint, incompatibleWindow, missingAudio, cancelled
}

public struct SpeechConfiguration: Codable, Equatable, Sendable {
    public static let analysisRuleVersion = "silero512-continuous-v1"
    public let language: String
    public let useITN: Bool
    public let threads: Int
    public let threshold: Float
    public let minimumSpeechSeconds: Float
    public let minimumSilenceSeconds: Float
    public let paddingFrames: Int64
    public let maximumCoreFrames: Int64
    public static let sampleRate = 16_000
    public static let vadFrameSize = 512
    static let archiveContextFrames: Int64 = 16_000
    var maximumRecognitionFrames: Int64 { maximumCoreFrames + 2 * max(paddingFrames, Self.archiveContextFrames) }

    public init(language: String = "auto", useITN: Bool = true, threads: Int = 2,
                threshold: Float = 0.5, minimumSpeechSeconds: Float = 0.25,
                minimumSilenceSeconds: Float = 0.5, paddingFrames: Int64 = 4_800,
                maximumCoreFrames: Int64 = 320_000) throws {
        self.language = language; self.useITN = useITN; self.threads = threads
        self.threshold = threshold; self.minimumSpeechSeconds = minimumSpeechSeconds
        self.minimumSilenceSeconds = minimumSilenceSeconds; self.paddingFrames = paddingFrames
        self.maximumCoreFrames = maximumCoreFrames
        try validate()
    }

    public func validate() throws {
        guard SpeechLanguage(rawValue: language) != nil, (1...4).contains(threads),
              threshold.isFinite, threshold > 0, threshold < 1,
              minimumSpeechSeconds.isFinite, (0.1...1).contains(minimumSpeechSeconds),
              minimumSilenceSeconds.isFinite, (0.1...2).contains(minimumSilenceSeconds),
              (0...4_800).contains(paddingFrames), (16_000...320_000).contains(maximumCoreFrames) else {
            throw SpeechError.invalidConfiguration
        }
    }
    func withLanguage(_ language: SpeechLanguage) throws -> Self {
        try Self(language: language.rawValue, useITN: useITN, threads: threads,
                 threshold: threshold, minimumSpeechSeconds: minimumSpeechSeconds,
                 minimumSilenceSeconds: minimumSilenceSeconds, paddingFrames: paddingFrames,
                 maximumCoreFrames: maximumCoreFrames)
    }

    func withVADThreshold(_ threshold: Float, minimumSilenceSeconds: Float? = nil) throws -> Self {
        try Self(language: language, useITN: useITN, threads: threads,
                 threshold: threshold, minimumSpeechSeconds: minimumSpeechSeconds,
                 minimumSilenceSeconds: minimumSilenceSeconds ?? self.minimumSilenceSeconds, paddingFrames: paddingFrames,
                 maximumCoreFrames: maximumCoreFrames)
    }
}

public struct SpeechAudioInput: Sendable {
    public let envelope: ManifestEnvelope
    public let audioURL: URL
    public init(envelope: ManifestEnvelope, audioURL: URL) {
        self.envelope = envelope; self.audioURL = audioURL
    }
}

public struct SpeechCheckpoint: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let epochID: UUID
    public let sourceFrame: Int64
    public let configurationFingerprint: String
    public init(sessionID: UUID, epochID: UUID, sourceFrame: Int64, configurationFingerprint: String) {
        self.sessionID = sessionID; self.epochID = epochID; self.sourceFrame = sourceFrame
        self.configurationFingerprint = configurationFingerprint
    }
}

/// One exact immutable input intersecting a window's context range.
public struct SpeechWindowSource: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let manifestSHA256: String
    public let audioSHA256: String
    public let sourceFrames: FrameRange
    public init(chunkID: UUID, manifestSHA256: String, audioSHA256: String, sourceFrames: FrameRange) {
        self.chunkID = chunkID; self.manifestSHA256 = manifestSHA256
        self.audioSHA256 = audioSHA256; self.sourceFrames = sourceFrames
    }
}

public struct SpeechWindow: Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: UUID
    public let epochID: UUID
    public let analysisAnchor: Int64
    public let coreFrames: FrameRange
    public let contextFrames: FrameRange
    /// Model-rate positions relative to analysisAnchor, before source-frame rounding.
    public let modelCoreFrames: FrameRange
    public let modelContextFrames: FrameRange
    public let sources: [SpeechWindowSource]
    public let replayInputManifestHashes: [String]
    public let configurationFingerprint: String

    public init(id: String, sessionID: UUID, epochID: UUID, analysisAnchor: Int64,
                coreFrames: FrameRange, contextFrames: FrameRange, modelCoreFrames: FrameRange,
                modelContextFrames: FrameRange, sources: [SpeechWindowSource], replayInputManifestHashes: [String],
                configurationFingerprint: String) {
        self.id = id; self.sessionID = sessionID; self.epochID = epochID; self.analysisAnchor = analysisAnchor
        self.coreFrames = coreFrames; self.contextFrames = contextFrames
        self.modelCoreFrames = modelCoreFrames; self.modelContextFrames = modelContextFrames
        self.sources = sources; self.replayInputManifestHashes = replayInputManifestHashes
        self.configurationFingerprint = configurationFingerprint
    }
}

public struct SpeechAnalysisBatch: Sendable {
    public let windows: [SpeechWindow]
    /// Register these ranges, windows and checkpoint in one Archive transaction.
    public let analyzedCoverage: [FrameRange]
    public let noSpeechCoverage: [FrameRange]
    public let checkpoint: SpeechCheckpoint?
    public let waitingForMoreAudio: Bool
}

public enum SpeechRecognitionBackend: String, Sendable {
    case sherpa, sherpaCoreML
}

public struct SpeechRecognition: Codable, Equatable, Sendable {
    public let windowID: String
    public let text: String
    public let tokens: [String]
    public let timestamps: [Float]
    public let rawJSON: String
    public let configurationFingerprint: String
    /// Recognition artifact identity is separate from persisted VAD/window identity.
    public internal(set) var recognitionFingerprint: String? = nil
    public internal(set) var speakers: [SpeakerEvidence]? = nil
    public internal(set) var speakerFailure: String? = nil
    public internal(set) var speakerTurns: [SpeakerTurnTranscript]? = nil
}

public enum SpeechExecutionEvent: Sendable {
    case analysisPageReady(windowCount: Int)
    case nativeDecodeStarted(windowID: String)
    case nativeDecodeReturned(windowID: String)
}

/// Cancellation invalidates queued work immediately; a synchronous native decode may finish first.
public final class SpeechAttempt: @unchecked Sendable {
    typealias CancellationHandler = @Sendable () -> Void
    typealias StepPollHandler = @Sendable (SpeechAttempt) -> Bool
    public let id: UUID
    private let lock = NSLock()
    private var cancelledAt: UInt64?
    private var cancellationHandlers: [UUID: CancellationHandler] = [:]
    private var stepPoll: StepPollHandler?
    public init(id: UUID = UUID()) { self.id = id }
    public func cancel() {
        let handlers: [CancellationHandler] = lock.withLock {
            guard cancelledAt == nil else { return [] }
            cancelledAt = DispatchTime.now().uptimeNanoseconds
            let handlers = Array(cancellationHandlers.values)
            cancellationHandlers.removeAll()
            return handlers
        }
        for handler in handlers { handler() }
    }
    func observeCancellation(_ handler: @escaping CancellationHandler) -> UUID {
        let id = UUID()
        let notify = lock.withLock {
            guard cancelledAt == nil else { return true }
            cancellationHandlers[id] = handler
            return false
        }
        if notify { handler() }
        return id
    }
    func removeCancellationObserver(_ id: UUID) { _ = lock.withLock { cancellationHandlers.removeValue(forKey: id) } }
    func installStepPoll(_ handler: StepPollHandler?) { lock.withLock { stepPoll = handler } }
    func pollCancellationOrPace() -> Bool {
        let (cancelled, poll) = lock.withLock { (cancelledAt != nil, stepPoll) }
        if cancelled { return true }
        return poll?(self) ?? false
    }
    var cancellationUptimeNanoseconds: UInt64? { lock.withLock { cancelledAt } }
    public func checkCancellation() throws {
        if cancellationUptimeNanoseconds != nil { throw SpeechError.cancelled }
    }
}
