import SwiftUI

extension View {
    func phonePageSurface() -> some View {
        phoneText(.body)
            .foregroundStyle(MoMoPalette.ink)
            .tint(MoMoPalette.ink)
            .background(MoMoPalette.canvas)
            .phoneSoftTopEdge()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

// Keep the top transition consistent across native phone reading and settings pages.
extension View {
    @ViewBuilder func phoneSoftTopEdge() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    @ViewBuilder func phoneScrollHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0, content: header)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            VStack(spacing: 0) { header(); self }
        }
        #else
        VStack(spacing: 0) { header(); self }
        #endif
    }
}

#if os(iOS)
/// Extend drawing under the custom bar and report the inset needed for the first chat message.
struct PhoneHeaderViewport<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GeometryReader { visible in
                GeometryReader { drawing in
                    content(max(0, visible.frame(in: .global).minY - drawing.frame(in: .global).minY))
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        } else {
            content(0)
        }
    }
}
#endif
