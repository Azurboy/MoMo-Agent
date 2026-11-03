import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

@MainActor
final class ArchiveExportLifecycleTests: XCTestCase {
    func testTimelineMarkdownUsesExistingShareCompletionAndCancellationCleanup() async throws {
        let (archive, _) = try await makeRecording()
        let claimed = try await archive.claimAnalysisJob(configurationHash: "export-lifecycle-test")
        let ticket = try XCTUnwrap(claimed)
        _ = try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "今天核对设计评审时间。")
        ])
        let day = TimelineDay(ticket.manifest.wallClockAnchor.addingTimeInterval(Double(ticket.manifest.timezoneOffset)),
                              calendar: TimelineDay.calendar)
        let controller = ArchiveExportController()
        controller.start(scope: .day(day), configurationFingerprint: nil, archive: archive)
        try await waitUntil { !controller.preparing }
        let artifact = try XCTUnwrap(controller.presented)
        XCTAssertEqual(artifact.fileURLs.map(\.pathExtension), ["md"])
        controller.presentationDismissed()
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURLs[0].path))
        controller.activityCompleted(id: artifact.id, errorMessage: nil)
        try await waitUntil { !controller.busy }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.fileURLs[0].path))
        controller.start(scope: .day(day), configurationFingerprint: nil, archive: archive)
        controller.cancelPreparation()
        try await waitUntil { !controller.busy }
        XCTAssertNil(controller.presented)
        let usage = try await archive.storageUsage(modelDirectory: nil)
        XCTAssertEqual(usage.temporaryBytes, 0)
    }

    func testSheetDismissalKeepsExtensionFilesUntilCompletionAndDuplicateCompletionIsHarmless() async throws {
        let (archive, recording) = try await makeRecording()
        let controller = ArchiveExportController()
        controller.start(recording: recording, content: .audio, archive: archive)
        try await waitUntil { !controller.preparing }
        let artifact = try XCTUnwrap(controller.presented)
        XCTAssertNil(controller.failure)
        XCTAssertTrue(artifact.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        controller.presentationDismissed()
        XCTAssertNil(controller.presented)
        XCTAssertTrue(controller.busy)
        XCTAssertTrue(artifact.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                      "A system extension can keep reading after SwiftUI dismisses its sheet")
        controller.activityCompleted(id: artifact.id, errorMessage: nil)
        controller.activityCompleted(id: artifact.id, errorMessage: nil)
        try await waitUntil { !controller.busy }
        XCTAssertFalse(artifact.fileURLs.contains { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(controller.cleanupNeeded)
        XCTAssertNil(controller.failure)
    }

    func testCancellationBeforePreparationCompletesNeverPresentsOrLeavesCopies() async throws {
        let (archive, recording) = try await makeRecording()
        let controller = ArchiveExportController()
        controller.start(recording: recording, content: .audio, archive: archive)
        controller.cancelPreparation()
        try await waitUntil { !controller.busy }
        XCTAssertNil(controller.presented)
        XCTAssertNil(controller.failure)
        let usage = try await archive.storageUsage(modelDirectory: nil)
        XCTAssertEqual(usage.temporaryBytes, 0)
    }

    func testCompletionBeforeSheetDismissalCannotStartAnExportThatOldDismissalWouldHide() async throws {
        let (archive, recording) = try await makeRecording()
        let controller = ArchiveExportController()
        controller.start(recording: recording, content: .audio, archive: archive)
        try await waitUntil { !controller.preparing }
        let artifact = try XCTUnwrap(controller.presented)
        controller.activityCompleted(id: artifact.id, errorMessage: nil)
        try await waitUntil { !FileManager.default.fileExists(atPath: artifact.fileURLs[0].path) }
        XCTAssertTrue(controller.busy, "The old sheet has not finished dismissing")
        controller.start(recording: recording, content: .audio, archive: archive)
        XCTAssertNil(controller.presented)
        controller.presentationDismissed()
        try await waitUntil { !controller.busy }
    }

    func testShareSheetDismissalNeverBlocksHostCloseAndRecoversMissingExtensionCallback() async throws {
        let (archive, recording) = try await makeRecording()
        let controller = ArchiveExportController()
        controller.start(recording: recording, content: .audio, archive: archive)
        try await waitUntil { !controller.preparing }
        let artifact = try XCTUnwrap(controller.presented)
        XCTAssertTrue(controller.blocksHostDismissal)

        // Simulate interactive dismissal or a third-party extension dismissing without completionWithItemsHandler.
        controller.presentationDismissed(id: artifact.id, fallbackCleanupDelay: .milliseconds(80))
        XCTAssertFalse(controller.blocksHostDismissal, "Host close button and swipe-down must re-enable as soon as the activity sheet closes")
        try await waitUntil { !controller.busy }
        XCTAssertFalse(artifact.fileURLs.contains { FileManager.default.fileExists(atPath: $0.path) })

        // Also verify explicit host close reclaims staged files without blocking UI dismissal.
        controller.start(recording: recording, content: .audio, archive: archive)
        try await waitUntil { !controller.preparing }
        let second = try XCTUnwrap(controller.presented)
        controller.hostDidClose(graceDelay: .milliseconds(20))
        XCTAssertFalse(controller.blocksHostDismissal)
        try await waitUntil { !controller.busy }
        XCTAssertFalse(second.fileURLs.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testSuccessfulShareSetsCompletedSuccessfullyOnlyWithoutError() async throws {
        let (archive, recording) = try await makeRecording()
        let controller = ArchiveExportController()
        controller.start(recording: recording, content: .audio, archive: archive)
        try await waitUntil { !controller.preparing }
        let artifact = try XCTUnwrap(controller.presented)
        XCTAssertFalse(controller.completedSuccessfully)
        controller.activityCompleted(id: artifact.id, completed: true, errorMessage: nil)
        controller.presentationDismissed(id: artifact.id)
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.completedSuccessfully)
        XCTAssertFalse(controller.blocksHostDismissal)
    }

    private func makeRecording() async throws -> (ArchiveStore, RecordingSummary) {
        // The runner removes this workspace after the test host exits and closes SQLite handles.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoExportLifecycle-\(UUID())")
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("fixture"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "export-lifecycle-test",
            sourceKind: .fixture, wallClockAnchor: Date(), timezoneOffset: 28800)
        _ = try writer.append([Int16](repeating: 0, count: 1600))
        let chunk = try XCTUnwrap(writer.finish())
        let item = try archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope)
        _ = try await archive.commitReceivedChunk(item)
        let recordings = try await archive.recordings()
        return (archive, try XCTUnwrap(recordings.first))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}
