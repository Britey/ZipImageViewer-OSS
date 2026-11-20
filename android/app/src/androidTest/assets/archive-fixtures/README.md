# Reader UI fixture

`field-notes.cbz` contains twelve project-generated Field Notes image pages.
It was moved unchanged from the former production `demo.cbz` asset. It is loaded
only from the instrumentation APK by AppSmokeTest and NativeProtocolTest, and
by the disposable emulator smoke script through the real document picker.
It must never be added to a main/debug/release asset source set.

The other archive fixtures and their provenance are recorded in `manifest.json`.

SHA-256 for `field-notes.cbz` after moving it into the test assets:

`d51322b1be8ba622068e6332e8207f992f5cd9f328ea1094fd927d541da6d059`
