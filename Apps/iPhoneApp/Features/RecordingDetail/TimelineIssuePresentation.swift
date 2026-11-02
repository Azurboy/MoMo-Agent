import Foundation
import MoMoArchive
import MoMoContracts

/// Presentation keeps the authoritative issue ID when a native failure narrows its range.
struct TimelineIssuePresentation: Identifiable {
    let issue: TimelineIssue
    let frames: FrameRange
    let failure: TimelineIssue.FailureReason?
    var id: String { "\(issue.id)/\(frames.start)/\(frames.end)" }
    var start: Date { issue.source.wallClockAnchor.addingTimeInterval(Double(frames.start) / issue.source.timebaseHz) }
    var end: Date { issue.source.wallClockAnchor.addingTimeInterval(Double(frames.end) / issue.source.timebaseHz) }
    var title: String {
        if failure != nil { return String(localized: "这一段未能整理") }
        switch issue.kind {
        case .waitingForSync: return String(localized: "等待同步")
        case .waitingForAnalysis: return String(localized: "等待分析语音")
        case .waitingForTranscription: return String(localized: "等待整理文字")
        case .transcriptionFailed: return String(localized: "这一段未能整理")
        case .audioUnavailable: return String(localized: "原音不可用")
        case .transcriptUnavailable: return String(localized: "文字暂不可读")
        }
    }
    var explanation: String {
        if let reason = failure ?? issue.failureReason {
            switch reason {
            case .speechProcessing: return String(localized: "本地语音处理未完成；已有文字和原音保留。")
            case .audioRead: return String(localized: "访问这部分本地音频或文件时未完成处理；已有文字保留。")
            case .archiveStorage: return String(localized: "这部分本地档案处理未完成；已有内容保留。")
            case .unspecified: return String(localized: "这部分处理未完成，未记录更具体的原因；已有内容保留。")
            }
        }
        switch issue.kind {
        case .waitingForSync: return String(localized: "手机尚未收到这个已知时间范围的原音，等待连接后继续同步。")
        case .waitingForAnalysis: return String(localized: "原音已收到，尚未完成语音分析；回到 App 后会自动继续。")
        case .waitingForTranscription: return String(localized: "已确认这部分有语音，文字尚未整理完成。")
        case .transcriptionFailed: return String(localized: "这部分处理未完成；已有文字和原音保留。")
        case .audioUnavailable: return String(localized: "这部分原音文件目前不可用，无法重新整理；已有文字仍可阅读。")
        case .transcriptUnavailable: return String(localized: "这段录音的本地导出文件与记录不一致，恢复或确认文件版本后即可继续显示文字。")
        }
    }
    var retryTitle: String { failure != nil || issue.kind == .transcriptionFailed ? String(localized: "重试这一段") : String(localized: "整理这一段") }

    static func rows(for window: TimelineWindow, failureScope: TranscriptionFailureScope?) -> [Self] {
        window.issues.flatMap { issue -> [Self] in
            let normal = Self(issue: issue, frames: issue.source.frames, failure: nil)
            guard let failureScope, failureScope.configurationFingerprint == window.configurationFingerprint,
                  failureScope.sessionID == issue.source.sessionID, failureScope.epochID == issue.source.epochID,
                  failureScope.generation == issue.source.generation,
                  (failureScope.stage == .analysis && issue.kind == .waitingForAnalysis)
                    || (failureScope.stage == .transcription && issue.kind == .waitingForTranscription) else { return [normal] }
            let range = issue.source.frames
            let start = max(range.start, failureScope.frames.start), end = min(range.end, failureScope.frames.end)
            guard end > start else { return [normal] }
            // Only non-empty intersections of already validated frame ranges can be constructed.
            return [(range.start, start, false), (start, end, true), (end, range.end, false)].compactMap { from, through, failed in
                guard through > from, let frames = try? FrameRange(start: from, count: through - from) else { return nil }
                return Self(issue: issue, frames: frames, failure: failed ? failureScope.reason : nil)
            }
        }
    }
}

enum TimelineDetailEntry: Identifiable {
    enum ID: Hashable { case paragraph(UUID), issue(String) }
    case paragraph(TranscriptReadingTurn)
    case issue(TimelineIssuePresentation)
    var id: ID {
        switch self {
        case .paragraph(let value): .paragraph(value.id)
        case .issue(let value): .issue(value.id)
        }
    }
    private var start: Date {
        switch self {
        case .paragraph(let value): value.recordedAt
        case .issue(let value): value.start
        }
    }
    static func ordered(window: TimelineWindow, issues: [TimelineIssuePresentation]) -> [Self] {
        (TranscriptReadingTurn.group(window.paragraphs, breaks: issues.map(\.start)).map(Self.paragraph) + issues.map(Self.issue))
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                // Keep readable text first at a shared timestamp; IDs are stable across refreshes.
                switch ($0, $1) {
                case (.paragraph(let left), .paragraph(let right)): return left.id.uuidString < right.id.uuidString
                case (.paragraph, .issue): return true
                case (.issue, .paragraph): return false
                case (.issue(let left), .issue(let right)): return left.id < right.id
                }
            }
    }
}
