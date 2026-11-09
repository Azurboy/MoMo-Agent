import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

private enum EncoderExit: Error { case stopped }

@Suite(.serialized)
struct CaptureDraftRecoveryTests {
    @Test func backgroundRecoveryLeavesTheLiveEpochUntouched() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let store = try fixture.store()
        try await store.beginEpoch(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID)
        let spool = fixture.root.appendingPathComponent("Encoding")
        let epoch = spool.appendingPathComponent(m.sessionID.uuidString).appendingPathComponent(m.epochID.uuidString)
        let writer = try AACSegmentWriter(directory: epoch, sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", sourceKind: .fixture,
            inputSampleRate: 16_000, targetSeconds: 1, wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        for _ in 0..<5 { _ = try writer.append(Array(repeating: 0.1, count: 4_000)) }
        let entries = try FileManager.default.contentsOfDirectory(at: epoch, includingPropertiesForKeys: nil)
        let original = try Dictionary(uniqueKeysWithValues: entries.map { ($0, try Data(contentsOf: $0)) })
        let skipped = try await CaptureSpool.recover(directory: spool, store: store, excludingOpenEpochs: true)
        #expect(skipped.recovered.isEmpty && skipped.incompleteFiles.isEmpty && skipped.damagedFiles.isEmpty)
        #expect(try await store.pendingChunks().isEmpty)
        for (url, bytes) in original { #expect(try Data(contentsOf: url) == bytes) }
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathComponent("Repair").path))

        _ = try writer.finish()
        try await store.recordEpochEnded(CaptureEpochEnded(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, endFrame: 20_000, reason: .paused))
        let recovered = try await CaptureSpool.recover(directory: spool, store: store, excludingOpenEpochs: true)
        #expect(recovered.recovered.count == 2)
        #expect(try await store.sealedDuration(sessionID: m.sessionID) == 1.25)
        #expect(try await store.sealedDuration(sessionID: m.sessionID, excludingEpochID: m.epochID) == 0)
    }

    @Test func closedContainerWithoutFinalSidecarRecoversItsOriginalFramePosition() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let spool = fixture.root.appendingPathComponent("Encoding")
        let directory = spool.appendingPathComponent(m.sessionID.uuidString).appendingPathComponent(m.epochID.uuidString)
        let writer = try AACSegmentWriter(directory: directory, sessionID: m.sessionID, epochID: m.epochID,
                                         sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", sourceKind: .fixture,
                                         inputSampleRate: 16_000, targetSeconds: 1,
                                         wallClockAnchor: m.wallClockAnchor, timezoneOffset: m.timezoneOffset)
        var first: [EncodedChunk] = []
        for _ in 0..<4 { first += try writer.append(Array(repeating: 0.1, count: 4_000)) }
        #expect(first.count == 1)
        _ = try writer.append(Array(repeating: 0.2, count: 4_000))
        var tailURL: URL?
        writer.sealCheckpoint = { step, url in
            if case .afterContainerClose = step { tailURL = url; throw EncoderExit.stopped }
        }
        #expect(throws: EncoderExit.self) { try writer.finish() }
        let tail = try #require(tailURL)
        let originalHash = try ContentHash.sha256(fileAt: tail)
        let draft = try WireJSON.decode(CaptureDraft.self, from: Data(contentsOf: SealedCaptureSpool.draftURL(for: tail)))
        #expect(draft.startFrame == 16_000 && draft.closingFrameCount == 4_000)
        #expect(!FileManager.default.fileExists(atPath: SealedCaptureSpool.sidecar(for: tail).path))
        let store = try fixture.store()
        let recovered = try await CaptureSpool.recover(directory: spool, store: store)
        #expect(recovered.recovered.count == 2)
        let stored = try await store.chunk(id: draft.chunkID)
        let indexed = try #require(stored)
        #expect(indexed.envelope.manifest.frames == (try FrameRange(start: 16_000, count: 4_000)))
        #expect(indexed.envelope.manifest.wallClockAnchor == m.wallClockAnchor)
        #expect(indexed.envelope.manifest.audioSHA256 == originalHash)
        #expect(try ContentHash.sha256(fileAt: indexed.audioURL) == originalHash)
        #expect(try await CaptureSpool.recover(directory: spool, store: store).recovered.isEmpty)
    }

    @Test func interruptedUnclosedContainerKeepsDraftAndEveryOriginalByte() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let live = fixture.root.appendingPathComponent("live")
        let spool = fixture.root.appendingPathComponent("snapshot")
        let snapshot = spool.appendingPathComponent(m.sessionID.uuidString).appendingPathComponent(m.epochID.uuidString)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let writer = try AACSegmentWriter(directory: live, sessionID: m.sessionID, epochID: m.epochID,
                                         sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", sourceKind: .fixture,
                                         inputSampleRate: 16_000, wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        _ = try writer.append(Array(repeating: 0.1, count: 4_096))
        var copiedAudio: URL?
        writer.sealCheckpoint = { step, audio in
            if case .beforeContainerClose = step {
                let destination = snapshot.appendingPathComponent(audio.lastPathComponent)
                try FileManager.default.copyItem(at: audio, to: destination)
                try FileManager.default.copyItem(at: SealedCaptureSpool.draftURL(for: audio), to: SealedCaptureSpool.draftURL(for: destination))
                copiedAudio = destination
                throw EncoderExit.stopped
            }
        }
        #expect(throws: EncoderExit.self) { try writer.finish() }
        let audio = try #require(copiedAudio)
        let original = try Data(contentsOf: audio)
        let store = try fixture.store()
        let result = try await CaptureSpool.recover(directory: spool, store: store)
        // A live m4a has no finalized packet table. Preserve it instead of manufacturing its tail.
        #expect(result.recovered.isEmpty)
        #expect(try await store.pendingChunks().isEmpty)
        let repair = spool.appendingPathComponent("Repair").appendingPathComponent(m.sessionID.uuidString)
            .appendingPathComponent(m.epochID.uuidString).appendingPathComponent(audio.lastPathComponent)
        #expect(try Data(contentsOf: repair) == original)
        #expect(FileManager.default.fileExists(atPath: SealedCaptureSpool.draftURL(for: repair).path))
        #expect(try await CaptureSpool.recover(directory: spool, store: store).incompleteFiles == ["Repair"])
        try CaptureSpool.removeConfirmedRepairFiles(sessionID: m.sessionID, directory: spool)
        #expect(!FileManager.default.fileExists(atPath: repair.path))
        #expect(try await CaptureSpool.recover(directory: spool, store: store).incompleteFiles.isEmpty)
    }

    @Test func legacyAudioWithoutAnyManifestIsQuarantinedUnchanged() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let session = UUID(), epoch = UUID(), chunk = UUID()
        let spool = fixture.root.appendingPathComponent("legacy")
        let directory = spool.appendingPathComponent(session.uuidString).appendingPathComponent(epoch.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent(chunk.uuidString).appendingPathExtension("m4a")
        let original = Data([0, 1, 2, 3, 4])
        try original.write(to: audio)
        let store = try fixture.store()
        let result = try await CaptureSpool.recover(directory: spool, store: store)
        #expect(result.recovered.isEmpty && result.incompleteFiles == [audio.lastPathComponent])
        let repair = spool.appendingPathComponent("Repair").appendingPathComponent(session.uuidString)
            .appendingPathComponent(epoch.uuidString).appendingPathComponent(audio.lastPathComponent)
        #expect(try Data(contentsOf: repair) == original)
        #expect(try await store.pendingChunks().isEmpty)
        try CaptureSpool.removeConfirmedRepairFiles(sessionID: session, directory: spool)
        #expect(try Data(contentsOf: repair) == original)
    }

    @Test(arguments: [false, true])
    func malformedEntriesAndSymlinksCannotBlockHealthyAudioOrPendingDeletion(repairIsSymlink: Bool) async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let spool = fixture.root.appendingPathComponent("Encoding")
        let session = spool.appendingPathComponent(m.sessionID.uuidString)
        let epoch = session.appendingPathComponent(m.epochID.uuidString)
        let writer = try AACSegmentWriter(directory: epoch, sessionID: m.sessionID, epochID: m.epochID,
                                         sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", sourceKind: .fixture,
                                         inputSampleRate: 16_000, wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        _ = try writer.append(Array(repeating: 0.1, count: 2_048))
        let finished = try writer.finish()
        let chunk = try #require(finished.first)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel")
        let sentinelBytes = Data("external data must stay unchanged".utf8)
        try sentinelBytes.write(to: sentinel)
        let invalidRoot = spool.appendingPathComponent("not-a-session")
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: false)
        try Data([1, 2]).write(to: invalidRoot.appendingPathComponent("unknown"))
        try Data([3, 4]).write(to: spool.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createSymbolicLink(at: spool.appendingPathComponent(UUID().uuidString), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("not-an-epoch"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: session.appendingPathComponent(UUID().uuidString), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: epoch.appendingPathComponent(UUID().uuidString + ".m4a.sealed.json"), withDestinationURL: sentinel)
        try FileManager.default.createSymbolicLink(at: epoch.appendingPathComponent(UUID().uuidString + ".m4a"), withDestinationURL: outside.appendingPathComponent("missing"))
        if repairIsSymlink {
            try FileManager.default.createSymbolicLink(at: spool.appendingPathComponent("Repair"), withDestinationURL: outside)
        }
        let store = try fixture.store()
        let deletion = try DeleteSession(sessionID: UUID(), generation: 1)
        try await store.prepareDeletion(deletion, deviceID: UUID())
        _ = try await store.recover()
        let result = try await CaptureSpool.recover(directory: spool, store: store)
        #expect(result.recovered == [chunk.envelope.manifest.chunkID])
        #expect(result.damagedFiles.count >= 7)
        let indexed = try await store.chunk(id: chunk.envelope.manifest.chunkID)
        let recovered = try #require(indexed)
        #expect(try ContentHash.sha256(fileAt: recovered.audioURL) == chunk.envelope.manifest.audioSHA256)
        _ = try await store.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
        #expect(try await store.pendingDeletions().isEmpty)
        #expect(try await store.pendingChunks().count == 1)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel"])
        if !repairIsSymlink {
            #expect(!FileManager.default.fileExists(atPath: invalidRoot.path))
            let quarantines = try FileManager.default.contentsOfDirectory(atPath: spool.appendingPathComponent("Repair/Unowned").path)
            #expect(quarantines.count == 7)
        }
        #expect(try await CaptureSpool.recover(directory: spool, store: store).recovered.isEmpty)
    }

    @Test func interruptedLiveWriterWithPCMSidecarRecoversExactTailFramesIntoStore() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let live = fixture.root.appendingPathComponent("live")
        let spool = fixture.root.appendingPathComponent("snapshot")
        let snapshot = spool.appendingPathComponent(m.sessionID.uuidString).appendingPathComponent(m.epochID.uuidString)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let writer = try AACSegmentWriter(directory: live, sessionID: m.sessionID, epochID: m.epochID,
                                         sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", sourceKind: .fixture,
                                         inputSampleRate: 16_000, wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        let inputSamples = (0..<4_096).map { Float(sin(Double($0) * 0.07)) * 0.25 }
        _ = try writer.append(inputSamples)
        var copiedChunkID: UUID?
        writer.sealCheckpoint = { step, audio in
            if case .beforeContainerClose = step {
                let destination = snapshot.appendingPathComponent(audio.lastPathComponent)
                try FileManager.default.copyItem(at: audio, to: destination)
                let draft = try WireJSON.decode(CaptureDraft.self, from: Data(contentsOf: SealedCaptureSpool.draftURL(for: audio)))
                var activeDraft = draft
                activeDraft.closingFrameCount = nil // Simulate abrupt termination during append before finish() began.
                try WireJSON.encode(activeDraft).write(to: SealedCaptureSpool.draftURL(for: destination))
                try FileManager.default.copyItem(at: SealedCaptureSpool.pcmURL(for: audio), to: SealedCaptureSpool.pcmURL(for: destination))
                copiedChunkID = draft.chunkID
                throw EncoderExit.stopped
            }
        }
        #expect(throws: EncoderExit.self) { try writer.finish() }
        let chunkID = try #require(copiedChunkID)
        let store = try fixture.store()
        let result = try await CaptureSpool.recover(directory: spool, store: store)
        #expect(result.recovered == [chunkID])
        #expect(result.incompleteFiles.isEmpty)
        #expect(result.damagedFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathComponent("Repair").path))
        #expect(try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil).isEmpty)

        let stored = try #require(await store.chunk(id: chunkID))
        #expect(stored.state == .ready)
        #expect(stored.envelope.manifest.frames == (try FrameRange(start: 0, count: 4_096)))
        #expect(stored.envelope.manifest.decodedFrameCount == 4_096)
        #expect(try ContentHash.sha256(fileAt: stored.audioURL) == stored.envelope.manifest.audioSHA256)
        #expect(try await CaptureSpool.recover(directory: spool, store: store).recovered.isEmpty)
    }

    @Test func interruptedZeroFrameOpenContainerCleansUpWithoutFalseRepairAlert() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let m = fixture.envelope.manifest
        let spool = fixture.root.appendingPathComponent("empty-open")
        let epoch = spool.appendingPathComponent(m.sessionID.uuidString).appendingPathComponent(m.epochID.uuidString)
        try FileManager.default.createDirectory(at: epoch, withIntermediateDirectories: true)
        let chunkID = UUID()
        let audio = epoch.appendingPathComponent(chunkID.uuidString).appendingPathExtension("m4a")
        let draft = CaptureDraft(version: 1, sessionID: m.sessionID, epochID: m.epochID, chunkID: chunkID,
                                 sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", sourceKind: .fixture,
                                 sequence: 0, startFrame: 0, maximumFrames: 960_000,
                                 sampleRate: 16_000, wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0)
        try Data(repeating: 0, count: 28).write(to: audio)
        try SealedCaptureSpool.preserveDraft(draft, audio: audio)
        try Data().write(to: SealedCaptureSpool.pcmURL(for: audio))

        let store = try fixture.store()
        let result = try await CaptureSpool.recover(directory: spool, store: store)
        #expect(result.recovered.isEmpty)
        #expect(result.incompleteFiles.isEmpty)
        #expect(result.damagedFiles.isEmpty)
        #expect(try await store.pendingChunks().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathComponent("Repair").path))
        #expect(try FileManager.default.contentsOfDirectory(at: epoch, includingPropertiesForKeys: nil).isEmpty)
    }
}
