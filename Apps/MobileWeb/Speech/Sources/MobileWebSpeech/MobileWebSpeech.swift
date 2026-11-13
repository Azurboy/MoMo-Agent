import Foundation
import MoMoContracts
import MoMoSpeech

private struct Job: Decodable {
    let id: UUID
    let audio: String
    let manifest: Data
}

private struct Segment: Encodable {
    let offset: Double
    let duration: Double
    let text: String
    let recognitionFingerprint: String
    let nativeResult: String
}

private struct ResultLine: Encodable {
    let id: UUID?
    let spans: [Segment]?
    let error: String?
}

/// One local process owns the production Silero + SenseVoice engine for a batch of watch uploads.
@main struct MobileWebSpeech {
    static func main() async throws {
        guard let models = CommandLine.arguments.dropFirst().first, CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: momo-web-speech MODEL_DIRECTORY\n".utf8))
            Foundation.exit(64)
        }
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: URL(fileURLWithPath: models)),
                                      configuration: SpeechConfiguration())
        while let line = readLine() {
            var id: UUID?
            let result: ResultLine
            do {
                let job = try JSONDecoder().decode(Job.self, from: Data(line.utf8))
                id = job.id
                let spans = try await transcribe(job, engine: engine)
                result = ResultLine(id: id, spans: spans, error: nil)
            } catch {
                // Do not log personal source content or file paths.
                result = ResultLine(id: id, spans: nil, error: "Mac 语音引擎无法处理此片段。")
            }
            var data = try JSONEncoder().encode(result)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    private static func transcribe(_ job: Job, engine: SpeechEngine) async throws -> [Segment] {
        let manifestHash = ContentHash.sha256(job.manifest)
        let envelope = try ManifestEnvelope(manifestData: job.manifest, manifestSHA256: manifestHash)
        let manifest = envelope.manifest
        guard job.audio.hasPrefix("/") else { throw SpeechError.missingAudio }
        let audioURL = URL(fileURLWithPath: job.audio)
        guard manifest.chunkID == job.id,
              try ContentHash.sha256(fileAt: audioURL) == manifest.audioSHA256 else {
            throw ContractError.hashMismatch
        }
        let input = SpeechAudioInput(envelope: envelope, audioURL: audioURL)
        var position = manifest.frames.start
        var checkpoint = SpeechCheckpoint(sessionID: manifest.sessionID, epochID: manifest.epochID,
                                          sourceFrame: position, configurationFingerprint: engine.configurationFingerprint)
        var spans = [Segment]()
        let ignoredText = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        while position < manifest.frames.end {
            let batch = try await engine.prepare(inputs: [input], resume: checkpoint, epochClosed: true)
            guard let next = batch.checkpoint, next.sourceFrame > position,
                  next.sourceFrame <= manifest.frames.end, !batch.waitingForMoreAudio else {
                throw SpeechError.incompatibleCheckpoint
            }
            for window in batch.windows {
                let result = try await engine.transcribe(window: window, inputs: [input])
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let offset = Double(window.coreFrames.start - manifest.frames.start) / manifest.timebaseHz
                // Preserve the recognizer's evidence on the Mac even for a window with no readable words.
                spans.append(Segment(offset: offset, duration: Double(window.coreFrames.count) / manifest.timebaseHz,
                                     text: text.rangeOfCharacter(from: ignoredText.inverted) == nil ? "" : text,
                                     recognitionFingerprint: result.recognitionFingerprint ?? result.configurationFingerprint,
                                     nativeResult: result.rawJSON))
            }
            checkpoint = next
            position = next.sourceFrame
        }
        return spans
    }
}
