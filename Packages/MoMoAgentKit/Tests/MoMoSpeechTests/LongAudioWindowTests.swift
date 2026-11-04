import Foundation
import Testing
import MoMoContracts
import MoMoRecording
import SherpaOnnxC
@testable import MoMoSpeech

struct LongAudioWindowTests {
    @Test func checkpointBeforeUtteranceKeepsItsOriginalContext() throws {
        let input = try longAudioInput(frames: 640_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        let original = try planner.continuousWindows(ranges: [80_000..<200_000], input: input,
            availableThrough: input.modelFrameCount, tailClosed: true)
        let resumed = try planner.continuousWindows(ranges: [80_000..<200_000], input: input,
            availableThrough: input.modelFrameCount, tailClosed: true, startAt: 75_200)
        #expect(original == resumed)
    }

    @Test func shortPausesAreSharedContextAndLongPausesStaySeparate() throws {
        let input = try longAudioInput(frames: 960_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        let windows = try planner.continuousWindows(
            ranges: [16_000..<64_000, 72_000..<144_000, 192_000..<240_000],
            input: input, availableThrough: input.modelFrameCount, tailClosed: true)
        #expect(windows.count == 2)
        #expect(windows[0].coreFrames == (try FrameRange(start: 11_200, count: 137_600)))
        #expect(windows[1].coreFrames.start == 187_200)
    }

    @Test func longUtteranceCutsAtPauseAndCoresStayDisjoint() throws {
        let input = try longAudioInput(frames: 960_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        let windows = try planner.continuousWindows(
            ranges: [0..<192_000, 201_600..<560_000, 566_400..<832_000],
            input: input, availableThrough: input.modelFrameCount, tailClosed: true)
        #expect(windows[0].modelCoreFrames.end == 196_800)
        #expect(windows.allSatisfy { $0.modelCoreFrames.count <= 320_000 })
        #expect(try FrameRange.union(windows.map(\.coreFrames)) == [FrameRange(start: 0, count: 836_800)])
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(a.coreFrames.end == b.coreFrames.start)
            #expect(a.contextFrames.end > b.contextFrames.start)
        }
    }

    @Test func nativeFlushAndShortPauseCannotPrematurelyCommitTail() throws {
        let input = try longAudioInput(frames: 640_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        #expect(try planner.continuousWindows(ranges: [0..<256_000], input: input,
            availableThrough: 304_000, tailClosed: false, hasPendingSpeech: true).isEmpty)
        #expect(try planner.continuousWindows(ranges: [0..<256_000], input: input,
            availableThrough: 270_000, tailClosed: false).isEmpty)
        let settled = try planner.continuousWindows(ranges: [0..<256_000], input: input,
            availableThrough: 304_000, tailClosed: false)
        #expect(settled.count == 1)
    }

    @Test func quietValleyIsRelativeToVolumeAndNeverRemovesAudio() throws {
        let input = try longAudioInput(frames: 640_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        func windows(gain: Float) throws -> [SpeechWindow] {
            let energy = stride(from: Int64(0), to: 640_000, by: 512).map {
                SpeechEnergyFrame(start: $0, rms: gain * ((260_096..<263_168).contains($0) ? 0.001 : 0.1))
            }
            return try planner.continuousWindows(ranges: [0..<640_000], input: input,
                availableThrough: input.modelFrameCount, tailClosed: true, energy: energy)
        }
        let normal = try windows(gain: 1), quiet = try windows(gain: 0.01)
        #expect(normal.map(\.coreFrames) == quiet.map(\.coreFrames))
        #expect((260_096..<263_168).contains(normal[0].coreFrames.end))
        #expect(try FrameRange.union(normal.map(\.coreFrames)) == [FrameRange(start: 0, count: 640_000)])
    }

    @Test func breathValleyUnderSixteenSecondsKeepsDiariZenSinglePass() throws {
        let input = try longAudioInput(frames: 640_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        let energy = stride(from: Int64(0), to: 640_000, by: 512).map { frame in
            // 160ms syllable/breath valley (-10 dB) around 14.0s (224,256..<227,328)
            let rms: Float = (224_256..<227_328).contains(frame) ? 0.03 : 0.10
            return SpeechEnergyFrame(start: frame, rms: rms)
        }
        let windows = try planner.continuousWindows(ranges: [0..<640_000], input: input,
            availableThrough: input.modelFrameCount, tailClosed: true, energy: energy)
        #expect(!windows.isEmpty)
        #expect(windows[0].coreFrames.count <= 256_000)
        #expect((224_256..<227_328).contains(windows[0].coreFrames.end))
        #expect(try FrameRange.union(windows.map(\.coreFrames)) == [FrameRange(start: 0, count: 640_000)])
    }

    @Test func compressedContinuousSpeechSelectsQuietestSyllableUnderSixteenSeconds() throws {
        let input = try longAudioInput(frames: 640_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        let energy = stride(from: Int64(0), to: 640_000, by: 512).map { frame in
            // Compressed noisy speech with only a mild -4.4 dB syllable dip at ~14.5s (231,936..<235,008)
            let rms: Float = (231_936..<235_008).contains(frame) ? 0.06 : 0.10
            return SpeechEnergyFrame(start: frame, rms: rms)
        }
        let windows = try planner.continuousWindows(ranges: [0..<640_000], input: input,
            availableThrough: input.modelFrameCount, tailClosed: true, energy: energy)
        #expect(!windows.isEmpty)
        #expect(windows[0].coreFrames.count <= 256_000)
        #expect((231_936..<235_008).contains(windows[0].coreFrames.end))
        #expect(try FrameRange.union(windows.map(\.coreFrames)) == [FrameRange(start: 0, count: 640_000)])
    }

    @Test func conversationalPauseBetweenSixteenAndTwentySecondsSplitsInsideSinglePassLimit() throws {
        let input = try longAudioInput(frames: 320_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        // Two speech runs spanning 18.0s total (0..<192,000 and 200,000..<288,000) with a 0.5s pause at 12.0s.
        let windows = try planner.continuousWindows(
            ranges: [0..<192_000, 200_000..<288_000],
            input: input,
            availableThrough: input.modelFrameCount,
            tailClosed: true
        )
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.modelCoreFrames.count <= 256_000 })
        #expect(windows[0].modelCoreFrames.end == 196_000)
        #expect(windows[1].modelCoreFrames.start == 196_000)
        #expect(try FrameRange.union(windows.map(\.coreFrames)) == [FrameRange(start: 0, count: 292_800)])
    }

    @Test func punctuationFollowsItsWordAcrossWindowBoundary() throws {
        let input = try longAudioInput(frames: 48_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: "test")
        let a = try planner.makeWindow(core: FrameRange(start: 0, count: 16_000),
            context: FrameRange(start: 0, count: 48_000), input: input)
        let b = try planner.makeWindow(core: FrameRange(start: 16_000, count: 32_000),
            context: FrameRange(start: 0, count: 48_000), input: input)
        func result(_ window: SpeechWindow) -> SpeechRecognition {
            SpeechRecognition(windowID: window.id, text: "好！继续。", tokens: ["好", "！", "继", "续", "。"],
                timestamps: [0.9, 1.02, 1.2, 1.4, 1.6], rawJSON: "{}", configurationFingerprint: "test")
        }
        #expect(result(a).textOwned(by: a) == "好！")
        #expect(result(b).textOwned(by: b) == "继续。")
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_LONG_AUDIO_WAV"] != nil))
struct LongAudioRecordingTests {
    @Test func priorRecordingUsesProductionAnalysisRecognitionAndSpeakerTurns() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["MOMO_LONG_AUDIO_OUTPUT"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wave = try #require(SherpaOnnxReadWave(try #require(env["MOMO_LONG_AUDIO_WAV"])))
        defer { SherpaOnnxFreeWave(wave) }
        #expect(wave.pointee.sample_rate == 16_000)
        let floats = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let pcm = floats.map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) }
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("audio"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "long-audio-regression", sourceKind: .fixture,
            sampleRate: 16_000, targetFrames: 960_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0)
        var chunks = try writer.append(pcm)
        if let tail = try writer.finish() { chunks.append(tail) }
        let inputs = chunks.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) }
        let input = try SpeechInputSet(inputs, anchor: 0)
        let bundle = try SpeechModelBundle.load(from: URL(fileURLWithPath: #require(env["MOMO_LONG_AUDIO_MODELS"])))
        let config = try SpeechConfiguration()
        let engine = try SpeechEngine(bundle: bundle, configuration: config, continuousArchive: true,
            recognitionBackend: .sherpaCoreML, coreMLCacheDirectory: root.appendingPathComponent("cache"),
            speakerDirectory: URL(fileURLWithPath: #require(env["MOMO_LONG_AUDIO_SPEAKERS"])))
        let batch = try await engine.prepare(inputs: inputs, boundary: .captureEnd(Int64(pcm.count)))
        #expect(batch.analyzedCoverage == [try FrameRange(start: 0, count: Int64(pcm.count))])
        #expect(batch.windows.allSatisfy { $0.modelCoreFrames.count <= 320_000 })
        for (a, b) in zip(batch.windows, batch.windows.dropFirst()) { #expect(a.coreFrames.end <= b.coreFrames.start) }

        // Reproduce the previous VAD/window policy, then use the exact same
        // production recognizer and speaker decoder for a controlled comparison.
        let oldVAD = try SherpaVAD(model: bundle.directory.appendingPathComponent("silero_vad.onnx"),
            configuration: config.withVADThreshold(0.5, minimumSilenceSeconds: 2))
        let old = VADContinuation(input: input, origin: 0, threshold: 0.5, detector: oldVAD)
        try old.append(floats, at: 0)
        while try old.step(through: Int64(floats.count)) {}
        try old.finish()
        let ranges = try FrameRange.union(old.relativeRanges(from: 0, through: Int64(floats.count)).map {
            let start = max(0, $0.lowerBound - 4_800), end = min(Int64(floats.count), $0.upperBound + 4_800)
            return try FrameRange(start: start, count: end - start)
        })
        let planner = WindowPlanner(configuration: config, fingerprint: engine.configurationFingerprint)
        var baseline: [SpeechWindow] = []
        for range in ranges {
            for start in stride(from: range.start, to: range.end, by: 320_000) {
                let end = min(range.end, start + 320_000), left = max(range.start, start - 16_000)
                let right = min(range.end, end + 16_000)
                baseline.append(try planner.makeWindow(core: FrameRange(start: start, count: end - start),
                    context: FrameRange(start: left, count: right - left), input: input))
            }
        }
        struct Output: Encodable { let window: SpeechWindow; let text: String; let result: SpeechRecognition }
        for (name, windows) in [("previous", baseline), ("cut-merge", batch.windows)] {
            var outputs: [Output] = [], previous: (result: SpeechRecognition, window: SpeechWindow)?
            for window in windows {
                let result = try await engine.transcribe(window: window, inputs: inputs)
                #expect(result.speakerFailure == nil)
                let text = engine.archiveText(result, window: window, after: previous)
                outputs.append(Output(window: window, text: text, result: result))
                previous = (result, window)
            }
            try WireJSON.encode(outputs).write(to: root.appendingPathComponent("\(name).json"))
        }
        #expect(batch.windows.map(\.modelCoreFrames) != baseline.map(\.modelCoreFrames))
    }
}

private func longAudioInput(frames: Int64) throws -> SpeechInputSet {
    let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "test",
        sequence: 0, frames: FrameRange(start: 0, count: frames), timebaseHz: 16_000,
        wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmInt16,
        sampleRate: 16_000, channels: 1, decodedFrameCount: frames, byteCount: frames * 2 + 44,
        audioSHA256: String(repeating: "a", count: 64), sourceKind: .fixture)
    return try SpeechInputSet([SpeechAudioInput(envelope: ManifestEnvelope(manifest: manifest),
        audioURL: URL(fileURLWithPath: "/unused.wav"))], anchor: 0)
}
