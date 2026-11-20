#!/usr/bin/env python3
"""Verify the XCFramework with Xcode. Optionally run its version probe on a booted simulator."""
import argparse
import plistlib
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("framework", type=Path)
parser.add_argument("version", help="expected libjxl release, e.g. 0.13.0")
parser.add_argument("--simulator", help="UDID of an existing booted iOS simulator for a runtime check")
args = parser.parse_args()
major, minor, patch = map(int, args.version.split("."))
framework = args.framework.resolve()
with (framework / "Info.plist").open("rb") as file:
    libraries = plistlib.load(file)["AvailableLibraries"]

expected = {"": {"arm64"}, "simulator": {"arm64", "x86_64"}}
if len(libraries) != 2 or {entry.get("SupportedPlatformVariant", "") for entry in libraries} != expected.keys():
    raise SystemExit("Expected one iOS device and one iOS simulator library")

probe = f"""
#include <jxl/version.h>
#include <jxl/encode.h>
#include <jxl/decode.h>
#include <cstdio>
extern "C" uint32_t BrotliEncoderVersion(void);
extern "C" uint32_t BrotliDecoderVersion(void);
static_assert(JPEGXL_MAJOR_VERSION == {major} && JPEGXL_MINOR_VERSION == {minor} &&
              JPEGXL_PATCH_VERSION == {patch}, "incorrect libjxl headers");
int main() {{
    constexpr unsigned jxl = {major} * 1000000 + {minor} * 1000 + {patch};
    constexpr unsigned brotli = (1u << 24) | (2u << 12) | 1u;
    std::printf("libjxl enc/dec %u/%u; Brotli enc/dec 0x%x/0x%x\\n",
                JxlEncoderVersion(), JxlDecoderVersion(), BrotliEncoderVersion(), BrotliDecoderVersion());
    return JxlEncoderVersion() == jxl && JxlDecoderVersion() == jxl &&
           BrotliEncoderVersion() == brotli && BrotliDecoderVersion() == brotli ? 0 : 1;
}}
"""

with tempfile.TemporaryDirectory() as temporary:
    source = Path(temporary) / "version.cc"
    source.write_text(probe)
    for entry in libraries:
        variant = entry.get("SupportedPlatformVariant", "")
        archs = expected[variant]
        if entry["SupportedPlatform"] != "ios" or set(entry["SupportedArchitectures"]) != archs:
            raise SystemExit(f"Incorrect platform or architectures in {entry}")
        directory = framework / entry["LibraryIdentifier"]
        archive = directory / entry["LibraryPath"]
        includes = directory / entry["HeadersPath"]
        actual = subprocess.check_output(["xcrun", "lipo", "-archs", archive], text=True).split()
        if set(actual) != archs:
            raise SystemExit(f"{archive} contains {actual}, expected {sorted(archs)}")
        sdk = "iphonesimulator" if variant else "iphoneos"
        sysroot = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        executables = []
        for arch in sorted(archs):
            target = f"{arch}-apple-ios18.1" + ("-simulator" if variant else "")
            executable = Path(temporary) / target
            # Link every object to catch incorrect platform/minimum OS or missing dependencies.
            subprocess.run(["xcrun", "--sdk", sdk, "clang++", "-std=c++17", "-target", target,
                            "-isysroot", sysroot, "-I", includes, source, "-Wl,-fatal_warnings",
                            "-Xlinker", "-force_load", "-Xlinker", archive, "-o", executable], check=True)
            print(f"Checked {target} with headers {args.version}", flush=True)
            executables.append(executable)
        if variant and args.simulator:
            # Let the simulator choose its native slice, including when Python
            # itself is running under Rosetta.
            universal = Path(temporary) / "simulator-version"
            subprocess.run(["xcrun", "lipo", "-create", *executables, "-output", universal], check=True)
            subprocess.run(["xcrun", "simctl", "spawn", args.simulator, universal], check=True)
