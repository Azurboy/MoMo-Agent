import SwiftUI

struct EarphoneStatusPresentation {
    let title: String
    let subtitle: String
    let indicator: WatchStatusPresentation.Indicator
    let isRunning: Bool

    var indicatorColor: Color {
        switch indicator {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    @MainActor init(_ runtime: EarphoneCaptureRuntime) {
        let name = runtime.headsetName ?? String(localized: "蓝牙耳机")
        isRunning = runtime.isActive
        switch runtime.status {
        case .off:
            title = String(localized: "耳机录音已停止"); indicator = .yellow
            subtitle = String(localized: "点按开始录音")
        case .starting:
            title = String(localized: "正在开始耳机录音"); indicator = .yellow
            subtitle = name
        case .recording:
            title = String(localized: "耳机正在录音"); indicator = .green
            subtitle = String(localized: "\(name) · 已录 \(Self.duration(runtime.savedSeconds))")
        case .otherAudioPlaying:
            title = String(localized: "正在播放，暂停录音"); indicator = .yellow
            subtitle = String(localized: "声音停止后自动继续录音")
        case .headsetUnavailable:
            title = String(localized: "耳机未连接"); indicator = .yellow
            subtitle = String(localized: "在系统设置的蓝牙中连接耳机后自动开始")
        case .interrupted:
            title = String(localized: "耳机录音已中断"); indicator = .red
            subtitle = String(localized: "通话等占用麦克风，结束后自动恢复")
        case .failed(let message):
            title = String(localized: "耳机录音出错"); indicator = .red
            subtitle = message
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }
}

struct EarphoneStatusPopover: View {
    let runtime: EarphoneCaptureRuntime
    var accessibilityPrefix = "assistant"
    var openLibrary: (() -> Void)? = nil
    @State private var working = false

    var body: some View {
        let status = EarphoneStatusPresentation(runtime)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: CaptureDevice.earphone.symbol).font(.system(size: 20))
                Text(status.title).phoneText(.section)
                    .accessibilityIdentifier("\(accessibilityPrefix).earphoneStatus.title")
                Spacer(minLength: 0)
                Circle().fill(status.indicatorColor).frame(width: 8, height: 8)
                    .accessibilityLabel(status.indicator.title)
            }
            Text(status.subtitle).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("只保存耳机麦克风的声音；其他 App 播放声音时暂停保存。")
                .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = runtime.deliveryFailure {
                Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button {
                working = true
                Task {
                    if status.isRunning { await runtime.stop() } else { await runtime.start() }
                    working = false
                }
            } label: {
                Text(status.isRunning ? "停止录音" : "开始录音")
            }
            .buttonStyle(PhoneActionButtonStyle())
            .disabled(working)
            .accessibilityIdentifier("\(accessibilityPrefix).earphoneStatus.toggle")
            if let openLibrary {
                Button(action: openLibrary) {
                    HStack {
                        Text("查看录音")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }.phoneText(.metadata).frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(accessibilityPrefix).earphoneStatus.openLibrary")
            }
        }
        .padding(20).frame(width: 292, alignment: .leading)
        .foregroundStyle(MoMoPalette.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix).earphoneStatus.popover")
        .presentationBackground(MoMoPalette.paper)
    }
}
