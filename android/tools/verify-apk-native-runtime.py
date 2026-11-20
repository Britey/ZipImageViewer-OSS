#!/usr/bin/env python3
"""Verify both shipping ABIs, 16 KiB ELF segments, and the exact pinned C++ runtime.

Run after assembleDebug/assembleRelease with APK and Android NDK 27.1.12297006 paths.
This checks packaging/linkage inputs; it does not replace device codec execution.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("apk", type=Path)
parser.add_argument("ndk", type=Path)
args = parser.parse_args()
assert "Pkg.Revision = 27.1.12297006" in (args.ndk / "source.properties").read_text(), "Use the RN-pinned NDK 27.1.12297006"
required = {"libappmodules.so", "libreactnative.so", "libjsi.so", "libhermesvm.so",
            "libc++_shared.so", "libzipimageviewer_native.so", "libzipimageviewer_jxl.so"}
prebuilt = args.ndk / "toolchains/llvm/prebuilt"
hosts = [p for p in prebuilt.iterdir() if (p / "bin/llvm-strip").is_file()]
assert len(hosts) == 1, f"Expected one host toolchain in {prebuilt}"
toolchain = hosts[0]
with zipfile.ZipFile(args.apk) as apk, tempfile.TemporaryDirectory() as tmp:
    abis = {name.split("/")[1] for name in apk.namelist() if name.startswith("lib/") and name.endswith(".so")}
    assert abis == {"arm64-v8a", "x86_64"}, f"Unexpected APK architectures: {abis}"
    for abi, triple, machine in [("arm64-v8a", "aarch64-linux-android", 183), ("x86_64", "x86_64-linux-android", 62)]:
        names = [name for name in apk.namelist() if name.startswith(f"lib/{abi}/") and name.endswith(".so")]
        assert len(names) == len(set(names)), f"Duplicate packaged library: {abi}"
        assert required <= {Path(name).name for name in names}, f"Missing native engine: {abi}"
        for name in names:
            data = apk.read(name)
            assert data[:6] == b"\x7fELF\x02\x01", f"Expected little-endian ELF64: {name}"
            assert struct.unpack_from("<H", data, 18)[0] == machine, f"Wrong ELF architecture: {name}"
            phoff = struct.unpack_from("<Q", data, 32)[0]
            phsize, phcount = struct.unpack_from("<HH", data, 54)
            for i in range(phcount):
                offset = phoff + i * phsize
                if struct.unpack_from("<I", data, offset)[0] == 1:  # PT_LOAD
                    alignment = struct.unpack_from("<Q", data, offset + 48)[0]
                    assert alignment >= 16384, f"Not 16 KiB segment aligned: {name}: {alignment}"
        expected = Path(tmp) / f"{abi}.so"
        subprocess.run([str(toolchain / "bin/llvm-strip"), "--strip-unneeded", "-o", str(expected),
                        str(toolchain / "sysroot/usr/lib" / triple / "libc++_shared.so")], check=True)
        runtime = apk.read(f"lib/{abi}/libc++_shared.so")
        assert runtime == expected.read_bytes(), f"Packaged C++ runtime differs from compiler NDK: {abi}"
        print(f"{abi}: {len(names)} native libraries, 16 KiB ELF alignment, pinned libc++ SHA256 {hashlib.sha256(runtime).hexdigest()}")
