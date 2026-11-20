# React Native coverage migration

Tests are classified by the surface they execute. A passing legacy library test does not establish React Native parity. Keep native canvas/engine coverage and distinguish it from shared presentation coverage. This ledger records coverage ownership; the verification log in `MVP.md` records executions.

| Surface | Existing suites / harness | Ownership and remaining boundary checks |
|---|---|---|
| Shared protocol | `mobile/src/__tests__/client.test.ts` | Snapshot validation, revision ordering, subscription/bootstrap and disposed-client callbacks. Retain. |
| Shared components | `mobile/src/__tests__/LibraryApp.test.tsx` | Password IDs and exact contents, error/modal precedence, reader route reset, physical tap-width rendering, quota reconfirmation, modal-dismiss acknowledgement and bootstrap retry. Busy reservations and one-time picker capabilities are covered; exhaustive settings interactions remain runtime checks. Composed/decomposed iOS accent search and unchanged Android case matching are covered. Component tests do not establish device layout or native presentation. |
| Shared reader | `ReaderApp.test.tsx`, `PagePosition.test.tsx`, `RangePreference.test.tsx` | Session/tool dispatch, sequence reconnect, exact rapid release/termination, sorting cancellation, jump validation, hidden preferences, reader settings, notices and replacement-import presentation. Thumbnail sizing covers ordinary release, cancellation restoring the saved value and changes to the latest native value. |
| Android native protocol | `bridge/NativeProtocolTest.kt`, `NativeStateTest.kt` | Process ownership, explicit events without Compose, staged password retry after module detach, stale commands and quota IDs, integer validation, out-of-order seeks, stale canvas callbacks and asynchronous storage reservations. Retain; real React reload is a separate runtime case. |
| Android incoming archives | `IncomingArchiveIntentTest`, `ExternalArchiveActivityTest`, `ArchivePickerTest` | Intent validation, provider handling, host lifecycle and picker behavior. Production host tests assert shared chrome/password views, Activity recreation, replacement-import ownership and native gesture/zoom behavior beneath Fabric. Test-owner resets tear down the cached React runtime first. |
| Android retained reader | Reader assertions in `AppSmokeTest`, `ExternalArchiveActivityTest`; `ReaderModelsTest`, `ReaderCoverIndexTest` | Compose supplies the shipping Fabric canvas; legacy Compose chrome is tested separately. Distinguish explicit close from Activity detachment; save original-page progress before cleanup. Overview indexing verifies session/sort invalidation and constant-time repeated lookup over 25,000 pages. |
| Android legacy library | `AppSmokeTest`, `ArchivePickerUiTest` using `LegacyLibraryActivity`, standalone `ReaderScreenTest` chrome assertions | Debug-only compatibility harness. Not shared-library evidence; retire only after corresponding real RN runtime coverage exists. |
| Android engines/storage | `ArchiveRepositoryTest`, `ExtractedImageProcessorTest`, `ArchivePolicyTest`, `ImagePreparationPolicyTest`, `ZipEntryMetadataTest` | Preserve native ZIP/7z/JXL, quotas, leases and metadata coverage. |
| Android real shared workflow | `scripts/smoke-android-mvp.py` | Installed app: shared library/settings, sample or seeded resume, shared reader/overview/jump/settings/hide/Back, return and process restart. `--reload-reader` verifies hidden-canvas reattachment; `--rotate-reader` checks landscape overview/native swipe and portrait page preservation. Optional encrypted fixtures use the one-time System files picker → RN password → retained reader → library without changing a saved file-app preference. Supports Debug and locally test-signed Release explicitly. |
| iOS native service | `NativeAppServiceTests`, `ReaderProgressFailureTests` | Bootstrap, snapshot revisions, preferences, stale commands, picker presentation reservation and quota tokens. A real catalog-write failure checks immediate reader error visibility and the native progress-save title. Retain; actual scene/reload events require runtime checks. |
| iOS storage/engines | `ArchiveCacheStoreTests`, `ArchiveCachePolicyTests`, `ZipArchiveRegressionTests`, `SevenZipExtractorTests`, `ExtractedImageProcessorTests`, `ArchiveImagePreparationIntegrationTests`, `ArchiveImportCoordinatorTests` | Preserve native archive, quota, staging, codec and lifetime coverage. |
| iOS retained reader | `ReaderImagePipelineTests`, `ReadingProgressTests`, `ReaderPreferencesTests`, `ReaderToolsTests`, retained reader assertions in navigation/UI suites | UIKit supplies the shipping canvas. ReaderTools retains shared exact-release and passthrough-container checks; custom VoiceOver one-page step expectations are retired; retained UIKit chrome assertions remain legacy coverage. |
| iOS legacy library/presentation | `ArchiveLibraryLayoutTests`, `SettingsInteractionTests`, `ImportPresentationStateTests`, `NavigationIntegrationTests`, recent-archive/encrypted/general UI suites when launched in legacy mode | Assertions against old controllers remain legacy coverage, even when they also exercise shared native services. They do not certify RN library or settings. |
| iOS real shared workflow | `ReactNativeMVPUITests` | Bundled RN root, shared preference persistence and encrypted 7z password → shared reader/native swipe → overview/jump/settings/hide/long-press → saved library → restart/resume. The verification script executes this suite on iPhone and iPad. Library password dialogs are checked in landscape. Native-mainline upgrade probes additionally qualify retained JXL reopening; ZIP retry and expanded lifecycle coverage remain additional cases. |

## Runtime checks before declaring shared reader parity verified

- Both platform native builds and generated bindings; shared TypeScript and component tests.
- Actual shared library/settings/import/password workflow into the retained reader, return and restart.
- Android native archive/codec/boundary instrumentation and minified Release execution without Metro.
- iOS simulator execution of the bundled React Native root, not only the legacy UIKit harness.
- Stale operation IDs, staged password retry, explicit close and retained progress at the native boundary.

## Next milestone and release qualification

Cover React reload during archive import and reading, iOS scene reconnect, accessible navigation and focus, and physical-device memory. Exercise native swipe through shared controls, rotation, modal safe areas and closing with a presented tool in the platform UI suites.


GitHub Actions is disabled and its workflows have been removed. Run Android JVM tests, lint, builds, packaging checks, instrumentation and UI smoke locally; retain the results. Run iOS verification on the owner’s Mac using `scripts/verify-ios.sh`.
