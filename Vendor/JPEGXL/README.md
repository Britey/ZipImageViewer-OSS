# JPEG XL cache encoder

This directory is shared by the iOS and Android apps. Both compile the same `Sources/JPEGXLBridge` encoder bridge. The iOS Swift package uses the XCFramework described below; Android builds the pinned upstream codec from source with CMake/NDK. Run `./android/vendor/bootstrap-jpegxl.sh` from the repository root before an Android build. See the [Android codec guide](../../android/vendor/README.md) for its decoder, dependency bootstrap and memory policies. The Apple binaries are not included in Android packages.

## Apple binary and source provenance

The rebuilt XCFramework contains libjxl 0.13.0 and Brotli 1.2.1, targeting iOS 18.1. Its device library contains arm64; its simulator library contains arm64 and x86_64. The release sources, generated headers, notices and archives are pinned or hashed below. This build used Xcode 27.0 (27A266a), Apple Clang 21.0.0 (clang-2100.3.34.2), CMake 4.5.1 and Ninja 1.13.2. The superseded 0.12.0 framework was built with Xcode 26.2/Apple Clang 17, CMake 4.4.3 and Ninja 1.13.2. [Historical 0.12.0 source](https://github.com/libjxl/libjxl/tree/a7a9c787341cf703dede03c2009fa460cae5e5df)

The Android bootstrap and the Apple **rebuild recipe** select libjxl 0.13.0 at `5a7da83447212fe4900fc29ce97430b881caa67e`. On Apple, the recipe compiles the three upstream gitlinks listed below. skcms objects are compiled into `jxl_cms`. The app uses UIKit/Image I/O to display stored pages. [Release notes](https://github.com/libjxl/libjxl/releases/tag/v0.13.0) · [Upstream dependency tree](https://github.com/libjxl/libjxl/tree/5a7da83447212fe4900fc29ce97430b881caa67e/third_party)

| Apple build input | Revision |
| --- | --- |
| Brotli 1.2.1 | `db24a98aed38a16de78cc05ca15cdd8dc2a0d92d` |
| Highway | `457c891775a7397bdb0376bb1031e6e027af1c48` |
| skcms | `96d9171c94b937a1b5f0293de7309ac16311b722` |

The rebuild preserves libjxl's license, authors and patents, both Highway licenses, the Brotli and skcms licenses, and the MIT notice for the adapted Xorshift128Plus implementation. The app ships their complete texts in `JPEGXL-Licenses.txt`. [Adapted code](https://github.com/libjxl/libjxl/blob/5a7da83447212fe4900fc29ce97430b881caa67e/lib/jxl/xorshift128plus-inl.h) · [Original MIT notice](https://github.com/vpxyz/xorshift/blob/5dc8bfcde1b2652bd36841343d02a270d8452d43/LICENSE)

## Mac rebuild and verification

1. Use a clean checkout of the **private staging branch** on the build SSD. Match its `git rev-parse HEAD` to the Linux handoff commit. Install the project's Node/npm and Ruby versions, Xcode with the iOS SDK and an available simulator runtime, Python 3, CMake and Ninja. Verify the installed tools and the current binary first.

   ```sh
   xcodebuild -version
   xcrun clang --version
   cmake --version
   ninja --version
   (cd Vendor/JPEGXL && shasum -a 256 -c SHA256SUMS)
   xcrun simctl list devices available -j
   ```

2. Reuse a compatible installed iPhone or iPad on iOS 18.1 through the selected SDK. Check its `dataPath` in the simulator listing and inspect the mounted volume using `df -h "/path/from/dataPath"`. If none exists, first confirm the physical CoreSimulator device-set directory is on the build SSD using `df -h "$HOME/Library/Developer/CoreSimulator/Devices"` (or the actual configured device-set path). Create at most one device there using an installed device type and runtime. Use the selected UDID for the run below.

3. From the repository root, rebuild the framework. The script uses a fresh directory under `JPEGXL_BUILD_ROOT` for each invocation and prints its physical location. It builds three architectures separately, compares simulator headers and uses `lipo` to combine the simulator pair. Before installing the result it checks the plist, actual archive architectures, version headers and full static linking against the iOS 18.1 target for each architecture. It regenerates the source notices, combined app resource and checksums alongside the candidate.

   ```sh
   JPEGXL_BUILD_ROOT="$PWD/build/codec-rebuild" Vendor/JPEGXL/Scripts/build-xcframework.sh
   (cd Vendor/JPEGXL && shasum -a 256 -c SHA256SUMS)
   ```

4. When updating the verified framework version, update the new policy strings in `ZipImageViewer/ArchiveImport/ExtractedImageProcessor.swift` and the matching expectation in `ZipImageViewerTests/ExtractedImageProcessorTests.swift`. The current policies use `libjxl-0.13.0-`. Keep pre-existing cached pages readable. Update the current-binary status and measured tool versions in this README and the Apple packaging description in the root third-party notices. Preserve accurate historical dates/versions in the recorded provenance.

5. Build the unsigned Release device app and run the named normal fixtures on the existing simulator. Replace `EXISTING_UDID` with the chosen device. Xcode processes a single destination with parallel testing disabled. The optional tablet UI run requires explicitly setting `IOS_TABLET_SIMULATOR_ID` to another existing compatible tablet.

   ```sh
   npm ci
   bundle install
   bundle exec pod install
   IOS_PHONE_SIMULATOR_ID=EXISTING_UDID IOS_CODEC_FIXTURE_TESTS_ONLY=1 ./scripts/verify-ios.sh
   ```

   The focused run executes a linked version probe on the simulator (libjxl encoder/decoder 13000 and Brotli encoder/decoder 0x1002001). It checks exact JPEG reconstruction, PNG dimensions/orientation/profile and large images, real ZIP/CBZ imports, plain and encrypted LZMA/LZMA2, PPMd, Unicode passwords and filenames, solid archives and cached reopen. It compares all app and archive-wrapper notice files against the built device and simulator app contents, including the combined JPEG XL notices and full Unicode ConvertUTF text.

6. Record the recipe commit, compiler/SDK versions, archive SHA-256s, fixture test counts, package checks, and the logs/xcresult under `build/ios-verification/`. Inspect `git diff --check` and `git status --short --untracked-files=all` before recording the rebuilt binaries, headers, licenses, checksums, policy IDs and documentation together on the private staging branch. Use the repository-local Britey noreply identity for both author and committer and verify the resulting commit metadata before any push.

## Publication history gate

Replacing the files at the tip leaves the old archives reachable through parents. After a separately approved publication plan, prepare a clean publication repository from the verified source tree and rebuilt Apple artifacts, with fresh history for `main`. Recreate the intended `cozy-reading-ui` differences on this clean base from a reviewed tree diff. Verify both candidate trees with the same dependency, archive, image and packaging checks. Import only approved source trees and refs into the fresh object database. Keep the private staging history, generated pull-request refs, caches and old binaries outside the candidate repository.

Before publication, enumerate every candidate branch/tag/ref, walk every reachable commit tree and check all embedded archives and any LFS/release artifacts against the approved rebuilt hashes. Include renamed files. Reject either old Git blob below anywhere in `git rev-list --objects --all`. A fresh clone of the candidate should pass the same checks. Existing server-generated or hidden refs can retain old objects, so changing the current repository's visibility would require a separate server-side retention and access audit. This handoff performs no history or visibility changes.

| Old slice | Git blob ID | SHA-256 |
| --- | --- | --- |
| arm64 iOS | `913af0982889b9fd552731538a9943c8581ca281` | `c9c966008252f0be17ec93ad36d228860bee5e017a342c8a3abc6d4083f02a0f` |
| arm64/x86_64 simulator | `b966e7db0619e50cb6c467784a1787f644052947` | `7d263558f766b42565660311e953d9bbe6f4ab78958afcef9f4545cfd4ed7846` |

## Bridge behavior

`JPEGXLBridge` exposes bounded, single-threaded operations with separate memory policies. JPEG recompression preserves the original JPEG bitstream and uses no Swift RGB conversion buffer. PNG conversion uses chunked pixel input and bounded output callbacks at distance 0.5, effort 3, retaining source dimensions/orientation and RGB ICC profiles; pixels are composited onto white. The input callbacks reference the existing packed RGB buffer instead of handing the encoder another complete copy. Output mode 0 retains compatibility with native iOS 18.1 decoding.

The custom allocator permits up to 1280 MiB for JPEG repacking and 384 MiB for pixel encoding, reduced by the caller's current memory allowance. These are ceilings, not reservations or total-process guarantees: JPEG coefficient vectors use standard allocations outside that allocator, and ImageIO owns decoder scratch. The Swift policy accounts separately for coefficients, input/output buffers, PNG pixel preparation and candidate validation. Its per-phase ceilings are 1536 MiB for JPEG and 512 MiB for PNG, with at least 64 MiB left below the advisory app allowance reported by `os_proc_available_memory()`. Simulator uses the fixed ceilings because it does not supply the device jetsam allowance; injected-pressure tests cover fallback behavior.

ImageIO source/context buffers are released before PNG encoding, and encoder/output buffers are released before replacement decoding. Processing accepts at most 32 MP and 128 MiB input files, retaining oversized/16-bit/animated inputs. Tests verify actual conversion and native reopening at 12/24/32 MP, exact JPEG reconstruction, and a 24 MP PNG larger than the old 64 MiB file limit. Measure actual process memory on target devices separately.

Cancellation is checked between operations. Candidates must natively decode and save both 5% and 16 KiB including previews, with no allocated-size increase. Budget exhaustion or an unprofitable candidate retains the original. Encoding itself is synchronous; cancellation takes effect after the current bounded image operation.

The JPEG reconstruction entry point exists for exact-byte regression tests. This is separate from decoded RGB equality across different decoders, which is not guaranteed by JPEG bitstream preservation.
