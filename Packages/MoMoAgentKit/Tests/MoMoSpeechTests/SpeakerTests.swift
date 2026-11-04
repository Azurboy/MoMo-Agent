import Foundation
import SherpaOnnxC
import Testing
import MoMoContracts
import MoMoRecording
@testable import MoMoSpeech

struct SpeakerAlignmentTests {
    @Test func acousticTurnsSplitWithoutTokensAndKeepShortDifferentSpeakers() throws {
        let revision = String(repeating: "a", count: 64)
        func evidence(_ start: Double, _ end: Double, _ track: Int, vector: [Float] = []) -> SpeakerEvidence {
            .init(start: start, end: end, localSpeaker: track, embedding: vector, cleanSeconds: 0, modelRevision: revision)
        }
        let plan = SpeakerTurn.plan([evidence(0.2, 2, 1), evidence(2.3, 4, 1), evidence(4.1, 4.7, 2)], core: 0..<80_000)
        #expect(plan.count == 2)
        #expect(plan[0].frames.lowerBound == 0)
        #expect(plan[0].frames.upperBound == plan[1].frames.lowerBound)
        #expect(plan[1].frames.upperBound == 80_000)
        let timed = SpeechRecognition(windowID: "timed", text: "明天见嗯", tokens: ["明", "天", "见", "嗯"],
            timestamps: [0.5, 1, 3, 4.2], rawJSON: "{}", configurationFingerprint: "test")
        #expect(timed.alignedSpeakerTurns(plan)?.map(\.text) == ["明天见", "嗯"])
        let interjection = SpeechRecognition(windowID: "short", text: "过了嗯，但是", tokens: ["过", "了", "嗯", "，", "但", "是"],
            timestamps: [0.36, 0.48, 0.78, 0.96, 1.2, 1.32], rawJSON: "{}", configurationFingerprint: "test")
        let shortTurns = SpeakerTurn.plan([evidence(0, 0.79, 1), evidence(0.79, 1.14, 2), evidence(1.14, 2, 1)], core: 0..<32_000)
        #expect(interjection.alignedSpeakerTurns(shortTurns)?.map(\.text) == ["过了", "嗯，", "但是"])
        let frames = try FrameRange(start: 32_000, count: 80_000)
        let context = try FrameRange(start: 16_000, count: 112_000)
        let window = SpeechWindow(id: "w", sessionID: UUID(), epochID: UUID(), analysisAnchor: 0,
            coreFrames: frames, contextFrames: context, modelCoreFrames: frames, modelContextFrames: context,
            sources: [], replayInputManifestHashes: [], configurationFingerprint: "test")
        var result = SpeechRecognition(windowID: "w", text: "明天12点见。好。", tokens: [], timestamps: [], rawJSON: "{}", configurationFingerprint: "test")
        result.speakerTurns = [
            .init(text: "明天12点见。", start: 1, end: 5.05, evidence: plan[0].evidence),
            .init(text: "好。", start: 5.05, end: 6, evidence: plan[1].evidence)]
        #expect(result.textOwned(by: window) == result.text)
        let parts = try #require(try result.speakerParts(text: result.text, window: window))
        #expect(parts.map(\.text) == ["明天12点见。", "好。"])
        #expect(parts.first?.frames.start == frames.start)
        #expect(parts.last?.frames.end == frames.end)
        #expect(parts[0].frames.end == parts[1].frames.start)
        // Different tracks in the same block must not collapse even if their vectors look alike.
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        #expect(!SpeakerTurn.sameVoice(evidence(0, 2, 1, vector: vector), evidence(2, 4, 2, vector: vector)))
        #expect(!SpeakerTurn.sameVoice(evidence(8, 10, 1, vector: vector), evidence(10, 12, 4, vector: vector)))
        #expect(SpeakerTurn.sameVoice(evidence(8, 10, 1, vector: vector), evidence(10, 12, 5, vector: vector)))
        // Natural pause up to 6 s with no intervening speaker stays a single turn and pools clean duration.
        let pausedSameSpeaker = SpeakerTurn.plan([
            SpeakerEvidence(start: 0.2, end: 2.0, localSpeaker: 1, embedding: vector, cleanSeconds: 1.8, modelRevision: revision),
            SpeakerEvidence(start: 5.5, end: 7.5, localSpeaker: 1, embedding: vector, cleanSeconds: 2.0, modelRevision: revision)
        ], core: 0..<128_000)
        #expect(pausedSameSpeaker.count == 1)
        #expect((pausedSameSpeaker.first?.evidence.cleanSeconds ?? 0) >= 3.7)
        // Wordless background sound (0 ASR tokens) from another track must not split a speaker's continuous sentence.
        let wordlessBackground = SpeakerTurn.plan([
            SpeakerEvidence(start: 0.2, end: 1.5, localSpeaker: 1, embedding: vector, cleanSeconds: 1.2, modelRevision: revision),
            SpeakerEvidence(start: 1.6, end: 2.3, localSpeaker: 2, embedding: [], cleanSeconds: 0, modelRevision: revision),
            SpeakerEvidence(start: 2.4, end: 4.5, localSpeaker: 1, embedding: vector, cleanSeconds: 2.0, modelRevision: revision)
        ], core: 0..<76_800)
        let bridged = SpeechRecognition(windowID: "bridged", text: "就是我会有个接入方案",
            tokens: ["就", "是", "我", "会", "有", "个", "接", "入", "方", "案"],
            timestamps: [0.3, 0.5, 0.7, 0.9, 1.1, 1.3, 2.5, 2.8, 3.2, 3.6],
            rawJSON: "{}", configurationFingerprint: "test")
        let bridgedTurns = try #require(bridged.alignedSpeakerTurns(wordlessBackground))
        #expect(bridgedTurns.count == 1)
        #expect(bridgedTurns[0].text == "就是我会有个接入方案")
        #expect(bridgedTurns[0].evidence.cleanSeconds >= 3.1)
    }

    @Test func timingSplitsWithoutLosingTextAndDoesNotGuessThroughITN() throws {
        let range = try FrameRange(start: 0, count: 160_000)
        let window = SpeechWindow(id: "w", sessionID: UUID(), epochID: UUID(), analysisAnchor: 0,
            coreFrames: range, contextFrames: range, modelCoreFrames: range, modelContextFrames: range,
            sources: [], replayInputManifestHashes: [], configurationFingerprint: "test")
        var recognition = SpeechRecognition(windowID: "w", text: "你好世界", tokens: ["你", "好", "世", "界"],
            timestamps: [0.5, 2, 5, 7], rawJSON: "{}", configurationFingerprint: "test")
        recognition.speakers = [SpeakerEvidence(start: 0, end: 4, localSpeaker: 1,
            embedding: [1] + Array(repeating: 0, count: 255), cleanSeconds: 4, modelRevision: String(repeating: "a", count: 64)),
            SpeakerEvidence(start: 4, end: 9, localSpeaker: 2,
            embedding: [0, 1] + Array(repeating: 0, count: 254), cleanSeconds: 5, modelRevision: String(repeating: "a", count: 64))]
        let parts = try #require(try recognition.speakerParts(text: recognition.text, window: window))
        #expect(parts.map(\.text) == ["你好", "世界"])
        #expect(parts[0].frames.end == parts[1].frames.start)
        #expect(parts[0].evidence?.localSpeaker == 1)
        #expect(parts[1].evidence?.localSpeaker == 2)
        let transformed = SpeechRecognition(windowID: "w", text: "123", tokens: ["一", "二", "三"],
            timestamps: [1, 2, 3], rawJSON: "{}", configurationFingerprint: "test", speakers: recognition.speakers)
        #expect(try transformed.speakerParts(text: "123", window: window) == nil)
        var single = transformed
        single.speakers = Array(recognition.speakers!.prefix(1))
        #expect(try single.speakerParts(text: "123", window: window)?.first?.evidence?.localSpeaker == 1)
    }

    @Test func collarAndSentenceBoundarySnappingKeepSentencesWholeAcrossTurnJitter() throws {
        let revision = String(repeating: "b", count: 64)
        let v1: [Float] = [1] + Array(repeating: 0, count: 255)
        let v2: [Float] = [0, 1] + Array(repeating: 0, count: 254)
        let core = 16_000..<96_000
        let bounds = 0..<112_000
        let ev1 = SpeakerEvidence(start: 1.15, end: 3.00, localSpeaker: 1, embedding: v1, cleanSeconds: 1.85, modelRevision: revision)
        let ev2 = SpeakerEvidence(start: 3.30, end: 5.80, localSpeaker: 2, embedding: v2, cleanSeconds: 2.50, modelRevision: revision)
        let turns = SpeakerTurn.plan([ev1, ev2], core: core, sampleBounds: bounds)
        #expect(turns.count == 2)
        // Core partition stays exact and contiguous, while audioFrames expands into quiet margins without crossing speech.
        #expect(turns[0].frames.lowerBound == core.lowerBound)
        #expect(turns[0].frames.upperBound == turns[1].frames.lowerBound)
        #expect(turns[1].frames.upperBound == core.upperBound)
        #expect(turns[0].audioFrames.lowerBound < turns[0].frames.lowerBound)
        #expect(turns[0].audioFrames.upperBound <= Int((ev2.start * 16_000).rounded(.down)))
        #expect(turns[1].audioFrames.lowerBound >= Int((ev1.end * 16_000).rounded(.up)))

        // Midpoint is 3.15 s; "见"(3.18s) + "。"(3.24s) jittered slightly past midpoint should snap back to Speaker 1.
        let jittered = SpeechRecognition(
            windowID: "snap",
            text: "明天见。好的没问题。",
            tokens: ["明", "天", "见", "。", "好", "的", "没", "问", "题", "。"],
            timestamps: [1.10, 1.50, 3.18, 3.24, 3.45, 3.65, 4.00, 4.30, 4.60, 5.88],
            rawJSON: "{}",
            configurationFingerprint: "test",
            speakers: [ev1, ev2])
        #expect(jittered.alignedSpeakerTurns(turns)?.map(\.text) == ["明天见。", "好的没问题。"])

        let frameRange = try FrameRange(start: 16_000, count: 80_000)
        let ctxRange = try FrameRange(start: 0, count: 112_000)
        let window = SpeechWindow(id: "w-snap", sessionID: UUID(), epochID: UUID(), analysisAnchor: 0,
            coreFrames: frameRange, contextFrames: ctxRange, modelCoreFrames: frameRange, modelContextFrames: ctxRange,
            sources: [], replayInputManifestHashes: [], configurationFingerprint: "test")
        let parts = try #require(try jittered.speakerParts(text: jittered.text, window: window))
        // Leading onset 1.10s (50ms before 1.15s) and trailing "。" at 5.88s (80ms after 5.80s) must not create nil orphan parts.
        #expect(parts.count == 2)
        #expect(parts.map(\.text) == ["明天见。", "好的没问题。"])
        #expect(parts[0].evidence?.localSpeaker == 1)
        #expect(parts[1].evidence?.localSpeaker == 2)

        // Trailing unvoiced micro-fragment (< 0.35 s, empty embedding) of the same speaker must not erase singleSpeaker() attribution.
        var singleWithTail = SpeechRecognition(windowID: "single-tail", text: "好的收到。", tokens: [], timestamps: [], rawJSON: "{}", configurationFingerprint: "test")
        singleWithTail.speakers = [
            SpeakerEvidence(start: 1.10, end: 3.30, localSpeaker: 1, embedding: v1, cleanSeconds: 2.20, modelRevision: revision),
            SpeakerEvidence(start: 3.45, end: 3.68, localSpeaker: 1, embedding: [], cleanSeconds: 0, modelRevision: revision)
        ]
        let singleParts = try #require(try singleWithTail.speakerParts(text: singleWithTail.text, window: window))
        #expect(singleParts.count == 1)
        #expect(singleParts[0].evidence?.hasVoiceprint == true)
        #expect(singleParts[0].evidence?.localSpeaker == 1)
    }

    @Test func clausePunctuationSnappingAndMicroTurnConsolidationPreventOverSplitting() throws {
        let revision = String(repeating: "d", count: 64)
        let v1: [Float] = [1] + Array(repeating: 0, count: 191)
        let v2: [Float] = [0, 1] + Array(repeating: 0, count: 190)

        let commaTurns = SpeakerTurn.plan([
            SpeakerEvidence(start: 0.0, end: 2.00, localSpeaker: 1, embedding: v1, cleanSeconds: 1.9, modelRevision: revision),
            SpeakerEvidence(start: 2.00, end: 4.20, localSpeaker: 2, embedding: v2, cleanSeconds: 2.0, modelRevision: revision)
        ], core: 0..<67_200)
        let commaRecognition = SpeechRecognition(
            windowID: "comma-snap",
            text: "先看方案，下午讨论。",
            tokens: ["先", "看", "方", "案", "，", "下", "午", "讨", "论", "。"],
            timestamps: [0.40, 0.85, 1.35, 2.08, 2.15, 2.55, 2.95, 3.35, 3.75, 3.90],
            rawJSON: "{}",
            configurationFingerprint: "test"
        )
        #expect(commaRecognition.alignedSpeakerTurns(commaTurns)?.map(\.text) == ["先看方案，", "下午讨论。"])

        // Consolidate noisy Watch micro-turns (< 1.5s, < 0.9s clean speech) before turn-split ASR
        // while keeping genuine >= 1.5s distinct speakers intact.
        let fragmented = SpeakerTurn.plan([
            SpeakerEvidence(start: 0.00, end: 4.50, localSpeaker: 1, embedding: v1, cleanSeconds: 3.8, modelRevision: revision),
            SpeakerEvidence(start: 4.50, end: 5.20, localSpeaker: 3, embedding: [], cleanSeconds: 0.0, modelRevision: revision),
            SpeakerEvidence(start: 5.20, end: 5.95, localSpeaker: 1, embedding: v1, cleanSeconds: 0.5, modelRevision: revision),
            SpeakerEvidence(start: 5.95, end: 9.20, localSpeaker: 2, embedding: v2, cleanSeconds: 2.9, modelRevision: revision)
        ], core: 0..<147_200)
        #expect(fragmented.count >= 3)
        let consolidated = SpeakerTurn.consolidateForTurnDecoding(fragmented)
        #expect(consolidated.count == 2)
        #expect(consolidated[0].evidence.localSpeaker == 1)
        #expect(consolidated[1].evidence.localSpeaker == 2)
        #expect(consolidated[0].frames.lowerBound == 0)
        #expect(consolidated[1].frames.upperBound == 147_200)
    }

    @Test func multiSpeakerOverlapDeduplicationAndGapRecoveryPreserveTurnAttribution() throws {
        let revision = String(repeating: "c", count: 64)
        let v1: [Float] = [1] + Array(repeating: 0, count: 191)
        let v2: [Float] = [0, 1] + Array(repeating: 0, count: 190)
        let session = UUID(), epoch = UUID(), device = UUID()
        let manifest = try ChunkManifest(sessionID: session, epochID: epoch, sourceDeviceID: device,
            sourceBuild: "test", sequence: 0, frames: FrameRange(start: 0, count: 96_000), timebaseHz: 16_000,
            wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmInt16,
            sampleRate: 16_000, channels: 1, decodedFrameCount: 96_000, byteCount: 192_044,
            audioSHA256: String(repeating: "a", count: 64), sourceKind: .fixture)
        let input = try SpeechInputSet([SpeechAudioInput(envelope: ManifestEnvelope(manifest: manifest),
            audioURL: URL(fileURLWithPath: "/unused.wav"))], anchor: 0)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        let before = try planner.makeWindow(core: FrameRange(start: 0, count: 32_000),
            context: FrameRange(start: 0, count: 40_000), input: input)
        let after = try planner.makeWindow(core: FrameRange(start: 32_000, count: 48_000),
            context: FrameRange(start: 24_000, count: 56_000), input: input)

        let evA = SpeakerEvidence(start: 0.0, end: 2.2, localSpeaker: 1, embedding: v1, cleanSeconds: 2.0, modelRevision: revision)
        let evB = SpeakerEvidence(start: 2.2, end: 3.5, localSpeaker: 2, embedding: v2, cleanSeconds: 1.3, modelRevision: revision)

        // Case 1: Duplicate boundary word ("好") across two speaker-attributed windows.
        var prevRec = SpeechRecognition(windowID: before.id, text: "明天好", tokens: ["明", "天", "好"],
            timestamps: [0.8, 1.4, 1.98], rawJSON: "{}", configurationFingerprint: "test", speakers: [evA])
        prevRec.speakerTurns = [SpeakerTurnTranscript(text: "明天好", start: 0, end: 2.0, evidence: evA)]

        var nextRec = SpeechRecognition(windowID: after.id, text: "好没问题", tokens: ["好", "没", "问", "题"],
            timestamps: [0.52, 0.90, 1.20, 1.50], rawJSON: "{}", configurationFingerprint: "test", speakers: [evA, evB])
        nextRec.speakerTurns = [
            SpeakerTurnTranscript(text: "好", start: 0.50, end: 0.75, evidence: evA),
            SpeakerTurnTranscript(text: "没问题", start: 0.75, end: 3.50, evidence: evB)
        ]

        let deduplicated = nextRec.textOwned(by: after, after: (prevRec, before))
        #expect(deduplicated == "没问题")
        let dedupParts = try #require(try nextRec.speakerParts(text: deduplicated, window: after))
        #expect(dedupParts.count == 1)
        #expect(dedupParts[0].text == "没问题")
        #expect(dedupParts[0].evidence?.localSpeaker == 2)
        #expect(dedupParts[0].frames == after.coreFrames)

        // Case 2: Boundary word ("乙") shifted into neither core is recovered onto the first turn of `after`.
        var gapPrev = SpeechRecognition(windowID: before.id, text: "甲乙", tokens: ["甲", "乙"],
            timestamps: [1.5, 2.02], rawJSON: "{}", configurationFingerprint: "test", speakers: [evA])
        gapPrev.speakerTurns = [SpeakerTurnTranscript(text: "甲", start: 0, end: 2.0, evidence: evA)]

        var gapNext = SpeechRecognition(windowID: after.id, text: "甲乙丙丁", tokens: ["甲", "乙", "丙", "丁"],
            timestamps: [0.10, 0.48, 0.65, 1.40], rawJSON: "{}", configurationFingerprint: "test", speakers: [evA, evB])
        gapNext.speakerTurns = [
            SpeakerTurnTranscript(text: "丙", start: 0.50, end: 0.90, evidence: evA),
            SpeakerTurnTranscript(text: "丁", start: 0.90, end: 3.50, evidence: evB)
        ]
        let prevOwned = gapPrev.textOwned(by: before)
        let recovered = gapNext.textOwned(by: after, after: (gapPrev, before))
        #expect(prevOwned == "甲")
        #expect(recovered == "乙丙丁")
        let recoveredParts = try #require(try gapNext.speakerParts(text: recovered, window: after))
        #expect(recoveredParts.map(\.text) == ["乙丙", "丁"])
        #expect(recoveredParts[0].evidence?.localSpeaker == 1)
        #expect(recoveredParts[1].evidence?.localSpeaker == 2)

        // Case 3: Sub-50ms (< 800 samples) boundary sliver is absorbed instead of creating a phantom turn.
        let sliver = SpeakerEvidence(start: 0.0, end: 0.03, localSpeaker: 2, embedding: [], cleanSeconds: 0, modelRevision: revision)
        let main = SpeakerEvidence(start: 0.03, end: 3.0, localSpeaker: 1, embedding: v1, cleanSeconds: 2.9, modelRevision: revision)
        let absorbed = SpeakerTurn.plan([sliver, main], core: 0..<48_000)
        #expect(absorbed.count == 1)
        #expect(absorbed[0].evidence.localSpeaker == 1)
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_TURN_TEST_MODEL_DIRECTORY"] != nil))
struct SpeakerTurnRecordingTests {
    @Test func priorRecordingRunsThroughProductionTurnDecoding() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["MOMO_TURN_TEST_OUTPUT"]))
        let wave = try #require(SherpaOnnxReadWave(try #require(environment["MOMO_TURN_TEST_WAV"])))
        defer { SherpaOnnxFreeWave(wave) }
        #expect(wave.pointee.sample_rate == 16_000)
        let pcm = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
            .map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) }
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "turn-regression", sourceKind: .fixture,
            sampleRate: 16_000, targetFrames: 960_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 28_800)
        var chunks = try writer.append(pcm)
        if let tail = try writer.finish() { chunks.append(tail) }
        let inputs = chunks.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) }
        let input = try SpeechInputSet(inputs, anchor: 0)
        let bundle = try SpeechModelBundle.load(from: URL(fileURLWithPath: #require(environment["MOMO_TURN_TEST_MODEL_DIRECTORY"])))
        let config = try SpeechConfiguration()
        let engine = try SpeechEngine(bundle: bundle, configuration: config, continuousArchive: true,
            recognitionBackend: .sherpaCoreML, coreMLCacheDirectory: root.appendingPathComponent("cache"),
            speakerDirectory: URL(fileURLWithPath: #require(environment["MOMO_TURN_TEST_SPEAKERS"])))
        let planner = WindowPlanner(configuration: config, fingerprint: engine.configurationFingerprint)
        var results: [SpeechRecognition] = []
        for start in stride(from: Int64(0), to: input.modelFrameCount, by: 160_000) {
            let frames = try FrameRange(start: start, count: min(160_000, input.modelFrameCount - start))
            let window = try planner.makeWindow(core: frames, context: frames, input: input)
            let result = try await engine.transcribe(window: window, inputs: inputs)
            #expect(result.speakerFailure == nil)
            if let parts = try result.speakerParts(text: engine.archiveText(result, window: window), window: window) {
                #expect(parts.map(\.text).joined() == result.text)
                #expect(parts.first?.frames.start == window.coreFrames.start)
                #expect(parts.last?.frames.end == window.coreFrames.end)
            }
            results.append(result)
        }
        #expect(results.contains { ($0.speakerTurns?.count ?? 0) > 1 })
        try WireJSON.encode(results).write(to: root.appendingPathComponent("prior-recording-turns.json"))
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEAKER_MODEL_DIRECTORY"] != nil))
struct SpeakerNativeTests {
    @Test func realRecordingAndSilenceUseTheProductionCoreMLAdapter() throws {
        let environment = ProcessInfo.processInfo.environment
        let models = URL(fileURLWithPath: try #require(environment["MOMO_SPEAKER_MODEL_DIRECTORY"]))
        let audio = try #require(environment["MOMO_SPEAKER_TEST_WAV"])
        let cache = URL(fileURLWithPath: try #require(environment["MOMO_SPEAKER_TEST_OUTPUT"]))
        let attempt = SpeechAttempt()
        let runtime = try SpeakerRuntime(directory: models, cacheRoot: cache, attempt: attempt)
        #expect(runtime.acceleratorMask == 3)
        let cpuRuntime = try SpeakerRuntime(directory: models, cacheRoot: nil, attempt: attempt)
        #expect(cpuRuntime.acceleratorMask == 0)
        let wave = try #require(SherpaOnnxReadWave(audio))
        defer { SherpaOnnxFreeWave(wave) }
        #expect(wave.pointee.sample_rate == 16_000)
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let exact3sSlice = Array(samples.prefix(min(samples.count, 48_000)))
        if let ane3s = try runtime.extractCleanVoiceprint(exact3sSlice, attempt: attempt),
           let cpu3s = try cpuRuntime.extractCleanVoiceprint(exact3sSlice, attempt: attempt) {
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for i in ane3s.embedding.indices {
                dot += ane3s.embedding[i] * cpu3s.embedding[i]
                na += ane3s.embedding[i] * ane3s.embedding[i]
                nb += cpu3s.embedding[i] * cpu3s.embedding[i]
            }
            let cos3s = dot / max(1e-8, (na * nb).squareRoot())
            print("Speaker ANE vs CPU 3s clean voiceprint cosine=\(cos3s)")
            #expect(cos3s >= 0.98)
        }
        let seedSlice = Array(samples.prefix(min(samples.count, 96_000)))
        if let aneSeed = try runtime.extractCleanVoiceprint(seedSlice, attempt: attempt),
           let cpuSeed = try cpuRuntime.extractCleanVoiceprint(seedSlice, attempt: attempt) {
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for i in aneSeed.embedding.indices {
                dot += aneSeed.embedding[i] * cpuSeed.embedding[i]
                na += aneSeed.embedding[i] * aneSeed.embedding[i]
                nb += cpuSeed.embedding[i] * cpuSeed.embedding[i]
            }
            let cosSim = dot / max(1e-8, (na * nb).squareRoot())
            print("Speaker ANE vs CPU 5.6s clean voiceprint cosine=\(cosSim)")
            #expect(cosSim >= 0.990)
        }
        let started = Date()
        let evidence = try runtime.analyze(samples, attempt: attempt)
        #expect(evidence.contains { $0.hasVoiceprint && $0.cleanSeconds >= 3 })
        #expect(evidence.allSatisfy { $0.start >= 0 && $0.end <= Double(samples.count) / 16_000 && $0.end > $0.start })
        #expect(evidence.allSatisfy { $0.embedding.isEmpty || $0.hasVoiceprint })
        if samples.count > 160_000 {
            #expect(evidence.allSatisfy { $0.localSpeaker < 0 || $0.localSpeaker >= 1 })
        }
        try WireJSON.encode(evidence).write(to: cache.appendingPathComponent("production-speaker-evidence.json"))
        print("Speaker adapter: audio=\(samples.count / 16000)s, segments=\(evidence.count), embeddings=\(evidence.filter(\.hasVoiceprint).count), elapsed=\(Date().timeIntervalSince(started))s")
        // Verify far-field / Watch attenuated speech (~ -30 dB alongside loud near-field speech
        // and across a 7 s silent 10 s-window seam) is rescued by short-term AGC and re-identified.
        let clip = Array(samples.prefix(min(samples.count, 64_000)))
        let crossSeam = clip.map { $0 * 0.03 } + Array(repeating: Float(0), count: 7 * 16_000) + clip
        let proto = evidence.first(where: \.hasVoiceprint).map {
            [EnrolledSpeakerPrototype(personID: UUID(), embedding: $0.embedding, modelRevision: $0.modelRevision)]
        } ?? []
        let leveledEvidence = try runtime.analyze(crossSeam, prototypes: proto, attempt: attempt)
        let earlySpk = leveledEvidence.first { $0.start < 4.5 && $0.hasVoiceprint }?.localSpeaker
        let lateSpk = leveledEvidence.last { $0.start > 10.5 && $0.hasVoiceprint }?.localSpeaker
        #expect(earlySpk != nil && earlySpk == lateSpk)
        #expect(try runtime.analyze(Array(repeating: 0, count: 160_000), attempt: attempt).isEmpty)
        attempt.cancel()
        #expect(throws: SpeechError.self) { try runtime.analyze(samples, attempt: attempt) }
    }

    @Test func rapidBackToBackMultiSpeakerTransitionsSplitAndPreservePureEmbeddings() throws {
        let environment = ProcessInfo.processInfo.environment
        let models = URL(fileURLWithPath: try #require(environment["MOMO_SPEAKER_MODEL_DIRECTORY"]))
        let audio = try #require(environment["MOMO_SPEAKER_TEST_WAV"])
        let cache = URL(fileURLWithPath: try #require(environment["MOMO_SPEAKER_TEST_OUTPUT"]))
            .appendingPathComponent("multi-speaker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        let attempt = SpeechAttempt()
        let runtime = try SpeakerRuntime(directory: models, cacheRoot: cache, attempt: attempt)

        func normalizePeak(_ input: [Float], targetPeak: Float) -> [Float] {
            let peak = input.reduce(Float(0)) { max($0, abs($1)) }
            guard peak > 1e-4 else { return input }
            let gain = targetPeak / peak
            return input.map { max(-0.98, min(0.98, $0 * gain)) }
        }

        func synthesizeVoice(voice: String, text: String, name: String) throws -> [Float] {
            let aiff = cache.appendingPathComponent("\(name).aiff")
            let wav = cache.appendingPathComponent("\(name).wav")
            let sayProc = Process()
            sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            sayProc.arguments = ["-v", voice, "-o", aiff.path, text]
            try sayProc.run()
            sayProc.waitUntilExit()
            #expect(sayProc.terminationStatus == 0)

            let convProc = Process()
            convProc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convProc.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
            try convProc.run()
            convProc.waitUntilExit()
            #expect(convProc.terminationStatus == 0)

            let wave = try #require(SherpaOnnxReadWave(wav.path))
            defer { SherpaOnnxFreeWave(wave) }
            let raw = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
            // Trim leading/trailing silence (< 0.008) so concatenation has a 0 ms rapid turn handoff.
            let firstIdx = raw.firstIndex(where: { abs($0) > 0.008 }) ?? 0
            let lastIdx = raw.lastIndex(where: { abs($0) > 0.008 }) ?? (raw.count - 1)
            return firstIdx < lastIdx ? Array(raw[firstIdx...lastIdx]) : raw
        }

        let waveA = try #require(SherpaOnnxReadWave(audio))
        defer { SherpaOnnxFreeWave(waveA) }
        let rawA = Array(UnsafeBufferPointer(start: waveA.pointee.samples, count: Int(waveA.pointee.num_samples)))
        let firstA = rawA.firstIndex(where: { abs($0) > 0.008 }) ?? 0
        let trimmedA = Array(rawA.dropFirst(firstA))

        let clipA1 = normalizePeak(Array(trimmedA.prefix(min(trimmedA.count, 51_200))), targetPeak: 0.26)
        let clipA2 = normalizePeak(Array(trimmedA.dropFirst(min(16_000, trimmedA.count / 4)).prefix(51_200)), targetPeak: 0.24)
        let rawB = try synthesizeVoice(
            voice: "Eddy (中文（中国大陆）)",
            text: "我觉得这个方案在逻辑上还需要进一步验证，不能直接上线。",
            name: "eddy")
        let clipB = normalizePeak(Array(rawB.prefix(min(rawB.count, 54_400))), targetPeak: 0.09)

        let rawC = try synthesizeVoice(
            voice: "Flo (中文（中国大陆）)",
            text: "同意，我们可以先整理测试数据，下午三点再一起评审结果。",
            name: "flo")
        let clipC = normalizePeak(Array(rawC.prefix(min(rawC.count, 54_400))), targetPeak: 0.05)

        let refA = try #require(try runtime.analyze(clipA1, attempt: attempt).first(where: \.hasVoiceprint)?.embedding)
        let refB = try #require(try runtime.analyze(clipB, attempt: attempt).first(where: \.hasVoiceprint)?.embedding)

        func cosine(_ a: [Float], _ b: [Float]) -> Float {
            guard a.count == b.count, !a.isEmpty else { return 0 }
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
            let d = (na * nb).squareRoot()
            return d > 0 ? dot / d : 0
        }

        // Case 1: Zero-gap [A (near-field 0.26) -> B (mid-field 0.09) -> A (near-field 0.24)]
        let aba = clipA1 + clipB + clipA2
        let durA1 = Double(clipA1.count) / 16_000
        let durB = Double(clipB.count) / 16_000
        let abaEvidence = try runtime.analyze(aba, attempt: attempt)
        let abaTurns = SpeakerTurn.plan(abaEvidence, core: 0..<aba.count)
        print("Multi-speaker ABA turns (\(abaTurns.count)): " + abaTurns.map {
            String(format: "[%.2f..%.2f spk=%d clean=%.2fs simA=%.2f simB=%.2f]",
                   $0.evidence.start, $0.evidence.end, $0.evidence.localSpeaker, $0.evidence.cleanSeconds,
                   cosine($0.evidence.embedding, refA), cosine($0.evidence.embedding, refB))
        }.joined(separator: " "))

        #expect(abaTurns.count >= 3)
        #expect(abaTurns.allSatisfy { $0.evidence.localSpeaker >= 1 && $0.evidence.hasVoiceprint })
        let firstTurn = try #require(abaTurns.first { $0.evidence.start < durA1 * 0.5 })
        let midTurn = try #require(abaTurns.first {
            let mid = ($0.evidence.start + $0.evidence.end) * 0.5
            return mid > durA1 + 0.4 && mid < durA1 + durB - 0.4
        })
        let lastTurn = try #require(abaTurns.last { $0.evidence.end > durA1 + durB + 1.0 })
        #expect(SpeakerTurn.sameVoice(firstTurn.evidence, lastTurn.evidence))
        #expect(!SpeakerTurn.sameVoice(firstTurn.evidence, midTurn.evidence))
        #expect((firstTurn.evidence.localSpeaker - 1) / 4 == (midTurn.evidence.localSpeaker - 1) / 4)
        #expect(cosine(firstTurn.evidence.embedding, refA) >= 0.90)
        #expect(cosine(midTurn.evidence.embedding, refB) >= 0.90)
        #expect(cosine(midTurn.evidence.embedding, refB) - cosine(midTurn.evidence.embedding, refA) >= 0.14)
        #expect(cosine(midTurn.evidence.embedding, refA) <= cosine(refA, refB) + 0.05)

        // Case 2: Zero-gap 3-speaker [A (0.26) -> B (0.09) -> C (far-field 0.05)] with enrolled A prototype
        // (tests HasOneSidedEnrolledDropoff + far-field 3rd speaker separation).
        let protoA = [EnrolledSpeakerPrototype(personID: UUID(), embedding: refA, modelRevision: firstTurn.evidence.modelRevision)]
        let abc = clipA1 + clipB + clipC
        let abcEvidence = try runtime.analyze(abc, prototypes: protoA, attempt: attempt)
        let abcTurns = SpeakerTurn.plan(abcEvidence, core: 0..<abc.count)
        let distinctSpeakers = Set(abcTurns.map { $0.evidence.localSpeaker })
        print("Multi-speaker ABC turns (\(abcTurns.count), distinct=\(distinctSpeakers.count)): " + abcTurns.map {
            String(format: "[%.2f..%.2f spk=%d clean=%.2fs]", $0.evidence.start, $0.evidence.end, $0.evidence.localSpeaker, $0.evidence.cleanSeconds)
        }.joined(separator: " "))
        #expect(abcTurns.count >= 3)
        #expect(distinctSpeakers.count >= 3)

        // Verify clean seed voiceprint extractor accepts pure single-speaker audio and rejects mixed 2-speaker audio,
        // and verify configurable PyAnnote Community-1 shares the exact same 192-dim ERes2NetV2 embedding space.
        let cleanSeedA = try #require(try runtime.extractCleanVoiceprint(clipA1, attempt: attempt))
        #expect(cleanSeedA.embedding.count == 192)
        #expect(cosine(cleanSeedA.embedding, refA) >= 0.95)
        let mixedSeed = try runtime.extractCleanVoiceprint(clipA1 + clipB, attempt: attempt)
        #expect(mixedSeed == nil)

        let communityRuntime = try SpeakerRuntime(
            directory: models,
            segmentationModel: .pyannoteCommunity1,
            cacheRoot: cache,
            attempt: attempt)
        #expect(communityRuntime.acceleratorMask == 3)
        let communityEvidence = try communityRuntime.analyze(aba, attempt: attempt)
        let communityTurns = SpeakerTurn.plan(communityEvidence, core: 0..<aba.count)
        #expect(communityTurns.count >= 3)
        let communityFirst = try #require(communityTurns.first(where: { $0.evidence.hasVoiceprint }))
        #expect(communityFirst.evidence.embedding.count == 192)
        #expect(cosine(communityFirst.evidence.embedding, refA) >= 0.85)
    }
}
