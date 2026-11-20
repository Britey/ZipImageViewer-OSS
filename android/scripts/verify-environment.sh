#!/usr/bin/env bash
set -euo pipefail
ZIV_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ZIV_SCRIPT_DIR/env.sh"
java -version
adb version
emulator -accel-check
emulator -list-avds
"$ZIV_SCRIPT_DIR/../gradlew" -p "$ZIV_SCRIPT_DIR/.." --version
