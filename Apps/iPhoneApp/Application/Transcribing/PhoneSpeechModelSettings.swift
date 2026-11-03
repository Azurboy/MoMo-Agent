import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
import MoMoSpeech

@MainActor @Observable
final class PhoneSpeechModelSettings {
    static let selectionKey = "speech.recognitionModel"
    private static let legacyFunASRCoreMLSelection = "funASRNanoCoreML"
    static let downloadable: [SpeechModelChoice] = [.funASRNano, .xASR]
    private(set) var choice: SpeechModelChoice
    private(set) var installed: Set<SpeechModelChoice> = []
    private(set) var checking = false
    private(set) var downloading: SpeechModelChoice?
    private(set) var switching = false
    private(set) var progress: [SpeechModelChoice: SpeechModelInstaller.Progress] = [:]
    private(set) var failure: String?
    let catalogs: [SpeechModelChoice: DownloadableSpeechModel]
    @ObservationIgnored private let speech: SpeechEngine?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installers: [SpeechModelChoice: SpeechModelInstaller]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(speech: SpeechEngine?, directory: URL, defaults: UserDefaults = .standard) {
        self.speech = speech
        self.defaults = defaults
        choice = speech?.recognitionModel ?? .senseVoice
        var catalogs: [SpeechModelChoice: DownloadableSpeechModel] = [:]
        var installers: [SpeechModelChoice: SpeechModelInstaller] = [:]
        var unavailable = false
        for model in Self.downloadable {
            do {
                guard let catalog = try model.catalog() else { continue }
                installers[model] = try SpeechModelInstaller(catalog: catalog, directory: directory)
                catalogs[model] = catalog
            } catch { unavailable = true }
        }
        self.catalogs = catalogs
        self.installers = installers
        if unavailable { failure = String(localized: "模型下载信息不可用，请更新 App。") }
        if defaults.string(forKey: Self.selectionKey) == Self.legacyFunASRCoreMLSelection {
            defaults.removeObject(forKey: Self.selectionKey)
        }
        if let saved = defaults.string(forKey: Self.selectionKey).flatMap(SpeechModelChoice.init(rawValue:)),
           saved != .senseVoice, choice != saved {
            failure = switch saved {
            case .xASR: String(localized: "X-ASR 文件未就绪，当前使用 SenseVoice。请重新下载后启用。")
            default: String(localized: "FunASR 文件未就绪，当前使用 SenseVoice。请重新下载后启用。")
            }
        }
    }

    static func pruneRetiredDownloads(at root: URL) {
        let activeCatalogs = downloadable.compactMap { try? $0.catalog() }
        guard activeCatalogs.count == downloadable.count else { return }
        SpeechModelInstaller.pruneUnreferencedDownloads(at: root, retaining: activeCatalogs)
    }

    /// Startup only checks the small receipt. Weight validation runs later on the recognition queue.
    static func restoredDownload(at root: URL, defaults: UserDefaults = .standard) -> DownloadedSpeechModel? {
        let language = defaults.string(forKey: PhoneSpeechSettings.languageKey)
            .flatMap(SpeechLanguage.init(rawValue:)) ?? .automatic
        if defaults.string(forKey: selectionKey) == legacyFunASRCoreMLSelection {
            if let migrated = verifiedDownload(for: .funASRNano, language: language, at: root) {
                defaults.set(SpeechModelChoice.funASRNano.rawValue, forKey: selectionKey)
                return migrated
            }
            defaults.removeObject(forKey: selectionKey)
            return nil
        }
        guard let model = defaults.string(forKey: selectionKey).flatMap(SpeechModelChoice.init(rawValue:)) else {
            return nil
        }
        return verifiedDownload(for: model, language: language, at: root)
    }

    private static func verifiedDownload(for model: SpeechModelChoice, language: SpeechLanguage,
                                         at root: URL) -> DownloadedSpeechModel? {
        guard model.supports(language),
              let catalog = try? model.catalog(),
              let revision = try? catalog.revision else { return nil }
        let directory = root.appendingPathComponent(revision)
        let receipt = directory.appendingPathComponent("complete.json")
        guard let size = try? receipt.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let bytes = try? Data(contentsOf: receipt),
              let saved = try? JSONDecoder().decode(DownloadableSpeechModel.self, from: bytes),
              saved == catalog else { return nil }
        for file in catalog.files {
            guard let values = try? directory.appendingPathComponent(file.path)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == file.byteCount else { return nil }
        }
        return DownloadedSpeechModel(directory: directory, catalog: catalog)
    }

    func refresh() async {
        guard !checking, downloading == nil, !switching, !installers.isEmpty else { return }
        checking = true
        defer { checking = false }
        for (model, installer) in installers {
            do {
                if try await installer.installedDirectory() != nil { installed.insert(model) }
                else { installed.remove(model) }
            } catch { installed.remove(model); failure = Self.message(error, model: model) }
        }
    }

    func downloadAndSelect(_ model: SpeechModelChoice) {
        guard downloading == nil, !switching, !checking,
              let installer = installers[model], let catalog = catalogs[model] else { return }
        downloading = model
        failure = nil
        task = Task { [self] in
            #if canImport(UIKit)
            let grant = UIApplication.shared.beginBackgroundTask(withName: "Speech model download") { [weak self] in
                Task { @MainActor in self?.pause() }
            }
            #endif
            defer {
                #if canImport(UIKit)
                if grant != .invalid { UIApplication.shared.endBackgroundTask(grant) }
                #endif
                downloading = nil
                task = nil
            }
            do {
                let directory = try await installer.install { [weak self] value in
                    Task { @MainActor in self?.progress[model] = value }
                }
                try Task.checkCancellation()
                installed.insert(model)
                try await activate(DownloadedSpeechModel(directory: directory, catalog: catalog))
            } catch is CancellationError {
                // Completed ranges remain available to the next explicit download.
            } catch {
                if !Task.isCancelled { failure = Self.message(error, model: model) }
            }
        }
    }

    func pause() { task?.cancel() }

    func select(_ model: SpeechModelChoice) {
        guard downloading == nil, !checking, !switching, choice != model else { return }
        failure = nil
        switching = true
        task = Task { [self] in
            defer { switching = false; task = nil }
            do {
                if model == .senseVoice { try await activate(nil) }
                else if let installer = installers[model], let catalog = catalogs[model],
                        let directory = try await installer.installedDirectory() {
                    try await activate(DownloadedSpeechModel(directory: directory, catalog: catalog))
                } else {
                    installed.remove(model)
                    failure = switch model {
                    case .xASR: String(localized: "请先下载 X-ASR 模型。")
                    default: String(localized: "请先下载 FunASR 模型。")
                    }
                }
            } catch { failure = Self.message(error, model: model) }
        }
    }

    func removeDownload(_ model: SpeechModelChoice) {
        guard choice != model, downloading == nil, !switching, !checking, let installer = installers[model] else { return }
        checking = true
        task = Task { [self] in
            defer { checking = false; task = nil }
            do {
                try await installer.remove()
                installed.remove(model)
                progress[model] = nil
                failure = nil
            } catch { failure = Self.message(error, model: model) }
        }
    }

    private func activate(_ download: DownloadedSpeechModel?) async throws {
        guard let speech else { throw SpeechError.nativeInitialization }
        switching = true
        defer { switching = false }
        try await speech.selectRecognitionModel(download)
        choice = speech.recognitionModel
        defaults.set(choice.rawValue, forKey: Self.selectionKey)
    }

    private static func message(_ error: Error, model: SpeechModelChoice) -> String {
        if case SpeechModelInstallationError.insufficientSpace(let required) = error {
            return String(localized: "可用空间不足，下载还需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))。")
        }
        if case SpeechModelSelectionError.unsupportedLanguage = error {
            return switch model {
            case .xASR: String(localized: "X-ASR 只支持中文和英文。请先将识别语言改为自动、中文或英文。")
            default: String(localized: "FunASR 不支持韩语。请先将识别语言改为自动、中文、英文或日文。")
            }
        }
        if case SpeechModelInstallationError.fileMismatch = error {
            return String(localized: "模型文件校验失败，请重试下载。")
        }
        if error is URLError {
            return String(localized: "下载中断。已下载的部分已保存，可以继续下载。")
        }
        return String(localized: "模型未能启用，请重试。当前模型保持不变。")
    }
}
