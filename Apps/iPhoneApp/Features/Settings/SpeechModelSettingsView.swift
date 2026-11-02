import SwiftUI
import MoMoSpeech

struct SpeechModelSettingsView: View {
    let settings: PhoneSpeechModelSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modelCard(.senseVoice, subtitle: "默认 · 神经网络引擎加速，约 2–3 分钟 / 1 小时录音") {
                    if settings.choice != .senseVoice {
                        Button("使用 SenseVoice") { settings.select(.senseVoice) }
                            .disabled(busy)
                    }
                }
                modelCard(.funASRNanoCoreML, subtitle: "神经网络引擎加速 · 方言与多语种抗噪") {
                    Text("离线识别中文及 7 大方言、英文、日文、韩语等 31 种语言，针对远场与高噪环境深度优化。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    download(.funASRNanoCoreML, use: "使用 FunASR (CoreML)")
                }
                modelCard(.xASR, subtitle: "中英混说更准、体积小") {
                    Text("离线识别普通话、英文及中英混说，带标点。不支持粤语、日语和韩语。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    download(.xASR, use: "使用 X-ASR")
                }
                modelCard(.funASRNano, subtitle: "实验性 · CPU 大模型推理") {
                    Text("离线识别中文及方言、英文、日文；运行 0.6B 语言模型，转写速度显著慢于 CoreML 版本且耗电更高。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    download(.funASRNano, use: "使用 FunASR Nano")
                }
                if settings.switching { ProgressView("正在切换模型…") }
                else if settings.checking { ProgressView("正在检查模型…") }
                if let failure = settings.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(.red)
                }
                Text("当前片段完成后切换，已有转录保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }
            .padding(24)
        }
        .phonePageSurface()
        .navigationTitle("转录模型")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.refresh() }
    }

    private var busy: Bool { settings.downloading != nil || settings.switching || settings.checking }

    @ViewBuilder
    private func download(_ model: SpeechModelChoice, use: LocalizedStringKey) -> some View {
        if let catalog = settings.catalogs[model] {
            Text("下载：\(ByteCountFormatter.string(fromByteCount: catalog.downloadBytes, countStyle: .file))")
                .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
        }
        if settings.downloading == model {
            if let progress = settings.progress[model] {
                ProgressView(value: Double(progress.receivedBytes), total: Double(progress.totalBytes))
                Text(progress.validating ? "正在校验模型…" : "正在下载…")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            } else { ProgressView("正在准备下载…") }
            if !settings.switching { Button("暂停下载") { settings.pause() } }
        } else if settings.installed.contains(model) {
            if settings.choice != model {
                Button(use) { settings.select(model) }.disabled(busy)
                Button("删除下载", role: .destructive) { settings.removeDownload(model) }.disabled(busy)
            }
        } else {
            Button(settings.progress[model] == nil ? "下载并启用" : "继续下载并启用") { settings.downloadAndSelect(model) }
                .disabled(busy || settings.catalogs[model] == nil)
        }
    }

    private func modelCard<Content: View>(_ model: SpeechModelChoice, subtitle: LocalizedStringKey,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.title).phoneText(.body)
                Spacer()
                if settings.choice == model {
                    Label("使用中", systemImage: "checkmark.circle.fill").phoneText(.metadata)
                }
            }
            Text(subtitle).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            content().buttonStyle(PhoneActionButtonStyle())
        }
        .foregroundStyle(MoMoPalette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("settings.speech.model.\(model.rawValue)")
    }
}

extension SpeechModelChoice {
    var title: String {
        switch self {
        case .senseVoice: "SenseVoice"
        case .funASRNanoCoreML: "FunASR (CoreML)"
        case .funASRNano: "FunASR Nano"
        case .xASR: "X-ASR"
        }
    }
}
