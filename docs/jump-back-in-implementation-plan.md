# Jump back in implementation plan


## 1. Product behavior

Add a **Jump back in** section above the existing reader settings. It lists completed, locally cached ZIP, CBZ, and 7z archives, most recently opened first. Selecting an entry opens its extracted images at the last-read image without a document picker, source-file access, hashing the original archive, extraction, or another password prompt.

Each row shows a small cover thumbnail, original filename, and `Page 24 of 180`. Use a format icon if a thumbnail cannot be generated. The empty state says `Open an archive to start reading.` Keep the existing Open Archive File button available.

Settings:

| Setting | Initial behavior |
|---|---|
| Cache storage limit | 2 GB by default; presets 500 MB, 1 GB, 2 GB, 5 GB, 10 GB |
| Maximum cached archives | Off by default; optional 5, 10, 20, 50 |
| Storage display | For example, `1.3 GB of 2 GB · 7 archives` |
| Remove one | Remove the selected cached archive and its thumbnail |
| Clear cached archives | Remove all cached archives and saved recent/progress records; preserve preferences |

Use decimal MB/GB consistently in settings, accounting thresholds, and formatting. Both enabled limits apply simultaneously. The count describes retained archives, not the number of visible rows.

Changing a limit applies it immediately to eligible cached entries. Show helper text explaining that least recently opened archives are removed automatically. Cache removal never deletes the user's original archive.

Use an ordinary vertically scrolling list with reusable rows, suitable for many small archives when the count limit is off. Avoid creating a full-resolution image view or a permanent view hierarchy for every entry.

## 2. Current code and proposed boundaries

| File/component | Current behavior | Planned change |
|---|---|---|
| `ArchiveService.swift` | One ZIP/CBZ cache, in-memory identity, fixed temporary extraction directory; clears previous cache before a different import | Own source preparation and ZIP extraction into unique staging; delegate completed-cache ownership to a shared store |
| `ArchiveImportCoordinator.swift` | One session-only 7z cache; startup deletes its root; replacement deletes previous success | Preserve import/password/cancellation state machine; delegate shared-cache lookup and successful publication to the store |
| `ViewController.swift` | Settings screen and picker; passes only image URLs to viewer | Present recent entries and cache settings; carry archive identity through open/import/viewer flows |
| `ImageViewerViewController.swift` | Supports an initial `currentIndex`; no persisted reading position | Receive restored index and report page changes and viewer closure |
| `ImageFileSorter.swift` | Existing filename/date ordering | Preserve ordering rules; locate the saved relative image path after sorting |

Introduce a small `ArchiveCache/` module:

- `CachedArchive.swift`: versioned manifest, catalog summaries, reading position, cache preferences, and a prepared reader session.
- `ArchiveCacheStore.swift`: async public API backed by a dedicated serial filesystem queue; sole owner of cache publication, removal, accounting, and reader leases.
- `ArchiveCachePolicy.swift`: deterministic size/count/LRU decisions, independent of UIKit and extraction.
- `ArchiveIdentity.swift`: shared streaming content-signature calculation, preserving the existing source-identity-plus-SHA-256 behavior.
- A recent-archives view/controller and reusable cell, keeping persistence and eviction logic out of `ViewController`.

Keep native decoding on the existing extraction workers. Cache mutations run on the store's queue; UI updates run on the main actor. Do not synchronously wait on the store from the main actor, or create circular waits between extraction and cache queues. Use one app-owned store injected into both import paths, rather than one store per importer.

Proposed store operations: list summaries, look up a valid source signature, begin staging, publish a completed import, acquire/release a reader session, save progress, change limits, remove one, clear all, and reconcile disk state. Return typed outcomes for unavailable cache, temporary viewing, and cleanup failure.

## 3. Persistence and identity

Use app-owned directories:

```text
Library/Caches/ZipImageViewer/
  archives/<UUID>/
    manifest.json
    images/...
    thumbnail.jpg
  staging/<operation UUID>/...
  pending-deletion/<UUID>/...

Library/Application Support/ZipImageViewer/
  recent-archives.json
```

Store cache preferences in `UserDefaults`. The Application Support catalog contains compact metadata and reading positions; image files and thumbnails remain disposable cache data. OS cache removal must not turn catalog entries into apparently usable archives. Apple recommends separating reconstructible caches from support data: [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

Manifest fields: schema version, UUID, original display name, archive format, source identity/content signature, import date, relative image paths, image count, and measured retained bytes. Catalog fields: UUID/signature, display name, last-opened date, a persisted access sequence for deterministic LRU ordering, last-read relative image path, fallback page index, and availability.

Persist relative paths, never absolute sandbox URLs. Validate decoded paths and schema before resolving them inside a cache entry; reject traversal, symlinks, or references outside the owned root. Filenames from archives must never determine cache directory names.

Use the existing source path plus content digest initially. Same source and bytes reuse a completed entry; changed bytes require a new successful import. Renamed/moved copies may create separate entries. Cross-location content deduplication and security-scoped source bookmarks are outside this feature.

Opening a recent entry intentionally reads the imported snapshot. It does not check whether the original archive has changed. Selecting the original through the picker still hashes its contents and detects changes, including same-size/same-timestamp replacements. A successful changed-source import replaces the prior version for that source; a failure preserves it.

Automatically evicted entries leave the visible list. Keep only lightweight progress for up to 100 unavailable/evicted entries, pruning oldest records; this bound does not limit available archives. Reimporting identical content from the same source can restore that progress. Explicit Remove also forgets that entry's saved progress.

## 4. Import and publication lifecycle

1. Acquire source access and compute the existing content signature on a worker. Reuse a validated entry if one exists.
2. Otherwise copy the source into a unique staging directory. Keep existing completed entries intact.
3. Extract into an attempt-specific directory. Password retries use fresh attempt output and the same copied source. Failed/cancelled output must never become a cache entry.
4. Validate all output, collect the supported images, and discard unneeded extracted files. ZIP currently extracts the whole archive, so explicitly account for and clean its non-image output. Preserve established filename/date-sort behavior.
5. Generate a downsampled thumbnail on a worker. Thumbnail failure uses a fallback icon and does not fail an otherwise valid import. Remove the copied compressed source after extraction succeeds.
6. Measure retained files, write a versioned completion manifest atomically, then rename the finished directory into `archives/` on the same volume. Commit catalog updates atomically. Protect the new entry for the pending reader before applying eviction.
7. Present a prepared reader session containing archive ID, resolved images, initial page, retention status, and a lease that prevents deletion while those URLs are in use. Release it if presentation fails or becomes stale.

The directory rename and catalog write are separate operations, so recovery must explicitly handle interruption between them. Completed directories with valid manifests can reconstruct missing catalog entries. Catalog entries without usable files become unavailable. Unfinished staging is removed only after no live operation owns it.

Both formats adopt the same preserve-on-failure behavior. Keep the existing 7z password, cancellation, progress, output-limit, and stale-callback protections. ZIP receives operation-scoped cleanup for password cancellation and terminal errors without broadening this work into a new ZIP decoder/cancellation subsystem.

## 5. Eviction and disk accounting

Order eligible archives by least recent successful open, using the persisted access sequence to avoid clock changes and timestamp ties affecting LRU. Import-and-open counts as an open; list rendering and failed opens do not. Keep a human-readable last-opened timestamp separately.

Measure allocated file bytes where available, with logical size as a fallback, for all retained files including images, manifest, and thumbnail. Treat this as a consistent application accounting estimate rather than exact physical APFS usage. Track pending-deletion bytes until deletion succeeds; never report reclaimed storage solely because a row disappeared.

Eviction procedure:

1. Calculate retained archive count and bytes after admitting a successful import or applying new settings.
2. Select the least recently opened unleased archive.
3. Remove the entire entry, including thumbnail and manifest, and update the catalog.
4. Repeat until both enabled limits are satisfied or no eligible entries remain.

Use a rename into `pending-deletion` to prevent new readers from acquiring an entry once removal begins. Keep retries/recovery explicit if actual deletion fails, and report incomplete cleanup honestly. User-owned sources are never eviction candidates.

An archive larger than the entire storage budget opens as a temporary reader session, assuming extraction limits and free space permit it. Show `This archive exceeds your cache limit and will be removed when you close it.` It must not evict all existing archives merely to attempt an impossible fit. Delete its session data after the viewer releases it, and clean abandoned temporary sessions on startup.

Reader leases protect both active and pending presentations. If a new limit cannot be met while an archive is leased, defer that part of eviction until release and show any temporary overage honestly. Clear/remove operations must not delete live reader files; UI actions remain unavailable during conflicting import work, and the store still enforces ownership independently of UI guards.

The setting is a retained-cache budget, not a hard ceiling on peak extraction storage. Staging may temporarily require the compressed source plus extracted output alongside the existing cache. Preserve existing 7z extraction/free-space limits; add practical available-space checks around copy/commit and handle write failures for both formats. If staging cannot fit, fail cleanly while preserving existing entries. Do not proactively destroy usable caches for an import that may fail. Do not claim a strict peak limit for ZIP where uncompressed requirements cannot be established reliably.

## 6. Reading-position restoration

Have `ImageViewerViewController` report position from the common page-selection path, covering taps, swipes, slider movement, and page-number jumps. Record the selected relative image path plus an index fallback, including pages displaying the existing corrupt-image placeholder.

Debounce background catalog writes during rapid navigation, and flush pending progress when the viewer closes and when the app backgrounds. Do not depend on an app-termination callback. Document that abrupt termination can lose the small debounce interval; use a short interval such as 300 ms.

Apply the user's currently selected sort criterion/order, then find the saved image path in that ordering. This resumes on the same image if sorting changes. If the image cannot be matched after a legitimate rebuild, clamp the fallback index to the valid range. A cache with missing required image files is invalid and follows the reimport flow instead of silently presenting partial output.

Keep existing reading-direction, hitbox, animation, and image-memory-cache behavior. Persist cache preferences; broad persistence/redesign of all reader settings is separate work.

## 7. UI, unavailable caches, and encrypted archives

Use a scrollable home collection/list with recent rows followed by the existing settings, and retain the bottom Open Archive File action. Add stable accessibility identifiers, Dynamic Type support, VoiceOver labels containing title/progress, and adequate touch targets. Generate/load thumbnails asynchronously with row identity checks so reused cells cannot display the wrong cover.

Refresh summaries on initial load, foregrounding, successful import/open, viewer dismissal, limit changes, and deletion. Initial reconciliation must complete before cache actions can race with startup cleanup.

If iOS removes a previously available archive or validation finds it incomplete, mark its recent row `Cached copy unavailable` with a `Select archive again` action. Reimport uses the ordinary picker; match its signature before associating saved progress. A different selected file is a normal new import. Such unavailable rows do not count toward retained-cache limits and are bounded by the lightweight-history cap. Ordinary policy eviction simply removes the row.

Cached encrypted-archive images are already decrypted. Extending cache lifetime means those images and thumbnails can now remain across app launches. Explain in cache settings that cached archives, including password-protected archives, reopen without another password. Never persist passwords or represent the extracted cache as archive-encrypted. Use appropriate iOS file protection consistently for cache and catalog files, and avoid treating a temporarily inaccessible protected file as permanently missing. App locking or re-encrypting cached content would be separate features.

## 8. Startup recovery and transition

Initialize the shared store once before either importer or recent-list UI uses it. Remove the 7z coordinator's unconditional deletion of its old root and its ownership of completed-entry lifetime.

On first launch of the new implementation, remove legacy `tmp/ZipImageViewer` and `tmp/ZipImageViewer7z` before new imports begin. Do not attempt to reconstruct their names/signatures/progress: that identity was session-only. Existing users begin with an empty recent list and acquire entries through normal opens.

On subsequent launches, remove abandoned staging/temporary sessions, retry pending deletion, reconcile manifests and catalog, and enforce saved limits. Missing thumbnails are regenerable; missing required images invalidate an entry. Corrupt/unsupported manifests must not be published as usable entries, and corrupt catalog data must not trigger deletion outside app-owned directories. Recover valid completed entries from supported manifests, accepting loss of progress if its catalog cannot be read. Preserve unknown newer schema data and surface an incompatibility rather than destructively treating it as garbage.

## 9. Implementation sequence

| Milestone | Deliverable | Completion criterion |
|---|---|---|
| 1. Models and store | Versioned manifests/catalog, serial ownership, preferences, recovery, leases, accounting and policy | Deterministic filesystem/policy tests pass, including relaunch and interrupted publication |
| 2. Import integration | Both importers use staging and shared completed caches | Multiple ZIP/CBZ/7z entries coexist; failed imports preserve them; all existing import/password regressions pass |
| 3. Reader integration | Prepared reader sessions, path-based progress, debounce/flush and lease release | Reopen and relaunch restore the expected image, including changed sort order |
| 4. Home UI and settings | Recent list, thumbnails, limits, usage, remove/clear, unavailable and oversize states | End-to-end flows work without reselection while cached files exist |
| 5. Validation and documentation | Native builds/tests, static checks, manual storage/UI checks, README and validation notes | Acceptance matrix below is verified and remaining device-only limits are explicitly recorded |

Make small reviewable commits in that order. Keep the existing unrelated Xcode project edit intact. Synchronized source folders should discover new Swift files; change project configuration only when actually required.

## 10. Validation and acceptance

Use injected filesystem roots and a deterministic clock/access sequence for cache tests. Add failure injection at publication, catalog writes, deletion, and file validation. Exercise actual small archive fixtures through both production import paths, rather than relying only on fake extractors.

| Scenario | Expected result |
|---|---|
| Import A ZIP, B CBZ, C 7z; reopen A | All remain eligible; A opens without picker/extraction and becomes most recent |
| Relaunch after reading | Entries and progress survive; original source may be offline or removed |
| Size limit only, count only in policy tests, both limits, exact boundary | Whole oldest eligible entries removed until applicable limits hold |
| Reopen old entry before a new import | Reopened entry survives ahead of less recently used entries |
| Change limits or close an active viewer | Live files stay protected; deferred eviction runs after release |
| Oversized archive | Temporary viewing works; existing cache remains; close removes temporary files |
| Wrong password, cancel, damaged archive, no images, low space | No partial entry is published; prior entries remain usable |
| Changed source with equal size/date | New content is extracted; old entry replaced only after successful publication |
| Sort change and duplicate basenames in different folders | Resume matches the relative image path, not merely page number/basename |
| Missing cached image, OS purge, corrupt catalog, interrupted commit | Honest unavailable state or manifest recovery; no partial cache hit |
| Failed deletion | Usage is not falsely reduced; retry/recovery remains possible |
| Clear/remove with pending callbacks or pending presentation | No use-after-delete, stale UI publication, or unintended reappearance |
| Encrypted archive reopen after relaunch | Cached images open without a stored password; remove/clear deletes thumbnails too |
| Unicode names, many entries, large source images | Correct names, reusable cells, downsampled thumbnails, responsive home screen |

Add `ArchiveCacheStoreTests`, `ArchiveCachePolicyTests`, reader-progress integration tests, and targeted recent-list UI tests. Adapt old single-cache tests to assert the new shared-store invariants while retaining source-signature, partial-output, safe-path, password, cancellation, and navigation regressions. Extend simulator fixture seeding to import multiple named formats into an isolated test root; retain the same root across relaunch tests and avoid auto-reimporting on the second launch.

Run the existing portable static checker, a Debug simulator build, an unsigned Release device build, and the app's unit/integration/UI suites on an installed simulator. Update static expectations only where behavior intentionally changed; do not weaken checks to obtain a pass. Manually verify iPhone/iPad layouts, Dynamic Type, VoiceOver, background/relaunch behavior, and cleanup/low-storage behavior on a physical device where available. Record tests actually run rather than promising simulator checks establish physical-device storage behavior.

The feature is complete when a user can import several supported archives, leave/relaunch the app, resume a retained archive directly at the same image, and see predictable whole-archive eviction under their configured limits without losing the active reader or unrelated original files.
