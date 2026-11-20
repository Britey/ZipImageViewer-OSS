# Vendored PLzmaSDK

This local Swift package is based on [PLzmaSDK 1.6.1](https://github.com/OlehKulykov/PLzmaSDK/releases/tag/1.6.1), commit `f449bc3e13204b68a7e05fca80ce8c31642085ec` (MIT). The original public headers, Swift bridge, native source subset, privacy manifest, and license are retained. The privacy manifest is moved unchanged from `resources/` to `swift/Resources/` so its path is inside the SwiftPM target. A copy of `LICENSE` is bundled alongside it as `PLzmaSDK-LICENSE.txt`. Platform examples and upstream test targets are omitted from the package manifest because the app has independent archive fixtures.

## Native SDK update

PLzmaSDK 1.6.1 bundled LZMA SDK 26.01. This package uses the **26.06 public-domain SDK** released on 2026-11-06. The official release history records security fixes in 26.04 and split-volume changes in 26.06. [SDK release history](https://www.7-zip.org/sdk.html)

The [official SDK archive](https://github.com/ip7z/7zip/releases/download/26.06/lzma2606.7z) matches release asset SHA-256 `1d9da340870b12712e9068be178a4436fbad785486b62aed6e2aa88ea1e3bb65`. The [corresponding 7-Zip tag](https://github.com/ip7z/7zip/tree/d3296e39e1f1f92c7b41c0c3848e65640428d42d) resolves to `d3296e39e1f1f92c7b41c0c3848e65640428d42d`. The SDK archive supplies the native subset and the original SDK notice in `swift/Resources/LZMA-SDK-NOTICE.txt`.

`patches/sdk-26.06.patch` records the cumulative SDK update and wrapper adaptations relative to PLzmaSDK 1.6.1. Changes in the public-domain SDK were merged against the previously shipped subset file by file. The wrapper retains its codec registrars, file-attribute restoration guard and compatibility include for `Defs.h`. It omits the standalone DLL initialization code as in PLzmaSDK 1.6.1. SDK 26.06 moved concatenated-volume reads into its split-file archive handler and removed `CMultiStream`. PLzmaSDK's stream-array API now tracks the end offset of each input volume and delegates reads and seeks to those same file, memory or callback streams. The package keeps the 26.06 split-volume handler.

The wrapper's MIT notice and the full Unicode ConvertUTF notice from its [pinned header](https://github.com/OlehKulykov/PLzmaSDK/blob/f449bc3e13204b68a7e05fca80ce8c31642085ec/src/plzma_convert_utf.hpp) accompany the SDK notice in SwiftPM resources and Android assets.

The optional `src/CPP/7zip/Archive/Tar/` sources from PLzmaSDK 1.6.1 are omitted. They belong to the full 7-Zip source distribution and are outside the public-domain SDK archive. Both platforms define the upstream `LIBPLZMA_NO_TAR=1` switch; the app supports 7z, ZIP and CBZ and has no TAR entry point.

## Password interoperability fix

`patches/unicode-password.patch` fixes the PLzmaSDK password callback on platforms with 32-bit `wchar_t` (including Apple). PLzmaSDK converts Swift UTF-8 to UTF-32, but 7z AES reads UTF-16 units from the callback's BSTR. Without conversion, supplementary characters such as emoji are truncated, and the correct password fails. The callback now expands those scalars into UTF-16 surrogate pairs while preserving all other characters and whitespace. The temporary converted string is wiped using the SDK's existing wipe operation. This does not claim secure erasure of Swift string storage.

This is covered by the independently generated `unicode-password.7z` fixture with test password `密码🔐café`.

## Filename conversion and solid extraction

`patches/unicode-filenames.patch` fixes the reverse UTF-16 boundary for archive names. It validates BSTR code units, rejects embedded NULs or malformed surrogate pairs, then converts the complete UTF-16 name to UTF-8 before creating the PLzmaSDK path. This preserves supplementary characters such as the independently generated `图像🔐.png` fixture. The Swift C-string helper also uses replacement-safe decoding for native diagnostic/progress strings rather than a force unwrap; archive item names are validated before reaching that helper.

`patches/solid-extraction.patch` removes repeated decompression of large solid blocks. The upstream wrapper made one native extraction call per 256 entries. For solid archives, this copy passes the selected set in one call using an owned heap buffer; the app bounds selections to 25,000 images (at most 100 KB of index storage). Non-solid archives retain the existing batches. Streams still open lazily and close per item. A 600-image encrypted solid fixture covers this boundary.

## Reproduce and audit

1. Check out the exact PLzmaSDK commit above.
2. Copy `src/`, `swift/`, `resources/`, `LICENSE`, `libplzma.h`, and `libplzma.hpp` into a fresh directory.
3. Normalize only existing source files named in the `--- a/` lines of the four patches from CRLF to LF; leave other upstream files byte-identical. The patches use normalized LF line endings.
4. Apply all four checked-in patches with `patch -p1 < PATCH_PATH`, in this order: `sdk-26.06.patch`, `unicode-password.patch`, `unicode-filenames.patch`, `solid-extraction.patch`.
5. Remove `src/CPP/7zip/Archive/Tar/`. Use the checked-in `Package.swift`, which disables TAR and omits upstream samples and tests; the Android CMake target also disables TAR.
6. Move `resources/PrivacyInfo.xcprivacy` to `swift/Resources/PrivacyInfo.xcprivacy` and copy `LICENSE` to `swift/Resources/PLzmaSDK-LICENSE.txt`. Copy the verified 26.06 SDK archive's `DOC/lzma-sdk.txt` verbatim to `swift/Resources/LZMA-SDK-NOTICE.txt`. Copy the first comment of `src/plzma_convert_utf.hpp` verbatim, including delimiters and its trailing newline, to `swift/Resources/Unicode-ConvertUTF-NOTICE.txt` (for instance, `sed -n '1,/^ \*\/$/p' src/plzma_convert_utf.hpp`). Copy all three notice/license files from `swift/Resources/` to `android/app/src/main/assets/` at the repository root.
7. `SHA256SUMS` records every shipped package source/header/resource and all four patch files. Verify from this directory using `shasum -a 256 -c SHA256SUMS`.

Do not edit Xcode's package cache. Future upgrades should update this copy, provenance, patches, hashes and archive regression results together.

## Adapter constraints

The app supplies validated, regular-file output streams and never asks the SDK to restore filesystem links or special objects. Streams open lazily and close per item; native close applies archive timestamps. The adapter checks both throwing and Boolean return channels, and creates a decoder per password attempt. Native error codes do not distinguish incorrect passwords, damaged data and unsupported methods, so the UI deliberately describes that ambiguity.

Solid archives now use one native extraction call, avoiding the wrapper's former 256-item repeated block decoding. The app also makes one public extraction call. Entry/output-size and free-disk checks do not cap native dictionary or header allocations. Physical-device memory/performance validation remains necessary, as does release validation for future SDK updates.
