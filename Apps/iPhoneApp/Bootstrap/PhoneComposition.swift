import Foundation
import os
import MoMoArchive
import MoMoContracts
import MoMoLink
import MoMoRecording
import MoMoSpeech

@MainActor
enum PhoneComposition {
    static func make(background: PhoneBackgroundTasks? = nil) throws -> PhoneRuntime {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        var container = documents.deletingLastPathComponent()
        var connectsToWatch = true
#if DEBUG
        let testConfiguration = try PhoneUITestConfiguration.load(container: container)
        if let testConfiguration {
            container = testConfiguration.rootURL
            connectsToWatch = false
        }
#endif
        let support = container.appendingPathComponent("Library/Application Support/MoMoAgent", isDirectory: true)
        let coreMLCacheRoot = container.appendingPathComponent("Library/Caches/MoMoAgent/SpeechModels", isDirectory: true)
        let directoryProtection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: directoryProtection)
        try? FileManager.default.setAttributes(directoryProtection, ofItemAtPath: support.path)
        try? FileManager.default.createDirectory(at: coreMLCacheRoot, withIntermediateDirectories: true, attributes: directoryProtection)
        try? FileManager.default.setAttributes(directoryProtection, ofItemAtPath: coreMLCacheRoot.path)
        let identityURL = support.appendingPathComponent("device-id")
        let deviceID: UUID
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let saved = try String(contentsOf: identityURL, encoding: .utf8)
            guard let id = UUID(uuidString: saved) else { throw PhoneCompositionError.invalidIdentity }
            try? FileManager.default.setAttributes(directoryProtection, ofItemAtPath: identityURL.path)
            deviceID = id
        } else {
            deviceID = UUID()
            try Data(deviceID.uuidString.utf8).write(
                to: identityURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
        let archive = try ArchiveStore(rootURL: container, receiverDeviceID: deviceID)
        let playback = AudioPlaybackController(archive: archive)
        let remoteAgent = try PhoneRemoteAgent(directory: support.appendingPathComponent("MacAgent", isDirectory: true), archive: archive, deviceID: deviceID)
        let controls = try ControlInbox(directory: support.appendingPathComponent("ControlInbox", isDirectory: true))
        let identity = ReceiverIdentity(messageID: archive.libraryInstanceID, receiverDeviceID: deviceID,
                                        libraryInstanceID: archive.libraryInstanceID)
        let receiver = PhoneReceiveCoordinator(archive: archive, controls: controls, identity: identity)
        let inbox = archive.inbox
        let phoneBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let transport: WatchConnectivityTransport?
        if connectsToWatch {
            let live = try WatchConnectivityTransport(
                preserveFile: { url, envelope in _ = try inbox.preserve(fileURL: url, envelope: envelope) },
                preserveControl: { try controls.preserve($0) },
                event: { [weak receiver] event in
                    let grant = PhoneConnectivityTask.beginSync()
                    let task = Task { @MainActor in
                        defer { grant.finish() }
                        await receiver?.receive(event)
                    }
                    grant.attach(task)
                },
                diagnosticsURL: support.appendingPathComponent("file-queue-diagnostic.json"),
                receiveAudioBlock: { try await PhoneConnectivityTask.receiveAudioBlock($0, archive: archive) },
                statusReplyProvider: { _ in try await archive.phoneStatus(sourceBuild: phoneBuild, refreshObservation: true) },
                controlReplyProvider: { [weak receiver] message in
                    let grant = PhoneConnectivityTask.beginSync()
                    defer { grant.finish() }
                    return await receiver?.inlineControlReply(for: message)
                },
                controlScopeID: archive.libraryInstanceID
            )
            receiver.attach(live)
            transport = live
        } else { transport = nil }
#if DEBUG
        try testConfiguration?.stage(in: archive, controls: controls)
#endif
        let speech: SpeechEngine?
        var speechPerformance: PhoneSpeechPerformance?
        let speechFailure: String?
        var fixedTimelineFixture = false
#if DEBUG
        fixedTimelineFixture = testConfiguration?.timelineFixture == true
#endif
        if fixedTimelineFixture {
            speech = nil; speechFailure = nil
        } else {
            do {
                guard let directory = Bundle.main.url(forResource: "Speech", withExtension: nil) else {
                    throw PhoneCompositionError.missingSpeechBundle
                }
                let backend = SpeechRecognitionBackend.sherpaCoreML
                let filenames = ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"]
                for filename in filenames {
                    let values = try directory.appendingPathComponent(filename)
                        .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                        throw PhoneCompositionError.missingSpeechBundle
                    }
                }
                let speechLog = Logger(subsystem: "com.momoagent.ios", category: "SpeechPerformance")
                let performance = PhoneSpeechPerformance(url: support.appendingPathComponent("transcription-performance.json"), backend: backend)
                speechPerformance = performance
                let bundle = try SpeechModelBundle.load(from: directory)
                pruneStaleCoreMLCaches(in: coreMLCacheRoot, retainingASRHash: bundle.manifest.asrSHA256)
                let downloadedModelsRoot = support.appendingPathComponent("SpeechModels", isDirectory: true)
                SpeechModelInstaller.repairInstalledProtection(at: downloadedModelsRoot)
                speech = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
                    continuousArchive: true,
                    recognitionBackend: backend,
                    coreMLCacheDirectory: coreMLCacheRoot,
                    speakerDirectory: directory.appendingPathComponent("Speakers"),
                    downloadedModel: PhoneSpeechModelSettings.restoredDownload(at: downloadedModelsRoot),
                    onDiagnostics: { value in
                        performance.record(value)
                        speechLog.debug("Speech \(value.operation.rawValue, privacy: .public) \(value.outcome.rawValue, privacy: .public): elapsed=\(value.elapsedSeconds), queue=\(value.queueWaitSeconds), read=\(value.audioReadSeconds), hash=\(value.audioHashSeconds), modelHash=\(value.modelHashSeconds), modelLoad=\(value.modelLoadSeconds), vadLoad=\(value.vadLoadSeconds), native=\(value.nativeDecodeSeconds), backpressure=\(value.analysisBackpressureSeconds), vadFrames=\(value.vadModelFrames), coreFrames=\(value.coreModelFrames), cachedFrames=\(value.preparedAudioModelFrames)")
                    }, onEvent: { _ in })
                speechFailure = nil
            } catch {
                speech = nil
                speechFailure = String(localized: "本地转写模型未就绪，请安装包含完整模型的构建。")
            }
        }
        // The phone is both source and receiver of earphone audio; its ledger lives beside the archive.
        let earphoneDirectory = support.appendingPathComponent("EarphoneCapture", isDirectory: true)
        let earphone = EarphoneCaptureRuntime(
            store: try RecordingStore(rootURL: earphoneDirectory.appendingPathComponent("Ledger", isDirectory: true)),
            archive: archive, deviceID: deviceID, sourceBuild: phoneBuild, directory: earphoneDirectory,
            settings: CaptureDeviceSettings())
        let runtime = try PhoneRuntime(archive: archive, remoteAgent: remoteAgent, playback: playback, receiver: receiver,
                                      transport: transport, speech: speech, speechFailure: speechFailure,
                                      backgroundTasks: background,
                                      modelDirectory: Bundle.main.url(forResource: "Speech", withExtension: nil),
                                      speechPerformance: speechPerformance, earphone: earphone)
#if DEBUG
        runtime.uiTestConfiguration = testConfiguration
#endif
        return runtime
    }

    private static func pruneStaleCoreMLCaches(in cacheRoot: URL, retainingASRHash: String) {
        let activeName = "sherpa-coreml-v2-\(retainingASRHash)"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent != activeName {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

enum PhoneCompositionError: Error { case invalidIdentity, missingSpeechBundle }
