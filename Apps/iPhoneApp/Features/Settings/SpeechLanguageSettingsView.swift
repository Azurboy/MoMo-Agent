import SwiftUI
import MoMoSpeech

struct SpeechLanguageSettingsView: View {
    let settings: PhoneSpeechSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("多种语言交替时，选择自动识别。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                VStack(spacing: 0) {
                    ForEach(SpeechLanguage.allCases, id: \.self) { language in
                        Button {
                            settings.select(language)
                        } label: {
                            HStack {
                                Text(language.title).phoneText(.body)
                                Spacer(minLength: 12)
                                if settings.language == language {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(MoMoPalette.ink)
                            .padding(.horizontal, 18).frame(minHeight: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!settings.models.choice.supports(language))
                        .accessibilityAddTraits(settings.language == language ? .isSelected : [])
                        .accessibilityIdentifier("settings.speech.language.\(language.rawValue)")
                    }
                }
                .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                Text("用于新转录，已有文字保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if settings.models.choice == .funASRNano {
                    Text("FunASR 不支持韩语；需要识别韩语时，请使用 SenseVoice。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                } else if settings.models.choice == .xASR {
                    Text("X-ASR 只识别中文和英文；需要粤语、日语或韩语时，请使用 SenseVoice。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
                if let failure = settings.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .phonePageSurface()
        .navigationTitle("识别语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}
