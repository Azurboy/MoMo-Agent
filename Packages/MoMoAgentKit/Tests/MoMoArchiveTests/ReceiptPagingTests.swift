import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ReceiptPagingTests {
    @Test func reconciliationPagesAndDiagnosticsSeparateWatchesWithoutDroppingTheOtherOutbox() async throws {
        let first = try Fixture(), second = try Fixture()
        defer { first.remove(); second.remove() }
        let store = try first.store()
        let firstRequest = try ReconcileRequest(sourceDeviceID: first.deviceID, receiverDeviceID: first.deviceID,
            libraryInstanceID: store.libraryInstanceID, items: [ReconcileChunkIdentity(envelope: first.envelope())])
        let secondRequest = try ReconcileRequest(sourceDeviceID: second.deviceID, receiverDeviceID: first.deviceID,
            libraryInstanceID: store.libraryInstanceID, items: [ReconcileChunkIdentity(envelope: second.envelope())])
        let old = try await store.receiveReconcileRequest(secondRequest)
        let current = try await store.receiveReconcileRequest(firstRequest)
        #expect(try await store.pendingReconcileResponses(limit: 1, sourceDeviceID: first.deviceID) == [current])
        #expect(try await store.pendingReconcileResponses(limit: 1, sourceDeviceID: second.deviceID) == [old])
        try await store.writeSyncDiagnostic()
        let diagnostic = try WireJSON.decode(ArchiveSyncDiagnostic.self, from: Data(contentsOf:
            store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/sync-receive-diagnostic.json")))
        #expect(diagnostic.pendingReconcileResponseCountsBySource == [first.deviceID.uuidString: 1, second.deviceID.uuidString: 1])
        try await store.markReconcileResponseSubmitted(messageID: current.messageID)
        let reopened = try first.store()
        #expect(try await reopened.pendingReconcileResponses(sourceDeviceID: first.deviceID).isEmpty)
        #expect(try await reopened.pendingReconcileResponses(sourceDeviceID: second.deviceID) == [old])
    }

    @Test func receiptsAndPendingStatusAreScopedToTheSelectedWatchWithoutAcknowledgingAnotherWatch() async throws {
        let first = try Fixture(), second = try Fixture()
        defer { first.remove(); second.remove() }
        let store = try first.store()
        var expected: [Receipt] = []
        for index in 0..<2 {
            for fixture in [first, second] {
                let envelope = try fixture.envelope(startFrame: Int64(index * 1600), sequence: Int64(index))
                guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
                    Issue.record("Expected an accepted recording"); return
                }
                if fixture.deviceID == first.deviceID { expected.append(receipt) }
            }
        }
        let page = try await store.pendingReceiptPage(limit: 1, sourceDeviceID: first.deviceID)
        #expect(page.entries.map(\.receipt) == [expected[0]])
        #expect(page.hasMore)
        let tail = try await store.pendingReceiptPage(after: page.scannedThrough, limit: 1, sourceDeviceID: first.deviceID)
        #expect(tail.entries.map(\.receipt) == [expected[1]])
        #expect(!tail.hasMore)
        #expect(try await store.pendingReceiptCount(sourceDeviceID: first.deviceID) == 2)
        #expect(try await store.pendingReceiptCount(sourceDeviceID: second.deviceID) == 2)
        #expect(try await store.pendingReceiptCount() == 4)
        #expect(try await store.sourceDeviceID(for: expected[0]) == first.deviceID)
        try await store.applyReceipt(ReceiptApplied(receipt: expected[0]))
        let status = try await store.phoneStatus(sourceBuild: "test", sourceDeviceID: first.deviceID)
        guard case .phone(let report) = status.payload else { Issue.record("Expected phone status"); return }
        #expect(report.pendingReceiptCount == 1)
        let refreshed = try await store.phoneStatus(sourceBuild: "test", sampledAt: status.sampledAt.addingTimeInterval(20),
            sourceDeviceID: first.deviceID, refreshObservation: true)
        #expect(refreshed.payload == status.payload)
        #expect(refreshed.revision > status.revision && refreshed.sampledAt > status.sampledAt)
        #expect(try await store.pendingReceiptCount(sourceDeviceID: second.deviceID) == 2)
        #expect(try await store.pendingReceipts().count == 3)
    }

    @Test func pagesBoundValidationAndAdvanceAcrossAcknowledgementsAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        var expected: [Receipt] = []
        for index in 0..<65 {
            let envelope = try fixture.envelope(startFrame: Int64(index * 1600), sequence: Int64(index))
            guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
                Issue.record("Expected accepted"); return
            }
            expected.append(receipt)
        }
        #expect(try await store.pendingReceiptCount() == 65)
        let first = try await store.pendingReceiptPage()
        #expect(first.entries.map(\.receipt) == Array(expected.prefix(32)))
        #expect(first.hasMore)
        try await store.applyReceipt(ReceiptApplied(receipt: expected[0]))
        let reopened = try fixture.store()
        #expect(try await reopened.pendingReceiptCount() == 64)
        let second = try await reopened.pendingReceiptPage(after: first.scannedThrough)
        #expect(second.entries.map(\.receipt) == Array(expected[32..<64]))
        let tail = try await reopened.pendingReceiptPage(after: second.scannedThrough)
        #expect(tail.entries.map(\.receipt) == [expected[64]])
        #expect(!tail.hasMore)
        #expect(try await reopened.pendingReceipts() == Array(expected.dropFirst()))
    }

    @Test func countNeverReadsAudioAndMissingFilesDoNotTrapTheCursor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(first, to: store))
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(second, to: store)) else {
            Issue.record("Expected accepted"); return
        }
        let path = await store.recordingDirectory(manifest: first.manifest) + "/audio/" + first.manifest.chunkID.uuidString + ".wav"
        try FileManager.default.removeItem(at: store.rootURL.appendingPathComponent(path))
        #expect(try await store.pendingReceiptCount() == 2, "A queue count must not scan or mutate original audio.")
        let invalid = try await store.pendingReceiptPage(limit: 1)
        #expect(invalid.entries.isEmpty)
        #expect(invalid.hasMore)
        #expect(invalid.scannedThrough > 0)
        #expect(try await store.pendingReceiptCount() == 1)
        let valid = try await store.pendingReceiptPage(after: invalid.scannedThrough, limit: 1)
        #expect(valid.entries.map(\.receipt) == [receipt])
        #expect(!valid.hasMore)
    }

    @Test func pageRejectsUnboundedQueriesAndErrorsDescribeTheUnderlyingDatabaseCode() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        await #expect(throws: ArchiveError.invalidQuery) { _ = try await store.pendingReceiptPage(limit: 33) }
        await #expect(throws: ArchiveError.invalidQuery) { _ = try await store.pendingReceiptPage(after: -1) }
        #expect(ArchiveError.database(13).localizedDescription.contains("SQLite 13"))
    }
}
