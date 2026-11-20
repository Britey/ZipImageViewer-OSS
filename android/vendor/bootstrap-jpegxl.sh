#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
exec "$root/../../Vendor/JPEGXL/Scripts/checkout-source.sh" "$root/libjxl" android
