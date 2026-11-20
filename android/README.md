# ZipImageViewer Android

Shared React Native interface with Kotlin/Compose image canvas and native engines,
maintained alongside the Swift iOS app in the same repository. Both apps share
the root `Vendor/` codec sources. Version `0.5.0-preview` adds shared library,
settings, import presentation and reader controls. Version `0.4.0-preview` added
configurable file pickers and external archive opening.
Version `0.3.0-preview` added the remaining image pipeline and cache behaviors, including
memory-bounded detail upgrades on zoom and optional JPEG XL compression.
Physical ARM64/OEM, display, thermal and performance validation is still a
separate gate. See the [cross-platform feature matrix](../docs/react-native/PARITY.md).

## What works

- Import ZIP, CBZ and 7z documents with Android's document picker or a preferred
  compatible file app; receive single-file Share and Open with requests, including
  AES-encrypted ZIP/CBZ and encrypted 7z headers/content. Password retries
  preserve whitespace and Unicode and reuse the staged download; passwords are not saved.
- Extract visible JPG/JPEG/PNG pages into private storage, with progress,
  cancellation, path validation, output limits, persistent previews and
  cleanup after failure. Source archives remain unchanged. Malformed/oversized pages remain
  navigable unavailable pages rather than preventing the rest of a book opening.
- Searchable offline library, cover thumbnails, archive details, removal,
  bulk removal and persisted reading position. Cached archives reopen after
  their original document has been removed or become inaccessible.
- Source URI plus SHA-256 identity reuses the same source/content, keeps
  distinct sources separate, and retires old versions after a replacement
  commits. Existing Android libraries remain readable.
- Full-screen reader with edge taps, swipes, reversed reading direction,
  pinch zoom, double-tap zoom, panning, configurable tap area, optional page
  animation, page count, page slider with thumbnail preview, validated page
  jump and an adjustable thumbnail overview.
- Natural filename sorting, ascending/descending direction and date sorting
  when metadata is available. The current page keeps its original identity
  across sort changes.
- Persisted reader preferences, light/dark themes, adaptive library/overview
  grids.
- Whole-archive LRU retention with a default **2,000,000,000-byte** budget;
  settings offer 500 MB, 1, 2, 5 or 10 GB, plus an optional archive count
  of 5, 10, 20 or 50 (unlimited by default). Active readers keep their files. An archive
  larger than the entire budget opens as a clearly labeled temporary session
  and is deleted after its reader and outstanding image work finish.

## Image pipeline and cache parity (0.3.0)

- Zoom starts with a screen-fit image and asynchronously upgrades to more
  source detail without resetting pan/scale or fading the replacement.
- Separate latest-request preview/fitted/detail work, bounded native decode
  concurrency, 33ms scrub sampling, 150ms stale/settle policy and exact release.
  Memory pressure clears expendable caches while preserving selected work.
- 48MiB decoded LRU; 30MiB output bitmap ceiling; 3,072px screen-fit and
  16,384px detail long-edge ceilings, constrained by memory; 32MP source guard.
- Persistent 384px sRGB JPEG previews, even with compression off. Missing
  previews fall back to original/detail decoding. Original PNG EXIF rotation
  and mirroring are applied explicitly, including when compression is off.
- Compression defaults off and is snapshotted across password retries.
  JPEG repacks preserve the complete reconstructable original bitstream;
  PNG uses original dimensions, distance 0.5, effort 3, ICC/orientation and
  alpha compositing onto white. Unsupported, unsafe, unprofitable or
  memory-inadmissible conversions preserve the original staging file.
- A candidate must fully decode and save at least 5% and 16KiB including its
  preview, with no increase in allocated disk usage, before replacement.
- ZIP/7z original creation/modification metadata survives generated filenames.
  Cache accounting includes previews/manifests and deferred-deletion bytes.
- One repository per process and an ordered progress/finalization queue protect
  image-work leases and the last reading position across Activity destruction.

The codec source is pinned and built locally for both ABIs. Run
`./vendor/bootstrap-jpegxl.sh` from this directory on a fresh checkout before
building. See [codec provenance and limits](vendor/README.md).

## Settings and retention (0.2.0, retained)

**Open archive** is a prominent filled, labeled button on both phone and tablet.
The library's Settings form includes the same persisted reader controls used
inside the reader. Visual tap-area presets and gesture help open as
separate scrollable dialogs, keeping the main form compact.

Storage settings use the same byte/count choices as iOS. Before applying a
change, a preview lists the exact LRU archives that would be removed. The
repository rechecks its catalog, reader leases and limits atomically; a stale
preview returns a fresh list for confirmation without deleting anything.
The byte budget and optional archive count share one persisted source of truth.
Active readers may temporarily keep the library above either limit; closing
them re-enforces retention.

See the [cross-platform feature matrix](../docs/react-native/PARITY.md).

## Compact UI (retained)

The library uses a small toolbar and compact archive rows, without a large
heading, tagline or footer. At widths of 720 dp and above, search joins the
toolbar; the archive grid adapts with a 320 dp minimum column width.

The reader deliberately omits archive and image filenames and Previous/Next
buttons. Taps and swipes turn pages. Floating Back, Settings and Hide controls
retain 48 dp touch targets; page jump, a thin slider and overview share one
48 dp row capped at 600 dp on larger screens. Empty space between controls
remains part of the reading canvas. Thumbnails are labeled by page number.

## Architecture and storage

`AppViewModel` coordinates document import, password retries, persistent
settings and reader sessions. Compose implements the library, dialogs and
reader controls. A custom Android View handles image gestures and drawing;
Android image decoders and the bundled JPEG XL decoder run away from the
main thread, using bounded outputs and asynchronous detail upgrades.

`data/ArchiveRepository` serializes storage transactions with a coroutine
mutex and performs I/O on `Dispatchers.IO`. Import copies the source URI to
private staging storage while hashing, extracts selected images, validates
them, syncs image files, promotes the completed directory, then commits an
`AtomicFile` JSON catalog. Separate archive manifests support recovery from a
damaged catalog. Reading position is stored by original relative image path.
The UI debounces progress writes; a process-owned ordered queue saves the last
position and releases the reader lease even when its ViewModel is destroyed.

The archive library is under **`Context.filesDir/archive-library`**, not
`cacheDir`. Its `retained`, `temporary` and `staging` subdirectories are managed
by the application. Android's automatic cache eviction does not enforce this
budget. App uninstall or clearing app storage removes the library. Automatic
backup is disabled. Missing cached images are reported unavailable and can
be repaired by importing the source again. Import staging and interrupted
temporary sessions are cleaned on the next repository load.

ZIP/CBZ extraction uses Zip4j 2.11.5. 7z extraction uses the existing patched
PLzmaSDK / 7-Zip SDK subset through JNI, compiled for `arm64-v8a` and `x86_64`.
See [the native bridge notes](app/src/main/cpp/README.md) and
[vendor provenance](../Vendor/PLzmaSDK/UPSTREAM.md).

Encrypted archives are cached **decrypted** inside the app's private storage
and can subsequently reopen without a password. Original archives are never
rewritten. The app requests neither broad storage permission nor Internet
permission; document access uses transient content-URI grants from the picker or
sending file app. [Archive access guide](../docs/android/ARCHIVE_ACCESS.md).

Extraction limits match the source application's policy: 100,000 entries,
25,000 selected images, 512 MiB per image, 10 GiB total selected output and
100 MiB free-space reserve. Display/preparation source images are limited to 32 megapixels; other
extracted payloads remain stored and navigable as unavailable pages. These limits do not bound native archive dictionary
or header allocations. The complete source copy and extracted pages coexist
during import, so temporary disk usage can exceed the retention budget.

## Build environment

| Component | Project setting |
| --- | --- |
| Minimum device version | Android 9 / API 28 |
| Compile / target SDK | API 36 |
| Build Tools | 36.0.0 |
| Gradle wrapper | 8.13, checksum pinned |
| Android Gradle Plugin | 8.13.2 |
| Kotlin / Compose compiler plugin | 2.2.21 |
| Java language target | 17 |
| NDK | 27.1.12297006 (aligned with the pinned React Native C++ runtime) |
| CMake | 3.22.1 |
| Native ABIs | arm64-v8a, x86_64 |

Open this `android` directory in Android Studio. Set `ANDROID_HOME` and `JAVA_HOME`
to your installed SDK and JDK locations. Android Studio can generate a local
`local.properties` with `sdk.dir`. That file stays outside version control.

Install shared dependencies from the repository root with `npm ci` using the
Node version in `.node-version`. See [REACT_NATIVE.md](REACT_NATIVE.md) for native
runtime packaging verification. Run from this directory after dependency setup:

```bash
source scripts/env.sh
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.brite.zipimageviewer.debug/com.brite.zipimageviewer.MainActivity
```

Debug uses Metro: start `npm start` from the repository root and use
`adb -s EMULATOR_SERIAL reverse tcp:8081 tcp:8081` for the selected disposable
emulator. Release embeds Hermes JavaScript and runs offline without Metro.

The debug package is `com.brite.zipimageviewer.debug`; the Release
package is `com.brite.zipimageviewer`. They install side by side and have
separate libraries. `assembleRelease` produces a signed release when local
`signing.properties` supplies `storeFile`, `storePassword`, `keyAlias` and
`keyPassword`; otherwise configure signing before installing that variant.
Keep signing keys and credentials outside the repository.

Create an API 35 phone or tablet emulator in Android Studio. Use
`scripts/start-emulator.sh AVD_NAME` to start a named local AVD.

## Verification

```bash
source scripts/env.sh
./gradlew testDebugUnitTest
./gradlew connectedDebugAndroidTest
./gradlew lintDebug assembleRelease
```

`connectedDebugAndroidTest` requires a booted Android emulator or attached
device. Both native ABIs are built. Release enables R8. Large-image
codec tests are separate from routine interaction tests:

```bash
./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.notClass=com.brite.zipimageviewer.nativebridge.NativeJpegXlLargeImageTest
./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.brite.zipimageviewer.nativebridge.NativeJpegXlLargeImageTest
```

Coverage includes safe output paths and aliases, natural/date ordering,
cache policies, independently generated ZIP/CBZ/7z fixture hashes,
encrypted-header/content decoding, Unicode and whitespace passwords,
600-image solid archives, mid-extraction cancellation, publication-boundary
cancellation, source immutability, reading-position persistence after source
deletion, stale cache repair, temporary/leased storage behavior, reader
navigation/zoom/sorting, and the fixture library-to-reader app flow.

Test assets are under `app/src/androidTest/assets/archive-fixtures`. Codec/archive
fixtures derive from `ZipImageViewerTests/Fixtures/SevenZip`; the twelve-page
`field-notes.cbz` reader fixture contains project-generated images. These assets
are included only in the test APK. Repository tests use isolated app-private directories. The full-app smoke
test resets the debug app's library and preferences; run it only against a
disposable debug installation. The separately installed release library is
unaffected. Reports are
under `app/build/reports` and `app/build/outputs/androidTest-results`.

## Later physical-device validation

The emulator verifies functionality, not phone speed or thermal behavior.
Install the signed ARM64 APK on a Pixel first, then check Samsung/Xiaomi
file providers, lifecycle, multitouch, TalkBack and wide-color displays.
Measure process/native memory, cold-storage loading, battery/thermal behavior
and representative large/solid archives on those devices.

Imports are cancelled if the process dies and staging is recovered at next
launch; they are not resumable foreground-service jobs. A new process starts
at the library with saved reading positions. iOS library migration, additional
archive formats and Google Play publishing are outside this port's scope.

## Third-party licenses

The APK includes `THIRD-PARTY-NOTICES.txt` and full license/notice assets for
PLzmaSDK, Zip4j, libjxl, Brotli, Highway, skcms, libpng, zlib, AndroidX,
Kotlin, kotlinx.coroutines and the LLVM/libc++
runtime. Zip4j's Apache license and required NOTICE were copied from the
[2.11.5 upstream tag](https://github.com/srikanth-lingala/zip4j/tree/v2.11.5).
Do not remove the bundled notices when redistributing a personal APK.
