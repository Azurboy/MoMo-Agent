import Darwin
import Foundation
import MoMoContracts
import MoMoRecording
import SherpaOnnxC
import Testing
@testable import MoMoSpeech

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
struct SherpaNativeBatchTests {
    @Test func senseVoiceCoreMLBatchMatchesIndividualReferenceAndKeepsOrder() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"])
        let directory = URL(fileURLWithPath: path)
        let bundle = try SpeechModelBundle.load(from: directory)
        let primaryWav = directory.appendingPathComponent("test_wavs/zh.wav")
        let fallbackWav = directory.deletingLastPathComponent().appendingPathComponent("TestFixtures/zh.wav")
        let wav = FileManager.default.fileExists(atPath: primaryWav.path) ? primaryWav : fallbackWav
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
        #expect(runtime.usesCoreMLAccelerator)
        #expect(runtime.acceleratorMask == 3)
        let primaryWav = bundle.directory.appendingPathComponent("test_wavs/zh.wav")
        let fallbackWav = bundle.directory.deletingLastPathComponent().appendingPathComponent("TestFixtures/zh.wav")
        let wav = FileManager.default.fileExists(atPath: primaryWav.path) ? primaryWav : fallbackWav
        let wave = try #require(wav.path.withCString { SherpaOnnxReadWave($0) })
        defer { SherpaOnnxFreeWave(wave) }
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let result = try runtime.recognize(samples: samples, windowID: "nano",
            fingerprint: "nano-native", attempt: attempt, onEvent: { _ in }, recorder: recorder)
        print("Nano native result: \(result.text), accelMask=\(runtime.acceleratorMask), load=\(recorder.value.modelLoadSeconds), total=\(Date().timeIntervalSince(started))")
        #expect(recorder.value.modelLoadSeconds < 45)
        #expect((result.text.contains("开放时间") || result.text.contains("开饭时间")) && result.text.contains("早上") && result.text.contains("下午"))
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
        #expect((noisyResult.text.contains("开放时间") || noisyResult.text.contains("开饭时间")) && noisyResult.text.contains("早上") && noisyResult.text.contains("下午"))
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

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_RUN_1H_BENCHMARK"] == "1"))
struct NanoOneHourBenchmarkTests {
    private static func cpuSeconds() -> (user: Double, sys: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) * 1e-6
        let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) * 1e-6
        return (u, s)
    }

    private static func currentAndMaxRSSMiB() -> (currentMiB: Double, maxMiB: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let cur = kr == KERN_SUCCESS ? Double(info.resident_size) / (1024.0 * 1024.0) : 0
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let mx = Double(usage.ru_maxrss) / (1024.0 * 1024.0)
        return (cur, mx)
    }

    private static func readWav(_ url: URL) throws -> [Float] {
        let wave = try #require(url.path.withCString { SherpaOnnxReadWave($0) })
        defer { SherpaOnnxFreeWave(wave) }
        #expect(wave.pointee.sample_rate == 16_000)
        return Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
    }

    @Test func funASRNanoCoreMLOneHourRuntimeAndFullSpeechEngineBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        let speechDir = URL(fileURLWithPath: try #require(env["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let nanoDir = URL(fileURLWithPath: try #require(env["MOMO_NANO_MODEL_DIRECTORY"]))
        let wavDir = URL(fileURLWithPath: try #require(env["MOMO_NANO_BENCH_WAVS"]))
        let bundle = try SpeechModelBundle.load(from: speechDir)
        let catalog = try DownloadableSpeechModel.funASRNano()

        let zh = try Self.readWav(wavDir.appendingPathComponent("zh.wav"))
        let en = try Self.readWav(wavDir.appendingPathComponent("en.wav"))
        let ja = try Self.readWav(wavDir.appendingPathComponent("ja.wav"))
        let yue = try Self.readWav(wavDir.appendingPathComponent("yue.wav"))

        // ---------------------------------------------------------------------
        // Part 1: Direct SherpaRuntime 1-hour (3,600.0s = 180 x 20.0s) dense multilingual speech
        // ---------------------------------------------------------------------
        let pause = Array(repeating: Float(0), count: Int(0.35 * 16_000))
        func build20sWindow(_ clip: [Float]) -> [Float] {
            var buf: [Float] = []
            buf.reserveCapacity(320_000)
            while buf.count < 320_000 {
                let rem = 320_000 - buf.count
                if rem <= clip.count {
                    buf.append(contentsOf: clip.prefix(rem))
                } else {
                    buf.append(contentsOf: clip)
                    let pRem = min(pause.count, 320_000 - buf.count)
                    buf.append(contentsOf: pause.prefix(pRem))
                }
            }
            return buf
        }
        let winZh = build20sWindow(zh)
        let winEn = build20sWindow(en)
        let winJa = build20sWindow(ja)
        let winYue = build20sWindow(yue)
        let templates: [(lang: String, samples: [Float], marker: String)] = [
            ("zh", winZh, "早上"),
            ("en", winEn, "gold"),
            ("ja", winJa, "学校"),
            ("yue", winYue, "意思")
        ]

        do {
            let attempt = SpeechAttempt()
            let recorder = SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id, windowID: nil, fingerprint: "1h-direct")
            let runtime = try SherpaRuntime(bundle: bundle, configuration: SpeechConfiguration(),
                backend: .sherpaCoreML, download: .init(directory: nanoDir, catalog: catalog),
                cacheRoot: nil, attempt: attempt, recorder: recorder)
            defer { runtime.close() }
            try runtime.warmUp(attempt: attempt, recorder: recorder)
            #expect(runtime.acceleratorMask == 3)

            let cpu0 = Self.cpuSeconds()
            let t0 = DispatchTime.now().uptimeNanoseconds
            var totalSamples = 0
            for i in 0..<180 {
                let tpl = templates[i % templates.count]
                let res = try runtime.recognize(samples: tpl.samples, windowID: "w-\(i)",
                    fingerprint: "1h-direct", attempt: attempt, onEvent: { _ in }, recorder: recorder)
                #expect(res.text.lowercased().contains(tpl.marker))
                totalSamples += tpl.samples.count
            }
            let wallSec = Double(DispatchTime.now().uptimeNanoseconds - t0) * 1e-9
            let cpu1 = Self.cpuSeconds()
            let rss = Self.currentAndMaxRSSMiB()
            let audioSec = Double(totalSamples) / 16_000.0
            let cpuTotal = (cpu1.user - cpu0.user) + (cpu1.sys - cpu0.sys)
            print(String(format: "[1H_DIRECT_SHERPA_RUNTIME] audio=%.1fs wall=%.2fs RTF=%.4f RTFx=%.1fx cpuUser=%.2fs cpuSys=%.2fs avgCores=%.2f curRSS=%.1fMiB maxRSS=%.1fMiB",
                         audioSec, wallSec, wallSec / audioSec, audioSec / wallSec,
                         cpu1.user - cpu0.user, cpu1.sys - cpu0.sys, cpuTotal / wallSec,
                         rss.currentMiB, rss.maxMiB))
            #expect(abs(audioSec - 3600.0) < 0.01)
            #expect(wallSec <= 300.0)
        }

        // ---------------------------------------------------------------------
        // Part 2: Full SpeechEngine 1-hour (3,600.0s = 60 x 60.0s PCM16 chunks)
        //         Silero VAD v6 + DiariZen WavLM ANE + ERes2NetV2 ANE + FunASR-Nano CoreML ANE
        // ---------------------------------------------------------------------
        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-1h-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        // Build a 60.0s (960,000 samples) conversational multi-speaker minute template (~75% speech + natural pauses)
        var minuteFloats: [Float] = []
        minuteFloats.reserveCapacity(960_000)
        let turnGap = Array(repeating: Float(0), count: Int(1.8 * 16_000))
        let turnClips = [zh, en, ja, yue, zh, en, yue]
        for clip in turnClips {
            if minuteFloats.count + clip.count <= 960_000 {
                minuteFloats.append(contentsOf: clip)
            }
            let gapLen = min(turnGap.count, 960_000 - minuteFloats.count)
            if gapLen > 0 { minuteFloats.append(contentsOf: turnGap.prefix(gapLen)) }
        }
        if minuteFloats.count < 960_000 {
            minuteFloats.append(contentsOf: repeatElement(Float(0), count: 960_000 - minuteFloats.count))
        }
        let minutePCM = minuteFloats.map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) }

        var writer = try PCM16SegmentWriter(
            directory: workRoot.appendingPathComponent("audio"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
            sourceBuild: "1h-coreml-ane-bench", sourceKind: .fixture,
            sampleRate: 16_000, targetFrames: 960_000,
            wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0
        )
        var chunks: [EncodedChunk] = []
        for _ in 0..<60 {
            chunks.append(contentsOf: try writer.append(minutePCM))
        }
        if let tail = try writer.finish() { chunks.append(tail) }
        #expect(chunks.count == 60)
        let inputs = chunks.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) }
        let totalFrames: Int64 = 60 * 960_000

        let cacheDir = workRoot.appendingPathComponent("coreml-cache", isDirectory: true)
        let speakersDir = speechDir.appendingPathComponent("Speakers", isDirectory: true)
        let engine = try SpeechEngine(
            bundle: bundle,
            configuration: SpeechConfiguration(),
            continuousArchive: true,
            recognitionBackend: .sherpaCoreML,
            coreMLCacheDirectory: cacheDir,
            speakerDirectory: speakersDir,
            speakerSegmentationModel: .diariZenWavLMBase,
            downloadedModel: .init(directory: nanoDir, catalog: catalog)
        )
        #expect(engine.configurationFingerprint == "d51e7ae14ac59455c77f473070d80d53263718d6773856eb0421f65ad9428afd")

        // Warm up both FunASR-Nano CoreML ANE and DiariZen + ERes2NetV2 CoreML caches once before timing 1h steady-state
        try await engine.warmUp()
        // Trigger 1 short prepare+transcribe on the first minute so ORT CoreML EP compiles DiariZen + ERes2NetV2 into cacheDir
        do {
            let warmInputs = [inputs[0]]
            let warmBatch = try await engine.prepare(inputs: warmInputs, boundary: .captureEnd(960_000))
            if let firstWin = warmBatch.windows.first {
                _ = try await engine.transcribe(window: firstWin, inputs: warmInputs)
            }
            engine.discardPreparedAudio()
        }

        let cpuStart = Self.cpuSeconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds

        let prepStart = DispatchTime.now().uptimeNanoseconds
        let batch = try await engine.prepare(inputs: inputs, boundary: .captureEnd(totalFrames))
        let prepSec = Double(DispatchTime.now().uptimeNanoseconds - prepStart) * 1e-9

        let sequence = try engine.makeTranscriptionSequence(inputs: inputs, anchor: 0)
        let transStart = DispatchTime.now().uptimeNanoseconds
        var nonEmptyWindows = 0
        var speakerTurnCount = 0
        let step = engine.coordinatorWindowBatchSize
        var idx = 0
        while idx < batch.windows.count {
            let end = min(idx + step, batch.windows.count)
            let slice = Array(batch.windows[idx..<end])
            let recognitions = try await engine.transcribe(windows: slice, sequence: sequence)
            for r in recognitions {
                if !r.text.isEmpty { nonEmptyWindows += 1 }
                speakerTurnCount += (r.speakerTurns?.count ?? max(1, r.speakers?.count ?? 0))
                #expect(r.speakerFailure == nil)
            }
            idx = end
        }
        await engine.close(sequence)
        let transSec = Double(DispatchTime.now().uptimeNanoseconds - transStart) * 1e-9
        let totalWallSec = Double(DispatchTime.now().uptimeNanoseconds - wallStart) * 1e-9
        let cpuEnd = Self.cpuSeconds()
        let rssEnd = Self.currentAndMaxRSSMiB()
        let cpuUsed = (cpuEnd.user - cpuStart.user) + (cpuEnd.sys - cpuStart.sys)

        print(String(format: "[1H_FULL_SPEECH_ENGINE] audio=3600.0s prepare=%.2fs transcribe=%.2fs totalWall=%.2fs RTF=%.4f RTFx=%.1fx windows=%d nonEmpty=%d speakerTurns=%d cpuUser=%.2fs cpuSys=%.2fs avgCores=%.2f curRSS=%.1fMiB maxRSS=%.1fMiB",
                     prepSec, transSec, totalWallSec, totalWallSec / 3600.0, 3600.0 / totalWallSec,
                     batch.windows.count, nonEmptyWindows, speakerTurnCount,
                     cpuEnd.user - cpuStart.user, cpuEnd.sys - cpuStart.sys, cpuUsed / totalWallSec,
                     rssEnd.currentMiB, rssEnd.maxMiB))

        #expect(nonEmptyWindows == batch.windows.count)
        #expect(speakerTurnCount >= batch.windows.count)
        #expect(totalWallSec <= 300.0)
    }
}
