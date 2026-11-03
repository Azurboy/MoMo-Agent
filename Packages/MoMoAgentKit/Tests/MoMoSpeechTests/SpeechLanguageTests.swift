import Foundation
import Testing
@testable import MoMoSpeech

@Test(arguments: SpeechLanguage.allCases)
func languageSelectionMatchesModelCapabilities(language: SpeechLanguage) throws {
    #expect(SpeechModelChoice.senseVoice.supports(language))
    #expect(SpeechModelChoice.funASRNano.supports(language) == (language != .korean))
    #expect(SpeechModelChoice.xASR.supports(language) == [.automatic, .mandarin, .english].contains(language))
    #expect(SherpaRuntime.nanoLanguage(.automatic).isEmpty)
    if language != .automatic { #expect(!SherpaRuntime.nanoLanguage(language).isEmpty) }
}

@Test func changingLanguageKeepsAnalysisIdentityAndConfiguration() throws {
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
        tokensSHA256: String(repeating: "b", count: 64), vadSHA256: String(repeating: "c", count: 64))
    let bundle = SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest)
    let original = try SpeechConfiguration(threads: 1, threshold: 0.6, minimumSpeechSeconds: 0.4,
        minimumSilenceSeconds: 0.8, paddingFrames: 3_200, maximumCoreFrames: 160_000)
    let engine = try SpeechEngine(bundle: bundle, configuration: original)
    let fingerprint = engine.configurationFingerprint
    #expect(engine.recognitionLanguage == .automatic)
    for language in SpeechLanguage.allCases {
        try engine.setRecognitionLanguage(language)
        #expect(engine.recognitionLanguage == language)
        #expect(engine.configurationFingerprint == fingerprint)
        #expect(try original.withLanguage(language).withLanguage(.automatic) == original)
    }
    let restarted = try SpeechEngine(bundle: bundle, configuration: original)
    try restarted.setRecognitionLanguage(.mandarin)
    #expect(restarted.configurationFingerprint == fingerprint)
    #expect(throws: SpeechError.invalidConfiguration) { try SpeechConfiguration(language: "fr") }
    #expect(Set(SpeechLanguage.allCases.map(\.rawValue)) == ["auto", "zh", "yue", "en", "ja", "ko"])
}

@Test func xASRDownloadLimitsEngineLanguagesToChineseAndEnglish() throws {
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
        tokensSHA256: String(repeating: "b", count: 64), vadSHA256: String(repeating: "c", count: 64))
    let bundle = SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest)
    let download = DownloadedSpeechModel(directory: URL(fileURLWithPath: "/unused"), catalog: try .xASR())
    #expect(throws: SpeechModelSelectionError.unsupportedLanguage) {
        try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration().withLanguage(.cantonese),
            downloadedModel: download)
    }
    let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), downloadedModel: download)
    #expect(engine.recognitionModel == .xASR)
    #expect(engine.archiveBatchSize == 1)
    try engine.setRecognitionLanguage(.english)
    #expect(throws: SpeechModelSelectionError.unsupportedLanguage) { try engine.setRecognitionLanguage(.japanese) }
    #expect(engine.recognitionLanguage == .english)
}
