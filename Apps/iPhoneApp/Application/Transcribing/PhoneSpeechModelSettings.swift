import AVFoundation
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
import MoMoArchive
import MoMoContracts
import MoMoSpeech

struct SpeechModelBenchmarkResult: Codable, Equatable, Sendable {
    let modelRawValue: String
    let audioSeconds: Double
    let totalTargetAudioSeconds: Double?
    let elapsedSeconds: Double
    let realtimeFactor: Double
    let minutesPerHour: Double
    let recognizedCharacterCount: Int
    let inProgress: Bool?
    let recordedAt: Date

    var model: SpeechModelChoice? { SpeechModelChoice(rawValue: modelRawValue) }
}

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
    private(set) var benchmarking = false
    private(set) var latestBenchmark: SpeechModelBenchmarkResult?
    private(set) var latestBenchmarkPreview: String?
    private(set) var progress: [SpeechModelChoice: SpeechModelInstaller.Progress] = [:]
    private(set) var failure: String?
    let catalogs: [SpeechModelChoice: DownloadableSpeechModel]
    @ObservationIgnored private let speech: SpeechEngine?
    @ObservationIgnored private let archive: ArchiveStore?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installers: [SpeechModelChoice: SpeechModelInstaller]
    @ObservationIgnored private let sampleLoader: (@Sendable () async throws -> [Float])?
    @ObservationIgnored private let benchmarkReportURL: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    var canBenchmark: Bool { speech != nil && (sampleLoader != nil || archive != nil) }

    init(speech: SpeechEngine?, directory: URL, defaults: UserDefaults = .standard,
         archive: ArchiveStore? = nil,
         sampleLoader: (@Sendable () async throws -> [Float])? = nil) {
        self.speech = speech
        self.archive = archive
        self.defaults = defaults
        self.sampleLoader = sampleLoader ?? archive.map { Self.archiveSampleLoader(archive: $0) }
        self.benchmarkReportURL = directory.deletingLastPathComponent().appendingPathComponent("speech-model-benchmark.json")
        if let data = try? Data(contentsOf: benchmarkReportURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            latestBenchmark = try? decoder.decode(SpeechModelBenchmarkResult.self, from: data)
        }
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

    func runBenchmark() async {
        guard !benchmarking, downloading == nil, !switching, !checking,
              let speech, let sampleLoader else { return }
        benchmarking = true
        failure = nil
        defer { benchmarking = false }
        do {
            let samples = try await sampleLoader()
            try await speech.warmUp()
            let activeModel = speech.recognitionModel
            let clock = ContinuousClock()
            let started = clock.now
            let recognized = try await speech.dictate(samples: samples)
            let duration = started.duration(to: clock.now)
            let elapsedSeconds = max(
                0.001,
                Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
            )
            let audioSeconds = Double(samples.count) / Double(SpeechConfiguration.sampleRate)
            let realtimeFactor = audioSeconds / elapsedSeconds
            let result = SpeechModelBenchmarkResult(
                modelRawValue: activeModel.rawValue,
                audioSeconds: audioSeconds,
                totalTargetAudioSeconds: audioSeconds,
                elapsedSeconds: elapsedSeconds,
                realtimeFactor: realtimeFactor,
                minutesPerHour: 60.0 / max(realtimeFactor, 0.001),
                recognizedCharacterCount: recognized.count,
                inProgress: false,
                recordedAt: Date()
            )
            latestBenchmark = result
            let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            latestBenchmarkPreview = trimmed.isEmpty ? nil : String(trimmed.prefix(96))
            writeBenchmarkReport(result)
        } catch is CancellationError {
        } catch {
            failure = String(localized: "本机速度实测未完成：\(error.localizedDescription)")
        }
    }

    func runOneHourBenchmark(sessionID targetSessionID: UUID? = nil) async {
        guard !benchmarking, downloading == nil, !switching, !checking,
              let speech, let archive else { return }
        benchmarking = true
        failure = nil
        #if canImport(UIKit)
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        defer {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            #endif
            benchmarking = false
        }
        do {
            let (timeline, parts) = try await Self.selectOneHourSessionParts(
                archive: archive,
                preferredSessionID: targetSessionID
            )
            try await speech.warmUp()
            let activeModel = speech.recognitionModel
            let maxSliceSamples = 120 * SpeechConfiguration.sampleRate
            let estimatedTotalSeconds = Double(parts.count) * 60.0
            var processedAudioSeconds = 0.0
            var cumulativeDictateSeconds = 0.0
            var totalRecognizedChars = 0
            let clock = ContinuousClock()

            var index = 0
            while index < parts.count {
                try Task.checkCancellation()
                let upper = min(parts.count, index + 2)
                let batchParts = Array(parts[index..<upper])
                index = upper
                var batchSamples: [Float] = []
                batchSamples.reserveCapacity(maxSliceSamples)
                for part in batchParts where batchSamples.count < maxSliceSamples {
                    let leased = try await archive.acquirePlaybackPart(part, in: timeline)
                    let chunkSamples: [Float]
                    do {
                        chunkSamples = try Self.decode16kMonoSamples(
                            leased,
                            limit: maxSliceSamples - batchSamples.count
                        )
                    } catch {
                        await archive.releaseAudioLease(id: leased.lease.id)
                        throw error
                    }
                    await archive.releaseAudioLease(id: leased.lease.id)
                    batchSamples.append(contentsOf: chunkSamples)
                }
                guard !batchSamples.isEmpty else { continue }
                let started = clock.now
                let recognized = try await speech.dictate(samples: batchSamples)
                let duration = started.duration(to: clock.now)
                let sliceElapsed = max(
                    0.0001,
                    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
                )
                let sliceAudioSeconds = Double(batchSamples.count) / Double(SpeechConfiguration.sampleRate)
                processedAudioSeconds += sliceAudioSeconds
                cumulativeDictateSeconds += sliceElapsed
                let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                totalRecognizedChars += trimmed.count
                if !trimmed.isEmpty {
                    latestBenchmarkPreview = String(trimmed.prefix(96))
                }
                let rtfx = processedAudioSeconds / max(cumulativeDictateSeconds, 0.001)
                let interim = SpeechModelBenchmarkResult(
                    modelRawValue: activeModel.rawValue,
                    audioSeconds: processedAudioSeconds,
                    totalTargetAudioSeconds: index < parts.count ? estimatedTotalSeconds : processedAudioSeconds,
                    elapsedSeconds: cumulativeDictateSeconds,
                    realtimeFactor: rtfx,
                    minutesPerHour: 60.0 / max(rtfx, 0.001),
                    recognizedCharacterCount: totalRecognizedChars,
                    inProgress: index < parts.count,
                    recordedAt: Date()
                )
                latestBenchmark = interim
                writeBenchmarkReport(interim)
            }
        } catch is CancellationError {
        } catch {
            failure = String(localized: "1 小时录音实测未完成：\(error.localizedDescription)")
        }
    }

    private func writeBenchmarkReport(_ result: SpeechModelBenchmarkResult) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(result).write(
            to: benchmarkReportURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private nonisolated static func selectOneHourSessionParts(
        archive: ArchiveStore,
        preferredSessionID: UUID?
    ) async throws -> (ArchivedPlaybackTimeline, [ArchivedPlaybackPart]) {
        if let preferredSessionID,
           let summary = try? await archive.recordingSummary(sessionID: preferredSessionID),
           let timeline = try? await archive.playbackTimeline(
               sessionID: summary.sessionID,
               expectedGeneration: summary.generation
           ) {
            let available = timeline.parts.filter(\.audioAvailable)
            if !available.isEmpty {
                return (timeline, Array(available.prefix(65)))
            }
        }
        let page = try await archive.recordingsPage(limit: 100)
        var bestCandidate: (distanceToHour: Int, timeline: ArchivedPlaybackTimeline, parts: [ArchivedPlaybackPart])?
        for summary in page.items where summary.chunkCount >= 45 {
            guard let timeline = try? await archive.playbackTimeline(
                sessionID: summary.sessionID,
                expectedGeneration: summary.generation
            ) else { continue }
            let available = timeline.parts.filter(\.audioAvailable)
            guard available.count >= 45 else { continue }
            let doc = try? await archive.readTranscript(sessionID: summary.sessionID)
            let totalChars = doc?.spans.reduce(0, { $0 + $1.text.count }) ?? 0
            guard totalChars >= 500 else { continue }
            let slice = available.count <= 70 ? available : Array(available.prefix(60))
            let distance = abs(available.count - 60)
            if bestCandidate == nil || distance < bestCandidate!.distanceToHour {
                bestCandidate = (distance, timeline, slice)
            }
        }
        guard let chosen = bestCandidate else {
            throw SpeechError.invalidAudio("no_one_hour_recording_available")
        }
        return (chosen.timeline, chosen.parts)
    }

    nonisolated static func archiveSampleLoader(archive: ArchiveStore) -> @Sendable () async throws -> [Float] {
        {
            let maxSamples = 120 * SpeechConfiguration.sampleRate
            let page = try await archive.recordingsPage(limit: 20)
            var fallbackSelection: (ArchivedPlaybackTimeline, [ArchivedPlaybackPart])?
            var bestSelection: (score: Int, timeline: ArchivedPlaybackTimeline, parts: [ArchivedPlaybackPart])?
            for summary in page.items where summary.chunkCount > 0 {
                guard let timeline = try? await archive.playbackTimeline(
                    sessionID: summary.sessionID,
                    expectedGeneration: summary.generation
                ) else { continue }
                let available = timeline.parts.filter(\.audioAvailable)
                guard !available.isEmpty else { continue }
                if fallbackSelection == nil {
                    fallbackSelection = (timeline, Array(available.suffix(2)))
                }
                if let document = try? await archive.readTranscript(sessionID: summary.sessionID),
                   !document.spans.isEmpty {
                    var charsByChunk: [UUID: Int] = [:]
                    for span in document.spans {
                        charsByChunk[span.chunkID, default: 0] += span.text.count
                    }
                    for idx in available.indices {
                        let slice = Array(available[max(0, idx - 1)...idx])
                        let score = slice.reduce(0) { $0 + (charsByChunk[$1.manifest.chunkID] ?? 0) }
                        if score > (bestSelection?.score ?? 0) {
                            bestSelection = (score, timeline, slice)
                        }
                    }
                    if let best = bestSelection, best.score >= 350 {
                        break
                    }
                }
            }
            let chosenSelection = bestSelection.map { ($0.timeline, $0.parts) }
            guard let (timeline, parts) = chosenSelection ?? fallbackSelection else {
                throw SpeechError.invalidAudio("no_local_recording_chunks")
            }
            var collected: [Float] = []
            collected.reserveCapacity(maxSamples)
            for part in parts where collected.count < maxSamples {
                let leased = try await archive.acquirePlaybackPart(part, in: timeline)
                let chunkSamples: [Float]
                do {
                    chunkSamples = try decode16kMonoSamples(leased, limit: maxSamples - collected.count)
                } catch {
                    await archive.releaseAudioLease(id: leased.lease.id)
                    throw error
                }
                await archive.releaseAudioLease(id: leased.lease.id)
                collected.append(contentsOf: chunkSamples)
            }
            guard !collected.isEmpty else {
                throw SpeechError.invalidAudio("empty_benchmark_samples")
            }
            return collected
        }
    }

    private nonisolated static func decode16kMonoSamples(_ part: AudioPlaybackPart, limit: Int) throws -> [Float] {
        guard limit > 0 else { return [] }
        let manifest = part.lease.manifest
        let file = try AVAudioFile(forReading: part.lease.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let start = max(0, manifest.primingFrames)
        let end = min(file.length, file.length - max(0, manifest.paddingFrames))
        guard end > start else { return [] }
        file.framePosition = start
        let sourceCount = AVAudioFrameCount(min(Int64(AVAudioFrameCount.max), end - start))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sourceCount) else {
            throw SpeechError.invalidAudio("benchmark_buffer_alloc")
        }
        try file.read(into: buffer, frameCount: sourceCount)
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let inputCount = Int(buffer.frameLength)
        let sampleRate = file.processingFormat.sampleRate
        if abs(sampleRate - Double(SpeechConfiguration.sampleRate)) < 1.0 {
            let take = min(limit, inputCount)
            return Array(UnsafeBufferPointer(start: channel, count: take))
        }
        let ratio = sampleRate / Double(SpeechConfiguration.sampleRate)
        let outputCount = min(limit, Int(Double(inputCount) / ratio))
        guard outputCount > 0 else { return [] }
        var resampled = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let pos = Double(i) * ratio
            let idx = min(inputCount - 1, Int(pos))
            let next = min(inputCount - 1, idx + 1)
            let frac = Float(pos - Double(idx))
            resampled[i] = channel[idx] * (1 - frac) + channel[next] * frac
        }
        return resampled
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
