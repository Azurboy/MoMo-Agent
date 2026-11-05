#if DEBUG
import AVFoundation
import Foundation
import MoMoArchive
import MoMoContracts
import MoMoLink
import MoMoAgentClient

struct PhoneUITestConfiguration {
    let runID: UUID
    let rootURL: URL
    let importFixture: Bool
    var remoteFixture = false
    var timelineFixture = false
    var timelineScrollFixture = false
    var timelineTurnsFixture = false
    var lifeIllustrationsFixture = false
    var documentChange: DocumentChange? = nil
    var useSilentAudio = false
    var padSpeechForPlayback = false
    var watchStatus: WatchStatusFixture?
    var showStatusFailure = false
    enum WatchStatusFixture: String { case recording, paused, stale, restored }

    enum DocumentChange: String { case removeMarkdown = "remove-markdown" }

    static func load(container: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self? {
        guard let value = environment["MOMO_UI_TEST_RUN_ID"] else {
            guard environment["MOMO_UI_TEST_IMPORT_FIXTURE"] == nil,
                  environment["MOMO_UI_TEST_DOCUMENT_CHANGE"] == nil,
                  environment["MOMO_UI_TEST_STATUS_FAILURE"] == nil,
                  environment["MOMO_UI_TEST_WATCH_STATUS"] == nil,
                  environment["MOMO_UI_TEST_CONTROLLED_STREAM"] == nil,
                  environment["MOMO_UI_TEST_CONTROLLED_STREAM_EXPIRE_AUDIO"] == nil else { throw FixtureError.invalidRunID }
            return nil
        }
        guard let runID = UUID(uuidString: value) else { throw FixtureError.invalidRunID }
        let root = container.appendingPathComponent("Library/Caches/MoMoAgentUITests", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        let fixture = environment["MOMO_UI_TEST_IMPORT_FIXTURE"]
        var result = Self(runID: runID, rootURL: root, importFixture: fixture.map { ["1", "silence", "speech-playback"].contains($0) } ?? false)
        let timelineFixture = environment["MOMO_UI_TEST_TIMELINE_FIXTURE"]
        result.lifeIllustrationsFixture = timelineFixture == "life-illustrations"
        result.timelineScrollFixture = timelineFixture == "scroll"
        result.timelineTurnsFixture = timelineFixture == "turns"
        result.remoteFixture = timelineFixture == "remote" || timelineFixture == "chat"
        result.timelineFixture = result.lifeIllustrationsFixture || timelineFixture == "1" || result.timelineScrollFixture || result.timelineTurnsFixture || timelineFixture == "remote"
        result.useSilentAudio = fixture == "silence"
        result.padSpeechForPlayback = fixture == "speech-playback"
        result.showStatusFailure = environment["MOMO_UI_TEST_STATUS_FAILURE"] == "1"
        if let value = environment["MOMO_UI_TEST_DOCUMENT_CHANGE"] {
            guard let change = DocumentChange(rawValue: value) else { throw FixtureError.invalidDocumentChange }
            result.documentChange = change
        }
        if let value = environment["MOMO_UI_TEST_WATCH_STATUS"] {
            guard let status = WatchStatusFixture(rawValue: value) else { throw FixtureError.invalidWatchStatus }
            result.watchStatus = status
        }
        return result
    }

#if targetEnvironment(simulator)
    @MainActor func configureLifeIllustrations(_ store: LifeIllustrationStore) async throws {
        guard lifeIllustrationsFixture else { return }
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        struct Fixture: Decodable { let baseURL: URL; let credential: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: documents.appendingPathComponent("life-illustrations-fixture.json")))
        guard ["127.0.0.1", "localhost"].contains(fixture.baseURL.host), fixture.baseURL.scheme == "http" else { throw FixtureError.invalidRunID }
        let client = try AgentClient(baseURL: fixture.baseURL, credential: fixture.credential, assistantID: runID)
        store.configure(client: client, scope: "life-illustrations-fixture-" + runID.uuidString)
        await store.refresh()
        store.startPolling()
    }

    @MainActor func connectRemoteFixture(_ agent: PhoneRemoteAgent) async throws {
        guard remoteFixture, agent.connection == nil else { return }
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let file = documents.appendingPathComponent("momo-simulator-pairing.json")
        struct Pairing: Decodable { let runID: UUID; let connection: String; let credential: String }
        let pairing = try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: file))
        guard pairing.runID == runID else { throw FixtureError.invalidRunID }
        await agent.connect(configuration: pairing.connection, credential: pairing.credential)
        if agent.store != nil { try FileManager.default.removeItem(at: file) }
    }
#endif

    func stageTimeline(in archive: ArchiveStore, fingerprint: String?) async throws {
        guard timelineFixture else { return }
        let marker = rootURL.appendingPathComponent("timeline-fixture-staged")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard let audioURL = Bundle.main.url(forResource: "zh", withExtension: "wav", subdirectory: "TestFixtures") else { throw FixtureError.missingAudio }
        let audio = try AVAudioFile(forReading: audioURL)
        let bytes = try Data(contentsOf: audioURL)
        let offset = TimeZone.current.secondsFromGMT()
        let now = Date().timeIntervalSince1970
        // Keep all synthetic windows in the selected recording day, including runs between midnight and dayStartHour.
        let todayDay = TimelineDay(Date())
        let earliestBase = todayDay.startDate().timeIntervalSince1970 + 3_600
        let base = max(earliestBase, floor((now + Double(offset)) / 1_800) * 1_800 - Double(offset) - 1_800)
        let illustrationBase = todayDay.startDate().timeIntervalSince1970
        let illustrationInputs: [(Double, String)] = [
            (illustrationBase + 6.25 * 3600, "讨论代码模块的数据交接。桌上摆着白色和淡蓝色积木，用积木表示还没连好的接口。"),
            (illustrationBase + 8.5 * 3600, "继续核对数据同步的边界，先把可复用的模块拆清楚，暂时还没有决定最后的实现。"),
            (illustrationBase + 9.3 * 3600, "两个人慢慢走了一会儿，停下脚步。"),
            (illustrationBase + 11.2 * 3600, "蹲下看看脚边的叶子，同伴弯腰凑近，摊开手掌作比较。没有摘走叶子。"),
            (illustrationBase + 12.3 * 3600, "打开台灯，把白色茶杯和画册放在桌上。"),
            (illustrationBase + 14.3 * 3600, "坐在台灯旁喝茶，翻看画册。"),
            (illustrationBase + 15.2 * 3600, "明天再继续，今晚先休息。")
        ]
        let inputs: [(Double, String)] = lifeIllustrationsFixture ? illustrationInputs : remoteFixture ? [(base, "下周五给小林发方案。方案需要包含手机采集和 Mac 执行的分工。聚餐还没有定，先不要安排。")] : timelineScrollFixture ? (8...19).map {
            (todayDay.date().timeIntervalSince1970 + Double($0) * 3_600,
             "第 \($0) 时的测试录音，用于验证时间轴顺序和阅读位置。")
        } + [(todayDay.adding(days: -1).date().timeIntervalSince1970 + 23 * 3_600,
               "昨天的测试录音，用于验证切换日期后今天的阅读位置。")]: [
            (base + 30, "第一段记录讨论了时间线的设计，应该按时间归组，保留原始录音。"),
            (base + 300, "第二段记录接着讨论播放器，点进同一时段就能读文字和回听原音。"),
            (base - 1_700, "嗯"),
            (base - 3_500, "……。"),
            (base - 86_400 + 60, "昨天讨论了这周的安排，今天需要继续完成设计和实现的验证。"),
            (base - 172_800 + 60, "更早的一天记录了几个新的想法，保留日期选择与跨日回看能力。")
        ]
        for (index, value) in inputs.enumerated() {
            let sessionID = UUID(), epochID = UUID()
            let manifest = try ChunkManifest(sessionID: sessionID, epochID: epochID, sourceDeviceID: runID,
                sourceBuild: "debug-timeline-fixture", sequence: 0, frames: FrameRange(start: 0, count: audio.length),
                timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: value.0), timezoneOffset: offset,
                codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: audio.length,
                byteCount: Int64(bytes.count), audioSHA256: ContentHash.sha256(bytes), sourceKind: .fixture)
            let upload = rootURL.appendingPathComponent("timeline-\(index).wav")
            try bytes.write(to: upload)
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: upload, envelope: ManifestEnvelope(manifest: manifest)))
            try await archive.receiveEpochEnd(CaptureEpochEnded(sessionID: sessionID, epochID: epochID,
                sourceDeviceID: runID, endFrame: audio.length, reason: .stopped))
            let claimed = try await archive.claimAnalysisJob(configurationHash: fingerprint ?? "timeline-ui")
            guard let ticket = claimed else { throw FixtureError.invalidAudio }
            if timelineTurnsFixture {
                let quarter = audio.length / 4
                _ = try await archive.commitTranscript(ticket: ticket, spans: [
                    TranscriptSpan(chunkID: ticket.chunkID, frames: FrameRange(start: 0, count: quarter), text: "同一个人的连续发言，"),
                    TranscriptSpan(chunkID: ticket.chunkID, frames: FrameRange(start: quarter + 1_600, count: quarter - 1_600), text: "短暂停顿后仍放在一起。"),
                    TranscriptSpan(chunkID: ticket.chunkID, frames: FrameRange(start: quarter * 2, count: quarter), text: "这里换了一个人，应该另起一行。", startsNewSpeakerTurn: true)])
            } else {
                _ = try await archive.commitTranscript(ticket: ticket, spans: [TranscriptSpan(chunkID: ticket.chunkID,
                    frames: ticket.manifest.frames, text: value.1)])
            }
        }
        try Data("staged".utf8).write(to: marker, options: .atomic)
    }

    func stageWatchStatus(in archive: ArchiveStore, receiver: PhoneReceiveCoordinator) async throws {
        if let watchStatus {
            let directory = rootURL.appendingPathComponent("selected-watch", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let clock = SelectedWatchEventClock()
            await receiver.receive(.selectedWatchChanged(clock.select(activation: .activated,
                peerState: .available, directoryURL: directory)))
            let marker = rootURL.appendingPathComponent("watch-status-\(watchStatus.rawValue)")
            if !FileManager.default.fileExists(atPath: marker.path) {
                let sampledAt = Date().addingTimeInterval(watchStatus == .stale ? -120 : 0)
                let status = try WatchCaptureStatus(receiverLibraryInstanceID: archive.libraryInstanceID,
                    sessionID: runID, epochID: runID, activity: watchStatus == .paused ? .paused : .recording,
                    capturedDuration: 12, sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0,
                    lastSampleFrame: 192_000, timebaseHz: 16_000, lastSampleAge: 0.1)
                let snapshot = try StatusSnapshot(sourceDeviceID: runID, sourceBuild: "ui-fixture",
                    sourceStoreInstanceID: runID, revision: 1, sampledAt: sampledAt, payload: .watch(status))
                await receiver.receive(.selectedWatchStatusReceived(snapshot,
                    origin: watchStatus == .restored ? .restoredApplicationContext : .applicationContextCallback,
                    context: clock.receive()))
                try Data("staged".utf8).write(to: marker, options: .atomic)
            }
        }
    }

    func stage(in archive: ArchiveStore, controls: ControlInbox, bundle: Bundle = .main) throws {
        try applyDocumentChange()
        guard importFixture else { return }
        let marker = rootURL.appendingPathComponent("fixture-staged")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard let source = bundle.url(forResource: "zh", withExtension: "wav", subdirectory: "TestFixtures") else {
            throw FixtureError.missingAudio
        }
        guard try ContentHash.sha256(fileAt: source) == "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373" else {
            throw FixtureError.invalidAudio
        }
        let temporary = rootURL.appendingPathComponent("fixture-upload.wav")
        if useSilentAudio || padSpeechForPlayback { try writePCMFixture(matching: source, to: temporary) }
        else { try Data(contentsOf: source).write(to: temporary, options: .atomic) }
        let envelope = try manifest(for: temporary)
        _ = try archive.inbox.preserve(fileURL: temporary, envelope: envelope)
        let manifest = envelope.manifest
        var epochMessageBytes = runID.uuid
        epochMessageBytes.14 ^= 0x40
        try controls.preserve(.epochEnded(CaptureEpochEnded(messageID: UUID(uuid: epochMessageBytes), sessionID: runID,
            epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID,
            endFrame: manifest.frames.end, reason: .stopped)))
        var markMessageBytes = runID.uuid
        markMessageBytes.15 ^= 0x80
        try controls.preserve(.captureMark(CaptureMark(messageID: UUID(uuid: markMessageBytes), markID: runID, sessionID: runID, epochID: runID,
            sourceDeviceID: runID, sourceFrame: manifest.frames.count / 2)))
        try Data("staged".utf8).write(to: marker, options: .atomic)
    }

    private func applyDocumentChange() throws {
        guard let documentChange else { return }
        let marker = rootURL.appendingPathComponent("fixture-change-\(documentChange.rawValue)")
        let files = FileManager.default
        guard !files.fileExists(atPath: marker.path) else { return }
        let directory = rootURL.appendingPathComponent("Documents/recordings")
        guard let entries = files.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { throw FixtureError.missingTranscript }
        var matches: [URL] = []
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true { entries.skipDescendants(); continue }
            guard values.isRegularFile == true, url.lastPathComponent == "transcript.json",
                  let size = values.fileSize, size <= 8 * 1024 * 1024 else { continue }
            let document = try WireJSON.decode(TranscriptDocument.self, from: Data(contentsOf: url))
            if document.sessionID == runID { matches.append(url.deletingLastPathComponent()) }
        }
        guard matches.count == 1, let found = matches.first else { throw FixtureError.missingTranscript }
        switch documentChange {
        case .removeMarkdown: try files.removeItem(at: found.appendingPathComponent("transcript.md"))
        }
        try Data("applied".utf8).write(to: marker, options: .atomic)
    }

    private func manifest(for source: URL) throws -> ManifestEnvelope {
        let audio = try AVAudioFile(forReading: source)
        let format = audio.fileFormat.streamDescription.pointee
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 16,
              audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
              let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw FixtureError.invalidAudio
        }
        let anchor = Date().addingTimeInterval(-Double(audio.length) / 16_000)
        return try ManifestEnvelope(manifest: ChunkManifest(sessionID: runID, epochID: runID, chunkID: runID,
            sourceDeviceID: runID, sourceBuild: "debug-ui-fixture", sequence: 0,
            frames: FrameRange(start: 0, count: audio.length), timebaseHz: 16_000,
            wallClockAnchor: anchor, timezoneOffset: 28800, codec: .pcmInt16, sampleRate: 16_000,
            channels: 1, decodedFrameCount: audio.length, byteCount: Int64(size),
            audioSHA256: ContentHash.sha256(fileAt: source), sealedAt: anchor.addingTimeInterval(Double(audio.length) / 16_000),
            sourceKind: .fixture))
    }

    private func writePCMFixture(matching source: URL, to destination: URL) throws {
        let reference = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = reference.length + (padSpeechForPlayback ? 90 * 16_000 : 0)
        guard reference.length > 0, reference.length <= 20 * 16_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData else { throw FixtureError.invalidAudio }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(buffer.format.channelCount) {
            samples[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
        if padSpeechForPlayback {
            try reference.read(into: buffer, frameCount: AVAudioFrameCount(reference.length))
            buffer.frameLength = buffer.frameCapacity
        }
        let output = try AVAudioFile(forWriting: destination, settings: reference.fileFormat.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        try output.write(from: buffer)
    }

    enum FixtureError: Error { case invalidWatchStatus, invalidRunID, missingAudio, invalidAudio, invalidDocumentChange, missingTranscript, invalidControlledStream }
}
#endif
