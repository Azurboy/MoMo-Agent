import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

@Suite struct CriticalAPIBenchmarkTests {
    private struct BaselineDocument: Decodable {
        struct Budget: Decodable {
            let p95Ms: Double
            let maxMs: Double
        }
        struct VersionEntry: Decodable {
            let notes: String
            let budgetsMs: [String: Budget]
        }
        let schemaVersion: Int
        let activeBaselineVersion: String
        let versionBaselines: [String: VersionEntry]
    }

    private func loadBaselineDocument() throws -> BaselineDocument {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MoMoArchiveTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MoMoAgentKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
        let url = packageRoot.appendingPathComponent("Tests/Support/api-performance-baselines.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BaselineDocument.self, from: data)
    }

    @Test func criticalInterfacesMeetVersionBaselineAndPersistMultiVersionTelemetry() async throws {
        let baselineDoc = try loadBaselineDocument()
        #expect(baselineDoc.schemaVersion == 1)
        let baseline = try #require(baselineDoc.versionBaselines[baselineDoc.activeBaselineVersion])

        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("momo-critical-api-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let receiverID = UUID()
        let sourceDeviceID = UUID()
        let fingerprint = ContentHash.sha256(Data("bench-fingerprint-v037".utf8))
        let baseAnchor = Date(timeIntervalSince1970: 1_793_664_000) // 2026-11-03 UTC

        let seedStore = try ArchiveStore(
            rootURL: root,
            receiverDeviceID: receiverID,
            marketingVersion: "0.3.7",
            buildVersion: "52"
        )

        let pcmSamples = Data(repeating: 0, count: 640) // 20ms @ 16kHz Int16 mono
        let audioHash = ContentHash.sha256(pcmSamples)
        let sourceAudioURL = root.appendingPathComponent("seed-sample.pcm")

        var allSessionIDs: [UUID] = []
        var latestDayEnvelopes: [ManifestEnvelope] = []

        for sessionIndex in 0..<12 {
            let sessionID = UUID()
            let epochID = UUID()
            allSessionIDs.append(sessionID)
            let sessionAnchor = baseAnchor.addingTimeInterval(Double(sessionIndex) * 5_400)
            var sessionEnvelopes: [ManifestEnvelope] = []

            for chunkIndex in 0..<20 {
                let manifest = try ChunkManifest(
                    sessionID: sessionID,
                    epochID: epochID,
                    sourceDeviceID: sourceDeviceID,
                    sourceBuild: "52",
                    sequence: Int64(chunkIndex),
                    frames: FrameRange(start: Int64(chunkIndex * 320), count: 320),
                    timebaseHz: 16_000,
                    wallClockAnchor: sessionAnchor,
                    timezoneOffset: 28_800,
                    codec: .pcmInt16,
                    sampleRate: 16_000,
                    channels: 1,
                    decodedFrameCount: 320,
                    byteCount: Int64(pcmSamples.count),
                    audioSHA256: audioHash,
                    sourceKind: .fixture
                )
                let envelope = try ManifestEnvelope(manifest: manifest)
                try pcmSamples.write(to: sourceAudioURL)
                let item = try seedStore.inbox.preserve(fileURL: sourceAudioURL, envelope: envelope)
                _ = try await seedStore.commitReceivedChunk(item, preverifiedAudioSHA256: audioHash)
                sessionEnvelopes.append(envelope)
            }
            if sessionIndex == 11 {
                latestDayEnvelopes = sessionEnvelopes
            }
            try await seedStore.markEpochClosed(epochID: epochID, endFrame: Int64(20 * 320))

            var spans: [TranscriptSpan] = []
            for spanIndex in 0..<15 {
                let env = sessionEnvelopes[spanIndex]
                spans.append(TranscriptSpan(
                    chunkID: env.manifest.chunkID,
                    frames: env.manifest.frames,
                    text: "第\(sessionIndex + 1)场录音第\(spanIndex + 1)段基准测试内容，验证关键接口读取延迟。"
                ))
            }
            let doc = TranscriptDocument(
                sessionID: sessionID,
                version: 1,
                generation: 1,
                spans: spans,
                updatedAt: sessionAnchor.addingTimeInterval(60)
            )
            _ = try await seedStore.storeDocument(doc)
        }

        // Complete one-time migrations and initial file projections so cold reopen reflects steady-state user launch.
        try await seedStore.discardPunctuationOnlyTranscripts()
        try await seedStore.upgradeSpeakerProfilesIfNeeded()
        try await seedStore.projectPendingDocuments(includeUnchanged: true)
        try seedStore.performanceMonitor.flushNow()

        // Simulate cold app launch on build 53 (all in-memory ArchiveStore caches start cold).
        let coldStartMs = APIPerformanceMonitor.uptimeMilliseconds()
        let reopened = try ArchiveStore(
            rootURL: root,
            receiverDeviceID: receiverID,
            marketingVersion: "0.3.7",
            buildVersion: "53"
        )
        try await reopened.discardPunctuationOnlyTranscripts()
        try await reopened.upgradeSpeakerProfilesIfNeeded()
        let page = try await reopened.recordingsPage(limit: 50)
        #expect(page.items.count == 12)
        let previewRequests = page.items.map {
            (sessionID: $0.id, expectedVersion: $0.transcriptVersion, expectedGeneration: $0.generation)
        }
        let previews = try await reopened.transcriptPreviews(requests: previewRequests)
        #expect(previews.count == 12)
        let selectedDay = TimelineDay(
            baseAnchor.addingTimeInterval(11 * 5_400 + 28_800),
            calendar: TimelineDay.calendar
        )
        let daySnapshot = try await reopened.timelineDaySnapshot(selectedDay, configurationFingerprint: fingerprint)
        #expect(!daySnapshot.windows.isEmpty)
        let earliest = try await reopened.earliestTimelineDay()
        #expect(earliest != nil)
        let coldInteractiveMs = APIPerformanceMonitor.uptimeMilliseconds() - coldStartMs
        reopened.performanceMonitor.record(
            .coldStartToTimelineInteractive,
            durationMs: coldInteractiveMs,
            itemCount: page.items.count
        )

        // Second earliestTimelineDay call must hit the revision-scoped cache cleanly.
        #expect(try await reopened.earliestTimelineDay() == earliest)

        // Full cold-cache reconcileDocumentFiles + projectPendingDocuments(includeUnchanged: false)
        // must hit manifest_projection_hash + projection_hash without decoding historical chunks/transcripts.
        #if DEBUG
        let decodeBeforeReconcile = await reopened.transcriptReadDecodeCount
        #endif
        let reconciled = try await reopened.reconcileDocumentFiles(onlyBlockedOrChanged: false)
        #expect(reconciled.count == 12)
        #expect(reconciled.allSatisfy { $0.issue == nil && !$0.didRevise })
        #if DEBUG
        let decodeAfterReconcile = await reopened.transcriptReadDecodeCount
        #expect(decodeAfterReconcile == decodeBeforeReconcile)
        #endif
        try await reopened.projectPendingDocuments(includeUnchanged: false)

        let detail = try await reopened.transcriptSnapshot(sessionID: allSessionIDs[11])
        #expect(detail.document.spans.count == 15)
        try await reopened.writeSyncDiagnostic(now: Date())
        let reconcileReq = try ReconcileRequest(
            sourceDeviceID: sourceDeviceID,
            receiverDeviceID: receiverID,
            libraryInstanceID: reopened.libraryInstanceID,
            items: latestDayEnvelopes.prefix(16).map { try ReconcileChunkIdentity(envelope: $0) }
        )
        let reconcileResp = try await reopened.receiveReconcileRequest(reconcileReq)
        #expect(reconcileResp.results.count == 16)

        try reopened.performanceMonitor.flushNow()
        let reportData = try Data(contentsOf: reopened.performanceMonitor.fileURL)
        let persisted = try WireJSON.decode(APIPerformanceReport.self, from: reportData)
        #expect(persisted.currentVersionKey == "0.3.7+53")
        #expect(persisted.versions["0.3.7+52"] != nil)
        let v53 = try #require(persisted.versions["0.3.7+53"])

        let checkedAPIs: [CriticalAPI] = [
            .coldStartToTimelineInteractive,
            .timelineDaySnapshot,
            .earliestTimelineDay,
            .recordingsPage,
            .transcriptPreviewsBatch,
            .transcriptSnapshot,
            .reconcileDocumentFiles,
            .projectPendingDocuments,
            .writeSyncDiagnostic,
            .receiveReconcileRequest
        ]
        for api in checkedAPIs {
            let metric = try #require(v53.metrics[api.rawValue], "Missing telemetry for \(api.rawValue)")
            let spec = try #require(baseline.budgetsMs[api.rawValue], "Missing baseline budget for \(api.rawValue)")
            #expect(metric.callCount >= 1)
            #expect(metric.errorCount == 0)
            // Allow 2x CI runner jitter over maxMs while enforcing strict sub-second regression gates.
            #expect(
                metric.p95DurationMs <= spec.maxMs * 2.0,
                "API \(api.rawValue) exceeded baseline gate: p95=\(metric.p95DurationMs)ms > gate=\(spec.maxMs * 2.0)ms"
            )
        }
    }

    @Test func largeMultiDayEpochTimelineSnapshotRemainsFastAtScale() async throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("momo-multiday-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let receiverID = UUID()
        let sourceDeviceID = UUID()
        let sessionID = UUID()
        let epochID = UUID()
        let fingerprint = ContentHash.sha256(Data("multiday-fingerprint".utf8))
        let baseAnchor = Date(timeIntervalSince1970: 1_793_664_000) // 2026-11-03 00:00 UTC (08:00 +08:00)

        let seedStore = try ArchiveStore(rootURL: root, receiverDeviceID: receiverID, marketingVersion: "0.4.1", buildVersion: "58")
        let pcmSamples = Data(repeating: 0, count: 640)
        let audioHash = ContentHash.sha256(pcmSamples)
        let sourceAudioURL = root.appendingPathComponent("seed.pcm")
        try pcmSamples.write(to: sourceAudioURL)

        let chunkFrames: Int64 = 30 * 16_000 // 30s per chunk -> 6,000 chunks = 50 hours across 3 days
        let totalChunks = 6_000
        let firstManifest = try ChunkManifest(
            sessionID: sessionID,
            epochID: epochID,
            sourceDeviceID: sourceDeviceID,
            sourceBuild: "58",
            sequence: 0,
            frames: FrameRange(start: 0, count: chunkFrames),
            timebaseHz: 16_000,
            wallClockAnchor: baseAnchor,
            timezoneOffset: 28_800,
            codec: .pcmInt16,
            sampleRate: 16_000,
            channels: 1,
            decodedFrameCount: chunkFrames,
            byteCount: Int64(pcmSamples.count),
            audioSHA256: audioHash,
            sourceKind: .fixture
        )
        let firstEnvelope = try ManifestEnvelope(manifest: firstManifest)
        _ = try await seedStore.commitReceivedChunk(
            seedStore.inbox.preserve(fileURL: sourceAudioURL, envelope: firstEnvelope),
            preverifiedAudioSHA256: audioHash
        )

        let db = await seedStore.database
        let sessionDirectory = try #require(
            db.rows("SELECT document_directory FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.string(0)
        )
        let audioDirectoryURL = root.appendingPathComponent(sessionDirectory + "/audio", isDirectory: true)

        var chunkIDs: [UUID] = [firstManifest.chunkID]
        chunkIDs.reserveCapacity(totalChunks)
        let anchorSeconds = baseAnchor.timeIntervalSince1970

        try db.transaction {
            for i in 1..<totalChunks {
                let cid = UUID()
                chunkIDs.append(cid)
                let startFrame = Int64(i) * chunkFrames
                let endFrame = startFrame + chunkFrames
                let manifest = try ChunkManifest(
                    sessionID: sessionID,
                    epochID: epochID,
                    chunkID: cid,
                    sourceDeviceID: sourceDeviceID,
                    sourceBuild: "58",
                    sequence: Int64(i),
                    frames: FrameRange(start: startFrame, count: chunkFrames),
                    timebaseHz: 16_000,
                    wallClockAnchor: baseAnchor,
                    timezoneOffset: 28_800,
                    codec: .pcmInt16,
                    sampleRate: 16_000,
                    channels: 1,
                    decodedFrameCount: chunkFrames,
                    byteCount: Int64(pcmSamples.count),
                    audioSHA256: audioHash,
                    sourceKind: .fixture
                )
                let manifestData = try WireJSON.encode(manifest)
                let manifestHash = ContentHash.sha256(manifestData)
                let relPath = "\(sessionDirectory)/audio/\(cid.uuidString).wav"
                // Retain present audio files for the active second day so filesystem checks run realistically.
                let isPresent = (2_000..<4_000).contains(i)
                if isPresent {
                    FileManager.default.createFile(atPath: audioDirectoryURL.appendingPathComponent("\(cid.uuidString).wav").path, contents: Data())
                }
                try db.execute("""
                    INSERT INTO chunks(
                      id,session_id,epoch_id,manifest,manifest_hash,audio_hash,relative_path,retention,
                      start_frame,end_frame,byte_count,sealed_at,wall_clock_anchor,timezone_offset,timebase_hz
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                        .text(cid.uuidString), .text(sessionID.uuidString), .text(epochID.uuidString),
                        .blob(manifestData), .text(manifestHash), .text(audioHash), .text(relPath),
                        .text(isPresent ? "present" : "expired"),
                        .integer(startFrame), .integer(endFrame), .integer(Int64(pcmSamples.count)),
                        .double(anchorSeconds + Double(i) * 30.0), .double(anchorSeconds),
                        .integer(28_800), .double(16_000)
                    ])
                try db.execute("""
                    INSERT INTO transcription_jobs(id,chunk_id,generation,state,configuration_hash)
                    VALUES(?,?,0,'complete',?)
                    """, [.text(cid.uuidString), .text(cid.uuidString), .text(fingerprint)])
            }
            let totalEndFrame = Int64(totalChunks) * chunkFrames
            try db.execute(
                "UPDATE epochs SET max_received_end_frame=? WHERE id=?",
                [.integer(totalEndFrame), .text(epochID.uuidString)]
            )
            try db.execute(
                "INSERT INTO analysis_epochs(epoch_id,configuration_hash,generation,has_pending) VALUES(?,?,0,0)",
                [.text(epochID.uuidString), .text(fingerprint)]
            )
            try db.execute(
                "INSERT INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind) VALUES(?,?,0,?,'analyzed')",
                [.text(epochID.uuidString), .text(fingerprint), .integer(totalEndFrame)]
            )
            var speechRanges: [FrameRange] = []
            for i in stride(from: 0, to: totalChunks, by: 3) where (i / 9) % 3 == 0 {
                let coreStart = Int64(i) * chunkFrames + 32_000
                let coreCount: Int64 = 12 * 16_000
                let coreRange = try FrameRange(start: coreStart, count: coreCount)
                speechRanges.append(coreRange)
                let win = ArchiveAnalysisWindow(
                    id: ContentHash.sha256(Data("w-\(i)".utf8)),
                    sessionID: sessionID,
                    epochID: epochID,
                    analysisAnchor: 0,
                    coreFrames: coreRange,
                    contextFrames: coreRange,
                    modelCoreFrames: coreRange,
                    modelContextFrames: coreRange,
                    sources: [ArchiveWindowSource(chunkID: chunkIDs[i], manifestSHA256: firstEnvelope.manifestSHA256, audioSHA256: audioHash, sourceFrames: coreRange)],
                    configurationFingerprint: fingerprint
                )
                try db.execute("""
                    INSERT INTO analysis_windows(
                      id,epoch_id,session_id,generation,configuration_hash,descriptor,state,raw_result,
                      core_start,core_end,context_start,context_end,analysis_anchor,model_core_start
                    ) VALUES(?,?,?,0,?,?,'complete',X'',?,?,?,?,0,?)
                    """, [
                        .text(win.id), .text(epochID.uuidString), .text(sessionID.uuidString),
                        .text(fingerprint), .blob(try WireJSON.encode(win)),
                        .integer(coreRange.start), .integer(coreRange.end),
                        .integer(coreRange.start), .integer(coreRange.end), .integer(coreRange.start)
                    ])
            }
            let fullRange = try FrameRange(start: 0, count: totalEndFrame)
            for silence in try CoverageRanges.subtract([fullRange], speechRanges) {
                try db.execute(
                    "INSERT INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind) VALUES(?,?,?,?,'no_speech')",
                    [.text(epochID.uuidString), .text(fingerprint), .integer(silence.start), .integer(silence.end)]
                )
            }
        }
        try await seedStore.markEpochClosed(epochID: epochID, endFrame: Int64(totalChunks) * chunkFrames)

        var spans: [TranscriptSpan] = []
        for i in stride(from: 0, to: totalChunks, by: 3) where (i / 9) % 3 == 0 {
            let coreRange = try FrameRange(start: Int64(i) * chunkFrames + 32_000, count: 12 * 16_000)
            spans.append(TranscriptSpan(
                chunkID: chunkIDs[i],
                frames: coreRange,
                text: "跨天长会话第\(i)段语音转写文本，用于验证正在读取记录接口在真实多日海量切片下的响应延迟。"
            ))
        }
        _ = try await seedStore.storeDocument(TranscriptDocument(
            sessionID: sessionID,
            version: 1,
            generation: 0,
            spans: spans,
            updatedAt: baseAnchor.addingTimeInterval(Double(totalChunks) * 30.0)
        ))

        let reopened = try ArchiveStore(rootURL: root, receiverDeviceID: receiverID, marketingVersion: "0.4.1", buildVersion: "58")
        let secondDay = TimelineDay(baseAnchor.addingTimeInterval(28_800 + 86_400), calendar: TimelineDay.calendar)

        let coldT0 = APIPerformanceMonitor.uptimeMilliseconds()
        let coldSnapshot = try await reopened.timelineDaySnapshot(secondDay, configurationFingerprint: fingerprint)
        let coldMs = APIPerformanceMonitor.uptimeMilliseconds() - coldT0

        let warmT0 = APIPerformanceMonitor.uptimeMilliseconds()
        let warmSnapshot = try await reopened.timelineDaySnapshot(secondDay, configurationFingerprint: fingerprint)
        let warmMs = APIPerformanceMonitor.uptimeMilliseconds() - warmT0

        print(String(format: "[MultiDayBench] 6000 chunks / 2000 spans -> cold=%.2fms warm=%.2fms windows=%d",
                     coldMs, warmMs, coldSnapshot.windows.count))
        #expect(!coldSnapshot.windows.isEmpty)
        #expect(warmSnapshot.windows == coldSnapshot.windows)
        #expect(coldMs <= 150.0, "Cold multi-day timelineDaySnapshot took \(coldMs)ms (> 150ms)")
        #expect(warmMs <= 80.0, "Warm multi-day timelineDaySnapshot took \(warmMs)ms (> 80ms)")
    }
}
