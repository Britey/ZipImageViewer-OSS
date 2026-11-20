# Encrypted 7z implementation plan


## Objective and scope

Allow a user to select a single encrypted `.7z` archive, enter its password, and view its images using the existing viewer. Support both encrypted file contents and encrypted archive headers/filenames. Preserve ordinary 7z, ZIP, and CBZ behavior.

The initial supported set is single-volume archives using LZMA/LZMA2, with solid and non-solid compression, and the existing JPG/JPEG/PNG image types. Test additional methods such as PPMd during validation, and document actual results rather than assuming all 7z variants work. Split volumes, archive creation, password storage, and opening individual images before extraction finishes are separate features.

Recommended approach: validate PLzmaSDK, then replace SWCompression's 7z path with a small adapter around it. Use the same decoder for encrypted and ordinary 7z files. Retain the existing ZipArchive backend for ZIP/CBZ.

## Current code and implications

| Location | Current behavior | Planned change |
|---|---|---|
| `ViewController.swift`: `documentPicker(_:didPickDocumentsAt:)` | Acquires file access, copies the archive, and starts extraction synchronously | Keep access valid throughout background copying; start an owned import operation |
| `handle7zFile` | Loads the archive into `Data`, opens it with SWCompression, and reports encryption as unsupported | Call the new file-based 7z extractor |
| `extractImageEntries` | Receives decoded entries in memory and writes supported images | Filter metadata and extract selected entries to validated file destinations |
| `promptForArchivePassword` / `promptForRetryPassword` | Secure entry exists; whitespace is trimmed; retry is tied to ZIP | Reuse the dialog presentation with an explicit submit/cancel result and format-independent completion |
| `prepareExtractionDirectory` / `clearWorkDirectory` | Deletes shared working output | Introduce per-import staging and wait for workers to stop before deleting their files |
| `lastOpenedArchiveSignature` | Enables reuse of the last successful extraction | Publish a signature only with completed output; prevent stale completion callbacks from publishing |
| `collectImageFiles` / `sortImageURLs` / `presentImageViewer` | Supplies the existing image viewing flow | Reuse after successful extraction; verify regular files and preserve date metadata where available |
| Unit/UI test targets | Primarily generated placeholders | Add real archive fixtures, importer tests, and focused UI coverage |

The inspected project uses Swift 5 language mode and the installed Xcode is 26.2. PLzmaSDK's current manifest declares Swift tools 6.1 and supports Swift 5/6 language modes; actual project integration still needs a build. [Package manifest](https://github.com/OlehKulykov/PLzmaSDK/blob/master/Package.swift)

There are pre-existing local changes to the Xcode project and package lockfile. Preserve them when implementing the dependency change; do not reset or regenerate them blindly.

## Milestone 1: prove the dependency — 0.5–1 day

Create a small validation harness before changing the app's import flow. This can be a temporary test target/package using the same toolchain. Choose a release or commit explicitly, and record its version, revision, bundled SDK version, and required build settings.

PLzmaSDK documents Swift/iOS integration, encrypted headers and contents, file streams, and progress/cancellation. These are reasons to evaluate it, not completed compatibility evidence. [Upstream documentation](https://github.com/OlehKulykov/PLzmaSDK)

Validation tasks:

1. Resolve and build the candidate for the installed simulator and a generic iOS device in Release configuration. Run the extraction cases on a simulator and a physical device when available; record any unverified device work explicitly.
2. Use independently generated archives, ideally created with official 7-Zip, and compare extracted bytes against known source images.
3. Cover unencrypted, content-encrypted, and header-encrypted archives; correct/missing/wrong passwords; Unicode passwords; passwords with surrounding spaces; and solid archives.
4. Record the exact outcomes of archive opening and extraction: Boolean result, exception code, stage, and whether item encryption metadata is available.
5. Check selected-item extraction, output-stream behavior, metadata preservation, and cancellation while opening and while extracting.
6. Measure elapsed time and peak memory for a representative large image archive. Check the actual supported compression methods with fixtures.
7. Inspect the bundled native SDK revision against upstream fixes and select or update the dependency accordingly. Record license notices from the exact version shipped.

**Important API details:** the inspected `open()` and extraction methods return `Bool` and can also throw. Every call must check both channels. `abort()` invalidates the decoder, so retries require a fresh instance. Delegate lifetime and cancellation must remain valid until native work returns. [Decoder source](https://github.com/OlehKulykov/PLzmaSDK/blob/master/swift/Decoder.swift)

**Decision gate:** continue if the target archives decode correctly, simulator/device builds work, and missing-password failures can be handled without falsely treating every broken archive as encrypted. If error reporting is too coarse, assess a narrow wrapper patch. If the native engine itself is incompatible, move to the fallback below before building the UI around it.

Deliverable: a short compatibility report with build commands, exact versions, fixture results, observed error mapping, and performance measurements.

## Milestone 2: implement the extraction service — 1–2 days

Suggested files, with names adjustable during implementation:

| File | Responsibility |
|---|---|
| `ZipImageViewer/ArchiveImport/SevenZipExtractor.swift` | Own the native decoder, enumerate entries, extract selected images, report progress, and map failures |
| `ZipImageViewer/ArchiveImport/ArchiveImportCoordinator.swift` | Own one active import, attempt IDs, staging directories, retries, cancellation, and successful cache publication |
| `ZipImageViewer/ArchiveImport/ArchiveImportTypes.swift` | App-owned request, result, progress, and failure types |
| `ZipImageViewer/ArchiveImport/ArchiveOutputPolicy.swift` | Validate destinations, reject collisions/unsafe paths, and track output limits |

Keep native library types inside the extractor. The conceptual request consists of an archive URL, optional password, unique staging directory, configured limits, and progress/cancellation support. The result contains completed image URLs and relevant metadata. UI code should not need to understand native exception types.

Extraction sequence:

1. Create a new decoder using a file input stream. Set the supplied password before opening when present.
2. Open the archive and check both its return value and thrown errors.
3. Enumerate metadata and choose supported image entries. PLzmaSDK exposes item encryption and directory flags; verify the exact metadata needed for the selected version. [Item source](https://github.com/OlehKulykov/PLzmaSDK/blob/master/swift/Item.swift)
4. If selected content needs a password, return to the coordinator so the UI can request one. Do not block a native callback waiting for UIKit.
5. Validate all chosen output paths before creating files. Extract the chosen set in one operation where practical, avoiding repeated traversal of solid compression blocks.
6. Stream output to files. Prefer explicitly controlled file destinations if directory extraction does not enforce the app's output policy. Verify file-descriptor behavior before creating thousands of output streams at once.
7. Treat any failed native operation as failure even if partial images exist. Restore entry timestamps when available so the existing date-sort options remain useful.
8. Return only after streams have closed, output has passed validation, and at least one supported image exists.

Output policy:

- Reject absolute paths, traversal components, invalid names, and destinations outside the staging root. Reject rather than silently rewriting hostile names.
- Check duplicate destinations, including collisions caused by filesystem case/normalization rules.
- Create only ordinary image files and necessary directories. Do not restore links or special filesystem objects; if metadata cannot distinguish them, use controlled regular-file output streams and verify the resulting behavior.
- Require collected results to be regular files within the successful output directory.
- Set configurable entry-count, per-file, and total-output limits, check available disk space, and handle write failures. Choose default thresholds using representative collections and device measurements.
- Do not assume output-size limits bound decoder memory. Validate whether the native layer exposes dictionary/allocation limits; record the remaining resource limitation if it does not. iOS process termination cannot be treated as a normal catchable extraction error.

App failures should distinguish cancellation, password required, password-or-damaged-data ambiguity, unsupported archive features, invalid/corrupt archive, unsafe output, resource/storage failure, and no supported images. Use a definitive “incorrect password” classification only where the backend actually provides reliable evidence. Avoid classifying failures by brittle matching against arbitrary exception prose.

## Milestone 3: connect the UI and import lifecycle — 1–2 days

Use a small explicit state machine:

`idle → copying → opening → extracting → finalizing → viewing`

`opening/extracting → awaitingPassword → opening with a new attempt`

`any active stage → cancelling → idle`, or `failure → idle` after cleanup.

Password behavior:

- Try opening without a password first.
- With readable headers, inspect selected-item encryption and request a password when necessary.
- With encrypted headers, use the failure mapping established in the spike to request a password before listing images. If the public API cannot identify that condition, add a narrow bridge improvement or a user-selected “Try password” action for ambiguous open failures rather than asserting encryption.
- Pass input exactly as entered: no trimming or Unicode normalization. Represent Cancel separately from a submitted string, including an empty string; verify empty-password semantics with the backend.
- For an ambiguous encrypted-data failure after submission, explain that the password may be incorrect or the archive damaged, and allow retry or cancel. Disk errors and unsupported codecs should not start a password retry loop.
- Keep passwords scoped to the operation, never in persistent preferences or logs. Release references after success/cancellation; do not promise secure erasure of Swift string storage.

Execution and ownership:

- Run synchronous native decoding on a dedicated background queue/worker. Merely wrapping a blocking call in a main-actor `Task` does not make it background work.
- Update UIKit on the main actor. Retain the progress delegate for the operation and throttle updates, for example to approximately ten per second.
- Show honest stages such as “Copying archive,” “Opening archive,” and “Extracting images.” Use indeterminate progress when the backend provides no meaningful percentage.
- Allow one import at a time. Disable conflicting Open/Clear actions while work is active, or explicitly cancel and await termination before another operation begins.
- Connect UI and task cancellation to native abort through a thread-safe handle. Do not queue abort behind the blocking extraction on the same serial worker. Treat cancellation as complete only when native work and file writes have stopped.
- Use operation/attempt IDs to discard late callbacks, including callbacks from an earlier password attempt.
- While copying a document-provider URL in the background, retain security-scoped access until copying finishes. A `defer` in a callback that returns immediately would release it too soon. Do not promise immediate interruption inside an uninterruptible file copy.
- Define background behavior: cancel imports on application backgrounding for the initial implementation, await cleanup where execution time permits, and remove abandoned staging directories on a later launch. Do not promise uninterrupted background extraction.

Staging and cache behavior:

1. Copy the selected source once into a unique import directory; reuse it for password retries.
2. Give each extraction attempt a fresh output directory.
3. Keep the previous successful cache until the replacement import succeeds, where disk space permits.
4. Publish the completed directory and archive signature together through the coordinator, then load/sort images and present the viewer.
5. Remove failed/cancelled output after the worker releases it. Never let partial extraction become a cache hit.
6. Route Clear Cache through the same owner. Clean abandoned staging directories at startup without deleting a current operation's output.

Preserve the app's existing session-level reuse of extracted images. This feature does not introduce persistent password storage or require a fresh password for every cached reopen. Extracted images remain temporary plaintext files, as in the existing viewer workflow; cleanup must be reliable.

## Milestone 4: validate and finish — 1–2 days

Add small committed fixtures plus a manifest recording creation commands, tool version, test-only passwords, expected image paths, and SHA-256 hashes. Generate fixtures with an independent implementation; do not rely exclusively on encrypt/decrypt round trips through the same library. Keep large performance archives out of Git and provide a reproducible generator.

| Case | Expected result |
|---|---|
| Ordinary LZMA and LZMA2 7z | Same images open without a password dialog |
| Content encryption, readable filenames | Password requested and correct images extracted |
| Header/filename encryption | Password requested before listing; correct images extracted |
| Solid and non-solid archives | Correct output; no repeated per-image decompression strategy |
| Missing/wrong password, then retry | Recoverable prompt; fresh decoder; no published partial output |
| Unicode and surrounding-space passwords | Input is preserved exactly and valid passwords succeed |
| Nested directories and repeated basenames | Paths remain distinct and images are complete |
| Uppercase image extensions and non-image entries | Existing supported-image selection remains consistent |
| No supported images | Clear result distinct from incorrect-password failure |
| Truncated archive / damaged encrypted data | No false success; honest error classification |
| Unsafe paths, collisions, links | No writes outside staging or creation of link/special objects |
| Cancel during open/extract and retry | UI recovers; worker exits; partial output is removed |
| Late progress/completion from old attempt | Cannot update current state or publish output |
| Output limits / write failure / low space | Controlled failure and cleanup |
| Large archive and large dictionary | Record memory, duration, cancellation latency, and supported practical limits |
| Date metadata and filename sorting | Existing viewer sort modes behave consistently |
| Successful reopen and Clear Cache | Valid output reused; cleared output is not reused |
| Encrypted/ordinary ZIP and CBZ | Existing behavior still works after shared UI changes |

Use real backend integration tests for extraction and hashes. Use a controllable fake extractor for coordinator races, delayed cancellation, and storage failures that are difficult to reproduce reliably. Add focused UI checks for password submit/retry/cancel and the busy state. A test-only local fixture entry point can avoid fragile automation of the system Files picker; manually verify the actual picker and document-provider access on device.

Release checks:

- Run the relevant unit/integration tests and focused UI tests on an available simulator.
- Build Debug and Release for simulator and generic iOS device; perform an actual signed device run separately.
- Exercise a representative large archive and one real encrypted collection on physical hardware. Record device model, OS, archive sizes, dictionary settings where known, peak memory, and elapsed time.
- Inspect dependency changes and include the exact shipped library's notices. Verify the bundled SDK version, not only the wrapper version.
- Remove the SWCompression import and package reference if a repository-wide usage check confirms it is no longer used. Let package resolution remove orphaned transitive dependencies; avoid unrelated package upgrades.
- Document any remaining codec/resource/volume limitations explicitly.

**Done means:** encrypted contents and filenames both work for the defined supported set; correct bytes reach the viewer; retries and cancellation are recoverable; UI remains responsive during decoding; partial output cannot be published; ZIP/CBZ and ordinary 7z regressions are checked; build and device evidence is recorded.

## Delivery order and estimates

| Change set | Reviewable outcome |
|---|---|
| A. Dependency validation | Pinned candidate, minimal extraction harness, fixture evidence, compatibility decision |
| B. Extraction backend | File-based adapter, safe output policy, actual archive integration tests |
| C. App integration | Password flow, worker/coordinator ownership, staging, progress, cancellation |
| D. Completion | Device/performance evidence, lifecycle regressions, dependency cleanup, notices and documentation |

Changes should remain buildable at each step; wire the viewer to the new backend after its basic integration tests pass. No runtime dual-engine fallback is required initially.

For an experienced Swift/iOS developer, budget approximately **4–7 focused working days** if the dependency validates cleanly. A basic end-to-end demonstration may be available in **1–2 days**, before lifecycle and failure-path coverage is complete. Milestone estimates total 3.5–7 days and are rounded for planning. These are effort estimates, not guaranteed calendar delivery dates.

The estimate assumes one active import, no split-volume UX, the existing image formats/viewer, and access to a physical device. Native wrapper patches, difficult dictionary-memory controls, uncommon codec requirements, or missing device access can extend the schedule. Re-estimate after Milestone 1 using measured results.

## Fallback if PLzmaSDK is unsuitable

First determine whether the problem is packaging/error exposure or decoding itself. A small maintained fork may be cheaper than replacing a working engine; pin and test any patch and document ongoing update ownership.

If necessary, integrate the relevant C++ 7z decoder and encryption components from the official LZMA SDK behind a narrow C or Objective-C++ bridge. The official SDK contains reduced C++ 7z support and AES code; a basic LZMA decoder alone is insufficient. [Official SDK](https://www.7-zip.org/sdk.html)

Expose the same app-owned extraction interface so the password UI, coordinator, staging, and tests remain useful. Expect roughly **2–4 weeks total effort** for this route, subject to a revised scope after investigating the native build and codec requirements. Budget for maintaining upstream native-code updates as well as the first integration.

Do not start by implementing 7z parsing, password derivation, and decryption from scratch. Also do not replace SWCompression with libarchive expecting that to fix encryption: its documented passphrase support is ZIP-only. [libarchive manual source](https://github.com/libarchive/libarchive/blob/master/tar/bsdtar.1)
