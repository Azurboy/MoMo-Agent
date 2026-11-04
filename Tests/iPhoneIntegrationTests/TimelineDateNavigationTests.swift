import Foundation
import XCTest
@testable import MoMoArchive
import MoMoContracts
import MoMoRecording
import SwiftUI
import Observation
import UIKit
import Vision
@testable import MoMoAgent

@MainActor
final class TimelineDateNavigationTests: XCTestCase {
    func testUnchangedRefreshReusesTheDayUntilArchiveContentChanges() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let day = TimelineDay(Date())
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        try await receive(archive, root: root, at: day.date().addingTimeInterval(9 * 3_600), offset: 0)
        await model.load(day)
        let initialBuilds = await archive.timelineDayBuildCount
        for _ in 0..<8 { await model.refresh() }
        let unchangedBuilds = await archive.timelineDayBuildCount
        XCTAssertEqual(unchangedBuilds, initialBuilds, "Status refreshes must not rebuild unchanged date content.")
        try await receive(archive, root: root, at: day.date().addingTimeInterval(11 * 3_600), offset: 0)
        await model.refresh()
        let changedBuilds = await archive.timelineDayBuildCount
        XCTAssertEqual(changedBuilds, initialBuilds + 1)
        XCTAssertEqual(model.listWindows[day]?.count, 2)
        XCTAssertEqual(model.listWindows[day]?.map(\.id.start), model.listWindows[day]?.map(\.id.start).sorted())
    }

    func testCancelledQueuedDayDoesNotBlockAnImmediateReturnToThatDay() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let day = TimelineDay(Date()), model = TimelineModel(archive: archive, configurationFingerprint: nil)
        try await receive(archive, root: root, at: day.date().addingTimeInterval(9 * 3_600), offset: 0)
        let baseline = await archive.timelineDayBuildCount
        let entered = expectation(description: "Archive busy before navigation")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached { try await archive.holdTimelineDateRead(entered: entered, release: release) }
        defer { release.signal() }
        await fulfillment(of: [entered], timeout: 3)
        let first = Task { await model.load(day) }
        try await waitForLoading(model, day: day)
        first.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let returned = Task { await model.load(day) }
        try await Task.sleep(for: .milliseconds(30))
        release.signal()
        try await holding.value
        await first.value
        await returned.value
        let builds = await archive.timelineDayBuildCount
        XCTAssertEqual(builds, baseline + 1, "The cancelled queued read must exit before scanning the archive.")
        XCTAssertEqual(model.snapshots[day]?.count, 1)
        XCTAssertFalse(model.loading.contains(day))
        XCTAssertNil(model.failures[day])
    }

    func testCancellingListReadKeepsTheSharedDetailReadAlive() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let day = TimelineDay(Date()), model = TimelineModel(archive: archive, configurationFingerprint: nil)
        try await receive(archive, root: root, at: day.date().addingTimeInterval(9 * 3_600), offset: 0)
        let windows = try await archive.timelineDay(day)
        let id = try XCTUnwrap(windows.first?.id)
        let baseline = await archive.timelineDayBuildCount
        let entered = expectation(description: "Archive busy before shared read")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached { try await archive.holdTimelineDateRead(entered: entered, release: release) }
        defer { release.signal() }
        await fulfillment(of: [entered], timeout: 3)
        let list = Task { await model.load(day) }
        try await waitForLoading(model, day: day)
        let detail = Task { try await model.loadWindow(id) }
        try await Task.sleep(for: .milliseconds(30))
        list.cancel()
        try await Task.sleep(for: .milliseconds(30))
        release.signal()
        try await holding.value
        let loaded = try await detail.value
        await list.value
        XCTAssertEqual(loaded?.window.id, id)
        let builds = await archive.timelineDayBuildCount
        XCTAssertEqual(builds, baseline + 1)
        XCTAssertFalse(model.loading.contains(day))
    }

    func testClockOverlapHandlesNestedAndEqualRangesAcrossOffsets() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func window(_ start: Double, _ end: Double, offset: Int) -> TimelineWindow {
            let id = TimelineWindowID(start: base.addingTimeInterval(start - Double(offset)), timezoneOffset: offset)
            return TimelineWindow(id: id, end: base.addingTimeInterval(end - Double(offset)), sources: [], paragraphs: [],
                state: .complete, isFinal: true, isMarked: false, unavailableAudio: false, revision: id.key,
                configurationFingerprint: nil, speechIntervals: [])
        }
        let outer = window(0, 3_600, offset: 0)
        let inner = window(600, 900, offset: 3_600)
        let same = window(600, 900, offset: 7_200)
        let separate = window(7_200, 7_800, offset: 0)
        XCTAssertEqual(TimelineDate.repeatedClockRanges(in: [separate, inner, outer, same]), [outer.id, inner.id, same.id])
        let mixed = (0..<160).map { index in
            let start = Double((index * 97) % 1_000) * 60
            return window(start, start + Double((index * 31) % 100) * 60,
                offset: [0, 3_600, -3_600, 19_800][index % 4])
        }
        var expected: Set<TimelineWindowID> = []
        for (index, value) in mixed.enumerated() {
            let start = floor((value.id.start.timeIntervalSince1970 + Double(value.id.timezoneOffset)) / 60)
            let end = floor((value.end.timeIntervalSince1970 + Double(value.id.timezoneOffset)) / 60)
            for other in mixed.dropFirst(index + 1) where value.id.timezoneOffset != other.id.timezoneOffset {
                let otherStart = floor((other.id.start.timeIntervalSince1970 + Double(other.id.timezoneOffset)) / 60)
                let otherEnd = floor((other.end.timeIntervalSince1970 + Double(other.id.timezoneOffset)) / 60)
                if start <= otherEnd, otherStart <= end { expected.formUnion([value.id, other.id]) }
            }
        }
        XCTAssertEqual(TimelineDate.repeatedClockRanges(in: mixed), expected)
        let many = (0..<12_000).map { window(Double($0) * 120, Double($0) * 120 + 30, offset: 0) }
        let start = ContinuousClock.now
        XCTAssertTrue(TimelineDate.repeatedClockRanges(in: many).isEmpty)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1), "Uniform-offset history must not perform pairwise comparisons.")
    }

    private func waitForLoading(_ model: TimelineModel, day: TimelineDay) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.loading.contains(day), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.loading.contains(day))
        try await Task.sleep(for: .milliseconds(30))
    }

    func testTimelineAsyncLoadDefaultsToNewestAtBottom() async throws {
        try await assertInitialPosition(preloaded: false)
    }

    func testTimelineCachedDayDefaultsToNewestAtBottom() async throws {
        try await assertInitialPosition(preloaded: true)
    }

    func testShortTimelineKeepsHorizontalInsetsAfterAsyncLoad() async throws {
        try await assertInitialPosition(preloaded: false, hours: 17...19)
    }

    func testShortTimelineKeepsHorizontalInsetsWhenCached() async throws {
        try await assertInitialPosition(preloaded: true, hours: 17...19)
    }

    func testHistoricalTimelineKeepsHorizontalInsetsWhenCached() async throws {
        try await assertInitialPosition(preloaded: true, hours: 17...19, dayOffset: -2)
    }

    func testSingleWindowKeepsInsetsInPhoneTabsAfterRefreshAndReturn() async throws {
        try await assertInitialPosition(preloaded: false, hours: 19...19, inTabs: true)
    }

    func testHistoricalShortListKeepsInsetsInPhoneTabsAfterRefreshAndReturn() async throws {
        try await assertInitialPosition(preloaded: true, hours: 17...19, dayOffset: -2, inTabs: true)
    }

    func testHistoricalLongListKeepsInsetsInPhoneTabsAfterRefreshAndReturn() async throws {
        try await assertInitialPosition(preloaded: true, hours: 8...19, dayOffset: -2, inTabs: true)
    }

    private func assertInitialPosition(preloaded: Bool, hours: ClosedRange<Int> = 8...19, dayOffset: Int = 0,
                                       inTabs: Bool = false) async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let day = TimelineDay(Date()).adding(days: dayOffset), base = day.date()
        let yesterday = base.addingTimeInterval(-12 * 3_600)
        try await receive(archive, root: root, at: yesterday, offset: TimeZone.current.secondsFromGMT(for: yesterday))
        for hour in hours {
            let at = base.addingTimeInterval(Double(hour) * 3_600)
            try await receive(archive, root: root, at: at, offset: TimeZone.current.secondsFromGMT(for: at))
        }
        let model = LibraryModel(archive: archive, configurationFingerprint: nil)
        model.timeline.select(day)
        if preloaded { await model.refresh() }
        let player = AudioPlaybackController(archive: archive)
        addTeardownBlock { await player.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let selection = TimelineLayoutTabSelection()
        let library = NavigationStack {
            LibraryView(model: model, playback: player, transcription: nil, speechFailure: nil, batches: [],
                delete: { _ in }, refresh: { await model.refresh() }, canDiscuss: false, discuss: { _ in })
        }.environment(\.colorScheme, .light)
        if inTabs {
            window.rootViewController = UIHostingController(rootView: TimelineLayoutTabs(selection: selection) { library })
        } else {
            window.rootViewController = UIHostingController(rootView: library)
        }
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()

        func verticalScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView,
               scroll.alwaysBounceVertical,
               scroll.contentSize.height > 0,
               scroll.contentSize.width <= scroll.bounds.width + 1,
               scroll.convert(scroll.bounds, to: window).intersection(window.bounds).width > 100 {
                return scroll
            }
            return view.subviews.lazy.compactMap { verticalScrollView(in: $0) }.first
        }
        func visibleText() throws -> String {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image {
                _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            // OCR verifies visible content, not layout: its glyph bounds vary with the
            // recognition model. Insets are measured from UIKit below and from actual
            // row frames in PhoneTimelineJourneyTests.
            let attachment = XCTAttachment(image: image)
            attachment.name = "timeline-entry-\(preloaded ? "cached" : "async")-\(hours.count)-rows"
            attachment.lifetime = .keepAlways
            add(attachment)
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        }
        var scroll: UIScrollView?
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            scroll = verticalScrollView(in: window)
            if let scroll, model.timeline.listWindows[day]?.count == hours.count,
               abs(scroll.contentOffset.y - max(-scroll.adjustedContentInset.top,
                   scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)) < 3 { break }
        } while ContinuousClock.now < deadline
        // Let UIKit finish presenting the hosting window before measuring rendered text.
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let content = try XCTUnwrap(scroll)
        XCTAssertEqual(content.contentOffset.x, -content.adjustedContentInset.left, accuracy: 1,
            "Vertical reading must not shift the page horizontally.")
        XCTAssertEqual(content.contentOffset.y, max(-content.adjustedContentInset.top,
            content.contentSize.height - content.bounds.height + content.adjustedContentInset.bottom), accuracy: 3,
            "The first asynchronous archive load must land at the bottom.")
        XCTAssertTrue(try visibleText().contains("19:00"), "The newest time belongs at the bottom.")
        if inTabs {
            for cycle in 0..<2 {
                // Discover older archive pages while the user is reading a different day.
                let older = day.adding(days: -5 - cycle).date().addingTimeInterval(12 * 3_600)
                try await receive(archive, root: root, at: older, offset: TimeZone.current.secondsFromGMT(for: older))
                let priorIDs = model.timeline.listWindows[day, default: []].map(\.id)
                // Late audio joins each visible group and changes its start/identity.
                // This exercises the production reading-position replacement path.
                for hour in hours {
                    let at = base.addingTimeInterval(Double(hour) * 3_600 - Double(cycle + 1) * 30)
                    try await receive(archive, root: root, at: at, offset: TimeZone.current.secondsFromGMT(for: at))
                }
                await model.refresh()
                let currentIDs = Set(model.timeline.listWindows[day, default: []].map(\.id))
                XCTAssertEqual(priorIDs.count, hours.count)
                XCTAssertEqual(currentIDs.count, hours.count)
                for prior in priorIDs {
                    let replacement = try XCTUnwrap(model.timeline.currentID(prior))
                    XCTAssertNotEqual(replacement, prior)
                    XCTAssertTrue(currentIDs.contains(replacement))
                }
                try await Task.sleep(for: .milliseconds(500))
                let refreshed = try XCTUnwrap(verticalScrollView(in: window))
                print("TIMELINE_REGROUP rows=\(hours.count) dayOffset=\(dayOffset) cycle=\(cycle) offsetX=\(refreshed.contentOffset.x)")
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image {
                    _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "timeline-regrouped-\(hours.count)-rows-cycle-\(cycle)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(refreshed.contentOffset.x, -refreshed.adjustedContentInset.left, accuracy: 1,
                    "Replacing archive groups must not scroll the reading pane horizontally.")
                selection.value = 0
                try await Task.sleep(for: .milliseconds(200))
                selection.value = 1
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                let restored = try XCTUnwrap(verticalScrollView(in: window))
                XCTAssertEqual(restored.contentOffset.x, -restored.adjustedContentInset.left, accuracy: 1,
                    "Returning to the transcript tab after refresh must preserve horizontal insets (cycle \(cycle)).")
                XCTAssertTrue(try visibleText().contains("19:00"))
            }
        }
    }

    func testDelayedArchiveRangeRemainsUnknownUntilRealBoundsArrive() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let today = TimelineDay(Date()), first = today.adding(days: -3)
        let recordedAt = first.date().addingTimeInterval(12 * 3_600)
        try await receive(archive, root: root, at: recordedAt, offset: TimeZone.current.secondsFromGMT(for: recordedAt))
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        let entered = expectation(description: "Archive read gate entered")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached { try await archive.holdTimelineDateRead(entered: entered, release: release) }
        defer { release.signal() }
        await fulfillment(of: [entered], timeout: 3)
        let loading = Task { await model.load(today) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.loading.contains(today), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.loading.contains(today))
        XCTAssertNil(model.earliestDay)
        XCTAssertFalse(model.hasLoadedDateRange, "A suspended real archive query is not an empty archive.")
        let unknown = TimelineDateRange(earliestDay: model.earliestDay, hasLoaded: model.hasLoadedDateRange, today: today)
        XCTAssertTrue(unknown.isUnknown)
        XCTAssertTrue(unknown.canRequest(today.adding(days: -1), today: today),
                      "Earlier navigation remains requestable while the real range is loading.")
        XCTAssertFalse(unknown.canRequest(today.adding(days: 1), today: today))

        release.signal()
        try await holding.value
        await loading.value
        XCTAssertTrue(model.hasLoadedDateRange)
        XCTAssertEqual(model.earliestDay, first)
        XCTAssertEqual(model.days, (0...3).map { first.adding(days: $0) })
        let known = TimelineDateRange(earliestDay: model.earliestDay, hasLoaded: model.hasLoadedDateRange, today: today)
        XCTAssertEqual(known, .known(first...today))
        XCTAssertTrue(known.canRequest(first, today: today))
        XCTAssertTrue(known.canRequest(today.adding(days: -1), today: today), "Empty days inside the real range remain reachable.")
        XCTAssertFalse(known.canRequest(first.adding(days: -1), today: today))
        XCTAssertFalse(known.canRequest(today.adding(days: 1), today: today))
    }

    func testFailedRangeQueryCanRetryWithoutClaimingEmptyOrLosingKnownBounds() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let today = TimelineDay(Date()), first = today.adding(days: -2)
        let recordedAt = first.date().addingTimeInterval(12 * 3_600)
        try await receive(archive, root: root, at: recordedAt, offset: TimeZone.current.secondsFromGMT(for: recordedAt))
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)

        try await archive.hideTimelineDateTable()
        await model.load(today)
        XCTAssertFalse(model.hasLoadedDateRange)
        XCTAssertNil(model.earliestDay)
        XCTAssertNotNil(model.failures[today])
        XCTAssertTrue(model.snapshots.isEmpty)
        try await archive.restoreTimelineDateTable()
        await model.load(today)
        XCTAssertTrue(model.hasLoadedDateRange)
        XCTAssertEqual(model.earliestDay, first)
        XCTAssertNil(model.failures[today])

        try await archive.hideTimelineDateTable()
        await model.load(first)
        XCTAssertNotNil(model.failures[first])
        XCTAssertTrue(model.hasLoadedDateRange, "A refresh failure must preserve previously admitted bounds.")
        XCTAssertEqual(model.earliestDay, first)
        try await archive.restoreTimelineDateTable()
        await model.load(first)
        XCTAssertNil(model.failures[first])
        XCTAssertEqual(model.snapshots[first]?.count, 1, "Recover the actual retained recording after the query fault is removed.")
    }

    func testConfirmedEmptyRangeBecomesNavigableWhenHistoryArrives() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let today = TimelineDay(Date()), yesterday = today.adding(days: -1)
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        await model.load(today)
        XCTAssertTrue(model.hasLoadedDateRange)
        XCTAssertNil(model.earliestDay)
        let empty = TimelineDateRange(earliestDay: model.earliestDay, hasLoaded: model.hasLoadedDateRange, today: today)
        XCTAssertEqual(empty, .empty)
        XCTAssertTrue(empty.canRequest(today, today: today))
        XCTAssertFalse(empty.canRequest(yesterday, today: today))

        let recordedAt = yesterday.date().addingTimeInterval(12 * 3_600)
        try await receive(archive, root: root, at: recordedAt, offset: TimeZone.current.secondsFromGMT(for: recordedAt))
        await model.load(today)
        XCTAssertEqual(model.earliestDay, yesterday)
        XCTAssertTrue(TimelineDateRange(earliestDay: model.earliestDay, hasLoaded: model.hasLoadedDateRange, today: today)
            .canRequest(yesterday, today: today))
    }

    func testFallBackClockLabelsUseRecordedOffsetsWithoutChangingArchiveIdentity() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let formatter = ISO8601DateFormatter()
        let first = try XCTUnwrap(formatter.date(from: "2026-11-01T05:30:00Z"))
        let repeated = try XCTUnwrap(formatter.date(from: "2026-11-01T06:30:00Z"))
        let later = try XCTUnwrap(formatter.date(from: "2026-11-01T07:30:00Z"))
        try await receive(archive, root: root, at: first, offset: -14_400)
        try await receive(archive, root: root, at: repeated, offset: -18_000)
        try await receive(archive, root: root, at: later, offset: -18_000)
        let day = TimelineDay(first, calendar: TimelineDay.calendar)
        let windows = try await archive.timelineDay(day)
        XCTAssertEqual(windows.count, 3)
        let firstID = TimelineWindowID(start: first, timezoneOffset: -14_400)
        let secondID = TimelineWindowID(start: repeated, timezoneOffset: -18_000)
        let laterID = TimelineWindowID(start: later, timezoneOffset: -18_000)
        XCTAssertEqual(Set(windows.map(\.id)), [firstID, secondID, laterID])
        XCTAssertNotEqual(firstID.key, secondID.key)
        XCTAssertEqual(TimelineDate.repeatedClockRanges(in: windows), [firstID, secondID])
        XCTAssertEqual(TimelineDate.time(first, offset: firstID.timezoneOffset), "01:30")
        XCTAssertEqual(TimelineDate.time(repeated, offset: secondID.timezoneOffset), "01:30")
        XCTAssertEqual(TimelineDate.range(firstID, end: first.addingTimeInterval(0.1)), "01:30 · UTC−04:00")
        XCTAssertEqual(TimelineDate.range(secondID, end: repeated.addingTimeInterval(0.1)), "01:30 · UTC−05:00")
        XCTAssertEqual(TimelineDate.range(laterID, end: later.addingTimeInterval(0.1), includeUTCOffset: false), "02:30")
        let reread = try await archive.timelineDay(day)
        XCTAssertEqual(reread.map(\.id), windows.map(\.id))
        XCTAssertEqual(reread.map(\.sources), windows.map(\.sources))
        let quarterHourOffset = TimelineWindowID(start: Date(timeIntervalSince1970: 0), timezoneOffset: 20_700)
        XCTAssertEqual(TimelineDate.range(quarterHourOffset, end: quarterHourOffset.start), "05:45 · UTC+05:45")
    }

    func testYesterdayShowsReceivedAudioProgressFromTheSameArchiveSnapshot() async throws {
        try await checkReceivedAudioProgress(dayOffset: -1)
    }

    func testTodayShowsRemainingAudioAsTheQueueGrowsAndHidesWhenCaughtUp() async throws {
        try await checkReceivedAudioProgress(dayOffset: 0)
    }

    func testDayPagerNeverStaysSplitBetweenDaysAcrossProgressBannerAndManyDays() async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let today = TimelineDay(Date())
        let yesterday = today.adding(days: -1)
        let earliest = today.adding(days: -25)
        let fingerprint = ContentHash.sha256(Data("day-pager-alignment".utf8))

        for day in [earliest, yesterday] {
            let at = day.date().addingTimeInterval(15 * 3_600)
            let offset = TimeZone.current.secondsFromGMT(for: at)
            try await receive(archive, root: root, at: at, offset: offset, frames: 960_000)
        }
        let todayAt = today.date().addingTimeInterval(15 * 3_600)
        let todayOffset = TimeZone.current.secondsFromGMT(for: todayAt)
        try await receive(archive, root: root, at: todayAt, offset: todayOffset, frames: 960_000)
        while let job = try await archive.claimAnalysisJob(configurationHash: fingerprint) {
            _ = try await archive.commitTranscript(ticket: job, spans: [TranscriptSpan(chunkID: job.chunkID,
                frames: job.manifest.frames, text: "已整理完的历史转录片段。")])
        }
        // Leave an unprocessed recording on today only, so today renders the pending banner while yesterday does not.
        try await receive(archive, root: root, at: todayAt.addingTimeInterval(3_600), offset: todayOffset, frames: 960_000)

        let model = LibraryModel(archive: archive, configurationFingerprint: fingerprint)
        let player = AudioPlaybackController(archive: archive)
        addTeardownBlock { await player.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            LibraryView(model: model, playback: player, transcription: nil, speechFailure: nil, batches: [],
                delete: { _ in }, refresh: { await model.refresh() }, canDiscuss: false, discuss: { _ in },
                continueInBackground: {})
        }.environment(\.colorScheme, .light))
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()

        func horizontalPager(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView,
               !scroll.alwaysBounceVertical,
               scroll.bounds.width > 300,
               scroll.contentSize.width > scroll.bounds.width * 1.5 {
                return scroll
            }
            return view.subviews.lazy.compactMap { horizontalPager(in: $0) }.first
        }
        func visibleDayPanes(in view: UIView) -> [CGRect] {
            var result: [CGRect] = []
            if let scroll = view as? UIScrollView, scroll.alwaysBounceVertical, scroll.bounds.height > 150 {
                let frame = scroll.convert(scroll.bounds, to: window)
                if frame.intersection(window.bounds).width > 1 {
                    result.append(frame)
                }
            } else {
                for child in view.subviews { result.append(contentsOf: visibleDayPanes(in: child)) }
            }
            return result
        }
        func waitForSingleAlignedPane(stage: String) async throws -> UIScrollView {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                let panes = visibleDayPanes(in: window)
                if let pager = horizontalPager(in: window),
                   model.timeline.days.count == 26,
                   panes.count == 1,
                   abs(panes[0].minX - 24) <= 1,
                   abs(panes[0].maxX - (window.bounds.width - 24)) <= 1 {
                    return pager
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            let panes = visibleDayPanes(in: window)
            XCTFail("Day pager did not settle on a single aligned page (\(stage)): panes=\(panes), selected=\(model.timeline.selectedDay)")
            throw CancellationError()
        }

        let pager = try await waitForSingleAlignedPane(stage: "initial-26-day-entry")
        XCTAssertEqual(model.timeline.selectedDay, today)
        try await assertProgressText(in: window, contains: "待处理1分钟录音", excludes: ["%"], name: "pager-initial-today")

        // Simulate a swipe interrupted mid-page (45% yesterday / 55% today, matching the 181pt split).
        let todayAlignedX = pager.contentOffset.x
        pager.setContentOffset(CGPoint(x: max(0, todayAlignedX - 181), y: 0), animated: false)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(visibleDayPanes(in: window).count, 1, "Precondition: viewport is split across two days.")

        _ = try await waitForSingleAlignedPane(stage: "recover-from-mid-page-split")
        XCTAssertEqual(model.timeline.selectedDay, today)
    }

    private func checkReceivedAudioProgress(dayOffset: Int) async throws {
        let root = temporaryRoot()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let day = TimelineDay(Date()).adding(days: dayOffset)
        let at = day.date().addingTimeInterval(12 * 3_600)
        let offset = TimeZone.current.secondsFromGMT(for: at)
        try await receive(archive, root: root, at: at, offset: offset, frames: 960_000)
        try await receive(archive, root: root, at: at.addingTimeInterval(120), offset: offset, frames: 960_000)
        let fingerprint = ContentHash.sha256(Data("day-progress-ui".utf8))
        let claimed = try await archive.claimAnalysisJob(configurationHash: fingerprint)
        let job = try XCTUnwrap(claimed)
        _ = try await archive.commitTranscript(ticket: job, spans: [TranscriptSpan(chunkID: job.chunkID,
            frames: job.manifest.frames, text: "这是用于验证昨日整理进度的独立测试录音。")])
        let model = LibraryModel(archive: archive, configurationFingerprint: fingerprint)
        await model.refresh()
        model.timeline.select(day)
        await model.timeline.load(day)
        XCTAssertEqual(model.timeline.processingProgress[day]?.received, 120)
        XCTAssertEqual(model.timeline.processingProgress[day]?.processed, 60)
        let player = AudioPlaybackController(archive: archive)
        addTeardownBlock { await player.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            LibraryView(model: model, playback: player, transcription: nil, speechFailure: nil, batches: [],
                delete: { _ in }, refresh: { await model.refresh() }, canDiscuss: false, discuss: { _ in },
                continueInBackground: {})
        }.environment(\.colorScheme, .light))
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        if dayOffset == 0 {
            try await assertProgressText(in: window, contains: "待处理1分钟录音", excludes: ["%"],
                name: "today-processing-remaining")
            try await receive(archive, root: root, at: at.addingTimeInterval(240), offset: offset, frames: 960_000)
            await model.refresh()
            await model.timeline.load(day)
            try await assertProgressText(in: window, contains: "待处理2分钟录音", excludes: ["%"],
                name: "today-processing-new-arrival")
            while let job = try await archive.claimAnalysisJob(configurationHash: fingerprint) {
                _ = try await archive.commitTranscript(ticket: job, spans: [TranscriptSpan(chunkID: job.chunkID,
                    frames: job.manifest.frames, text: "新的录音已经整理完成。")])
            }
            await model.refresh()
            await model.timeline.load(day)
            XCTAssertEqual(model.timeline.processingProgress[day]?.remaining, 0)
            try await assertProgressText(in: window, contains: "今天", excludes: ["待处理", "%", "后台继续整理"],
                name: "today-processing-complete")
        } else {
            try await assertProgressText(in: window, contains: "50%", excludes: ["待处理"],
                name: "yesterday-processing-progress")
        }
    }

    private func assertProgressText(in window: UIWindow, contains expected: String, excludes: [String], name: String) async throws {
        var visible = false
        var text = ""
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
                .replacingOccurrences(of: " ", with: "")
            visible = text.contains(expected) && !excludes.contains(where: { text.contains($0) })
            if visible {
                if expected.hasPrefix("待处理") {
                    let line = try XCTUnwrap(request.results?.first {
                        $0.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "").contains(expected) == true
                    })
                    XCTAssertLessThan(line.boundingBox.minX, 0.12, "Today's status must align with the timeline's leading edge.")
                }
                let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
                add(attachment)
            }
        } while !visible && ContinuousClock.now < deadline
        XCTAssertTrue(visible, "Expected \(expected), excluding \(excludes); rendered: \(text)")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MoMoTimelineDates-\(UUID())")
    }

    private func receive(_ archive: ArchiveStore, root: URL, at date: Date, offset: Int, frames: Int = 1_600) async throws {
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input-\(UUID())"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "timeline-date-fixture", sourceKind: .fixture,
            targetFrames: frames, wallClockAnchor: date, timezoneOffset: offset)
        let chunk = try XCTUnwrap(writer.append([Int16](repeating: 0, count: frames)).first)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope))
    }
}

@MainActor @Observable private final class TimelineLayoutTabSelection {
    var value = 1
}

private struct TimelineLayoutTabs<Content: View>: View {
    @Bindable var selection: TimelineLayoutTabSelection
    @ViewBuilder let content: () -> Content
    var body: some View {
        TabView(selection: $selection.value) {
            Tab("聊天", systemImage: "bubble.left.and.bubble.right", value: 0) { Text("聊天") }
            Tab("转录", systemImage: "doc.text", value: 1) { content() }
        }
    }
}

private extension ArchiveStore {
    func holdTimelineDateRead(entered: XCTestExpectation, release: DispatchSemaphore) throws {
        entered.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.coderReadCorrupt) }
    }

    func hideTimelineDateTable() throws {
        try database.execute("ALTER TABLE epoch_closures RENAME TO timeline_date_test_epoch_closures")
    }

    func restoreTimelineDateTable() throws {
        try database.execute("ALTER TABLE timeline_date_test_epoch_closures RENAME TO epoch_closures")
    }
}
