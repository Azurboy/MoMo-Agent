# iPhone scroll edges

On iOS 26 and later the phone uses the system soft effect at the top of scrolling pages. Native navigation bars use the shared page style. Chat, pairing, onboarding and the task panel use a safe-area bar to register their custom controls with the scrolling surface. See [Apple’s scroll edge documentation](https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle) and [custom bar guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

In chat, the WebKit viewport extends under the MoMo header. The renderer measures the overlap and positions the first message, notification targets and reading anchors relative to the visible region. Older iOS versions use the stacked header layout. The timeline keeps its date controls outside the horizontal pager to preserve each day’s reading position. While reading below the top of a day or a list of search results, a 16-point fade softens the edge below the controls. It disappears at the start of the list or when Reduce Transparency is enabled.

| Screen | Capture |
| --- | --- |
| Chat while reading earlier messages | [iPhone](screenshots/chat-scroll.png) |
| Timeline with the date controls pinned | [iPhone](screenshots/timeline-scroll.png) |
| Memory detail while scrolling | [Light](screenshots/light-scroll.png) · [Dark](screenshots/dark-scroll.png) |
| Settings with the previous appearance | [iPhone](screenshots/phone-settings.png) · [Mac](screenshots/mac-settings.png) |

The chat capture used 42 synthetic messages in the app’s history on an iPhone 17 simulator running iOS 27. Interaction checks covered scrolling to the first message below the wordmark, reading with the header fixed, returning to the latest message and opening settings. Renderer tests exercised reading-position restoration and following new replies. A timeline regression test paged away and back, tapped the tab bar and verified that both the latest entry and the manually selected reading position remained accessible. The Mac capture used an isolated data directory in a Debug build.

The separate chat-delivery fixture returned 404 for shared conversation discovery before the app could submit a message. That scenario did not verify delivery or desktop handoff.
