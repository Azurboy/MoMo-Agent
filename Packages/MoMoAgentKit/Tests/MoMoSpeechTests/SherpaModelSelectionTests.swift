import Foundation
import Testing
import MoMoContracts
import MoMoSherpaBridge
@testable import MoMoSpeech

@Test func nanoCatalogPinsUpstreamFilesWithoutRequantization() throws {
    let catalog = try DownloadableSpeechModel.funASRNano()
    #expect(catalog.files.count == 6)
    #expect(catalog.files.contains { $0.path == "encoder_adaptor.int8.onnx" && $0.byteCount == 237_792_748 })
    #expect(catalog.files.contains { $0.path == "llm.int8.onnx" && $0.byteCount == 600_356_593 })
    #expect(catalog.baseURL.absoluteString.contains("6f16bd378457e13f36ccf3910df9017f96c346fb"))
    #expect(catalog.files.allSatisfy { !$0.path.contains(".mlmodel") })
}

@Test func funASRNanoCoreMLCatalogPinsUpstreamFilesWithoutRequantization() throws {
    let catalog = try DownloadableSpeechModel.funASRNanoCoreML()
    #expect(catalog.files.map(\.path).sorted() == ["model.int8.onnx", "tokens.txt"])
    #expect(catalog.files.contains { $0.path == "model.int8.onnx" && $0.byteCount == 263_531_902 })
    #expect(catalog.files.contains { $0.path == "tokens.txt" && $0.byteCount == 939_815 })
    #expect(catalog.baseURL.absoluteString.contains("ebb95fbda2a034d9a8f3b2d2cba32c104b60bed3"))
    #expect(try SpeechModelChoice.funASRNanoCoreML.catalog() == catalog)
    #expect(try catalog.revision != DownloadableSpeechModel.funASRNano().revision)
    #expect(try catalog.revision != DownloadableSpeechModel.xASR().revision)
    let unused = URL(fileURLWithPath: "/unused")
    #expect(DownloadedSpeechModel(directory: unused, catalog: catalog).model == .funASRNanoCoreML)
}

@Test func xASRCatalogPinsUpstreamFilesWithoutRequantization() throws {
    let catalog = try DownloadableSpeechModel.xASR()
    #expect(catalog.files.map(\.path).sorted() == ["decoder-epoch-99-avg-1.onnx", "encoder-epoch-99-avg-1.int8.onnx",
                                                   "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt"])
    #expect(catalog.files.contains { $0.path == "encoder-epoch-99-avg-1.int8.onnx" && $0.byteCount == 161_744_450 })
    #expect(catalog.baseURL.absoluteString.contains("ce812cc05d858539a68dd42e86f4fd7a9ce1acf0"))
    #expect(try SpeechModelChoice.xASR.catalog() == catalog)
    #expect(try SpeechModelChoice.senseVoice.catalog() == nil)
    #expect(try catalog.revision != DownloadableSpeechModel.funASRNano().revision)
    let unused = URL(fileURLWithPath: "/unused")
    #expect(DownloadedSpeechModel(directory: unused, catalog: catalog).model == .xASR)
    #expect(DownloadedSpeechModel(directory: unused, catalog: try .funASRNano()).model == .funASRNano)
}

@Test func downloadedModelReceiptDetectsSameSizeContentReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("verified model".utf8)
    let file = DownloadableSpeechModel.File(path: "encoder.onnx", asset: "encoder.onnx",
        byteCount: Int64(payload.count), sha256: ContentHash.sha256(payload))
    let model = DownloadableSpeechModel(identifier: "test-model", baseURL: URL(string: "https://example.com/model/")!, files: [file])
    let url = root.appendingPathComponent(file.path)
    try payload.write(to: url)
    try model.validateFiles(at: root, attempt: SpeechAttempt())
    #expect(ModelValidationReceipt.read(at: root) != nil)
    try Data(repeating: 0, count: payload.count).write(to: url)
    #expect(throws: SpeechModelInstallationError.fileMismatch(file.path)) {
        try model.validateFiles(at: root, attempt: SpeechAttempt())
    }
}

@Test func modelCatalogRejectsEscapingDownloadPaths() throws {
    for path in ["../model.onnx", "/model.onnx", "Qwen//vocab.json", "Qwen/../vocab.json"] {
        let file = DownloadableSpeechModel.File(path: "model.onnx", asset: path, byteCount: 1,
            sha256: String(repeating: "a", count: 64))
        let model = DownloadableSpeechModel(identifier: "test", baseURL: URL(string: "https://example.com/")!, files: [file])
        #expect(throws: SpeechModelInstallationError.invalidCatalog) { try model.validate() }
    }
}

@Test func providerCacheReusesConfigurationAndSeparatesModelRevisions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try SherpaRuntime.provider(backend: .sherpaCoreML, revision: String(repeating: "a", count: 64), cacheRoot: root)
    let same = try SherpaRuntime.provider(backend: .sherpaCoreML, revision: String(repeating: "a", count: 64), cacheRoot: root)
    let other = try SherpaRuntime.provider(backend: .sherpaCoreML, revision: String(repeating: "b", count: 64), cacheRoot: root)
    #expect(first == same)
    #expect(first != other)
    let file = URL(fileURLWithPath: String(first.dropFirst("coreml:".count)))
    let content = try String(contentsOf: file, encoding: .utf8)
    #expect(content.contains("ModelCacheDirectory="))
    #expect(content.contains("ModelFormat=MLProgram"))
    #expect(content.contains("session.intra_op.allow_spinning=0"))
}

@Test func funASRNanoForcesORTCPUProviderToPreventCoreMLGraphFragmentation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let rev = String(repeating: "c", count: 64)
    let nanoProvider = try SherpaRuntime.provider(backend: .sherpaCoreML, revision: rev, model: .funASRNano, cacheRoot: root)
    #expect(nanoProvider.hasPrefix("cpu:"))
    let nanoConfig = try String(contentsOf: URL(fileURLWithPath: String(nanoProvider.dropFirst("cpu:".count))), encoding: .utf8)
    #expect(!nanoConfig.contains("ModelFormat=MLProgram"))
    #expect(nanoConfig.contains("session.intra_op.allow_spinning=0"))

    let xASRProvider = try SherpaRuntime.provider(backend: .sherpaCoreML, revision: rev, model: .xASR, cacheRoot: root)
    #expect(xASRProvider.hasPrefix("cpu:"))
    let xASRConfig = try String(contentsOf: URL(fileURLWithPath: String(xASRProvider.dropFirst("cpu:".count))), encoding: .utf8)
    #expect(!xASRConfig.contains("ModelFormat="))
    #expect(xASRConfig.contains("session.intra_op.allow_spinning=0"))

    let senseProvider = try SherpaRuntime.provider(backend: .sherpaCoreML, revision: rev, model: .senseVoice, cacheRoot: root)
    #expect(senseProvider.hasPrefix("coreml:"))
    let senseConfig = try String(contentsOf: URL(fileURLWithPath: String(senseProvider.dropFirst("coreml:".count))), encoding: .utf8)
    #expect(senseConfig.contains("ModelFormat=MLProgram"))
    #expect(senseConfig.contains("RequireStaticInputShapes=1"))

    let funASRCoreMLProvider = try SherpaRuntime.provider(backend: .sherpaCoreML, revision: rev, model: .funASRNanoCoreML, cacheRoot: root)
    #expect(funASRCoreMLProvider.hasPrefix("coreml:"))
    let funASRCoreMLConfig = try String(contentsOf: URL(fileURLWithPath: String(funASRCoreMLProvider.dropFirst("coreml:".count))), encoding: .utf8)
    #expect(funASRCoreMLConfig.contains("ModelFormat=MLProgram"))
    #expect(funASRCoreMLConfig.contains("MLComputeUnits=CPUAndNeuralEngine"))
    #expect(funASRCoreMLConfig.contains("RequireStaticInputShapes=1"))
}

@Test func validationReceiptSurvivesVolumeDeviceNumberChangeWhileRejectingContentEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("stable-onnx-weights".utf8)
    let file = DownloadableSpeechModel.File(path: "encoder.onnx", asset: "encoder.onnx",
        byteCount: Int64(payload.count), sha256: ContentHash.sha256(payload))
    let model = DownloadableSpeechModel(identifier: "test-model", baseURL: URL(string: "https://example.com/model/")!, files: [file])
    let url = root.appendingPathComponent(file.path)
    try payload.write(to: url)
    try model.validateFiles(at: root, attempt: SpeechAttempt())
    let receiptURL = root.appendingPathComponent(".validated-model-v1.json")
    var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
    var filesObj = try #require(json["files"] as? [String: [String: Any]])
    var stampObj = try #require(filesObj[file.path])
    stampObj["device"] = 999_999
    filesObj[file.path] = stampObj
    json["files"] = filesObj
    try JSONSerialization.data(withJSONObject: json).write(to: receiptURL)
    let recorder = SpeechDiagnosticRecorder(operation: .warmUp, attemptID: UUID(), windowID: nil, fingerprint: "receipt-test")
    try model.validateFiles(at: root, attempt: SpeechAttempt(), recorder: recorder)
    #expect(recorder.value.modelHashedBytes == 0)
}

@Test func cleanFunASRTextPreservesHexColorsPathsAndStripsArtifacts() throws {
    func clean(_ raw: String) throws -> String {
        let ptr = try #require(raw.withCString { MoMoCleanFunASRText($0) })
        defer { MoMoFreeCString(ptr) }
        return String(cString: ptr)
    }
    #expect(try clean("掩码是 0xFFFF，背景色 #FFFFFF，前缀 FFFFFFF 正常。") == "掩码是 0xFFFF，背景色 #FFFFFF，前缀 FFFFFFF 正常。")
    #expect(try clean("路径 /silicon 和 /silver 以及 /silence 保留。") == "路径 /silicon 和 /silver 以及 /silence 保留。")
    #expect(try clean("<|im_start|>你好 /sil 世界 endofbreak FFFFFFFF<|im_end|><|endoftext|>") == "你好  世界")
    #expect(try clean("/sil") == "")
    #expect(try clean("FFFFFFFFFFFFFFFF") == "")
}
