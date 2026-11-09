import AVFAudio
import CoreAudioTypes
import Darwin
import Foundation
import MoMoContracts

/// Bridges the crash window between closing an encoder file and indexing it in RecordingStore.
enum SealedCaptureSpool {
    static let recoveryAACBitRate = 24_000
    static func sidecar(for audio: URL) -> URL { audio.appendingPathExtension("sealed.json") }
    static func draftURL(for audio: URL) -> URL { audio.appendingPathExtension("draft.json") }
    static func pcmURL(for audio: URL) -> URL { audio.appendingPathExtension("pcm") }

    static func preserveDraft(_ draft: CaptureDraft, audio: URL) throws {
        let url = draftURL(for: audio)
        try WireJSON.encode(draft).write(to: url, options: RecordingFileProtection.atomicWriteOptions)
        RecordingFileProtection.apply(to: url)
        try synchronize(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func preserve(_ chunk: EncodedChunk) throws {
        RecordingFileProtection.apply(to: chunk.audioURL)
        try synchronize(chunk.audioURL)
        let metadata = sidecar(for: chunk.audioURL)
        try WireJSON.encode(chunk.envelope).write(to: metadata, options: RecordingFileProtection.atomicWriteOptions)
        RecordingFileProtection.apply(to: metadata)
        try synchronize(metadata)
        try synchronizeDirectory(metadata.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let result = fsync(descriptor), savedError = errno
        let closed = close(descriptor)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: savedError) ?? .EIO) }
        guard closed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func remove(_ chunk: EncodedChunk) throws {
        if FileManager.default.fileExists(atPath: chunk.audioURL.path) { try FileManager.default.removeItem(at: chunk.audioURL) }
        let draft = draftURL(for: chunk.audioURL)
        if FileManager.default.fileExists(atPath: draft.path) { try FileManager.default.removeItem(at: draft) }
        let pcm = pcmURL(for: chunk.audioURL)
        if FileManager.default.fileExists(atPath: pcm.path) { try FileManager.default.removeItem(at: pcm) }
        try FileManager.default.removeItem(at: sidecar(for: chunk.audioURL))
        try synchronizeDirectory(chunk.audioURL.deletingLastPathComponent())
    }

    private static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() }
        catch { let original = error; try handle.close(); throw original }
    }
}

public struct CaptureSpoolRecovery: Sendable {
    public var recovered: [UUID] = []
    public var incompleteFiles: [String] = []
    public var damagedFiles: [String] = []
    public init() {}
}

public enum CaptureSpool {
    /// Unknown legacy audio stays in repair; a validated draft supplies explicit deletion ownership.
    public static func removeConfirmedRepairFiles(sessionID: UUID, directory: URL) throws {
        let repair = directory.appendingPathComponent("Repair").appendingPathComponent(sessionID.uuidString)
        guard try entryKind(directory) == .directory,
              try entryKind(directory.appendingPathComponent("Repair")) == .directory,
              try entryKind(repair) == .directory else { return }
        for epoch in try children(repair) {
            guard try entryKind(epoch) == .directory, UUID(uuidString: epoch.lastPathComponent) != nil else { continue }
            for draftURL in try children(epoch).filter({ $0.lastPathComponent.hasSuffix(".m4a.draft.json") }) {
                guard try entryKind(draftURL) == .regular else { continue }
                let draft: CaptureDraft
                do { draft = try WireJSON.decode(CaptureDraft.self, from: Data(contentsOf: draftURL)) }
                catch is DecodingError { continue }
                let audio = draftURL.deletingPathExtension().deletingPathExtension()
                let pcm = SealedCaptureSpool.pcmURL(for: audio)
                guard draft.version == 1, draft.sessionID == sessionID,
                      draft.epochID.uuidString == epoch.lastPathComponent,
                      audio.lastPathComponent == draft.chunkID.uuidString + ".m4a" else { continue }
                let audioKind = try entryKind(audio)
                let pcmKind = try entryKind(pcm)
                guard (audioKind == nil || audioKind == .regular),
                      (pcmKind == nil || pcmKind == .regular) else { continue }
                if audioKind != nil { try FileManager.default.removeItem(at: audio) }
                if pcmKind != nil { try FileManager.default.removeItem(at: pcm) }
                try FileManager.default.removeItem(at: draftURL)
            }
            try SealedCaptureSpool.synchronizeDirectory(epoch)
            if try children(epoch).isEmpty { try FileManager.default.removeItem(at: epoch) }
        }
        try SealedCaptureSpool.synchronizeDirectory(repair)
        if try children(repair).isEmpty { try FileManager.default.removeItem(at: repair) }
        try SealedCaptureSpool.synchronizeDirectory(repair.deletingLastPathComponent())
    }

    public static func recover(
        directory: URL,
        store: RecordingStore,
        excludingOpenEpochs: Bool = false,
        now: Date = Date(),
        repairRetentionInterval: TimeInterval = 14 * 86_400
    ) async throws -> CaptureSpoolRecovery {
        let files = FileManager.default
        var report = CaptureSpoolRecovery()
        guard let rootKind = try entryKind(directory) else { return report }
        guard rootKind == .directory else { report.damagedFiles.append(directory.lastPathComponent); return report }
        RecordingFileProtection.apply(to: directory)
        for session in try children(directory) {
            await Task.yield()
            try Task.checkCancellation()
            if session.lastPathComponent == "Repair" {
                if try entryKind(session) != .directory {
                    report.damagedFiles.append("Repair")
                } else {
                    RecordingFileProtection.apply(to: session)
                    try pruneExpiredRepairEntries(in: session, now: now, retentionInterval: repairRetentionInterval)
                    if try !children(session).isEmpty { report.incompleteFiles.append("Repair") }
                }
                continue
            }
            guard UUID(uuidString: session.lastPathComponent) != nil, try entryKind(session) == .directory else {
                try quarantineUnowned(session, root: directory)
                report.damagedFiles.append(session.lastPathComponent)
                continue
            }
            for epoch in try children(session) {
                await Task.yield()
                try Task.checkCancellation()
                guard let epochID = UUID(uuidString: epoch.lastPathComponent), try entryKind(epoch) == .directory else {
                    try quarantineUnowned(epoch, root: directory)
                    report.damagedFiles.append(session.lastPathComponent + "/" + epoch.lastPathComponent)
                    continue
                }
                // Foreground capture may already be writing while historical repair continues.
                if excludingOpenEpochs, try await store.isCaptureEpochOpen(epochID) { continue }
                for entry in try children(epoch) {
                    if entry.lastPathComponent.hasSuffix(".m4a.recovering"), try entryKind(entry) == .regular {
                        try files.removeItem(at: entry)
                        continue
                    }
                    let name = entry.lastPathComponent
                    let knownSuffix = entry.pathExtension == "m4a"
                        || name.hasSuffix(".m4a.draft.json")
                        || name.hasSuffix(".m4a.sealed.json")
                        || name.hasSuffix(".m4a.pcm")
                    if try entryKind(entry) != .regular || !knownSuffix {
                        try quarantineUnowned(entry, root: directory)
                        report.damagedFiles.append(epoch.lastPathComponent + "/" + entry.lastPathComponent)
                    }
                }
                for draftURL in try children(epoch).filter({ $0.lastPathComponent.hasSuffix(".m4a.draft.json") }) {
                    await Task.yield()
                    try Task.checkCancellation()
                    guard try entryKind(draftURL) == .regular else { continue }
                    let audio = draftURL.deletingPathExtension().deletingPathExtension()
                    let pcmURL = SealedCaptureSpool.pcmURL(for: audio)
                    guard try entryKind(audio) == nil || entryKind(audio) == .regular else { continue }
                    guard try entryKind(pcmURL) == nil || entryKind(pcmURL) == .regular else { continue }
                    guard try entryKind(SealedCaptureSpool.sidecar(for: audio)) == nil else { continue }
                    do {
                        let draft = try WireJSON.decode(CaptureDraft.self, from: Data(contentsOf: draftURL))
                        guard draft.sessionID.uuidString == session.lastPathComponent,
                              draft.epochID.uuidString == epoch.lastPathComponent,
                              audio.lastPathComponent == draft.chunkID.uuidString + ".m4a" else {
                            throw RecordingError.contentConflict(draft.chunkID)
                        }
                        let envelope: ManifestEnvelope
                        if let indexed = try await store.chunk(id: draft.chunkID) {
                            guard indexed.state != .missing, indexed.state != .damaged else { throw RecordingError.invalidAudio(draft.chunkID) }
                            if !files.fileExists(atPath: audio.path) {
                                if indexed.state == .ready {
                                    guard try ContentHash.sha256(fileAt: indexed.audioURL) == indexed.envelope.manifest.audioSHA256 else {
                                        throw RecordingError.invalidAudio(draft.chunkID)
                                    }
                                }
                                if try entryKind(pcmURL) == .regular { try files.removeItem(at: pcmURL) }
                                try files.removeItem(at: draftURL)
                                try SealedCaptureSpool.synchronizeDirectory(epoch)
                                continue
                            }
                            envelope = indexed.envelope
                        } else {
                            do {
                                envelope = try draft.envelope(audioURL: audio)
                            } catch {
                                guard isUnrecoverableDraft(error), try entryKind(pcmURL) == .regular else { throw error }
                                guard let recovered = try recoverFromPCM(
                                    pcmURL: pcmURL,
                                    audioURL: audio,
                                    draft: draft,
                                    epochDirectory: epoch
                                ) else {
                                    if try entryKind(audio) == .regular { try files.removeItem(at: audio) }
                                    if try entryKind(pcmURL) == .regular { try files.removeItem(at: pcmURL) }
                                    try files.removeItem(at: draftURL)
                                    try SealedCaptureSpool.synchronizeDirectory(epoch)
                                    continue
                                }
                                envelope = recovered
                            }
                        }
                        let chunk = EncodedChunk(audioURL: audio, envelope: envelope)
                        try SealedCaptureSpool.preserve(chunk)
                        if try entryKind(pcmURL) == .regular { try files.removeItem(at: pcmURL) }
                    } catch {
                        guard isUnrecoverableDraft(error) else { throw error }
                        try quarantineRegularFiles([audio, draftURL, pcmURL], from: epoch, root: directory)
                        report.incompleteFiles.append(audio.lastPathComponent)
                    }
                }
                let entries = try children(epoch)
                for sidecar in entries.filter({ $0.lastPathComponent.hasSuffix(".m4a.sealed.json") }) {
                    await Task.yield()
                    try Task.checkCancellation()
                    guard try entryKind(sidecar) == .regular else { continue }
                    let candidateAudio = sidecar.deletingPathExtension().deletingPathExtension()
                    let candidateDraft = SealedCaptureSpool.draftURL(for: candidateAudio)
                    let candidatePCM = SealedCaptureSpool.pcmURL(for: candidateAudio)
                    do {
                        let envelope = try WireJSON.decode(ManifestEnvelope.self, from: Data(contentsOf: sidecar))
                        let manifest = envelope.manifest
                        guard manifest.sessionID.uuidString == session.lastPathComponent,
                              manifest.epochID.uuidString == epoch.lastPathComponent,
                              sidecar.lastPathComponent == manifest.chunkID.uuidString + ".m4a.sealed.json" else {
                            throw RecordingError.contentConflict(manifest.chunkID)
                        }
                        let audio = epoch.appendingPathComponent(manifest.chunkID.uuidString).appendingPathExtension("m4a")
                        guard try entryKind(audio) == nil || entryKind(audio) == .regular else { continue }
                        let chunk = EncodedChunk(audioURL: audio, envelope: envelope)
                        // A crash after the ledger commit and audio removal may leave just this sidecar.
                        if let indexed = try await store.chunk(id: manifest.chunkID) {
                            guard indexed.envelope.manifestSHA256 == envelope.manifestSHA256 else { throw RecordingError.contentConflict(manifest.chunkID) }
                            if indexed.state == .missing || indexed.state == .damaged { throw RecordingError.invalidAudio(manifest.chunkID) }
                            if indexed.state == .ready {
                                guard try ContentHash.sha256(fileAt: indexed.audioURL) == manifest.audioSHA256 else { throw RecordingError.invalidAudio(manifest.chunkID) }
                            }
                        } else {
                            do { _ = try await store.sealChunk(audioAt: audio, envelope: envelope) }
                            catch RecordingError.deletedSession { try SealedCaptureSpool.remove(chunk); continue }
                        }
                        try SealedCaptureSpool.remove(chunk)
                        report.recovered.append(manifest.chunkID)
                    } catch is DecodingError {
                        try quarantineRegularFiles([candidateAudio, candidateDraft, candidatePCM, sidecar], from: epoch, root: directory)
                        report.damagedFiles.append(sidecar.lastPathComponent)
                    } catch is ContractError {
                        try quarantineRegularFiles([candidateAudio, candidateDraft, candidatePCM, sidecar], from: epoch, root: directory)
                        report.damagedFiles.append(sidecar.lastPathComponent)
                    } catch let error as RecordingError {
                        switch error {
                        case .invalidAudio, .contentConflict:
                            try quarantineRegularFiles([candidateAudio, candidateDraft, candidatePCM, sidecar], from: epoch, root: directory)
                            report.damagedFiles.append(sidecar.lastPathComponent)
                        default: throw error
                        }
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                        report.incompleteFiles.append(sidecar.lastPathComponent)
                    }
                }
                let remainingEntries = try children(epoch)
                for audio in remainingEntries where audio.pathExtension == "m4a" {
                    guard try entryKind(audio) == .regular else { continue }
                    // Pre-draft versions cannot recover frame identity from audio alone.
                    if try entryKind(SealedCaptureSpool.sidecar(for: audio)) == nil {
                        try quarantine([audio], from: epoch, root: directory)
                    }
                    report.incompleteFiles.append(audio.lastPathComponent)
                }
                for pcm in try children(epoch) where pcm.lastPathComponent.hasSuffix(".m4a.pcm") {
                    guard try entryKind(pcm) == .regular else { continue }
                    let audio = pcm.deletingPathExtension()
                    if try entryKind(SealedCaptureSpool.sidecar(for: audio)) == nil,
                       try entryKind(SealedCaptureSpool.draftURL(for: audio)) == nil {
                        try quarantine([pcm], from: epoch, root: directory)
                        report.incompleteFiles.append(pcm.lastPathComponent)
                    }
                }
            }
        }
        return report
    }

    private static func isUnrecoverableDraft(_ error: any Error) -> Bool {
        if error is DecodingError || error is ContractError { return true }
        if let writer = error as? AACWriterError {
            switch writer {
            case .invalidFormat, .conversionFailed, .decodedFrameMismatch: return true
            case .allocationFailed, .inputTooLarge: return false
            }
        }
        if let recording = error as? RecordingError {
            switch recording {
            case .contentConflict, .invalidAudio: return true
            default: break
            }
        }
        if let cocoa = error as? CocoaError,
           [.fileReadNoSuchFile, .fileNoSuchFile, .fileReadCorruptFile].contains(cocoa.code) { return true }
        return CaptureAudioReadFailure.requiresRepair(error)
    }

    private static func recoverFromPCM(
        pcmURL: URL,
        audioURL: URL,
        draft: CaptureDraft,
        epochDirectory: URL
    ) throws -> ManifestEnvelope? {
        guard draft.version == 1,
              draft.maximumFrames > 0,
              draft.maximumFrames <= 4_800_000,
              draft.sampleRate == 16_000 else {
            throw AACWriterError.invalidFormat
        }
        var pcmStat = stat()
        guard lstat(pcmURL.path, &pcmStat) == 0,
              (pcmStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let availableFrames = min(draft.maximumFrames, Int64(pcmStat.st_size) / 2)
        if availableFrames <= 0 {
            guard draft.closingFrameCount == nil else {
                throw AACWriterError.invalidFormat
            }
            return nil
        }
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: draft.sampleRate, channels: 1),
              let floatBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 8_192),
              let channel = floatBuffer.floatChannelData?[0] else {
            throw AACWriterError.allocationFailed
        }
        let tempURL = epochDirectory.appendingPathComponent("\(draft.chunkID.uuidString).m4a.recovering")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        defer {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
        do {
            var writerFile: AVAudioFile? = try AVAudioFile(
                forWriting: tempURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: draft.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: SealedCaptureSpool.recoveryAACBitRate,
                    AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            RecordingFileProtection.apply(to: tempURL)
            let handle = try FileHandle(forReadingFrom: pcmURL)
            defer { try? handle.close() }
            var remaining = availableFrames
            while remaining > 0 {
                let batchFrames = Int(min(8_192, remaining))
                guard let raw = try handle.read(upToCount: batchFrames * 2),
                      raw.count == batchFrames * 2 else {
                    throw AACWriterError.conversionFailed
                }
                raw.withUnsafeBytes { bytes in
                    for index in 0..<batchFrames {
                        let lo = UInt16(bytes[index * 2])
                        let hi = UInt16(bytes[index * 2 + 1]) << 8
                        let sample = Int16(bitPattern: lo | hi)
                        channel[index] = sample == .min ? -1.0 : Float(sample) / 32_767.0
                    }
                }
                floatBuffer.frameLength = AVAudioFrameCount(batchFrames)
                try writerFile?.write(from: floatBuffer)
                remaining -= Int64(batchFrames)
            }
            writerFile = nil
        }
        if FileManager.default.fileExists(atPath: audioURL.path) {
            _ = try FileManager.default.replaceItemAt(audioURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: audioURL)
        }
        RecordingFileProtection.apply(to: audioURL)
        var recoveredDraft = draft
        recoveredDraft.closingFrameCount = availableFrames
        return try recoveredDraft.envelope(audioURL: audioURL, verifyFullDecode: true)
    }

    private static func quarantineRegularFiles(_ urls: [URL], from epoch: URL, root: URL) throws {
        var regular: [URL] = []
        for url in urls where (try entryKind(url)) == .regular {
            regular.append(url)
        }
        guard !regular.isEmpty else { return }
        try quarantine(regular, from: epoch, root: root)
    }

    private static func quarantine(_ urls: [URL], from epoch: URL, root: URL) throws {
        let base = root.appendingPathComponent("Repair")
        let session = base.appendingPathComponent(epoch.deletingLastPathComponent().lastPathComponent)
        let repair = session.appendingPathComponent(epoch.lastPathComponent)
        // A damaged repair destination must not redirect writes or block healthy source files.
        guard try ensureDirectory(base), try ensureDirectory(session), try ensureDirectory(repair) else { return }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let preferred = repair.appendingPathComponent(url.lastPathComponent)
            let destination = FileManager.default.fileExists(atPath: preferred.path)
                ? repair.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                : preferred
            try FileManager.default.moveItem(at: url, to: destination)
            RecordingFileProtection.apply(to: destination)
        }
        try SealedCaptureSpool.synchronizeDirectory(repair)
        try SealedCaptureSpool.synchronizeDirectory(repair.deletingLastPathComponent())
        try SealedCaptureSpool.synchronizeDirectory(root.appendingPathComponent("Repair"))
        try SealedCaptureSpool.synchronizeDirectory(root)
        try SealedCaptureSpool.synchronizeDirectory(epoch)
    }

    private static func pruneExpiredRepairEntries(in directory: URL, now: Date, retentionInterval: TimeInterval) throws {
        guard retentionInterval >= 0, now.timeIntervalSince1970.isFinite else { return }
        for child in try children(directory) {
            guard let info = try entryStat(child) else { continue }
            if info.kind == .directory {
                RecordingFileProtection.apply(to: child)
                try pruneExpiredRepairEntries(in: child, now: now, retentionInterval: retentionInterval)
                if try children(child).isEmpty {
                    try FileManager.default.removeItem(at: child)
                }
            } else if info.modifiedAt > 0, now.timeIntervalSince1970 - info.modifiedAt > retentionInterval {
                try FileManager.default.removeItem(at: child)
            }
        }
    }

    private static func children(_ directory: URL) throws -> [URL] {
        guard try entryKind(directory) == .directory else { throw RecordingError.invalidDirectory(directory.lastPathComponent) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private enum EntryKind: Equatable { case directory, regular, other }

    private static func entryKind(_ url: URL) throws -> EntryKind? {
        try entryStat(url)?.kind
    }

    private static func entryStat(_ url: URL) throws -> (kind: EntryKind, modifiedAt: TimeInterval)? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return (.directory, modified)
        case mode_t(S_IFREG): return (.regular, modified)
        default: return (.other, modified)
        }
    }

    private static func ensureDirectory(_ url: URL) throws -> Bool {
        if let kind = try entryKind(url) {
            if kind == .directory { RecordingFileProtection.apply(to: url) }
            return kind == .directory
        }
        try RecordingFileProtection.createDirectory(at: url, withIntermediateDirectories: false)
        try SealedCaptureSpool.synchronizeDirectory(url.deletingLastPathComponent())
        return true
    }

    private static func quarantineUnowned(_ entry: URL, root: URL) throws {
        let base = root.appendingPathComponent("Repair")
        let unowned = base.appendingPathComponent("Unowned")
        let destination = unowned.appendingPathComponent(UUID().uuidString)
        guard try ensureDirectory(base), try ensureDirectory(unowned), try ensureDirectory(destination) else { return }
        // rename moves the directory entry itself; it never reads a symbolic link's target.
        try FileManager.default.moveItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        try SealedCaptureSpool.synchronizeDirectory(destination)
        try SealedCaptureSpool.synchronizeDirectory(entry.deletingLastPathComponent())
    }
}
