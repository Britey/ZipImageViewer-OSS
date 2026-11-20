# React Native port

This branch implements the shared library, settings, import presentation and reader chrome while retaining native archive, storage, codec and canvas engines. See [the feature parity ledger](PARITY.md) and [the Mac testing handoff](MACOS.md).

## Scope and ownership

- Shared TypeScript library, search/details, reader preferences, compression/retention settings, import/password/progress/error presentation and help.
- Native process-owned services hold library, settings, imports and reader leases. React mounts subscribe to revisioned snapshots; they do not own repositories or durable settings.
- Android retains its picker options and external archive intake. iOS retains its document picker and native staged ZIP/7z operations.
- UIKit/Compose provide the native reading canvas and image pipelines. Shared reader chrome, slider, jump, overview, reader settings, notices and help now ship from the React Native root.
- Keep current application IDs, minimum OS versions, native storage locations, original page identities and codec sources. No runtime networking, analytics, OTA or account feature is introduced.

## Port acceptance

The MVP needs a real bundled app, not just shared components compiling. Required workflow: launch shared library, select/import an archive, enter an encrypted archive's password, observe native progress/errors, open the shared reader and native canvas, return to shared library, change settings, restart and retain progress/preferences. Existing ZIP/7z/JXL behavior and stored libraries must remain usable.

Tests must cover reconnect without duplicate repository ownership, obsolete operation IDs, snapshot/event races, import cancellation/retry, exact reader finalization and shared UI dispatching against current IDs. React teardown only detaches listeners. Native owners determine cancellation and close.

Physical-device memory and same-certificate production upgrade verification are distinct release gates. A successful emulator, simulator or unsigned build does not certify those gates. Use synthetic data in disposable installations for upgrade/destructive tests.

## Build

Use the exact Node version in `.node-version`, then `npm ci`. Run `npm run typecheck`, `npm test` and `npm run codegen`. `npm start` runs Metro for development. Release variants embed the JS bundle and must run with Metro stopped.

Android retains its Gradle wrapper, native codec bootstrap and pinned SDK/NDK/CMake in `android/`. Build with the existing `android/gradlew` from that directory. Debug has the `.debug` application-ID suffix; it is not an in-place upgrade of the release app.

Keep verification sequential on memory-constrained hosts: build with `--no-daemon` and `CMAKE_BUILD_PARALLEL_LEVEL=1`, then run one emulator. Gradle defaults to one worker, a 2 GiB heap and in-process Kotlin compilation; Metro defaults to two workers. The emulator helper defaults to 2048 MiB and two cores, configurable with `ZIV_EMULATOR_MEMORY_MB` and `ZIV_EMULATOR_CORES`. The original-resolution 32 MP JPEG XL capacity test needs a 4096 MiB guest; run that separately with Metro/build daemons stopped and adequate host memory. Lower-memory devices may retain the original when the native codec allowance is insufficient. Stop Metro for offline Release smoke. Do not overlap the native build with phone/tablet emulators.

iOS uses the existing Xcode project plus a CocoaPods workspace for React Native. On macOS install the Ruby dependencies with `bundle install`, then `bundle exec pod install`. Open the generated `ZipImageViewer.xcworkspace` and use the `ZipImageViewer` scheme. `scripts/verify-ios.sh` builds the unsigned device Release and executes simulator tests from this workspace. See [macOS checkout and Metro instructions](MACOS.md) for bundled-JS testing and simulator/device development.

The initial candidate RN 0.87.1 failed the real Android Gradle probe: its plugin called an AGP 9 API absent from the existing AGP 8.13.2. RN 0.86.3 passed Gradle configuration and production Kotlin compilation while retaining AGP 8.13.2, Gradle 8.13, Kotlin 2.2.21 and SDK 36. Package/lock files pin that candidate and matching RN tooling. React is 19.2.3 and Node is 24.21.0. Native packaging/runtime verification remains a separate gate.

The native NDK is aligned to RN's prebuilt C++ runtime (27.1.12297006). RN's Gradle plugin automatically chooses a duplicate libc++ runtime; a successful merge alone would not prove coherent runtime selection. The APK verifier checks byte identity with that pinned runtime, both required ABIs, all packaged ELF alignment and required RN/Hermes/codec libraries. Keep codec sources and explicit 16 KiB alignment rather than adding an unexplained packaging override.

## Repeatable Android shared UI smoke

On a disposable English-language emulator, install a fresh build and use the system file picker. The script never installs, uninstalls or clears app data. For Release, locally sign an APK copy with a disposable testing certificate and stop Metro before running; this does not produce a production-signed release.

```sh
python3 scripts/smoke-android-mvp.py --serial emulator-5554 \
  --package com.brite.zipimageviewer --output work/release-smoke \
  --encrypted-archive android/app/src/androidTest/assets/archive-fixtures/encrypted.zip \
  --encrypted-archive android/app/src/androidTest/assets/archive-fixtures/headers-lzma-solid.7z
```

The default package is the Debug suffix. A fresh empty library checks repeated picker cancellation, then imports the test-only `field-notes.cbz` through DocumentsUI. The production app contains no sample archive. Use `--existing-seed --seed-title "Field Notes.cbz" --expected-page 2` when verifying a previously seeded archive; `--seed-archive` can select another reader fixture. Screenshots and UI trees are saved under the selected output directory. Public fixture passwords are used only for these synthetic archives.

With fresh default preferences and the twelve-page fixture, `--verify-double-tap` checks the default-on shared switch, live disabling with two rapid page turns, live re-enabling with zoom-in/out, and the disabled value after a process restart. Native gesture tests separately verify immediate callback timing and pinch/pan preservation.

With Debug and Metro running, `--reload-reader` checks reattachment of a hidden native canvas, retaining its page and controls without restarting the process. `--reload-password` additionally reloads React at each password prompt, requires the ephemeral input to clear without a native process restart, deletes the uniquely named synthetic source copy, then unlocks using native staged bytes. This is a separate development lifecycle check, not an offline Release mode.

`--rotate-reader` additionally exercises landscape overview layout, actual native swipes through shared chrome and page preservation on returning to portrait. It restores the emulator's previous rotation policy. Encrypted fixture checks select **System files** through the one-time picker, preserving any saved third-party picker preference. 

Activity destruction is UI detachment. Normal reader Back/Close explicitly saves and releases the session; configuration changes and external singleTask replacement retain it so a failed new archive does not lose the old reader. Relaunch can reattach that native session. Task-removal cleanup is not presented as a verified release behavior; it needs a distinct signal rather than closing indiscriminately in onDestroy.
