#!/bin/bash
set -euo pipefail
export LC_ALL=C
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Scripts/source-pins.sh"
# A fresh build directory prevents stale CMake caches, archives or headers from
# crossing architectures or versions. Keep it available for the build audit.
build_parent="${JPEGXL_BUILD_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$build_parent"
work="$(mktemp -d "${build_parent%/}/zipimageviewer-jxl.XXXXXX")"
work="$(cd "$work" && pwd -P)"
printf 'JPEG XL build workspace: %s\n' "$work"
source_dir="$work/source"
"$root/Scripts/checkout-source.sh" "$source_dir"

# Configure each architecture separately so upstream CPU feature checks run
# for the platform and architecture of the objects being compiled.
for target in iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64; do
  sdk="${target%-*}"
  arch="${target##*-}"
  build="$work/$target"
  cmake -S "$source_dir" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR="$arch" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=18.1 -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_TCMALLOC=OFF \
    -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_WARNINGS_AS_ERRORS=OFF
  cmake --build "$build" --target jxl jxl_cms --parallel "${JPEGXL_BUILD_JOBS:-6}"
  mkdir -p "$build/Headers/jxl"
  cp "$source_dir"/lib/include/jxl/*.h "$build/Headers/jxl/"
  cp "$build"/lib/include/jxl/*.h "$build/Headers/jxl/"
  # skcms objects are compiled directly into jxl_cms.
  xcrun libtool -static -o "$work/$target.a" \
    "$build/lib/libjxl.a" "$build/lib/libjxl_cms.a" \
    "$build/third_party/highway/libhwy.a" \
    "$build/third_party/brotli/libbrotlienc.a" \
    "$build/third_party/brotli/libbrotlidec.a" "$build/third_party/brotli/libbrotlicommon.a"
done
diff -r "$work/iphonesimulator-arm64/Headers" "$work/iphonesimulator-x86_64/Headers"
mv "$work/iphoneos-arm64.a" "$work/zipimageviewer-jxl-ios.a"
xcrun lipo -create "$work/iphonesimulator-arm64.a" "$work/iphonesimulator-x86_64.a" \
  -output "$work/zipimageviewer-jxl-sim.a"
xcodebuild -create-xcframework \
  -library "$work/zipimageviewer-jxl-ios.a" -headers "$work/iphoneos-arm64/Headers" \
  -library "$work/zipimageviewer-jxl-sim.a" -headers "$work/iphonesimulator-arm64/Headers" \
  -output "$work/JPEGXL.xcframework"
"$root/Scripts/verify-xcframework.py" "$work/JPEGXL.xcframework" "${JXL_VERSION#v}"

mkdir "$work/Licenses"
cp "$root/Licenses/libjxl-Xorshift128Plus-MIT.txt" "$work/Licenses/"
for file in AUTHORS LICENSE PATENTS; do cp "$source_dir/$file" "$work/Licenses/libjxl-$file.txt"; done
for dep in brotli highway skcms; do cp "$source_dir/third_party/$dep/LICENSE" "$work/Licenses/$dep.txt"; done
cp "$source_dir/third_party/highway/LICENSE-BSD3" "$work/Licenses/highway-BSD3.txt"
{
  printf 'JPEG XL cache encoder: libjxl v%s\nhttps://github.com/libjxl/libjxl/tree/%s\n\n' "${JXL_VERSION#v}" "$JXL_REVISION"
  for license in "$work"/Licenses/*.txt; do
    printf '%s\n\n' "$(basename "$license")"
    cat "$license"
    printf '\n\n'
  done
} > "$work/JPEGXL-Licenses.txt"
(cd "$work" && find JPEGXL.xcframework Licenses -type f | sort | while IFS= read -r file; do shasum -a 256 "$file"; done) > "$work/SHA256SUMS"

# Only replace the working copy after the entire candidate has passed its
# structure, header and linker checks and its notices are ready.
rsync -a --delete "$work/JPEGXL.xcframework/" "$root/JPEGXL.xcframework/"
rsync -a --delete "$work/Licenses/" "$root/Licenses/"
cp "$work/JPEGXL-Licenses.txt" "$root/../../ZipImageViewer/Resources/"
cp "$work/SHA256SUMS" "$root/SHA256SUMS"
(cd "$root" && shasum -a 256 -c SHA256SUMS)
