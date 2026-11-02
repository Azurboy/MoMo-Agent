import SwiftUI

/// Shared geometry from the existing settings rows, without changing the phone palette.
struct PhoneSettingsSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct PhoneSettingsLinkRow: View {
    let title: String
    var symbol: String?
    var value: String?
    var disclosure = true

    var body: some View {
        HStack(spacing: 12) {
            if let symbol { Image(systemName: symbol).frame(width: 22).accessibilityHidden(true) }
            Text(LocalizedStringKey(title)).phoneText(.body)
            Spacer(minLength: 12)
            if let value { Text(LocalizedStringKey(value)).phoneText(.metadata).foregroundStyle(MoMoPalette.muted).multilineTextAlignment(.trailing) }
            if disclosure {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted).accessibilityHidden(true)
            }
        }
        .foregroundStyle(MoMoPalette.ink)
        .padding(.horizontal, 18).frame(minHeight: 58).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PhoneSettingsValueRow: View {
    let title: String
    let value: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(title)).phoneText(.body)
            Spacer(minLength: 0)
            value.phoneText(.metadata).foregroundStyle(MoMoPalette.muted).multilineTextAlignment(.trailing)
        }.frame(minHeight: 44).accessibilityElement(children: .combine)
    }
}

struct PhoneSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).phoneText(.metadata).foregroundStyle(MoMoPalette.muted).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct PhoneActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.phoneText(.body)
            .foregroundStyle(MoMoPalette.ink)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}
