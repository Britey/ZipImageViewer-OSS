#!/usr/bin/env bash
set -euo pipefail
ZIV_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ZIV_SCRIPT_DIR/env.sh"
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 AVD_NAME [emulator options]" >&2
  exit 2
fi
ZIV_AVD="$1"
shift
exec emulator -avd "$ZIV_AVD" -accel on -gpu software -no-snapshot -no-boot-anim -no-audio \
  -memory "${ZIV_EMULATOR_MEMORY_MB:-2048}" -cores "${ZIV_EMULATOR_CORES:-2}" "$@"
