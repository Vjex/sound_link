#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v em++ >/dev/null 2>&1 && [ -f "${EMSDK:-$HOME/emsdk}/emsdk_env.sh" ]; then
  . "${EMSDK:-$HOME/emsdk}/emsdk_env.sh" >/dev/null 2>&1
fi
OUT="$ROOT/../assets/web"
mkdir -p "$OUT"
em++ -std=c++17 -O3 -DGGWAVE_DISABLE_LOG -DNDEBUG \
  -I "$ROOT" -I "$ROOT/ggwave/include" \
  "$ROOT/sound_link_core.cpp" "$ROOT/ggwave/src/ggwave.cpp" "$ROOT/web/sound_link_web_bridge.cpp" \
  -sMODULARIZE=1 -sEXPORT_NAME=createSoundLinkCore -sSINGLE_FILE=1 -sENVIRONMENT=web,worker,node \
  -sALLOW_MEMORY_GROWTH=1 -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPF32,HEAP16,HEAP32 \
  -o "$OUT/sound_link_core.js"
echo "Built $OUT/sound_link_core.js"
