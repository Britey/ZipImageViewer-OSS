# ZipImageViewer

Offline image-archive readers for **iOS and Android**, maintained in one repository. React Native supplies the shared library, settings, import interface and reader controls; UIKit/Compose retain the image canvases, archive engines and storage. Both apps open ZIP, CBZ and 7z archives, including encrypted archives, with saved reading positions and optional JPEG XL cache compression.

| Platform | Application | Build entry point |
| --- | --- | --- |
| iOS 18.1+ | Shared React Native UI + Swift / UIKit in `ZipImageViewer/` | Install JS/Ruby/Pods dependencies, then open `ZipImageViewer.xcworkspace` on macOS |
| Android 9+ (API 28) | Shared React Native UI + Kotlin / Compose in `android/` | Install JS dependencies, then open `android/` in Android Studio or use its Gradle wrapper |

The apps retain their native readers, storage formats and application identities. Standalone UIKit/Compose presentation is deprecated; the shared React Native interface is the mainline UI. Legacy presentation remains only for compatibility tests, while native canvases, codecs and storage services remain supported. `Vendor/PLzmaSDK` and the JPEG XL encoder bridge are shared source dependencies; platform adapters and build packaging remain native.

- [React Native MVP scope, setup and verification](docs/react-native/MVP.md), [coverage migration](docs/react-native/COVERAGE.md), and [Android integration details](android/REACT_NATIVE.md).
- [Android overview](docs/android/README.md), [build/test guide](android/README.md), and [archive picker / Share / Open with support](docs/android/ARCHIVE_ACCESS.md).
- [macOS build and regression verification](docs/react-native/MACOS.md).

From the repository root, an Android debug build is:

```sh
# Use the Node version in .node-version and npm pinned in package.json.
npm ci
./android/vendor/bootstrap-jpegxl.sh
cd android
./gradlew assembleDebug
```

Install the pinned SDK/NDK/JDK prerequisites in the Android integration guide first. Debug UI development uses `npm start` from the repository root; Release embeds JS and works offline. iOS builds require Xcode/macOS. Signing credentials and machine-local SDK paths are not committed.

## iOS application

An iOS UIKit reader for JPG, JPEG and PNG images inside ZIP, CBZ and 7z archives. Password-protected ZIP and encrypted 7z contents/filenames are supported. Requires iOS 18.1 according to the current project settings.

With Node and Ruby installed, run `npm ci`, `bundle install` and `bundle exec pod install`, then open `ZipImageViewer.xcworkspace` using Xcode 26.2. Choose your existing signing team for a physical device, or an installed iOS simulator. Run `scripts/verify-ios.sh` locally on your Mac to build the unsigned Release device target and run simulator tests. The project uses Xcode synchronized source folders and retains pinned Swift packages alongside React Native's Pods.

## Code layout

- `mobile/src/`: shared library, search/details, reader controls/slider/jump/overview, settings, import/password/progress/errors and the typed native command/snapshot client.
- `NativeAppService.swift`, `ZipImageViewerModule.mm` and `ReactAppHost.swift`: process-owned native services, generated bridge adapter and React Native host.
- `ViewController.swift`: retained legacy UIKit library/presentation harness used by existing native UI tests.
- `ArchiveCache/`: shared persistent ZIP/CBZ/7z cache, manifests, reading progress, reader leases, storage accounting and whole-archive LRU eviction.
- `ArchiveLibraryViewController.swift` and `ArchiveLibraryCell.swift`: searchable adaptive list/grid with downsampled covers, progress and archive details.
- `ReaderPreferencesStore.swift` and `SettingsViewController.swift`: persistent reader preferences and accessible reading/storage forms.
- `ReaderControlsView.swift`, `PageJumpViewController.swift` and `PageOverviewViewController.swift`: grouped reader controls, validated page input and bounded thumbnail browsing.
- `ArchiveService.swift`: coordinated ZIP/CBZ access and operation-scoped extraction. Call it from a single serial queue.
- `ArchiveImport/`: native 7z extraction, output validation, progress, cancellation, password retries and staging ownership.
- `ArchiveImport/ExtractedImageProcessor.swift` and `Vendor/JPEGXL/`: optional cache compression, navigation previews and the pinned libjxl encoder.
- `ReaderImagePipeline.swift`: asynchronous image preparation, replaceable pending requests and decoded-byte budgets.
- `Vendor/PLzmaSDK/`: local native dependency, including SDK 26.06 updates and reproducible Unicode/solid-archive patches; see its `UPSTREAM.md`.
- `ImageFileSorter.swift`: natural filename/date sorting with deterministic ties.
- `ImageViewerViewController.swift`: page navigation, gestures, zoom, controls and image display.

**Library** uses shared searchable cards with native cover thumbnails, exact reading progress, availability, details and cached-copy removal. The shared reader provides controls, continuous page scrubbing, jump, thumbnail overview, settings and help over the retained native image canvas. Keyboard shortcuts and custom VoiceOver reader actions were removed at the owner's request; standard controls and labels remain. Tap a retained archive to resume without selecting or reading the original file again. Completed iOS image caches live in `Library/Caches/ZipImageViewer`; its catalog and reading positions live in `Library/Application Support/ZipImageViewer`. Progress identifies the image by its relative path, so changing sort order still resumes on the same image.

The default retained-cache budget is 2 GB, with an optional archive-count limit (off by default). Whole least-recently-opened archives are removed until both enabled limits are satisfied; an active reader's files are protected until it closes. An archive larger than the budget can be read temporarily and is removed on closing without displacing the retained collection. Import staging can require extra disk space beyond the budget. Failed imports preserve completed caches. Use **Remove Cached Archive…** in an archive’s menu, or **Remove All Cached Archives…** in Settings. Both ask for confirmation before removing cached entries and saved progress; original files remain. Lowering a cache limit previews the affected count before applying eviction.

**Compress extracted images** in Settings → Storage is off by default and applies to new extractions. Suitable JPEG pages are repacked into JPEG XL losslessly; suitable PNG pages use a high-fidelity lossy preset at their original dimensions. Transparency is composited onto white for converted pages. Originals are retained if conversion is unsupported, exceeds the processing limits, or does not save at least 5% and 16 KiB including the preview, with no allocated-size increase. The setting never rewrites an existing cache. To use a different choice for an already cached archive, remove that cached copy, change the setting, and reopen the source archive; removing the cached copy also removes its saved progress.

JPEG repacking and PNG encoding have separate memory policies, with actual compression/reopening regression coverage at 12, 24 and 32 megapixels. PNG encoding uses chunked input. Each phase checks the app's available memory; unusually large or memory-constrained conversions retain their originals. The input-file limit is 128 MiB, and the source-resolution limit is 32 MP. See [the codec and build notes](Vendor/JPEGXL/README.md) for encoding and decoding limits.

New imports prepare small navigation previews even when compression is off; the detailed original bytes remain unchanged in that mode. Slider movement updates the requested page immediately and samples previews during rapid dragging, then loads the exact selected page when released. Existing caches use asynchronous decoding without migration. Reader decoding has a 48 MiB image cache and bounded transient allocations; individual displayed bitmaps are capped near 30 MiB, so very large pages may have reduced maximum zoom detail. Sources above 32 megapixels or 100,000 pixels on either axis are retained but display as unavailable. These guards do not resize the stored source files.

Reader settings persist across launches and apply immediately to an open archive. The page-number button jumps to a page; **Pages** opens the thumbnail overview directly. Adjust **Thumbnail size** in Settings to choose a denser or larger grid. Invalid page numbers stay in the form with an explanation. Reader controls sit at the safe-area edges: separate top buttons and a single bottom row with page number, slider and thumbnails. Tap the small screen-center area, use the eye button, or long press the page to hide/show all reader controls. **Tap center to show/hide controls** in Settings enables this center shortcut by default; turn it off to use the normal page action there. Center taps also work while zoomed without changing the page or zoom.

Cached images from encrypted archives are decrypted and reopen without another password; passwords are never saved. iOS may purge cached files, in which case the recent row offers reselection. Picker imports still hash the source to detect changed contents. Existing temporary single-archive caches are cleared on first launch of this version; recent entries accumulate through new opens.

7z imports run in the background, preserve password whitespace and Unicode, and support progress and cancellation. The app supports single-volume LZMA and LZMA2 and the tested PPMd archive types. See the [native bridge notes](android/app/src/main/cpp/README.md) for extraction and allocation limits.

## Local verification

For the portable source/resource checks (Python 3.10+ required; no Xcode required), from the repository root:

```sh
python3 -m venv .venv-static
.venv-static/bin/pip install -r scripts/requirements-static.txt
.venv-static/bin/python scripts/verify_static.py
```

The checker parses Swift grammar and project resources, verifies dependency and synthetic fixture integrity, and checks selected navigation and ordering contracts. Xcode builds and runtime tests are separate steps.

To repeat the native tests, run the `ZipImageViewerTests` and `ZipImageViewerUITests` targets in Xcode on an installed iOS simulator.

Run shared tests with `npm run typecheck`, `npm test` and `npm run codegen`. See the [local Mac instructions](docs/react-native/MACOS.md) and the [Android build guide](android/README.md) for platform verification.

## License

First-party material is licensed under the [Apache License 2.0](LICENSE). See [third-party notices](THIRD-PARTY-NOTICES.md) for dependencies, packaged notices and fixture provenance.
