import Foundation
import SherpaOnnxC
import Testing
@testable import MoMoSpeech

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
struct SherpaNativeBatchTests {
    @Test func senseVoiceCoreMLBatchMatchesIndividualReferenceAndKeepsOrder() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"])
        let directory = URL(fileURLWithPath: path)
        let bundle = try SpeechModelBundle.load(from: directory)
        let wav = directory.appendingPathComponent("test_wavs/zh.wav")
        let wave = try #require(wav.path.withCString { SherpaOnnxReadWave($0) })
        defer { SherpaOnnxFreeWave(wave) }
        #expect(wave.pointee.sample_rate == 16_000)
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let config = try SpeechConfiguration()
        let attempt = SpeechAttempt()
        func recorder() -> SpeechDiagnosticRecorder {
            .init(operation: .transcribe, attemptID: attempt.id, windowID: nil, fingerprint: "batch-parity")
        }
        let cpu = try SherpaRuntime(bundle: bundle, configuration: config, backend: .sherpa,
            download: nil, cacheRoot: nil, attempt: attempt, recorder: recorder())
        let reference = try cpu.recognize(samples: samples, windowID: "first", fingerprint: "batch-parity",
            attempt: attempt, onEvent: { _ in }, recorder: recorder())
        cpu.close()
        // Raw whole-clip decoding differs from the VAD-trimmed quality fixture.
        // This gate compares Core ML batching with the same unchanged ONNX input.
        #expect(reference.text.contains("早上9点至下午5点"))
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-batch-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let accelerated = try SherpaRuntime(bundle: bundle, configuration: config, backend: .sherpaCoreML,
            download: nil, cacheRoot: cacheRoot, attempt: attempt, recorder: recorder())
        defer { accelerated.close() }
        let results = try accelerated.recognizeBatch([
            .init(samples: samples, windowID: "first"),
            .init(samples: samples + Array(repeating: 0, count: 8_000), windowID: "second")
        ], fingerprint: "batch-parity", attempt: attempt, onEvent: { _ in }, recorder: recorder())
        #expect(results.map(\.windowID) == ["first", "second"])
        #expect(results.allSatisfy { $0.text == reference.text })
        #expect(results.allSatisfy { $0.timestamps.allSatisfy(\.isFinite) })
        let cancelled = SpeechAttempt()
        cancelled.cancel()
        #expect(throws: SpeechError.cancelled) {
            try accelerated.recognize(samples: samples, windowID: "cancelled", fingerprint: "batch-parity",
                attempt: cancelled, onEvent: { _ in }, recorder: recorder())
        }
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_NANO_MODEL_DIRECTORY"] != nil))
struct NanoNativeTests {
    @Test func publishedNanoUsesTheSharedRuntimeAndReturnsSpeech() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["MOMO_NANO_MODEL_DIRECTORY"]))
        let bundle = try SpeechModelBundle.load(from: URL(fileURLWithPath: try #require(environment["MOMO_SPEECH_MODEL_DIRECTORY"])))
        let catalog = try DownloadableSpeechModel.funASRNano()
        let attempt = SpeechAttempt()
        let recorder = SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id,
            windowID: nil, fingerprint: "nano-native")
        let started = Date()
        let runtime = try SherpaRuntime(bundle: bundle, configuration: SpeechConfiguration(),
            backend: .sherpaCoreML, download: .init(directory: directory, catalog: catalog),
            cacheRoot: nil, attempt: attempt, recorder: recorder)
        defer { runtime.close() }
        try runtime.warmUp(attempt: attempt, recorder: recorder)
        let wav = bundle.directory.appendingPathComponent("test_wavs/zh.wav")
        let wave = try #require(wav.path.withCString { SherpaOnnxReadWave($0) })
        defer { SherpaOnnxFreeWave(wave) }
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let result = try runtime.recognize(samples: samples, windowID: "nano",
            fingerprint: "nano-native", attempt: attempt, onEvent: { _ in }, recorder: recorder)
        print("Nano native result: \(result.text), load=\(recorder.value.modelLoadSeconds), total=\(Date().timeIntervalSince(started))")
        #expect(recorder.value.modelLoadSeconds < 10)
        #expect(result.text.contains("开放时间") && result.text.contains("早上") && result.text.contains("下午"))
        #expect(result.text.count < 120)
        #expect(result.rawJSON.contains(result.text))

        // Trailing low-level room noise after speech must not trigger repetition loops or misrecognitions.
        var lcg: UInt64 = 0x9E37_79B9_7F4A_7C15
        let trailingHiss = (0..<(5 * 16_000)).map { _ -> Float in
            lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(Int64(bitPattern: lcg) >> 40) / Float(1 << 23)
            return u * 0.002
        }
        let noisyResult = try runtime.recognize(samples: samples + trailingHiss, windowID: "nano-trailing-hiss",
            fingerprint: "nano-native", attempt: attempt, onEvent: { _ in }, recorder: recorder)
        #expect(noisyResult.text.contains("开放时间") && noisyResult.text.contains("早上") && noisyResult.text.contains("下午"))
        #expect(noisyResult.text.count < 40)

        let silence = try runtime.recognize(samples: Array(repeating: 0, count: 16_000),
            windowID: "silence", fingerprint: "nano-native", attempt: attempt, onEvent: { _ in }, recorder: recorder)
        #expect(silence.text.isEmpty)

        let ambientNoise = try runtime.recognize(samples: trailingHiss,
            windowID: "ambient-hiss", fingerprint: "nano-native", attempt: attempt, onEvent: { _ in }, recorder: recorder)
        #expect(ambientNoise.text.isEmpty)

        let cancelled = SpeechAttempt()
        cancelled.cancel()
        #expect(throws: SpeechError.cancelled) {
            try runtime.recognize(samples: samples, windowID: "cancelled",
                fingerprint: "nano-native", attempt: cancelled, onEvent: { _ in }, recorder: recorder)
        }
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_XASR_MODEL_DIRECTORY"] != nil))
struct XASRNativeTests {
    @Test func publishedXASRDecodesWithTokensThatArchiveOwnershipCanAlign() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["MOMO_XASR_MODEL_DIRECTORY"]))
        let bundle = try SpeechModelBundle.load(from: URL(fileURLWithPath: try #require(environment["MOMO_SPEECH_MODEL_DIRECTORY"])))
        let attempt = SpeechAttempt()
        let recorder = SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id,
            windowID: nil, fingerprint: "xasr-native")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-xasr-coreml-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let download = DownloadedSpeechModel(directory: directory, catalog: try .xASR())
        let runtime = try SherpaRuntime(bundle: bundle, configuration: SpeechConfiguration(),
            backend: .sherpaCoreML, download: download, cacheRoot: cacheRoot, attempt: attempt, recorder: recorder)
        defer { runtime.close() }
        try runtime.warmUp(attempt: attempt, recorder: recorder)
        #expect(recorder.value.modelLoadSeconds < 10)
        let cachedEntries = (try? FileManager.default.contentsOfDirectory(atPath:
            cacheRoot.appendingPathComponent("sherpa-coreml-v2-\(try download.catalog.revision)").path)) ?? []
        #expect(cachedEntries.contains("sherpa.config"))
        // The public fixture is Chinese; an English clip, when present, also exercises casing.
        let english = bundle.directory.appendingPathComponent("test_wavs/en.wav")
        let clips = [("zh", "早上九点至下午五点")]
            + (FileManager.default.fileExists(atPath: english.path) ? [("en", "fifty pieces of gold")] : [])
        for (name, expected) in clips {
            let wav = bundle.directory.appendingPathComponent("test_wavs/\(name).wav")
            let wave = try #require(wav.path.withCString { SherpaOnnxReadWave($0) })
            defer { SherpaOnnxFreeWave(wave) }
            let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
            let result = try runtime.recognize(samples: samples, windowID: name,
                fingerprint: "xasr-native", attempt: attempt, onEvent: { _ in }, recorder: recorder)
            print("X-ASR native result (\(name)): \(result.text)")
            #expect(result.text.contains(expected))
            // Archive ownership matches token spellings against the text; casing and punctuation must keep that intact.
            #expect(result.tokens.count == result.timestamps.count)
            #expect(result.tokens.joined().replacingOccurrences(of: "▁", with: " ").filter { !$0.isWhitespace }
                .lowercased() == result.text.filter { !$0.isWhitespace }.lowercased())
            if name == "zh" {
                let batched = try runtime.recognizeBatch([
                    .init(samples: samples, windowID: "batch-1"),
                    .init(samples: samples + Array(repeating: 0, count: 8_000), windowID: "batch-2")
                ], fingerprint: "xasr-native", attempt: attempt, onEvent: { _ in }, recorder: recorder)
                #expect(batched.map(\.windowID) == ["batch-1", "batch-2"])
                #expect(batched.allSatisfy { $0.text == result.text })
                #expect(batched.allSatisfy { $0.timestamps.allSatisfy(\.isFinite) })
            }
        }
        #expect(try runtime.updateLanguage(.english))
        #expect(throws: SpeechModelSelectionError.unsupportedLanguage) { try runtime.updateLanguage(.japanese) }
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_FUNASR_COREML_MODEL_DIRECTORY"] != nil))
struct FunASRNanoCoreMLNativeTests {
    @Test func publishedFunASRNanoCoreMLCompilesAndMatchesCPUReferenceWithTokens() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["MOMO_FUNASR_COREML_MODEL_DIRECTORY"]))
        let bundle = try SpeechModelBundle.load(from: URL(fileURLWithPath: try #require(environment["MOMO_SPEECH_MODEL_DIRECTORY"])))
        let catalog = try DownloadableSpeechModel.funASRNanoCoreML()
        let download = DownloadedSpeechModel(directory: directory, catalog: catalog)
        let wav = bundle.directory.appendingPathComponent("test_wavs/zh.wav")
        let wave = try #require(wav.path.withCString { SherpaOnnxReadWave($0) })
        defer { SherpaOnnxFreeWave(wave) }
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let attempt = SpeechAttempt()
        func makeRecorder() -> SpeechDiagnosticRecorder {
            .init(operation: .transcribe, attemptID: attempt.id, windowID: nil, fingerprint: "funasr-coreml-native")
        }

        let cpuRuntime = try SherpaRuntime(bundle: bundle, configuration: SpeechConfiguration(),
            backend: .sherpa, download: download, cacheRoot: nil, attempt: attempt, recorder: makeRecorder())
        let cpuRef = try cpuRuntime.recognize(samples: samples, windowID: "cpu-ref",
            fingerprint: "funasr-coreml-native", attempt: attempt, onEvent: { _ in }, recorder: makeRecorder())
        let longSamples = samples + samples + samples
        let cpuLongStart = Date()
        _ = try cpuRuntime.recognize(samples: longSamples, windowID: "cpu-long",
            fingerprint: "funasr-coreml-native", attempt: attempt, onEvent: { _ in }, recorder: makeRecorder())
        let cpuLongElapsed = Date().timeIntervalSince(cpuLongStart)
        cpuRuntime.close()

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-funasr-coreml-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let loadRecorder = makeRecorder()
        let runtime = try SherpaRuntime(bundle: bundle, configuration: SpeechConfiguration(),
            backend: .sherpaCoreML, download: download, cacheRoot: cacheRoot, attempt: attempt, recorder: loadRecorder)
        try runtime.warmUp(attempt: attempt, recorder: loadRecorder)

        let cacheDir = cacheRoot.appendingPathComponent("sherpa-coreml-v2-\(try catalog.revision)")
        let cachedEntries = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        #expect(cachedEntries.contains("sherpaCoreML.config"))
        #expect(cachedEntries.contains { $0 != "sherpaCoreML.config" })
        let partitionEntry = cachedEntries.first { $0 != "sherpaCoreML.config" } ?? ""
        let mlmodelCount = (try? FileManager.default.contentsOfDirectory(atPath:
            cacheDir.appendingPathComponent(partitionEntry).path).filter { $0.hasSuffix(".mlmodelc") }.count) ?? 0

        let decodeStart = Date()
        let batched = try runtime.recognizeBatch([
            .init(samples: samples, windowID: "batch-1"),
            .init(samples: samples + Array(repeating: 0, count: 8_000), windowID: "batch-2")
        ], fingerprint: "funasr-coreml-native", attempt: attempt, onEvent: { _ in }, recorder: makeRecorder())
        let decodeElapsed = Date().timeIntervalSince(decodeStart)

        let coremlLongStart = Date()
        let longDecoded = try runtime.recognize(samples: longSamples, windowID: "coreml-long",
            fingerprint: "funasr-coreml-native", attempt: attempt, onEvent: { _ in }, recorder: makeRecorder())
        let coremlLongElapsed = Date().timeIntervalSince(coremlLongStart)
        runtime.close()

        let warmRecorder = makeRecorder()
        let warmRuntime = try SherpaRuntime(bundle: bundle, configuration: try SpeechConfiguration().withLanguage(.english),
            backend: .sherpaCoreML, download: download, cacheRoot: cacheRoot, attempt: attempt, recorder: warmRecorder)
        defer { warmRuntime.close() }
        try warmRuntime.warmUp(attempt: attempt, recorder: warmRecorder)
        let enDecoded = try warmRuntime.recognize(samples: samples, windowID: "en-check",
            fingerprint: "funasr-coreml-native", attempt: attempt, onEvent: { _ in }, recorder: makeRecorder())

        print("FunASR CoreML native: text='\(batched[0].text)', en='\(enDecoded.text)', coldLoad=\(loadRecorder.value.modelLoadSeconds)s, warmLoad=\(warmRecorder.value.modelLoadSeconds)s, mlmodelc=\(mlmodelCount), batch2=\(decodeElapsed)s, coreml17s=\(coremlLongElapsed)s vs cpu17s=\(cpuLongElapsed)s")

        #expect(batched.map(\.windowID) == ["batch-1", "batch-2"])
        #expect(!batched[0].text.isEmpty)
        #expect(batched[0].text.contains("早上九点至下午五点"))
        #expect(batched.allSatisfy { $0.text == cpuRef.text })
        #expect(!longDecoded.text.isEmpty)
        #expect(!batched[0].tokens.isEmpty)
        #expect(batched[0].tokens.count == batched[0].timestamps.count)
        #expect(batched.allSatisfy { $0.timestamps.allSatisfy(\.isFinite) })
        #expect(try warmRuntime.updateLanguage(.korean))
    }
}
