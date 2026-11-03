import Foundation
import Testing
import MoMoSpeech
#if SWIFT_PACKAGE
@testable import PhonePipelineReplay
#endif

@MainActor
@Test func recognitionLanguageSelectionPersistsAndUpdatesEngine() throws {
    let suite = "MoMoAgent.speech-language-test.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
        tokensSHA256: String(repeating: "b", count: 64), vadSHA256: String(repeating: "c", count: 64))
    let bundle = SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest)
    let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
    let settings = PhoneSpeechSettings(speech: engine, defaults: defaults)
    #expect(settings.language == .automatic)
    for language in SpeechLanguage.allCases {
        settings.select(language)
        #expect(settings.language == language)
        #expect(engine.recognitionLanguage == language)
        let restored = PhoneSpeechSettings(speech: nil, defaults: defaults)
        #expect(restored.language == language)
    }
    settings.select(.mandarin)
    let restartedEngine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
    let restored = PhoneSpeechSettings(speech: restartedEngine, defaults: defaults)
    #expect(restored.language == .mandarin)
    #expect(restartedEngine.recognitionLanguage == .mandarin)
    #expect(restartedEngine.configurationFingerprint == engine.configurationFingerprint)
}

@MainActor
@Test func unsupportedSavedLanguageUsesAutomaticRecognition() throws {
    let suite = "MoMoAgent.speech-language-test.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("fr", forKey: PhoneSpeechSettings.languageKey)
    let settings = PhoneSpeechSettings(speech: nil, defaults: defaults)
    #expect(settings.language == .automatic)
    settings.select(.cantonese)
    #expect(defaults.string(forKey: PhoneSpeechSettings.languageKey) == "yue")
}

@MainActor
@Test func vadThresholdDefaultsToQuarterAndPersistsWithoutResettingCoverageIdentity() throws {
    let defaults = try #require(UserDefaults(suiteName: "MoMoAgent.vad-test.\(UUID())"))
    defer { defaults.removeObject(forKey: PhoneSpeechSettings.vadThresholdKey) }
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
        tokensSHA256: String(repeating: "b", count: 64), vadSHA256: String(repeating: "c", count: 64))
    let bundle = SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest)
    let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
    let fingerprint = engine.configurationFingerprint
    let settings = PhoneSpeechSettings(speech: engine, defaults: defaults)
    #expect(settings.vadThreshold == 0.25)
    #expect(engine.voiceActivityThreshold == 0.25)
    for value in [0.05, 0.20, 0.25, 0.5, 0.95] {
        settings.selectVADThreshold(value)
        #expect(engine.voiceActivityThreshold == Float(value))
        #expect(engine.configurationFingerprint == fingerprint)
        let restored = PhoneSpeechSettings(speech: engine, defaults: defaults)
        #expect(restored.vadThreshold == value)
    }
    settings.selectVADThreshold(.nan)
    #expect(settings.vadThreshold == 0.95)
    #expect(engine.voiceActivityThreshold == 0.95)
    #expect(settings.failure != nil)
    settings.selectVADThreshold(PhoneSpeechSettings.defaultVADThreshold)
    #expect(settings.failure == nil)
}

@MainActor
@Test func invalidSavedVADThresholdFallsBackToQuarter() throws {
    let defaults = try #require(UserDefaults(suiteName: "MoMoAgent.vad-test.\(UUID())"))
    defer { defaults.removeObject(forKey: PhoneSpeechSettings.vadThresholdKey) }
    for value in [-0.1, 0, 1.0, Double.infinity] {
        defaults.set(value, forKey: PhoneSpeechSettings.vadThresholdKey)
        #expect(PhoneSpeechSettings(speech: nil, defaults: defaults).vadThreshold == 0.25)
    }
}

@MainActor
@Test func xASRLimitsLanguagesAndRestoresOnlyAVerifiedDownload() throws {
    let suite = "MoMoAgent.speech-model-test.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
        tokensSHA256: String(repeating: "b", count: 64), vadSHA256: String(repeating: "c", count: 64))
    let bundle = SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest)
    let catalog = try DownloadableSpeechModel.xASR()
    let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
        downloadedModel: DownloadedSpeechModel(directory: root, catalog: catalog))
    let settings = PhoneSpeechSettings(speech: engine, defaults: defaults, modelDirectory: root)
    #expect(settings.models.choice == .xASR)
    #expect(settings.models.catalogs[.xASR] == catalog)
    settings.select(.japanese)
    #expect(settings.language == .automatic)
    #expect(settings.failure != nil)
    settings.select(.english)
    #expect(engine.recognitionLanguage == .english)

    // Restore needs the selection, a supported language and a complete receipt with every file at its pinned size.
    defaults.set(SpeechModelChoice.xASR.rawValue, forKey: PhoneSpeechModelSettings.selectionKey)
    #expect(PhoneSpeechModelSettings.restoredDownload(at: root, defaults: defaults) == nil)
    let directory = root.appendingPathComponent(try catalog.revision, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for file in catalog.files {
        let url = directory.appendingPathComponent(file.path)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(file.byteCount))
        try handle.close()
    }
    try JSONEncoder().encode(catalog).write(to: directory.appendingPathComponent("complete.json"))
    #expect(PhoneSpeechModelSettings.restoredDownload(at: root, defaults: defaults)?.model == .xASR)
    defaults.set(SpeechLanguage.korean.rawValue, forKey: PhoneSpeechSettings.languageKey)
    #expect(PhoneSpeechModelSettings.restoredDownload(at: root, defaults: defaults) == nil)

    // Legacy "funASRNanoCoreML" selection migrates to CPU FunASR Nano when installed, else clears cleanly.
    defaults.set(SpeechLanguage.mandarin.rawValue, forKey: PhoneSpeechSettings.languageKey)
    defaults.set("funASRNanoCoreML", forKey: PhoneSpeechModelSettings.selectionKey)
    #expect(PhoneSpeechModelSettings.restoredDownload(at: root, defaults: defaults) == nil)
    #expect(defaults.string(forKey: PhoneSpeechModelSettings.selectionKey) == nil)

    let nanoCatalog = try DownloadableSpeechModel.funASRNano()
    let nanoDir = root.appendingPathComponent(try nanoCatalog.revision, isDirectory: true)
    try FileManager.default.createDirectory(at: nanoDir, withIntermediateDirectories: true)
    for file in nanoCatalog.files {
        let url = nanoDir.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(file.byteCount))
        try handle.close()
    }
    try JSONEncoder().encode(nanoCatalog).write(to: nanoDir.appendingPathComponent("complete.json"))
    defaults.set("funASRNanoCoreML", forKey: PhoneSpeechModelSettings.selectionKey)
    #expect(PhoneSpeechModelSettings.restoredDownload(at: root, defaults: defaults)?.model == .funASRNano)
    #expect(defaults.string(forKey: PhoneSpeechModelSettings.selectionKey) == SpeechModelChoice.funASRNano.rawValue)
}
