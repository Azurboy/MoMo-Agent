import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchiveSyncDiagnosticTests {
    @Test func actorSnapshotIncludesCommittedIDsButNotAProbeAndRefreshesAtMostOncePerThirtySeconds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let partial = try fixture.envelope(startFrame: 3200, sequence: 2)
        _ = try await store.receiveAudioBlock(AudioBlock(receiverDeviceID: fixture.deviceID,
            libraryInstanceID: store.libraryInstanceID, envelope: partial, offset: 0, payload: Data()))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let now = Date()
        try await store.writeSyncDiagnostic(now: now)
        let path = store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/sync-receive-diagnostic.json")
        let firstData = try Data(contentsOf: path)
        let first = try WireJSON.decode(ArchiveSyncDiagnostic.self, from: firstData)
        #expect(first.days.count == 1)
        #expect(first.days[0].chunkIDs == [envelope.manifest.chunkID.uuidString])
        #expect(first.days[0].retentionCounts == ["present": 1])
        #expect(first.days[0].sourceDeviceID == fixture.deviceID.uuidString)
        #expect(first.latestCommit?.chunkID == envelope.manifest.chunkID && first.pendingReceiptCount == 1)
        #expect(first.pendingReceiptCountsBySource == [fixture.deviceID.uuidString: 1])
        #expect(first.pendingReconcileResponseCountsBySource == [:])
        let next = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(next, to: store))
        try await store.writeSyncDiagnostic(now: now.addingTimeInterval(1))
        #expect(try Data(contentsOf: path) == firstData)
        try await store.writeSyncDiagnostic(now: now.addingTimeInterval(31))
        let second = try WireJSON.decode(ArchiveSyncDiagnostic.self, from: Data(contentsOf: path))
        #expect(second.days[0].chunkIDs == [envelope.manifest.chunkID.uuidString, next.manifest.chunkID.uuidString])
        #expect(second.latestCommit?.chunkID == next.manifest.chunkID && second.pendingReceiptCount == 2)
    }

    @Test func legacyDeletionIsReissuedOnceWithCurrentLibraryAndANewMessageID() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(), to: store))
        let deletion = try await store.deleteSession(id: fixture.sessionID)
        let legacy = try DeleteSession(messageID: deletion.messageID, deletionID: deletion.deletionID,
            sessionID: deletion.sessionID, generation: deletion.generation)
        let database = try ArchiveDatabase(url: store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite"))
        try database.execute("UPDATE deletions SET message=? WHERE id=?", [.blob(try WireJSON.encode(legacy)), .text(legacy.deletionID.uuidString)])
        let scoped = try #require(await store.pendingDeletions().first)
        #expect(scoped.messageID != legacy.messageID && scoped.deletionID == legacy.deletionID)
        #expect(scoped.libraryInstanceID == store.libraryInstanceID && scoped.receiverDeviceID == fixture.deviceID)
        #expect(try await fixture.store().pendingDeletions() == [scoped])
    }

    @Test func diagnosticWriteFailureCannotRemoveCommittedAudioOrItsReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        let path = store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/sync-receive-diagnostic.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        await #expect(throws: (any Error).self) { try await store.writeSyncDiagnostic() }
        #expect(try await store.pendingReceiptCount() == 1)
        let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        #expect(try ContentHash.sha256(fileAt: lease.audioURL) == envelope.manifest.audioSHA256)
        await store.releaseAudioLease(id: lease.id)
    }
}
