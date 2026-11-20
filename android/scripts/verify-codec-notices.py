#!/usr/bin/env python3
"""Compare packaged APK notices to the project assets and pinned codec inputs."""
import argparse
from pathlib import Path
from zipfile import ZipFile

root = Path(__file__).resolve().parents[2]
assets = root / "android/app/src/main/assets"
jxl = root / "android/vendor/libjxl"
lzma = root / "Vendor/PLzmaSDK"
upstream = {
    "JPEGXL-AUTHORS.txt": jxl / "AUTHORS",
    "JPEGXL-LICENSE.txt": jxl / "LICENSE",
    "JPEGXL-PATENTS.txt": jxl / "PATENTS",
    "Brotli-LICENSE.txt": jxl / "third_party/brotli/LICENSE",
    "Highway-LICENSE.txt": jxl / "third_party/highway/LICENSE",
    "Highway-LICENSE-BSD3.txt": jxl / "third_party/highway/LICENSE-BSD3",
    "Skcms-LICENSE.txt": jxl / "third_party/skcms/LICENSE",
    "Libpng-LICENSE.txt": jxl / "third_party/libpng/LICENSE",
    "Libpng-AUTHORS.txt": jxl / "third_party/libpng/AUTHORS",
    "Zlib-LICENSE.txt": jxl / "third_party/zlib/LICENSE",
    "JPEGXL-Xorshift128Plus-MIT.txt": root / "Vendor/JPEGXL/Licenses/libjxl-Xorshift128Plus-MIT.txt",
    "PLzmaSDK-LICENSE.txt": lzma / "LICENSE",
    "LZMA-SDK-NOTICE.txt": lzma / "swift/Resources/LZMA-SDK-NOTICE.txt",
    "Unicode-ConvertUTF-NOTICE.txt": lzma / "swift/Resources/Unicode-ConvertUTF-NOTICE.txt",
}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("apk", type=Path)
args = parser.parse_args()
for name, source in upstream.items():
    if source.read_bytes() != (assets / name).read_bytes():
        raise SystemExit(f"{name} differs from {source}")

index = (assets / "THIRD-PARTY-NOTICES.txt").read_text()
for name in upstream:
    if name not in index:
        raise SystemExit(f"Missing from APK notice index: {name}")

with ZipFile(args.apk) as apk:
    entries = apk.namelist()
    notices = sorted(assets.glob("*.txt"))
    for notice in notices:
        entry = "assets/" + notice.name
        if entries.count(entry) != 1 or apk.read(entry) != notice.read_bytes():
            raise SystemExit(f"Missing, duplicate or mismatched APK entry: {entry}")
print(f"Verified {len(notices)} packaged notices and {len(upstream)} codec notice sources.")
