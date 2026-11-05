import Foundation
import SwiftUI
import UIKit
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

@MainActor
final class TimelineReadingIntegrationTests: XCTestCase {
    func testOpeningAMarkLocatesTextWithoutPlayingOrRepeatingTheJumpOnRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoMarkedReading-\(UUID())")
        let lifetime = trackLifetime(at: root)
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        lifetime.archive = archive
        let (document, _) = try await fixture(archive: archive, root: root, at: Date())
        let paragraph = document.spans[12]
        let lease = try await archive.acquireAudioLease(chunkID: paragraph.chunkID)
        let manifest = lease.manifest
        await archive.releaseAudioLease(id: lease.id)
        let mark = try CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: manifest.sourceDeviceID, sourceFrame: paragraph.frames.start + 1)
        try await archive.receiveMark(mark)
        let model = LibraryModel(archive: archive, configurationFingerprint: nil)
        lifetime.model = model
        await model.refresh()
        let found = try await archive.timelineWindow(containing: document.source(for: paragraph))
        let id = try XCTUnwrap(found).id
        let loadedValue = try await model.timeline.loadWindow(id)
        let loaded = try XCTUnwrap(loadedValue)
        model.timeline.rememberReadingPosition(document.spans[0].id, in: loaded.window, layout: loaded.layout)
        let playback = AudioPlaybackController(archive: archive)
        lifetime.playback = playback
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        lifetime.window = window
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var observation: TimelineReadingDiagnostic?
        var jumps: [UUID] = []
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            TimelineDetailView(id: id, library: model, playback: playback, transcription: nil, speechFailure: nil,
                retryTimeline: nil, canDiscuss: false, discuss: { _ in }, initialMarkID: mark.markID,
                readingPositionObserver: { event in
                    observation = event
                    if event.event == "scrollTo", let target = event.spanID { jumps.append(target) }
                })
        })
        window.makeKeyAndVisible()
        try await wait(in: window, stage: "marked-paragraph") {
            window.layoutIfNeeded()
            return observation?.restoringSpanID == nil && observation?.visibleSpanIDs.contains(paragraph.id) == true
                && jumps == [paragraph.id]
        }
        XCTAssertNil(playback.activeTarget, "Locating a mark must never start audio.")
        for _ in 0..<3 { await model.refresh(); await Task.yield() }
        XCTAssertEqual(jumps, [paragraph.id], "Background refresh must not repeat the explicit mark navigation.")
    }

    func testUnchangedValidationRetainsOnlyTheRequestingDetailsCurrentLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoStableTimelineLayout-\(UUID())")
        let lifetime = trackLifetime(at: root)
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        lifetime.archive = archive
        let (document, _) = try await fixture(archive: archive, root: root, at: Date())
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        lifetime.timeline = model
        let found = try await archive.timelineWindow(containing: document.source(for: document.spans[0]))
        let id = try XCTUnwrap(found).id
        await model.load(id.day)
        let first = try XCTUnwrap(model.cachedWindow(id))
        let checked = try await model.loadWindow(id, previous: first.window, preservingLayout: first.layout)
        XCTAssertEqual(checked?.layout, first.layout)
        let reopened = try XCTUnwrap(model.cachedWindow(id))
        XCTAssertNotEqual(reopened.layout, first.layout)
        do {
            _ = try await model.loadWindow(id, previous: first.window, preservingLayout: first.layout)
            XCTFail("A departed detail cannot reclaim a later detail's layout")
        } catch is CancellationError { }
        XCTAssertTrue(model.isCurrent(reopened.layout))
    }

    func testActivityStripMatchesClippedOverlappingAndExactBoundaryIntervals() {
        let start = Date(timeIntervalSince1970: 0), end = start.addingTimeInterval(100)
        let intervals = [(-5.0, 20.0), (10.0, 40.0), (30.0, 50.0), (99.0, 110.0), (150.0, 180.0)]
            .map { DateInterval(start: start.addingTimeInterval($0.0), end: start.addingTimeInterval($0.1)) }
        for count in [1, 10, 36] {
            let actual = TimelinePresentation.activity(intervals, from: start, to: end, count: count)
            let step = 100 / Double(count)
            for index in 0..<count {
                let lower = start.addingTimeInterval(Double(index) * step), upper = lower.addingTimeInterval(step)
                let expected = min(1, intervals.reduce(0) { $0 + max(0, min(upper, $1.end).timeIntervalSince(max(lower, $1.start))) } / step)
                XCTAssertEqual(actual[index], expected, accuracy: 1e-12)
            }
        }
        XCTAssertTrue(TimelinePresentation.activity(intervals, from: start, to: end, count: 0).isEmpty)
        XCTAssertTrue(TimelinePresentation.activity(intervals, from: start, to: start, count: 36).isEmpty)
    }

    func testLargeCachedWindowOpenAndReadingPositionStayWithin50Milliseconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoTimelinePerformance-\(UUID())")
        let lifetime = trackLifetime(at: root)
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        lifetime.archive = archive
        let (document, _) = try await fixture(archive: archive, root: root, at: Date(), paragraphCount: 2_000)
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        lifetime.timeline = model
        let value = try await archive.timelineWindow(containing: document.source(for: document.spans[0]))
        let id = try XCTUnwrap(value).id
        await model.load(id.day)
        var samples: [Double] = []
        for index in 0..<30 {
            let started = ContinuousClock.now
            let cached = try XCTUnwrap(model.cachedWindow(id))
            let spanID = document.spans[document.spans.count - 1 - index].id
            model.rememberReadingPosition(spanID, in: cached.window, layout: cached.layout)
            XCTAssertEqual(model.readingAnchor(in: cached.window, layout: cached.layout), spanID)
            let elapsed = started.duration(to: .now).components
            samples.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        print("TIMELINE_PERFORMANCE cachedOpenAndReading paragraphs=2000 p95_ms=\(p95 * 1000) max_ms=\((samples.last ?? 0) * 1000)")
        XCTAssertLessThan(p95, 0.050)
    }

    func testLargeDetailScrollHasNo50MillisecondDisplayGaps() async throws {
        guard ProcessInfo.processInfo.environment["MOMO_RUN_TIMELINE_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set MOMO_RUN_TIMELINE_PERFORMANCE=1 on a dedicated performance host to enforce the 50 ms display budget.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoTimelineScrollPerformance-\(UUID())")
        let lifetime = trackLifetime(at: root)
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        lifetime.archive = archive
        let (document, _) = try await fixture(archive: archive, root: root, at: Date(), paragraphCount: 2_000)
        let model = LibraryModel(archive: archive)
        lifetime.model = model
        await model.refresh()
        let value = try await archive.timelineWindow(containing: document.source(for: document.spans[0]))
        let id = try XCTUnwrap(value).id
        await model.timeline.load(id.day)
        let playback = AudioPlaybackController(archive: archive)
        lifetime.playback = playback
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        lifetime.window = window
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            TimelineDetailView(id: id, library: model, playback: playback, transcription: nil, speechFailure: nil,
                retryTimeline: nil, canDiscuss: false, discuss: { _ in })
        })
        window.makeKeyAndVisible()
        try await wait(in: window, stage: "performance-visible-text") {
            window.layoutIfNeeded()
            return (self.readingScroll(in: window)?.contentSize.height ?? 0) > window.bounds.height * 2
        }
        try await Task.sleep(for: .milliseconds(250))
        let scroll = try XCTUnwrap(readingScroll(in: window))
        let probe = TimelineScrollFrameProbe(scroll: scroll)
        probe.start()
        defer { probe.stop() }
        try await Task.sleep(for: .seconds(2))
        probe.stop()
        let samples = probe.milliseconds.sorted()
        XCTAssertGreaterThan(samples.count, 20)
        guard !samples.isEmpty else { return }
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1], maximum = samples.last ?? 0
        print("TIMELINE_PERFORMANCE scrolling paragraphs=2000 frames=\(samples.count) p95_ms=\(p95) max_ms=\(maximum)")
        XCTAssertLessThan(maximum, 50, "A measured display gap exceeded the interaction budget")
        await playback.stop()
    }

    func testWindowAnchorsKeepSecondSourceOnAppendAndRejectRevisionDeletionAndLateLayouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoTimelineReadingIdentity-\(UUID())")
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let date = Date(timeIntervalSince1970: 1_792_023_100)
        let (first, firstWriter) = try await fixture(archive: archive, root: root, at: date)
        let (second, _) = try await fixture(archive: archive, root: root, at: date.addingTimeInterval(100))
        let (other, _) = try await fixture(archive: archive, root: root, at: date.addingTimeInterval(1_900))
        var writer = firstWriter
        let initialWindow = try await archive.timelineWindow(containing: first.source(for: first.spans[0]))
        let otherWindow = try await archive.timelineWindow(containing: other.source(for: other.spans[0]))
        let id = try XCTUnwrap(initialWindow).id, otherID = try XCTUnwrap(otherWindow).id
        XCTAssertNotEqual(id, otherID)
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        let initialValue = try await model.loadWindow(id), otherValue = try await model.loadWindow(otherID)
        let initial = try XCTUnwrap(initialValue), independent = try XCTUnwrap(otherValue)
        XCTAssertEqual(initial.window.sources.map(\.sessionID), [first.sessionID, second.sessionID])
        let anchor = second.spans[12].id, otherAnchor = other.spans[4].id
        model.rememberReadingPosition(anchor, in: initial.window, layout: initial.layout)
        model.rememberReadingPosition(otherAnchor, in: independent.window, layout: independent.layout)
        let sameValue = try await model.loadWindow(id)
        let same = try XCTUnwrap(sameValue)
        XCTAssertEqual(same.window.revision, initial.window.revision)
        XCTAssertNotEqual(same.layout, initial.layout, "Recreating a layout must revoke callbacks from its predecessor, even for unchanged content.")
        XCTAssertEqual(model.readingAnchor(in: same.window, layout: same.layout), anchor)
        model.rememberReadingPosition(second.spans[13].id, in: same.window, layout: same.layout)
        model.rememberReadingPosition(first.spans[0].id, in: initial.window, layout: initial.layout)
        XCTAssertEqual(model.readingAnchor(in: same.window, layout: same.layout), second.spans[13].id)
        model.rememberReadingPosition(anchor, in: same.window, layout: same.layout)

        _ = try await append(archive: archive, writer: &writer)
        let appendedValue = try await model.loadWindow(id)
        let appended = try XCTUnwrap(appendedValue)
        XCTAssertNotEqual(appended.layout, initial.layout)
        XCTAssertEqual(model.readingAnchor(in: appended.window, layout: appended.layout), anchor)
        model.rememberReadingPosition(first.spans[0].id, in: initial.window, layout: initial.layout)
        XCTAssertEqual(model.readingAnchor(in: appended.window, layout: appended.layout), anchor,
                       "An old rendered layout cannot overwrite the second source's current reading position.")
        XCTAssertEqual(model.readingAnchor(in: independent.window, layout: independent.layout), otherAnchor)

        let revised = try await archive.reviseTranscript(sessionID: second.sessionID,
            expectedVersion: second.version, spans: second.spans)
        XCTAssertNotEqual(revised.generation, second.generation)
        let revisedValue = try await model.loadWindow(id)
        let revision = try XCTUnwrap(revisedValue)
        XCTAssertNil(model.readingAnchor(in: revision.window, layout: revision.layout),
                     "The same span UUID in a revised second source is a different reading identity.")
        model.rememberReadingPosition(anchor, in: appended.window, layout: appended.layout)
        XCTAssertNil(model.readingAnchor(in: revision.window, layout: revision.layout))
        model.rememberReadingPosition(revised.spans[8].id, in: revision.window, layout: revision.layout)
        XCTAssertEqual(model.readingAnchor(in: revision.window, layout: revision.layout), revised.spans[8].id)

        _ = try await archive.deleteSession(id: second.sessionID)
        model.invalidate(sessionID: second.sessionID)
        XCTAssertFalse(model.isCurrent(revision.layout))
        model.rememberReadingPosition(revised.spans[8].id, in: revision.window, layout: revision.layout)
        let deletedValue = try await model.loadWindow(id)
        let deleted = try XCTUnwrap(deletedValue)
        XCTAssertFalse(deleted.window.sources.contains { $0.sessionID == second.sessionID })
        XCTAssertNil(model.readingAnchor(in: deleted.window, layout: deleted.layout))
        XCTAssertEqual(model.readingAnchor(in: independent.window, layout: independent.layout), otherAnchor,
                       "Invalidating one window must not clear another window's valid reading position.")

        model.rememberReadingPosition(first.spans[2].id, in: deleted.window, layout: deleted.layout)
        _ = try await archive.deleteSession(id: first.sessionID)
        let missing = try await model.loadWindow(id)
        XCTAssertNil(missing)
        XCTAssertFalse(model.isCurrent(deleted.layout))
        model.rememberReadingPosition(first.spans[2].id, in: deleted.window, layout: deleted.layout)
        XCTAssertNil(model.readingAnchor(in: deleted.window, layout: deleted.layout))
        let evidence = XCTAttachment(string: "Synthetic silent PCM and formal Archive APIs; no ASR or model request. Retained fixture: \(root.path)")
        evidence.name = "timeline-reading-identity-fixture"; evidence.lifetime = .keepAlways; add(evidence)
    }

    func testRevisingOrInvalidatingSecondMemberRejectsFirstMembersAnchorAndOldLayouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoTimelineReadingMember-\(UUID())")
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let date = Date(timeIntervalSince1970: 1_792_023_100)
        let (first, _) = try await fixture(archive: archive, root: root, at: date)
        let (second, _) = try await fixture(archive: archive, root: root, at: date.addingTimeInterval(100))
        let value = try await archive.timelineWindow(containing: first.source(for: first.spans[0]))
        let id = try XCTUnwrap(value).id
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        let loadedValue = try await model.loadWindow(id)
        let loaded = try XCTUnwrap(loadedValue)
        model.rememberReadingPosition(first.spans[5].id, in: loaded.window, layout: loaded.layout)
        XCTAssertEqual(model.readingAnchor(in: loaded.window, layout: loaded.layout), first.spans[5].id)
        _ = try await archive.reviseTranscript(sessionID: second.sessionID, expectedVersion: second.version, spans: second.spans)
        let revisedValue = try await model.loadWindow(id)
        let revised = try XCTUnwrap(revisedValue)
        XCTAssertNil(model.readingAnchor(in: revised.window, layout: revised.layout),
                     "Changing a second member invalidates the window's old reading context even when the saved paragraph belongs to the first.")
        model.rememberReadingPosition(first.spans[5].id, in: loaded.window, layout: loaded.layout)
        XCTAssertNil(model.readingAnchor(in: revised.window, layout: revised.layout))
        model.rememberReadingPosition(first.spans[5].id, in: revised.window, layout: revised.layout)
        model.invalidate(sessionID: second.sessionID)
        XCTAssertFalse(model.isCurrent(revised.layout))
        model.rememberReadingPosition(first.spans[5].id, in: revised.window, layout: revised.layout)
        let refreshedValue = try await model.loadWindow(id)
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertNotEqual(refreshed.layout, revised.layout, "A matching revision string cannot revive an invalidated layout token.")
        XCTAssertNil(model.readingAnchor(in: refreshed.window, layout: refreshed.layout))
    }

    func testTimelineDetailRestoresVisibleParagraphAfterRecreationAndKeepsItsFrameOnAppend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoTimelineReadingScroll-\(UUID())")
        let lifetime = ReadingLifetime()
        addTeardownBlock { @MainActor in
            lifetime.window?.isHidden = true
            lifetime.window?.rootViewController = nil
            await lifetime.playback?.stop()
            let deadline = ContinuousClock.now + .seconds(10)
            while lifetime.hasOwners && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(lifetime.hasOwners, "Retaining the fixture while an archive/model/player is still owned: \(lifetime.description)")
            guard !lifetime.hasOwners else { return }
            try FileManager.default.removeItem(at: root)
        }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        lifetime.archive = archive
        let (document, initialWriter) = try await fixture(archive: archive, root: root,
            at: Date(timeIntervalSince1970: 1_792_023_100))
        var writer = initialWriter
        let model = LibraryModel(archive: archive)
        lifetime.model = model
        await model.refresh()
        let windowValue = try await archive.timelineWindow(containing: document.source(for: document.spans[0]))
        let id = try XCTUnwrap(windowValue).id
        let loadedValue = try await model.timeline.loadWindow(id)
        let loaded = try XCTUnwrap(loadedValue)
        let playback = AudioPlaybackController(archive: archive)
        lifetime.playback = playback
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        lifetime.window = window
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var trace: [String] = []
        var observations: [Int: TimelineReadingDiagnostic] = [:]
        var frames: [Int: [UUID: CGRect]] = [:]
        var frameLayouts: [Int: [UUID: TimelineReadingLayoutToken]] = [:]
        var incarnation = 0
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "timeline-reading-identity-and-geometry-trace"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        func showDetail() {
            incarnation += 1
            let current = incarnation
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                TimelineDetailView(id: id, library: model, playback: playback, transcription: nil, speechFailure: nil,
                    retryTimeline: nil, canDiscuss: false, discuss: { _ in }, readingPositionObserver: { [weak window] event in
                        observations[current] = event
                        if let spanID = event.spanID {
                            if let frame = event.frame {
                                frames[current, default: [:]][spanID] = frame
                                frameLayouts[current, default: [:]][spanID] = event.layout
                            }
                            if event.event == "disappear" { frames[current]?[spanID] = nil }
                        }
                        if trace.count < 600 {
                            let scroll = window.flatMap { self.readingScroll(in: $0) }
                            trace.append("view=\(current) offset=\(String(describing: scroll?.contentOffset.y)) content=\(String(describing: scroll?.contentSize)) \(event.description)")
                        }
                    })
            }.environment(\.dynamicTypeSize, .large))
            window.makeKeyAndVisible()
        }
        showDetail()
        try await wait(in: window, stage: "initial-layout") {
            window.layoutIfNeeded()
            return self.readingScroll(in: window) != nil
        }
        let initial = try XCTUnwrap(readingScroll(in: window))
        initial.setContentOffset(CGPoint(x: 0, y: 2400), animated: false)
        trace.append("requested-native-scroll=2400 actual=\(initial.contentOffset.y)")
        try await wait(in: window, stage: "initial-anchor") {
            guard let layout = observations[1]?.layout,
                  let anchor = model.timeline.readingAnchor(in: loaded.window, layout: layout),
                  let index = loaded.window.paragraphs.firstIndex(where: { $0.id == anchor }) else { return false }
            return index > 2 && initial.contentOffset.y > 2000
        }
        let initialLayout = try XCTUnwrap(observations[1]?.layout)
        let anchor = try XCTUnwrap(model.timeline.readingAnchor(in: loaded.window, layout: initialLayout))
        let beforeFrame = try XCTUnwrap(frames[1]?[anchor])
        let beforeObservation = try XCTUnwrap(observations[1])
        XCTAssertGreaterThan(visibleHeight(beforeFrame, viewport: beforeObservation.viewportHeight), 44)
        screenshot(window, name: "timeline-reading-before-leaving")
        window.rootViewController = UIViewController()
        await Task.yield()
        showDetail()
        try await wait(in: window, stage: "restored-anchor") {
            window.layoutIfNeeded()
            guard let observation = observations[2], let layout = observation.layout,
                  let frame = frames[2]?[anchor] else { return false }
            return observation.restoringSpanID == nil && observation.visibleSpanIDs.first == anchor
                && model.timeline.readingAnchor(in: loaded.window, layout: layout) == anchor
                && self.visibleHeight(frame, viewport: observation.viewportHeight) > 44
        }
        XCTAssertNil(observations[2]?.restoringSpanID)
        XCTAssertEqual(observations[2]?.visibleSpanIDs.first, anchor)
        screenshot(window, name: "timeline-reading-after-restore")

        // A lazy scroll can expose the target before its final native anchor correction.
        // Sample after the screenshot and require three consecutive real layout checks;
        // an unsettled restore must not become the baseline for the append assertion.
        func stableReadingFrame(in expectedWindow: TimelineWindow, stage: String) async throws -> CGRect {
            let revision = expectedWindow.revision
            var candidateLayout: TimelineReadingLayoutToken?
            var candidateFrame: CGRect?
            var consecutiveChecks = 0
            var result: CGRect?
            try await wait(in: window, stage: stage) {
                window.layoutIfNeeded()
                guard let observation = observations[2], let layout = observation.layout,
                      layout.revision == revision, let frame = frames[2]?[anchor],
                      frameLayouts[2]?[anchor] == layout,
                      observation.restoringSpanID == nil, observation.visibleSpanIDs.first == anchor,
                      model.timeline.readingAnchor(in: expectedWindow, layout: layout) == anchor,
                      self.visibleHeight(frame, viewport: observation.viewportHeight) > 44 else {
                    candidateLayout = nil; candidateFrame = nil; consecutiveChecks = 0; result = nil
                    return false
                }
                let unchanged = candidateFrame.map {
                    abs($0.minX - frame.minX) <= 0.25 && abs($0.minY - frame.minY) <= 0.25
                        && abs($0.width - frame.width) <= 0.25 && abs($0.height - frame.height) <= 0.25
                } ?? false
                if candidateLayout == layout, unchanged {
                    consecutiveChecks = min(3, consecutiveChecks + 1)
                } else {
                    candidateLayout = layout; candidateFrame = frame; consecutiveChecks = 1
                }
                result = consecutiveChecks == 3 ? frame : nil
                return result != nil
            }
            let stable = try XCTUnwrap(result)
            trace.append("\(stage) stable-checks=\(consecutiveChecks) tolerance=0.25 layout=\(String(describing: candidateLayout?.identity)) revision=\(revision) frame=\(stable)")
            return stable
        }

        let restoredFrame = try await stableReadingFrame(in: loaded.window, stage: "restored-frame-stable")
        let unchangedLayout = observations[2]?.layout
        for _ in 0..<5 { await model.refresh(); await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(observations[2]?.layout, unchangedLayout,
            "Unchanged library refreshes must not cancel and restart the open detail load.")
        let restored = try XCTUnwrap(readingScroll(in: window))
        trace.append("restore-verified offset=\(restored.contentOffset.y) frame=\(restoredFrame)")
        _ = try await append(archive: archive, writer: &writer)
        let updatedValue = try await archive.timelineWindow(id)
        let updated = try XCTUnwrap(updatedValue)
        XCTAssertNotEqual(updated.revision, loaded.window.revision)
        await model.refresh()
        try await wait(in: window, stage: "appended-layout") {
            window.layoutIfNeeded()
            return observations[2]?.layout?.revision == updated.revision
                && frameLayouts[2]?[anchor]?.revision == updated.revision
                && observations[2]?.restoringSpanID == nil && observations[2]?.visibleSpanIDs.first == anchor
        }
        let appendedFrame = try await stableReadingFrame(in: updated, stage: "appended-frame-stable")
        XCTAssertEqual(appendedFrame.minY, restoredFrame.minY, accuracy: 4,
                       "Appending text below the same paragraph must preserve its actual viewport location.")
        XCTAssertEqual(appendedFrame.height, restoredFrame.height, accuracy: 4)
        let currentLayout = try XCTUnwrap(observations[2]?.layout)
        XCTAssertEqual(model.timeline.readingAnchor(in: updated, layout: currentLayout), anchor)
        trace.append("append-verified offset=\(restored.contentOffset.y) frame=\(appendedFrame)")
        screenshot(window, name: "timeline-reading-after-append")
        window.rootViewController = nil
        await playback.stop()
    }

    private func fixture(archive: ArchiveStore, root: URL, at: Date, paragraphCount: Int = 20) async throws -> (TranscriptDocument, PCM16SegmentWriter) {
        let sessionID = UUID()
        let frameCount = paragraphCount * 80
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input-\(sessionID)"), sessionID: sessionID,
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "timeline-reading-fixture", sourceKind: .fixture,
            targetFrames: frameCount, wallClockAnchor: at, timezoneOffset: 0)
        let chunk = try XCTUnwrap(writer.append([Int16](repeating: 0, count: frameCount)).first)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "timeline-reading")
        let ticket = try XCTUnwrap(claimed)
        XCTAssertEqual(ticket.manifest.sessionID, sessionID)
        let spans = try (0..<paragraphCount).map { index in
            TranscriptSpan(chunkID: ticket.chunkID, frames: try FrameRange(start: Int64(index * 80), count: 80),
                text: "第\(index + 1)段。" + String(repeating: "这是用于时间线长文阅读位置验证的合成文字，没有调用语音识别或外部模型。", count: 12))
        }
        return (try await archive.commitTranscript(ticket: ticket, spans: spans), writer)
    }

    private func append(archive: ArchiveStore, writer: inout PCM16SegmentWriter) async throws -> TranscriptDocument {
        let chunk = try XCTUnwrap(writer.append([Int16](repeating: 0, count: 1600)).first)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "timeline-reading")
        let ticket = try XCTUnwrap(claimed)
        XCTAssertEqual(ticket.chunkID, chunk.envelope.manifest.chunkID)
        return try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames,
                           text: String(repeating: "追加的真实归档段落不得改变当前阅读位置。", count: 20))
        ])
    }

    private func visibleHeight(_ frame: CGRect, viewport: CGFloat) -> CGFloat {
        min(frame.maxY, viewport) - max(frame.minY, 0)
    }

    private func readingScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 200,
           scroll.contentSize.height > scroll.bounds.height * 3 { return scroll }
        for child in view.subviews { if let result = readingScroll(in: child) { return result } }
        return nil
    }

    private func screenshot(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(in window: UIWindow, stage: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let passed = condition()
        if !passed {
            screenshot(window, name: "timeline-reading-failed-\(stage)")
            if let scroll = readingScroll(in: window) {
                let attachment = XCTAttachment(string: "bounds=\(scroll.bounds) content=\(scroll.contentSize) offset=\(scroll.contentOffset) inset=\(scroll.adjustedContentInset)")
                attachment.name = "timeline-reading-native-scroll-\(stage)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertTrue(passed, "Actual timeline layout/anchor did not settle: \(stage)")
        if !passed { throw ReadingFailure.unsettled(stage) }
    }

    func testTimelineHydratesCachedSummarySynchronouslyBeforeFirstListPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoCachedSummaryFirstFrame-\(UUID())")
        let lifetime = trackLifetime(at: root)
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        lifetime.archive = archive
        let (document, _) = try await fixture(archive: archive, root: root, at: Date())
        let foundWindow = try await archive.timelineWindow(containing: document.source(for: document.spans[0]))
        let seededWindow = try XCTUnwrap(foundWindow)
        XCTAssertTrue(seededWindow.canSummarize)
        let expectedSummary = "会议核心结论：确定下周上线端侧语音方案。"
        let revision = seededWindow.summaryRevision

        let model = TimelineModel(
            archive: archive,
            configurationFingerprint: nil,
            cachedSummaries: { revisions in
                revisions.contains(revision) ? [revision: expectedSummary] : [:]
            },
            summarize: { _ in
                try await Task.sleep(for: .seconds(5))
                return [revision: expectedSummary]
            }
        )
        lifetime.timeline = model

        await model.load(seededWindow.id.day)
        let listed = try XCTUnwrap(model.listWindows[seededWindow.id.day]?.first { $0.id == seededWindow.id })
        XCTAssertEqual(model.summary(for: listed), expectedSummary)
        XCTAssertEqual(
            TimelinePresentation.preview(listed, summary: model.summary(for: listed)),
            expectedSummary
        )
    }

    private enum ReadingFailure: Error { case unsettled(String) }

    private func trackLifetime(at root: URL) -> ReadingLifetime {
        let lifetime = ReadingLifetime()
        addTeardownBlock { @MainActor in
            lifetime.window?.isHidden = true
            lifetime.window?.rootViewController = nil
            await lifetime.playback?.stop()
            let deadline = ContinuousClock.now + .seconds(10)
            while lifetime.hasOwners && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(lifetime.hasOwners, "Retaining the fixture while an archive/model/player is still owned: \(lifetime.description)")
            guard !lifetime.hasOwners else { return }
            try FileManager.default.removeItem(at: root)
        }
        return lifetime
    }

    @MainActor private final class ReadingLifetime {
        weak var archive: ArchiveStore?
        weak var model: LibraryModel?
        weak var timeline: TimelineModel?
        weak var playback: AudioPlaybackController?
        weak var window: UIWindow?
        var hasOwners: Bool { archive != nil || model != nil || timeline != nil || playback != nil }
        var description: String { "archive=\(archive != nil), model=\(model != nil), timeline=\(timeline != nil), playback=\(playback != nil)" }
    }
}

@MainActor private final class TimelineScrollFrameProbe: NSObject {
    private weak var scroll: UIScrollView?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var warmup = 3
    private(set) var milliseconds: [Double] = []

    init(scroll: UIScrollView) { self.scroll = scroll }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() { displayLink?.invalidate(); displayLink = nil }

    @objc private func frame(_ link: CADisplayLink) {
        if let lastTimestamp, warmup == 0 { milliseconds.append((link.timestamp - lastTimestamp) * 1_000) }
        lastTimestamp = link.timestamp
        if warmup > 0 { warmup -= 1 }
        if let scroll {
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + 36)), animated: false)
        }
    }
}
