#!/usr/bin/env python3
"""Generate tiny independent 7z fixtures; requires an official 7-Zip 7zz executable.

Usage: python3 scripts/generate-archive-fixtures.py --seven-zip /path/to/7zz
No packages, downloads, or global installation are required. Passwords are test data.
Encrypted archives use random salts, so their archive hashes change on regeneration.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zlib


JPEG = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAgACAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A/WD9m/wH4H1L9nj4XajqPh3Trq7uvC2iSzTS2kLySSPYwszuzKSzMSSSTknk17R/wrb4d/8AQraV/wCAMH/xFcF+zF/ybZ8Jv+xS0H/0ghr3GgD/2Q=="


def png(rgb):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0" + bytes(rgb) * 2 + b"\0" + bytes(rgb) * 2)) + chunk(b"IEND", b""))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seven-zip", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "ZipImageViewerTests/Fixtures/SevenZip")
    parser.add_argument("--performance-mib", type=int, default=64,
                        help="Uncompressed cancellation image size in MiB; compressed fixture stays tiny (default: 64)")
    args = parser.parse_args()
    executable = args.seven_zip.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([str(executable), "i"], text=True).splitlines()[1].strip()
    release = re.match(r"7-Zip(?: \(z\))? (\d+\.\d+)\b", version)
    if not release:
        parser.error(f"Could not identify the official 7-Zip release in {version!r}")
    files = {"panel.png": png((255, 0, 0)), "nested/panel.png": png((0, 0, 255)),
             "nested/PHOTO.JPG": base64.b64decode(JPEG), "notes.txt": b"Non-image entries must not be extracted.\n"}
    images = {name: {"sha256": digest(data), "size": len(data)} for name, data in files.items() if name != "notes.txt"}
    manifest = {"generator": "scripts/generate-archive-fixtures.py", "tool": version,
                "tool_url": f"https://github.com/ip7z/7zip/releases/tag/{release.group(1)}",
                "tool_sha256": digest(executable.read_bytes()),
                "source_mtime_unix": 1700000000, "expected_images": images, "fixtures": []}
    with tempfile.TemporaryDirectory(prefix="zipimageviewer-fixtures-") as temporary:
        source = Path(temporary)
        for name, data in files.items():
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            os.utime(path, (1700000000, 1700000000))

        def run(command):
            subprocess.run([str(executable), *command], cwd=source, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        def record(name, command, password, expected="success"):
            path = output / name
            if path.exists():
                path.unlink()
            run(command)
            entry = {"file": name, "password": password, "expected": expected,
                     "command": ["7zz", *[str(argument).replace(str(output) + "/", "") for argument in command]],
                     "archive_sha256": digest(path.read_bytes()), "archive_size": path.stat().st_size}
            manifest["fixtures"].append(entry)
            return entry

        for name, method, solid, password, headers in [
            ("plain-lzma-solid.7z", "LZMA", True, None, False),
            ("plain-lzma2-nonsolid.7z", "LZMA2", False, None, False),
            ("content-lzma2-solid.7z", "LZMA2", True, "test-password", False),
            ("headers-lzma-solid.7z", "LZMA", True, "test-password", True),
            ("headers-lzma2-nonsolid.7z", "LZMA2", False, "test-password", True),
            ("unicode-password.7z", "LZMA2", True, "密码🔐café", True),
            ("whitespace-password.7z", "LZMA2", True, "  padded password  ", True),
            ("plain-ppmd.7z", "PPMd", True, None, False),
        ]:
            command = ["a", "-t7z", "-y", "-m0=" + method, "-ms=" + ("on" if solid else "off"),
                       "-mx=3", "-mtc=off", "-mta=off", str(output / name), *sorted(files)]
            if password is not None:
                command[2:2] = ["-p" + password, "-mhe=" + ("on" if headers else "off")]
            record(name, command, password)
            run(["t", str(output / name), *(["-p" + password] if password is not None else [])])

        record("no-images.7z", ["a", "-t7z", "-y", str(output / "no-images.7z"), "notes.txt"], None, "noSupportedImages")
        hidden_names = ["._panel.png", ".hidden/page.png"]
        for name in hidden_names:
            hidden = source / name
            hidden.parent.mkdir(parents=True, exist_ok=True)
            hidden.write_bytes(b"Hidden metadata is not a viewer page.")
        record("hidden-images.7z", ["a", "-t7z", "-y", "-m0=LZMA2", "-mx=3",
               str(output / "hidden-images.7z"), *sorted(files), *hidden_names], None)
        unicode_name = "图像🔐.png"
        (source / unicode_name).write_bytes(files["panel.png"])
        os.utime(source / unicode_name, (1700000000, 1700000000))
        entry = record("unicode-filename.7z", ["a", "-t7z", "-y", "-m0=LZMA2", "-mx=3",
                       str(output / "unicode-filename.7z"), unicode_name], None, "unicodeFilename")
        entry["expected_images"] = {unicode_name: images["panel.png"]}
        many_names = [f"pages/page-{index:04d}.png" for index in range(600)]
        (source / "pages").mkdir()
        for name in many_names:
            (source / name).write_bytes(files["panel.png"])
            os.utime(source / name, (1700000000, 1700000000))
        entry = record("many-images-solid-encrypted.7z", ["a", "-t7z", "-y", "-m0=LZMA2", "-ms=on",
                       "-ptest-password", "-mhe=on", "-mx=3", str(output / "many-images-solid-encrypted.7z"), "pages"],
                       "test-password", "manyImages")
        entry["image_count"] = len(many_names)
        entry["expected_image"] = images["panel.png"]
        entry["image_path_pattern"] = "pages/page-{index:04d}.png (index 0...599)"
        # A private ancillary PNG chunk is ignored by readers but gives the archive
        # decoder substantial real work. The source and extracted large file stay out of Git.
        padding = bytes(args.performance_mib * 1024 * 1024)
        kind = b"npAD"
        large_image = png((255, 0, 0))[:-12] + struct.pack(">I", len(padding)) + kind + padding
        large_image += struct.pack(">I", zlib.crc32(kind + padding) & 0xFFFFFFFF) + png((255, 0, 0))[-12:]
        (source / "large.png").write_bytes(large_image)
        entry = record("cancellation.7z", ["a", "-t7z", "-y", "-m0=LZMA2", "-mx=1",
                       str(output / "cancellation.7z"), "large.png"], None, "cancellationProbe")
        entry["uncompressed_size"] = len(large_image)
        entry["source_sha256"] = digest(large_image)
        del large_image, padding
        for suffix in ["zip", "cbz"]:
            for encrypted in [False, True]:
                name = ("encrypted" if encrypted else "plain") + "." + suffix
                command = ["a", "-tzip", "-y", "-mm=Deflate", str(output / name), *sorted(files)]
                if encrypted:
                    command[2:2] = ["-ptest-password", "-mem=AES256"]
                record(name, command, "test-password" if encrypted else None)
        for name, replacement in [("unsafe-traversal.7z", "../escape.png"), ("case-collision.7z", "PANEL.png")]:
            shutil.copyfile(output / "plain-lzma2-nonsolid.7z", output / name)
            command = ["rn", str(output / name), "nested/panel.png", replacement]
            run(command)
            manifest["fixtures"].append({"file": name, "password": None, "expected": "unsafeOutput",
                "derived_from": "plain-lzma2-nonsolid.7z", "command": ["7zz", "rn", name, "nested/panel.png", replacement],
                "archive_sha256": digest((output / name).read_bytes()), "archive_size": (output / name).stat().st_size})
        for name, original, change in [("truncated.7z", "plain-lzma-solid.7z", "truncate"),
                                        ("damaged-content.7z", "content-lzma2-solid.7z", "flip")]:
            data = bytearray((output / original).read_bytes())
            if change == "truncate":
                data = data[:len(data) // 2]
            else:
                data[40] ^= 0x40
            (output / name).write_bytes(data)
            manifest["fixtures"].append({"file": name, "password": "test-password" if change == "flip" else None,
                "expected": "failure", "derived_from": original,
                "mutation": "remove last half" if change == "truncate" else "XOR byte at offset 40 with 0x40",
                "archive_sha256": digest(data), "archive_size": len(data)})
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"Generated {len(manifest['fixtures'])} fixtures with {version} in {output}")


if __name__ == "__main__":
    main()
