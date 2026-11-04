import Foundation
import MoMoContracts

public struct SpeakerAttribution: Codable, Equatable, Sendable {
    public let clusterID: UUID
    public let personID: UUID?
    public let isUser: Bool
    public let confirmed: Bool
    public let canLearn: Bool

    public init(clusterID: UUID, personID: UUID?, isUser: Bool, confirmed: Bool, canLearn: Bool) {
        self.clusterID = clusterID
        self.personID = personID
        self.isUser = isUser
        self.confirmed = confirmed
        self.canLearn = canLearn
    }
}

public struct FullSpeakerRematchPlan: Sendable {
    public let sessionIDs: [UUID]
    public let totalObservationCount: Int
}

public struct SpeakerProfile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isUser: Bool
    public let sampleCount: Int
    public let correctionCount: Int

    public init(id: UUID, name: String, isUser: Bool, sampleCount: Int = 0, correctionCount: Int = 0) {
        self.id = id
        self.name = name
        self.isUser = isUser
        self.sampleCount = sampleCount
        self.correctionCount = correctionCount
    }
}

public struct VoiceprintSeedCandidate: Sendable {
    public let anchorID: UUID
    public let personID: UUID
    public let sessionID: UUID
    public let epochID: UUID
    public let frames: FrameRange
    public let batchKey: String
    public let batchSize: Int
    public let inputs: [ArchivedAudioInput]
    let leaseIDs: [UUID]
}

public enum SpeakerFeedback: Sendable { case owner, notOwner, person(String), knownPerson(UUID), notPerson(UUID), clear }
public enum SpeakerFeedbackScope: Sendable { case selection, cluster }
public enum VoiceprintError: Error, LocalizedError {
    case insufficientSpeech, invalidName, missingPerson, duplicateName
    public var errorDescription: String? {
        switch self {
        case .insufficientSpeech: String(localized: "请选一段至少 0.8 秒、没有重叠说话的片段来校正声纹。")
        case .invalidName: String(localized: "请输入 1 至 80 个字符的姓名。")
        case .missingPerson: String(localized: "这个人物已被删除，请重新选择。")
        case .duplicateName: String(localized: "已有同名人物，请选择已有的人物。")
        }
    }
}

enum VoiceprintPolicy {
    static let minLearnableCleanSeconds: Double = 0.8
    static let minEres2NetCleanSeconds: Double = 0.42
    static let minNegativeCleanSeconds: Double = 1.2
    static let maxCleanSeconds: Double = 30.0
    static let legacyWeSpeakerRevision = "32fc906500b8e828c4602fd4e5caf8e38ed20e7ee7ab1b5e3719a6a4d6d4ec88"

    static func isValidDim(_ count: Int) -> Bool {
        count == 192 || count == 256
    }

    static func minLearnableSeconds(forDim dim: Int) -> Double {
        dim == 192 ? minEres2NetCleanSeconds : minLearnableCleanSeconds
    }

    static func effectiveCleanSeconds(_ evidence: SpeakerEvidence, positive: Bool = false) -> Double {
        guard evidence.cleanSeconds.isFinite, evidence.cleanSeconds >= 0 else { return 0 }
        if evidence.cleanSeconds > 0 { return evidence.cleanSeconds }
        if positive, evidence.embedding.count == 192, evidence.hasVoiceprint {
            let dur = evidence.end - evidence.start
            if dur.isFinite, dur >= 0.45 {
                return min(0.65, dur * 0.65)
            }
        }
        return 0
    }

    static func isLearnable(_ evidence: SpeakerEvidence, positive: Bool = false) -> Bool {
        guard evidence.hasVoiceprint else { return false }
        let clean = effectiveCleanSeconds(evidence, positive: positive)
        return clean >= minLearnableSeconds(forDim: evidence.embedding.count) && clean <= maxCleanSeconds
    }

    static func weight(for cleanSeconds: Double) -> Float {
        Float(min(1.0, max(0.30, cleanSeconds / 3.0)))
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard isValidDim(vector.count), vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 1e-6 else { return nil }
        return vector.map { $0 / norm }
    }
}

struct VoiceprintCone: Sendable {
    let mean: [Float]
    let strength: Float

    func center(_ vector: [Float]) -> [Float]? {
        let dim = mean.count
        guard VoiceprintPolicy.isValidDim(dim), vector.count == dim else { return nil }
        guard strength > 0 else { return VoiceprintPolicy.normalized(vector) }
        var shifted = Array(repeating: Float(0), count: dim)
        for d in 0..<dim { shifted[d] = vector[d] - strength * mean[d] }
        return VoiceprintPolicy.normalized(shifted)
    }
}

struct VoiceprintExample {
    let person: UUID
    let embedding: [Float]
    let positive: Bool
    let cleanSeconds: Double
    let spanDuration: Double
    let batchKey: String

    init(person: UUID, embedding: [Float], positive: Bool, cleanSeconds: Double = 4.0,
         spanDuration: Double? = nil, batchKey: String = "") {
        self.person = person
        self.embedding = embedding
        self.positive = positive
        self.cleanSeconds = cleanSeconds
        self.spanDuration = spanDuration ?? cleanSeconds
        self.batchKey = batchKey
    }

    var weight: Float { VoiceprintPolicy.weight(for: cleanSeconds) }
}

enum VoiceprintMatcher {
    /// Caps voting weight per confirmation batch so a single bulk cluster confirmation of
    /// 20+ mixed turns cannot outvote multiple careful per-turn confirmations.
    private static func batchBalancedWeights(for items: [VoiceprintExample]) -> [Float] {
        guard !items.isEmpty else { return [] }
        var indicesByBatch: [String: [Int]] = [:]
        for idx in items.indices where !items[idx].batchKey.isEmpty {
            indicesByBatch[items[idx].batchKey, default: []].append(idx)
        }
        var weights = items.map(\.weight)
        for (_, group) in indicesByBatch where group.count >= 4 {
            let total = group.reduce(Float(0)) { $0 + weights[$1] }
            guard total > 1.5 else { continue }
            let scale = 1.5 / total
            for idx in group { weights[idx] *= scale }
        }
        return weights
    }

    private static func nonMarathonPositives(_ positives: [VoiceprintExample]) -> [VoiceprintExample] {
        guard let dim = positives.first(where: { VoiceprintPolicy.isValidDim($0.embedding.count) })?.embedding.count else { return [] }
        let valid = positives.filter { $0.embedding.count == dim }
        let concise = valid.filter { $0.spanDuration <= 9.5 }
        return concise.isEmpty ? valid : concise
    }

    /// Detects a shared reverberant/channel embedding cone across >= 3 enrolled speaker profiles.
    static func bankCone(from examples: [VoiceprintExample]) -> VoiceprintCone? {
        guard let dim = examples.first(where: { $0.positive && VoiceprintPolicy.isValidDim($0.embedding.count) })?.embedding.count else {
            return nil
        }
        let grouped = Dictionary(grouping: examples.filter { $0.positive && $0.embedding.count == dim }, by: \.person)
        guard grouped.count >= 3 else { return nil }
        var personMeans: [[Float]] = []
        personMeans.reserveCapacity(grouped.count)
        for (_, rawPos) in grouped {
            let concise = nonMarathonPositives(rawPos)
            let voteWeights = batchBalancedWeights(for: concise)
            var sum = Array(repeating: Float(0), count: dim)
            for idx in concise.indices {
                let w = voteWeights[idx]
                for d in 0..<dim { sum[d] += w * concise[idx].embedding[d] }
            }
            if let mean = VoiceprintPolicy.normalized(sum) {
                personMeans.append(mean)
            }
        }
        guard personMeans.count >= 3 else { return nil }
        var minPairwise: Float = 1.0
        for i in 0..<personMeans.count {
            for j in (i + 1)..<personMeans.count {
                minPairwise = min(minPairwise, SpeakerEvidence.similarity(personMeans[i], personMeans[j]))
            }
        }
        guard minPairwise >= 0.35 else { return nil }
        var mean = Array(repeating: Float(0), count: dim)
        let invCount = 1.0 / Float(personMeans.count)
        for pm in personMeans {
            for d in 0..<dim { mean[d] += pm[d] * invCount }
        }
        let coneNorm = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
        guard coneNorm >= 0.76 else { return nil }
        let strength = min(0.90, (coneNorm - 0.72) / 0.20 * 0.90)
        return VoiceprintCone(mean: mean, strength: strength)
    }

    /// Computes a robust consensus core per person so a mislabeled or multi-speaker mixed span
    /// cannot hijack a person's prototype or pull another speaker's turns onto the wrong person.
    private static func consensusCentroid(for positives: [VoiceprintExample], cone: VoiceprintCone? = nil) -> [Float]? {
        let valid = nonMarathonPositives(positives)
        guard let dim = valid.first?.embedding.count else { return nil }
        let projected: [[Float]] = valid.compactMap { item in
            if let cone { return cone.center(item.embedding) }
            return VoiceprintPolicy.normalized(item.embedding)
        }
        guard projected.count == valid.count else { return nil }
        let voteWeights = batchBalancedWeights(for: valid)
        if valid.count <= 2 {
            var sum = Array(repeating: Float(0), count: dim)
            for i in valid.indices {
                let w = voteWeights[i]
                for d in 0..<dim { sum[d] += w * projected[i][d] }
            }
            return VoiceprintPolicy.normalized(sum)
        }
        // Spherical medoid: pick the exemplar with highest batch-balanced agreement with peers.
        var medoidIdx = 0
        var bestAgreement: Float = -2
        for i in valid.indices {
            var num: Float = 0, den: Float = 0
            for j in valid.indices where j != i {
                let w = voteWeights[j]
                num += w * SpeakerEvidence.similarity(projected[i], projected[j])
                den += w
            }
            let score = den > 0 ? num / den : 0
            if score > bestAgreement { bestAgreement = score; medoidIdx = i }
        }
        let medoid = projected[medoidIdx]
        let inlierFloor: Float = cone != nil ? 0.25 : (dim == 192 ? 0.36 : 0.52)
        let inlierIndices = valid.indices.filter { SpeakerEvidence.similarity(projected[$0], medoid) >= inlierFloor }
        let pool = inlierIndices.isEmpty ? Array(valid.indices) : inlierIndices
        var sum = Array(repeating: Float(0), count: dim)
        for idx in pool {
            let w = voteWeights[idx]
            for d in 0..<dim { sum[d] += w * projected[idx][d] }
        }
        return VoiceprintPolicy.normalized(sum) ?? medoid
    }

    /// Filters historical multi-speaker / cross-contaminated positive exemplars whose embedding
    /// aligns with another enrolled person's consensus core or exceeds concise turn duration.
    static func sanitizedExamples(_ examples: [VoiceprintExample]) -> [VoiceprintExample] {
        guard let dim = examples.first(where: { $0.positive && VoiceprintPolicy.isValidDim($0.embedding.count) })?.embedding.count else {
            return examples
        }
        let rawPositives = Dictionary(grouping: examples.filter { $0.positive && $0.embedding.count == dim }, by: \.person)
        guard !rawPositives.isEmpty else { return examples }
        if rawPositives.count == 1 {
            var out: [VoiceprintExample] = []
            for (_, pos) in rawPositives { out.append(contentsOf: nonMarathonPositives(pos)) }
            out.append(contentsOf: examples.filter { !$0.positive && $0.embedding.count == dim })
            return out
        }

        let cone = bankCone(from: examples)
        var cores: [UUID: [Float]] = [:]
        for (person, pos) in rawPositives {
            if let core = consensusCentroid(for: pos, cone: cone) { cores[person] = core }
        }
        var keptPositivesByPerson: [UUID: [VoiceprintExample]] = [:]
        let chimeraFloor: Float = dim == 192 ? 0.48 : 0.70
        for (person, rawPos) in rawPositives {
            let pos = nonMarathonPositives(rawPos)
            guard pos.count >= 2 else {
                keptPositivesByPerson[person] = pos
                continue
            }
            let voteWeights = batchBalancedWeights(for: pos)
            var filtered: [VoiceprintExample] = []
            var bestFallback = pos[0]
            var bestFallbackMargin: Float = -.infinity
            if let cone, let selfCore = cores[person] {
                for item in pos {
                    guard let cVec = cone.center(item.embedding) else { continue }
                    let selfSim = SpeakerEvidence.similarity(cVec, selfCore)
                    let otherSim = cores.compactMap { otherPerson, core in
                        otherPerson == person ? nil : SpeakerEvidence.similarity(cVec, core)
                    }.max() ?? -1
                    let margin = selfSim - otherSim
                    if margin > bestFallbackMargin {
                        bestFallbackMargin = margin
                        bestFallback = item
                    }
                    if selfSim >= 0.15 && selfSim >= otherSim + 0.06 {
                        filtered.append(item)
                    }
                }
            } else {
                for idx in pos.indices {
                    let item = pos[idx]
                    var peerNum: Float = 0, peerDen: Float = 0
                    for j in pos.indices where j != idx {
                        let w = voteWeights[j]
                        peerNum += w * SpeakerEvidence.similarity(item.embedding, pos[j].embedding)
                        peerDen += w
                    }
                    let selfSim = peerDen > 0 ? (peerNum / peerDen) : (cores[person].map { SpeakerEvidence.similarity(item.embedding, $0) } ?? 1)
                    let otherSim = cores.compactMap { otherPerson, core in
                        otherPerson == person ? nil : SpeakerEvidence.similarity(item.embedding, core)
                    }.max() ?? -1
                    let margin = selfSim - otherSim
                    if margin > bestFallbackMargin {
                        bestFallbackMargin = margin
                        bestFallback = item
                    }
                    let isCrossPersonChimera = otherSim >= chimeraFloor && otherSim >= selfSim - 0.02
                    if !isCrossPersonChimera {
                        filtered.append(item)
                    }
                }
            }
            keptPositivesByPerson[person] = filtered.isEmpty ? [bestFallback] : filtered
        }
        var out: [VoiceprintExample] = []
        for (_, kept) in keptPositivesByPerson { out.append(contentsOf: kept) }
        out.append(contentsOf: examples.filter { !$0.positive && $0.embedding.count == dim })
        return out
    }

    /// Builds up to 3 L2-normalized sub-center prototypes per speaker (e.g. near-field phone
    /// vs far-field Watch) using weighted spherical k-means while pruning noisy singleton outliers.
    static func subcenters(for positives: [VoiceprintExample]) -> (centers: [[Float]], totalWeight: Float) {
        guard let dim = positives.first(where: { VoiceprintPolicy.isValidDim($0.embedding.count) })?.embedding.count else {
            return ([], 0)
        }
        let valid = positives.filter { $0.embedding.count == dim }
        guard !valid.isEmpty else { return ([], 0) }
        let voteWeights = batchBalancedWeights(for: valid)
        let orderedPairs: [(item: VoiceprintExample, voteW: Float)]
        if valid.count >= 3 {
            let scored = valid.indices.map { idx -> (VoiceprintExample, Float, Float) in
                let item = valid[idx]
                var num: Float = 0, den: Float = 0
                for j in valid.indices where j != idx {
                    let w = voteWeights[j]
                    num += w * SpeakerEvidence.similarity(item.embedding, valid[j].embedding)
                    den += w
                }
                let peerSim = max(0.20, den > 0 ? num / den : 1.0)
                return (item, voteWeights[idx], voteWeights[idx] * (0.45 + 0.55 * peerSim))
            }
            orderedPairs = scored.sorted { a, b in
                if abs(a.2 - b.2) > 0.04 { return a.2 > b.2 }
                return a.0.cleanSeconds > b.0.cleanSeconds
            }.map { ($0.0, $0.1) }
        } else {
            orderedPairs = valid.indices
                .map { (valid[$0], voteWeights[$0]) }
                .sorted { $0.0.cleanSeconds > $1.0.cleanSeconds }
        }
        let ordered = orderedPairs.map(\.item)
        let orderedVoteW = orderedPairs.map(\.voteW)
        let totalWeight = ordered.reduce(Float(0)) { $0 + $1.weight }

        let splitMaxSim: Float = dim == 192 ? 0.58 : 0.82
        var centers: [[Float]] = [ordered[0].embedding]
        for item in ordered.dropFirst() where centers.count < 3 {
            let maxSim = centers.map { SpeakerEvidence.similarity(item.embedding, $0) }.max() ?? 1
            if maxSim < splitMaxSim {
                centers.append(item.embedding)
            }
        }

        if centers.count == 1 && ordered.count == 1 {
            return (centers, totalWeight)
        }

        for _ in 0..<4 {
            var sums = Array(repeating: Array(repeating: Float(0), count: dim), count: centers.count)
            var weights = Array(repeating: Float(0), count: centers.count)
            for idx in ordered.indices {
                let item = ordered[idx]
                var bestIdx = 0
                var bestSim: Float = -2
                for cIdx in centers.indices {
                    let s = SpeakerEvidence.similarity(item.embedding, centers[cIdx])
                    if s > bestSim { bestSim = s; bestIdx = cIdx }
                }
                let w = orderedVoteW[idx]
                weights[bestIdx] += w
                for d in 0..<dim { sums[bestIdx][d] += w * item.embedding[d] }
            }
            var nextCenters: [[Float]] = []
            for cIdx in centers.indices where weights[cIdx] > 0 {
                if let norm = VoiceprintPolicy.normalized(sums[cIdx]) {
                    nextCenters.append(norm)
                }
            }
            if nextCenters.isEmpty { break }
            centers = nextCenters
        }

        if centers.count > 1 {
            var weights = Array(repeating: Float(0), count: centers.count)
            var counts = Array(repeating: 0, count: centers.count)
            for idx in ordered.indices {
                let item = ordered[idx]
                if let bestIdx = centers.indices.max(by: {
                    SpeakerEvidence.similarity(item.embedding, centers[$0]) < SpeakerEvidence.similarity(item.embedding, centers[$1])
                }) {
                    weights[bestIdx] += orderedVoteW[idx]
                    counts[bestIdx] += 1
                }
            }
            let filtered = centers.indices.compactMap { idx -> [Float]? in
                if idx == 0 { return weights[idx] > 0 ? centers[idx] : nil }
                if ordered.count >= 5 {
                    return (counts[idx] >= 2 || weights[idx] >= 0.85) && weights[idx] >= 0.45 ? centers[idx] : nil
                }
                return weights[idx] >= 0.40 ? centers[idx] : nil
            }
            if !filtered.isEmpty { centers = filtered }
        }
        return (centers, totalWeight)
    }

    static func positiveAffinity(_ vector: [Float], positives: [VoiceprintExample], centers: [[Float]]) -> Float {
        guard let proto = centers.map({ SpeakerEvidence.similarity(vector, $0) }).max() else { return -1 }
        if positives.count <= 1 { return proto }
        let ranked = positives
            .map { (sim: SpeakerEvidence.similarity(vector, $0.embedding), w: $0.weight) }
            .sorted { $0.sim > $1.sim }
            .prefix(3)
        let wSum = ranked.reduce(Float(0)) { $0 + $1.w }
        let topK = wSum > 0 ? ranked.reduce(Float(0)) { $0 + $1.sim * $1.w } / wSum : proto
        return 0.70 * proto + 0.30 * topK
    }

    private static func negativeAffinity(_ vector: [Float], negatives: [VoiceprintExample]) -> Float {
        let sims = negatives.map { SpeakerEvidence.similarity(vector, $0.embedding) }.sorted(by: >)
        guard let first = sims.first else { return -1 }
        if sims.count >= 3 {
            return 0.75 * first + 0.25 * sims[1]
        }
        return first
    }

    struct PreparedPersonModel {
        let person: UUID
        let rawPositives: [VoiceprintExample]
        let rawNegatives: [VoiceprintExample]
        let rawCenters: [[Float]]
        let totalWeight: Float
        let cPositives: [VoiceprintExample]
        let cNegatives: [VoiceprintExample]
        let cCenters: [[Float]]
    }

    struct PreparedBank {
        let dim: Int
        let cone: VoiceprintCone?
        let people: [PreparedPersonModel]
    }

    /// Precompiles sanitized exemplars, shared cone, and spherical k-means sub-centers once per
    /// `(modelRevision, dim)` so matching thousands of spans executes pure dot products in microseconds.
    static func prepare(_ examples: [VoiceprintExample]) -> [Int: PreparedBank] {
        var out: [Int: PreparedBank] = [:]
        for dim in [192, 256] {
            let dimExamples = examples.filter { $0.embedding.count == dim }
            guard !dimExamples.isEmpty else { continue }
            let sanitized = sanitizedExamples(dimExamples)
            let grouped = Dictionary(grouping: sanitized, by: \.person)
            guard !grouped.isEmpty else { continue }
            let cone = bankCone(from: sanitized) ?? bankCone(from: dimExamples)
            var models: [PreparedPersonModel] = []
            models.reserveCapacity(grouped.count)
            for (person, samples) in grouped {
                let rawPos = samples.filter(\.positive)
                guard !rawPos.isEmpty else { continue }
                let (rawCenters, totalWeight) = subcenters(for: rawPos)
                guard !rawCenters.isEmpty else { continue }
                let rawNeg = samples.filter { !$0.positive }
                var cPos: [VoiceprintExample] = []
                var cNeg: [VoiceprintExample] = []
                var cCenters: [[Float]] = []
                if let cone {
                    cPos = rawPos.compactMap { ex in
                        cone.center(ex.embedding).map {
                            VoiceprintExample(person: ex.person, embedding: $0, positive: true,
                                              cleanSeconds: ex.cleanSeconds, spanDuration: ex.spanDuration, batchKey: ex.batchKey)
                        }
                    }
                    cCenters = subcenters(for: cPos).centers
                    cNeg = rawNeg.compactMap { ex in
                        cone.center(ex.embedding).map {
                            VoiceprintExample(person: ex.person, embedding: $0, positive: false,
                                              cleanSeconds: ex.cleanSeconds, spanDuration: ex.spanDuration, batchKey: ex.batchKey)
                        }
                    }
                }
                models.append(PreparedPersonModel(
                    person: person,
                    rawPositives: rawPos,
                    rawNegatives: rawNeg,
                    rawCenters: rawCenters,
                    totalWeight: totalWeight,
                    cPositives: cPos,
                    cNegatives: cNeg,
                    cCenters: cCenters))
            }
            if !models.isEmpty {
                out[dim] = PreparedBank(dim: dim, cone: cone, people: models)
            }
        }
        return out
    }

    static func rawPersonAffinities(_ vector: [Float], prepared: [Int: PreparedBank]) -> [UUID: Float] {
        guard let normVec = VoiceprintPolicy.normalized(vector),
              let bank = prepared[normVec.count] else { return [:] }
        var scores: [UUID: Float] = [:]
        for entry in bank.people {
            scores[entry.person] = positiveAffinity(normVec, positives: entry.rawPositives, centers: entry.rawCenters)
        }
        return scores
    }

    static func match(_ vector: [Float], clusterCentroid: [Float]? = nil,
                      sessionCone: VoiceprintCone? = nil,
                      cleanSeconds: Double = 4.0, examples: [VoiceprintExample]) -> UUID? {
        match(vector, clusterCentroid: clusterCentroid, sessionCone: sessionCone,
              cleanSeconds: cleanSeconds, prepared: prepare(examples))
    }

    static func match(_ vector: [Float], clusterCentroid: [Float]? = nil,
                      sessionCone: VoiceprintCone? = nil,
                      cleanSeconds: Double = 4.0, prepared: [Int: PreparedBank]) -> UUID? {
        let dim = vector.count
        guard VoiceprintPolicy.isValidDim(dim),
              let bank = prepared[dim],
              !bank.people.isEmpty,
              let normVec = VoiceprintPolicy.normalized(vector) else { return nil }
        let validCentroid = clusterCentroid.flatMap { $0.count == dim ? VoiceprintPolicy.normalized($0) : nil }

        if let cone = bank.cone {
            let queryCone = sessionCone ?? cone
            guard let qVec = queryCone.center(normVec) else { return nil }
            let qCluster = validCentroid.flatMap { queryCone.center($0) }
            struct CenteredScore {
                let person: UUID
                let centered: Float
                let raw: Float
                let threshold: Float
                let rejected: Bool
            }
            var scored: [CenteredScore] = []
            scored.reserveCapacity(bank.people.count)
            for entry in bank.people {
                guard !entry.cCenters.isEmpty else { continue }
                let rawSpanPos = positiveAffinity(normVec, positives: entry.rawPositives, centers: entry.rawCenters)
                let rawNeg = negativeAffinity(normVec, negatives: entry.rawNegatives)
                let cSpanPos = positiveAffinity(qVec, positives: entry.cPositives, centers: entry.cCenters)
                let cNeg = negativeAffinity(qVec, negatives: entry.cNegatives)

                var cEffective = cSpanPos
                var rawEffective = rawSpanPos
                if let qCluster, let validCentroid {
                    let cClusterPos = positiveAffinity(qCluster, positives: entry.cPositives, centers: entry.cCenters)
                    let rClusterPos = positiveAffinity(validCentroid, positives: entry.rawPositives, centers: entry.rawCenters)
                    if cSpanPos >= 0.22, cClusterPos >= 0.36 {
                        let alpha = Float(min(0.80, max(0.35, cleanSeconds / 4.0)))
                        cEffective = alpha * cSpanPos + (1.0 - alpha) * cClusterPos
                        rawEffective = alpha * rawSpanPos + (1.0 - alpha) * rClusterPos
                    }
                }
                let minRawFloor: Float = sessionCone != nil ? (dim == 192 ? 0.42 : 0.56) : (dim == 192 ? 0.39 : 0.72)
                let isRejected = (rawSpanPos - rawNeg < 0.04) || (cSpanPos - cNeg < 0.08) || (rawEffective < minRawFloor)
                let cThreshold: Float
                if dim == 192 {
                    cThreshold = entry.totalWeight >= 0.50 ? 0.32 : 0.36
                } else {
                    cThreshold = entry.totalWeight >= 0.50 ? 0.36 : 0.42
                }
                scored.append(CenteredScore(person: entry.person, centered: cEffective, raw: rawEffective,
                                            threshold: cThreshold, rejected: isRejected))
            }
            scored.sort { $0.centered > $1.centered }
            guard let best = scored.first, !best.rejected, best.centered >= best.threshold else { return nil }
            let cMargin: Float = dim == 192 ? 0.08 : 0.10
            if scored.count >= 2 {
                guard best.centered - scored[1].centered >= cMargin else { return nil }
                if sessionCone == nil {
                    let bestRawAmongRest = scored.dropFirst().map(\.raw).max() ?? -1
                    guard best.raw - bestRawAmongRest >= 0.012 else { return nil }
                }
            }
            return best.person
        }

        struct RawScore {
            let person: UUID
            let score: Float
            let threshold: Float
            let rejected: Bool
        }
        var scored: [RawScore] = []
        scored.reserveCapacity(bank.people.count)
        let clusterSpanFloor: Float = dim == 192 ? 0.32 : 0.68
        let clusterCenterFloor: Float = dim == 192 ? 0.40 : 0.78
        for entry in bank.people {
            let spanPos = positiveAffinity(normVec, positives: entry.rawPositives, centers: entry.rawCenters)
            let neg = negativeAffinity(normVec, negatives: entry.rawNegatives)

            var effectivePos = spanPos
            if let center = validCentroid {
                let clusterPos = positiveAffinity(center, positives: entry.rawPositives, centers: entry.rawCenters)
                // Guard against single-link cluster drift: cluster evidence only assists
                // when the span itself is acoustically plausible and the cluster center strongly matches.
                if spanPos >= clusterSpanFloor, clusterPos >= clusterCenterFloor {
                    let alpha = Float(min(0.75, max(0.28, cleanSeconds / 4.0)))
                    effectivePos = alpha * spanPos + (1.0 - alpha) * clusterPos
                }
            }
            let threshold: Float
            if dim == 192 {
                threshold = entry.totalWeight >= 0.50 ? 0.39 : 0.42
            } else {
                threshold = entry.totalWeight >= 0.50 ? 0.75 : 0.78
            }
            scored.append(RawScore(person: entry.person, score: effectivePos, threshold: threshold, rejected: spanPos - neg < 0.05))
        }
        scored.sort { $0.score > $1.score }
        let minMargin: Float = dim == 192 ? 0.055 : 0.05
        guard let best = scored.first, !best.rejected, best.score >= best.threshold,
              scored.count == 1 || best.score - scored[1].score >= minMargin else { return nil }
        return best.person
    }
}

struct VoicePerson: Sendable {
    let id: UUID
    let name: String
    let owner: Bool
}

struct VoiceprintBankCache {
    let dataVersion: Int64
    let rollbackCount: UInt64
    let people: [VoicePerson]
    var baseExamples: [String: [VoiceprintExample]]
    var basePrepared: [String: [Int: VoiceprintMatcher.PreparedBank]]
    var prototypes: [EnrolledSpeakerPrototype]?
    var enrichedExamples: [String: [VoiceprintExample]]?
    var enrichedPrepared: [String: [Int: VoiceprintMatcher.PreparedBank]]?
}

extension ArchiveStore {
    private typealias Person = VoicePerson

    func invalidateVoiceprintCache() {
        voiceprintBankCache = nil
    }

    func invalidateTransductiveVoiceprintCache() {
        voiceprintBankCache?.enrichedExamples = nil
        voiceprintBankCache?.enrichedPrepared = nil
    }

    private func speakerTransaction<T>(_ body: () throws -> T) throws -> T {
        let savedPending = pendingSpeakerRematchSessionIDs
        do {
            return try database.transaction(body)
        } catch {
            pendingSpeakerRematchSessionIDs = savedPending
            invalidateVoiceprintCache()
            throw error
        }
    }

    private func voicePeople() throws -> [Person] {
        try database.rows("SELECT id,name,is_owner FROM voice_profiles ORDER BY id").map {
            Person(id: try $0.requireUUID(0), name: try $0.requireString(1), owner: $0.integer(2) == 1)
        }
    }

    func cachedVoicePeople() throws -> [VoicePerson] {
        try ensureBaseVoiceprintCache().people
    }

    private func ensureBaseVoiceprintCache() throws -> VoiceprintBankCache {
        let currentDataVersion = try database.rows("PRAGMA data_version").first?.integer(0) ?? 0
        if let existing = voiceprintBankCache,
           existing.dataVersion == currentDataVersion,
           existing.rollbackCount == database.rollbackCount {
            return existing
        }
        let people = try voicePeople()
        var baseExamples: [String: [VoiceprintExample]] = [:]
        var basePrepared: [String: [Int: VoiceprintMatcher.PreparedBank]] = [:]
        if !people.isEmpty {
            let revRows = try database.rows("""
                SELECT DISTINCT model_revision FROM speaker_observations WHERE model_revision!='manual-label' AND confirmed_person IS NOT NULL
                UNION
                SELECT DISTINCT o.model_revision FROM voice_rejections r JOIN speaker_observations o ON o.span_id=r.span_id WHERE o.model_revision!='manual-label'
                UNION
                SELECT DISTINCT model_revision FROM voice_profile_seeds
                """)
            for r in revRows {
                let rev = try r.requireString(0)
                guard ContentHash.isValid(rev) else { continue }
                let ex = try voiceExamples(revision: rev, people: people)
                baseExamples[rev] = ex
                basePrepared[rev] = VoiceprintMatcher.prepare(ex)
            }
        }
        let fresh = VoiceprintBankCache(
            dataVersion: currentDataVersion,
            rollbackCount: database.rollbackCount,
            people: people,
            baseExamples: baseExamples,
            basePrepared: basePrepared,
            prototypes: nil,
            enrichedExamples: nil,
            enrichedPrepared: nil)
        voiceprintBankCache = fresh
        return fresh
    }

    private func cachedBasePreparedBank(for revision: String) throws -> [Int: VoiceprintMatcher.PreparedBank] {
        guard ContentHash.isValid(revision) else { return [:] }
        var cache = try ensureBaseVoiceprintCache()
        if let existing = cache.basePrepared[revision] {
            return existing
        }
        guard !cache.people.isEmpty else {
            cache.baseExamples[revision] = []
            cache.basePrepared[revision] = [:]
            voiceprintBankCache = cache
            return [:]
        }
        let ex = try voiceExamples(revision: revision, people: cache.people)
        let prep = VoiceprintMatcher.prepare(ex)
        cache.baseExamples[revision] = ex
        cache.basePrepared[revision] = prep
        voiceprintBankCache = cache
        return prep
    }

    private func ensureEnrichedPreparedBanks() throws -> [String: [Int: VoiceprintMatcher.PreparedBank]] {
        var cache = try ensureBaseVoiceprintCache()
        if let existing = cache.enrichedPrepared {
            return existing
        }
        let enrichedExamples = try harvestTransductiveClusterExamples(
            baseExamples: cache.baseExamples,
            basePrepared: cache.basePrepared)
        var enrichedPrepared: [String: [Int: VoiceprintMatcher.PreparedBank]] = [:]
        for (rev, ex) in enrichedExamples {
            enrichedPrepared[rev] = VoiceprintMatcher.prepare(ex)
        }
        cache.enrichedExamples = enrichedExamples
        cache.enrichedPrepared = enrichedPrepared
        voiceprintBankCache = cache
        return enrichedPrepared
    }

    private func voiceExamples(revision: String, people: [Person]) throws -> [VoiceprintExample] {
        guard !people.isEmpty else { return [] }
        let activePeople = Set(people.map(\.id))
        struct CandidateRow {
            let spanID: String
            let embedding: [Float]
            let cleanSeconds: Double
            let spanDuration: Double
            let updatedAt: Double
            let batchKey: String
        }
        func selectSlices(_ items: [CandidateRow], positive: Bool, personID: UUID, seen: inout Set<String>) -> [VoiceprintExample] {
            guard !items.isEmpty else { return [] }
            let cleanest = items.sorted {
                if $0.cleanSeconds != $1.cleanSeconds { return $0.cleanSeconds > $1.cleanSeconds }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.spanID < $1.spanID
            }.prefix(16)
            let anchors = items.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.spanID < $1.spanID
            }.prefix(8)
            let recent = items.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.spanID < $1.spanID
            }.prefix(64)
            var out: [VoiceprintExample] = []
            for item in Array(cleanest) + Array(anchors) + Array(recent) {
                guard seen.insert(item.spanID).inserted else { continue }
                out.append(VoiceprintExample(
                    person: personID,
                    embedding: item.embedding,
                    positive: positive,
                    cleanSeconds: item.cleanSeconds,
                    spanDuration: item.spanDuration,
                    batchKey: positive ? item.batchKey : ""))
            }
            return out
        }

        // 1. Positive observations via indexed (model_revision, confirmed_person, updated_at) scan.
        var posByPerson: [UUID: [CandidateRow]] = [:]
        let posRows = try database.rows("""
            SELECT o.confirmed_person,o.span_id,o.evidence,o.session_id,o.updated_at
            FROM speaker_observations o
            JOIN sessions s ON s.id=o.session_id
            WHERE o.model_revision=? AND o.confirmed_person IS NOT NULL AND s.deleted=0
            """, [.text(revision)])
        for row in posRows {
            guard let personID = row.string(0).flatMap(UUID.init(uuidString:)),
                  activePeople.contains(personID),
                  let ev = try? WireJSON.decode(SpeakerEvidence?.self, from: row.requireData(2)),
                  VoiceprintPolicy.isValidDim(ev.embedding.count),
                  VoiceprintPolicy.isLearnable(ev, positive: true) else { continue }
            let effClean = VoiceprintPolicy.effectiveCleanSeconds(ev, positive: true)
            let sessStr = row.string(3) ?? ""
            let updatedAt = row.double(4) ?? 0
            let updBucket = Int64((updatedAt / 2.0).rounded(.down))
            let rawSpanDur = max(effClean, ev.end - ev.start)
            posByPerson[personID, default: []].append(CandidateRow(
                spanID: try row.requireString(1),
                embedding: ev.embedding,
                cleanSeconds: effClean,
                spanDuration: rawSpanDur.isFinite ? rawSpanDur : effClean,
                updatedAt: updatedAt,
                batchKey: "\(sessStr):\(updBucket)"))
        }

        // 2. Negative observations starting from voice_rejections PK/index (never scanning all observations).
        var negByPerson: [UUID: [CandidateRow]] = [:]
        let negRows = try database.rows("""
            SELECT r.person_id,o.span_id,o.evidence,o.updated_at
            FROM voice_rejections r
            JOIN speaker_observations o ON o.span_id=r.span_id
            JOIN sessions s ON s.id=o.session_id
            WHERE o.model_revision=? AND s.deleted=0
            """, [.text(revision)])
        for row in negRows {
            guard let personID = row.string(0).flatMap(UUID.init(uuidString:)),
                  activePeople.contains(personID),
                  let ev = try? WireJSON.decode(SpeakerEvidence?.self, from: row.requireData(2)),
                  ev.hasVoiceprint,
                  VoiceprintPolicy.isValidDim(ev.embedding.count),
                  ev.cleanSeconds.isFinite,
                  ev.cleanSeconds >= VoiceprintPolicy.minNegativeCleanSeconds,
                  ev.cleanSeconds <= VoiceprintPolicy.maxCleanSeconds else { continue }
            let rawSpanDur = max(ev.cleanSeconds, ev.end - ev.start)
            negByPerson[personID, default: []].append(CandidateRow(
                spanID: try row.requireString(1),
                embedding: ev.embedding,
                cleanSeconds: ev.cleanSeconds,
                spanDuration: rawSpanDur.isFinite ? rawSpanDur : ev.cleanSeconds,
                updatedAt: row.double(3) ?? 0,
                batchKey: ""))
        }

        // 3. Neural voiceprint seeds via voice_profile_seed_lookup(model_revision, person_id).
        var seedsByPerson: [UUID: [(anchorID: String, vec: [Float], cleanSec: Double, batchKey: String)]] = [:]
        let seedRows = try database.rows("""
            SELECT v.person_id,v.anchor_id,v.embedding,v.clean_seconds,v.batch_key
            FROM voice_profile_seeds v
            JOIN sessions s ON s.id=v.session_id
            WHERE v.model_revision=? AND s.deleted=0
            ORDER BY v.clean_seconds DESC, v.anchor_id ASC
            """, [.text(revision)])
        for row in seedRows {
            guard let personID = row.string(0).flatMap(UUID.init(uuidString:)),
                  activePeople.contains(personID),
                  let rawVec = try? WireJSON.decode([Float].self, from: row.requireData(2)),
                  let normVec = VoiceprintPolicy.normalized(rawVec),
                  let cleanSec = row.double(3), cleanSec.isFinite,
                  cleanSec >= VoiceprintPolicy.minLearnableSeconds(forDim: normVec.count),
                  cleanSec <= VoiceprintPolicy.maxCleanSeconds else { continue }
            if (seedsByPerson[personID]?.count ?? 0) < 32 {
                seedsByPerson[personID, default: []].append((
                    anchorID: try row.requireString(1),
                    vec: normVec,
                    cleanSec: cleanSec,
                    batchKey: row.string(4) ?? ""))
            }
        }

        var examples: [VoiceprintExample] = []
        for person in people {
            var posSeen: Set<String> = []
            examples += selectSlices(posByPerson[person.id] ?? [], positive: true, personID: person.id, seen: &posSeen)
            for seed in seedsByPerson[person.id] ?? [] {
                guard posSeen.insert("seed:" + seed.anchorID).inserted else { continue }
                examples.append(VoiceprintExample(
                    person: person.id,
                    embedding: seed.vec,
                    positive: true,
                    cleanSeconds: seed.cleanSec,
                    spanDuration: seed.cleanSec,
                    batchKey: seed.batchKey))
            }
            var negSeen: Set<String> = []
            examples += selectSlices(negByPerson[person.id] ?? [], positive: false, personID: person.id, seen: &negSeen)
        }
        return examples
    }

    private func sessionSpeakerCone(sessionID: UUID, revision: String) throws -> VoiceprintCone? {
        guard ContentHash.isValid(revision) else { return nil }
        let clusterRows = try database.rows(
            "SELECT centroid FROM speaker_clusters WHERE session_id=? AND model_revision=? AND sample_count>0",
            [.text(sessionID.uuidString), .text(revision)])
        let clusterVecs: [[Float]] = clusterRows.compactMap { row in
            guard let data = try? row.requireData(0),
                  let raw = try? WireJSON.decode([Float].self, from: data) else { return nil }
            return VoiceprintPolicy.normalized(raw)
        }
        guard let dim = clusterVecs.first?.count, clusterVecs.count >= 3,
              clusterVecs.allSatisfy({ $0.count == dim }) else { return nil }
        var minPairwise: Float = 1.0
        var maxPairwise: Float = -1.0
        for i in 0..<clusterVecs.count {
            for j in (i + 1)..<clusterVecs.count {
                let s = SpeakerEvidence.similarity(clusterVecs[i], clusterVecs[j])
                minPairwise = min(minPairwise, s)
                maxPairwise = max(maxPairwise, s)
            }
        }
        // Only activate when >= 3 distinct speakers share a genuine channel/reverb cone
        // (neither synthetic orthogonal vectors nor a fragmented single-speaker monologue).
        guard minPairwise >= 0.35, maxPairwise <= 0.96 else { return nil }

        let obsRows = try database.rows(
            "SELECT evidence FROM speaker_observations WHERE session_id=? AND model_revision=?",
            [.text(sessionID.uuidString), .text(revision)])
        var voiced: [[Float]] = []
        for row in obsRows {
            guard let data = try? row.requireData(0),
                  let ev = try? WireJSON.decode(SpeakerEvidence?.self, from: data),
                  ev.hasVoiceprint, ev.embedding.count == dim,
                  ev.cleanSeconds >= VoiceprintPolicy.minLearnableSeconds(forDim: dim),
                  let v = VoiceprintPolicy.normalized(ev.embedding) else { continue }
            voiced.append(v)
        }
        guard voiced.count >= 6 else { return nil }
        var mean = Array(repeating: Float(0), count: dim)
        let inv = 1.0 / Float(voiced.count)
        for v in voiced {
            for d in 0..<dim { mean[d] += v[d] * inv }
        }
        let coneNorm = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
        guard coneNorm >= 0.76 else { return nil }
        let strength = min(0.90, (coneNorm - 0.72) / 0.20 * 0.90)
        return VoiceprintCone(mean: mean, strength: strength)
    }

    /// Exports L2-normalized multi-prototype voiceprint sub-centers so segmentation can split
    /// mid-window transitions between enrolled speakers even when acoustic pauses are tiny.
    public func enrolledSpeakerPrototypes() throws -> [EnrolledSpeakerPrototype] {
        var cache = try ensureBaseVoiceprintCache()
        if let cached = cache.prototypes {
            return cached
        }
        let people = cache.people
        guard !people.isEmpty else {
            cache.prototypes = []
            voiceprintBankCache = cache
            return []
        }
        var out: [EnrolledSpeakerPrototype] = []
        for revision in cache.baseExamples.keys.sorted() {
            guard ContentHash.isValid(revision),
                  let rawExamples = cache.baseExamples[revision],
                  !rawExamples.isEmpty else { continue }
            let examples = VoiceprintMatcher.sanitizedExamples(rawExamples)
            let byPerson = Dictionary(grouping: examples.filter(\.positive), by: \.person)
            for person in people {
                guard let positives = byPerson[person.id], !positives.isEmpty else { continue }
                let (centers, _) = VoiceprintMatcher.subcenters(for: positives)
                for center in centers {
                    out.append(EnrolledSpeakerPrototype(personID: person.id, embedding: center, modelRevision: revision))
                }
            }
        }
        cache.prototypes = out
        voiceprintBankCache = cache
        return out
    }

    func attributeSpeaker(spanID: UUID, sessionID: UUID, evidence: SpeakerEvidence?, excluding: Set<UUID> = []) throws -> (String?, SpeakerAttribution?) {
        var preparedBanks: [String: [Int: VoiceprintMatcher.PreparedBank]] = [:]
        var sessionCones: [String: VoiceprintCone?] = [:]
        var didShiftCluster = false
        return try attributeSpeaker(
            spanID: spanID,
            sessionID: sessionID,
            evidence: evidence,
            excluding: excluding,
            preloadedPeople: nil,
            preparedBanks: &preparedBanks,
            sessionCones: &sessionCones,
            didShiftCluster: &didShiftCluster)
    }

    func attributeSpeaker(
        spanID: UUID,
        sessionID: UUID,
        evidence: SpeakerEvidence?,
        excluding: Set<UUID> = [],
        preloadedPeople: [VoicePerson]?,
        preparedBanks: inout [String: [Int: VoiceprintMatcher.PreparedBank]],
        sessionCones: inout [String: VoiceprintCone?],
        didShiftCluster: inout Bool
    ) throws -> (String?, SpeakerAttribution?) {
        guard let evidence, evidence.hasVoiceprint, evidence.cleanSeconds.isFinite,
              evidence.cleanSeconds >= 0, evidence.cleanSeconds <= VoiceprintPolicy.maxCleanSeconds,
              ContentHash.isValid(evidence.modelRevision) else { return (nil, nil) }
        let dim = evidence.embedding.count
        let joinMinSim: Float = dim == 192 ? 0.45 : 0.80
        let clusters = try database.rows("SELECT id,centroid,sample_count FROM speaker_clusters WHERE session_id=? AND model_revision=? ORDER BY sample_count>0 DESC,rowid DESC LIMIT 64",
            [.text(sessionID.uuidString), .text(evidence.modelRevision)])
        var candidates: [(UUID, [Float], Int64, Float)] = []
        for row in clusters {
            let id = try row.requireUUID(0)
            guard !excluding.contains(id) else { continue }
            let vector = try WireJSON.decode([Float].self, from: row.requireData(1))
            guard vector.count == dim else { continue }
            let score = SpeakerEvidence.similarity(evidence.embedding, vector)
            if score >= joinMinSim {
                candidates.append((id, vector, row.integer(2) ?? 0, score))
            }
        }
        // Prefer the strongest compatible cluster; never mint duplicate clusters just because two
        // fragments of the same voice exist yet. Reconciler merges compatible fragments cleanly.
        candidates.sort { a, b in
            if abs(a.3 - b.3) < 0.025, (a.2 > 0) != (b.2 > 0) { return a.2 > 0 }
            return a.3 > b.3
        }
        let best = candidates.first
        let cluster = best?.0 ?? UUID()
        var centroid = evidence.embedding
        let count = min(best?.2 ?? 0, 32)
        let canLearn = VoiceprintPolicy.isLearnable(evidence, positive: false)
        if let best, canLearn {
            let addWeight = VoiceprintPolicy.weight(for: evidence.cleanSeconds)
            let priorWeight = max(Float(1), Float(count))
            let blended = zip(best.1, evidence.embedding).map {
                ($0 * priorWeight + $1 * addWeight) / (priorWeight + addWeight)
            }
            centroid = VoiceprintPolicy.normalized(blended) ?? best.1
        } else if let best, !canLearn {
            centroid = best.1
        }
        let updatedSampleCount = count + (canLearn ? 1 : 0)
        if best == nil || !excluding.isEmpty || count < 2
            || updatedSampleCount == 8 || updatedSampleCount == 16 || updatedSampleCount == 32
            || (best != nil && canLearn && SpeakerEvidence.similarity(best!.1, centroid) < 0.9985) {
            didShiftCluster = true
        }
        try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET centroid=excluded.centroid,sample_count=excluded.sample_count",
            [.text(cluster.uuidString), .text(sessionID.uuidString), .text(evidence.modelRevision), .blob(try WireJSON.encode(centroid)), .integer(updatedSampleCount)])
        if updatedSampleCount >= 2 {
            invalidateTransductiveVoiceprintCache()
        }
        for other in excluding { try separateSpeakerClusters(cluster, other) }
        let people = try preloadedPeople ?? cachedVoicePeople()
        let prepared: [Int: VoiceprintMatcher.PreparedBank]
        if let existing = preparedBanks[evidence.modelRevision] {
            prepared = existing
        } else {
            let bank = try cachedBasePreparedBank(for: evidence.modelRevision)
            preparedBanks[evidence.modelRevision] = bank
            prepared = bank
        }
        let sessCone: VoiceprintCone?
        if prepared[dim]?.cone != nil {
            if let cachedCone = sessionCones[evidence.modelRevision] {
                sessCone = cachedCone
            } else {
                let computed = try sessionSpeakerCone(sessionID: sessionID, revision: evidence.modelRevision)
                sessionCones[evidence.modelRevision] = computed
                sessCone = computed
            }
        } else {
            sessCone = nil
        }
        let person = VoiceprintMatcher.match(
            evidence.embedding,
            clusterCentroid: updatedSampleCount > 0 ? centroid : nil,
            sessionCone: sessCone,
            cleanSeconds: max(0.3, evidence.cleanSeconds),
            prepared: prepared)
        let encodedEvidence = try WireJSON.encode(evidence)
        try database.execute("INSERT INTO speaker_observations(span_id,session_id,cluster_id,model_revision,evidence,matched_person,updated_at) VALUES(?,?,?,?,?,?,?)",
            [.text(spanID.uuidString), .text(sessionID.uuidString), .text(cluster.uuidString), .text(evidence.modelRevision),
             .blob(encodedEvidence), person.map { .text($0.uuidString) } ?? .null, .double(Date().timeIntervalSince1970)])
        storeDecodedSpeakerEvidence(sessionID: sessionID, spanID: spanID, data: encodedEvidence, evidence: evidence)
        return try speakerLabel(cluster: cluster, personID: person, confirmed: false, learnable: canLearn, people: people)
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { raw in
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in raw {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }
    }

    private func storeDecodedSpeakerEvidence(sessionID: UUID, spanID: UUID, data: Data, evidence: SpeakerEvidence?) {
        if speakerObservationEvidenceCache[sessionID] == nil {
            speakerObservationSessionOrder.removeAll { $0 == sessionID }
            speakerObservationSessionOrder.append(sessionID)
            while speakerObservationSessionOrder.count > 16 {
                let oldest = speakerObservationSessionOrder.removeFirst()
                speakerObservationEvidenceCache.removeValue(forKey: oldest)
            }
        }
        speakerObservationEvidenceCache[sessionID, default: [:]][spanID] = (
            byteCount: data.count,
            checksum: Self.fnv1a64(data),
            evidence: evidence
        )
    }

    private func decodeCachedSpeakerEvidence(sessionID: UUID, spanID: UUID, data: Data) throws -> SpeakerEvidence? {
        let sum = Self.fnv1a64(data)
        if let hit = speakerObservationEvidenceCache[sessionID]?[spanID],
           hit.byteCount == data.count, hit.checksum == sum {
            return hit.evidence
        }
        let decoded = try WireJSON.decode(SpeakerEvidence?.self, from: data)
        storeDecodedSpeakerEvidence(sessionID: sessionID, spanID: spanID, data: data, evidence: decoded)
        return decoded
    }

    private func speakerLabel(cluster: UUID, personID: UUID?, confirmed: Bool, learnable: Bool,
                              people: [Person], clusterNumbers: [UUID: Int]? = nil) throws -> (String?, SpeakerAttribution?) {
        let person = people.first { $0.id == personID }
        let number: Int
        if let precomputed = clusterNumbers?[cluster] {
            number = precomputed
        } else {
            let n = try database.rows("SELECT COUNT(*) FROM speaker_clusters WHERE session_id=(SELECT session_id FROM speaker_clusters WHERE id=?) AND rowid<=(SELECT rowid FROM speaker_clusters WHERE id=?)",
                [.text(cluster.uuidString), .text(cluster.uuidString)]).first?.integer(0) ?? 0
            number = Int(n)
        }
        let label = person?.name ?? String(localized: "说话人 \(max(1, number))")
        return (label, SpeakerAttribution(clusterID: cluster, personID: person?.id, isUser: person?.owner ?? false,
            confirmed: confirmed, canLearn: learnable))
    }

    public func correctSpeaker(_ source: SourceReference, feedback: SpeakerFeedback) throws {
        try correctSpeakers([source], feedback: feedback)
    }

    public func correctSpeakers(
        _ sources: [TranscriptCitationSource],
        feedback: SpeakerFeedback,
        scope: SpeakerFeedbackScope = .selection,
        deferGlobalRematch: Bool = false
    ) throws {
        try speakerTransaction {
            try validateSources(sources)
            let selected = try speakerFeedbackSources(sources, scope: scope)
            if case .selection = scope {
                if case .clear = feedback { /* Removing a label does not change acoustic grouping. */ }
                else { try separateSelectedSpeakerObservations(selected) }
            }
            var manualClusters: [UUID: UUID] = [:]
            var people = try voicePeople()
            func owner() throws -> UUID {
                if let known = people.first(where: \.owner) { return known.id }
                let id = UUID()
                try database.execute("INSERT INTO voice_profiles(id,name,is_owner) VALUES(?,?,1)", [.text(id.uuidString), .text(String(localized: "我"))])
                people = try voicePeople()
                return id
            }
            var resolvedNewPerson: UUID?
            if case .person(let raw) = feedback {
                let name = try voiceName(raw)
                guard name.caseInsensitiveCompare(String(localized: "我")) != .orderedSame,
                      !people.contains(where: { $0.owner && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw VoiceprintError.duplicateName
                }
                if let known = people.first(where: { !$0.owner && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    resolvedNewPerson = known.id
                } else {
                    let id = UUID()
                    try database.execute("INSERT INTO voice_profiles(id,name,is_owner) VALUES(?,?,0)", [.text(id.uuidString), .text(name)])
                    people = try voicePeople()
                    resolvedNewPerson = id
                }
            }

            let now = Date().timeIntervalSince1970
            let batchBucket = Int64((now / 2.0).rounded(.down))
            var spansBySession: [UUID: [UUID: TranscriptSpan]] = [:]
            var epochsByChunkBySession: [UUID: [UUID: UUID]] = [:]
            func spanInfo(sessionID: UUID, spanID: UUID) throws -> (span: TranscriptSpan, epochID: UUID)? {
                if spansBySession[sessionID] == nil {
                    let doc = try currentTranscriptOrNil(sessionID: sessionID)
                    spansBySession[sessionID] = Dictionary(uniqueKeysWithValues: (doc?.spans ?? []).map { ($0.id, $0) })
                    var epMap: [UUID: UUID] = [:]
                    for c in try database.rows("SELECT id,epoch_id FROM chunks WHERE session_id=?", [.text(sessionID.uuidString)]) {
                        epMap[try c.requireUUID(0)] = try c.requireUUID(1)
                    }
                    epochsByChunkBySession[sessionID] = epMap
                }
                guard let sp = spansBySession[sessionID]?[spanID],
                      let ep = epochsByChunkBySession[sessionID]?[sp.chunkID] else { return nil }
                return (sp, ep)
            }

            for source in selected {
                let row = try database.rows("SELECT confirmed_person,matched_person,model_revision,evidence FROM speaker_observations WHERE span_id=? AND session_id=?",
                    [.text(source.spanID.uuidString), .text(source.sessionID.uuidString)]).first
                if row == nil {
                    if case .clear = feedback { continue }
                    // A manual label needs no acoustic evidence. Keep it in a separate namespace,
                    // with JSON null evidence, so it can never become a matching exemplar.
                    let cluster = manualClusters[source.sessionID] ?? UUID()
                    let revision = "manual-label"
                    if manualClusters[source.sessionID] == nil {
                        try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,0)",
                            [.text(cluster.uuidString), .text(source.sessionID.uuidString), .text(revision), .blob(try WireJSON.encode([Float]()))])
                        manualClusters[source.sessionID] = cluster
                    }
                    try database.execute("INSERT INTO speaker_observations(span_id,session_id,cluster_id,model_revision,evidence,updated_at) VALUES(?,?,?,?,?,?)",
                        [.text(source.spanID.uuidString), .text(source.sessionID.uuidString), .text(cluster.uuidString), .text(revision),
                         .blob(try WireJSON.encode(Optional<SpeakerEvidence>.none)), .double(now)])
                }
                var person: UUID?
                var rejection: UUID?
                switch feedback {
                case .owner: person = try owner()
                case .notOwner:
                    rejection = try owner()
                    if let previous = row?.string(0).flatMap(UUID.init(uuidString:)), people.contains(where: { $0.id == previous && !$0.owner }) { person = previous }
                case .notPerson(let id):
                    guard people.contains(where: { $0.id == id }) else { throw VoiceprintError.missingPerson }
                    rejection = id
                    if let previous = row?.string(0).flatMap(UUID.init(uuidString:)), previous != id { person = previous }
                case .knownPerson(let id):
                    guard people.contains(where: { $0.id == id }) else { throw VoiceprintError.missingPerson }
                    person = id
                case .clear: break
                case .person:
                    person = resolvedNewPerson
                }
                let span = SQLValue.text(source.spanID.uuidString)
                if case .clear = feedback {
                    try database.execute("DELETE FROM voice_rejections WHERE span_id=?", [span])
                    try database.execute("DELETE FROM voice_profile_seeds WHERE anchor_id=?", [span])
                    try database.execute("DELETE FROM speaker_feedback_anchors WHERE id=? AND reconciled=1", [span])
                } else {
                    // Record negative exemplars only on explicit negative feedback (.notOwner / .notPerson).
                    // Positive identity assignments compete via multi-prototype margin without poisoning
                    // another person's negative bank when a span had mixed/inherited audio.
                    if let rejection, people.contains(where: { $0.id == rejection }) {
                        try database.execute("INSERT OR IGNORE INTO voice_rejections(span_id,person_id) VALUES(?,?)", [span, .text(rejection.uuidString)])
                        try database.execute("DELETE FROM voice_profile_seeds WHERE anchor_id=? AND person_id=?", [span, .text(rejection.uuidString)])
                        try database.execute("UPDATE speaker_feedback_anchors SET confirmed_person=NULL WHERE id=? AND confirmed_person=?",
                            [span, .text(rejection.uuidString)])
                    }
                    if let person {
                        try database.execute("DELETE FROM voice_rejections WHERE span_id=? AND person_id=?", [span, .text(person.uuidString)])
                    }
                }
                let ownerRejected = try database.rows("SELECT 1 FROM voice_rejections r JOIN voice_profiles p ON p.id=r.person_id WHERE r.span_id=? AND p.is_owner=1", [span]).first != nil
                try database.execute("UPDATE speaker_observations SET confirmed_person=?,rejected_owner=?,updated_at=? WHERE span_id=?",
                    [person.map { .text($0.uuidString) } ?? .null, .integer(ownerRejected ? 1 : 0), .double(now), span])

                // If confirming a legacy/unseeded/short span whose audio may still be retained, enqueue a
                // reconciled=1 seed anchor so ERes2NetV2 extracts a pristine 192-dim voiceprint in the background.
                if let person {
                    let existingEv = row.flatMap { try? $0.requireData(3) }.flatMap { try? WireJSON.decode(SpeakerEvidence?.self, from: $0) }
                    let alreadyHas192Learnable = existingEv.map { $0.embedding.count == 192 && VoiceprintPolicy.isLearnable($0, positive: true) } ?? false
                    if !alreadyHas192Learnable,
                       let info = try spanInfo(sessionID: source.sessionID, spanID: source.spanID),
                       info.span.frames.count >= 13_600 {
                        let bKey = "\(source.sessionID.uuidString):\(batchBucket)"
                        try database.execute("""
                            INSERT OR REPLACE INTO speaker_feedback_anchors(
                                id,session_id,epoch_id,start_frame,end_frame,confirmed_person,rejected_people_json,batch_key,batch_size,seeded_revision,reconciled
                            ) VALUES(?,?,?,?,?,?,'[]',?,?,NULL,1)
                            """, [
                                span,
                                .text(source.sessionID.uuidString),
                                .text(info.epochID.uuidString),
                                .integer(info.span.frames.start),
                                .integer(info.span.frames.end),
                                .text(person.uuidString),
                                .text(bKey),
                                .integer(Int64(selected.count))
                            ])
                    }
                }
            }
            let editedSessions = Set(selected.map(\.sessionID))
            invalidateVoiceprintCache()
            if deferGlobalRematch {
                try rematchSessionsDeferringOthers(immediateSessions: editedSessions)
            } else {
                try refreshSpeakerMatches(editedSessions: editedSessions)
            }
        }
    }

    private func voiceName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VoiceprintError.invalidName }
        return name
    }

    /// Counts the eligible exemplars used by the matcher across retained model revisions.
    public func speakerProfiles() throws -> [SpeakerProfile] {
        let cache = try ensureBaseVoiceprintCache()
        let people = cache.people
        guard !people.isEmpty else { return [] }
        let examples = cache.baseExamples.values.flatMap { $0 }
        return people.map { person in
            SpeakerProfile(id: person.id, name: person.name, isUser: person.owner,
                sampleCount: examples.filter { $0.person == person.id && $0.positive }.count,
                correctionCount: examples.filter { $0.person == person.id && !$0.positive }.count)
        }.sorted { a, b in a.isUser != b.isUser ? a.isUser : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    public func renameVoiceprint(personID: UUID, name raw: String) throws {
        let name = try voiceName(raw)
        try speakerTransaction {
            let people = try voicePeople()
            guard let person = people.first(where: { $0.id == personID }) else { throw VoiceprintError.missingPerson }
            guard person.owner || name.caseInsensitiveCompare(String(localized: "我")) != .orderedSame else { throw VoiceprintError.duplicateName }
            guard !people.contains(where: { $0.id != personID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw VoiceprintError.duplicateName }
            try database.execute("UPDATE voice_profiles SET name=? WHERE id=?", [.text(name), .text(personID.uuidString)])
            invalidateVoiceprintCache()
            try refreshSpeakerMatches()
        }
    }

    public func speakerFeedbackPreview(_ sources: [SourceReference]) throws -> (count: Int, learnableCount: Int, selectionLearnableCount: Int) {
        try validateSources(sources)
        let expanded = try speakerFeedbackSources(sources, scope: .cluster)
        var learnable = 0, selectedLearnable = 0
        let selectedIDs = Set(sources.map(\.spanID))
        let expandedBySession = Dictionary(grouping: expanded, by: \.sessionID)
        for (sessionID, sessionSources) in expandedBySession {
            let targetSpanIDs = Set(sessionSources.map(\.spanID))
            for row in try database.rows("SELECT span_id,evidence FROM speaker_observations WHERE session_id=?", [.text(sessionID.uuidString)]) {
                let spanID = try row.requireUUID(0)
                guard targetSpanIDs.contains(spanID),
                      let evidence = try WireJSON.decode(SpeakerEvidence?.self, from: row.requireData(1)),
                      VoiceprintPolicy.isLearnable(evidence, positive: true) else { continue }
                learnable += 1
                if selectedIDs.contains(spanID) { selectedLearnable += 1 }
            }
        }
        return (expanded.count, learnable, selectedLearnable)
    }

    private func speakerFeedbackSources(_ sources: [SourceReference], scope: SpeakerFeedbackScope) throws -> [SourceReference] {
        guard case .cluster = scope else { return sources }
        var selected = Dictionary(grouping: sources, by: \.sessionID)
        for (id, references) in selected {
            guard let document = try currentTranscriptOrNil(sessionID: id) else { throw ArchiveError.missingTranscript(id) }
            let selectedIDs = Set(references.map(\.spanID))
            let clusters = Set(document.spans.filter { selectedIDs.contains($0.id) }.compactMap { $0.attribution?.clusterID })
            selected[id] = document.spans.filter { selectedIDs.contains($0.id) || $0.attribution.map { clusters.contains($0.clusterID) } == true }
                .map { document.source(for: $0) }
        }
        return selected.values.flatMap { $0 }
    }

    private func separateSelectedSpeakerObservations(_ sources: [SourceReference]) throws {
        let selected = Set(sources.map(\.spanID))
        for session in Set(sources.map(\.sessionID)) {
            let rows = try database.rows("SELECT span_id,cluster_id,model_revision,evidence FROM speaker_observations WHERE session_id=?", [.text(session.uuidString)])
            let groups = try Dictionary(grouping: rows, by: { try $0.requireUUID(1) })
            for (original, members) in groups {
                let chosen = try members.filter { selected.contains(try $0.requireUUID(0)) }
                guard !chosen.isEmpty, chosen.count < members.count else { continue }
                let evidence = try chosen.compactMap { try WireJSON.decode(SpeakerEvidence?.self, from: $0.requireData(3)) }.filter(\.hasVoiceprint)
                let clean = evidence.filter { VoiceprintPolicy.isLearnable($0, positive: false) }
                var center = evidence.first?.embedding ?? []
                if let dim = clean.first?.embedding.count, clean.allSatisfy({ $0.embedding.count == dim }) {
                    var sum = Array(repeating: Float(0), count: dim)
                    for sample in clean {
                        let w = VoiceprintPolicy.weight(for: max(0.3, sample.cleanSeconds))
                        for d in 0..<dim { sum[d] += w * sample.embedding[d] }
                    }
                    if let normalized = VoiceprintPolicy.normalized(sum) { center = normalized }
                }
                let cluster = UUID()
                try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,?)",
                    [.text(cluster.uuidString), .text(session.uuidString), .text(try chosen[0].requireString(2)),
                     .blob(try WireJSON.encode(center)), .integer(Int64(min(clean.count, 32)))])
                for row in chosen {
                    try database.execute("UPDATE speaker_observations SET cluster_id=? WHERE span_id=?", [.text(cluster.uuidString), .text(try row.requireString(0))])
                }
                try separateSpeakerClusters(original, cluster)
                // Recompute original cluster's centroid from its remaining members.
                let remaining = try members.filter { !selected.contains(try $0.requireUUID(0)) }
                let remEvidence = try remaining.compactMap { try WireJSON.decode(SpeakerEvidence?.self, from: $0.requireData(3)) }.filter(\.hasVoiceprint)
                let remClean = remEvidence.filter { VoiceprintPolicy.isLearnable($0, positive: false) }
                if let fallback = remEvidence.first?.embedding {
                    var remCenter = fallback
                    if let dim = remClean.first?.embedding.count, remClean.allSatisfy({ $0.embedding.count == dim }) {
                        var sum = Array(repeating: Float(0), count: dim)
                        for sample in remClean {
                            let w = VoiceprintPolicy.weight(for: max(0.3, sample.cleanSeconds))
                            for d in 0..<dim { sum[d] += w * sample.embedding[d] }
                        }
                        if let normalized = VoiceprintPolicy.normalized(sum) { remCenter = normalized }
                    }
                    try database.execute("UPDATE speaker_clusters SET centroid=?,sample_count=? WHERE id=?",
                        [.blob(try WireJSON.encode(remCenter)), .integer(Int64(min(remClean.count, 32))), .text(original.uuidString)])
                }
            }
        }
    }

    /// Idempotent upgrade of speaker grouping and voiceprint matching, plus automatic
    /// re-diarization of unedited, unconfirmed Build-16/17 retained multi-speaker sessions.
    public func upgradeSpeakerProfilesIfNeeded() throws {
        let needsV2 = try database.rows("SELECT 1 FROM metadata WHERE key='speaker_profiles_v2'").isEmpty
        let needsV3 = try database.rows("SELECT 1 FROM metadata WHERE key='speaker_profiles_v3'").isEmpty
        let needsV4 = try database.rows("SELECT 1 FROM metadata WHERE key='speaker_profiles_v4'").isEmpty
        let needsV5 = try database.rows("SELECT 1 FROM metadata WHERE key='speaker_profiles_v5'").isEmpty
        let needsV6 = try database.rows("SELECT 1 FROM metadata WHERE key='speaker_profiles_v6'").isEmpty
        let needsV7 = try database.rows("SELECT 1 FROM metadata WHERE key='speaker_profiles_v7'").isEmpty
        guard needsV2 || needsV3 || needsV4 || needsV5 || needsV6 || needsV7 else { return }
        try speakerTransaction {
            invalidateVoiceprintCache()
            if needsV3 {
                // Remove historical auto-generated rejections on spans that carry a positive
                // confirmed_person identity (created by legacy side-effect rejections rather
                // than explicit .notOwner / .notPerson feedback).
                try database.execute("""
                    DELETE FROM voice_rejections
                    WHERE span_id IN (
                        SELECT span_id FROM speaker_observations
                        WHERE confirmed_person IS NOT NULL
                    ) AND person_id != (
                        SELECT confirmed_person FROM speaker_observations
                        WHERE speaker_observations.span_id = voice_rejections.span_id
                    )
                    """)
                try database.execute("""
                    UPDATE speaker_observations
                    SET rejected_owner = CASE
                        WHEN EXISTS(
                            SELECT 1 FROM voice_rejections r
                            JOIN voice_profiles p ON p.id=r.person_id
                            WHERE r.span_id=speaker_observations.span_id AND p.is_owner=1
                        ) THEN 1 ELSE 0 END
                    """)
            }
            if needsV4 || needsV5 {
                // Prune false cannot-link conflicts written by sequential local_speaker IDs on Oct 30
                // where neither cluster carries any manual speaker confirmation or rejection.
                try database.execute("""
                    DELETE FROM speaker_cluster_conflicts
                    WHERE (first_id IN (
                        SELECT c.id FROM speaker_clusters c JOIN sessions s ON s.id=c.session_id
                        WHERE s.recorded_at >= 1793318400
                    ) OR second_id IN (
                        SELECT c.id FROM speaker_clusters c JOIN sessions s ON s.id=c.session_id
                        WHERE s.recorded_at >= 1793318400
                    ))
                    AND NOT EXISTS (
                        SELECT 1 FROM speaker_observations o
                        WHERE (o.cluster_id=speaker_cluster_conflicts.first_id OR o.cluster_id=speaker_cluster_conflicts.second_id)
                          AND (o.confirmed_person IS NOT NULL OR o.rejected_owner!=0
                               OR EXISTS (SELECT 1 FROM voice_rejections r WHERE r.span_id=o.span_id))
                    )
                    """)
                try requeueUnconfirmedBuild16Sessions()
            }
            if needsV6 {
                try migrateLegacySpeakerSessionsForV6()
            }
            if needsV7 {
                try enqueueSeedAnchorsForRetainedConfirmedSpans()
            }
            invalidateVoiceprintCache()
            let baseCache = try ensureBaseVoiceprintCache()
            for row in try database.rows("SELECT DISTINCT session_id FROM speaker_observations") {
                _ = try reconcileSpeakerClusters(sessionID: row.requireUUID(0), preparedBanks: baseCache.basePrepared)
            }
            invalidateTransductiveVoiceprintCache()
            try refreshSpeakerMatches()
            if needsV2 {
                try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v2','1')")
            }
            if needsV3 {
                try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v3','1')")
            }
            if needsV4 {
                try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v4','1')")
            }
            if needsV5 {
                try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v5','1')")
            }
            if needsV6 {
                try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v6','1')")
            }
            if needsV7 {
                try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v7','1')")
            }
        }
    }

    private func enqueueSeedAnchorsForRetainedConfirmedSpans() throws {
        // Snapshot reconciled=1 seed anchors for confirmed spans in partially-retained or legacy
        // sessions so ERes2NetV2 can extract 192-dim voiceprint seeds from any surviving audio chunks.
        let sessionRows = try database.rows("""
            SELECT DISTINCT o.session_id
            FROM speaker_observations o
            JOIN sessions s ON s.id=o.session_id
            WHERE s.deleted=0 AND o.confirmed_person IS NOT NULL
            """)
        for sRow in sessionRows {
            let sessionID = try sRow.requireUUID(0)
            guard let doc = try currentTranscriptOrNil(sessionID: sessionID), !doc.spans.isEmpty else { continue }
            let sid = SQLValue.text(sessionID.uuidString)
            var epochByChunk: [UUID: UUID] = [:]
            for cRow in try database.rows("SELECT id,epoch_id,retention,relative_path FROM chunks WHERE session_id=?", [sid]) {
                guard cRow.string(2) == "present",
                      let rel = cRow.string(3),
                      files.fileExists(atPath: rootURL.appendingPathComponent(rel).path) else { continue }
                epochByChunk[try cRow.requireUUID(0)] = try cRow.requireUUID(1)
            }
            guard !epochByChunk.isEmpty else { continue }
            let spanByID = Dictionary(uniqueKeysWithValues: doc.spans.map { ($0.id, $0) })
            let obsRows = try database.rows(
                "SELECT span_id,confirmed_person,evidence,updated_at FROM speaker_observations WHERE session_id=? AND confirmed_person IS NOT NULL",
                [sid])
            var batchCounts: [String: Int] = [:]
            var candidates: [(spanID: UUID, confirmed: String, updatedAt: Double)] = []
            for oRow in obsRows {
                let spanID = try oRow.requireUUID(0)
                guard let confirmed = oRow.string(1) else { continue }
                let ev = (try? oRow.requireData(2)).flatMap { try? WireJSON.decode(SpeakerEvidence?.self, from: $0) }
                if let ev, ev.embedding.count == 192, VoiceprintPolicy.isLearnable(ev, positive: true) {
                    continue
                }
                let updatedAt = oRow.double(3) ?? 0
                let bucket = Int64((updatedAt / 2.0).rounded(.down))
                let bKey = "\(sessionID.uuidString):\(bucket)"
                batchCounts["\(confirmed)|\(bKey)", default: 0] += 1
                candidates.append((spanID, confirmed, updatedAt))
            }
            for item in candidates {
                guard let sp = spanByID[item.spanID],
                      sp.frames.count >= 13_600,
                      let epochID = epochByChunk[sp.chunkID] else { continue }
                let bucket = Int64((item.updatedAt / 2.0).rounded(.down))
                let bKey = "\(sessionID.uuidString):\(bucket)"
                let bSize = batchCounts["\(item.confirmed)|\(bKey)"] ?? 1
                try database.execute("""
                    INSERT OR IGNORE INTO speaker_feedback_anchors(
                        id,session_id,epoch_id,start_frame,end_frame,confirmed_person,rejected_people_json,batch_key,batch_size,seeded_revision,reconciled
                    ) VALUES(?,?,?,?,?,?,'[]',?,?,NULL,1)
                    """, [
                        .text(sp.id.uuidString), sid, .text(epochID.uuidString),
                        .integer(sp.frames.start), .integer(sp.frames.end),
                        .text(item.confirmed), .text(bKey), .integer(Int64(bSize))
                    ])
            }
        }
    }

    private func migrateLegacySpeakerSessionsForV6() throws {
        // Snapshot manual speaker feedback into speaker_feedback_anchors and re-queue all retained
        // legacy WeSpeaker (or unattributed) sessions for clean DiariZen + ERes2NetV2 re-diarization.
        let candidates = try database.rows("""
            SELECT s.id FROM sessions s
            WHERE s.deleted=0 AND s.generation=0 AND s.projection_blocked=0
              AND EXISTS (SELECT 1 FROM analysis_windows w WHERE w.session_id=s.id AND w.state='complete')
              AND NOT EXISTS (SELECT 1 FROM analysis_windows w WHERE w.session_id=s.id AND w.state='running')
              AND NOT EXISTS (SELECT 1 FROM analysis_epochs a JOIN epochs e ON e.id=a.epoch_id WHERE e.session_id=s.id AND a.attempt_id IS NOT NULL)
              AND (
                  EXISTS (SELECT 1 FROM speaker_observations o WHERE o.session_id=s.id AND o.model_revision=?)
                  OR (
                      s.recorded_at >= 1700000000
                      AND NOT EXISTS (SELECT 1 FROM speaker_observations o WHERE o.session_id=s.id AND o.model_revision!='manual-label')
                  )
              )
            """, [.text(VoiceprintPolicy.legacyWeSpeakerRevision)])
        for row in candidates {
            let sessionID = try row.requireUUID(0)
            guard try !batchReservesSession(sessionID) else { continue }
            let sid = SQLValue.text(sessionID.uuidString)
            let chunks = try database.rows("SELECT id,epoch_id,retention,relative_path FROM chunks WHERE session_id=?", [sid])
            guard !chunks.isEmpty else { continue }
            var allPresent = true
            var epochByChunk: [UUID: UUID] = [:]
            for chunk in chunks {
                guard chunk.string(2) == "present",
                      let rel = chunk.string(3),
                      files.fileExists(atPath: rootURL.appendingPathComponent(rel).path) else {
                    allPresent = false
                    break
                }
                epochByChunk[try chunk.requireUUID(0)] = try chunk.requireUUID(1)
            }
            guard allPresent else { continue }

            let old = try currentTranscriptOrNil(sessionID: sessionID)
            if let old, !old.spans.isEmpty {
                let obsRows = try database.rows("SELECT span_id,confirmed_person,updated_at FROM speaker_observations WHERE session_id=?", [sid])
                let rejRows = try database.rows("SELECT r.span_id,r.person_id FROM voice_rejections r JOIN speaker_observations o ON o.span_id=r.span_id WHERE o.session_id=?", [sid])
                var obsBySpan: [UUID: (confirmed: String?, updatedAt: Double)] = [:]
                for o in obsRows {
                    obsBySpan[try o.requireUUID(0)] = (o.string(1), o.double(2) ?? 0)
                }
                var rejBySpan: [UUID: [String]] = [:]
                for r in rejRows {
                    rejBySpan[try r.requireUUID(0), default: []].append(try r.requireString(1))
                }
                var batchCounts: [String: Int] = [:]
                for span in old.spans {
                    guard let info = obsBySpan[span.id], let confirmed = info.confirmed else { continue }
                    let bucket = Int64(((info.updatedAt) / 2.0).rounded(.down))
                    let bKey = "\(sessionID.uuidString):\(bucket)"
                    batchCounts["\(confirmed)|\(bKey)", default: 0] += 1
                }
                for span in old.spans where span.frames.count > 0 {
                    let info = obsBySpan[span.id]
                    let confirmed = info?.confirmed
                    let rejs = (rejBySpan[span.id] ?? []).sorted()
                    guard confirmed != nil || !rejs.isEmpty else { continue }
                    guard let epochID = epochByChunk[span.chunkID] else { continue }
                    let bucket = Int64(((info?.updatedAt ?? 0) / 2.0).rounded(.down))
                    let bKey = "\(sessionID.uuidString):\(bucket)"
                    let bSize = confirmed.map { batchCounts["\($0)|\(bKey)"] ?? 1 } ?? 1
                    let rejJSON = String(data: try WireJSON.encode(rejs), encoding: .utf8) ?? "[]"
                    try database.execute("""
                        INSERT OR REPLACE INTO speaker_feedback_anchors(
                            id,session_id,epoch_id,start_frame,end_frame,confirmed_person,rejected_people_json,batch_key,batch_size,seeded_revision,reconciled
                        ) VALUES(?,?,?,?,?,?,?,?,?,NULL,0)
                        """, [
                            .text(span.id.uuidString), sid, .text(epochID.uuidString),
                            .integer(span.frames.start), .integer(span.frames.end),
                            confirmed.map(SQLValue.text) ?? .null, .text(rejJSON),
                            .text(bKey), .integer(Int64(bSize))
                        ])
                }
            }

            try database.execute("DELETE FROM speaker_observations WHERE session_id=?", [sid])
            try database.execute("""
                DELETE FROM speaker_cluster_conflicts
                WHERE first_id IN (SELECT id FROM speaker_clusters WHERE session_id=?)
                   OR second_id IN (SELECT id FROM speaker_clusters WHERE session_id=?)
                """, [sid, sid])
            try database.execute("DELETE FROM speaker_clusters WHERE session_id=?", [sid])
            // Re-planned from audio once the active configuration is known; resetting windows in
            // place would strand carried windows whose IDs the planner cannot rebuild.
            try requestAnalysisReplan(sessionID: sessionID)
        }
    }

    public func claimNextVoiceprintSeedCandidate(modelRevision: String) throws -> VoiceprintSeedCandidate? {
        guard ContentHash.isValid(modelRevision) else { return nil }
        let rows = try database.rows("""
            SELECT a.id,a.confirmed_person,a.session_id,a.epoch_id,a.start_frame,a.end_frame,a.batch_key,a.batch_size,e.timebase
            FROM speaker_feedback_anchors a
            JOIN sessions s ON s.id=a.session_id
            JOIN epochs e ON e.id=a.epoch_id
            JOIN voice_profiles p ON p.id=a.confirmed_person
            WHERE s.deleted=0
              AND a.confirmed_person IS NOT NULL
              AND (a.seeded_revision IS NULL OR a.seeded_revision != ?)
              AND (SELECT COUNT(*) FROM voice_profile_seeds v WHERE v.person_id=a.confirmed_person AND v.model_revision=?) < 20
            ORDER BY (CASE WHEN a.batch_size <= 2 THEN 0 WHEN a.batch_size <= 6 THEN 1 ELSE 2 END) ASC,
                     a.batch_size ASC,
                     ABS((a.end_frame - a.start_frame) / MAX(1.0, e.timebase) - 3.5) ASC,
                     a.id ASC
            LIMIT 64
            """, [.text(modelRevision), .text(modelRevision)])
        for row in rows {
            let anchorID = try row.requireUUID(0)
            let personID = try row.requireUUID(1)
            let sessionID = try row.requireUUID(2)
            let epochID = try row.requireUUID(3)
            let startFrame = try row.requireInt(4)
            let endFrame = try row.requireInt(5)
            let batchKey = try row.requireString(6)
            let batchSize = Int(try row.requireInt(7))
            let timebase = max(1.0, row.double(8) ?? 16_000)
            let durationSec = Double(endFrame - startFrame) / timebase
            guard endFrame > startFrame, durationSec >= 0.85, durationSec <= 12.0 else {
                try database.execute("UPDATE speaker_feedback_anchors SET seeded_revision=? WHERE id=?",
                    [.text(modelRevision), .text(anchorID.uuidString)])
                continue
            }
            let inputs = try contiguousInputs(epochID: epochID, from: startFrame, through: endFrame)
            guard let first = inputs.first, let last = inputs.last,
                  first.envelope.manifest.frames.start <= startFrame,
                  last.envelope.manifest.frames.end >= endFrame else {
                try database.execute("UPDATE speaker_feedback_anchors SET seeded_revision=? WHERE id=?",
                    [.text(modelRevision), .text(anchorID.uuidString)])
                continue
            }
            do {
                let leases = try leaseInputs(inputs)
                return VoiceprintSeedCandidate(
                    anchorID: anchorID,
                    personID: personID,
                    sessionID: sessionID,
                    epochID: epochID,
                    frames: try FrameRange(start: startFrame, count: endFrame - startFrame),
                    batchKey: batchKey,
                    batchSize: batchSize,
                    inputs: inputs,
                    leaseIDs: leases)
            } catch {
                try database.execute("UPDATE speaker_feedback_anchors SET seeded_revision=? WHERE id=?",
                    [.text(modelRevision), .text(anchorID.uuidString)])
                continue
            }
        }
        return nil
    }

    public func completeVoiceprintSeedCandidate(_ candidate: VoiceprintSeedCandidate, modelRevision: String,
                                                extracted: (embedding: [Float], cleanSeconds: Double)?) throws {
        defer {
            for id in candidate.leaseIDs { audioLeases.removeValue(forKey: id) }
            try? cleanDeletedFilesIfPending()
        }
        try speakerTransaction {
            try database.execute("UPDATE speaker_feedback_anchors SET seeded_revision=? WHERE id=?",
                [.text(modelRevision), .text(candidate.anchorID.uuidString)])
            guard let extracted,
                  ContentHash.isValid(modelRevision),
                  let norm = VoiceprintPolicy.normalized(extracted.embedding),
                  extracted.cleanSeconds.isFinite,
                  extracted.cleanSeconds >= VoiceprintPolicy.minLearnableSeconds(forDim: norm.count),
                  try !sessionIsDeleted(candidate.sessionID),
                  try !database.rows("SELECT 1 FROM voice_profiles WHERE id=?", [.text(candidate.personID.uuidString)]).isEmpty else {
                return
            }
            try database.execute("""
                INSERT OR REPLACE INTO voice_profile_seeds(anchor_id,person_id,session_id,model_revision,embedding,clean_seconds,batch_key)
                VALUES(?,?,?,?,?,?,?)
                """, [
                    .text(candidate.anchorID.uuidString),
                    .text(candidate.personID.uuidString),
                    .text(candidate.sessionID.uuidString),
                    .text(modelRevision),
                    .blob(try WireJSON.encode(norm)),
                    .double(min(VoiceprintPolicy.maxCleanSeconds, extracted.cleanSeconds)),
                    .text(candidate.batchKey)
                ])
            invalidateVoiceprintCache()
            try rematchSessionsDeferringOthers(immediateSessions: [candidate.sessionID])
        }
    }

    public func releaseVoiceprintSeedCandidate(_ candidate: VoiceprintSeedCandidate) throws {
        for id in candidate.leaseIDs { audioLeases.removeValue(forKey: id) }
        try cleanDeletedFilesIfPending()
    }

    func applyHistoricalFeedbackAnchors(sessionID: UUID, epochID: UUID, coreEnd: Int64, newSpans: [TranscriptSpan]) throws -> Bool {
        guard !newSpans.isEmpty,
              let windowStart = newSpans.map(\.frames.start).min(),
              let windowEnd = newSpans.map(\.frames.end).max() else { return false }
        let anchorRows = try database.rows("""
            SELECT id,start_frame,end_frame,confirmed_person,rejected_people_json,batch_size
            FROM speaker_feedback_anchors
            WHERE session_id=? AND epoch_id=? AND reconciled=0 AND end_frame>? AND start_frame<?
            """, [.text(sessionID.uuidString), .text(epochID.uuidString), .integer(windowStart), .integer(windowEnd)])
        guard !anchorRows.isEmpty else { return false }

        let people = try voicePeople()
        let activePersonIDs = Set(people.map(\.id))
        let ownerID = people.first(where: \.owner)?.id
        var sanitizedByRev: [String: [VoiceprintExample]] = [:]
        func sanitized(for revision: String) throws -> [VoiceprintExample] {
            if let cached = sanitizedByRev[revision] { return cached }
            let computed = VoiceprintMatcher.sanitizedExamples(try voiceExamples(revision: revision, people: people))
            sanitizedByRev[revision] = computed
            return computed
        }

        var manualClusterID: UUID?
        func ensureObservationRow(for spanID: UUID) throws {
            let exists = try !database.rows("SELECT 1 FROM speaker_observations WHERE span_id=?", [.text(spanID.uuidString)]).isEmpty
            guard !exists else { return }
            let cluster = manualClusterID ?? UUID()
            if manualClusterID == nil {
                try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,0)",
                    [.text(cluster.uuidString), .text(sessionID.uuidString), .text("manual-label"), .blob(try WireJSON.encode([Float]()))])
                manualClusterID = cluster
            }
            try database.execute("INSERT INTO speaker_observations(span_id,session_id,cluster_id,model_revision,evidence,updated_at) VALUES(?,?,?,?,?,?)",
                [.text(spanID.uuidString), .text(sessionID.uuidString), .text(cluster.uuidString), .text("manual-label"),
                 .blob(try WireJSON.encode(Optional<SpeakerEvidence>.none)), .double(Date().timeIntervalSince1970)])
        }

        var didChange = false
        for row in anchorRows {
            let anchorID = try row.requireUUID(0)
            let aStart = try row.requireInt(1)
            let aEnd = try row.requireInt(2)
            let anchorLen = max(1, aEnd - aStart)
            let confirmedID = row.string(3).flatMap(UUID.init(uuidString:)).flatMap { activePersonIDs.contains($0) ? $0 : nil }
            let rejectedIDs = ((try? WireJSON.decode([String].self, from: Data((row.string(4) ?? "[]").utf8))) ?? [])
                .compactMap(UUID.init(uuidString:))
                .filter { activePersonIDs.contains($0) }
            let batchSize = Int(row.integer(5) ?? 1)

            let overlapping = newSpans.compactMap { span -> (span: TranscriptSpan, overlap: Int64)? in
                let ov = min(span.frames.end, aEnd) - max(span.frames.start, aStart)
                return ov > 0 ? (span, ov) : nil
            }

            if !rejectedIDs.isEmpty {
                for (span, ov) in overlapping where Double(ov) >= 0.50 * Double(max(1, span.frames.count)) {
                    try ensureObservationRow(for: span.id)
                    for rID in rejectedIDs {
                        try database.execute("INSERT OR IGNORE INTO voice_rejections(span_id,person_id) VALUES(?,?)",
                            [.text(span.id.uuidString), .text(rID.uuidString)])
                    }
                    if let ownerID, rejectedIDs.contains(ownerID) {
                        try database.execute("UPDATE speaker_observations SET rejected_owner=1 WHERE span_id=?",
                            [.text(span.id.uuidString)])
                    }
                    didChange = true
                }
            }

            if let confirmedID {
                let significant = overlapping.filter { $0.overlap >= min(4_800, max(1, anchorLen / 4)) }
                if batchSize <= 2, significant.count == 1,
                   let sole = significant.first,
                   Double(sole.overlap) >= 0.60 * Double(anchorLen),
                   Double(sole.overlap) >= 0.60 * Double(max(1, sole.span.frames.count)) {
                    try ensureObservationRow(for: sole.span.id)
                    let isRejected = try !database.rows("SELECT 1 FROM voice_rejections WHERE span_id=? AND person_id=?",
                        [.text(sole.span.id.uuidString), .text(confirmedID.uuidString)]).isEmpty
                    if !isRejected {
                        try database.execute("UPDATE speaker_observations SET confirmed_person=?,updated_at=? WHERE span_id=?",
                            [.text(confirmedID.uuidString), .double(Date().timeIntervalSince1970), .text(sole.span.id.uuidString)])
                        if let obs = try database.rows("SELECT model_revision,evidence FROM speaker_observations WHERE span_id=?",
                            [.text(sole.span.id.uuidString)]).first,
                           let rev = obs.string(0),
                           let ev = try? WireJSON.decode(SpeakerEvidence?.self, from: obs.requireData(1)),
                           VoiceprintPolicy.isLearnable(ev, positive: true) {
                            try database.execute("DELETE FROM voice_profile_seeds WHERE anchor_id=? AND model_revision=?",
                                [.text(anchorID.uuidString), .text(rev)])
                            sanitizedByRev.removeValue(forKey: rev)
                        }
                        didChange = true
                    }
                } else {
                    // Bulk cluster confirmation OR newly split multi-speaker turn: verify acoustic match
                    // before restoring confirmed_person so mixed/other-speaker sub-turns are not poisoned!
                    for (span, ov) in overlapping where Double(ov) >= 0.50 * Double(max(1, span.frames.count)) {
                        guard let obs = try database.rows("SELECT model_revision,evidence FROM speaker_observations WHERE span_id=?",
                            [.text(span.id.uuidString)]).first,
                              let rev = obs.string(0), rev != "manual-label",
                              let ev = try? WireJSON.decode(SpeakerEvidence?.self, from: obs.requireData(1)),
                              ev.hasVoiceprint,
                              let normVec = VoiceprintPolicy.normalized(ev.embedding) else { continue }
                        let isRejected = try !database.rows("SELECT 1 FROM voice_rejections WHERE span_id=? AND person_id=?",
                            [.text(span.id.uuidString), .text(confirmedID.uuidString)]).isEmpty
                        if isRejected { continue }

                        let examples = try sanitized(for: rev).filter { $0.positive && $0.embedding.count == normVec.count }
                        let byPerson = Dictionary(grouping: examples, by: \.person)
                        guard let selfPos = byPerson[confirmedID], !selfPos.isEmpty else { continue }
                        let (selfCenters, _) = VoiceprintMatcher.subcenters(for: selfPos)
                        let selfAff = VoiceprintMatcher.positiveAffinity(normVec, positives: selfPos, centers: selfCenters)
                        var bestOther: Float = -1
                        for (otherPerson, otherPos) in byPerson where otherPerson != confirmedID && !otherPos.isEmpty {
                            let (otherCenters, _) = VoiceprintMatcher.subcenters(for: otherPos)
                            bestOther = max(bestOther, VoiceprintMatcher.positiveAffinity(normVec, positives: otherPos, centers: otherCenters))
                        }
                        let minVerifySim: Float = normVec.count == 192 ? 0.44 : 0.72
                        if selfAff >= minVerifySim && (bestOther < 0 || selfAff >= bestOther + 0.04) {
                            try database.execute("UPDATE speaker_observations SET confirmed_person=?,updated_at=? WHERE span_id=?",
                                [.text(confirmedID.uuidString), .double(Date().timeIntervalSince1970), .text(span.id.uuidString)])
                            if VoiceprintPolicy.isLearnable(ev, positive: true) {
                                try database.execute("DELETE FROM voice_profile_seeds WHERE anchor_id=? AND model_revision=?",
                                    [.text(anchorID.uuidString), .text(rev)])
                                sanitizedByRev.removeValue(forKey: rev)
                            }
                            didChange = true
                        }
                    }
                }
            }

            if aEnd <= coreEnd {
                try database.execute("UPDATE speaker_feedback_anchors SET reconciled=1 WHERE id=?",
                    [.text(anchorID.uuidString)])
            }
        }
        if didChange {
            invalidateVoiceprintCache()
        }
        return didChange
    }

    private func requeueUnconfirmedBuild16Sessions() throws {
        // Re-run diarization + turn-decoding on unedited, unconfirmed recordings from Oct 30
        // (2026-10-30 08:00 CST onwards) whose original audio chunks are 100% present on disk.
        let candidates = try database.rows("""
            SELECT s.id FROM sessions s
            WHERE s.deleted=0 AND s.generation=0 AND s.projection_blocked=0
              AND s.recorded_at >= 1793318400
              AND EXISTS (SELECT 1 FROM analysis_windows w WHERE w.session_id=s.id AND w.state='complete')
              AND NOT EXISTS (SELECT 1 FROM analysis_windows w WHERE w.session_id=s.id AND w.state='running')
              AND NOT EXISTS (SELECT 1 FROM analysis_epochs a JOIN epochs e ON e.id=a.epoch_id WHERE e.session_id=s.id AND a.attempt_id IS NOT NULL)
              AND NOT EXISTS (
                  SELECT 1 FROM speaker_observations o WHERE o.session_id=s.id
                    AND (o.confirmed_person IS NOT NULL OR o.rejected_owner!=0 OR o.model_revision='manual-label')
              )
              AND NOT EXISTS (
                  SELECT 1 FROM voice_rejections r JOIN speaker_observations o ON o.span_id=r.span_id
                  WHERE o.session_id=s.id
              )
            """)
        for row in candidates {
            let sessionID = try row.requireUUID(0)
            guard try !batchReservesSession(sessionID) else { continue }
            let sid = SQLValue.text(sessionID.uuidString)
            let chunks = try database.rows("SELECT retention,relative_path FROM chunks WHERE session_id=?", [sid])
            guard !chunks.isEmpty else { continue }
            var allPresent = true
            for chunk in chunks {
                guard chunk.string(0) == "present",
                      let rel = chunk.string(1),
                      files.fileExists(atPath: rootURL.appendingPathComponent(rel).path) else {
                    allPresent = false
                    break
                }
            }
            guard allPresent else { continue }

            try database.execute("DELETE FROM speaker_observations WHERE session_id=?", [sid])
            try database.execute("""
                DELETE FROM speaker_cluster_conflicts
                WHERE first_id IN (SELECT id FROM speaker_clusters WHERE session_id=?)
                   OR second_id IN (SELECT id FROM speaker_clusters WHERE session_id=?)
                """, [sid, sid])
            try database.execute("DELETE FROM speaker_clusters WHERE session_id=?", [sid])
            // Re-planned from audio once the active configuration is known; resetting windows in
            // place would strand carried windows whose IDs the planner cannot rebuild.
            try requestAnalysisReplan(sessionID: sessionID)
        }
    }

    func separateSpeakerClusters(_ a: UUID, _ b: UUID) throws {
        guard a != b else { return }
        let ids = [a.uuidString, b.uuidString].sorted()
        try database.execute("INSERT OR IGNORE INTO speaker_cluster_conflicts(first_id,second_id) VALUES(?,?)", [.text(ids[0]), .text(ids[1])])
    }

    private func computeInMemorySessionCone(clusterVecs: [[Float]], voicedEmbeddings: [[Float]]) -> VoiceprintCone? {
        guard let dim = clusterVecs.first?.count, clusterVecs.count >= 3,
              clusterVecs.allSatisfy({ $0.count == dim }) else { return nil }
        var minPairwise: Float = 1.0
        var maxPairwise: Float = -1.0
        for i in 0..<clusterVecs.count {
            for j in (i + 1)..<clusterVecs.count {
                let s = SpeakerEvidence.similarity(clusterVecs[i], clusterVecs[j])
                minPairwise = min(minPairwise, s)
                maxPairwise = max(maxPairwise, s)
            }
        }
        guard minPairwise >= 0.35, maxPairwise <= 0.96 else { return nil }
        let voiced = voicedEmbeddings.filter { $0.count == dim }
        guard voiced.count >= 6 else { return nil }
        var mean = Array(repeating: Float(0), count: dim)
        let inv = 1.0 / Float(voiced.count)
        for v in voiced {
            for d in 0..<dim { mean[d] += v[d] * inv }
        }
        let coneNorm = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
        guard coneNorm >= 0.76 else { return nil }
        let strength = min(0.90, (coneNorm - 0.72) / 0.20 * 0.90)
        return VoiceprintCone(mean: mean, strength: strength)
    }

    /// Semi-supervised constrained agglomerative clustering within a session:
    /// merges fragmented clusters of the same voice while strictly respecting cannot-link
    /// conflicts, manual confirmations, and voice rejections, and prunes empty orphan clusters.
    func reconcileSpeakerClusters(sessionID: UUID,
                                  preparedBanks: [String: [Int: VoiceprintMatcher.PreparedBank]]? = nil) throws -> Bool {
        let key: [SQLValue] = [.text(sessionID.uuidString)]
        let obsRows = try database.rows(
            "SELECT span_id,cluster_id,model_revision,evidence,confirmed_person FROM speaker_observations WHERE session_id=? AND model_revision!='manual-label'",
            key)
        guard !obsRows.isEmpty else { return false }

        struct ObsItem {
            let spanID: UUID
            var clusterID: UUID
            let revision: String
            let evidence: SpeakerEvidence
            let confirmedPerson: UUID?
            let rejectedPeople: Set<UUID>
        }

        let rejRows = try database.rows(
            "SELECT r.span_id,r.person_id FROM voice_rejections r JOIN speaker_observations o ON o.span_id=r.span_id WHERE o.session_id=?",
            key)
        var rejectionsBySpan: [UUID: Set<UUID>] = [:]
        for r in rejRows {
            if let s = UUID(uuidString: try r.requireString(0)),
               let p = UUID(uuidString: try r.requireString(1)) {
                rejectionsBySpan[s, default: []].insert(p)
            }
        }

        var items: [ObsItem] = []
        items.reserveCapacity(obsRows.count)
        for row in obsRows {
            let spanID = try row.requireUUID(0)
            guard let ev = try decodeCachedSpeakerEvidence(
                sessionID: sessionID, spanID: spanID, data: row.requireData(3)
            ), ev.hasVoiceprint else { continue }
            items.append(ObsItem(
                spanID: spanID,
                clusterID: try row.requireUUID(1),
                revision: try row.requireString(2),
                evidence: ev,
                confirmedPerson: row.string(4).flatMap(UUID.init(uuidString:)),
                rejectedPeople: rejectionsBySpan[spanID] ?? []))
        }
        guard !items.isEmpty else { return false }

        let clusterRows = try database.rows(
            "SELECT id,model_revision,centroid,sample_count,rowid FROM speaker_clusters WHERE session_id=? AND model_revision!='manual-label' ORDER BY rowid ASC",
            key)

        struct ClusterNode {
            let id: UUID
            let revision: String
            let rowOrder: Int64
            var centroid: [Float]
            var sampleCount: Int64
            var memberIndices: [Int]
            var confirmedPeople: Set<UUID>
            var rejectedPeople: Set<UUID>
            var profileAnchor: UUID?
        }

        var localBanks: [String: [Int: VoiceprintMatcher.PreparedBank]] = preparedBanks ?? [:]
        let revisions = Set(items.map(\.revision))
        for rev in revisions where localBanks[rev] == nil && ContentHash.isValid(rev) {
            localBanks[rev] = try cachedBasePreparedBank(for: rev)
        }

        var nodes: [UUID: ClusterNode] = [:]
        for row in clusterRows {
            let cid = try row.requireUUID(0)
            let rev = try row.requireString(1)
            let storedCentroid = (try? WireJSON.decode([Float].self, from: row.requireData(2))) ?? []
            nodes[cid] = ClusterNode(
                id: cid,
                revision: rev,
                rowOrder: row.integer(4) ?? 0,
                centroid: storedCentroid,
                sampleCount: row.integer(3) ?? 0,
                memberIndices: [],
                confirmedPeople: [],
                rejectedPeople: [],
                profileAnchor: nil)
        }

        for idx in items.indices {
            let cid = items[idx].clusterID
            if nodes[cid] == nil {
                nodes[cid] = ClusterNode(
                    id: cid, revision: items[idx].revision, rowOrder: Int64.max,
                    centroid: items[idx].evidence.embedding, sampleCount: 0,
                    memberIndices: [], confirmedPeople: [], rejectedPeople: [], profileAnchor: nil)
            }
            nodes[cid]!.memberIndices.append(idx)
            if let p = items[idx].confirmedPerson { nodes[cid]!.confirmedPeople.insert(p) }
            nodes[cid]!.rejectedPeople.formUnion(items[idx].rejectedPeople)
        }

        var sessionConesByRev: [String: VoiceprintCone] = [:]
        for rev in revisions {
            let cVecs = nodes.values.filter { $0.revision == rev && $0.sampleCount > 0 }.compactMap { VoiceprintPolicy.normalized($0.centroid) }
            if cVecs.count >= 3 {
                let voiced = items.filter { $0.revision == rev && VoiceprintPolicy.isLearnable($0.evidence, positive: false) }
                    .compactMap { VoiceprintPolicy.normalized($0.evidence.embedding) }
                if let cone = computeInMemorySessionCone(clusterVecs: cVecs, voicedEmbeddings: voiced) {
                    sessionConesByRev[rev] = cone
                }
            }
        }

        func recomputeNode(_ node: inout ClusterNode) {
            let members = node.memberIndices.map { items[$0] }
            let clean = members.filter { VoiceprintPolicy.isLearnable($0.evidence, positive: false) }
            let pool = clean.isEmpty ? members : clean
            if let dim = pool.first?.evidence.embedding.count, pool.allSatisfy({ $0.evidence.embedding.count == dim }) {
                var sum = Array(repeating: Float(0), count: dim)
                for m in pool {
                    let w = VoiceprintPolicy.weight(for: max(0.3, m.evidence.cleanSeconds))
                    for d in 0..<dim { sum[d] += w * m.evidence.embedding[d] }
                }
                if let norm = VoiceprintPolicy.normalized(sum) { node.centroid = norm }
            }
            node.sampleCount = Int64(min(clean.count, 32))
            if node.confirmedPeople.count == 1, let confirmed = node.confirmedPeople.first {
                node.profileAnchor = confirmed
            } else if VoiceprintPolicy.isValidDim(node.centroid.count) {
                let matched = VoiceprintMatcher.match(
                    node.centroid,
                    sessionCone: sessionConesByRev[node.revision],
                    cleanSeconds: max(3.0, Double(clean.count) * 2.0),
                    prepared: localBanks[node.revision] ?? [:])
                node.profileAnchor = matched.flatMap { node.rejectedPeople.contains($0) ? nil : $0 }
            } else {
                node.profileAnchor = nil
            }
        }

        var changed = false
        // Prune empty clusters first.
        let emptyClusterIDs = nodes.values.filter { $0.memberIndices.isEmpty }.map(\.id)
        for emptyID in emptyClusterIDs {
            nodes.removeValue(forKey: emptyID)
            try database.execute("DELETE FROM speaker_cluster_conflicts WHERE first_id=? OR second_id=?",
                [.text(emptyID.uuidString), .text(emptyID.uuidString)])
            try database.execute("DELETE FROM speaker_clusters WHERE id=?", [.text(emptyID.uuidString)])
            changed = true
        }

        var centroidUpdatedOnMultiSampleCluster = false
        for cid in Array(nodes.keys) {
            var node = nodes[cid]!
            let oldCount = node.sampleCount
            let oldCentroid = node.centroid
            recomputeNode(&node)
            nodes[cid] = node
            if node.sampleCount != oldCount
                || (oldCentroid.count == node.centroid.count && VoiceprintPolicy.isValidDim(oldCentroid.count)
                    && SpeakerEvidence.similarity(oldCentroid, node.centroid) < 0.999) {
                try database.execute("UPDATE speaker_clusters SET centroid=?,sample_count=? WHERE id=?",
                    [.blob(try WireJSON.encode(node.centroid)), .integer(node.sampleCount), .text(cid.uuidString)])
                if node.sampleCount >= 2 || oldCount >= 2 {
                    centroidUpdatedOnMultiSampleCluster = true
                }
            }
        }

        if changed || centroidUpdatedOnMultiSampleCluster {
            invalidateTransductiveVoiceprintCache()
        }
        guard nodes.count >= 2 else { return changed }

        // Load conflict graph among surviving session clusters.
        var conflicts: Set<String> = []
        func conflictKey(_ a: UUID, _ b: UUID) -> String {
            let s = [a.uuidString, b.uuidString].sorted()
            return s[0] + ":" + s[1]
        }
        let allConflicts = try database.rows(
            "SELECT first_id,second_id FROM speaker_cluster_conflicts WHERE first_id IN (SELECT id FROM speaker_clusters WHERE session_id=?) OR second_id IN (SELECT id FROM speaker_clusters WHERE session_id=?)",
            [.text(sessionID.uuidString), .text(sessionID.uuidString)])
        for row in allConflicts {
            if let u1 = UUID(uuidString: try row.requireString(0)),
               let u2 = UUID(uuidString: try row.requireString(1)) {
                conflicts.insert(conflictKey(u1, u2))
            }
        }

        // Constrained Agglomerative Hierarchical Clustering (AHC) loop.
        while nodes.count >= 2 {
            let keys = nodes.keys.sorted { a, b in
                let na = nodes[a]!, nb = nodes[b]!
                if (na.sampleCount > 0) != (nb.sampleCount > 0) { return na.sampleCount > 0 }
                return na.rowOrder < nb.rowOrder
            }
            // Compute live cluster-cone across remaining trusted nodes so distinct speakers in
            // a reverberant room never collapse into one cluster via raw common-mode similarity.
            let trustedVecs = keys.compactMap { k -> [Float]? in
                let n = nodes[k]!
                return n.sampleCount > 0 ? VoiceprintPolicy.normalized(n.centroid) : nil
            }
            var liveCone: VoiceprintCone?
            if let coneDim = trustedVecs.first?.count, trustedVecs.count >= 3,
               trustedVecs.allSatisfy({ $0.count == coneDim }) {
                var minP: Float = 1.0, maxP: Float = -1.0
                for i in 0..<trustedVecs.count {
                    for j in (i + 1)..<trustedVecs.count {
                        let s = SpeakerEvidence.similarity(trustedVecs[i], trustedVecs[j])
                        minP = min(minP, s)
                        maxP = max(maxP, s)
                    }
                }
                if minP >= 0.35, maxP <= 0.96 {
                    var m = Array(repeating: Float(0), count: coneDim)
                    let inv = 1.0 / Float(trustedVecs.count)
                    for v in trustedVecs {
                        for d in 0..<coneDim { m[d] += v[d] * inv }
                    }
                    let cn = sqrt(m.reduce(Float(0)) { $0 + $1 * $1 })
                    if cn >= 0.76 {
                        liveCone = VoiceprintCone(mean: m, strength: min(0.90, (cn - 0.72) / 0.20 * 0.90))
                    }
                }
            }

            var bestPair: (keep: UUID, absorb: UUID, sim: Float)?
            for i in 0..<keys.count {
                let a = nodes[keys[i]]!
                let dim = a.centroid.count
                guard VoiceprintPolicy.isValidDim(dim) else { continue }
                for j in (i + 1)..<keys.count {
                    let b = nodes[keys[j]]!
                    guard a.revision == b.revision, b.centroid.count == dim else { continue }
                    guard !conflicts.contains(conflictKey(a.id, b.id)) else { continue }
                    let combinedConfirmed = a.confirmedPeople.union(b.confirmedPeople)
                    guard combinedConfirmed.count <= 1 else { continue }
                    let allRejected = a.rejectedPeople.union(b.rejectedPeople)
                    if let confirmed = combinedConfirmed.first, allRejected.contains(confirmed) { continue }
                    if let pa = a.profileAnchor, let pb = b.profileAnchor, pa != pb { continue }
                    if let pa = a.profileAnchor, b.rejectedPeople.contains(pa) { continue }
                    if let pb = b.profileAnchor, a.rejectedPeople.contains(pb) { continue }

                    let sim = SpeakerEvidence.similarity(a.centroid, b.centroid)
                    let sameProfile = (a.profileAnchor != nil && a.profileAnchor == b.profileAnchor)
                    let oneProvisional = (a.sampleCount == 0 || b.sampleCount == 0)
                    let bothTrusted = (a.sampleCount > 0 && b.sampleCount > 0)
                    let minSim: Float
                    if dim == 192 {
                        if sameProfile {
                            minSim = 0.38
                        } else if oneProvisional && (a.sampleCount > 0 || b.sampleCount > 0) {
                            minSim = 0.44
                        } else if bothTrusted {
                            minSim = 0.46
                        } else {
                            minSim = 0.50
                        }
                    } else {
                        if sameProfile {
                            minSim = 0.75
                        } else if oneProvisional && (a.sampleCount > 0 || b.sampleCount > 0) {
                            minSim = 0.79
                        } else if bothTrusted {
                            minSim = 0.81
                        } else {
                            minSim = 0.83
                        }
                    }
                    guard sim >= minSim else { continue }
                    let coneFloor: Float = dim == 192 ? 0.25 : 0.30
                    if !sameProfile, let cone = liveCone ?? sessionConesByRev[a.revision],
                       let ca = cone.center(a.centroid), let cb = cone.center(b.centroid) {
                        guard SpeakerEvidence.similarity(ca, cb) >= coneFloor else { continue }
                    }
                    if bestPair == nil || sim > bestPair!.sim {
                        bestPair = (a.id, b.id, sim)
                    }
                }
            }
            guard let merge = bestPair, var keep = nodes[merge.keep], let absorb = nodes[merge.absorb] else { break }

            keep.memberIndices.append(contentsOf: absorb.memberIndices)
            keep.confirmedPeople.formUnion(absorb.confirmedPeople)
            keep.rejectedPeople.formUnion(absorb.rejectedPeople)
            for mIdx in absorb.memberIndices { items[mIdx].clusterID = keep.id }
            recomputeNode(&keep)
            nodes[keep.id] = keep
            nodes.removeValue(forKey: absorb.id)

            try database.execute("UPDATE speaker_observations SET cluster_id=? WHERE cluster_id=?",
                [.text(keep.id.uuidString), .text(absorb.id.uuidString)])
            try database.execute("UPDATE speaker_clusters SET centroid=?,sample_count=? WHERE id=?",
                [.blob(try WireJSON.encode(keep.centroid)), .integer(keep.sampleCount), .text(keep.id.uuidString)])

            // Transfer cannot-link edges from absorbed cluster onto surviving cluster.
            let absorbConflictRows = try database.rows(
                "SELECT first_id,second_id FROM speaker_cluster_conflicts WHERE first_id=? OR second_id=?",
                [.text(absorb.id.uuidString), .text(absorb.id.uuidString)])
            for row in absorbConflictRows {
                let first = try row.requireUUID(0), second = try row.requireUUID(1)
                let other = first == absorb.id ? second : first
                if other != keep.id {
                    try separateSpeakerClusters(keep.id, other)
                    conflicts.insert(conflictKey(keep.id, other))
                }
            }
            try database.execute("DELETE FROM speaker_cluster_conflicts WHERE first_id=? OR second_id=?",
                [.text(absorb.id.uuidString), .text(absorb.id.uuidString)])
            try database.execute("DELETE FROM speaker_clusters WHERE id=?", [.text(absorb.id.uuidString)])
            changed = true
        }
        if changed {
            invalidateTransductiveVoiceprintCache()
        }
        return changed
    }

    func labeledSpeakerSpans(_ spans: [TranscriptSpan], sessionID: UUID) throws -> [TranscriptSpan] {
        let cache = try ensureBaseVoiceprintCache()
        var preparedBanks = cache.basePrepared
        return try labeledSpeakerSpans(spans, sessionID: sessionID, people: cache.people, preparedBanks: &preparedBanks)
    }

    public func forgetVoiceprint(personID: UUID) throws {
        try speakerTransaction {
            let owner = try voicePeople().first { $0.id == personID }?.owner == true
            try database.execute("UPDATE speaker_observations SET confirmed_person=NULL WHERE confirmed_person=?", [.text(personID.uuidString)])
            try database.execute("UPDATE speaker_feedback_anchors SET confirmed_person=NULL WHERE confirmed_person=?", [.text(personID.uuidString)])
            if owner { try database.execute("UPDATE speaker_observations SET rejected_owner=0") }
            try database.execute("DELETE FROM voice_profiles WHERE id=?", [.text(personID.uuidString)])
            invalidateVoiceprintCache()
            try refreshSpeakerMatches()
        }
    }

    /// Manually re-runs cluster reconciliation and two-pass global voiceprint propagation across all recordings.
    @discardableResult
    public func rematchAllSpeakers() throws -> Int {
        try speakerTransaction {
            invalidateVoiceprintCache()
            let allSessions = Set(try database.rows("""
                SELECT DISTINCT o.session_id
                FROM speaker_observations o
                JOIN sessions s ON s.id=o.session_id
                WHERE s.deleted=0
                """).map { try $0.requireUUID(0) })
            try refreshSpeakerMatches(editedSessions: allSessions)
            return try matchedSpeakerObservationCount()
        }
    }

    /// Prepares the voiceprint feature banks up front and returns ordered session IDs so UI callers
    /// can report determinate progress and ETA immediately while cluster reconciliation runs per step.
    public func prepareFullSpeakerRematch() throws -> FullSpeakerRematchPlan {
        try speakerTransaction {
            invalidateVoiceprintCache()
            _ = try ensureBaseVoiceprintCache()
            invalidateTransductiveVoiceprintCache()
            _ = try ensureEnrichedPreparedBanks()
            let sessionIDs = try database.rows("""
                SELECT s.id
                FROM sessions s
                WHERE s.deleted=0 AND EXISTS (SELECT 1 FROM speaker_observations o WHERE o.session_id=s.id)
                ORDER BY s.rowid DESC
                """).map { try $0.requireUUID(0) }
            let observationCount = Int(try database.rows("""
                SELECT COUNT(*)
                FROM speaker_observations o
                JOIN sessions s ON s.id=o.session_id
                WHERE s.deleted=0
                """).first?.integer(0) ?? 0)
            return FullSpeakerRematchPlan(sessionIDs: sessionIDs, totalObservationCount: observationCount)
        }
    }

    /// Reconciles clusters and re-labels a bounded batch of sessions using the prepared voiceprint banks,
    /// returning how many sessions changed.
    public func rematchSpeakerSessionsStep(_ sessionIDs: [UUID]) throws -> Int {
        guard !sessionIDs.isEmpty else { return 0 }
        let updatedCount = try speakerTransaction {
            let baseCache = try ensureBaseVoiceprintCache()
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            let multiClusterRows = try database.rows("""
                SELECT c.session_id
                FROM speaker_clusters c
                JOIN sessions s ON s.id=c.session_id
                WHERE s.deleted=0 AND c.model_revision!='manual-label'
                  AND c.session_id IN (\(placeholders))
                GROUP BY c.session_id
                HAVING COUNT(*) >= 2
                """, sessionIDs.map { .text($0.uuidString) })
            for row in multiClusterRows {
                let sid = try row.requireUUID(0)
                if try reconcileSpeakerClusters(sessionID: sid, preparedBanks: baseCache.basePrepared) {
                    invalidateTransductiveVoiceprintCache()
                }
            }
            var enrichedPrepared = try ensureEnrichedPreparedBanks()
            let people = baseCache.people
            var count = 0
            for id in sessionIDs {
                guard try !sessionIsDeleted(id),
                      let document = try currentTranscriptOrNil(sessionID: id) else { continue }
                let spans = try labeledSpeakerSpans(document.spans, sessionID: id, people: people, preparedBanks: &enrichedPrepared)
                if spans != document.spans {
                    try storeDocument(
                        TranscriptDocument(
                            sessionID: id,
                            version: document.version + 1,
                            generation: document.generation,
                            spans: spans,
                            updatedAt: Date()),
                        invalidatesExistingSources: true,
                        knownPrevious: .some(document))
                    count += 1
                }
            }
            return count
        }
        pendingSpeakerRematchSessionIDs.subtract(sessionIDs)
        return updatedCount
    }

    public func matchedSpeakerObservationCount() throws -> Int {
        let count = try database.rows("""
            SELECT COUNT(*)
            FROM speaker_observations o
            JOIN sessions s ON s.id=o.session_id
            WHERE s.deleted=0 AND (o.confirmed_person IS NOT NULL OR o.matched_person IS NOT NULL)
            """).first?.integer(0) ?? 0
        return Int(count)
    }

    /// Harvests high-confidence multi-turn cluster centroids across recordings as domain-bridged
    /// prototypes (e.g. bridging near-field iPhone enrollments to far-field Watch / room recordings).
    private func harvestTransductiveClusterExamples(
        baseExamples: [String: [VoiceprintExample]],
        basePrepared: [String: [Int: VoiceprintMatcher.PreparedBank]]
    ) throws -> [String: [VoiceprintExample]] {
        guard !basePrepared.isEmpty else { return baseExamples }
        let clusterRows = try database.rows("""
            SELECT c.session_id,c.model_revision,c.centroid,c.sample_count,
                   (SELECT GROUP_CONCAT(DISTINCT o.confirmed_person) FROM speaker_observations o WHERE o.cluster_id=c.id AND o.confirmed_person IS NOT NULL),
                   (SELECT GROUP_CONCAT(DISTINCT r.person_id) FROM voice_rejections r JOIN speaker_observations o ON o.span_id=r.span_id WHERE o.cluster_id=c.id)
            FROM speaker_clusters c
            JOIN sessions s ON s.id=c.session_id
            WHERE s.deleted=0 AND c.model_revision!='manual-label' AND c.sample_count>=2
            """)
        struct BridgedCandidate {
            let revision: String
            let person: UUID
            let sessionID: String
            let centroid: [Float]
            let score: Float
        }
        var candidatesByKey: [String: [BridgedCandidate]] = [:]
        for row in clusterRows {
            let sessStr = try row.requireString(0)
            let rev = try row.requireString(1)
            guard let revBanks = basePrepared[rev], !revBanks.isEmpty,
                  let rawCentroid = try? WireJSON.decode([Float].self, from: row.requireData(2)),
                  let normCentroid = VoiceprintPolicy.normalized(rawCentroid),
                  let dimBank = revBanks[normCentroid.count] else { continue }
            let dim = normCentroid.count
            let confirmedList = (row.string(4) ?? "")
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
            if confirmedList.count > 1 { continue }
            let rejectedSet = Set((row.string(5) ?? "")
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) })
            let enrolledPeople = Set(dimBank.people.map(\.person))
            let affinities = VoiceprintMatcher.rawPersonAffinities(normCentroid, prepared: revBanks)

            if let soleConfirmed = confirmedList.first {
                guard enrolledPeople.contains(soleConfirmed),
                      !rejectedSet.contains(soleConfirmed) else { continue }
                let selfAff = affinities[soleConfirmed] ?? -1
                let otherMax = affinities.compactMap { $0.key == soleConfirmed ? nil : $0.value }.max() ?? -1
                let minSelf: Float = dim == 192 ? 0.42 : 0.78
                if selfAff >= minSelf && (otherMax < 0 || selfAff >= otherMax + 0.06) {
                    let key = "\(rev)|\(soleConfirmed.uuidString)"
                    candidatesByKey[key, default: []].append(BridgedCandidate(
                        revision: rev, person: soleConfirmed, sessionID: sessStr, centroid: normCentroid, score: selfAff + 0.1))
                }
            } else {
                guard let matched = VoiceprintMatcher.match(
                    normCentroid, cleanSeconds: 4.0, prepared: revBanks),
                      !rejectedSet.contains(matched) else { continue }
                let selfAff = affinities[matched] ?? -1
                let otherMax = affinities.compactMap { $0.key == matched ? nil : $0.value }.max() ?? -1
                let minBridgeAff: Float = dim == 192 ? 0.46 : 0.82
                let minBridgeMargin: Float = dim == 192 ? 0.09 : 0.08
                if selfAff >= minBridgeAff && (otherMax < 0 || selfAff - otherMax >= minBridgeMargin) {
                    let key = "\(rev)|\(matched.uuidString)"
                    candidatesByKey[key, default: []].append(BridgedCandidate(
                        revision: rev, person: matched, sessionID: sessStr, centroid: normCentroid, score: selfAff))
                }
            }
        }
        guard !candidatesByKey.isEmpty else { return baseExamples }
        var enriched = baseExamples
        for (_, items) in candidatesByKey {
            let top = items.sorted { $0.score > $1.score }.prefix(6)
            for c in top {
                enriched[c.revision, default: []].append(VoiceprintExample(
                    person: c.person,
                    embedding: c.centroid,
                    positive: true,
                    cleanSeconds: 1.2,
                    spanDuration: 3.0,
                    batchKey: "bridge:\(c.sessionID)"))
            }
        }
        return enriched
    }

    /// Re-evaluate session clusters and inferred labels after feedback; confirmed labels remain authoritative.
    func refreshSpeakerMatches(editedSessions: Set<UUID> = []) throws {
        let baseCache = try ensureBaseVoiceprintCache()
        let people = baseCache.people
        let basePrepared = baseCache.basePrepared

        // Only multi-cluster sessions (or sessions just edited) can merge/prune clusters in AHC.
        var sessionsToReconcile = editedSessions
        for row in try database.rows("""
            SELECT c.session_id
            FROM speaker_clusters c
            JOIN sessions s ON s.id=c.session_id
            WHERE s.deleted=0 AND c.model_revision!='manual-label'
            GROUP BY c.session_id
            HAVING COUNT(*) >= 2
            """) {
            sessionsToReconcile.insert(try row.requireUUID(0))
        }
        for sessionID in sessionsToReconcile {
            _ = try reconcileSpeakerClusters(sessionID: sessionID, preparedBanks: basePrepared)
        }

        // Pass 2: enrich voiceprint bank with high-confidence multi-turn session cluster prototypes
        // so confirming 1 turn propagates across all recordings and device channels automatically.
        invalidateTransductiveVoiceprintCache()
        var enrichedPrepared = try ensureEnrichedPreparedBanks()

        let sessions = try database.rows("SELECT DISTINCT o.session_id FROM speaker_observations o JOIN sessions s ON s.id=o.session_id WHERE s.deleted=0")
        for session in sessions {
            let id = try session.requireUUID(0)
            guard let document = try currentTranscriptOrNil(sessionID: id) else { continue }
            let spans = try labeledSpeakerSpans(document.spans, sessionID: id, people: people, preparedBanks: &enrichedPrepared)
            if spans != document.spans {
                // A label revision invalidates citations but does not cancel unrelated ASR work.
                try storeDocument(
                    TranscriptDocument(
                        sessionID: id,
                        version: document.version + 1,
                        generation: document.generation,
                        spans: spans,
                        updatedAt: Date()),
                    invalidatesExistingSources: true,
                    knownPrevious: .some(document))
            }
        }
        pendingSpeakerRematchSessionIDs.removeAll()
    }

    public func resolveCurrentSpeakerSources(_ sources: [SourceReference]) throws -> [SourceReference] {
        guard !sources.isEmpty, sources.count <= Self.maximumSourceReferences else { throw ArchiveError.invalidQuery }
        var currentBySession: [UUID: (doc: TranscriptDocument, spans: [UUID: TranscriptSpan])] = [:]
        for sessionID in Set(sources.map(\.sessionID)) {
            let doc = try readTranscript(sessionID: sessionID)
            let map = Dictionary(uniqueKeysWithValues: doc.spans.map { ($0.id, $0) })
            currentBySession[sessionID] = (doc, map)
        }
        return try sources.map { source in
            guard let entry = currentBySession[source.sessionID],
                  entry.doc.generation == source.generation,
                  let span = entry.spans[source.spanID] else {
                throw ArchiveError.staleSource
            }
            return entry.doc.source(for: span)
        }
    }

    /// Resolves citations to the current transcript version ONLY when `generation`, `chunkID`, `frames`,
    /// `sourceRanges`, and `text` are unchanged since the cited version (e.g., speaker-label-only updates
    /// or subsequent span appends). Any edit to text or audio frame ranges still throws `ArchiveError.staleSource`.
    public func resolveAudioCompatibleSources(_ sources: [SourceReference]) throws -> [SourceReference] {
        guard !sources.isEmpty, sources.count <= Self.maximumSourceReferences else { throw ArchiveError.invalidQuery }
        var resolvedByIndex = Array<SourceReference?>(repeating: nil, count: sources.count)
        let indexed = Array(sources.enumerated())
        for (sessionID, sessionItems) in Dictionary(grouping: indexed, by: { $0.element.sessionID }) {
            let current = try readTranscript(sessionID: sessionID)
            var currentSpans: [UUID: TranscriptSpan] = [:]
            var currentIndices: [UUID: Int] = [:]
            currentSpans.reserveCapacity(current.spans.count)
            currentIndices.reserveCapacity(current.spans.count)
            for (idx, span) in current.spans.enumerated() {
                currentSpans[span.id] = span
                currentIndices[span.id] = idx
            }
            for (version, versionItems) in Dictionary(grouping: sessionItems, by: { $0.element.transcriptVersion }) {
                if version == current.version {
                    for (outIdx, source) in versionItems {
                        guard source.generation == current.generation,
                              let span = currentSpans[source.spanID] else {
                            throw ArchiveError.staleSource
                        }
                        resolvedByIndex[outIdx] = current.source(for: span)
                    }
                    continue
                }
                guard version > 0, version < current.version,
                      let row = try database.rows(
                          "SELECT document FROM transcript_versions WHERE session_id=? AND version=?",
                          [.text(current.sessionID.uuidString), .integer(version)]
                      ).first else {
                    throw ArchiveError.staleSource
                }
                let neededIDs = Set(versionItems.map { $0.element.spanID })
                let hints = neededIDs.compactMap { currentIndices[$0] }
                let citedSpans = try decodeStoredTranscriptSpans(
                    row.requireData(0),
                    expectedGeneration: current.generation,
                    spanIDs: neededIDs,
                    hintIndices: hints
                )
                for (outIdx, source) in versionItems {
                    guard source.generation == current.generation,
                          let currentSpan = currentSpans[source.spanID],
                          let citedSpan = citedSpans[source.spanID],
                          citedSpan.chunkID == currentSpan.chunkID,
                          citedSpan.frames == currentSpan.frames,
                          citedSpan.sourceRanges == currentSpan.sourceRanges,
                          citedSpan.text == currentSpan.text else {
                        throw ArchiveError.staleSource
                    }
                    resolvedByIndex[outIdx] = current.source(for: currentSpan)
                }
            }
        }
        return try resolvedByIndex.map {
            guard let value = $0 else { throw ArchiveError.staleSource }
            return value
        }
    }

    private func rematchSessionsDeferringOthers(immediateSessions: Set<UUID>) throws {
        let baseCache = try ensureBaseVoiceprintCache()
        for sessionID in immediateSessions {
            _ = try reconcileSpeakerClusters(sessionID: sessionID, preparedBanks: baseCache.basePrepared)
        }
        invalidateTransductiveVoiceprintCache()
        var immediatePrepared = baseCache.basePrepared
        let people = baseCache.people
        for id in immediateSessions {
            guard try !sessionIsDeleted(id),
                  let document = try currentTranscriptOrNil(sessionID: id) else { continue }
            let spans = try labeledSpeakerSpans(document.spans, sessionID: id, people: people, preparedBanks: &immediatePrepared)
            if spans != document.spans {
                try storeDocument(
                    TranscriptDocument(
                        sessionID: id,
                        version: document.version + 1,
                        generation: document.generation,
                        spans: spans,
                        updatedAt: Date()),
                    invalidatesExistingSources: true,
                    knownPrevious: .some(document))
            }
        }
        let allObserved = try database.rows("""
            SELECT DISTINCT o.session_id
            FROM speaker_observations o
            JOIN sessions s ON s.id=o.session_id
            WHERE s.deleted=0 AND o.confirmed_person IS NULL
            """)
        for row in allObserved {
            pendingSpeakerRematchSessionIDs.insert(try row.requireUUID(0))
        }
    }

    public func rematchPendingSpeakerSessionsBatch(limit: Int = 6) throws -> (updatedSessions: Int, hasMore: Bool) {
        guard !pendingSpeakerRematchSessionIDs.isEmpty else {
            return (updatedSessions: 0, hasMore: false)
        }
        let batchLimit = max(1, limit)
        let batchIDs = Array(
            pendingSpeakerRematchSessionIDs
                .sorted { $0.uuidString < $1.uuidString }
                .prefix(batchLimit)
        )
        let updatedCount = try speakerTransaction {
            let baseCache = try ensureBaseVoiceprintCache()
            let placeholders = Array(repeating: "?", count: batchIDs.count).joined(separator: ",")
            let multiClusterRows = try database.rows("""
                SELECT c.session_id
                FROM speaker_clusters c
                JOIN sessions s ON s.id=c.session_id
                WHERE s.deleted=0 AND c.model_revision!='manual-label'
                  AND c.session_id IN (\(placeholders))
                GROUP BY c.session_id
                HAVING COUNT(*) >= 2
                """, batchIDs.map { .text($0.uuidString) })
            for row in multiClusterRows {
                let sid = try row.requireUUID(0)
                if try reconcileSpeakerClusters(sessionID: sid, preparedBanks: baseCache.basePrepared) {
                    invalidateTransductiveVoiceprintCache()
                }
            }
            var enrichedPrepared = try ensureEnrichedPreparedBanks()
            let people = baseCache.people
            var count = 0
            for id in batchIDs {
                guard try !sessionIsDeleted(id),
                      let document = try currentTranscriptOrNil(sessionID: id) else { continue }
                let spans = try labeledSpeakerSpans(document.spans, sessionID: id, people: people, preparedBanks: &enrichedPrepared)
                if spans != document.spans {
                    try storeDocument(
                        TranscriptDocument(
                            sessionID: id,
                            version: document.version + 1,
                            generation: document.generation,
                            spans: spans,
                            updatedAt: Date()),
                        invalidatesExistingSources: true,
                        knownPrevious: .some(document))
                    count += 1
                }
            }
            return count
        }
        pendingSpeakerRematchSessionIDs.subtract(batchIDs)
        return (updatedSessions: updatedCount, hasMore: !pendingSpeakerRematchSessionIDs.isEmpty)
    }

    private func labeledSpeakerSpans(_ spans: [TranscriptSpan], sessionID id: UUID, people: [Person],
                                     preparedBanks: inout [String: [Int: VoiceprintMatcher.PreparedBank]]) throws -> [TranscriptSpan] {
        var clusterCentroids: [UUID: (revision: String, centroid: [Float], count: Int64)] = [:]
        var clusterNumbers: [UUID: Int] = [:]
        var ordinal = 0
        for cRow in try database.rows("SELECT id,model_revision,centroid,sample_count FROM speaker_clusters WHERE session_id=? ORDER BY rowid ASC", [.text(id.uuidString)]) {
            ordinal += 1
            let cid = try cRow.requireUUID(0)
            let rev = try cRow.requireString(1)
            let vec = (try? WireJSON.decode([Float].self, from: cRow.requireData(2))) ?? []
            clusterNumbers[cid] = ordinal
            clusterCentroids[cid] = (rev, vec, cRow.integer(3) ?? 0)
        }

        let obsRows = try database.rows(
            "SELECT span_id,cluster_id,model_revision,evidence,confirmed_person,matched_person FROM speaker_observations WHERE session_id=?",
            [.text(id.uuidString)])
        guard !obsRows.isEmpty else { return spans }

        var rejectionsBySpan: [UUID: Set<UUID>] = [:]
        for rRow in try database.rows(
            "SELECT r.span_id,r.person_id FROM voice_rejections r JOIN speaker_observations o ON o.span_id=r.span_id WHERE o.session_id=?",
            [.text(id.uuidString)]) {
            if let s = UUID(uuidString: try rRow.requireString(0)),
               let p = UUID(uuidString: try rRow.requireString(1)) {
                rejectionsBySpan[s, default: []].insert(p)
            }
        }

        struct DecodedObs {
            let spanID: UUID
            let clusterID: UUID
            let revision: String
            let evidence: SpeakerEvidence?
            let confirmed: UUID?
            let oldMatched: UUID?
        }

        var decoded: [DecodedObs] = []
        decoded.reserveCapacity(obsRows.count)
        var clusterConfirmed: [UUID: Set<UUID>] = [:]
        var clusterRejected: [UUID: Set<UUID>] = [:]
        var confirmedVectorSums: [UUID: [Float]] = [:]

        for row in obsRows {
            let spanID = try row.requireUUID(0)
            let clusterID = try row.requireUUID(1)
            let revision = try row.requireString(2)
            let ev = try decodeCachedSpeakerEvidence(sessionID: id, spanID: spanID, data: row.requireData(3))
            let confirmed = row.string(4).flatMap(UUID.init(uuidString:))
            let oldMatched = row.string(5).flatMap(UUID.init(uuidString:))
            if let rejs = rejectionsBySpan[spanID] {
                clusterRejected[clusterID, default: []].formUnion(rejs)
            }
            if let confirmed {
                clusterConfirmed[clusterID, default: []].insert(confirmed)
                if let ev, ev.hasVoiceprint {
                    let dim = ev.embedding.count
                    let w = VoiceprintPolicy.weight(for: max(0.3, ev.cleanSeconds))
                    var sum = confirmedVectorSums[clusterID] ?? Array(repeating: Float(0), count: dim)
                    if sum.count == dim {
                        for d in 0..<dim { sum[d] += w * ev.embedding[d] }
                        confirmedVectorSums[clusterID] = sum
                    }
                }
            }
            if preparedBanks[revision] == nil && revision != "manual-label" && ContentHash.isValid(revision) {
                preparedBanks[revision] = try cachedBasePreparedBank(for: revision)
            }
            decoded.append(DecodedObs(spanID: spanID, clusterID: clusterID, revision: revision,
                                      evidence: ev, confirmed: confirmed, oldMatched: oldMatched))
        }

        var confirmedCentroids: [UUID: [Float]] = [:]
        for (cid, sum) in confirmedVectorSums {
            if let norm = VoiceprintPolicy.normalized(sum) { confirmedCentroids[cid] = norm }
        }

        var sessionCones: [String: VoiceprintCone] = [:]
        for rev in Set(decoded.map(\.revision)) where rev != "manual-label" {
            let cVecs = clusterCentroids.values
                .filter { $0.revision == rev && $0.count > 0 }
                .compactMap { VoiceprintPolicy.normalized($0.centroid) }
            if cVecs.count >= 3 {
                let voiced = decoded.compactMap { item -> [Float]? in
                    guard item.revision == rev, let ev = item.evidence,
                          VoiceprintPolicy.isLearnable(ev, positive: false) else { return nil }
                    return VoiceprintPolicy.normalized(ev.embedding)
                }
                if let cone = computeInMemorySessionCone(clusterVecs: cVecs, voicedEmbeddings: voiced) {
                    sessionCones[rev] = cone
                }
            }
        }

        // Precompute cluster-level matched identity so short/noisy sibling turns in a well-matched
        // cluster inherit coherent speaker attribution instead of fragmenting back to "说话人 N".
        var clusterMatchedPerson: [UUID: UUID] = [:]
        for (cid, info) in clusterCentroids where info.revision != "manual-label" {
            if let cSet = clusterConfirmed[cid], cSet.count == 1, let sole = cSet.first,
               !(clusterRejected[cid]?.contains(sole) ?? false) {
                clusterMatchedPerson[cid] = sole
            } else if info.count > 0, VoiceprintPolicy.isValidDim(info.centroid.count) {
                if let matched = VoiceprintMatcher.match(
                    info.centroid,
                    sessionCone: sessionCones[info.revision],
                    cleanSeconds: max(3.0, Double(info.count) * 1.5),
                    prepared: preparedBanks[info.revision] ?? [:]),
                   !(clusterRejected[cid]?.contains(matched) ?? false) {
                    clusterMatchedPerson[cid] = matched
                }
            }
        }

        var updated: [UUID: (String?, SpeakerAttribution?)] = [:]
        updated.reserveCapacity(decoded.count)
        for obs in decoded {
            let sessCone = sessionCones[obs.revision]
            let clusterInfo = clusterCentroids[obs.clusterID]
            let validClusterVec = (clusterInfo?.count ?? 0) > 0 ? clusterInfo?.centroid : nil
            let revPrepared = preparedBanks[obs.revision] ?? [:]

            var person = obs.confirmed
            if person == nil, let ev = obs.evidence, ev.hasVoiceprint {
                person = VoiceprintMatcher.match(
                    ev.embedding,
                    clusterCentroid: validClusterVec,
                    sessionCone: sessCone,
                    cleanSeconds: max(0.3, ev.cleanSeconds),
                    prepared: revPrepared)
                // Intra-cluster coherence: propagate unambiguous cluster identity (either user-confirmed
                // or matched cluster centroid) to acoustically aligned sibling turns in the same cluster.
                if person == nil, let clusterPerson = clusterMatchedPerson[obs.clusterID] {
                    let dim = ev.embedding.count
                    let hasConfirmedAnchor = confirmedCentroids[obs.clusterID] != nil
                    let anchor = confirmedCentroids[obs.clusterID] ?? clusterInfo?.centroid
                    let minAnchorSim: Float
                    if dim == 192 {
                        minAnchorSim = hasConfirmedAnchor ? 0.35 : 0.38
                    } else {
                        minAnchorSim = hasConfirmedAnchor ? 0.80 : 0.83
                    }
                    if let anchor, anchor.count == dim,
                       SpeakerEvidence.similarity(ev.embedding, anchor) >= minAnchorSim {
                        let affinities = VoiceprintMatcher.rawPersonAffinities(ev.embedding, prepared: revPrepared)
                        let selfAff = affinities[clusterPerson] ?? 1.0
                        let rivalMax = affinities.compactMap { $0.key == clusterPerson ? nil : $0.value }.max() ?? -1.0
                        let coneOK: Bool
                        if let cone = sessCone, let ce = cone.center(ev.embedding), let ca = cone.center(anchor) {
                            coneOK = SpeakerEvidence.similarity(ce, ca) >= (dim == 192 ? 0.25 : 0.35)
                        } else {
                            coneOK = true
                        }
                        if coneOK && selfAff >= rivalMax {
                            person = clusterPerson
                        }
                    }
                }
            }
            if obs.confirmed == nil, let candidate = person,
               rejectionsBySpan[obs.spanID]?.contains(candidate) == true {
                person = nil
            }
            // Note: attribution.canLearn reports raw VoiceprintPolicy.minLearnableCleanSeconds for UI/API invariants,
            // while voiceExamples() additionally admits 192-dim >= 0.42 s clean positive exemplars.
            let learnable = obs.evidence.map { $0.hasVoiceprint && $0.cleanSeconds >= VoiceprintPolicy.minLearnableCleanSeconds } ?? false
            updated[obs.spanID] = try speakerLabel(
                cluster: obs.clusterID,
                personID: person,
                confirmed: obs.confirmed != nil,
                learnable: learnable,
                people: people,
                clusterNumbers: clusterNumbers)
            let newMatched = obs.confirmed == nil ? person : obs.oldMatched
            if obs.confirmed != nil {
                if obs.oldMatched != person {
                    try database.execute("UPDATE speaker_observations SET matched_person=? WHERE span_id=?",
                        [person.map { .text($0.uuidString) } ?? .null, .text(obs.spanID.uuidString)])
                }
            } else if newMatched != obs.oldMatched {
                try database.execute("UPDATE speaker_observations SET matched_person=? WHERE span_id=?",
                    [newMatched.map { .text($0.uuidString) } ?? .null, .text(obs.spanID.uuidString)])
            }
        }

        var result: [TranscriptSpan] = []
        result.reserveCapacity(spans.count)
        for span in spans {
            let mapped = updated[span.id]
            let speaker = mapped != nil ? mapped!.0 : span.speaker
            let attribution = mapped != nil ? mapped!.1 : span.attribution
            var startsNewTurn = span.startsNewSpeakerTurn
            if mapped != nil, let prev = result.last,
               prev.chunkID == span.chunkID, prev.frames.end == span.frames.start,
               let prevAttr = prev.attribution, let currAttr = attribution {
                let sameSpeaker = prevAttr.personID != nil
                    ? prevAttr.personID == currAttr.personID
                    : (currAttr.personID == nil && prevAttr.clusterID == currAttr.clusterID)
                startsNewTurn = !sameSpeaker
            }
            result.append(TranscriptSpan(
                id: span.id, chunkID: span.chunkID, frames: span.frames, text: span.text,
                speaker: speaker, sourceRanges: span.sourceRanges, attribution: attribution,
                startsNewSpeakerTurn: startsNewTurn))
        }
        return result
    }
}
