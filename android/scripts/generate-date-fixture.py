#!/usr/bin/env python3
"""Regenerate creation-only.7z with 7-Zip and a deterministic original creation date.

The tiny page comes from the existing independent archive fixture. 7-Zip on
Linux cannot set an arbitrary source birth time; patch the uncompressed 7z
CTime property and recompute both standard header CRCs instead.
"""
from pathlib import Path
import argparse
import struct
import subprocess
import tempfile
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seven-zip', default='7z')
args = parser.parse_args()
android = Path(__file__).resolve().parents[1]
assets = android / 'app/src/androidTest/assets/archive-fixtures'
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    subprocess.run([args.seven_zip, 'e', str(assets / 'plain-lzma-solid.7z'), 'panel.png', '-y'], cwd=root, check=True)
    source = root / 'creation-only.7z'
    subprocess.run([args.seven_zip, 'a', '-t7z', '-mtc=on', '-mtm=off', '-mta=off', '-mhc=off', str(source), 'panel.png'], cwd=root, check=True)
    payload = bytearray(source.read_bytes())
    offset, size = struct.unpack_from('<QQ', payload, 12)
    start = 32 + offset
    header = payload[start:start + size]
    marker = b'\x12\x0a\x01\x00'  # CTime, size=10, all-defined, inline values
    assert header.count(marker) == 1, 'Unexpected generated 7z header'
    struct.pack_into('<Q', payload, start + header.index(marker) + 4, (1577836800 + 11644473600) * 10000000)
    struct.pack_into('<I', payload, 28, zlib.crc32(payload[start:start + size]))
    struct.pack_into('<I', payload, 8, zlib.crc32(payload[12:32]))
    destination = assets / 'creation-only.7z'
    destination.write_bytes(payload)
    subprocess.run([args.seven_zip, 't', str(destination)], check=True)
