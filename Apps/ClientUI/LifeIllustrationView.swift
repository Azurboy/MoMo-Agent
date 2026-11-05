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
    var contentMode: ContentMode = .fit
    @State private var image: Image?

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay { if let image { image.resizable().aspectRatio(contentMode: contentMode) } }
            .clipped()
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

struct LifeIllustrationPlate: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(LifeIllustrationPaper.fill(for: colorScheme))
            .clipShape(Rectangle())
            .overlay {
                ZStack {
                    Rectangle().strokeBorder(MoMoPalette.line, lineWidth: 0.6)
                    Rectangle().inset(by: 5).strokeBorder(MoMoPalette.line.opacity(0.65), lineWidth: 0.5)
                }
                .allowsHitTesting(false)
            }
    }
}

struct LifeIllustrationMetadata: View {
    let illustration: LifeIllustration
    let position: Int
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(illustration.logicalDay)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(MoMoPalette.surface, in: Capsule())
                    .accessibilityHidden(true)
                Text(illustration.caption).font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .accessibilityLabel(illustration.dateCaption)
                    .accessibilityIdentifier("lifeIllustration.viewer.caption")
            }
            Spacer(minLength: 0)
            if count > 1 {
                Text(String(format: "%02d / %02d", position, count))
                    .font(.system(.caption2, design: .monospaced))
                    .fixedSize()
                    .accessibilityIdentifier("lifeIllustration.viewer.page")
            }
        }
        .foregroundStyle(MoMoPalette.muted)
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

    private var items: [LifeIllustration] {
        store.items.filter { store.imageURL(for: $0, thumbnail: false) != nil }
            .sorted { $0.windowStart < $1.windowStart }
    }
    private var selected: LifeIllustration? { items.first { $0.id == selection } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = max(0, min(geometry.size.width - 48, geometry.size.height - 124))
                VStack(spacing: 16) {
                    if let selected {
                        LifeIllustrationMetadata(illustration: selected,
                            position: (items.firstIndex(where: { $0.id == selection }) ?? 0) + 1,
                            count: items.count)
                            .frame(width: side)
                    }
                    TabView(selection: $selection) {
                        ForEach(items) { item in
                            Group {
                                if let url = store.imageURL(for: item, thumbnail: false) {
                                    LifeIllustrationZoomView(url: url, zoomed: Binding(
                                        get: { selection == item.id && zoomed },
                                        set: { if selection == item.id { zoomed = $0 } }))
                                        .id(item.id + (selection == item.id ? "-selected" : "-offscreen"))
                                        .frame(width: side, height: side)
                                        .modifier(LifeIllustrationPlate())
                                }
                            }
                            .tag(item.id)
                            .contextMenu {
                                Button("查看依据", systemImage: "text.alignleft") { dismiss(); showSource(item) }
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    Task {
                                        do { try await store.delete(item); if items.isEmpty { dismiss() } }
                                        catch { failure = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: side)
                    .accessibilityIdentifier("lifeIllustration.viewer.image")
                    if let selected {
                        Button("查看这段转录") { dismiss(); showSource(selected) }
                            .font(.caption).foregroundStyle(MoMoPalette.muted)
                            .frame(minHeight: 44).buttonStyle(.plain)
                            .accessibilityIdentifier("lifeIllustration.viewer.source")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: items.map(\.id)) { _, ids in
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
