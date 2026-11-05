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
                modelCard(.xASR, subtitle: "神经网络引擎加速 · 中英混说更准、体积小") {
                    Text("离线识别普通话、英文及中英混说，带标点与英文大小写；Zipformer2 编码器原生运行于 Apple 神经网络引擎。不支持粤语、日语和韩语。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    download(.xASR, use: "使用 X-ASR")
                }
                modelCard(.funASRNano, subtitle: "神经网络引擎加速 · 0.6B 大模型推理") {
                    Text("离线识别中文及方言、英文、日文；完整 Encoder + Adaptor + Qwen3-0.6B 运行于 Apple 神经网络引擎。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    download(.funASRNano, use: "使用 FunASR Nano")
                }
                if settings.switching { ProgressView("正在切换模型…") }
                else if settings.checking { ProgressView("正在检查模型…") }
                else if settings.benchmarking { ProgressView("正在用本机真实录音实测神经网络引擎速度…") }
                if settings.canBenchmark {
                    benchmarkCard
                }
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

    private var busy: Bool {
        settings.downloading != nil || settings.switching || settings.checking || settings.benchmarking
    }

    private var benchmarkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本机推理测速").phoneText(.body)
                Spacer()
                if let result = settings.latestBenchmark, let model = result.model {
                    Text(model.title).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
            }
            if let result = settings.latestBenchmark {
                if result.inProgress == true, let total = result.totalTargetAudioSeconds, total > 0 {
                    ProgressView(value: min(result.audioSeconds, total), total: total)
                    Text("正在实测：\((result.audioSeconds / 60).formatted(.number.precision(.fractionLength(1)))) / \((total / 60).formatted(.number.precision(.fractionLength(1)))) 分钟 · 当前 \(result.realtimeFactor.formatted(.number.precision(.fractionLength(1))))x 实时（1 小时约 \(result.minutesPerHour.formatted(.number.precision(.fractionLength(1)))) 分钟）")
                        .phoneText(.metadata).monospacedDigit().foregroundStyle(MoMoPalette.ink)
                } else {
                    Text("实测 \((result.audioSeconds / 60).formatted(.number.precision(.fractionLength(1)))) 分钟真实录音耗时 \(result.elapsedSeconds.formatted(.number.precision(.fractionLength(1)))) 秒 · \(result.realtimeFactor.formatted(.number.precision(.fractionLength(1))))x 实时（折算 1 小时约 \(result.minutesPerHour.formatted(.number.precision(.fractionLength(2)))) 分钟），识别 \(result.recognizedCharacterCount) 字。")
                        .phoneText(.metadata).monospacedDigit().foregroundStyle(MoMoPalette.ink)
                }
                if let preview = settings.latestBenchmarkPreview, !preview.isEmpty {
                    Text("片段预览：\(preview)")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted).lineLimit(3)
                }
            } else {
                Text("读取本机真实录音（只读，不改动任何已有转录），实测当前启用模型在 Apple 神经网络引擎上的转写速度。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
            }
            HStack(spacing: 12) {
                Button(settings.benchmarking ? "正在实测…" : "实测 2 分钟片段") {
                    Task { await settings.runBenchmark() }
                }
                .buttonStyle(PhoneActionButtonStyle())
                .disabled(busy)
                .accessibilityIdentifier("settings.speech.model.benchmark")

                Button("实测 1 小时录音") {
                    Task { await settings.runOneHourBenchmark() }
                }
                .buttonStyle(PhoneActionButtonStyle())
                .disabled(busy)
                .accessibilityIdentifier("settings.speech.model.benchmark1h")
            }
        }
        .foregroundStyle(MoMoPalette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

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
        case .funASRNano: "FunASR Nano"
        case .xASR: "X-ASR"
        }
    }
}
