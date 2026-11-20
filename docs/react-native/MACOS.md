# Build and verify on macOS

Use the Node version in `.node-version`, npm version in `package.json`, Ruby
3.3 and a compatible Xcode installation. The app targets iOS 18.1 and later.

```sh
npm ci
bundle install
bundle exec pod install
open ZipImageViewer.xcworkspace
```

Open the workspace and select the **ZipImageViewer** scheme for development or
**ZipImageViewer Device** for running the bundled Release app on your device.
For physical-device builds, select your own signing team in Xcode. Keep
signing settings and any Node path in `.xcode.env.local` local to your machine.

## Tests

```sh
npm run typecheck
npm test
npm run codegen
./scripts/verify-ios.sh
```

The script builds the unsigned device Release, runs native and shared UI tests
on the newest installed compatible iPhone simulator, then runs the shared UI
suite on an iPad simulator. Install an available simulator for each. Set
`IOS_PHONE_SIMULATOR_ID` or `IOS_TABLET_SIMULATOR_ID` to select a specific
device. Logs and result bundles go under `build/ios-verification/`.

## Debug variants

The Debug scheme uses Metro. Run `npm start` from the repository root for
active development. The Xcode Test action and Release builds use bundled
JavaScript. To run a Debug build with the embedded bundle, set
`ZIPIMAGEVIEWER_USE_BUNDLED_JS=1` in the scheme's Run environment variables.

For signed physical Debug builds using Metro, connect the Mac and device to
the same network and start `npm start -- --host 0.0.0.0`. Accept the Debug app's
Local Network prompt. Rebuild after changing networks so the bundle script
refreshes its development host IP. For normal offline testing, use the
Device scheme. Release uses its bundled JavaScript and original ATS settings.
