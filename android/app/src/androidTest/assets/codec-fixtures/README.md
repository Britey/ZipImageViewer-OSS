# Native codec fixtures

Images are deterministic synthetic patterns generated for this project by
`android/app/src/main/cpp/tests/generate-codec-fixtures.py`, using Pillow and
NumPy. No photos or third-party visual artwork are included. manifest.json
records byte size and SHA-256. The fixtures exercise full JPEG reconstruction,
PNG grayscale and 16-bit fallback, alpha-on-white and EXIF orientation 6,
Display P3 color preservation and grayscale transfer-function conversion.

`pattern-gray-icc.png` embeds a grayscale ICC v2 display profile created by
the generator from a D50 white point and a gamma of 1.8. The project licenses
this profile under Apache-2.0. Its transfer curve differs from the gamma
chunk in `pattern-gray-gamma.png` so the test can distinguish the two paths.

The two color fixtures embed `profiles/mobile/Display_P3_parametric.icc`
from the pinned libjxl skcms submodule at
`96d9171c94b937a1b5f0293de7309ac16311b722`. The skcms BSD license is
included in the application assets and checkout. Fixtures and native
instrumentation are included only in the test APK.
