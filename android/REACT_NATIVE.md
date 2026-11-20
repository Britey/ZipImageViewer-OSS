# React Native Android integration

The production entry point is `MainActivity` (`ReactActivity`). `ZipImageViewerApplication`
owns one React runtime and the process `AppCoordinator` owns native import, reader, preferences,
and repository state. Module invalidation detaches subscriptions only. Native reader close and
import cancellation are explicit operations. `LegacyLibraryActivity` exists in Debug only for
retained Compose regression coverage; passing those tests does not establish shared UI parity.

Incoming VIEW/SEND content URIs and stable ActivityResult picker results reach the coordinator
before JS readiness. Native staging and permission lifetimes stay in the host. The complete
reader is presented in `ReaderActivity` with shared React controls and a Fabric-hosted Compose
canvas; its image pipeline/leases/codecs remain native.
Snapshots are revisioned and carry opaque archive/import identifiers, never pixel data.
Native StateFlow notifications drive bridge events and reader presentation before any Compose
Recomposer exists; Compose state is only an adapter for the retained reader. The native-only
observer regression is covered by JVM and instrumentation tests.

## Toolchain choice and runtime verification

RN 0.87.1 was probed in this project and failed configuration on its AGP 9-only
`ApplicationExtension.getBuildFeatures` signature. RN 0.86.3 compiles with the existing
Gradle 8.13, AGP 8.13.2, Kotlin 2.2.21 and SDK 36. Its native binaries use NDK 27.1.12297006.
The app and autolinked libraries therefore use that NDK, replacing the prior 28.2 compiler.

This is a deliberate C++ runtime alignment: RN's plugin automatically adds a libc++ `pickFirst`
packaging rule. A successful package build alone could conceal different runtime producers.
The stripped NDK 27.1 runtime is byte-for-byte identical to RN 0.86.3's packaged runtime on
both ARM64 and x86_64. `tools/verify-apk-native-runtime.py` checks the final APK's required engines,
every packaged ELF's 16 KiB load alignment, and exact runtime identity with the configured NDK.
Run Android build-tools `zipalign -c -P 16 -v 4 APK` as the separate ZIP alignment check.

RN/generated bindings use C++20 in `cpp/react`; existing codecs retain their C++17 settings.
React's CMake integration has its own directory so it cannot mistake codec JNI entry points for
its `OnLoad.cpp`. Application IDs, native persistence paths and preference keys are unchanged.
Release has bundled JS and no added INTERNET permission; Metro access is Debug only.

## Validation

Build from this directory after root `npm ci` and `vendor/bootstrap-jpegxl.sh`:

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:assembleDebugAndroidTest
python3 tools/verify-apk-native-runtime.py app/build/outputs/apk/debug/app-debug.apk "$ANDROID_HOME/ndk/27.1.12297006"
```

`NativeProtocolTest` covers stable revisions, durable native preferences, invalid commands,
and module invalidation during a staged password retry. `ExternalArchiveActivityTest` exercises
the actual React host's native intake and retained reader presentation. Shared React UI testing
and upgrade-install evidence are documented in the repository MVP handoff; the legacy Compose
harness is kept separately and is not presented as RN UI coverage.

A repeatable production-host smoke script lives at `../scripts/smoke-android-mvp.py`.
Its `--package com.brite.zipimageviewer` option exercises a locally signed Release APK;
stop Metro and remove the emulator's TCP 8081 reverse before this run. The script opens
shared library/settings, imports the sample into the native reader, returns to the shared
library and verifies persistence after process restart. Repeated `--encrypted-archive`
arguments additionally exercise DocumentsUI, shared password entry, native decoding and
retained library entries using public `test-password` fixtures. Run only on the disposable
emulator with synthetic data. Signing the Release APK with a local debug key verifies
minification and offline execution, not production signing or a production-signed upgrade.

`ExternalArchiveActivityTest` drives real Main/Reader Activities using instrumentation and
lifecycle observation: Main is covered while Reader is foreground, so forcing a background
Main into an ActivityScenario RESUMED state would test an impossible lifecycle condition.
It checks foreground reader recreation and native service identity/provider-open count,
then recreates Main after explicit close and checks that the original incoming intent is
not replayed. Activity destruction intentionally detaches; explicit close/cancel releases
native sessions. This also preserves an existing reader when a singleTask incoming archive
fails after replacing its Activity.
