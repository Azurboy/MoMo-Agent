import Foundation
import MoMoContracts

extension WindowPlanner {
    /// Select detected speech with bounded context for continuous archive recognition.
    func continuousWindows(ranges: [Range<Int64>], input: SpeechInputSet, availableThrough: Int64,
                         tailClosed: Bool, startAt: Int64 = 0,
                         energy: [SpeechEnergyFrame] = [], hasPendingSpeech: Bool = false) throws -> [SpeechWindow] {
        var result: [SpeechWindow] = []
        let end = min(availableThrough, input.modelFrameCount)
        guard end > startAt else { return [] }
        // VAD endpoints are pause candidates, not separate ASR requests. Keep brief
        // pauses inside a shared decoding context, while leaving long gaps out.
        let contextPadding = SpeechConfiguration.archiveContextFrames
        var joined: [Range<Int64>] = []
        for range in ranges {
            if let last = joined.last, range.lowerBound - last.upperBound <= 32_000 {
                joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { joined.append(range) }
        }
        let speech = try FrameRange.union(joined.compactMap { range in
            let lower = max(startAt, range.lowerBound - configuration.paddingFrames)
            let upper = min(end, range.upperBound + configuration.paddingFrames)
            return upper > lower ? try FrameRange(start: lower, count: upper - lower) : nil
        })
        for part in speech {
            var cursor = part.start
            while cursor < part.end {
                let limit = cursor + configuration.maximumCoreFrames
                // A forced native buffer drain is not an utterance end. Hold the
                // provisional tail until a real pause or enough right context arrives.
                if !tailClosed {
                    if part.end >= limit {
                        if limit + contextPadding > end { return result }
                    } else if part.end + 32_000 > end || (part == speech.last && hasPendingSpeech) { return result }
                }
                let cut = part.end >= limit
                    ? pauseCut(after: cursor, through: limit, ranges: ranges, energy: energy)
                    : part.end
                let core = try FrameRange(start: cursor, count: cut - cursor)
                // A checkpoint in silence must not turn a new utterance into a
                // continuation with extra leading audio. Only extend left when
                // the checkpoint actually lies inside detected speech.
                let continuesSpeech = ranges.contains { $0.lowerBound <= startAt && startAt < $0.upperBound }
                let leftLimit = part.start == startAt && continuesSpeech ? 0 : part.start
                let rightLimit = part.end == end ? input.modelFrameCount : part.end
                let left = max(leftLimit, cursor - contextPadding)
                let right = min(rightLimit, cut + contextPadding)
                result.append(try makeWindow(core: core,
                    context: FrameRange(start: left, count: right - left), input: input))
                cursor = cut
            }
        }
        return result
    }

    private func pauseCut(after start: Int64, through limit: Int64,
                          ranges: [Range<Int64>], energy: [SpeechEnergyFrame]) -> Int64 {
        let lower = start + configuration.maximumCoreFrames / 2
        let singlePassLimit = min(limit, start + 256_000)
        // Prefer detected pauses; ignore the one-frame gap introduced by Flush.
        let pauses = zip(ranges, ranges.dropFirst()).compactMap { a, b -> (Int64, Int64)? in
            let gap = b.lowerBound - a.upperBound
            let middle = a.upperBound + gap / 2
            return gap >= 1_920 && middle >= lower && middle <= limit ? (middle, gap) : nil
        }
        // Prefer a complete utterance around 13s within DiariZen's 16s single-pass
        // ceiling when a >=300ms pause exists <=16s; otherwise consider up to 20s.
        let target = start + configuration.maximumCoreFrames * 13 / 20
        let singlePassPauses = pauses.filter { $0.0 <= singlePassLimit && $0.1 >= 4_800 }
        let pausePool = singlePassPauses.isEmpty ? pauses : singlePassPauses
        if let best = pausePool.min(by: {
            if ($0.1 >= 16_000) != ($1.1 >= 16_000) { return $0.1 >= 16_000 }
            let a = abs($0.0 - target), b = abs($1.0 - target)
            return a == b ? $0.0 < $1.0 : a < b
        }) { return best.0 }
        // Uninterrupted speech still needs a bounded window. Use a relative 160 ms
        // energy valley when available; absolute amplitude would reject quiet Watch speech.
        // Prefer a natural breath/syllable valley <= 16.0s (256,000 frames) so DiariZen
        // executes one 16s WavLM pass instead of two overlapping passes.
        let candidates = energy.filter { $0.start >= lower && $0.start + 512 <= limit }
        guard candidates.count >= 5 else { return limit }
        let mean = candidates.reduce(Float(0)) { $0 + $1.rms * $1.rms } / Float(candidates.count)
        guard mean > 0 else { return limit }
        let quietestLower = start + configuration.maximumCoreFrames * 3 / 5
        var bestSinglePass: (frame: Int64, power: Float)?
        var bestFallback: (frame: Int64, power: Float)?
        var quietestSinglePass: (frame: Int64, power: Float)?
        for index in 0...(candidates.count - 5) {
            let slice = candidates[index..<(index + 5)]
            guard slice.last!.start - slice.first!.start == 4 * 512 else { continue }
            let power = slice.reduce(Float(0)) { $0 + $1.rms * $1.rms } / 5
            let cutFrame = candidates[index + 2].start + 256
            if cutFrame <= singlePassLimit {
                if power < mean * 0.14, bestSinglePass == nil || power < bestSinglePass!.power {
                    bestSinglePass = (cutFrame, power)
                }
                if cutFrame >= quietestLower, power < mean * 0.85,
                   quietestSinglePass == nil || power < quietestSinglePass!.power {
                    quietestSinglePass = (cutFrame, power)
                }
            }
            if power < mean * 0.0625, bestFallback == nil || power < bestFallback!.power {
                bestFallback = (cutFrame, power)
            }
        }
        return bestSinglePass?.frame ?? bestFallback?.frame ?? quietestSinglePass?.frame ?? limit
    }
}

struct SpeechEnergyFrame: Sendable {
    let start: Int64
    let rms: Float
}
