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
