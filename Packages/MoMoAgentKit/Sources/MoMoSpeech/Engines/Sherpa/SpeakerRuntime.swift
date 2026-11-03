import Foundation
import MoMoContracts
import MoMoSherpaBridge

private func speakerAttemptIsCancelled(_ raw: UnsafeRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let attempt = Unmanaged<SpeechAttempt>.fromOpaque(raw).takeUnretainedValue()
    return attempt.pollCancellationOrPace() ? 1 : 0
}

/// Queue-confined 3D-Speaker ERes2NetV2 (192-d) + configurable DiariZen / PyAnnote Community-1 segmentation on ORT CPU.
final class SpeakerRuntime: @unchecked Sendable {
    static let revision = "bf1a75b9930474cf3389ef415e6e5d38ca96fea4a3a00f7e301d080a58ee2239"
    private static let stitchedBlockSamples = 640_000
    let segmentationModel: SpeakerSegmentationModel
    let embeddingDim: Int
    private let handle: OpaquePointer
    init(directory: URL, segmentationModel: SpeakerSegmentationModel = .diariZenWavLMBase,
         cacheRoot: URL?, attempt: SpeechAttempt, threads: Int = 2,
         skipValidation: Bool = false) throws {
        let files = [("eres2netv2.onnx", Self.revision),
                     (segmentationModel.filename, segmentationModel.sha256)]
        if !skipValidation {
            for (file, hash) in files {
                try attempt.checkCancellation()
                guard try speechFileHash(directory.appendingPathComponent(file), attempt: attempt,
                    recorder: nil, model: true) == hash else {
                    throw SpeechError.modelHashMismatch(file)
                }
            }
        }
        _ = cacheRoot
        var error = [CChar](repeating: 0, count: 2048)
        guard let handle = MoMoCreateSpeakerRuntimeWithThreads(
            directory.appendingPathComponent(files[1].0).path,
            directory.appendingPathComponent(files[0].0).path,
            "cpu", Int32(max(1, min(6, threads))), &error, error.count) else {
            throw SpeechNativeFailure(stage: .load, detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        let dim = Int(MoMoGetSpeakerEmbeddingDim(handle))
        guard dim == 192 || dim == 256 else {
            MoMoDestroySpeakerRuntime(handle)
            throw SpeechError.invalidModelManifest
        }
        self.segmentationModel = segmentationModel
        self.embeddingDim = dim
        self.handle = handle
    }
    deinit { MoMoDestroySpeakerRuntime(handle) }

    func analyze(_ samples: [Float], prototypes: [EnrolledSpeakerPrototype] = [],
                 attempt: SpeechAttempt) throws -> [SpeakerEvidence] {
        try attempt.checkCancellation()
        var enrolledVectors: [Float] = []
        var enrolledPersonIDs: [Int32] = []
        var personIndexByUUID: [UUID: Int32] = [:]
        for item in prototypes.prefix(48) where item.modelRevision == Self.revision && item.embedding.count == embeddingDim
            && item.embedding.allSatisfy(\.isFinite) {
            let pid = personIndexByUUID[item.personID] ?? {
                let next = Int32(personIndexByUUID.count)
                personIndexByUUID[item.personID] = next
                return next
            }()
            enrolledVectors.append(contentsOf: item.embedding)
            enrolledPersonIDs.append(pid)
        }
        let enrolledCount = Int32(enrolledPersonIDs.count)

        var result: [SpeakerEvidence] = []
        var nextBucketOffset = 0
        for start in stride(from: 0, to: samples.count, by: Self.stitchedBlockSamples) {
            try attempt.checkCancellation()
            let count = min(Self.stitchedBlockSamples, samples.count - start)
            var turns = [MoMoSpeakerTurn](repeating: MoMoSpeakerTurn(), count: 1024)
            var error = [CChar](repeating: 0, count: 2048)
            let written = withExtendedLifetime(attempt) {
                let context = UnsafeRawPointer(Unmanaged.passUnretained(attempt).toOpaque())
                return withNativeCancelToken(attempt) { cancelToken in
                    samples.withUnsafeBufferPointer { buffer in
                        enrolledVectors.withUnsafeBufferPointer { vecBuf in
                            enrolledPersonIDs.withUnsafeBufferPointer { idBuf in
                                MoMoAnalyzeSpeakersWithProfilesCancellable(
                                    handle, buffer.baseAddress! + start, Int32(count),
                                    enrolledCount > 0 ? vecBuf.baseAddress : nil,
                                    enrolledCount > 0 ? idBuf.baseAddress : nil,
                                    enrolledCount,
                                    speakerAttemptIsCancelled, context, cancelToken,
                                    &turns, Int32(turns.count), &error, error.count)
                            }
                        }
                    }
                }
            }
            if written == -2 { throw SpeechError.cancelled }
            guard written >= 0 else {
                throw SpeechNativeFailure(stage: .decode, detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
            let blockOffset = nextBucketOffset
            var maxLocal = 0
            for var turn in turns.prefix(Int(written)) {
                if Int(turn.local_speaker) > maxLocal { maxLocal = Int(turn.local_speaker) }
                let dim = max(0, min(256, Int(turn.embedding_dim)))
                let vector = withUnsafeBytes(of: &turn.embedding) {
                    Array($0.bindMemory(to: Float.self).prefix(dim))
                }
                result.append(SpeakerEvidence(start: Double(start + Int(turn.start_sample)) / 16_000,
                    end: Double(start + Int(turn.end_sample)) / 16_000,
                    localSpeaker: turn.local_speaker < 0 ? -1 : blockOffset + Int(turn.local_speaker),
                    embedding: vector.contains(where: { $0 != 0 }) ? vector : [],
                    cleanSeconds: Double(turn.clean_seconds), modelRevision: Self.revision))
            }
            let usedBuckets = maxLocal > 0 ? ((maxLocal - 1) / 4 + 1) : 1
            nextBucketOffset += usedBuckets * 4
        }
        try attempt.checkCancellation()
        return result
    }

    func extractCleanVoiceprint(_ samples: [Float], attempt: SpeechAttempt) throws -> (embedding: [Float], cleanSeconds: Double)? {
        guard !samples.isEmpty else { return nil }
        try attempt.checkCancellation()
        var outEmbedding = [Float](repeating: 0, count: 256)
        var outCleanSeconds: Float = 0
        var error = [CChar](repeating: 0, count: 2048)
        let rc = withExtendedLifetime(attempt) {
            let context = UnsafeRawPointer(Unmanaged.passUnretained(attempt).toOpaque())
            return withNativeCancelToken(attempt) { cancelToken in
                samples.withUnsafeBufferPointer { buffer in
                    MoMoExtractCleanVoiceprintCancellable(
                        handle, buffer.baseAddress!, Int32(samples.count),
                        speakerAttemptIsCancelled, context, cancelToken,
                        &outEmbedding, Int32(outEmbedding.count), &outCleanSeconds,
                        &error, error.count)
                }
            }
        }
        if rc == -2 { throw SpeechError.cancelled }
        guard rc >= 0 else {
            throw SpeechNativeFailure(stage: .decode, detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        guard rc > 0 else { return nil }
        let vector = Array(outEmbedding.prefix(min(256, Int(rc))))
        guard vector.contains(where: { $0 != 0 }) else { return nil }
        return (vector, Double(outCleanSeconds))
    }
}
