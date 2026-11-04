import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct InboxHandoffTests {
    #if DEBUG && os(macOS)
    @Test func scanningDuringHandoffOnlySeesPublishedItems() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let existing = try fixture.deliver(fixture.envelope(), to: store)
        let envelope = try fixture.envelope(sequence: 1)
        let source = fixture.root.appendingPathComponent("delivery.wav")
        try fixture.audio.write(to: source)
        let inbox = try InboxCustodian(rootURL: store.inbox.rootURL) { _ in
            do {
                #expect(try store.inbox.pendingItems().map(\.id) == [existing.id])
                #expect(FileManager.default.fileExists(atPath: source.path))
            } catch { Issue.record("Concurrent inbox scan failed: \(error)") }
        }
        let item = try inbox.preserve(fileURL: source, envelope: envelope)
        #expect(try Set(store.inbox.pendingItems().map(\.id)) == [existing.id, item.id])
        #expect(try ContentHash.sha256(fileAt: item.directoryURL.appendingPathComponent("audio")) == envelope.manifest.audioSHA256)
        #expect(try await store.pendingReceipts().isEmpty)
    }
    #endif

    @Test(arguments: ["manifest.json", "manifest.sha256"])
    func legacyMissingMetadataIsRetainedWithoutRepeatedFailure(missing: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let item = try fixture.deliver(envelope, to: store)
        try FileManager.default.removeItem(at: item.directoryURL.appendingPathComponent(missing))

        let reopened = try fixture.store()
        #expect(try reopened.inbox.pendingItems().isEmpty)
        #expect(try await reopened.processInbox().isEmpty)
        #expect(try await reopened.pendingReceipts().isEmpty)
        let retained = item.directoryURL.appendingPathExtension("incomplete")
        #expect(try Data(contentsOf: retained.appendingPathComponent("audio")) == fixture.audio)
        #expect(!FileManager.default.fileExists(atPath: retained.appendingPathComponent(missing).path))

        guard case .accepted(let receipt) = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened)) else {
            Issue.record("Matching retransmission did not recover the recording"); return
        }
        #expect(receipt.matches(envelope))
        let again = try fixture.store()
        #expect(try await again.processInbox().isEmpty)
        #expect(try await again.pendingReceipts() == [receipt])
        #expect(try await again.recordings().count == 1)
    }

    @Test func failedAudioHandoffWaitsForRedeliveryWithoutAcknowledging() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        #expect(throws: (any Error).self) {
            try store.inbox.preserve(fileURL: fixture.root.appendingPathComponent("missing.wav"), envelope: envelope)
        }
        #expect(try store.inbox.pendingItems().isEmpty)
        let reopened = try fixture.store()
        #expect(try await reopened.processInbox().isEmpty)
        #expect(try await reopened.pendingReceipts().isEmpty)
        let retained = try #require(reopened.inbox.storedItems(includingIncomplete: true).first)
        #expect(retained.directoryURL.pathExtension == "incomplete")
        #expect(try Data(contentsOf: retained.directoryURL.appendingPathComponent("manifest.json")) == envelope.manifestData)
        guard case .accepted = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened)) else {
            Issue.record("Redelivery failed after interrupted handoff"); return
        }
    }

    @Test func completeUnpublishedHandoffRecoversOnRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let item = try fixture.deliver(envelope, to: store)
        // Recreate process death after the audio move but before publication.
        try FileManager.default.moveItem(at: item.directoryURL, to: item.directoryURL.appendingPathExtension("receiving"))
        #expect(try store.inbox.pendingItems().isEmpty)
        let reopened = try fixture.store()
        let outcomes = try await reopened.processInbox()
        #expect(outcomes.count == 1)
        guard case .accepted(let receipt) = try #require(outcomes.first).result.get() else {
            Issue.record("Complete staged handoff was not recovered"); return
        }
        #expect(receipt.matches(envelope))
        #expect(try reopened.inbox.pendingItems().isEmpty)
        #expect(try await reopened.pendingReceipts() == [receipt])
    }

    @Test func deletingSessionAlsoRemovesItsVerifiableIncompleteHandoff() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        #expect(throws: (any Error).self) {
            try store.inbox.preserve(fileURL: fixture.root.appendingPathComponent("missing.wav"), envelope: envelope)
        }
        let reopened = try fixture.store()
        let retained = try #require(reopened.inbox.storedItems(includingIncomplete: true).first)
        _ = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened))
        _ = try await reopened.deleteSession(id: fixture.sessionID)
        try await reopened.cleanDeletedFiles()
        #expect(!FileManager.default.fileExists(atPath: retained.directoryURL.path))
        #expect(try reopened.inbox.storedItems(includingIncomplete: true).isEmpty)
    }

    @Test func staleQueueSnapshotDoesNotFailOrIssueAnotherReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let item = try fixture.deliver(fixture.envelope(), to: store)
        let listed = try #require(store.inbox.pendingItems().first)
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(item) else {
            Issue.record("Initial receive failed"); return
        }
        guard case .noLongerPending = try await store.commitReceivedChunk(listed) else {
            Issue.record("Consumed inbox entry was not recognized"); return
        }
        #expect(try await store.pendingReceipts() == [receipt])
        #expect(try await store.recordings().count == 1)
    }

    @Test func duplicateVerifiedDeliveriesCoalesceOntoSinglePendingInboxEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let first = try fixture.deliver(envelope, to: store)
        let second = try fixture.deliver(envelope, to: store)
        let third = try fixture.deliver(envelope, to: store)
        #expect(first.id == envelope.manifest.chunkID)
        #expect(second.id == first.id)
        #expect(third.id == first.id)
        #expect(try store.inbox.pendingItems().count == 1)
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(first) else {
            Issue.record("Expected coalesced inbox item to commit cleanly"); return
        }
        #expect(receipt.matches(envelope))
        #expect(try store.inbox.pendingItems().isEmpty)
    }

    @Test func startupCleanupCollapsesLegacyRandomUUIDDuplicatesWithoutTouchingCorruptCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inboxRoot = fixture.root.appendingPathComponent("legacy-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let envelope = try fixture.envelope()
        for _ in 0..<4 {
            let dup = inboxRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dup, withIntermediateDirectories: true)
            try envelope.manifestData.write(to: dup.appendingPathComponent("manifest.json"))
            try Data(envelope.manifestSHA256.utf8).write(to: dup.appendingPathComponent("manifest.sha256"))
            try fixture.audio.write(to: dup.appendingPathComponent("audio"))
        }
        let custodian = try InboxCustodian(rootURL: inboxRoot)
        let pending = try custodian.pendingItems()
        #expect(pending.count == 1)
        #expect(custodian.pendingItem(chunkID: envelope.manifest.chunkID)?.id == pending.first?.id)
        #expect(custodian.pendingItem(manifestSHA256: envelope.manifestSHA256)?.id == pending.first?.id)
    }
}
