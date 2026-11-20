# Reader image rotation

Enable **Show image rotation buttons** in reader or library settings. It defaults
to off, including upgrades from preferences saved before this feature. The two
buttons appear before Settings and Hide in the top toolbar. Their accessible
names explicitly identify counterclockwise/clockwise and 90 degrees.

Each press turns the current image 90 degrees and fits it to the viewport,
resetting zoom and pan. Pinch, double-tap zoom, and pan then operate on the turned
image. Four turns restore its original orientation. Page gestures remain relative
to the screen and respect reading direction. Moving to another image (including
scrubbing, jump, or overview) resets rotation; returning to an earlier image does
not restore its old turn. Selecting the same image and changing its sort position
preserve rotation. Overview thumbnails and stored image files remain unchanged.

Hiding the buttons preserves the current image's rotation. The setting persists
across app launches; image turns last only for the current page in a reader
session. Device rotation and window resizing preserve the image turn and use the
reader's existing viewport/zoom behavior. Android retains the turn across reader
Activity/canvas recreation. Rotation never requests device orientation or changes
rotation lock or system settings.

iOS reuses the source CGImage with composed UIImage orientation metadata, leaving
aspect-fit and UIScrollView in charge of fitting and zoom. Android rotates the
Canvas at draw time and swaps fitted dimensions and pan limits for odd quarter
turns. Neither path allocates a second full-size rotated bitmap. Preview/detail
replacement preserves the turn without changing source pixels or cache identity.

## Local verification

Keep native runs serial. Use task-owned disposable devices, at most two Xcode
build jobs, one Gradle worker, a 2 GiB Gradle heap, and a two-core/2 GiB Android
emulator. Stop the build daemon before launching the emulator, and stop the task's
phone before starting its tablet. Keep hosted CI disabled.

```sh
npm ci
npm run typecheck
npm test -- --runInBand
npm run codegen
# After pinned CocoaPods setup; pass IDs for disposable task-owned devices.
IOS_PHONE_SIMULATOR_ID=<phone> IOS_TABLET_SIMULATOR_ID=<tablet> ./scripts/verify-ios.sh
cd android
CMAKE_BUILD_PARALLEL_LEVEL=1 ./gradlew --no-daemon --max-workers=1 \
  -PreactNativeArchitectures=arm64-v8a \
  :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest :app:lintDebug
```

New tests cover default/migrated/persisted preferences, live toolbar visibility,
shared action routing, both turn directions, four-turn identity, rendered fitting,
zoom/pan and detail replacement, page/overview transitions, and viewport/reader
recreation. Actual iOS XCUI and Android Compose/Fabric tests exercise the native
canvas and toolbar, including stable portrait and landscape operation. These
checks do not toggle system rotation lock or certify physical-device installation.
