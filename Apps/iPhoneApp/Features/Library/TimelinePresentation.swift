import SwiftUI
import MoMoArchive
import MoMoContracts

enum TimelineDateRange: Equatable {
    case unknown, empty
    case known(ClosedRange<TimelineDay>)

    init(earliestDay: TimelineDay?, hasLoaded: Bool, today: TimelineDay = TimelineDay(Date())) {
        if !hasLoaded { self = .unknown }
        else if let earliestDay { self = .known(min(earliestDay, today)...today) }
        else { self = .empty }
    }

    var isUnknown: Bool { if case .unknown = self { true } else { false } }

    func canRequest(_ day: TimelineDay, today: TimelineDay = TimelineDay(Date())) -> Bool {
        guard day <= today else { return false }
        switch self {
        case .unknown: return true // Wait for the real lower bound before admitting navigation.
        case .empty: return day == today
        case .known(let bounds): return bounds.contains(day)
        }
    }
}

@MainActor
enum TimelineDate {
    private struct Clock: Hashable { let offset: Int; let seconds: Bool }
    private static var clocks: [Clock: DateFormatter] = [:]
    static func day(_ day: TimelineDay) -> String {
        let today = TimelineDay(Date())
        let prefix = day == today ? String(localized: "今天 · ") : day == today.adding(days: -1) ? String(localized: "昨天 · ") : ""
        let date = day.date()
        let style = Date.FormatStyle.dateTime.locale(AppLanguage.current.locale).month().day()
        let formatted = day.year == today.year ? date.formatted(style) : date.formatted(style.year())
        return prefix + formatted
    }
    static func time(_ date: Date, offset: Int, seconds: Bool = false) -> String {
        let key = Clock(offset: offset, seconds: seconds)
        let formatter: DateFormatter
        if let cached = clocks[key] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = AppLanguage.current.locale
            formatter.timeZone = TimeZone(secondsFromGMT: offset)
            formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
            if clocks.count >= 32 { clocks.removeAll(keepingCapacity: true) }
            clocks[key] = formatter
        }
        return formatter.string(from: date)
    }
    static func range(_ id: TimelineWindowID, end: Date, includeUTCOffset: Bool = true) -> String {
        let first = time(id.start, offset: id.timezoneOffset)
        let last = time(end, offset: id.timezoneOffset)
        let clock = first == last ? first : "\(first)–\(last)"
        return includeUTCOffset ? "\(clock) · \(utcOffset(id.timezoneOffset))" : clock
    }
    nonisolated static func repeatedClockRanges(in windows: [TimelineWindow]) -> Set<TimelineWindowID> {
        // The archive stores capture offsets, not zone identifiers. Compare recorded wall
        // minutes instead of guessing a historical zone from the phone's current settings.
        guard Set(windows.map(\.id.timezoneOffset)).count > 1 else { return [] }
        let local = windows.map { window in
            (id: window.id,
             first: floor((window.id.start.timeIntervalSince1970 + Double(window.id.timezoneOffset)) / 60),
             last: floor((window.end.timeIntervalSince1970 + Double(window.id.timezoneOffset)) / 60))
        }.sorted { $0.first < $1.first }
        var repeated: Set<TimelineWindowID> = []
        // Forward: an earlier interval reaches this start. Backward: a later start
        // lies within this interval. Two maxima suffice to exclude the current offset.
        for backward in [false, true] {
            var maxima: [(offset: Int, value: Double)] = []
            for index in local.indices {
                let value = local[backward ? local.count - 1 - index : index]
                let threshold = backward ? -value.last : value.first
                if let other = maxima.first(where: { $0.offset != value.id.timezoneOffset }), other.value >= threshold {
                    repeated.insert(value.id)
                }
                let candidate = backward ? -value.first : value.last
                if let existing = maxima.firstIndex(where: { $0.offset == value.id.timezoneOffset }) {
                    maxima[existing].value = max(maxima[existing].value, candidate)
                } else {
                    maxima.append((value.id.timezoneOffset, candidate))
                }
                maxima.sort { $0.value > $1.value }
                if maxima.count > 2 { maxima.removeLast() }
            }
        }
        return repeated
    }
    private static func utcOffset(_ offset: Int) -> String {
        let magnitude = abs(offset)
        let result = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", magnitude / 3_600, magnitude % 3_600 / 60)
        return magnitude % 60 == 0 ? result : result + String(format: ":%02d", magnitude % 60)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(localized: "\(max(1, Int(seconds.rounded()))) 秒") }
        if seconds < 3_600 { return String(localized: "\(Int((seconds / 60).rounded())) 分钟") }
        return String(localized: "\(Int((seconds / 3_600).rounded())) 小时")
    }
}

@MainActor
enum TimelinePresentation {
    static func activity(_ intervals: [DateInterval], from start: Date, to end: Date, count: Int) -> [Double] {
        let duration = end.timeIntervalSince(start)
        guard count > 0, duration.isFinite, duration > 0 else { return [] }
        let step = duration / Double(count)
        var edges = [Double](repeating: 0, count: count)
        var fullBins = [Double](repeating: 0, count: count + 1)
        for interval in intervals {
            let lower = max(0, min(duration, interval.start.timeIntervalSince(start))) / step
            let upper = max(0, min(duration, interval.end.timeIntervalSince(start))) / step
            guard upper > lower else { continue }
            let first = min(count - 1, Int(lower)), last = min(count - 1, Int(upper))
            if first == last { edges[first] += upper - lower }
            else {
                edges[first] += Double(first + 1) - lower
                edges[last] += upper - Double(last)
                fullBins[first + 1] += 1
                fullBins[last] -= 1
            }
        }
        var full = 0.0
        return edges.indices.map { index in
            full += fullBins[index]
            return min(1, max(0, edges[index] + full))
        }
    }

    static func resourceExplanation(_ snapshot: TranscriptionSnapshot?) -> String? {
        guard snapshot?.nativeInFlight != true else { return nil }
        switch snapshot?.historicalResourceConstraint {
        case .thermalPressure: return String(localized: "手机温度过高，历史录音将在降温后自动继续整理")
        case .lowPower: return String(localized: "低电量模式已开启，历史录音将在关闭后自动继续整理")
        case nil: return nil
        }
    }

    static func preview(_ window: TimelineWindow, summary: String?) -> String {
        if window.canSummarize, let summary {
            let preview = MarkdownDocument.plainTextPreview(summary)
            if !preview.isEmpty { return preview }
        }
        var text = ""
        for paragraph in window.paragraphs where paragraph.hasReadableText {
            if !text.isEmpty { text += "  " }
            text += paragraph.text.prefix(max(0, 256 - text.count))
            if text.count >= 256 { break }
        }
        if !text.isEmpty { return String(text.prefix(256)).replacingOccurrences(of: "\n", with: " ") }
        switch window.state {
        case .waitingForTranscription: return String(localized: "正在整理，完成后生成总结。")
        case .waitingForSync: return String(localized: "等待原音传到手机后自动整理。")
        case .failed: return String(localized: "暂未生成文字，原音仍保留。")
        case .complete:
            return window.speechDuration > 0 ? String(localized: "这段有语音，可回听原音。") : String(localized: "未识别到语音")
        }
    }

    private enum PreparationStatus {
        case partialFailure, failed, waitingForSync, processing, deferred, pending
        var title: String {
            switch self {
            case .partialFailure: String(localized: "部分未完成")
            case .failed: String(localized: "未能整理")
            case .waitingForSync: String(localized: "等待同步")
            case .processing: String(localized: "正在整理")
            case .deferred: String(localized: "稍后继续")
            case .pending: String(localized: "等待整理")
            }
        }
    }
    static func status(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> String? {
        statusKind(window, transcription: transcription, speechFailure: speechFailure)?.title
    }
    static func hasRetryableFailure(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> Bool {
        switch statusKind(window, transcription: transcription, speechFailure: speechFailure) {
        case .partialFailure, .failed: true
        default: false
        }
    }
    private static func statusKind(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> PreparationStatus? {
        switch window.state {
        case .failed: return window.paragraphs.contains(where: \.hasReadableText) ? .partialFailure : .failed
        case .waitingForSync: return .waitingForSync
        case .complete: return nil
        case .waitingForTranscription:
            // A pending window can span several recordings. Durable completion/sync/failure
            // above takes precedence; only matching, in-flight native work is active.
            let sources = window.sources.map {
                RecordingTranscriptionPresentation(sessionID: $0.sessionID, state: .pending, snapshot: transcription)
            }
            if sources.contains(where: { $0.activity == .failed }) { return .partialFailure }
            if sources.contains(where: \.isActive) { return .processing }
            if sources.contains(where: { $0.activity == .deferred }) { return .deferred }
            return speechFailure == nil ? .pending : .failed
        }
    }
    static func explanation(_ window: TimelineWindow, transcription: TranscriptionSnapshot?, speechFailure: String?) -> String? {
        switch statusKind(window, transcription: transcription, speechFailure: speechFailure) {
        case .waitingForSync: String(localized: "还有原音尚未传到手机，已收到的文字和原音可以先查看。")
        case .processing: String(localized: "正在整理，后续文字会自动补上。")
        case .pending: String(localized: "原音已收到，文字将自动整理。")
        case .deferred: String(localized: "回到 App 或系统允许后会继续整理，已有内容已保留。")
        case .partialFailure, .failed: String(localized: "部分文字未能生成，已有文字和原音会保留。")
        default: nil
        }
    }
}

struct TimelineRow: View {
    let window: TimelineWindow
    let summary: String?
    let status: String?
    let connected: Bool
    var includeUTCOffset = false
    var body: some View {
        ClientTranscriptRow(time: TimelineDate.range(window.id, end: window.end, includeUTCOffset: includeUTCOffset),
            preview: TimelinePresentation.preview(window, summary: summary), status: status,
            connected: connected, isFinal: window.isFinal, bottomSpacing: window.marks.isEmpty ? 26 : 2) {
            if window.speechDuration > 0, window.state == .complete {
                TimelineActivityStrip(window: window).frame(height: 8).accessibilityHidden(true)
                Text("说话约 \(TimelineDate.duration(window.speechDuration))")
                    .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                    .accessibilityIdentifier("timeline.speechDuration")
            }
        }
    }
}

private struct TimelineActivityStrip: View {
    let window: TimelineWindow
    var body: some View {
        let bins = TimelinePresentation.activity(window.speechIntervals, from: window.id.start, to: window.end, count: 36)
        return Canvas { context, size in
            for (index, activity) in bins.enumerated() {
                let diameter = 2 + 4 * activity
                let center = (Double(index) + 0.5) * size.width / Double(bins.count)
                context.fill(Path(ellipseIn: CGRect(x: center - diameter / 2, y: (size.height - diameter) / 2,
                    width: diameter, height: diameter)), with: .color(MoMoPalette.ink.opacity(0.12 + 0.7 * activity)))
            }
        }
    }
}

enum RecordingDatePresentation {
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return String(localized: "昨天") }
        return date.formatted(.dateTime.locale(AppLanguage.current.locale).year().month().day())
    }

    static func title(_ date: Date) -> String {
        "\(day(date)) \(date.formatted(.dateTime.hour().minute()))"
    }
}
