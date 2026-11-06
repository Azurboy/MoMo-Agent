import SwiftUI
import MoMoArchive
import MoMoContracts

struct WatchStatusPresentation {
    enum Indicator: String {
        case green = "绿色", yellow = "黄色", red = "红色"
        var title: String {
            switch self {
            case .green: String(localized: "绿色")
            case .yellow: String(localized: "黄色")
            case .red: String(localized: "红色")
            }
        }
    }
    let title: String
    let compactTitle: String
    let subtitle: String
    let isRecording: Bool
    let needsAttention: Bool
    let indicator: Indicator

    var indicatorColor: Color {
        switch indicator {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    init(observation: WatchStatusObservation?, now: Date) {
        guard let observation, case .watch(let status) = observation.snapshot.payload else {
            title = String(localized: "等待手表状态")
            compactTitle = title
            subtitle = String(localized: "在 Apple Watch 上打开 MoMo Agent")
            isRecording = false
            needsAttention = false
            indicator = .yellow
            return
        }
        let sampledAge = now.timeIntervalSince(observation.snapshot.sampledAt)
        let receivedAge = observation.observedAt.map { now.timeIntervalSince($0) }
        // Opening a status surface requests a fresh report; passive cached reports remain historical evidence.
        let fresh = !observation.restored && (-5...30).contains(sampledAge)
            && receivedAge.map { (-5...30).contains($0) } == true
        let hasRecentSamples = status.lastSampleAge.map { $0 + max(0, sampledAge) <= 10 } == true
        isRecording = fresh && status.activity == .recording && hasRecentSamples
        if !fresh { indicator = .yellow }
        else if status.activity == .interrupted || status.activity == .failed { indicator = .red }
        else { indicator = isRecording ? .green : .yellow }
        needsAttention = !fresh || status.activity == .interrupted || status.activity == .failed
            || (status.activity == .recording && !hasRecentSamples)
        if !fresh {
            title = switch status.activity {
            case .recording: String(localized: "上次报告：手表正在录音")
            case .paused: String(localized: "上次报告：手表已静音")
            case .idle, .stopped: String(localized: "上次报告：手表未在录音")
            case .preparing: String(localized: "上次报告：手表正在准备录音")
            case .interrupted: String(localized: "上次报告：手表录音已中断")
            case .failed: String(localized: "上次报告：手表录音已停止")
            }
            subtitle = String(localized: "状态待更新 · 上次更新 \(observation.snapshot.sampledAt.formatted(.dateTime.hour().minute()))，当前录音请以手表为准")
        } else {
            title = switch status.activity {
            case .idle, .stopped: String(localized: "手表未在录音")
            case .preparing: String(localized: "手表正在准备录音")
            case .recording: hasRecentSamples ? String(localized: "手表正在录音") : String(localized: "等待手表声音采集")
            case .paused: String(localized: "手表已静音")
            case .interrupted: String(localized: "手表录音已中断")
            case .failed: String(localized: "手表录音已停止")
            }
            switch status.activity {
            case .interrupted, .failed:
                subtitle = String(localized: "请在 Apple Watch 上查看并恢复录音")
            case .recording where !hasRecentSamples:
                subtitle = String(localized: "暂未收到新的采样，请在手表上查看")
            default:
                subtitle = String(localized: "状态刚刚更新")
            }
        }
        compactTitle = fresh ? title : String(localized: "手表状态待更新")
    }
}

struct WatchStatusPopover: View {
    let observation: WatchStatusObservation?
    var accessibilityPrefix = "assistant"
    var openLibrary: (() -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { clock in
            let status = WatchStatusPresentation(observation: observation, now: clock.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "applewatch").font(.system(size: 20))
                    Text(status.title).phoneText(.section)
                        .accessibilityIdentifier("\(accessibilityPrefix).watchStatus.title")
                    Spacer(minLength: 0)
                    Circle().fill(status.indicatorColor).frame(width: 8, height: 8)
                        .accessibilityLabel(status.indicator.title)
                }
                Text(status.subtitle).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let observation, case .watch(let report) = observation.snapshot.payload {
                    Text(report.pendingChunkCount > 0
                         ? String(localized: "上次报告：\(report.pendingChunkCount) 段待接收确认 · \(report.pendingBytes.formatted(.byteCount(style: .file)))")
                         : String(localized: "上次报告：没有待接收确认的录音"))
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(accessibilityPrefix).watchStatus.sync")
                }
                if let openLibrary {
                    Divider()
                    Button(action: openLibrary) {
                        HStack {
                            Text("查看录音与同步")
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        }.phoneText(.metadata).frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(accessibilityPrefix).watchStatus.openLibrary")
                }
            }
            .padding(20).frame(width: 292, alignment: .leading)
            .foregroundStyle(MoMoPalette.ink)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(accessibilityPrefix).watchStatus.popover")
        }
        .presentationBackground(MoMoPalette.paper)
    }
}

extension View {
    func watchStatusRefresh(_ request: (() -> Void)?) -> some View {
        modifier(WatchStatusRefresh(request: request))
    }
}

private struct WatchStatusRefresh: ViewModifier {
    let request: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            guard scenePhase == .active, let request else { return }
            while !Task.isCancelled {
                request()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }
}
