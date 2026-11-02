import SwiftUI
import MoMoAgentClient

struct ChatAttachmentStrip: View {
    let attachments: [AgentAttachment]
    let remove: (UUID) -> Void
    var preview: (AgentAttachment) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(attachments) { item in
                    ZStack(alignment: .topTrailing) {
                        Button { preview(item) } label: {
                            Group {
                                if let bytes = item.preview, let image = UIImage(data: bytes) {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .frame(width: 120, height: 120).accessibilityHidden(true)
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).font(.system(size: 13)).lineLimit(3)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(item.displaySize).font(.system(size: 11)).foregroundStyle(MoMoPalette.muted)
                                        Spacer(minLength: 0)
                                        Text(item.displayFormat).font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(MoMoPalette.muted).padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(MoMoPalette.canvas, in: RoundedRectangle(cornerRadius: 5))
                                    }.padding(12).frame(width: 120, height: 120)
                                }
                            }
                            .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MoMoPalette.muted.opacity(0.2), lineWidth: 0.5) }
                        }
                        .buttonStyle(.plain).accessibilityLabel("预览\(item.name)")
                        Button { remove(item.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .background(MoMoPalette.canvas, in: Circle())
                                .overlay { Circle().strokeBorder(MoMoPalette.muted.opacity(0.25), lineWidth: 0.5) }
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).offset(x: 20, y: -20)
                        .accessibilityLabel("移除\(item.name)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("assistant.attachment.\(item.id)")
                }
            }.padding(.horizontal, 12).padding(.vertical, 12)
        }.scrollIndicators(.hidden).frame(height: 144)
    }
}

struct ChatAttachmentPreview: View {
    let attachment: AgentAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = attachment.data, let image = UIImage(data: data) {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } else if let text = attachment.text {
                    ScrollView {
                        Text(text).phoneText(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }
            }
            .background(MoMoPalette.canvas)
            .phoneSoftTopEdge()
            .navigationTitle(attachment.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
