import Foundation
import Testing
import MoMoContracts
import MoMoLink
@testable import MoMoArchive

struct LocalSyncIntegrationTests {
    @Test func binaryAudioBlockFramingAndNoProbeFastStartPreserveIntegrity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("momo-bin-block-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let receiverID = UUID()
        let store = try ArchiveStore(rootURL: root, receiverDeviceID: receiverID)
        let libraryID = store.libraryInstanceID
        let sessionID = UUID(), epochID = UUID(), sourceID = UUID()
        let audio = makeTestWAV(frameCount: 28_000)
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(
            sessionID: sessionID, epochID: epochID, sourceDeviceID: sourceID, sourceBuild: "tests",
            sequence: 0, frames: FrameRange(start: 0, count: 28_000), timebaseHz: 16_000,
            wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 28_800,
            codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 28_000,
            byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture))
        let fileURL = root.appendingPathComponent("chunk.wav")
        try audio.write(to: fileURL)

        actor ProbeRecorder {
            var sawEmptyProbe = false
            var sliceCount = 0
            func record(isEmpty: Bool) {
                sliceCount += 1
                if isEmpty { sawEmptyProbe = true }
            }
        }
        let recorder = ProbeRecorder()
        let receipt = try await AudioBlockTransfer.send(
            file: fileURL,
            envelope: envelope,
            receiverDeviceID: receiverID,
            libraryInstanceID: libraryID,
            initialProbe: false,
            maximumSliceBytes: AudioBlock.maximumPayloadBytes
        ) { block in
            await recorder.record(isEmpty: block.payload.isEmpty)
            let wire = try block.binaryWireMetadata()
            let header = try #require(wire["audio_block_header"] as? Data)
            let payload = try #require(wire["audio_block_payload"] as? Data)
            let decoded = try AudioBlock(binaryHeaderData: header, payload: payload)
            return try await store.receiveAudioBlock(decoded)
        }
        #expect(await !recorder.sawEmptyProbe)
        #expect(await recorder.sliceCount == 2)
        #expect(receipt.matches(envelope))
    }

    @Test func localSyncServerAuthenticatesStreamsChunksAndAppliesReceiptsInBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("momo-local-sync-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let receiverID = UUID()
        let store = try ArchiveStore(rootURL: root, receiverDeviceID: receiverID)
        let libraryID = store.libraryInstanceID
        let server = try LocalSyncServer(
            handlers: LocalSyncHandlers(
                receiverDeviceID: receiverID,
                libraryInstanceID: libraryID,
                receiveChunk: { envelope, data in
                    try await store.receiveDirectChunk(
                        envelope: envelope,
                        audioData: data,
                        receiverDeviceID: receiverID,
                        libraryInstanceID: libraryID)
                },
                applyReceipts: { items in
                    try await store.applyReceipts(items)
                }
            ),
            includeLoopback: true
        )
        try server.start()
        defer { server.stop() }

        var endpoint: LocalSyncEndpoint?
        for _ in 0..<50 {
            if let current = server.currentEndpoint(),
               let loopback = current.baseURLs.first(where: { $0.contains("127.0.0.1") }) {
                endpoint = try LocalSyncEndpoint(baseURLs: [loopback], bearerToken: current.bearerToken)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let activeEndpoint = try #require(endpoint)
        let client = LocalSyncClient()

        let wrongTokenEndpoint = try LocalSyncEndpoint(
            baseURLs: activeEndpoint.baseURLs,
            bearerToken: String(repeating: "f", count: 64))
        #expect(await client.probe(
            endpoint: wrongTokenEndpoint,
            expectedReceiverDeviceID: receiverID,
            expectedLibraryInstanceID: libraryID) == nil)

        for preferDirect in [true, false] {
            let route = try #require(await client.probe(
                endpoint: activeEndpoint,
                expectedReceiverDeviceID: receiverID,
                expectedLibraryInstanceID: libraryID,
                preferDirectWiFi: preferDirect))
            #expect(route.transport == (preferDirect ? .directWiFi : .urlSession))

            let sessionID = UUID(), epochID = UUID(), sourceID = UUID()
            var chunks: [(envelope: ManifestEnvelope, url: URL)] = []
            for index in 0..<6 {
                let frames: Int64 = 8_000
                let audio = makeTestWAV(frameCount: Int(frames), fillByte: UInt8(index + 1))
                let envelope = try ManifestEnvelope(manifest: ChunkManifest(
                    sessionID: sessionID, epochID: epochID, sourceDeviceID: sourceID, sourceBuild: "tests",
                    sequence: Int64(index), frames: FrameRange(start: Int64(index) * frames, count: frames),
                    timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000),
                    timezoneOffset: 28_800, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
                    decodedFrameCount: frames, byteCount: Int64(audio.count),
                    audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture))
                let fileURL = root.appendingPathComponent("src-\(preferDirect)-\(index).wav")
                try audio.write(to: fileURL)
                chunks.append((envelope, fileURL))
            }

            let receipts = try await withThrowingTaskGroup(of: Receipt.self) { group in
                for item in chunks {
                    group.addTask {
                        try await client.uploadChunk(route: route, envelope: item.envelope, audioURL: item.url)
                    }
                }
                var collected: [Receipt] = []
                for try await receipt in group { collected.append(receipt) }
                return collected
            }
            #expect(receipts.count == 6)
            #expect(try await store.pendingReceiptCount(sourceDeviceID: sourceID) == 6)

            let acked = try await client.sendReceiptsApplied(
                route: route,
                items: receipts.map { ReceiptApplied(receipt: $0) })
            #expect(acked == 6)
            #expect(try await store.pendingReceiptCount(sourceDeviceID: sourceID) == 0)
        }
    }

    private func makeTestWAV(frameCount: Int, fillByte: UInt8 = 0) -> Data {
        let dataBytes = frameCount * 2
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        var chunkSize = UInt32(36 + dataBytes).littleEndian
        withUnsafeBytes(of: &chunkSize) { header.append(contentsOf: $0) }
        header.append(contentsOf: "WAVEfmt ".utf8)
        var subchunk1Size = UInt32(16).littleEndian
        var audioFormat = UInt16(1).littleEndian
        var numChannels = UInt16(1).littleEndian
        var sampleRate = UInt32(16_000).littleEndian
        var byteRate = UInt32(32_000).littleEndian
        var blockAlign = UInt16(2).littleEndian
        var bitsPerSample = UInt16(16).littleEndian
        withUnsafeBytes(of: &subchunk1Size) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &audioFormat) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &numChannels) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &sampleRate) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &byteRate) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &blockAlign) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &bitsPerSample) { header.append(contentsOf: $0) }
        header.append(contentsOf: "data".utf8)
        var subchunk2Size = UInt32(dataBytes).littleEndian
        withUnsafeBytes(of: &subchunk2Size) { header.append(contentsOf: $0) }
        header.append(Data(repeating: fillByte, count: dataBytes))
        return header
    }
}
