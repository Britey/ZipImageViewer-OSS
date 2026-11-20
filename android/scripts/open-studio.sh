#!/usr/bin/env bash
set -euo pipefail
ZIV_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${ANDROID_STUDIO_HOME:-}" ]]; then
  exec "$ANDROID_STUDIO_HOME/bin/studio" "$ZIV_SCRIPT_DIR/.." "$@"
fi
exec studio "$ZIV_SCRIPT_DIR/.." "$@"
