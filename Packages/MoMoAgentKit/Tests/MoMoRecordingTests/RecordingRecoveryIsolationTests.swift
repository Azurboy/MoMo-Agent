import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

@Test(arguments: [false, true])
func malformedReadyEntryDoesNotAbortRecoveryOfHealthyAudio(symbolicLink: Bool) async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let healthy = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let malformedID = UUID()
    let malformed = fixture.root.appendingPathComponent("watch/CaptureReady/\(malformedID.uuidString)")
    let bytes = Data("interrupted directory write".utf8)
    if symbolicLink {
        try FileManager.default.createSymbolicLink(at: malformed, withDestinationURL: fixture.source)
    } else {
        try bytes.write(to: malformed)
    }
    let reopened = try fixture.store()
    let report = try await reopened.recover()
    #expect(report.damaged == [malformedID])
    #expect(report.registered == [fixture.envelope.manifest.chunkID])
    #expect(try await reopened.pendingChunkCount() == 1)
    #expect(try await reopened.originalAvailableForTransferRetry(fixture.envelope, maximumValidationBytes: 1_048_576))
    #expect(try ContentHash.sha256(fileAt: healthy.audioURL) == fixture.envelope.manifest.audioSHA256)
    if symbolicLink {
        #expect(try malformed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try ContentHash.sha256(fileAt: fixture.source) == fixture.envelope.manifest.audioSHA256)
    } else {
        #expect(try Data(contentsOf: malformed) == bytes)
    }
}

@Test func deletionIgnoresUnrelatedCorruptionAndCleansKnownOwnerWithBrokenDraft() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let working = fixture.root.appendingPathComponent("watch/CaptureWorking")
    let owned = working.appendingPathComponent(fixture.envelope.manifest.chunkID.uuidString)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
    try Data("bad owned draft".utf8).write(to: owned.appendingPathComponent("draft.json"))
    var originalBytes: [String: Data] = [:]
    for corruptedDraft in [false, true] {
        let id = UUID().uuidString
        let directory = working.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let bytes = Data("orphan audio \(id)".utf8)
        try bytes.write(to: directory.appendingPathComponent("audio"))
        if corruptedDraft { try Data("{bad".utf8).write(to: directory.appendingPathComponent("draft.json")) }
        originalBytes[id] = bytes
    }
    let stray = working.appendingPathComponent(UUID().uuidString)
    try Data("stray".utf8).write(to: stray)
    let deletion = try DeleteSession(sessionID: fixture.envelope.manifest.sessionID, generation: 1)
    try await store.prepareDeletion(deletion, deviceID: fixture.envelope.manifest.sourceDeviceID)
    _ = try await store.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
    #expect(!FileManager.default.fileExists(atPath: owned.path))
    #expect(!FileManager.default.fileExists(atPath: chunk.audioURL.path))
    #expect(try await store.pendingDeletions().isEmpty)
    #expect(try await store.pendingDeletionApplications().count == 1)
    let repair = fixture.root.appendingPathComponent("watch/CaptureRepair")
    let containers = try FileManager.default.contentsOfDirectory(at: repair, includingPropertiesForKeys: nil)
    #expect(containers.count == 3)
    for container in containers {
        let entries = try FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
        let entry = try #require(entries.first)
        if let bytes = originalBytes[entry.lastPathComponent] { #expect(try Data(contentsOf: entry.appendingPathComponent("audio")) == bytes) }
        else { #expect(try Data(contentsOf: entry) == Data("stray".utf8)) }
    }
    let reopened = try fixture.store()
    #expect(try await reopened.recover().unfinished.count == 3)
    #expect(try await reopened.pendingDeletions().isEmpty)
    _ = try await reopened.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
    #expect(try FileManager.default.contentsOfDirectory(at: repair, includingPropertiesForKeys: nil).count == 3)
}

@Test func legacyWorkingDraftRecoversOwnershipWithoutDeletingOtherSessions() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let working = fixture.root.appendingPathComponent("watch/CaptureWorking")
        .appendingPathComponent(fixture.envelope.manifest.chunkID.uuidString)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
    try WireJSON.encode(fixture.envelope).write(to: working.appendingPathComponent("draft.json"))
    let audio = Data([7, 8, 9])
    try audio.write(to: working.appendingPathComponent("audio"))
    let unrelated = try DeleteSession(sessionID: UUID(), generation: 1)
    try await store.prepareDeletion(unrelated, deviceID: UUID())
    _ = try await store.completeDeletionAfterCaptureStopped(deletionID: unrelated.deletionID)
    #expect(try Data(contentsOf: working.appendingPathComponent("audio")) == audio)
    let requested = try DeleteSession(sessionID: fixture.envelope.manifest.sessionID, generation: 1)
    try await store.prepareDeletion(requested, deviceID: UUID())
    _ = try await store.completeDeletionAfterCaptureStopped(deletionID: requested.deletionID)
    #expect(!FileManager.default.fileExists(atPath: working.path))
}

@Test func retainedControlEventsPageWithoutLoadingOrLosingTheWholeHistory() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let m = fixture.envelope.manifest
    var expected: [ControlMessage] = []
    for frame in 0..<65 {
        let mark = try CaptureMark(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID, sourceFrame: Int64(frame))
        try await store.recordMark(mark)
        expected.append(.captureMark(mark))
    }
    let reopened = try fixture.store()
    var cursor: Int64 = 0
    var actual: [ControlMessage] = []
    for count in [32, 32, 1] {
        let batch = try await reopened.controlBatch(kind: .capture, after: cursor, limit: 1_000)
        #expect(batch.count == count)
        actual += batch.map(\.message)
        cursor = try #require(batch.last).sequence
    }
    #expect(actual == expected)
    #expect(try await reopened.controlBatch(kind: .capture, after: cursor).isEmpty)
    #expect(try await reopened.controlBatch(kind: .capture, after: 0).map(\.message) == Array(expected.prefix(32)))
}

@Test func versionTwoLedgerMigratesWithoutLosingPendingDeletionOrRecordedAudio() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let database = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
    try removeSchemaFiveTables(database)
    try database.execute("DROP TABLE capture_diagnostics")
    try database.execute("DROP TABLE working_owners")
    try database.execute("PRAGMA user_version=2")
    let migrated = try fixture.store()
    #expect(try await migrated.pendingChunks().count == 1)
    #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == fixture.envelope.manifest.audioSHA256)
    let deletion = try DeleteSession(sessionID: fixture.envelope.manifest.sessionID, generation: 1)
    try await migrated.prepareDeletion(deletion, deviceID: UUID())
    let reopened = try fixture.store()
    #expect(try await reopened.pendingDeletions() == [deletion])
    _ = try await reopened.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
    #expect(try await reopened.pendingDeletions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: chunk.audioURL.path))
}
