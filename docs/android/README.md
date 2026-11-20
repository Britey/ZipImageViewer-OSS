# ZipImageViewer for Android

A shared React Native interface with native image/archive engines for Android 9
and later. Open ZIP, CBZ
and 7z archives, including encrypted archives, and read their images without
an account or network access.

This is the Android app in the [ZipImageViewer repository](../../README.md),
alongside the iOS app and shared codec sources. Version **0.5.0-preview**.

## Features

- Prominent **Open archive** action, searchable offline library and adaptive phone/tablet layouts.
- Configurable system/third-party file pickers, remembered picker preference,
  and ZIP/CBZ/7z **Share** and **Open with** handling.
- Network documents supplied by compatible file apps/providers; password retries
  reuse the staged download instead of fetching the archive again.
- Compact reader with taps, swipes, pinch/double-tap zoom,
  page jump, slider previews and thumbnail overview.
- Higher-resolution detail decoding on zoom, preserving pan and scale within memory limits.
- Shared reader settings accessible both from the library and while reading.
- Optional JPEG XL cache compression, exact JPEG reconstruction, original-dimension
  PNG conversion, color/orientation handling and persistent previews.
- Original archive dates, saved reading positions, byte/count retention limits,
  protected active readers and cache recovery. Original archives remain unchanged.

Compression defaults off. Encrypted archives are cached decrypted in app-private
storage. The app requests neither Internet nor broad storage permission.
Network access and server authentication are handled by your selected file app
or document provider. See [opening network archives](ARCHIVE_ACCESS.md).


## Build

Install the Node version in `.node-version`, JDK 21, Android SDK 36 / Build Tools
36.0.0, NDK 27.1.12297006 and
CMake 3.22.1. Open **`android/`** in Android Studio. Configure `ANDROID_HOME`,
`JAVA_HOME` and, if needed, `android/local.properties` for your SDK location.

```bash
# From the repository root: install shared dependencies and pinned codec sources.
npm ci
./android/vendor/bootstrap-jpegxl.sh
cd android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Debug uses Metro: run `npm start` from the repository root and reverse TCP 8081
on the explicitly selected disposable emulator. Release embeds its JavaScript bundle and runs offline.

The Gradle wrapper and dependency versions are pinned. The first build needs
network access for dependencies. Debug builds need no private signing key.
For a signed personal release, configure ignored `android/signing.properties`
as described in the [Android guide](../../android/README.md).

Native targets are ARM64 and x86_64. Minimum Android version is API28;
compile/target SDK is API36. See [codec provenance](../../android/vendor/README.md)
and bundled third-party notices for the native dependencies.

## Verification and development

- [Build, emulator, storage and architecture guide](../../android/README.md)

Physical ARM64, OEM/provider, accessibility, display and performance checks require physical devices.
