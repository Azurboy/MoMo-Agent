import Foundation
import os
import Testing
import MoMoContracts
@testable import MoMoSpeech

@Test func speechDiagnosticsRemainIsolatedAcrossCancelledAndFailedAttempts() async throws {
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
                                           tokensSHA256: String(repeating: "b", count: 64),
                                           vadSHA256: String(repeating: "c", count: 64))
    let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
    let engine = try SpeechEngine(bundle: SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest),
        configuration: SpeechConfiguration(), onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
    let cancelled = SpeechAttempt()
    cancelled.cancel()
    await #expect(throws: SpeechError.cancelled) { try await engine.prepare(inputs: [], epochClosed: true, attempt: cancelled) }
    let failed = SpeechAttempt()
    await #expect(throws: SpeechError.missingAudio) { try await engine.prepare(inputs: [], epochClosed: true, attempt: failed) }
    let values = observations.withLock { $0 }
    #expect(values.count == 2)
    #expect(values.map(\.attemptID) == [cancelled.id, failed.id])
    #expect(values.map(\.outcome) == [.cancelled, .failed])
    #expect(Set(values.map(\.operationID)).count == 2)
    #expect(values.allSatisfy { $0.modelHashedBytes == 0 && $0.audioHashedBytes == 0 && $0.nativeDecodeSeconds == 0 })
    #expect(values.first?.cancellationToOperationEndSeconds != nil)
    #expect(values.last?.cancellationToOperationEndSeconds == nil)
}

@Test func speechHashPreservesIdentityAndCountsOnlyReadBytes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-hash-\(UUID()).bin")
    defer { do { try FileManager.default.removeItem(at: url) } catch { Issue.record(error) } }
    let data = Data((0..<131_079).map { UInt8($0 % 251) })
    try data.write(to: url, options: .withoutOverwriting)
    let attempt = SpeechAttempt()
    let recorder = SpeechDiagnosticRecorder(operation: .prepare, attemptID: attempt.id, windowID: nil, fingerprint: "test")
    let actual = try speechFileHash(url, attempt: attempt, recorder: recorder, model: false)
    #expect(actual == ContentHash.sha256(data))
    #expect(recorder.value.audioHashedBytes == Int64(data.count))
    #expect(recorder.value.modelHashedBytes == 0)
    #expect(recorder.value.audioHashSeconds >= 0)
}

@Test func cancelledHashDoesNotOpenMissingInput() throws {
    let attempt = SpeechAttempt()
    attempt.cancel()
    let recorder = SpeechDiagnosticRecorder(operation: .prepare, attemptID: attempt.id, windowID: nil, fingerprint: "test")
    #expect(throws: SpeechError.cancelled) {
        try speechFileHash(URL(fileURLWithPath: "/unused/missing-model"), attempt: attempt, recorder: recorder, model: true)
    }
    #expect(recorder.value.modelHashedBytes == 0)
}

@Test func cancellationDiagnosticsKeepFirstRequestAndExcludePreDecodeCancellation() throws {
    let attempt = SpeechAttempt()
    let start = DispatchTime.now().uptimeNanoseconds
    attempt.cancel()
    let first = try #require(attempt.cancellationUptimeNanoseconds)
    attempt.cancel()
    #expect(attempt.cancellationUptimeNanoseconds == first)
    let recorder = SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id, windowID: "window", fingerprint: "test")
    recorder.nativeReturned(startedAt: start, returnedAt: first + 10, attempt: attempt)
    #expect(recorder.value.cancellationDuringNativeDecode)
    #expect(recorder.value.cancellationToNativeReturnSeconds == 10.0 / 1_000_000_000)
    let preDecode = SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id, windowID: "window", fingerprint: "test")
    preDecode.nativeReturned(startedAt: first + 1, returnedAt: first + 10, attempt: attempt)
    #expect(!preDecode.value.cancellationDuringNativeDecode)
    #expect(preDecode.value.cancellationToNativeReturnSeconds == nil)
    #expect(preDecode.finished(outcome: .cancelled, attempt: attempt).outcome == .cancelled)
}

@Test func nativeCancelTokenSerializesConcurrentCancelAndRetirement() {
    for _ in 0..<32 {
        let attempt = SpeechAttempt()
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            entered.wait()
            attempt.cancel()
            finished.signal()
        }
        let code = withNativeCancelToken(attempt) { token in
            #expect(token != nil)
            entered.signal()
            Thread.sleep(forTimeInterval: 0.002)
            return attempt.cancellationUptimeNanoseconds != nil ? -2 : 0
        }
        finished.wait()
        attempt.cancel()
        #expect(code == -2 || code == 0)
        #expect(attempt.cancellationUptimeNanoseconds != nil)
    }
}

@Test func backgroundCPUPacerWakesImmediatelyOnForegroundOrCancel() async {
    let fgPacer = BackgroundCPUPacer(initiallyForeground: true, maxCapacity: 1.0, initialBackgroundBurst: -0.5, refillRate: 0.01)
    let attempt = SpeechAttempt()
    #expect(!fgPacer.paceIfNeeded(attempt: attempt))

    // Force negative initial burst so background pacing enters condition wait, then wake via foreground transition.
    let bgPacer = BackgroundCPUPacer(initiallyForeground: false, maxCapacity: 1.0, initialBackgroundBurst: -5.0, refillRate: 0.01)
    let started = ContinuousClock.now
    let wakeTask = Task.detached {
        try? await Task.sleep(for: .milliseconds(15))
        bgPacer.setSceneForeground(true)
    }
    let cancelledOnWake = bgPacer.paceIfNeeded(attempt: attempt)
    await wakeTask.value
    #expect(!cancelledOnWake)
    #expect(bgPacer.sceneForeground)
    #expect(started.duration(to: ContinuousClock.now) < .milliseconds(500))

    // Also verify cancellation wakes a sleeping background pacer immediately.
    let cancelPacer = BackgroundCPUPacer(initiallyForeground: false, maxCapacity: 1.0, initialBackgroundBurst: -5.0, refillRate: 0.01)
    let cancelAttempt = SpeechAttempt()
    let cancelStart = ContinuousClock.now
    let cancelWake = Task.detached {
        try? await Task.sleep(for: .milliseconds(15))
        cancelAttempt.cancel()
    }
    let cancelled = cancelPacer.paceIfNeeded(attempt: cancelAttempt)
    await cancelWake.value
    #expect(cancelled)
    #expect(cancelStart.duration(to: ContinuousClock.now) < .milliseconds(500))
}

@Test func backgroundCPUPacerScalesRefillRateAcrossBudgetTiers() throws {
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
                                           tokensSHA256: String(repeating: "b", count: 64),
                                           vadSHA256: String(repeating: "c", count: 64))
    let engine = try SpeechEngine(bundle: SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest),
                                  configuration: SpeechConfiguration())
    #expect(engine.backgroundBudget == .standard)
    engine.setBackgroundBudget(.elevatedSystemTask)
    #expect(engine.backgroundBudget == .elevatedSystemTask)
    engine.setBackgroundBudget(.externalPowerSystemTask)
    #expect(engine.backgroundBudget == .externalPowerSystemTask)

    let pacer = BackgroundCPUPacer(initiallyForeground: false, budget: .standard)
    #expect(pacer.currentRefillRate == 0.65)
    pacer.setBackgroundBudget(.elevatedSystemTask)
    #expect(pacer.currentRefillRate == 1.35)
    pacer.setBackgroundBudget(.externalPowerSystemTask)
    #expect(pacer.currentRefillRate == 2.20)
    pacer.setBackgroundBudget(.standard)
    #expect(pacer.currentRefillRate == 0.65)
}

@Test func preparedAudioCacheProtectsActiveStreamFromCrossOwnerEvictionAndEvictsOtherOwnerTail() throws {
    let cache = PreparedAudioCache(capacity: 16)
    let batchOwner = UUID()
    let liveOwner = UUID()
    let sessionID = UUID()
    let epochID = UUID()
    let fingerprint = ContentHash.sha256(Data("cache-partition".utf8))
    let attempt = SpeechAttempt()

    func makeWindow(_ label: String, index: Int) throws -> SpeechWindow {
        let frames = try FrameRange(start: Int64(index * 1_600), count: 1_600)
        return SpeechWindow(
            id: ContentHash.sha256(Data(label.utf8)),
            sessionID: sessionID,
            epochID: epochID,
            analysisAnchor: 0,
            coreFrames: frames,
            contextFrames: frames,
            modelCoreFrames: frames,
            modelContextFrames: frames,
            sources: [],
            replayInputManifestHashes: [],
            configurationFingerprint: fingerprint
        )
    }

    let batchWindows = try (0..<14).map { try makeWindow("batch-\($0)", index: $0) }
    for (idx, w) in batchWindows.enumerated() {
        try cache.put(owner: batchOwner, window: w, samples: [Float(idx)], attempt: attempt)
    }
    let liveWindows = try (0..<4).map { try makeWindow("live-\($0)", index: 100 + $0) }
    for (idx, w) in liveWindows.enumerated() {
        try cache.put(owner: liveOwner, window: w, samples: [Float(100 + idx)], attempt: attempt)
    }

    // All 4 live Watch windows and the batch's immediate upcoming 12 windows must hit; only batch tail (12, 13) is evicted.
    for (idx, w) in liveWindows.enumerated() {
        #expect(cache.take(w) == [Float(100 + idx)])
    }
    for idx in 0..<12 {
        #expect(cache.take(batchWindows[idx]) == [Float(idx)])
    }
    #expect(cache.take(batchWindows[12]) == nil)
    #expect(cache.take(batchWindows[13]) == nil)
}

@Test func backgroundCPUPacerIgnoresIdleNonSpeechCPUBetweenOperations() {
    let pacer = BackgroundCPUPacer(initiallyForeground: false, maxCapacity: 4.0, initialBackgroundBurst: 0.2, refillRate: 0.65)
    // Burn CPU while SpeechEngine has zero active operations (simulating Watch sync / SQLite work).
    var acc = 0.0
    for i in 1..<250_000 {
        acc += Double(i).squareRoot()
    }
    #expect(acc > 0)
    pacer.beginOperation()
    defer { pacer.endOperation() }
    let attempt = SpeechAttempt()
    let started = ContinuousClock.now
    #expect(!pacer.paceIfNeeded(attempt: attempt))
    #expect(started.duration(to: ContinuousClock.now) < .milliseconds(50))
}
