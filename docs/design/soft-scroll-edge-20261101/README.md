# Native soft top scroll edge

Use the system's soft transition between scrolling content and top controls on iPhone. Typography, navigation, and layout stay unchanged.

- Shared `phonePageSurface()` sets `.scrollEdgeEffectStyle(.soft, for: .top)` for native phone pages and their descendant scroll views.
- `ChatRendererView` applies the same style to its native fallback and explicitly sets `WKWebView.scrollView.topEdgeEffect.style = .soft` for its UIKit scrolling surface.
- iOS 26+ uses the public API; older iOS and Mac retain their existing rendering. No overlay, gradient mask, private filter, continuous animation, or extra dependency is introduced.
- The OS controls the blur radius, extent, interaction with overlapping controls, and accessibility adaptation. Selecting `.soft` does not force a custom blur band where no control overlaps the scroll view.

References: [Apple ScrollEdgeEffectStyle](https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle), [Apple UIScrollView.topEdgeEffect](https://developer.apple.com/documentation/uikit/uiscrollview/topedgeeffect), and [Linear's custom material approach](https://linear.app/now/linear-liquid-glass). The Linear article describes its own custom rendering; this change uses Apple's public system effect.

Validation uses synthetic memories on an iPhone 17 simulator running iOS 27, at the default text size. The long-memory fixture exceeds the viewport, and the UI test checks that its text frame actually moves upward before capturing the top edge. Screenshots show the app's native navigation bar over scrolling text.

- `MoMoAgentRemote` build-for-testing: passed.
- Shared page modifier type-check for macOS 14: passed. This is a compatibility check, not a full Mac build.
- Light appearance: `MemoryReadingTests` passed (1 test, 0 failures), including full-text preservation, navigation, menu/cancel behavior, scrolling, and contrast/hit-region/trait audit.
- Dark appearance: the same reading and accessibility test passed (1 test, 0 failures).

[Light scrolled content](screenshots/light-scroll.png) · [Dark scrolled content](screenshots/dark-scroll.png). Both show a blurred transition beneath the navigation controls with sharp text below. These are simulator captures, not real-device installation evidence. The WebKit style is configured and compiled; its visible edge under the custom chat header has not been separately verified.

Cleanup: stopped the task's synthetic fixture service, deleted its temporary simulator, build/package caches, raw test results, and borrowed resource symlinks. Original models and runtime resources remain in the main checkout. Disk available after cleanup: 7.0 GiB; this is a point-in-time reading, not an attribution of all free-space change to this task.
