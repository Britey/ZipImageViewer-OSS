#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/source-pins.sh"
dir="${1:?Usage: checkout-source.sh DIRECTORY [android|ios] [--verify]}"
dependencies=(third_party/brotli third_party/highway third_party/skcms)
case "${2:-ios}" in
  android) dependencies+=(third_party/libpng third_party/zlib) ;;
  ios) ;;
  *) exit 2 ;;
esac

fail() { echo "libjxl $JXL_VERSION: $*" >&2; exit 1; }
case "${3:-}" in
  '')
    if [[ ! -e "$dir/.git" ]]; then
      git init -q "$dir"
      git -C "$dir" remote add origin https://github.com/libjxl/libjxl.git
    fi
    if ! git -C "$dir" cat-file -e "$JXL_REVISION^{commit}" 2>/dev/null; then
      git -C "$dir" fetch --depth 1 origin "$JXL_REVISION"
    fi
    git -C "$dir" checkout --detach "$JXL_REVISION"
    git -C "$dir" submodule update --init --depth 1 -- "${dependencies[@]}"
    ;;
  --verify) ;; # Offline configure-time check.
  *) exit 2 ;;
esac

[[ -e "$dir/.git" && "$(git -C "$dir" rev-parse HEAD)" == "$JXL_REVISION" ]] ||
  fail "run android/vendor/bootstrap-jpegxl.sh or the Apple rebuild recipe"
git -C "$dir" diff --quiet --ignore-submodules=all HEAD -- || fail "locally modified libjxl sources"
# Upstream discovers some compilation units by glob. An added source must not
# silently enter a build whose version/attribution is tied to these revisions.
[[ -z "$(git -C "$dir" ls-files --others)" ]] || fail "untracked files in libjxl checkout"
for path in "${dependencies[@]}"; do
  pin="$(git -C "$dir" rev-parse "$JXL_REVISION:$path")"
  [[ -e "$dir/$path/.git" && "$(git -C "$dir/$path" rev-parse HEAD)" == "$pin" ]] ||
    fail "$path must be checked out at $pin"
  dep="$dir/$path"
  extras="$(git -C "$dep" ls-files --others)"
  case "$path:$extras" in
    *:) ;;
    third_party/libpng:pnglibconf.h)
      cmp -s "$dep/pnglibconf.h" "$dep/scripts/pnglibconf.h.prebuilt" || fail "modified generated pnglibconf.h"
      ;;
    third_party/zlib:zconf.h.included)
      [[ "$(git -C "$dep" hash-object zconf.h.included)" == "$(git -C "$dep" rev-parse HEAD:zconf.h)" ]] ||
        fail "modified zconf.h.included"
      ;;
    *) fail "untracked files in $path checkout" ;;
  esac
  # zlib 1.3.1 CMake moves its tracked configuration header aside on configure.
  if [[ "$path" == third_party/zlib && ! -e "$dep/zconf.h" && -f "$dep/zconf.h.included" ]]; then
    git -C "$dep" diff --quiet HEAD -- . ':(exclude)zconf.h' || fail "locally modified $path sources"
  else
    git -C "$dep" diff --quiet HEAD -- || fail "locally modified $path sources"
  fi
done
printf 'Verified libjxl %s (%s) and %d dependency gitlinks.\n' "$JXL_VERSION" "$JXL_REVISION" "${#dependencies[@]}"
