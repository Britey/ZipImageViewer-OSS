# Android JPEG XL source bootstrap

Run `./android/vendor/bootstrap-jpegxl.sh` once before the Android Gradle build.
It checks out libjxl **0.13.0**, revision
`5a7da83447212fe4900fc29ce97430b881caa67e`, and exactly the Brotli, Highway,
skcms, libpng and zlib revisions recorded in that commit's gitlinks. The
shared Android/iOS pin is in `Vendor/JPEGXL/Scripts/source-pins.sh`. The
checkout is ignored; no downloaded object files are committed. A subsequent
build is offline once this checkout and the normal Android dependencies exist.
No dependencies are selected by a moving branch or latest-version URL.

The root CMake file builds the libraries from source for x86_64 and arm64-v8a,
Android API 28+, NDK 27.1.12297006, aligned with the pinned React Native C++
runtime in the app's Gradle configuration. Upstream's pinned Android build workflow is
`.github/workflows/build_test.yml` in the checkout. CMake Ninja pools cap each
build at three compile jobs and one link job; do not launch concurrent ABI
builds on memory-constrained hosts. The shipping JNI shared library uses
16KiB-compatible ELF segment alignment. Native tools, benchmarks, tests,
viewers, JPEG XL JNI wrappers and optional image libraries are disabled;
libpng and skcms are enabled for source PNG decoding and color management.
No upstream libjxl or dependency source patches are applied.

`Vendor/JPEGXL/Sources/JPEGXLBridge/JPEGXLBridge.cpp` is the existing project
bridge reused verbatim. JPEG repacking preserves reconstruction metadata;
PNG encoding uses original-resolution 8-bit RGB, ICC/orientation, distance
0.5 and effort 3. Android's adapter adds libpng decoding, alpha compositing
on white, bounded JNI file IO, full candidate validation and scanline-based
bounded Bitmap rendering with skcms output to Display P3.

Runtime policy is separate from the codec: the repository decides admission,
minimum source size, savings and allocation profitability, fallback, atomic
publication, cancellation before/after a synchronous codec operation, and
cache accounting. A codec call cannot currently be interrupted mid-image.
The custom allocator accounts libjxl and decoder accumulators; source/output
vectors, libpng, ICC/CMS and runtime overhead require additional admission.
`EncodeResult.peakCodecBytes` reports custom allocator usage, **not process
RSS**. The decoder uses at most 16 bytes per output pixel for resampling
accumulators, charged inside its supplied codec budget, plus the separately
allocated 4-byte output bitmap and compressed input. It never allocates a
full-resolution output bitmap solely to resize it.

`app/src/main/assets/THIRD-PARTY-NOTICES.txt` and the corresponding license,
author and patent files are distributed in the APK, including
`JPEGXL-Xorshift128Plus-MIT.txt` for libjxl's adapted Xorshift128Plus code. Upstream source notices
remain intact in the ignored checkout. After assembling the APK, compare its
notices with the pinned sources and checked-in assets from the repository root:

```sh
python3 android/scripts/verify-codec-notices.py android/app/build/outputs/apk/debug/app-debug.apk
```

Test image generator and provenance:
`app/src/main/cpp/tests/generate-codec-fixtures.py` and
`app/src/androidTest/assets/codec-fixtures/README.md`.

Tests: run `NativeJpegXlInstrumentedTest` for format, reconstruction, color,
orientation, alpha, validation and failures. Run `NativeJpegXlLargeImageTest`
separately for 12/24/32MP source-size and reader budget probes. Large images
are generated on-device and removed, rather than stored in the APK.
