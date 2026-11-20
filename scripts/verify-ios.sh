#!/usr/bin/env bash
# Run from any directory on a Mac with Xcode and an installed iOS simulator.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
result_dir="$repo_root/build/ios-verification"
mkdir -p "$result_dir"
# Xcode must use one physical path when build/ is a symlink to another volume.
result_dir="$(cd "$result_dir" && pwd -P)"
# Avoid overwriting an earlier local test result bundle.
result_bundle="$result_dir/tests-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
xcodebuild -version
if [[ ! -d ZipImageViewer.xcworkspace ]]; then
  echo 'Missing React Native workspace. Run npm ci and bundle exec pod install first.' >&2
  exit 1
fi
project_args=(-workspace ZipImageViewer.xcworkspace -scheme ZipImageViewer -jobs 2
  -clonedSourcePackagesDirPath "$result_dir/SourcePackages")

# Use the newest available iPhone runtime supported by the selected Xcode SDK.
# A model name is deliberately not pinned: installed simulator devices vary between Macs.
select_simulator() {
python3 - "$1" <<'PY'
import json
import subprocess
import sys

def version_tuple(value, separator='.'):
    parts = tuple(map(int, value.split(separator)))
    return (parts + (0, 0, 0))[:3]

sdk = version_tuple(subprocess.check_output(
    ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip())
devices = json.loads(subprocess.check_output(
    ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True))['devices']
candidates = []
for runtime, entries in devices.items():
    if '.iOS-' not in runtime:
        continue
    version = version_tuple(runtime.rsplit('.iOS-', 1)[1], '-')
    if not (18, 1, 0) <= version <= sdk:
        continue
    for device in entries:
        if device.get('isAvailable') and device['name'].startswith(sys.argv[1]):
            candidates.append((version, device['name'], device['udid']))
if not candidates:
    raise SystemExit(f'No available {sys.argv[1]} simulator for iOS 18.1 through the selected SDK. Install one in Xcode.')
print(max(candidates)[2])
PY
}
fixture_mode="${IOS_CODEC_FIXTURE_TESTS_ONLY:-0}"
if [[ "$fixture_mode" == 1 ]]; then
  # Reuse one available iOS simulator (either form factor). A separate tablet
  # run is opt-in when a second device already exists.
  simulator_id="${IOS_PHONE_SIMULATOR_ID:-$(select_simulator i)}"
  ipad_id="${IOS_TABLET_SIMULATOR_ID:-}"
else
  simulator_id="${IOS_PHONE_SIMULATOR_ID:-$(select_simulator iPhone)}"
  ipad_id="${IOS_TABLET_SIMULATOR_ID:-$(select_simulator iPad)}"
fi
cleanup_simulators() {
  xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
  if [[ -n "$ipad_id" ]]; then xcrun simctl shutdown "$ipad_id" >/dev/null 2>&1 || true; fi
}
# The selected test devices may already be booted by an earlier run. Begin with
# both stopped and clean them up on failure as well as on successful completion.
trap cleanup_simulators EXIT
cleanup_simulators
xcodebuild "${project_args[@]}" -resolvePackageDependencies \
  -derivedDataPath "$result_dir/DerivedData-device" \
  -onlyUsePackageVersionsFromResolvedFile 2>&1 | tee "$result_dir/packages.log"

xcodebuild "${project_args[@]}" -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$result_dir/DerivedData-device" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$result_dir/device-build.log"

test_args=(-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1)
if [[ "$fixture_mode" == 1 ]]; then
  source Vendor/JPEGXL/Scripts/source-pins.sh
  xcrun simctl boot "$simulator_id"
  xcrun simctl bootstatus "$simulator_id" -b
  Vendor/JPEGXL/Scripts/verify-xcframework.py Vendor/JPEGXL/JPEGXL.xcframework "$JXL_VERSION" --simulator "$simulator_id"
  for fixture in \
      SevenZipExtractorTests/testFixturesMatchIndependentManifest \
      SevenZipExtractorTests/testOrdinaryLZMAAndLZMA2Archives \
      SevenZipExtractorTests/testEncryptedContentsAndEncryptedHeaders \
      SevenZipExtractorTests/testSolidEncryptedArchiveWith600Images \
      SevenZipExtractorTests/testPPMdCompatibility \
      SevenZipExtractorTests/testUnicodePassword \
      SevenZipExtractorTests/testSupplementaryPlaneUnicodeFilename \
      ZipArchiveRegressionTests/testStandardAndAESEncryptedZIPAndCBZ \
      ZipArchiveRegressionTests/testProductionImportersSharePersistentZIPCBZAndSevenZipCache \
      ZipArchiveRegressionTests/testRealZIPCompressionReopensWithoutRewritingAndOffImportKeepsOriginalBytes \
      ExtractedImageProcessorTests/testJPEGRepackingReconstructsExactOriginalBytes \
      ExtractedImageProcessorTests/testLargeJPEGsActuallyRepackAndReconstructExactly \
      ExtractedImageProcessorTests/testLargePNGsActuallyEncodeAtOriginalDimensions \
      ExtractedImageProcessorTests/test24MegapixelPNGAboveOldFileSizeLimitActuallyEncodes \
      ExtractedImageProcessorTests/testJPEGCompressionRetainsOrientationAndReconstructsOriginalFromStoredPage \
      ExtractedImageProcessorTests/testPNGCompressionPreservesPageIdentityDimensionsOrientationAndProfile; do
    test_args+=("-only-testing:ZipImageViewerTests/$fixture")
  done
fi
printf 'Testing simulator %s\n' "$simulator_id"
xcodebuild "${project_args[@]}" -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" -destination-timeout 180 \
  -derivedDataPath "$result_dir/DerivedData-simulator" -resultBundlePath "$result_bundle" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  "${test_args[@]}" test \
  2>&1 | tee "$result_dir/simulator-tests.log"

if [[ "$fixture_mode" == 1 ]]; then
  # Compare actual bundled bytes for both the Release/device and Debug/simulator products.
  python3 - "$result_dir" <<'PYTHON'
from pathlib import Path
import sys

root = Path(sys.argv[1])
sources = list(Path("ZipImageViewer/Resources").glob("*.txt"))
sources.extend(Path("Vendor/PLzmaSDK/swift/Resources").glob("*.txt"))
for target, product in [("device", "Release-iphoneos"), ("simulator", "Debug-iphonesimulator")]:
    app = root / f"DerivedData-{target}/Build/Products/{product}/ZipImageViewer.app"
    for source in sources:
        copies = [copy for copy in app.rglob(source.name) if "PlugIns" not in copy.relative_to(app).parts]
        if not copies or any(copy.read_bytes() != source.read_bytes() for copy in copies):
            raise SystemExit(f"Incorrect {target} package notice: {source.name}")
        print(f"Verified {copies[0].relative_to(app)} in {product}")
PYTHON
  [[ -n "$ipad_id" && "$ipad_id" != "$simulator_id" ]] || exit 0
fi

# Release the phone simulator before starting tablet execution on the same host.
# Xcode may already have stopped the selected device after testing.
xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true

# Tablet execution targets the real shared library and reader, including native
# canvas touch pass-through, overview, jump, settings and restart progress.
ipad_bundle="$result_dir/ipad-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
printf 'Testing shared workflow on iPad %s\n' "$ipad_id"
xcodebuild "${project_args[@]}" -configuration Debug \
  -destination "platform=iOS Simulator,id=$ipad_id" -destination-timeout 180 \
  -derivedDataPath "$result_dir/DerivedData-simulator" -resultBundlePath "$ipad_bundle" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:ZipImageViewerUITests/ReactNativeMVPUITests test \
  2>&1 | tee "$result_dir/ipad-shared-tests.log"
xcrun simctl shutdown "$ipad_id" >/dev/null 2>&1 || true
