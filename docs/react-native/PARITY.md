# React Native feature parity implementation

The shared library and reader now use the existing UIKit/Compose engines through native services and Fabric views. Native source grants, paths, passwords, decoded pixels, storage and reader leases stay outside JavaScript. This document describes the implementation; execution evidence is recorded in MVP.md and the Mac handoff in MACOS.md.


| Native feature | React Native port |
|---|---|
| Library, search, resume, covers, details and unavailable entries | Adaptive shared cards, native thumbnails, exact current page, reading progress, format, retained bytes and last-opened date. Native catalog remains the owner. iOS search folds accents as well as case; library dialogs support the app-advertised orientations. |
| ZIP/CBZ/7z and password retries | Existing staged native import engines; shared password/progress/error UI in both library and reader roots. Incoming replacement archives keep the previous reader until a successful import. |
| Android sample, external VIEW/SEND and picker choices | Existing native intake and sample; shared controls for saved picker preferences and a one-time alternative picker. |
| Reading, swipe/tap zones, reverse direction and animations | Existing UIKit canvas and Compose ReaderImageSurface/pipeline. Shared chrome passes empty touches to the canvas. |
| Pinch/double-tap zoom, pan and detailed decoding | Existing native geometry, preview/detail lanes, source/memory admission, native color/orientation policy and codec fallback. Shared retry actions. |
| Page count, continuous slider and exact release | Shared touch PagePosition; throttled previews and unconditional exact release. Native session IDs and increasing seek sequences reject stale/out-of-order actions. |
| Jump and page overview | Shared validated jump dialog and virtualized adaptive grid; native downsampled thumbnails retain image-work leases. Selection uses native sorting and original-page identities. Android cover lookups reuse one ordering per session/list/sort change. |
| Reader settings, thumbnail size and help | Shared controls, continuous thumbnail sizing with smaller/larger buttons, native preference persistence and explanatory help. Canceled sizing drags restore the saved value. Reader settings keep Done visible while scrolling. |
| Hide controls and Back | Native canvas gestures plus shared chrome/tools. Back reveals hidden controls before closing. Reader keyboard shortcuts were removed on both platforms at the owner’s request. |
| Sorting, progress and restart | Existing native metadata sort policy; changes preserve the original page identity. Native progress flushes on explicit close/background and survives process restart. iOS save errors appear while the reader remains active. |
| Compression/JXL, quotas, preview/reconfirmation, LRU and temporary reading | Existing native storage/codec implementation; shared explanations, busy reservations, victim/reclaimed-byte previews and temporary-copy notices. Original archive files remain unchanged. |
| React reload / Activity detachment | Native repositories and staged imports remain process-owned. Canvas reattachment restores the page and controls; stale canvas callbacks cannot replace the current surface. Explicit close owns finalization. |
| Offline builds | Release embeds Hermes JS, preserves app identity and has no added network permission or OTA mechanism. |

## Acceptance limits


Reader keyboard shortcuts and custom VoiceOver reader adjustments, canvas actions and dismissal handlers remain intentionally removed. The reviewed port is ready to become the shared mainline presentation; standalone legacy UI paths can be deprecated while retaining native canvases, codecs, archive/storage services and still-relevant test coverage.

The Android update used one disposable certificate and the iOS update used unsigned simulator apps. They establish retained-data compatibility for those installations, not production signing provenance. Physical-device memory/provider performance, minimum-supported-OS runtime coverage and ordinary screen-reader traversal remain release qualification work. Hosted GitHub Actions remain disabled.
