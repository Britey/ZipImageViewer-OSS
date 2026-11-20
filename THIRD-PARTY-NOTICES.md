# Third-party notices

The root [Apache License 2.0](LICENSE) covers first-party material. The components
below keep their upstream terms and attribution.

- [PLzmaSDK 1.6.1 and its LZMA SDK 26.06 subset](Vendor/PLzmaSDK/UPSTREAM.md)
  ships as vendored source. The wrapper is MIT and the shipped SDK subset is
  public domain. Both native builds include the original notices. The optional
  full 7-Zip TAR code is excluded. PLzmaSDK also includes Unicode ConvertUTF,
  whose complete notice is reproduced below and packaged on both platforms.
- Android builds [libjxl 0.13.0](https://github.com/libjxl/libjxl/releases/tag/v0.13.0)
  with Brotli 1.2.1, Highway 1.2.0, skcms (2025-09-16), libpng 1.6.47 and
  zlib 1.3.1. The [APK notice](android/app/src/main/assets/THIRD-PARTY-NOTICES.txt)
  identifies the source revision and each dependency gitlink. The APK includes
  the upstream licenses, authors, patent grant and Xorshift128Plus MIT notice.
- The [Apple XCFramework](Vendor/JPEGXL/README.md) contains libjxl 0.13.0,
  Brotli 1.2.1, and the pinned Highway and skcms sources. Its
  [license files](Vendor/JPEGXL/Licenses/), combined app notice and binary
  checksums describe this rebuilt framework.
- [SSZipArchive 2.6.0](https://github.com/ZipArchive/ZipArchive/tree/df35718ea19a94e015b91dc4881dee028ce4cdba),
  its included minizip, and [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/tree/22787ffb59de99e5dc1fbfe80b19c97a904ad48d)
  are fetched by SwiftPM. The iOS app resources include their MIT and zlib notices.
- React, React Native and react-native-safe-area-context retain their MIT
  notices in [iOS resources](ZipImageViewer/Resources/) and
  [Android assets](android/app/src/main/assets/). The dependency lock files pin
  the development and runtime dependencies.
- Android dependencies and their packaged notices are recorded in
  [the Android notice file](android/app/src/main/assets/THIRD-PARTY-NOTICES.txt).
  The Gradle 8.13 wrapper is a build tool under Apache 2.0; its launchers carry
  original headers and its JAR contains upstream license information. Its digest
  matches the [official Gradle checksum](https://gradle.org/release-checksums/#8.13).

Before distributing an IPA or APK, inspect the actual packaged notices and
include the licenses and attributions required by the resolved native and
JavaScript runtime, including Hermes and transitively bundled components. The
checked-in notices cover the source snapshot and the items identified above.
Keep the exact upstream notices from the build inputs with the release.

## Application assets and test fixtures

- [Launcher artwork](docs/app-icon.md) was generated for this project. The
  iOS and Android PNGs retain their pixels and color information after metadata
  cleanup.
- [The archive fixture manifests](ZipImageViewerTests/Fixtures/SevenZip/manifest.json)
  and [generator](scripts/generate-archive-fixtures.py) record synthetic archive
  content and public test passwords. Android's
  [reader fixture](android/app/src/androidTest/assets/archive-fixtures/README.md)
  is a project-generated archive for instrumentation.
- [Android codec fixtures](android/app/src/androidTest/assets/codec-fixtures/README.md)
  use deterministic synthetic pixels and a project-generated grayscale ICC
  profile. The color fixtures use a Display P3 ICC profile from pinned skcms
  and retain its upstream terms and notice.

## Unicode ConvertUTF

From the [pinned PLzmaSDK source](https://github.com/OlehKulykov/PLzmaSDK/blob/f449bc3e13204b68a7e05fca80ce8c31642085ec/src/plzma_convert_utf.hpp).

```text
/*
 * Copyright 2001-2004 Unicode, Inc.
 *
 * Disclaimer
 *
 * This source code is provided as is by Unicode, Inc. No claims are
 * made as to fitness for any particular purpose. No warranties of any
 * kind are expressed or implied. The recipient agrees to determine
 * applicability of information provided. If this file has been
 * purchased on magnetic or optical media from Unicode, Inc., the
 * sole remedy for any claim will be exchange of defective media
 * within 90 days of receipt.
 *
 * Limitations on Rights to Redistribute This Code
 *
 * Unicode, Inc. hereby grants the right to freely use the information
 * supplied in this file in the creation of products supporting the
 * Unicode Standard, and to make copies of this file in any form
 * for internal or external distribution as long as this notice
 * remains attached.
 */
```
