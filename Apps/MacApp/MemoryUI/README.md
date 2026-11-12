# MoMo memory UI adapter

The Mac app embeds the actual StarMap from the vendored Hermes Desktop source
(`Vendor/HermesAgent/apps/desktop/src/app/starmap`, upstream `cf4f3a7`).
The original renderer, force layout, zoom/pan, node hover, and timeline are bundled
without changing the vendored tree. `build.mjs` documents the small integration seams.

```sh
cd Apps/MacApp/MemoryUI
npm ci --ignore-scripts
npm test
npm run build
```

The checked-in `../Desktop/MemoryWeb` is the offline build shipped by Xcode.
It includes the upstream MIT license. No npm toolchain is needed to build the
Swift application unless changing this UI. Runtime network access is disabled by
CSP. Native code sends only the memory snapshot; no API credential enters WebKit.

MoMo memory remains authoritative. The adapter uses source timestamps (not an
invented "learned at" field), excludes forgotten records, and emits no skills,
usage counts or inferred relationship edges. Upstream sharing/import and mutation
calls are replaced: clicking a node or its preview (or right-clicking) opens the native memory inspector. Forget
uses the existing revision-checked MoMo API. Native list mode supports keyboard
and screen-reader use, reduced motion and web-process failure recovery.

The timeline gains arrow/Home/End keyboard controls. App theme tokens and Chinese
labels are supplied locally. The local `preview.mjs` replaces only the upstream
black title tooltip with a bounded reading card: Chinese/grapheme wrapping,
regular body text, source/date metadata, and an explicit preview/full-reader
boundary. Exact legacy recording UUID/version prefixes move out of the preview;
uncertainty qualifiers remain visible. The native reader retains the full original
text and identity. Dates parsed from a legacy prefix do not alter graph chronology.
No memory file or API response is rewritten. `build.mjs` checks its upstream
integration anchors and fails rather than silently shipping an incompatible patch.
