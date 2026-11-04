import Foundation
import SherpaOnnxC

final class SherpaVAD: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let minimumSilenceFrames: Int64
    private var acceptedFrames: Int64 = 0
    private var flushedThrough: Int64?
    init(model: URL, configuration: SpeechConfiguration) throws {
        minimumSilenceFrames = Int64(configuration.minimumSilenceSeconds * 16_000)
        let result = model.path.withCString { path in "cpu".withCString { provider in
            var config = SherpaOnnxVadModelConfig()
            config.sample_rate = 16_000; config.num_threads = 1; config.provider = provider
            config.silero_vad.model = path
            config.silero_vad.threshold = configuration.threshold
            config.silero_vad.min_speech_duration = configuration.minimumSpeechSeconds
            config.silero_vad.min_silence_duration = configuration.minimumSilenceSeconds
            config.silero_vad.window_size = 512
            // v1.13.8 changes thresholds after this duration; we instead flush storage every 16s without resetting model state.
            config.silero_vad.max_speech_duration = 3_600
            return SherpaOnnxCreateVoiceActivityDetector(&config, 30)
        }}
        guard let result else { throw SpeechError.nativeInitialization }
        pointer = result
    }
    deinit { SherpaOnnxDestroyVoiceActivityDetector(pointer) }
    func reset() {
        SherpaOnnxVoiceActivityDetectorReset(pointer)
        acceptedFrames = 0; flushedThrough = nil
    }
    var speechDetected: Bool { SherpaOnnxVoiceActivityDetectorDetected(pointer) != 0 }
    func accept(_ samples: UnsafeBufferPointer<Float>, alreadyVerifiedFinite: Bool = false) throws {
        precondition(samples.count == 512)
        if !alreadyVerifiedFinite {
            guard samples.allSatisfy(\.isFinite) else { throw SpeechError.invalidAudio("non_finite_sample") }
        }
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(pointer, samples.baseAddress, 512)
        acceptedFrames += 512
    }
    func accept(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try accept($0) }
    }
    func flush() {
        if speechDetected { flushedThrough = acceptedFrames }
        SherpaOnnxVoiceActivityDetectorFlush(pointer)
    }
    func drain() throws -> [Range<Int64>] {
        var ranges: [Range<Int64>] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(pointer) == 0 {
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(pointer) else { throw SpeechError.nativeResult }
            let start = Int64(segment.pointee.start), count = Int64(segment.pointee.n)
            SherpaOnnxDestroySpeechSegment(segment)
            SherpaOnnxVoiceActivityDetectorPop(pointer)
            // v1.13.8 Flush retains Silero's pending silence. Its next end can precede the
            // flushed boundary, yielding an empty duplicate; the original speech is already emitted.
            // Native Flush may stop one frame before the accepted sample clock.
            if count == 0, let flushedThrough, (start == flushedThrough || start == flushedThrough - 512),
               acceptedFrames > flushedThrough, acceptedFrames - flushedThrough < minimumSilenceFrames + 512 { continue }
            guard start >= 0, count > 0 else { throw SpeechError.nativeResult }
            ranges.append(start..<(start + count))
        }
        return ranges
    }
}
