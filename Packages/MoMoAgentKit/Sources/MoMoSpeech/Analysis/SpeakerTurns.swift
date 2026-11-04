import Foundation
import MoMoContracts

/// Acoustic turns are independent of punctuation, token spelling and VAD windows.
struct SpeakerTurn: Sendable {
    var frames: Range<Int>
    var audioFrames: Range<Int>
    var evidence: SpeakerEvidence

    init(frames: Range<Int>, audioFrames: Range<Int>? = nil, evidence: SpeakerEvidence) {
        self.frames = frames
        self.audioFrames = audioFrames ?? frames
        self.evidence = evidence
    }

    static func sameVoice(_ a: SpeakerEvidence, _ b: SpeakerEvidence) -> Bool {
        guard a.localSpeaker > 0, b.localSpeaker > 0 else { return false }
        if a.localSpeaker == b.localSpeaker { return true }
        // Track numbers encode 4-slot cannot-link cliques within each segmentation block.
        if (a.localSpeaker - 1) / 4 == (b.localSpeaker - 1) / 4 { return false }
        let minSim: Float = a.embedding.count == 192 ? 0.46 : 0.78
        return a.modelRevision == b.modelRevision && a.hasVoiceprint && b.hasVoiceprint
            && SpeakerEvidence.similarity(a.embedding, b.embedding) >= minSim
    }

    static func mergeEvidence(_ a: SpeakerEvidence, _ b: SpeakerEvidence) -> SpeakerEvidence {
        let best = b.cleanSeconds > a.cleanSeconds ? b : a
        var pooled = best.embedding
        if a.hasVoiceprint, b.hasVoiceprint, a.embedding.count == b.embedding.count {
            let dim = a.embedding.count
            let wa = Float(max(0.25, a.cleanSeconds))
            let wb = Float(max(0.25, b.cleanSeconds))
            var sum = [Float](repeating: 0, count: dim)
            for d in 0..<dim { sum[d] = wa * a.embedding[d] + wb * b.embedding[d] }
            let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
            if norm > 1e-6 { pooled = sum.map { $0 / norm } }
        }
        return SpeakerEvidence(
            start: min(a.start, b.start),
            end: max(a.end, b.end),
            localSpeaker: best.localSpeaker,
            embedding: pooled,
            cleanSeconds: min(10.0, a.cleanSeconds + b.cleanSeconds),
            modelRevision: best.modelRevision)
    }

    static func plan(_ evidence: [SpeakerEvidence], core: Range<Int>,
                     sampleBounds: Range<Int>? = nil) -> [Self] {
        guard !core.isEmpty else { return [] }
        let bounds = sampleBounds ?? core
        let collarSamples = 2_560 // 160 ms acoustic collar for consonant onsets/codas
        let audible = evidence.filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                && $0.start * 16_000 < Double(core.upperBound) && $0.end * 16_000 > Double(core.lowerBound)
        }.sorted { $0.start < $1.start }
        var groups: [(first: SpeakerEvidence, last: SpeakerEvidence, members: [SpeakerEvidence])] = []
        for value in audible {
            if let last = groups.last,
               value.start - last.last.end <= 6.0,
               sameVoice(last.last, value)
                   || (last.members.last(where: \.hasVoiceprint).map { sameVoice($0, value) } ?? false) {
                groups[groups.count - 1].last = value
                groups[groups.count - 1].members.append(value)
            } else { groups.append((value, value, [value])) }
        }
        let minTurnSamples = 800 // 50 ms minimum turn width; absorb sub-50 ms boundary slivers.
        while groups.count > 1 && core.count >= minTurnSamples {
            var testCursor = core.lowerBound
            var sliverIndex: Int?
            for idx in groups.indices {
                let end: Int
                if idx + 1 == groups.count {
                    end = core.upperBound
                } else {
                    let boundary = (groups[idx].last.end + groups[idx + 1].first.start) / 2
                    end = min(core.upperBound, max(testCursor, Int((boundary * 16_000).rounded())))
                }
                if end - testCursor < minTurnSamples {
                    sliverIndex = idx
                    break
                }
                testCursor = end
            }
            guard let dropIdx = sliverIndex else { break }
            groups.remove(at: dropIdx)
        }
        var cursor = core.lowerBound
        return groups.indices.compactMap { index in
            let group = groups[index]
            let end: Int
            if index + 1 == groups.count { end = core.upperBound }
            else {
                let boundary = (group.last.end + groups[index + 1].first.start) / 2
                end = min(core.upperBound, max(cursor, Int((boundary * 16_000).rounded())))
            }
            guard end > cursor else { return nil }
            let start = cursor
            defer { cursor = end }
            let leftFloor = index == 0
                ? bounds.lowerBound
                : max(bounds.lowerBound, Int((groups[index - 1].last.end * 16_000).rounded(.up)))
            let rightCeil = index + 1 == groups.count
                ? bounds.upperBound
                : min(bounds.upperBound, Int((groups[index + 1].first.start * 16_000).rounded(.down)))
            let audioStart = min(start, max(leftFloor, start - collarSamples))
            let audioEnd = max(end, min(rightCeil, end + collarSamples))
            let startSec = Double(start) / 16_000
            let endSec = Double(end) / 16_000
            let best = group.members.max(by: { $0.cleanSeconds < $1.cleanSeconds }) ?? group.first
            var pooledEmbedding = best.embedding
            let voicedMembers = group.members.filter(\.hasVoiceprint)
            if let dim = voicedMembers.first?.embedding.count,
               voicedMembers.count > 1,
               voicedMembers.allSatisfy({ $0.embedding.count == dim }) {
                var sum = [Float](repeating: 0, count: dim)
                for member in voicedMembers {
                    let w = Float(max(0.25, member.cleanSeconds))
                    for d in 0..<dim { sum[d] += w * member.embedding[d] }
                }
                let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
                if norm > 1e-6 { pooledEmbedding = sum.map { $0 / norm } }
            }
            let totalClean = group.members.reduce(0.0) { acc, member in
                guard member.cleanSeconds > 0 else { return acc }
                let overlap = max(0, min(member.end, endSec) - max(member.start, startSec))
                return acc + min(member.cleanSeconds, overlap)
            }
            return Self(frames: start..<end, audioFrames: audioStart..<audioEnd,
                evidence: SpeakerEvidence(start: group.first.start, end: group.last.end,
                    localSpeaker: best.localSpeaker, embedding: pooledEmbedding,
                    cleanSeconds: min(10.0, totalClean), modelRevision: best.modelRevision))
        }
    }

    /// Consolidates sub-second unverified micro-turns into compatible adjacent turns before
    /// per-turn ASR decoding (e.g. timestamp-free FunASR-Nano), avoiding redundant LLM passes
    /// on Watch noise/backchannels while keeping real enrolled or multi-second speakers separate.
    static func consolidateForTurnDecoding(
        _ turns: [Self],
        enrolledPrototypes: [EnrolledSpeakerPrototype] = []
    ) -> [Self] {
        guard turns.count > 1 else { return turns }
        func matchedEnrolledPerson(_ ev: SpeakerEvidence) -> UUID? {
            guard ev.hasVoiceprint, !enrolledPrototypes.isEmpty else { return nil }
            let minScore: Float = ev.embedding.count == 192 ? 0.60 : 0.76
            let minMargin: Float = ev.embedding.count == 192 ? 0.07 : 0.045
            var bestScoreByPerson: [UUID: Float] = [:]
            for proto in enrolledPrototypes where proto.modelRevision == ev.modelRevision
                && proto.embedding.count == ev.embedding.count {
                let s = SpeakerEvidence.similarity(ev.embedding, proto.embedding)
                if s > (bestScoreByPerson[proto.personID] ?? -2) {
                    bestScoreByPerson[proto.personID] = s
                }
            }
            let ranked = bestScoreByPerson.sorted { $0.value > $1.value }
            guard let top = ranked.first, top.value >= minScore else { return nil }
            if ranked.count >= 2, top.value - ranked[1].value < minMargin { return nil }
            return top.key
        }

        var current = turns
        while current.count > 1 {
            var mergedAny = false
            for idx in current.indices {
                let micro = current[idx]
                guard micro.frames.count < 14_400, micro.evidence.cleanSeconds < 0.60 else { continue }
                let microPerson = matchedEnrolledPerson(micro.evidence)
                var bestTarget: Int?
                var bestScore: Float = -2
                for candIdx in [idx - 1, idx + 1] where current.indices.contains(candIdx) {
                    let neighbor = current[candIdx]
                    let neighborPerson = matchedEnrolledPerson(neighbor.evidence)
                    if let mp = microPerson, let np = neighborPerson, mp != np { continue }
                    if microPerson != nil, neighborPerson == nil { continue }
                    let score: Float
                    if sameVoice(micro.evidence, neighbor.evidence) {
                        score = 2.0
                    } else if !micro.evidence.hasVoiceprint || !neighbor.evidence.hasVoiceprint {
                        score = Float(neighbor.frames.count) / 160_000
                    } else {
                        let sim = SpeakerEvidence.similarity(micro.evidence.embedding, neighbor.evidence.embedding)
                        let minSim: Float = micro.evidence.embedding.count == 192 ? 0.32 : 0.58
                        guard sim >= minSim else { continue }
                        score = sim
                    }
                    if score > bestScore {
                        bestScore = score
                        bestTarget = candIdx
                    }
                }
                guard let targetIdx = bestTarget else { continue }
                let lo = min(idx, targetIdx)
                let hi = max(idx, targetIdx)
                let dominant = current[targetIdx]
                let combinedFrames = current[lo].frames.lowerBound..<current[hi].frames.upperBound
                let combinedAudio = min(current[lo].audioFrames.lowerBound, current[hi].audioFrames.lowerBound)
                    ..< max(current[lo].audioFrames.upperBound, current[hi].audioFrames.upperBound)
                let combinedEvidence: SpeakerEvidence
                if sameVoice(micro.evidence, dominant.evidence) {
                    combinedEvidence = mergeEvidence(current[lo].evidence, current[hi].evidence)
                } else {
                    combinedEvidence = SpeakerEvidence(
                        start: min(current[lo].evidence.start, current[hi].evidence.start),
                        end: max(current[lo].evidence.end, current[hi].evidence.end),
                        localSpeaker: dominant.evidence.localSpeaker,
                        embedding: dominant.evidence.embedding,
                        cleanSeconds: dominant.evidence.cleanSeconds,
                        modelRevision: dominant.evidence.modelRevision)
                }
                current[lo] = Self(frames: combinedFrames, audioFrames: combinedAudio, evidence: combinedEvidence)
                current.remove(at: hi)
                mergedAny = true
                break
            }
            if !mergedAny { break }
        }
        return current
    }
}

public struct SpeakerTurnTranscript: Codable, Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let evidence: SpeakerEvidence
}

extension SpeechRecognition {
    fileprivate static func isWordToken(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }

    fileprivate static func isSentenceEndingToken(_ token: String) -> Bool {
        token.contains { "。！？!?；;".contains($0) }
    }

    fileprivate static func isClauseEndingToken(_ token: String) -> Bool {
        token.contains { "，、：,:".contains($0) }
    }

    /// Use genuine word times first: short interjections need the full decode's language context.
    func alignedSpeakerTurns(_ turns: [SpeakerTurn]) -> [SpeakerTurnTranscript]? {
        guard !turns.isEmpty, !tokens.isEmpty, tokens.count == timestamps.count,
              timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        var cursor = text.startIndex
        var starts: [String.Index] = []
        for token in tokens {
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            let spelling = token.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            guard !spelling.isEmpty, let range = text.range(of: spelling, options: [.anchored, .caseInsensitive],
                range: cursor..<text.endIndex) else { return nil }
            starts.append(range.lowerBound)
            cursor = range.upperBound
        }
        guard text[cursor...].allSatisfy(\.isWhitespace) else { return nil }
        var ownership: [Int?] = []
        for index in timestamps.indices {
            if !Self.isWordToken(tokens[index]) {
                ownership.append(ownership.last.flatMap { $0 })
                continue
            }
            let onset = Double(timestamps[index])
            guard onset * 16_000 >= Double(turns[0].frames.lowerBound),
                  onset * 16_000 < Double(turns[turns.count - 1].frames.upperBound) else {
                ownership.append(nil); continue
            }
            // sherpa exposes CTC onsets, not word ends. Bound the next-onset interval
            // to 200 ms so a following silence cannot move a word to another turn.
            let width = index + 1 < timestamps.count ? min(0.2, Double(timestamps[index + 1]) - onset) : 0
            let frame = min((onset + width / 2) * 16_000, Double(turns[turns.count - 1].frames.upperBound).nextDown)
            let match = turns.indices.first { frame >= Double(turns[$0].frames.lowerBound) && frame < Double(turns[$0].frames.upperBound) }
            // Punctuation belongs to the preceding words, never its own speaker row.
            ownership.append(match)
        }

        // Snap speaker transitions to adjacent sentence/clause punctuation within acoustic jitter bounds
        // (350 ms for sentence endings, 250 ms for clause commas when both sides have >= 2 words)
        // so acoustic midpoint jitter does not strand a trailing syllable + punctuation across turns.
        if turns.count > 1 {
            for tA in 0..<(turns.count - 1) {
                let tB = tA + 1
                let boundarySec = Double(turns[tA].frames.upperBound) / 16_000
                guard let lastA = ownership.indices.last(where: { ownership[$0] == tA }),
                      let firstB = ownership.indices.first(where: { ownership[$0] == tB }),
                      firstB == lastA + 1 else { continue }
                let wordsInA = ownership.indices.filter { ownership[$0] == tA && Self.isWordToken(tokens[$0]) }
                let wordsInB = ownership.indices.filter { ownership[$0] == tB && Self.isWordToken(tokens[$0]) }
                let distanceLastA = abs(Double(timestamps[lastA]) - boundarySec)
                let distanceFirstB = abs(Double(timestamps[firstB]) - boundarySec)
                if lastA >= 1, ownership[lastA - 1] == tA, Self.isWordToken(tokens[lastA]), wordsInA.count >= 2,
                   (Self.isSentenceEndingToken(tokens[lastA - 1]) && distanceLastA <= 0.35)
                   || (Self.isClauseEndingToken(tokens[lastA - 1]) && wordsInB.count >= 2 && distanceLastA <= 0.25) {
                    ownership[lastA] = tB
                } else if firstB + 2 <= tokens.count, ownership[firstB + 1] == tB,
                          Self.isWordToken(tokens[firstB]), !Self.isWordToken(tokens[firstB + 1]), wordsInB.count >= 2,
                          (Self.isSentenceEndingToken(tokens[firstB + 1]) && distanceFirstB <= 0.35)
                          || (Self.isClauseEndingToken(tokens[firstB + 1]) && wordsInA.count >= 2 && distanceFirstB <= 0.25) {
                    ownership[firstB] = tA
                    ownership[firstB + 1] = tA
                }
            }
        }

        let assigned = ownership.compactMap { $0 }
        guard zip(assigned, assigned.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        if turns.count > 1 {
            for turnIndex in turns.indices {
                let turn = turns[turnIndex]
                let hasWords = ownership.indices.contains { ownership[$0] == turnIndex && Self.isWordToken(tokens[$0]) }
                if !hasWords, turn.evidence.cleanSeconds >= 2.5, turn.frames.count >= 40_000 {
                    // Full-window CTC ASR genuinely dropped a sustained >= 2.5 s clean speech turn
                    // (e.g. extreme near/far-field volume contrast); fall back to per-turn ASR.
                    return nil
                }
            }
        }
        var alignedTurns: [SpeakerTurnTranscript] = []
        var pendingStart = Double(turns[0].frames.lowerBound) / 16_000
        for turnIndex in turns.indices {
            let turn = turns[turnIndex]
            let turnEnd = Double(turn.frames.upperBound) / 16_000
            let indexes = ownership.indices.filter { ownership[$0] == turnIndex }
            if let first = indexes.first, let last = indexes.last {
                let end = last + 1 < starts.count ? starts[last + 1] : text.endIndex
                let pieceText = String(text[starts[first]..<end])
                let pieceStart = alignedTurns.isEmpty ? pendingStart : Double(turn.frames.lowerBound) / 16_000
                if let prev = alignedTurns.last, SpeakerTurn.sameVoice(prev.evidence, turn.evidence) {
                    alignedTurns[alignedTurns.count - 1] = SpeakerTurnTranscript(
                        text: prev.text + pieceText,
                        start: prev.start,
                        end: turnEnd,
                        evidence: SpeakerTurn.mergeEvidence(prev.evidence, turn.evidence))
                } else {
                    alignedTurns.append(SpeakerTurnTranscript(
                        text: pieceText, start: pieceStart, end: turnEnd, evidence: turn.evidence))
                }
                pendingStart = turnEnd
            } else if !alignedTurns.isEmpty {
                let prev = alignedTurns[alignedTurns.count - 1]
                alignedTurns[alignedTurns.count - 1] = SpeakerTurnTranscript(
                    text: prev.text, start: prev.start, end: turnEnd, evidence: prev.evidence)
                pendingStart = turnEnd
            }
        }
        return alignedTurns
    }
}
