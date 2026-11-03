import Foundation
import SherpaOnnxC
import MoMoContracts
import MoMoSherpaBridge
import onnxruntime

public struct SpeechNativeFailure: Error, Sendable {
    public enum Stage: Sendable { case load, input, decode }
    public let stage: Stage
    let detail: String
}

struct SherpaRecognitionInput {
    let samples: [Float]
    let windowID: String
    var coreRange: Range<Int>? = nil
}

private func speechAttemptIsCancelled(_ raw: UnsafeRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let attempt = Unmanaged<SpeechAttempt>.fromOpaque(raw).takeUnretainedValue()
    return attempt.cancellationUptimeNanoseconds != nil ? 1 : 0
}

/// Owns the only ASR runtime. All access, including teardown, stays on the recognition queue.
final class SherpaRuntime: @unchecked Sendable {
    private var recognizer: OpaquePointer?
    private var nanoRuntime: OpaquePointer?
    private var configuration: SpeechConfiguration
    private var fingerprint: String
    private let revision: String
    private let runtimeTag: String
    private let model: SpeechModelChoice
    private var warmed = false

    init(bundle: SpeechModelBundle, configuration: SpeechConfiguration,
         backend: SpeechRecognitionBackend, download: DownloadedSpeechModel?,
         cacheRoot: URL?, attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder,
         effectiveThreads: Int? = nil, validateBundleFiles: Bool = true) throws {
        try configuration.validate()
        try attempt.checkCancellation()
        let started = DispatchTime.now().uptimeNanoseconds
        defer { recorder.value.modelLoadSeconds += SpeechDiagnosticRecorder.seconds(since: started) }
        self.configuration = configuration
        model = download?.model ?? .senseVoice
        guard model.supports(SpeechLanguage(rawValue: configuration.language)!) else {
            throw SpeechModelSelectionError.unsupportedLanguage
        }
        let revision: String
        if let download {
            guard download.catalog == (try download.model.catalog()) else {
                throw SpeechModelInstallationError.invalidCatalog
            }
            try download.catalog.validateFiles(at: download.directory, attempt: attempt, recorder: recorder)
            revision = try download.catalog.revision
        } else {
            if validateBundleFiles {
                try bundle.validate(attempt: attempt, recorder: recorder)
            } else {
                try bundle.manifest.validate()
            }
            revision = bundle.manifest.asrSHA256
        }
        self.revision = revision
        let runtimeTag = switch model {
        case .senseVoice: "sherpa-1.13.8-coreml-v1"
        case .funASRNano: "funasr-nano-ort-cpu-naud-v2"
        case .xASR: "sherpa-1.13.8-transducer-cpu-v1"
        }
        self.runtimeTag = runtimeTag
        fingerprint = ContentHash.sha256(Data(
            "\(revision):\(runtimeTag):\(configuration.language):\(configuration.useITN)".utf8))
        let provider = try Self.provider(backend: backend, revision: revision, model: model, cacheRoot: cacheRoot)
        let directory = download?.directory ?? bundle.directory
        let cpuThreads = max(1, min(4, effectiveThreads ?? configuration.threads))
        var error = [CChar](repeating: 0, count: 2048)

        if model == .funASRNano {
            let encoderPath = directory.appendingPathComponent("encoder_adaptor.int8.onnx").path
            let llmPath = directory.appendingPathComponent("llm.int8.onnx").path
            let embeddingPath = directory.appendingPathComponent("embedding.int8.onnx").path
            let tokenizerPath = directory.appendingPathComponent("Qwen3-0.6B").path
            nanoRuntime = MoMoCreateFunASRNanoRuntime(
                encoderPath, llmPath, embeddingPath, tokenizerPath,
                Int32(cpuThreads), &error, error.count)
            guard nanoRuntime != nil else {
                throw SpeechNativeFailure(stage: .load,
                    detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
            return
        }

        if model == .xASR {
            // Offline Zipformer transducer with punctuation and casing; no language or ITN input.
            let strings = [
                provider, "greedy_search",
                directory.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path,
                directory.appendingPathComponent("decoder-epoch-99-avg-1.onnx").path,
                directory.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx").path,
                directory.appendingPathComponent("tokens.txt").path
            ].map { strdup($0) }
            defer { strings.forEach { free($0) } }
            guard strings.allSatisfy({ $0 != nil }) else { throw SpeechError.nativeInitialization }
            func pointer(_ index: Int) -> UnsafePointer<CChar>? { strings[index].map { UnsafePointer($0) } }
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = 16_000
            config.feat_config.feature_dim = 80
            config.model_config.num_threads = Int32(cpuThreads)
            config.model_config.provider = pointer(0)
            config.decoding_method = pointer(1)
            config.model_config.transducer.encoder = pointer(2)
            config.model_config.transducer.decoder = pointer(3)
            config.model_config.transducer.joiner = pointer(4)
            config.model_config.tokens = pointer(5)
            recognizer = MoMoCreateOfflineRecognizer(&config, &error, error.count)
            guard recognizer != nil else {
                throw SpeechNativeFailure(stage: .load, detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
            return
        }

        let useCoreML = backend == .sherpaCoreML && model == .senseVoice
        let senseThreads = useCoreML ? configuration.threads : cpuThreads
        let strings = [
            provider, configuration.language, "greedy_search",
            directory.appendingPathComponent("model.int8.onnx").path,
            directory.appendingPathComponent("tokens.txt").path
        ].map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw SpeechError.nativeInitialization }
        func pointer(_ index: Int) -> UnsafePointer<CChar>? { strings[index].map { UnsafePointer($0) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.num_threads = Int32(senseThreads)
        config.model_config.provider = pointer(0)
        config.decoding_method = pointer(2)
        config.model_config.tokens = pointer(4)
        config.model_config.sense_voice.model = pointer(3)
        config.model_config.sense_voice.language = pointer(1)
        config.model_config.sense_voice.use_itn = configuration.useITN ? 1 : 0
        recognizer = MoMoCreateOfflineRecognizer(&config, &error, error.count)
        guard recognizer != nil else {
            throw SpeechNativeFailure(stage: .load, detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
    }

    deinit { close() }

    func close() {
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer); self.recognizer = nil }
        if let nanoRuntime { MoMoDestroyFunASRNanoRuntime(nanoRuntime); self.nanoRuntime = nil }
    }

    func updateLanguage(_ language: SpeechLanguage) throws -> Bool {
        // Nano takes the language as a prompt; X-ASR ignores it, so neither needs a reload.
        guard (model == .funASRNano && nanoRuntime != nil) || (model == .xASR && recognizer != nil) else { return false }
        guard model.supports(language) else { throw SpeechModelSelectionError.unsupportedLanguage }
        let updated = try configuration.withLanguage(language)
        configuration = updated
        fingerprint = ContentHash.sha256(Data(
            "\(revision):\(runtimeTag):\(updated.language):\(updated.useITN)".utf8))
        return true
    }

    static func validateVersion() throws {
        guard let version = SherpaOnnxGetVersionStr(), String(cString: version) == SpeechModelManifest.sherpaVersion,
              let ort = OrtGetApiBase(), let ortVersion = ort.pointee.GetVersionString?(),
              String(cString: ortVersion) == SpeechModelManifest.ortVersion else {
            throw SpeechError.runtimeVersionMismatch
        }
    }

    func warmUp(attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder) throws {
        guard !warmed else { return }
        _ = try recognize(samples: Array(repeating: 0, count: 16_000), windowID: "warmup",
            fingerprint: "", attempt: attempt, onEvent: { _ in }, recorder: recorder)
        warmed = true
    }

    func recognize(samples: [Float], windowID: String, fingerprint: String, attempt: SpeechAttempt,
                   onEvent: @Sendable (SpeechExecutionEvent) -> Void, recorder: SpeechDiagnosticRecorder) throws -> SpeechRecognition {
        try recognizeBatch([.init(samples: samples, windowID: windowID)], fingerprint: fingerprint,
            attempt: attempt, onEvent: onEvent, recorder: recorder)[0]
    }

    func recognizeBatch(_ inputs: [SherpaRecognitionInput], fingerprint: String, attempt: SpeechAttempt,
                        onEvent: @Sendable (SpeechExecutionEvent) -> Void,
                        recorder: SpeechDiagnosticRecorder) throws -> [SpeechRecognition] {
        try attempt.checkCancellation()
        guard !inputs.isEmpty, inputs.count <= 4,
              Set(inputs.map(\.windowID)).count == inputs.count,
              inputs.allSatisfy({ !$0.samples.isEmpty
                  && $0.samples.count <= Int(configuration.maximumRecognitionFrames)
                  && $0.samples.allSatisfy(\.isFinite) }) else { throw SpeechError.incompatibleWindow }

        if model == .funASRNano {
            guard let nanoRuntime else { throw SpeechError.incompatibleWindow }
            let language = Self.nanoLanguage(SpeechLanguage(rawValue: configuration.language)!)
            let useITN: Int32 = configuration.useITN ? 1 : 0
            return try inputs.map { input in
                try attempt.checkCancellation()
                var error = [CChar](repeating: 0, count: 2048)
                var rawResult: UnsafeMutablePointer<MoMoFunASRNanoResult>?
                onEvent(.nativeDecodeStarted(windowID: input.windowID))
                let started = DispatchTime.now().uptimeNanoseconds
                let status = withExtendedLifetime(attempt) {
                    let context = UnsafeRawPointer(Unmanaged.passUnretained(attempt).toOpaque())
                    return input.samples.withUnsafeBufferPointer { buffer in
                        MoMoTranscribeFunASRNano(
                            nanoRuntime, buffer.baseAddress, Int32(buffer.count),
                            language, useITN, speechAttemptIsCancelled, context,
                            &rawResult, &error, error.count)
                    }
                }
                recorder.nativeReturned(startedAt: started, returnedAt: DispatchTime.now().uptimeNanoseconds, attempt: attempt)
                onEvent(.nativeDecodeReturned(windowID: input.windowID))
                defer { if let rawResult { MoMoDestroyFunASRNanoResult(rawResult) } }
                if status == -2 { throw SpeechError.cancelled }
                try attempt.checkCancellation()
                guard status == 1, let result = rawResult?.pointee,
                      let textPtr = result.text, let jsonPtr = result.raw_json else {
                    throw failure(.decode, error)
                }
                var output = SpeechRecognition(
                    windowID: input.windowID,
                    text: String(cString: textPtr),
                    tokens: [],
                    timestamps: [],
                    rawJSON: String(cString: jsonPtr),
                    configurationFingerprint: fingerprint)
                output.recognitionFingerprint = self.fingerprint
                return output
            }
        }

        guard let recognizer else { throw SpeechError.incompatibleWindow }
        var streams: [OpaquePointer?] = []
        defer { streams.forEach { if let stream = $0 { SherpaOnnxDestroyOfflineStream(stream) } } }
        var error = [CChar](repeating: 0, count: 2048)
        for input in inputs {
            try attempt.checkCancellation()
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw SpeechError.nativeInitialization }
            streams.append(stream)
            let accepted = input.samples.withUnsafeBufferPointer {
                MoMoAcceptWaveform(stream, $0.baseAddress, Int32($0.count), &error, error.count)
            }
            guard accepted == 1 else { throw failure(.input, error) }
        }
        try attempt.checkCancellation()
        inputs.forEach { onEvent(.nativeDecodeStarted(windowID: $0.windowID)) }
        let started = DispatchTime.now().uptimeNanoseconds
        let success = MoMoDecodeOfflineStreams(recognizer, &streams, Int32(streams.count), &error, error.count)
        recorder.nativeReturned(startedAt: started, returnedAt: DispatchTime.now().uptimeNanoseconds, attempt: attempt)
        inputs.forEach { onEvent(.nativeDecodeReturned(windowID: $0.windowID)) }
        try attempt.checkCancellation()
        guard success == 1 else { throw failure(.decode, error) }
        return try zip(inputs, streams).map { input, stream in
            guard let stream, let pointer = SherpaOnnxGetOfflineStreamResult(stream) else { throw SpeechError.nativeResult }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(pointer) }
            let result = pointer.pointee
            guard let text = result.text, let json = result.json, (0...100_000).contains(result.count) else {
                throw SpeechError.nativeResult
            }
            var tokens: [String] = []
            if result.count > 0 {
                guard let array = result.tokens_arr else { throw SpeechError.nativeResult }
                for index in 0..<Int(result.count) {
                    guard let token = array[index] else { throw SpeechError.nativeResult }
                    tokens.append(String(cString: token))
                }
            }
            let rawTimestamps = result.timestamps.map { Array(UnsafeBufferPointer(start: $0, count: Int(result.count))) } ?? []
            guard rawTimestamps.allSatisfy(\.isFinite) else { throw SpeechError.nativeResult }
            var output = SpeechRecognition(windowID: input.windowID, text: String(cString: text), tokens: tokens,
                timestamps: rawTimestamps, rawJSON: String(cString: json), configurationFingerprint: fingerprint)
            output.recognitionFingerprint = self.fingerprint
            return output
        }
    }

    private func failure(_ stage: SpeechNativeFailure.Stage, _ bytes: [CChar]) -> SpeechNativeFailure {
        SpeechNativeFailure(stage: stage, detail: bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    static func nanoLanguage(_ language: SpeechLanguage) -> String {
        switch language {
        case .automatic: ""
        case .mandarin: "中文"
        case .cantonese: "粤语"
        case .english: "英文"
        case .japanese: "日文"
        case .korean: "韩语"
        }
    }

    static func provider(backend: SpeechRecognitionBackend, revision: String,
                         model: SpeechModelChoice = .senseVoice, cacheRoot: URL?) throws -> String {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoMoAgent/SpeechModels")
        let directory = root.appendingPathComponent("sherpa-coreml-v2-\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        guard !directory.path.contains("\n"), !directory.path.contains("\r") else {
            throw SpeechError.invalidConfiguration
        }
        // ORT workers must sleep between bursts. This does not throttle active inference.
        var lines = ["SessionConfig.session.intra_op.allow_spinning=0", "SessionConfig.session.inter_op.allow_spinning=0"]
        // FunASR-Nano (LLM) and X-ASR rely on interleaved DynamicQuantizeLinear + MatMulInteger blocks:
        // - CoreML MLProgram fractures X-ASR into 511-563 partitions (15s compile / 6.5s warm load), runs 1.3-3.6x slower,
        //   and promotes rank-0 int64 downsample scalars to rank-1, crashing /encoder/{1,2,3}/downsample/If Concat;
        // - CoreML NeuralNetwork creates 345-448 partitions and runs 1.25-1.74x slower than AMX INT8 CPU;
        // - Full static FP32 dequantization bloats 154 MB -> 576 MB and overflows ANE FP16 in Zipformer2 BasicNorm (cos=0.195).
        // SenseVoice SAN-M encoders cleanly offload static subgraphs to CoreML without overflow.
        let useCoreML = backend == .sherpaCoreML && model == .senseVoice
        if useCoreML {
            lines += ["ModelFormat=MLProgram", "MLComputeUnits=CPUAndNeuralEngine",
                      "RequireStaticInputShapes=1",
                      "ModelCacheDirectory=\(directory.path)"]
        }
        let configName = useCoreML ? backend.rawValue : SpeechRecognitionBackend.sherpa.rawValue
        let url = directory.appendingPathComponent("\(configName).config")
        let bytes = Data((lines.joined(separator: "\n") + "\n").utf8)
        if (try? Data(contentsOf: url)) != bytes {
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return "\(useCoreML ? "coreml" : "cpu"):\(url.path)"
    }
}
