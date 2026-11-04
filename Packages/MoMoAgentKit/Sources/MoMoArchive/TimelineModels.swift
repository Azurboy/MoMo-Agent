import Foundation
import MoMoContracts

/// A calendar date, independent of the phone's current UTC offset.
public struct TimelineDay: Codable, Hashable, Comparable, Sendable, Identifiable {
    public static let defaultStartHour = DayStartBoundary.defaultHour
    public static let startHourRange = DayStartBoundary.hourRange
    public static let startHourDefaultsKey = DayStartBoundary.defaultsKey
    public static var currentStartHour: Int { DayStartBoundary.currentHour }
    public static func setCurrentStartHour(_ hour: Int, defaults: UserDefaults? = .standard) {
        DayStartBoundary.setCurrentHour(hour, defaults: defaults)
    }

    public let year: Int
    public let month: Int
    public let day: Int
    public var id: String { "\(year)-\(month)-\(day)" }

    public init(_ date: Date, calendar: Calendar = .current, startHour: Int = TimelineDay.currentStartHour) {
        let anchor = DayStartBoundary.logicalDayStart(for: date, calendar: calendar, startHour: startHour)
        let parts = calendar.dateComponents([.year, .month, .day], from: anchor)
        year = parts.year!; month = parts.month!; day = parts.day!
    }

    /// Literal calendar date without applying `startHour` (e.g. from a graphical calendar picker).
    public init(calendarDate: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: calendarDate)
        year = parts.year!; month = parts.month!; day = parts.day!
    }

    /// Calendar midnight (`00:00`) for display formatting and calendar controls.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Start instant of this recording day (`08:00` by default).
    public func startDate(calendar: Calendar = .current, startHour: Int = TimelineDay.currentStartHour) -> Date {
        DayStartBoundary.boundaryStart(forCalendarDay: date(calendar: calendar), calendar: calendar, startHour: startHour)
    }

    public func adding(days: Int) -> Self {
        Self(calendarDate: Self.calendar.date(byAdding: .day, value: days, to: date(calendar: Self.calendar))!, calendar: Self.calendar)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.date(calendar: calendar) < rhs.date(calendar: calendar)
    }

    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
}

public struct TimelineWindowID: Codable, Hashable, Sendable, Identifiable {
    public let start: Date
    public let timezoneOffset: Int
    public var id: Self { self }
    public var day: TimelineDay {
        TimelineDay(start.addingTimeInterval(Double(timezoneOffset)), calendar: TimelineDay.calendar)
    }
    public var key: String { "\(Int64(start.timeIntervalSince1970))-\(timezoneOffset)" }
    public init(start: Date, timezoneOffset: Int) { self.start = start; self.timezoneOffset = timezoneOffset }
}

public struct TimelineAudioSource: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let generation: Int64
    public let epochID: UUID
    public let frames: FrameRange
    public let timebaseHz: Double
    public let wallClockAnchor: Date
    public var recordedAt: Date { wallClockAnchor.addingTimeInterval(Double(frames.start) / timebaseHz) }
}

public struct TimelineParagraph: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { source.spanID }
    public let source: SourceReference
    public let text: String
    public let recordedAt: Date
    public let audioAvailable: Bool
    public var speaker: String? = nil
    public var attribution: SpeakerAttribution? = nil
    public var audioSource: TimelineAudioSource? = nil
    public var startsNewSpeakerTurn: Bool? = nil
    public var hasReadableText: Bool { TranscriptText.hasContent(text) }
}

/// A Watch mark keeps its sample-clock position, independent of transcript boundaries.
public struct TimelineMark: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let generation: Int64
    public let epochID: UUID
    public let sourceFrame: Int64
    public let recordedAt: Date
    public let audioAvailable: Bool
    public var nearbyParagraphID: UUID? = nil

    /// Playback concatenates these sources, excluding the gaps between them.
    /// An end-of-epoch mark has no sample to play and must not jump to another epoch.
    public func playbackPosition(in sources: [TimelineAudioSource]) -> TimeInterval? {
        var elapsed = 0.0
        for source in sources {
            if source.sessionID == sessionID, source.generation == generation, source.epochID == epochID,
               source.frames.start <= sourceFrame, sourceFrame < source.frames.end {
                return elapsed + Double(sourceFrame - source.frames.start) / source.timebaseHz
            }
            elapsed += Double(source.frames.count) / source.timebaseHz
        }
        return nil
    }
}

public enum TimelineProcessingState: String, Codable, Sendable {
    case complete, waitingForSync, waitingForTranscription, failed
}

/// A known interval, never an inferred end for audio that has not arrived.
public struct TimelineIssue: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case waitingForSync, waitingForAnalysis, waitingForTranscription, transcriptionFailed, audioUnavailable, transcriptUnavailable
    }
    public enum FailureReason: String, Codable, Sendable {
        case speechProcessing, audioRead, archiveStorage, unspecified

        public init(code: String?) {
            switch code {
            case "speech_processing_failed", "invalid-model": self = .speechProcessing
            case "legacy_decode_failed", "local_file_operation_failed", "audio_read_failed", "audio_invalid", "audio_unavailable": self = .audioRead
            case "archive_operation_failed": self = .archiveStorage
            default: self = .unspecified
            }
        }
    }
    public let kind: Kind
    public let source: TimelineAudioSource
    public let failureReason: FailureReason?
    public var id: String {
        let value = "\(kind.rawValue)/\(source.sessionID)/\(source.generation)/\(source.epochID)/\(source.frames.start)/\(source.frames.end)"
        return ContentHash.sha256(Data(value.utf8))
    }
    public var start: Date { source.recordedAt }
    public var end: Date { source.wallClockAnchor.addingTimeInterval(Double(source.frames.end) / source.timebaseHz) }
    public var canRetry: Bool {
        kind == .waitingForAnalysis || kind == .waitingForTranscription || kind == .transcriptionFailed
    }
}

/// The last failed native attempt in the current runtime, not a durable failure after restart.
public struct TranscriptionFailureScope: Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case analysis, transcription }
    public let sessionID: UUID
    public let epochID: UUID
    public let generation: Int64
    public let configurationFingerprint: String
    public let frames: FrameRange
    public let stage: Stage
    public let reason: TimelineIssue.FailureReason

    public init(
        sessionID: UUID, epochID: UUID, generation: Int64,
        configurationFingerprint: String, frames: FrameRange,
        stage: Stage, reason: TimelineIssue.FailureReason
    ) {
        self.sessionID = sessionID
        self.epochID = epochID
        self.generation = generation
        self.configurationFingerprint = configurationFingerprint
        self.frames = frames
        self.stage = stage
        self.reason = reason
    }
}

public struct TimelineRetryRequest: Sendable {
    public let window: TimelineWindow
    public let issueID: String?
    /// An optional subrange of that issue, e.g. the exact current native attempt.
    public let frames: FrameRange?
    public init(window: TimelineWindow, issueID: String? = nil, frames: FrameRange? = nil) {
        self.window = window; self.issueID = issueID; self.frames = frames
    }
}

public struct TimelineDayProgress: Equatable, Sendable {
    public let received: TimeInterval
    public let processed: TimeInterval?
    public let unavailable: TimeInterval
    public let awaitingSync: TimeInterval
    public var remaining: TimeInterval? { processed.map { max(0, received - $0) } }
}

public struct TimelineDaySnapshot: Sendable {
    public let windows: [TimelineWindow]
    public let progress: TimelineDayProgress
}

public struct TimelineWindow: Codable, Equatable, Sendable, Identifiable {
    public static let inactivityGap: TimeInterval = 300
    public let id: TimelineWindowID
    public let end: Date
    public let sources: [TimelineAudioSource]
    public let paragraphs: [TimelineParagraph]
    public let state: TimelineProcessingState
    public let isFinal: Bool
    public let isMarked: Bool
    public let unavailableAudio: Bool
    public let revision: String
    public let configurationFingerprint: String?
    public let speechIntervals: [DateInterval]
    public var discardedTranscription = false
    public var issues: [TimelineIssue] = []
    public var hasUnknownTail = false
    public var marks: [TimelineMark] = []
    public var speechDuration: TimeInterval { speechIntervals.reduce(0) { $0 + $1.duration } }
    public func sharesSource(with previous: [TimelineAudioSource]) -> Bool {
        sources.contains { source in previous.contains {
            $0.sessionID == source.sessionID && $0.generation == source.generation && $0.epochID == source.epochID
                && $0.frames.start < source.frames.end && source.frames.start < $0.frames.end
        } }
    }
    public var text: String { paragraphs.filter(\.hasReadableText).map(\.text).joined(separator: "\n\n") }
    /// Summary input excludes playback, processing and unrelated transcript-version changes.
    public var summaryRevision: String {
        let inputs = paragraphs.filter(\.hasReadableText).map {
            "\($0.source.sessionID)/\($0.source.generation)/\($0.id)/\(ContentHash.sha256(Data($0.text.utf8)))"
        }
        return ContentHash.sha256(Data(([id.key] + inputs).joined(separator: "\n").utf8))
    }
    public var omitsPunctuationOnlyResult: Bool {
        isFinal && state == .complete && !isMarked && (discardedTranscription || !paragraphs.isEmpty)
            && !paragraphs.contains(where: \.hasReadableText)
    }
    public var effectiveCharacterCount: Int {
        text.filter { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }.count
    }
    /// Summarize readable content as it arrives; short passages remain their own preview.
    public var canSummarize: Bool {
        var characters = 0
        for paragraph in paragraphs where paragraph.hasReadableText {
            if isMarked { return true }
            for character in paragraph.text where character.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                characters += 1
                if characters >= 20 { return true }
            }
        }
        return false
    }
    public var references: [SourceReference] { paragraphs.filter(\.hasReadableText).map(\.source) }
}
