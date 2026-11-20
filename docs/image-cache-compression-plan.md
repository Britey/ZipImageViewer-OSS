# Optional compression of extracted images

> Historical design proposal. See [the JPEG XL implementation notes](../Vendor/JPEGXL/README.md) for the current codec and constraints.


## Recommendation and feature contract

Add **Compress extracted images**, default **off**, to Settings → Storage. This is useful for large photographic PNGs and lightly compressed JPEGs, but savings and visible loss depend on the content. Manga linework, small text, gradients, and colored edges need particular visual testing.

Use these rules for the first release:

- Off means byte-for-byte preservation of extracted page files, with no image inspection or encoding work.
- On applies when a new cache is built, after successful extraction and before publication. ZIP, CBZ, and 7z use the same processor.
- Convert eligible still images at their original pixel dimensions to JPEG quality 92, only when the replacement saves space.
- Preserve already lower/equal-quality JPEGs, unknown-quality JPEGs, animation, and formats/color representations that cannot be converted safely. Transparency does not exclude a PNG: composite transparent areas onto white before JPEG encoding.
- Original archives are never edited. Compression changes only disposable import output that will become a cached copy.
- Existing caches are reused without conversion, even after changing the switch. Turning it off cannot restore detail already discarded from a compressed cache. A genuinely new extraction uses the current setting; selecting an already cached archive still reuses that cache.
- To preserve transparency for one archive, turn compression off, import it, and turn compression back on. That archive's retained cache stays unchanged. This uses the global switch; no separate per-archive control is needed. If iOS purges that cache, a later extraction uses the then-current setting, so turn it off again before rebuilding that archive.
- No automatic cache migration, background recompression, quality slider, or new image-format support in this release. The reader currently supports JPG, JPEG, and PNG.

Suggested setting explanation: “Save space in newly extracted caches using JPEG quality 92. Transparent areas become white. Existing caches are unchanged. May add import time and slightly reduce image quality.” Additional help can explain that unsuitable images and candidates that do not save space stay in their original form.

## Define quality 92 precisely

JPEG does not carry a universal original-quality score. Quantization tables describe the current encoding, not its editing history or actual perceptual quality. PNG is lossless storage, but could itself contain pixels from a previously lossy source. Therefore, the literal rule “any image higher quality than 92” is not reliably decidable for arbitrary files.

Recommendation: define the target as the standard IJG/libjpeg quality-92 quantization tables and use a pinned libjpeg-turbo encoder. Use 4:4:4 sampling for color output to avoid introducing additional chroma subsampling, and grayscale output for grayscale pages. This is a proposed product definition, not a guarantee of imperceptible loss.

Apple Image I/O exposes a floating-point compression setting from 0 to 1, but does not document `0.92` as equivalent to IJG quality 92. Using it would be simpler, but would require explicitly redefining the requested quality scale. Do not silently equate these two settings. See [Apple's compression-quality API](https://developer.apple.com/documentation/imageio/kcgimagedestinationlossycompressionquality).

For input JPEGs, read quantization tables and component assignments through the codec header API. Match all used luminance/chrominance tables against standard tables generated for quality values 1–100. Accept only unambiguous supported matches above 92; if separate component qualities are present, require every used component's matched quality to exceed 92. Skip custom tables, ambiguous matches, unsupported component layouts, and malformed files. This deliberately misses some high-quality JPEGs instead of recompressing uncertain ones. More encoder profiles can be added later with fixtures. Standard-table matching is an encoding classification, not a perceptual assessment; see [research on recovering standard quality factors](https://arxiv.org/abs/1802.00992).

## Eligibility and replacement rules

| Input | Action when enabled |
| --- | --- |
| Supported 8-bit still JPEG, all recognized component qualities >92 | Encode a candidate at quality 92. |
| JPEG with a component quality ≤92, custom/unknown tables, or unsupported JPEG features | Keep original bytes. |
| Supported still PNG, including palette/grayscale images and images with transparency | Encode a candidate; composite alpha onto white, including palette transparency. No opacity-based eligibility scan is needed. |
| APNG, multi-image JPEG/MPO, gain-map/HDR content | Keep original to avoid dropping frames or auxiliary information. |
| High-bit-depth, unsupported CMYK/color profile, excessive dimensions, or corrupt image | Keep original; preserve the reader's existing unavailable-page behavior where applicable. |
| Valid candidate with no meaningful storage saving | Delete candidate and keep original. |

Inspect actual file type and image properties rather than trusting the extension. Be conservative when auxiliary-image/animation detection is inconclusive.

Start with a replacement threshold of at least **5% and 16 KiB** lower logical file size, and require no increase in measured allocated bytes. These are tunable proposed defaults, not measured results. Log both sizes during validation; allocated-block savings, not just JPEG byte counts, determine cache-budget usefulness.

Preserve the displayed orientation exactly once: preferably normalize pixels and write orientation 1, testing all eight EXIF orientations. Preserve a compatible embedded color profile or a tested equivalent representation; skip unsupported profiles instead of silently stripping them. Keep useful resolution metadata. Avoid blindly copying stale thumbnails, dimensions, offsets, or format-specific metadata. Preserve original filesystem creation/modification dates and original logical sort metadata.

## Current architecture and insertion points

- `ArchiveService.prepareArchive` hashes the source and reuses a cache before copying. `ArchiveService.extract` handles ZIP/CBZ (and a service-level 7z path), collects files, then calls `ArchiveCacheStore.publish`.
- The main 7z UI path uses `ArchiveImportCoordinator`. It checks cache reuse, extracts on a worker, validates output, then publishes with cancellation support.
- `ArchiveCacheStore.publish` currently validates/copies files under its private serial queue, generates a cover, records allocated bytes, commits a manifest/catalog, acquires a reader lease, and applies eviction.
- Sorting currently uses physical filenames and file dates. Reading progress identifies a page by the physical relative path. PNG-to-JPEG renaming therefore requires explicit identity handling.

Add the processor immediately before publication in both import owners, outside the cache store's serial queue. This keeps encoding from blocking cache reads, progress saves, or reader lease release.

## 1. Preference and operation snapshot

Extend `ArchiveCachePreferences` with `compressExtractedImages: Bool = false`.

- Add explicit backwards-compatible decoding using `decodeIfPresent(... ) ?? false`. A stored-property default alone does not make synthesized Codable tolerate a missing required key. Preserve existing byte/count limits when upgrading old preferences.
- Add the switch with accessibility identifier `compressExtractedImages` in the Storage section. Keep it out of Reader Settings, matching the existing storage separation.
- Wire it through `onStoragePreferencesChange` and the existing persistence path. Toggling compression alone must not trigger the lower-cache-limit confirmation or schedule a rewrite. Disable it during import/storage mutation consistently with adjacent controls.
- Capture an immutable compression policy when an import begins, before copying or requesting a password. Store it in `ArchiveService.Request` and the coordinator's `Operation`; password retries use that same snapshot.
- Direct/test import entry points also receive an explicit policy, with default-off defaults for source compatibility.

## 2. Shared processor and codec boundary

Add `ArchiveImport/ExtractedImageCompressor.swift`, a small policy/result model, and a narrow native codec adapter.

The processor accepts validated page inputs, their trusted extraction root, an immutable policy, cancellation checks, and a progress callback. It returns prepared pages plus aggregate statistics: attempted/converted/skipped counts and before/after bytes. Inject the encoder and filesystem operations needed for meaningful failure tests.

For each page:

1. Check cancellation and validate root containment, regular-file status, and symlink-free ancestry before reading image content.
2. Inspect headers and apply eligibility/size/memory checks before decoding pixels.
3. Decode only one page, composite alpha onto white when present, and encode to a uniquely created sibling temporary file within the operation workspace. Use correct premultiplied-alpha compositing so translucent edges do not acquire dark fringes.
4. Finalize the JPEG; reopen it with Image I/O and verify type, dimensions/orientation, expected color representation, and successful decoding. Verify the quality tables in codec tests rather than inferring success from the extension.
5. Compare sizes. If accepted, move the complete candidate into its reserved final staging path, update the page record, and only then remove the superseded extracted file. If rejected, delete the candidate.
6. Release decoder/encoder/pixel resources in a per-page scope and publish throttled progress.

An unsupported input or codec failure falls back to the original and allows other pages to continue. Cancellation must propagate rather than being swallowed as a skip. A filesystem failure that prevents safe cleanup or reliable preservation/publication fails the operation; do not turn it into a password retry. Preserve the copied source archive for existing password retry semantics only.

Use a pinned reproducible iOS/device/simulator build of libjpeg-turbo, with license notices and a documented update procedure. Keep native error handling entirely inside a C wrapper: codec failures must return typed results rather than aborting the app or jumping across Swift frames. File output and scanline processing should avoid holding a second complete encoded image in memory. The library documents header, scanline, error-handling, and ICC APIs in its [official integration guide](https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/doc/libjpeg.txt).

## 3. Stable page identity and schema compatibility

Introduce a page descriptor with:

- `originalRelativePath`: stable identity and filename-sort key from the archive.
- `storedRelativePath`: actual cached filename with the correct `.jpg`/`.jpeg`/`.png` extension.
- Original creation/modification dates, preserving nil when absent.
- Optional original/stored byte counts and conversion outcome if useful for diagnostics.

Reserve every existing extracted path before assigning conversion filenames. Keep JPEG paths unchanged when possible; for converted PNGs, try a derived `.jpg` name and resolve collisions deterministically with a suffix. Check collisions case-insensitively, including directory/file conflicts and names such as `page.png`, `page.jpg`, and `page.png.jpg`. Never overwrite another page. The logical identity stays `page.png` regardless of its stored name.

Use a version-2 manifest and catalog for the page descriptors. Implement explicit v1 readers that synthesize descriptors with identical original/stored paths. Old progress paths then retain their meaning. Upgrade metadata atomically when needed; do not transcode old images. Make startup recovery tolerate a mixture of v1 and v2 entries during interrupted upgrades. Update all schema guards, validation, catalog recovery, and unsupported-newer-version handling together.

`ArchiveReaderSession` should expose immutable page metadata and stored URLs. Its progress-path lookup returns the original path; `saveProgress` validates against original identities. Both initial library opening and in-reader sort changes must sort by original filenames/dates and original-path tie-breaks. Use the same metadata to select the archive cover. Reader rendering and overview thumbnails continue to load real stored URLs.

Keep archive signature calculation unchanged. Compression policy is not part of the cache key in this release because settings apply only to new cache construction. Record the applied policy/encoder version in new manifests for diagnostics, without requiring a match to reopen a cache. Avoid redundant cache variants and repeat lossy encoding.

## 4. Import lifecycle and cache publication

Add a `compressing` stage to `ImportPresentationState` and `ArchiveImportCoordinator.State`; extend `ArchiveImportProgress.Stage` only where shared callbacks need it. Audit every exhaustive stage switch, including the service's fallback 7z mapping.

- ZIP/CBZ: extract → enumerate/validate → compress → publish. Preserve current non-cancellable ZIP UI behavior; making all ZIP extraction cancellable is separate work.
- 7z: extract → validate → compress → finalizing/publish. Report compression from the operation worker, check operation/attempt identity when delivering callbacks, and ignore stale callbacks after cancellation or completion.
- Progress text: “Compressing images…” with current-page/total progress, throttled to avoid flooding the main actor. Compression is its own stage, not a fabricated continuation of extraction's percentage.
- Keep 7z cancellation effective between pages and during codec scanline work. Some Image I/O decode calls cannot be interrupted; cancellation must wait for those calls to return before deleting their files.
- Preserve the existing durable-publication cancellation cutoff. Cancellation before commit cleans the operation and cache staging; cancellation after commit cannot invalidate a successfully published reader session.

`ArchiveCacheStore.publish` takes the prepared descriptors, independently validates their paths, copies selected final files, and derives the thumbnail from the final representation. Its byte preflight uses actual prepared file sizes. Cache size, oversized-temporary decisions, and LRU eviction use the final allocated footprint, including manifests and thumbnails. Existing leases and failed-import protections remain intact.

Do not move encoding into extraction callbacks: completion/CRC validation and password handling should finish before transformation, and the shared post-extraction pass must behave identically for both archive engines.

## 5. Memory, disk, and failure limits

- Process serially off the main actor. No task per image and no archive-wide array of decoded images.
- Add overflow-safe dimension, pixel-count, and decoded-byte estimates before allocation. Proposed starting caps: 32 megapixels and a 256 MiB estimated conversion working set, reduced if physical-device profiling requires it. Include decoder, destination pixels, encoder buffers, and validation decode in the estimate; release encoding buffers before validation decoding.
- Keep the original page when it exceeds conversion limits; do not downsample to make it fit. Existing extraction limits still apply to original expanded content and must not be relaxed based on hoped-for compression.
- Check available disk with the existing reserve before candidate writes, cap candidate output growth, and stop an unprofitable candidate early where possible. With insufficient scratch space, skip compression if the original can still be published safely.
- Peak storage still includes the compressed source, extraction output, a page candidate, and publication staging. Do not promise this feature fixes low-space extraction failures.
- Never mutate files in an active reader cache. Crash recovery discards orphaned import/candidate/staging files through the existing owned-workspace cleanup rules.

## 6. Validation and acceptance criteria

### Focused automated coverage

- Preferences: fresh install off, v1 preferences missing the new key, persistence across relaunch, existing limits preserved, UI toggle binding, no eviction confirmation for a toggle-only change, operation snapshot survives password retry.
- Codec: deterministic q80/q92/q93/q95/q100 fixtures; baseline and progressive JPEGs; grayscale and separate component qualities; custom/unknown tables; truncated headers; unsupported precision; source-to-output q92 table verification; known lower-quality files remain byte-identical.
- PNG: RGB, grayscale, indexed palette, opaque alpha, partial transparency, palette transparency, APNG, high-bit-depth, and misleading extensions. Test a photographic PNG that shrinks and a small/line-art PNG whose candidate is rejected.
- Fidelity: all EXIF orientations, dimensions, supported ICC profiles, resolution metadata, and white-background alpha compositing (including partially transparent antialiased edges and fully transparent pixels). Golden fixtures exercise text edges and grayscale, not only photographs.
- Naming/identity: colliding extensions, case-only conflicts, nested duplicate filenames, preserved filename/date sort order both directions, cover selection, resume after sort/relaunch, and original progress identity after a purged cache is rebuilt under a different policy.
- Publication: final allocated-byte accounting, compressed archive now fitting the cache budget, unchanged oversized behavior, no premature eviction, reader leases, corrupt catalog recovery, mixed v1/v2 startup, unknown-schema protection, and failures before/after durable commit.
- Lifecycle: off bypasses the processor and preserves hashes/transparency; import one archive with compression off, turn it on, and verify that reopening that archive preserves its original cache; enabled ZIP/CBZ/7z and encrypted imports; cache hits never invoke encoding; single-image fallback; cancellation mid-conversion; disk-write/finalize/cleanup failures; stale progress callbacks and no compression error mistaken for a bad password.

Extend the existing preference/settings, import coordinator, ZIP regression, cache store, reading-progress, sorter, and presentation-state suites. Add a focused compressor/codec suite with generated fixtures and recorded generation commands. Update static-check expectations and UI tests that assume the Storage section has four rows.

### Native and visual validation

Run the repository's portable static checker, Debug simulator build, unsigned Release device build, unit/integration tests, and focused UI tests. Review setting layout at large Dynamic Type and with VoiceOver on iPhone and iPad.

Measure imports with the switch off/on on a physical lower-memory supported device, using representative photographic PNG, q95/q100 JPEG, mixed-format manga, and already-compressed archives. Record retained allocated bytes, import duration, peak memory, and cancellation latency. Inspect full-resolution crops at 100% and 200% for text, halftones, gradients, skin tones, and colored linework. Treat perceptual metrics as supplementary; structural similarity alone is not an acceptance guarantee.

Release gates: no changed image bytes when off; no automatic recompression of existing caches; no accepted larger candidate; no lost pages/identity/order/animation; correct white-background compositing when on; no active-cache mutation; default and migrated preferences off; safe failure/cancellation; positive measured space savings on representative eligible archives with acceptable visual results and memory use. Document images skipped by the conservative classifier rather than claiming every high-quality JPEG is recognized.

## Implementation sequence

1. **Codec feasibility spike:** validate reproducible libjpeg-turbo builds, standard-table recognition, q92/4:4:4 output, orientation/profile handling, memory estimates, and a small representative visual corpus. This resolves the largest technical uncertainty before integration.
2. **Identity/schema foundation:** introduce descriptors and backwards-compatible readers, update sorting/progress/cover logic, and prove unchanged behavior with compression off.
3. **Shared processor:** implement eligibility, safe candidate lifecycle, size comparison, resource limits, and focused tests.
4. **Import/UI integration:** wire the default-off setting, snapshot policy, both importer paths, progress/cancellation, and final-byte publication.
5. **End-to-end validation and documentation:** run the matrix above, tune thresholds/caps from measurements, and update README storage/import behavior and validation notes.

The codec and page-identity work make this a medium-sized feature rather than a one-line JPEG save. The conservative scope keeps the default behavior intact while providing a path to measurable cache savings.
