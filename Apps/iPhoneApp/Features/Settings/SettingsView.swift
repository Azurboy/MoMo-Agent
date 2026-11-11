import SwiftUI
import MoMoArchive
import MoMoContracts
import MoMoAgentClient

struct SettingsView: View {
    let archive: ArchiveStore
    let remoteAgent: PhoneRemoteAgent
    let modelDirectory: URL?
    let modelStatus: LocalSpeechModelStatus
    let speechSettings: PhoneSpeechSettings
    var illustrations: LifeIllustrationStore? = nil
    var earphone: EarphoneCaptureRuntime? = nil
    var speakerRematch: SpeakerRematchController = SpeakerRematchController()
    var onSpeakersChanged: (() async -> Void)? = nil
    @State private var versionTapCount = 0
    @State private var previewingWelcome = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("设置").phoneText(.title).accessibilityAddTraits(.isHeader)
                PhoneSettingsSection(title: "MoMo") {
                    PhoneSettingsSurface {
                        NavigationLink { PhoneMacConnectionView(agent: remoteAgent, showsDoneButton: false) } label: {
                            PhoneSettingsLinkRow(title: "Mac 连接", symbol: "desktopcomputer",
                                                 value: remoteAgent.connection == nil ? "尚未配对" : "已配对")
                        }.accessibilityIdentifier("settings.mac")
                        if let sync = remoteAgent.context {
                            rowDivider
                            NavigationLink { RemoteMemoryView(sync: sync, taskStore: remoteAgent.store) } label: {
                                PhoneSettingsLinkRow(title: "记忆", symbol: "brain")
                            }.accessibilityIdentifier("settings.memories")
                        }
                        if remoteAgent.connection != nil {
                            rowDivider
                            NavigationLink { PhoneNotificationSettings(notifications: remoteAgent.notifications) } label: {
                                PhoneSettingsLinkRow(title: "通知", symbol: "bell", value: remoteAgent.notifications.title)
                            }.accessibilityIdentifier("settings.notifications")
                        }
                    }
                }
                PhoneSettingsSection(title: "个人资料") {
                    PhoneSettingsSurface {
                        if let health = remoteAgent.health {
                            NavigationLink { PhoneHealthSettingsView(health: health) } label: {
                                PhoneSettingsLinkRow(title: "健康", symbol: "heart", value: health.enabled ? "已开启" : "未开启")
                            }.accessibilityIdentifier("settings.health")
                        }
                        if let sources = remoteAgent.sources {
                            ForEach(PhoneSourceKind.allCases, id: \.rawValue) { kind in
                                if remoteAgent.health != nil || kind != PhoneSourceKind.allCases.first { rowDivider }
                                NavigationLink { PhoneSourcesSettingsView(sources: sources, kind: kind) } label: {
                                    PhoneSettingsLinkRow(title: kind.title, symbol: kind.symbol,
                                                         value: sources.preference(kind).enabled ? "已开启" : "未开启")
                                }.accessibilityIdentifier("settings.\(kind.rawValue)")
                            }
                        }
                    }
                    if let failure = remoteAgent.sourcesFailure {
                        Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                    }
                }
                PhoneSettingsSection(title: "转录与储存") {
                    PhoneSettingsSurface {
                        if let illustrations {
                            NavigationLink { LifeIllustrationSettingsView(store: illustrations) } label: {
                                PhoneSettingsLinkRow(title: "生活插画", value: illustrations.settingsRowStatus)
                            }.accessibilityIdentifier("settings.lifeIllustrations")
                            rowDivider
                        }
                        if let earphone {
                            NavigationLink { CaptureDeviceSettingsView(runtime: earphone) } label: {
                                PhoneSettingsLinkRow(title: "录音设备", value: earphone.settings.device.title)
                            }.accessibilityIdentifier("settings.captureDevice")
                            rowDivider
                        }
                        NavigationLink { SpeechModelSettingsView(settings: speechSettings.models) } label: {
                            PhoneSettingsLinkRow(title: "转录模型", value: speechSettings.models.choice.title)
                        }.accessibilityIdentifier("settings.speech.model")
                        rowDivider
                        NavigationLink { SpeechLanguageSettingsView(settings: speechSettings) } label: {
                            PhoneSettingsLinkRow(title: "识别语言", value: speechSettings.language.title)
                        }.accessibilityIdentifier("settings.speech.language")
                        rowDivider
                        NavigationLink { SpeechDetectionSettingsView(settings: speechSettings) } label: {
                            PhoneSettingsLinkRow(title: "语音检测", value: speechSettings.vadThreshold.formatted(.number.precision(.fractionLength(2))))
                        }.accessibilityIdentifier("settings.speech.detection")
                        rowDivider
                        NavigationLink { SpeakerSegmentationSettingsView(settings: speechSettings) } label: {
                            PhoneSettingsLinkRow(title: "说话人分段", value: speechSettings.speakerSegmentationModel.title)
                        }.accessibilityIdentifier("settings.speech.segmentation")
                        rowDivider
                        NavigationLink {
                            SpeakerProfilesView(archive: archive, rematch: speakerRematch, onSpeakersChanged: onSpeakersChanged)
                        } label: {
                            PhoneSettingsLinkRow(title: "人物与声纹")
                        }.accessibilityIdentifier("settings.speakers")
                        rowDivider
                        NavigationLink { StorageUsageView(archive: archive, modelDirectory: modelDirectory, modelStatus: modelStatus) } label: {
                            PhoneSettingsLinkRow(title: "储存空间")
                        }.accessibilityIdentifier("settings.storage")
                    }
                }
                PhoneSettingsSection(title: "高级设置") {
                    PhoneSettingsSurface {
                        NavigationLink { DayStartSettingsView(settings: speechSettings) } label: {
                            PhoneSettingsLinkRow(title: "每天起点", symbol: "clock", value: speechSettings.dayStartHourLabel)
                        }.accessibilityIdentifier("settings.advanced.dayStartHour")
                    }
                }
                Button {
                    versionTapCount += 1
                    if versionTapCount == 7 { versionTapCount = 0; previewingWelcome = true }
                } label: {
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.accessibilityIdentifier("settings.version")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 24)
        }
        .phonePageSurface().navigationTitle("")
        .task { await illustrations?.refresh(minimumInterval: 3) }
        .onDisappear { versionTapCount = 0 }
        .fullScreenCover(isPresented: $previewingWelcome) {
            WelcomeExperienceView(finishTitle: "返回设置", finish: { previewingWelcome = false }, closePreview: { previewingWelcome = false })
        }
    }

    private var rowDivider: some View { Divider().padding(.leading, 18) }
}

extension AudioRetentionPolicy {
    var title: String {
        switch self {
        case .days(let days): String(localized: "\(days) 天")
        case .forever: String(localized: "永久")
        }
    }
}

private struct PhoneNotificationSettings: View {
    let notifications: PhoneNotifications
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PhoneSettingsSurface {
                    PhoneSettingsLinkRow(title: "通知状态", value: notifications.title, disclosure: false)
                    if notifications.status?.configured == true {
                        Divider().padding(.leading, 18)
                        HStack {
                            Text("接收通知").phoneText(.body)
                            Spacer(minLength: 16)
                            Toggle("接收通知", isOn: Binding(
                            get: { notifications.status?.enabled == true && notifications.allowed },
                            set: { enabled in Task { if enabled { await notifications.enable() } else { await notifications.disable() } } }))
                            .labelsHidden().tint(MoMoPalette.ink).disabled(notifications.busy)
                            .accessibilityIdentifier("settings.notifications.enabled")
                        }.padding(.horizontal, 18).frame(minHeight: 58)
                    }
                }
                if notifications.status?.configured == false {
                    Text("Mac 尚未配置推送服务").phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
                if notifications.busy { ProgressView().controlSize(.small) }
            }.padding(24)
        }.phonePageSurface().navigationTitle("通知").navigationBarTitleDisplayMode(.inline)
            .task { await notifications.refresh() }
    }
}

private struct DayStartSettingsView: View {
    let settings: PhoneSpeechSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("每天起点").phoneText(.body)
                        Spacer(minLength: 16)
                        Picker("每天起点", selection: Binding(
                            get: { settings.dayStartHour },
                            set: { settings.selectDayStartHour($0) }
                        )) {
                            ForEach(Array(PhoneSpeechSettings.dayStartHourRange), id: \.self) { hour in
                                Text(DayStartBoundary.label(for: hour)).monospacedDigit().tag(hour)
                            }
                        }
                        .labelsHidden()
                        .tint(MoMoPalette.ink)
                        .accessibilityIdentifier("settings.advanced.dayStartHour.picker")
                    }
                    Text("早于该时间的凌晨录音会归入前一天。默认 08:00。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    Button("恢复默认") {
                        settings.selectDayStartHour(PhoneSpeechSettings.defaultDayStartHour)
                    }
                    .buttonStyle(PhoneActionButtonStyle())
                    .disabled(settings.dayStartHour == PhoneSpeechSettings.defaultDayStartHour)
                    .accessibilityIdentifier("settings.advanced.dayStartHour.reset")
                }
                .padding(18).background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                Text("修改后立即重排时间线日期归属，已有录音和文字保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if let failure = settings.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                }
            }
            .padding(24)
        }
        .phonePageSurface()
        .navigationTitle("每天起点")
        .navigationBarTitleDisplayMode(.inline)
    }
}
