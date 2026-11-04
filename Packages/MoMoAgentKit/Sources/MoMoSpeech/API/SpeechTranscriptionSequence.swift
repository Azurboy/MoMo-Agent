import Foundation
import MoMoContracts

/// A bounded, sequential reader over one leased, immutable input snapshot. Close before releasing its inputs.
/// Window attempts and durable commits remain independent. Never reuse after cancellation or input revision.
public final class SpeechTranscriptionSequence: @unchecked Sendable {
    let owner: UUID
    let input: SpeechInputSet
    var cursor: SequentialSpeechSamples?
    var closed = false
    var previousCoreEnd: Int64 = 0

    init(owner: UUID, input: SpeechInputSet) { self.owner = owner; self.input = input }
}

/// Accessed only by the owning SpeechEngine executor. Retains at most one context window and read-ahead.
final class SequentialSpeechSamples {
    private let reader: EpochAudioReader
    private let retainedFrames: Int64
    private var buffer: [Float] = []
    private var readOffset = 0
    private var start: Int64 = 0
    private var end: Int64 = 0
    private var lastStart: Int64 = 0

    init(input: SpeechInputSet, configuration: SpeechConfiguration, attempt: SpeechAttempt,
         recorder: SpeechDiagnosticRecorder? = nil) throws {
        reader = try EpochAudioReader(input: input, attempt: attempt, recorder: recorder)
        retainedFrames = configuration.maximumRecognitionFrames
    }

    private func consume(_ count: Int) {
        guard count > 0 else { return }
        readOffset += count
        start += Int64(count)
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 65_536 && readOffset >= buffer.count / 2 {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
    }

    func samples(for range: FrameRange, sourceContext: FrameRange, attempt: SpeechAttempt,
                 recorder: SpeechDiagnosticRecorder? = nil) throws -> [Float] {
        try attempt.checkCancellation()
        guard range.start >= lastStart, range.start >= start else { throw SpeechError.incompatibleWindow }
        try reader.continueOperation(attempt: attempt, recorder: recorder, context: sourceContext)
        let discarded = min(range.start - start, Int64(buffer.count - readOffset))
        consume(Int(discarded))
        if end < range.start {
            try reader.skipToModelFrameIfNative16kMono(range.start)
            if reader.emitted > end {
                end = reader.emitted
                start = end
            }
        }
        while end < range.end {
            guard let block = try reader.next() else { throw SpeechError.missingAudio }
            let blockStart = end
            end += Int64(block.count)
            let keptStart = max(blockStart, range.start)
            recorder?.value.discardedPrefixModelFrames += max(0, min(end, range.start) - blockStart)
            if keptStart < end { buffer.append(contentsOf: block[Int(keptStart - blockStart)...]) }
            if blockStart < range.start { start = min(end, range.start) }
        }
        guard range.start >= start, range.end <= end,
              Int64(buffer.count - readOffset) == end - start else { throw SpeechError.missingAudio }
        let sliceStart = readOffset + Int(range.start - start)
        let sliceEnd = readOffset + Int(range.end - start)
        let result = Array(buffer[sliceStart..<sliceEnd])
        lastStart = range.start
        let keepFrom = max(start, range.end - retainedFrames)
        consume(Int(keepFrom - start))
        return result
    }
}
