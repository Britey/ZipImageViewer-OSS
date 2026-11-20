# Android 7z bridge

`zipimageviewer_native` builds the repository's **PLzmaSDK 1.6.1 / 7-Zip SDK 26.06**
source subset directly. See `Vendor/PLzmaSDK/UPSTREAM.md`, its four patches, and
`SHA256SUMS` for pinned provenance and audit details. No vendor sources are modified
by the Android adapter. The wrapper is MIT, copyright 2015–2026 Oleh Kulykov; the
underlying LZMA SDK subset is public domain. The unsupported TAR implementation
is excluded with `LIBPLZMA_NO_TAR=1`. The Android build packages the original
MIT license, SDK public-domain notice and Unicode ConvertUTF notice in `app/src/main/assets/`.

The portable C LZMA decoder is used on **x86_64 and arm64-v8a**, with no optional
hand-written assembly dependency. Crypto, PPMd, LZMA, LZMA2, and SDK thread-safe
wrappers remain enabled. The pinned NDK builds with 16 KiB ELF page alignment. Minimum API
28 is set by the Android Gradle module.

`NativeSevenZip.extract` is synchronous and must run off the UI thread. Give it an
app-private, empty, unique staging directory per import/password attempt. It returns
relative image names; `extractDetailed` additionally returns nullable original
creation/modification dates from archive headers. Missing dates remain unknown,
never inferred from extraction time. Kotlin validates output paths before the SDK sees destinations
and verifies each extracted file's type and length. Only regular-file stream APIs are
used: archive links, modes and special objects are never restored. On failure or
cancellation, the owned staging directory is removed.

Limits match the original app: 100,000 archive entries, 25,000 selected images,
512 MiB/image, 10 GiB total declared selected image bytes and 100 MiB free storage
reserve. Native header/dictionary allocations are **not bounded by these output
limits**; physical-device memory profiling and a future isolated extraction process
remain advisable for large untrusted archives. The SDK enforces per-item decompressed
length; the adapter verifies actual sizes after extraction.

Passwords preserve whitespace and standard Unicode, including supplementary code
points. JNI strings are explicitly transcoded from UTF-16 to standard UTF-8; modified
JNI UTF-8 is never passed to the SDK. Temporary native password storage is wiped on
exit; this does not promise erasure of the original immutable Kotlin String.

A dedicated JNI-attached monitor polls cancellation about every 30 ms and reports
progress at most ten times per second. It calls SDK abort outside progress callback
locks, including during header opening. Actual cancellation latency depends on the
codec reaching an abort checkpoint. Callbacks run on worker threads and must be
thread-safe. Exceptions from either callback are propagated to the calling thread.

Native failures cannot reliably distinguish wrong passwords, corrupt encrypted
content, and unsupported methods. `PasswordRequiredException` intentionally retains
this ambiguity. `InterruptedIOException` identifies cancellation.

If enabling R8/minification, keep the `NativeSevenZip` class and its native method,
`NativeSevenZip$Callbacks` methods `reserve`, `recordTimes`, `prepare`, `isCancelled`, `onProgress`,
and the `PasswordRequiredException(String)` constructor unchanged. Debug builds do
not minify.

A non-Android CMake branch supports JNI smoke tests with a host JDK; it is not a
substitute for installing and testing the NDK-built library on Android.

## Host regression runner

From repository root, with a JDK and `kotlinc` on PATH (Android Studio bundles it):

```sh
cmake -S android/app/src/main/cpp -B ../native-host-build -DCMAKE_BUILD_TYPE=Release
cmake --build ../native-host-build -j4
kotlinc android/app/src/main/java/com/brite/zipimageviewer/nativebridge/NativeSevenZip.kt \
  android/app/src/main/cpp/tests/NativeSevenZipHostTest.kt -include-runtime -d ../native-kotlin-tests.jar
java -Xcheck:jni -Djava.library.path=../native-host-build \
  -jar ../native-kotlin-tests.jar android/app/src/androidTest/assets/archive-fixtures
```

This runs the production Kotlin adapter against the production JNI library, including
independently generated archive content hashes, encrypted headers/content, Unicode
and whitespace passwords, supplementary filenames, all 600 solid-block images,
path collision/traversal rejection, callback failure, mid-decode cancellation and
partial-output cleanup. Host results do not establish Android runtime or ARM64
hardware correctness.
