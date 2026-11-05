import Foundation
import os
import MoMoSpeech

/// Bounded, local timing evidence. Contains no transcript, audio, URLs or credentials.
final class PhoneSpeechPerformance: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MoMoAgent.speech.performance", qos: .utility)
    private let url: URL
    private let logger = Logger(subsystem: "com.momoagent.ios", category: "SpeechPerformance")
    private var document: Document
    private var lastWrite: TimeInterval = -.infinity

    init(url: URL, backend: SpeechRecognitionBackend) {
        self.url = url
        document = Document(backend: backend.rawValue)
    }

    func record(_ diagnostic: SpeechDiagnostics) {
        queue.async { [self] in
            document.operationCount += 1
            document.nativeSeconds += diagnostic.nativeDecodeSeconds
            document.speakerSeconds += diagnostic.speakerAnalyzeSeconds
            if diagnostic.outcome == .completed { document.completedCoreFrames += diagnostic.coreModelFrames }
            document.recent.append(diagnostic)
            if document.recent.count > 16 { document.recent.removeFirst(document.recent.count - 16) }
            persist(force: diagnostic.outcome == .failed
                || diagnostic.operation == .warmUp
                || diagnostic.operation == .dictate
                || diagnostic.operation == .transcribe)
        }
    }

    func record(_ snapshot: TranscriptionSnapshot, foreground: Bool) {
        queue.async { [self] in
            let changed = document.phase != snapshot.phase.rawValue
            document.phase = snapshot.phase.rawValue
            document.foreground = foreground
            document.historicalConstraint = snapshot.historicalResourceConstraint
            document.nativeInFlight = snapshot.nativeInFlight
            document.completedWindows = snapshot.completedWindows
            document.failureCode = snapshot.failureCode
            persist(force: changed && !snapshot.nativeInFlight)
        }
    }

    private func persist(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastWrite >= 10 else { return }
        lastWrite = now
        document.updatedAt = Date()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            let native = error as NSError
            logger.error("Timing evidence write failed: \(native.domain, privacy: .public) / \(native.code)")
        }
    }

    private struct Document: Encodable {
        let startedAt = Date()
        let backend: String
        var updatedAt = Date()
        var phase: String?
        var foreground = false
        var nativeInFlight = false
        var historicalConstraint: TranscriptionResourceConstraint?
        var completedWindows = 0
        var operationCount = 0
        var completedCoreFrames: Int64 = 0
        var nativeSeconds: Double = 0
        var speakerSeconds: Double = 0
        var failureCode: String?
        var recent: [SpeechDiagnostics] = []
    }
}
