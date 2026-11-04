import Foundation
import MoMoContracts

/// Detector state belongs to an audio epoch, not to a scheduling ticket.
final class VADContinuation {
    struct ResamplerState {
        let reader: EpochAudioReader
        var retainedStart: Int64
        var retainedPCM: [Float]
        var retainedHead: Int = 0

        var retainedCount: Int { retainedPCM.count - retainedHead }
        var readerPosition: Int64 { retainedStart + Int64(retainedCount) }

        mutating func trim(to floor: Int64) {
            guard floor > retainedStart else { return }
            let drop = min(retainedCount, Int(floor - retainedStart))
            retainedHead += drop
            retainedStart += Int64(drop)
            if retainedHead == retainedPCM.count {
                retainedPCM.removeAll(keepingCapacity: true)
                retainedHead = 0
            } else if retainedHead >= 16_384 && retainedHead >= retainedPCM.count / 2 {
                retainedPCM.removeFirst(retainedHead)
                retainedHead = 0
            }
        }

        mutating func append(_ samples: [Float], at frame: Int64) {
            if retainedCount == 0 && frame >= retainedStart {
                retainedStart = frame
            }
            guard frame <= readerPosition else { return }
            let skipped = min(samples.count, Int(readerPosition - frame))
            if skipped < samples.count {
                retainedPCM.append(contentsOf: samples[skipped...])
            }
        }

        func samples(from startFrame: Int64, maxCount: Int? = nil) -> [Float] {
            guard startFrame >= retainedStart, startFrame < readerPosition else { return [] }
            let offset = retainedHead + Int(startFrame - retainedStart)
            let available = retainedPCM.count - offset
            let count = maxCount.map { min($0, available) } ?? available
            guard count > 0 else { return [] }
            return Array(retainedPCM[offset..<(offset + count)])
        }
    }

    let sessionID: UUID
    let epochID: UUID
    let threshold: Float
    let origin: Int64
    let rate: Double
    let detector: SherpaVAD
    private(set) var processed: Int64 = 0
    private var pendingStorage: [Float] = []
    private var pendingHead = 0
    private(set) var ranges: [Range<Int64>] = []
    private(set) var replayFloor: Int64 = 0
    private(set) var continuousSpeech: Int64 = 0
    private(set) var quietFrames: Int64 = 0
    private(set) var undrainedSpeechFloor: Int64?
    private(set) var lastFlushWasForced = false
    private(set) var finalized = false
    private(set) var rolloverReplayFrames: Int64 = 0
    private let nativeFrameLimit: Int64
    private let warmupFrames: Int64
    private var recentPCM: AnalysisAudioBuffer?
    private var nativeOrigin: Int64 = 0
    private var nativeRangeFloor: Int64 = 0
    private var vadGainRing: [VADFrameStat] = []
    private var vadGainHead = 0
    private var previousVADGain: Float = 1
    private var heldVADGain: Float = 1
    private var energy: [SpeechEnergyFrame] = []
    private(set) var resampler: ResamplerState?

    init(input: SpeechInputSet, origin: Int64, threshold: Float, detector: SherpaVAD,
         nativeFrameLimit: Int64 = 24 * 3_600 * 16_000, warmupFrames: Int64 = 60 * 16_000) {
        precondition(nativeFrameLimit > warmupFrames && nativeFrameLimit < Int64(Int32.max) - 512
            && nativeFrameLimit % 512 == 0 && warmupFrames > 256_000 && warmupFrames % 512 == 0)
        sessionID = input.sessionID; epochID = input.epochID
        rate = input.sampleRate; self.origin = origin
        self.threshold = threshold; self.detector = detector
        self.nativeFrameLimit = nativeFrameLimit; self.warmupFrames = warmupFrames
        vadGainRing.reserveCapacity(32)
    }

    var pendingCount: Int { pendingStorage.count - pendingHead }
    var received: Int64 { processed + Int64(pendingCount) }

    func offset(_ source: Int64) -> Int64 {
        Int64((Double(source - origin) * 16_000 / rate).rounded(.down))
    }

    func canContinue(_ input: SpeechInputSet, threshold: Float) -> Bool {
        guard input.sampleRate == rate, self.threshold == threshold,
              sessionID == input.sessionID, epochID == input.epochID, !finalized else { return false }
        if rate == 16_000 {
            return offset(input.start) >= replayFloor
                && offset(input.inputs[0].envelope.manifest.frames.start) <= received
                && offset(input.end) >= received
        }
        guard let resampler else { return false }
        let targetStart = offset(input.start)
        guard targetStart >= max(replayFloor, resampler.retainedStart),
              targetStart <= resampler.readerPosition,
              input.inputs[0].envelope.manifest.frames.start <= origin,
              input.end >= resampler.reader.sourcePosition,
              let probe = try? SpeechInputSet(input.inputs, anchor: origin, through: input.end) else {
            return false
        }
        return resampler.reader.canExtendResampling(to: probe)
    }

    func takeResampler() -> ResamplerState? {
        defer { resampler = nil }
        return resampler
    }

    func saveResampler(_ state: ResamplerState?) {
        if var state, !finalized {
            state.trim(to: replayFloor)
            resampler = state.retainedCount <= 960_000 ? state : nil
        } else {
            resampler = nil
        }
    }

    func retain(from frame: Int64) {
        replayFloor = max(replayFloor, frame)
        resampler?.trim(to: replayFloor)
        energy.removeAll { $0.start + 512 <= replayFloor }
        ranges = ranges.compactMap { range in
            let lower = max(range.lowerBound, replayFloor)
            return range.upperBound > lower ? lower..<range.upperBound : nil
        }
    }

    func append(_ samples: [Float], at frame: Int64) throws {
        guard frame <= received else { throw SpeechError.inputGap(expected: received, actual: frame) }
        let skipped = min(samples.count, Int(received - frame))
        if skipped < samples.count {
            pendingStorage.append(contentsOf: samples[skipped...])
        }
    }

    /// Consume only PCM available to this caller. A replay never feeds the detector twice.
    func step(through frame: Int64) throws -> Bool {
        guard pendingCount >= 512, processed + 512 <= frame else { return false }
        // Sherpa uses Int32 positions internally. A day-long detector rolls over with
        // a warm prefix, independently of file, task or checkpoint boundaries.
        if processed - nativeOrigin >= nativeFrameLimit { try rollOverNativeClock() }
        if recentPCM == nil, processed - nativeOrigin >= nativeFrameLimit - warmupFrames {
            recentPCM = AnalysisAudioBuffer(capacity: Int(warmupFrames), start: processed)
        }
        if let normalized = try normalizeForVADSlice(at: origin + processed) {
            try detector.accept(normalized)
            recentPCM?.append(normalized)
        } else {
            try pendingStorage.withUnsafeBufferPointer { fullBuffer in
                let slice = UnsafeBufferPointer(rebasing: fullBuffer[pendingHead..<(pendingHead + 512)])
                try detector.accept(slice, alreadyVerifiedFinite: true)
            }
            if recentPCM != nil {
                recentPCM?.append(Array(pendingStorage[pendingHead..<(pendingHead + 512)]))
            }
        }
        pendingHead += 512
        if pendingHead == pendingStorage.count {
            pendingStorage.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 16_384 && pendingHead >= pendingStorage.count / 2 {
            pendingStorage.removeFirst(pendingHead)
            pendingHead = 0
        }
        processed += 512
        let finished = try detector.drain()
        if !finished.isEmpty {
            appendRanges(finished)
            lastFlushWasForced = false
            if !detector.speechDetected { undrainedSpeechFloor = nil }
        }
        if detector.speechDetected {
            quietFrames = 0
            if undrainedSpeechFloor == nil { undrainedSpeechFloor = max(0, processed - 512 - 32_000) }
            continuousSpeech += 512
            if continuousSpeech >= 256_000 {
                detector.flush(); appendRanges(try detector.drain())
                continuousSpeech = 0; lastFlushWasForced = true; undrainedSpeechFloor = nil
            }
        } else {
            continuousSpeech = 0
            quietFrames += 512
            if quietFrames >= 32_000 {
                lastFlushWasForced = false
                undrainedSpeechFloor = nil
                if ranges.isEmpty && quietFrames >= 64_000 && energy.count >= 512 {
                    energy.removeFirst(energy.count - 128)
                }
            }
        }
        return true
    }

    func finish(padTail: Bool = true) throws {
        if padTail, pendingCount > 0 {
            pendingStorage.append(contentsOf: repeatElement(Float(0), count: 512 - pendingCount))
            _ = try step(through: processed + 512)
        }
        detector.flush()
        appendRanges(try detector.drain())
        undrainedSpeechFloor = nil
        finalized = padTail
        if padTail { resampler = nil }
    }

    func relativeRanges(from frame: Int64, through end: Int64) -> [Range<Int64>] {
        ranges.compactMap {
            let lower = max(frame, $0.lowerBound), upper = min(end, $0.upperBound)
            return upper > lower ? (lower - frame)..<(upper - frame) : nil
        }
    }

    func relativeEnergy(from frame: Int64, through end: Int64) -> [SpeechEnergyFrame] {
        energy.filter { $0.start >= frame && $0.start + 512 <= end }
            .map { SpeechEnergyFrame(start: $0.start - frame, rms: $0.rms) }
    }

    private func appendRanges(_ added: [Range<Int64>]) {
        for local in added {
            let lower = max(replayFloor, nativeRangeFloor, local.lowerBound + nativeOrigin)
            let upper = local.upperBound + nativeOrigin
            guard upper > lower else { continue }
            let range = lower..<upper
            if let previous = ranges.last, range.lowerBound <= previous.upperBound {
                ranges[ranges.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
    }

    private func rollOverNativeClock() throws {
        let wasSpeech = detector.speechDetected
        detector.flush()
        appendRanges(try detector.drain())
        // Native Flush can end one 512-sample frame before the consumed boundary.
        // Preserve that real audio before resetting the native clock mid-utterance.
        if wasSpeech, let tail = ranges.last, processed > tail.upperBound,
           processed - tail.upperBound <= 512 {
            ranges[ranges.count - 1] = tail.lowerBound..<processed
        }
        let start = processed - warmupFrames
        guard let samples = recentPCM?.samples(in: try FrameRange(start: start, count: warmupFrames)) else {
            throw SpeechError.incompatibleCheckpoint
        }
        detector.reset()
        recentPCM = nil
        nativeOrigin = start; nativeRangeFloor = processed
        continuousSpeech = 0
        for offset in stride(from: 0, to: samples.count, by: 512) {
            try detector.accept(Array(samples[offset..<(offset + 512)]))
            _ = try detector.drain()
            continuousSpeech = detector.speechDetected ? continuousSpeech + 512 : 0
            if continuousSpeech >= 256_000 {
                detector.flush(); _ = try detector.drain(); continuousSpeech = 0
            }
        }
        rolloverReplayFrames += warmupFrames
        quietFrames = detector.speechDetected ? 0 : quietFrames
        undrainedSpeechFloor = detector.speechDetected ? max(0, processed - continuousSpeech - 32_000) : nil
        lastFlushWasForced = wasSpeech || detector.speechDetected
    }

    /// Causal 1.024s P98 envelope normalizer for sleeve-attenuated Watch speech.
    /// Normal-volume speech (maxAbs >= 0.25) and low-crest stationary noise stay at gain 1.0
    /// and return `nil` so callers pass the slice zero-copy into Silero VAD without allocating.
    private func normalizeForVADSlice(at globalFrame: Int64) throws -> [Float]? {
        let startIdx = pendingHead
        let endIdx = pendingHead + 512
        var maxAbs: Float = 0
        var sumSq: Double = 0
        for idx in startIdx..<endIdx {
            let sample = pendingStorage[idx]
            guard sample.isFinite else { throw SpeechError.invalidAudio("non_finite_sample") }
            let mag = abs(sample)
            if mag > maxAbs { maxAbs = mag }
            sumSq += Double(sample) * Double(sample)
        }
        let stat: VADFrameStat
        if maxAbs < 0.002 || maxAbs >= 0.25 {
            stat = VADFrameStat(maxAbs: maxAbs, sumSq: sumSq, cachedP90: maxAbs, samples: nil)
        } else {
            stat = VADFrameStat(maxAbs: maxAbs, sumSq: sumSq, cachedP90: nil,
                samples: Array(pendingStorage[startIdx..<endIdx]))
        }
        energy.append(SpeechEnergyFrame(start: processed, rms: Float((sumSq / 512).squareRoot())))
        if vadGainRing.count < 32 {
            vadGainRing.append(stat)
        } else {
            vadGainRing[vadGainHead] = stat
            vadGainHead = (vadGainHead + 1) & 31
        }
        if vadGainRing.count == 1 || globalFrame % 8_192 == 0 {
            var windowMax: Float = 0
            var windowSumSq: Double = 0
            for item in vadGainRing {
                if item.maxAbs > windowMax { windowMax = item.maxAbs }
                windowSumSq += item.sumSq
            }
            let windowRMS = (windowSumSq / Double(vadGainRing.count * 512)).squareRoot()
            if windowRMS >= 0.0012 && windowMax < 0.25 && Double(windowMax) >= 2.5 * windowRMS {
                var p90s = [Float]()
                p90s.reserveCapacity(vadGainRing.count)
                for index in vadGainRing.indices {
                    p90s.append(vadGainRing[index].resolveP90())
                }
                p90s.sort()
                let windowP98 = p90s[max(0, p90s.count - 2)]
                if windowP98 >= 0.002 {
                    heldVADGain = min(45.0, max(1.0, 0.80 / windowP98))
                } else {
                    heldVADGain = 1.0
                }
            } else {
                heldVADGain = 1.0
            }
        }
        let targetGain = heldVADGain
        if targetGain == 1.0 && previousVADGain == 1.0 {
            return nil
        }
        var output = [Float]()
        output.reserveCapacity(512)
        for index in 0..<512 {
            let alpha = Float(index) / 512.0
            let gain = previousVADGain + (targetGain - previousVADGain) * alpha
            output.append(tanh(pendingStorage[startIdx + index] * gain))
        }
        previousVADGain = targetGain
        return output
    }
}

private struct VADFrameStat {
    let maxAbs: Float
    let sumSq: Double
    var cachedP90: Float?
    var samples: [Float]?

    mutating func resolveP90() -> Float {
        if let p90 = cachedP90 { return p90 }
        guard let raw = samples, raw.count == 512 else { return maxAbs }
        var magnitudes = [Float]()
        magnitudes.reserveCapacity(512)
        for value in raw { magnitudes.append(abs(value)) }
        magnitudes.sort()
        let p90 = magnitudes[460]
        cachedP90 = p90
        samples = nil
        return p90
    }
}
