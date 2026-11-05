import SwiftUI
import MoMoAgentClient
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension LifeIllustration {
    var caption: String {
        let zone = TimeZone(identifier: timezone) ?? .current
        var clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        clock.timeZone = zone
        let range = Date(timeIntervalSince1970: windowStart).formatted(clock)
            + "–" + Date(timeIntervalSince1970: windowEnd).formatted(clock)
        return place.flatMap { $0.isEmpty ? nil : range + " · " + $0 } ?? range
    }

    var dateCaption: String { logicalDay + " · " + caption }
}

struct LifeIllustrationImageView: View {
    let url: URL
    @State private var image: Image?

    var body: some View {
        Color.clear.aspectRatio(4 / 3, contentMode: .fit)
            .overlay { if let image { image.resizable().scaledToFit() } }
        .task(id: url) {
            image = nil
            let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled, let bytes else { return }
            #if os(iOS)
            image = UIImage(data: bytes).map { Image(uiImage: $0) }
            #else
            image = NSImage(data: bytes).map { Image(nsImage: $0) }
            #endif
        }
    }
}

struct LifeIllustrationInlineView: View {
    let illustration: LifeIllustration
    let url: URL
    let open: () -> Void
    let showSource: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                LifeIllustrationImageView(url: url)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(illustration.caption).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "生活插画") + "，" + illustration.dateCaption)
        .accessibilityIdentifier("lifeIllustration.inline.\(illustration.id)")
        .contextMenu {
            Button("查看依据", systemImage: "text.alignleft", action: showSource)
            Button("删除", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

struct LifeIllustrationSettingsControls: View {
    let store: LifeIllustrationStore
    @State private var saving = false
    @State private var failure: String?

    private var status: String {
        if store.settings.supported { return String(localized: "Codex 订阅可用") }
        if store.settings.provider == "anthropic" {
            return String(localized: "Claude 订阅暂不支持，切换为 Codex 订阅后可用。")
        }
        return String(localized: "登录 Codex 订阅后可用。")
    }

    var body: some View {
        Toggle("生活插画", isOn: Binding(get: { store.settings.enabled }, set: {
            save(enabled: $0, interval: store.settings.intervalHours)
        }))
        .disabled(!store.settings.supported || saving)
        .accessibilityIdentifier("lifeIllustration.settings.enabled")
        Picker("生成间隔", selection: Binding(get: { store.settings.intervalHours }, set: {
            save(enabled: store.settings.enabled, interval: $0)
        })) {
            ForEach([2, 3, 4, 6], id: \.self) { hours in Text("每 \(hours) 小时").tag(hours) }
        }
        .disabled(!store.settings.supported || saving)
        .accessibilityIdentifier("lifeIllustration.settings.interval")
        Text(status).font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("lifeIllustration.settings.subscription")
        if let failure = failure ?? store.error {
            Text(failure).font(.footnote).foregroundStyle(MoMoPalette.failure)
        }
    }

    private func save(enabled: Bool, interval: Int) {
        saving = true
        Task {
            defer { saving = false }
            do { try await store.updateSettings(enabled: enabled, intervalHours: interval); failure = nil }
            catch { failure = error.localizedDescription }
        }
    }
}

struct LifeIllustrationSettingsView: View {
    let store: LifeIllustrationStore
    var body: some View {
        Form { Section { LifeIllustrationSettingsControls(store: store) } }
            .navigationTitle("生活插画")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

#if os(iOS)
struct LifeIllustrationViewer: View {
    let store: LifeIllustrationStore
    let initialID: String
    let showSource: (LifeIllustration) -> Void
    @State private var selection: String
    @State private var zoomed = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(store: LifeIllustrationStore, initialID: String, showSource: @escaping (LifeIllustration) -> Void) {
        self.store = store
        self.initialID = initialID
        self.showSource = showSource
        _selection = State(initialValue: initialID)
    }

    private var selected: LifeIllustration? { store.items.first { $0.id == selection } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TabView(selection: $selection) {
                    ForEach(store.items) { item in
                        Group {
                            if let url = store.imageURL(for: item, thumbnail: false) {
                                LifeIllustrationZoomView(url: url, zoomed: Binding(
                                    get: { selection == item.id && zoomed },
                                    set: { if selection == item.id { zoomed = $0 } }))
                                    .id(item.id + (selection == item.id ? "-selected" : "-offscreen"))
                            }
                        }
                        .tag(item.id)
                        .contextMenu {
                            Button("查看依据", systemImage: "text.alignleft") { dismiss(); showSource(item) }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                Task {
                                    do { try await store.delete(item); if store.items.isEmpty { dismiss() } }
                                    catch { failure = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityIdentifier("lifeIllustration.viewer.image")
                if let selected {
                    Text(selected.dateCaption).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 24).padding(.bottom, 24)
                        .accessibilityIdentifier("lifeIllustration.viewer.caption")
                }
            }
            .background(MoMoPalette.canvas)
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                if !zoomed, value.translation.height > 100,
                   abs(value.translation.height) > abs(value.translation.width) * 1.5 { dismiss() }
            })
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                        .accessibilityIdentifier("lifeIllustration.viewer.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let selected, let url = store.imageURL(for: selected, thumbnail: false) {
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }.labelStyle(.iconOnly)
                            .accessibilityIdentifier("lifeIllustration.viewer.share")
                    }
                }
            }
        }
        .onChange(of: selection) { zoomed = false }
        .onChange(of: store.items.map(\.id)) { _, ids in
            if ids.isEmpty { dismiss() }
            else if !ids.contains(selection), let first = ids.first { selection = first }
        }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

// UIScrollView keeps pinch zoom and image panning native, without taking timeline gestures.
private struct LifeIllustrationZoomView: UIViewRepresentable {
    let url: URL
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.panGestureRecognizer.isEnabled = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.imageView.image = UIImage(contentsOfFile: url.path)
        scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        return scroll
    }

    func updateUIView(_ scroll: ImageScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.url != url {
            scroll.setZoomScale(1, animated: false)
            scroll.imageView.image = UIImage(contentsOfFile: url.path)
            context.coordinator.url = url
        }
    }

    final class ImageScrollView: UIScrollView {
        let imageView = UIImageView()
        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { imageView.frame = bounds; contentSize = bounds.size }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: LifeIllustrationZoomView
        var url: URL
        init(parent: LifeIllustrationZoomView) { self.parent = parent; url = parent.url }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScrollView)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            scrollView.panGestureRecognizer.isEnabled = zoomed
            parent.zoomed = zoomed
        }
    }
}
#endif
