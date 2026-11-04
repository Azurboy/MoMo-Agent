@preconcurrency import AVFoundation
import Foundation
import MoMoContracts

struct SpeechInputSet {
    let inputs: [SpeechAudioInput]
    let sessionID: UUID
    let epochID: UUID
    let sampleRate: Double
    let start: Int64
    let end: Int64
    let modelFrameCount: Int64

    init(_ inputs: [SpeechAudioInput], anchor: Int64, through: Int64? = nil) throws {
        guard let first = inputs.first, anchor >= 0 else { throw SpeechError.missingAudio }
        let format = first.envelope.manifest
        var next = format.frames.start
        for input in inputs {
            let m = input.envelope.manifest
            try m.validate()
            guard input.audioURL.isFileURL, m.sessionID == format.sessionID, m.epochID == format.epochID,
                  m.sampleRate == format.sampleRate, m.timebaseHz == m.sampleRate, m.channels == format.channels,
                  m.representation == .full,
                  m.decodedFrameCount - m.primingFrames - m.paddingFrames == m.frames.count else {
                throw SpeechError.invalidAudio("epoch_format")
            }
            guard m.frames.start == next else { throw SpeechError.inputGap(expected: next, actual: m.frames.start) }
            next = m.frames.end
        }
        if let through {
            guard through > anchor, through <= next else { throw SpeechError.incompatibleCheckpoint }
            next = through
        }
        guard anchor >= format.frames.start, anchor < next else { throw SpeechError.missingAudio }
        let convertedCount = (Double(next - anchor) * 16_000 / format.sampleRate).rounded(.down)
        guard convertedCount >= 0, convertedCount < Double(Int64.max) else {
            throw SpeechError.invalidAudio("epoch_duration")
        }
        self.inputs = inputs; sessionID = format.sessionID; epochID = format.epochID
        sampleRate = format.sampleRate; start = anchor; end = next
        modelFrameCount = Int64(convertedCount)
    }

    func sourceFrame(forModelFrame frame: Int64) -> Int64 {
        let offset = (Double(frame) * sampleRate / 16_000).rounded(.up)
        if offset >= Double(end - start) { return end }
        return start + Int64(offset)
    }

    func sourceRange(_ range: FrameRange) throws -> FrameRange {
        let lower = sourceFrame(forModelFrame: range.start)
        return try FrameRange(start: lower, count: sourceFrame(forModelFrame: range.end) - lower)
    }
}

/// One converter spans physical files. Both uninterrupted and resumed work start a new reader at a committed anchor.
/// The converter invokes its input block synchronously. All access stays on SpeechEngine's serial executor.
final class EpochAudioReader: @unchecked Sendable {
    private(set) var input: SpeechInputSet
    private var attempt: SpeechAttempt
    private var recorder: SpeechDiagnosticRecorder?
    private let isNative16kMono: Bool
    private let converter: AVAudioConverter?
    private let output: AVAudioPCMBuffer
    private var inputBuffer: AVAudioPCMBuffer?
    private var file: AVAudioFile?
    private var index = 0
    private var remainingFileFrames: Int64 = 0
    private var callbackError: (any Error)?
    private(set) var emitted: Int64 = 0
    private var limit: Int64
    private var allowContinuation: Bool
    private(set) var sourcePosition: Int64
    private(set) var converterPoisoned = false

    init(input: SpeechInputSet, attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder? = nil,
         allowContinuation: Bool = false) throws {
        self.input = input; self.attempt = attempt
        self.recorder = recorder
        self.allowContinuation = allowContinuation
        self.sourcePosition = input.start
        let m = input.inputs[0].envelope.manifest
        let native16kMono = m.sampleRate == 16_000 && m.channels == 1
        self.isNative16kMono = native16kMono
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: native16kMono ? 16_384 : 4_096) else {
            throw SpeechError.invalidAudio("converter")
        }
        if native16kMono {
            self.converter = nil
        } else {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: m.sampleRate,
                                             channels: AVAudioChannelCount(m.channels), interleaved: false),
                  let converter = AVAudioConverter(from: format, to: target) else {
                throw SpeechError.invalidAudio("converter")
            }
            converter.primeMethod = .none
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.converter = converter
        }
        self.output = output
        limit = input.modelFrameCount
    }

    func canExtendResampling(to newInput: SpeechInputSet) -> Bool {
        guard !converterPoisoned,
              newInput.sessionID == input.sessionID,
              newInput.epochID == input.epochID,
              newInput.sampleRate == input.sampleRate,
              newInput.start == input.start,
              newInput.end >= sourcePosition,
              newInput.inputs.count >= index else { return false }
        for offset in 0..<index {
            if newInput.inputs[offset].envelope.manifest.frames != input.inputs[offset].envelope.manifest.frames {
                return false
            }
        }
        return true
    }

    func extendResampling(to newInput: SpeechInputSet, allowContinuation: Bool,
                          retainedSourceStart: Int64, attempt: SpeechAttempt,
                          recorder: SpeechDiagnosticRecorder?) throws {
        guard canExtendResampling(to: newInput) else { throw SpeechError.incompatibleCheckpoint }
        self.attempt = attempt
        self.recorder = recorder
        for offset in 0..<index {
            let item = newInput.inputs[offset]
            let frames = item.envelope.manifest.frames
            if (remainingFileFrames > 0 && offset == index - 1)
                || (frames.start < newInput.end && frames.end > retainedSourceStart) {
                try validateIdentity(item)
            }
        }
        if remainingFileFrames > 0, index > 0 {
            let m = newInput.inputs[index - 1].envelope.manifest
            let oldCap = min(m.frames.end, input.end)
            let newCap = min(m.frames.end, newInput.end)
            remainingFileFrames += (newCap - oldCap)
        }
        self.input = newInput
        self.limit = newInput.modelFrameCount
        self.allowContinuation = allowContinuation
    }

    /// A continued file or retained padding is checked again; consumed prefixes are never read again.
    func continueOperation(attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder?, context: FrameRange) throws {
        self.attempt = attempt; self.recorder = recorder
        for (offset, item) in input.inputs.prefix(index).enumerated() where
            (remainingFileFrames > 0 && offset == index - 1)
            || (item.envelope.manifest.frames.start < context.end && item.envelope.manifest.frames.end > context.start) {
            try validateIdentity(item)
        }
    }

    /// Skips completely unread 16 kHz mono chunks (and seeks uncompressed PCM) before `targetModelFrame`
    /// so sequential cursor cache misses never decode or hash silent prefix chunks from the epoch origin.
    func skipToModelFrameIfNative16kMono(_ targetModelFrame: Int64) throws {
        guard isNative16kMono, targetModelFrame > emitted else { return }
        let clampedTarget = min(targetModelFrame, limit)
        guard clampedTarget > emitted else { return }
        let targetSource = input.start + clampedTarget

        if remainingFileFrames > 0, index > 0 {
            let need = clampedTarget - emitted
            if remainingFileFrames <= need {
                let skipped = remainingFileFrames
                remainingFileFrames = 0
                file = nil
                sourcePosition += skipped
                emitted += skipped
            } else if input.inputs[index - 1].envelope.manifest.codec != .aac, let activeFile = file {
                activeFile.framePosition += need
                remainingFileFrames -= need
                sourcePosition += need
                emitted += need
                return
            } else {
                return
            }
        }

        while remainingFileFrames == 0, index < input.inputs.count {
            try attempt.checkCancellation()
            let item = input.inputs[index]
            let m = item.envelope.manifest
            if m.frames.end <= input.start {
                index += 1
                continue
            }
            guard m.frames.start < input.end else { break }
            if m.frames.end <= targetSource {
                let chunkStart = max(m.frames.start, input.start)
                let chunkEnd = min(m.frames.end, input.end)
                let useful = max(0, chunkEnd - chunkStart)
                index += 1
                sourcePosition += useful
                emitted += useful
                continue
            }
            if m.codec != .aac, emitted < clampedTarget {
                guard let activeFile = try advanceFileIfNeeded() else { break }
                let delta = min(remainingFileFrames, clampedTarget - emitted)
                if delta > 0 {
                    activeFile.framePosition += delta
                    remainingFileFrames -= delta
                    sourcePosition += delta
                    emitted += delta
                }
            }
            break
        }
    }

    private func validateIdentity(_ item: SpeechAudioInput) throws {
        try validateSpeechAudioIdentity(item, attempt: attempt, recorder: recorder)
    }

    func next() throws -> [Float]? {
        let start = DispatchTime.now().uptimeNanoseconds
        let hashBefore = recorder?.value.audioHashSeconds ?? 0
        defer {
            let hashSeconds = (recorder?.value.audioHashSeconds ?? 0) - hashBefore
            recorder?.value.audioReadSeconds += max(0, SpeechDiagnosticRecorder.seconds(since: start) - hashSeconds)
        }
        try attempt.checkCancellation()
        guard emitted < limit else { return nil }
        if isNative16kMono {
            return try nextNative16kMono()
        }
        guard let converter else { throw SpeechError.invalidAudio("converter") }
        output.frameLength = 0
        callbackError = nil
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] requested, state in
            do {
                if let buffer = try readSource(maxFrames: requested) { state.pointee = .haveData; return buffer }
                if allowContinuation {
                    state.pointee = .noDataNow
                } else {
                    converterPoisoned = true
                    state.pointee = .endOfStream
                }
                return nil
            } catch {
                callbackError = error
                converterPoisoned = true
                state.pointee = .endOfStream
                return nil
            }
        }
        if let callbackError { throw callbackError }
        if let error { throw SpeechError.audioRead(domain: error.domain, code: error.code) }
        guard status != .error else { throw SpeechError.invalidAudio("conversion_failed") }
        let count = min(Int(output.frameLength), Int(limit - emitted))
        guard count > 0, let samples = output.floatChannelData?[0] else {
            if emitted == limit || (allowContinuation && status == .inputRanDry && remainingFileFrames == 0) {
                return nil
            }
            throw SpeechError.invalidAudio("decoded_frame_count")
        }
        let result = Array(UnsafeBufferPointer(start: samples, count: count))
        guard result.allSatisfy(\.isFinite) else { throw SpeechError.invalidAudio("non_finite_pcm") }
        emitted += Int64(count)
        recorder?.value.convertedModelFrames += Int64(count)
        return result
    }

    private func nextNative16kMono() throws -> [Float]? {
        guard let activeFile = try advanceFileIfNeeded() else {
            if allowContinuation { return nil }
            converterPoisoned = true
            if emitted == limit { return nil }
            throw SpeechError.invalidAudio("decoded_frame_count")
        }
        output.frameLength = 0
        let frameCap = min(Int64(output.frameCapacity), min(remainingFileFrames, limit - emitted))
        do { try activeFile.read(into: output, frameCount: AVAudioFrameCount(frameCap)) }
        catch { let value = error as NSError; throw SpeechError.audioRead(domain: value.domain, code: value.code) }
        let count = Int(output.frameLength)
        guard count > 0, let samples = output.floatChannelData?[0] else {
            throw SpeechError.invalidAudio("truncated_audio")
        }
        remainingFileFrames -= Int64(count)
        sourcePosition += Int64(count)
        recorder?.value.sourceFramesRead += Int64(count)
        let result = Array(UnsafeBufferPointer(start: samples, count: count))
        guard result.allSatisfy(\.isFinite) else { throw SpeechError.invalidAudio("non_finite_pcm") }
        emitted += Int64(count)
        recorder?.value.convertedModelFrames += Int64(count)
        return result
    }

    private func advanceFileIfNeeded() throws -> AVAudioFile? {
        try attempt.checkCancellation()
        while remainingFileFrames == 0 {
            file = nil
            guard index < input.inputs.count else { return nil }
            let item = input.inputs[index]
            let m = item.envelope.manifest
            if m.frames.end <= input.start {
                index += 1
                continue
            }
            guard m.frames.start < input.end else { return nil }
            index += 1
            try validateIdentity(item)
            let opened: AVAudioFile
            do { opened = try AVAudioFile(forReading: item.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false) }
            catch { let value = error as NSError; throw SpeechError.audioRead(domain: value.domain, code: value.code) }
            let encoded = opened.fileFormat.streamDescription.pointee
            let codecMatches: Bool
            switch m.codec {
            case .aac: codecMatches = encoded.mFormatID == kAudioFormatMPEG4AAC
            case .pcmInt16:
                codecMatches = encoded.mFormatID == kAudioFormatLinearPCM && encoded.mBitsPerChannel == 16
                    && encoded.mFormatFlags & kAudioFormatFlagIsFloat == 0
            case .pcmFloat32:
                codecMatches = encoded.mFormatID == kAudioFormatLinearPCM && encoded.mBitsPerChannel == 32
                    && encoded.mFormatFlags & kAudioFormatFlagIsFloat != 0
            }
            guard opened.length == m.decodedFrameCount,
                  codecMatches,
                  opened.processingFormat.sampleRate == m.sampleRate,
                  opened.processingFormat.channelCount == AVAudioChannelCount(m.channels) else {
                throw SpeechError.invalidAudio("decoded_format")
            }
            let skip = max(0, input.start - m.frames.start)
            opened.framePosition = m.primingFrames + skip
            remainingFileFrames = min(m.frames.end, input.end) - m.frames.start - skip
            file = opened
        }
        return file
    }

    private func readSource(maxFrames: AVAudioPacketCount) throws -> AVAudioPCMBuffer? {
        guard let file = try advanceFileIfNeeded() else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: min(maxFrames, 4_096)) else {
            throw SpeechError.invalidAudio("input_buffer")
        }
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remainingFileFrames))) }
        catch { let value = error as NSError; throw SpeechError.audioRead(domain: value.domain, code: value.code) }
        guard buffer.frameLength > 0 else { throw SpeechError.invalidAudio("truncated_audio") }
        remainingFileFrames -= Int64(buffer.frameLength)
        sourcePosition += Int64(buffer.frameLength)
        recorder?.value.sourceFramesRead += Int64(buffer.frameLength)
        inputBuffer = buffer
        return buffer
    }
}

func validateSpeechAudioIdentity(_ item: SpeechAudioInput, attempt: SpeechAttempt,
                                 recorder: SpeechDiagnosticRecorder?) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: item.audioURL.path)
    guard (attributes[.size] as? NSNumber)?.int64Value == item.envelope.manifest.byteCount,
          try speechFileHash(item.audioURL, attempt: attempt, recorder: recorder, model: false) == item.envelope.manifest.audioSHA256 else {
        throw SpeechError.invalidAudio("audio_identity")
    }
}
