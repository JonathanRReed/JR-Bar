#!/bin/sh
# Builds hook/build/jrbar-hook with the Command Line Tools' clang.
# JRBAR_HOOK_BUILD_DIR picks another output directory (packaging).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${JRBAR_HOOK_BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT"
CC="${CC:-/usr/bin/clang}"
"$CC" -O2 -Wall -Wextra -std=c11 -o "$OUT/jrbar-hook" "$HERE/jrbar-hook.c"
echo "built $OUT/jrbar-hook"
