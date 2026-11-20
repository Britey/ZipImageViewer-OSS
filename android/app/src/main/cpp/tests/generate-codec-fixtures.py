#!/usr/bin/env python3
"""Deterministic project-generated images; requires Pillow and NumPy, codec bootstrap."""
from pathlib import Path
import hashlib, json, struct
import numpy as np
from PIL import Image, PngImagePlugin


def grayscale_icc_profile():
    """Generate a v2 grayscale display profile with a D50 white point and gamma 1.8."""
    # ICC v2 XYZ values are s15Fixed16. These are the standard D50 PCS values.
    white = struct.pack('>iii', 0xF6D6, 0x10000, 0xD32D)
    description = b'ZipImageViewer synthetic grayscale gamma 1.8\0'
    tags = {
        b'desc': b'desc\0\0\0\0' + struct.pack('>I', len(description)) + description + bytes(78),
        b'cprt': b'text\0\0\0\0Copyright 2026 Britey. Apache-2.0.\0',
        b'wtpt': b'XYZ \0\0\0\0' + white,
        b'kTRC': struct.pack('>4sIIH', b'curv', 0, 1, round(1.8 * 256)),
    }
    header = bytearray(128)
    struct.pack_into('>I4s4s4s6H4s', header, 8, 0x02400000, b'mntr', b'GRAY', b'XYZ ',
                     2020, 1, 1, 0, 0, 0, b'acsp')
    header[68:80] = white

    table = bytearray(struct.pack('>I', len(tags)))
    data = bytearray()
    data_start = len(header) + len(table) + 12 * len(tags)
    for signature, value in tags.items():
        table.extend(struct.pack('>4sII', signature, data_start + len(data), len(value)))
        data.extend(value)
        data.extend(bytes(-len(value) % 4))
    struct.pack_into('>I', header, 0, data_start + len(data))
    return bytes(header + table + data)


root = Path(__file__).resolve().parents[6]
out = root / 'android/app/src/androidTest/assets/codec-fixtures'
out.mkdir(parents=True, exist_ok=True)
profiles = root / 'android/vendor/libjxl/third_party/skcms/profiles'
y, x = np.indices((600, 800))
rng = np.random.default_rng(20260921)
a = np.stack((x*255//799, y*255//599, ((x//32+y//32)%2)*180+30), axis=-1).astype('uint8')
a = (a.astype('uint16') + rng.integers(0, 12, a.shape, dtype='uint16')).clip(0,255).astype('uint8')
Image.fromarray(a).resize((1600,1200)).save(out/'pattern-rgb.jpg', quality=93, subsampling=0)
p3 = (profiles/'mobile/Display_P3_parametric.icc').read_bytes()
exif = Image.Exif(); exif[274] = 6
rgba = np.dstack((a, np.where(x<400,0,255).astype('uint8')))
Image.fromarray(rgba).save(out/'pattern-rgba-p3.png', compress_level=0, icc_profile=p3, exif=exif)
gray = (x*255//799).astype('uint8')
Image.fromarray(gray).save(out/'pattern-gray.png', compress_level=0)
gamma = PngImagePlugin.PngInfo(); gamma.add(b'gAMA', struct.pack('>I', 45455))
Image.fromarray(gray).save(out/'pattern-gray-gamma.png', compress_level=0, pnginfo=gamma)
Image.fromarray(gray).save(out/'pattern-gray-icc.png', compress_level=0,
    icc_profile=grayscale_icc_profile())
Image.fromarray((x*65535//799).astype('uint16')).save(out/'high-depth.png', compress_level=0)
swatches = np.zeros((600,800,3), dtype='uint8')
for iy, ix, c in [(0,0,(240,20,30)),(0,1,(30,230,40)),(1,0,(20,30,240)),(1,1,(100,160,220))]:
    swatches[iy*300:(iy+1)*300,ix*400:(ix+1)*400]=c
Image.fromarray(swatches).save(out/'p3-swatches.png', compress_level=0, icc_profile=p3)
manifest = {p.name: {'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in sorted(out.iterdir()) if p.suffix in ('.png','.jpg')}
(out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
