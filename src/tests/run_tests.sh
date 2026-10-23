#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${TMPDIR:-/tmp}/sound_link_core_test"
clang++ -std=c++17 -O2 -Wall -DGGWAVE_DISABLE_LOG \
  -I "$ROOT" -I "$ROOT/ggwave/include" \
  "$ROOT/sound_link_core.cpp" "$ROOT/ggwave/src/ggwave.cpp" "$ROOT/tests/sound_link_core_test.cpp" \
  -o "$BUILD"
"$BUILD"
