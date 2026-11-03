import Foundation

public enum SpeechModelChoice: String, CaseIterable, Sendable {
    case senseVoice
    case funASRNano
    case xASR

    public func supports(_ language: SpeechLanguage) -> Bool {
        switch self {
        case .senseVoice: true
        case .funASRNano: language != .korean
        // The X-ASR checkpoint is trained on Mandarin, English and code-switched speech only.
        case .xASR: [SpeechLanguage.automatic, .mandarin, .english].contains(language)
        }
    }

    /// The app-pinned download catalog. SenseVoice ships in the app bundle.
    public func catalog() throws -> DownloadableSpeechModel? {
        switch self {
        case .senseVoice: nil
        case .funASRNano: try .funASRNano()
        case .xASR: try .xASR()
        }
    }
}

/// An immutable, verified download. The default model remains in the app bundle.
public struct DownloadedSpeechModel: Equatable, Sendable {
    public let directory: URL
    public let catalog: DownloadableSpeechModel

    public init(directory: URL, catalog: DownloadableSpeechModel) {
        self.directory = directory
        self.catalog = catalog
    }

    /// Runtime construction still compares the whole catalog; the identifier only names the model.
    public var model: SpeechModelChoice {
        catalog.identifier == DownloadableSpeechModel.xASRIdentifier ? .xASR : .funASRNano
    }
}

public enum SpeechModelSelectionError: Error, Equatable, Sendable {
    case unsupportedLanguage
}

public enum SpeakerSegmentationModel: String, Codable, CaseIterable, Sendable {
    case diariZenWavLMBase
    case pyannoteCommunity1

    public var filename: String {
        switch self {
        case .diariZenWavLMBase: "diarizen-wavlm-base-s80-md.onnx"
        case .pyannoteCommunity1: "segmentation-community-1.onnx"
        }
    }

    public var sha256: String {
        switch self {
        case .diariZenWavLMBase: "ddc29bab8f9331ea26398becf6af5c57ff513f1f2d49200f68a5547799b3563a"
        case .pyannoteCommunity1: "62d59a487d8ba877d0bd1638c53aa06a810bdb104fb776a27ec2204521711006"
        }
    }
}
