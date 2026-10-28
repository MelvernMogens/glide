#!/bin/bash
# Measure real scrolling in whatever app is under (X,Y): film a strip with --scrollcam while
# injecting mouse-like wheel ticks, then restore the pointer.
# Usage: tools/m1-film.sh <x> <y> <strip_h> <label> [inject args...]
set -u
X=$1; Y=$2; H=$3; LABEL=$4; shift 4
B=$(cd "$(dirname "$0")/.." && swift build --show-bin-path)/Glide
T=${TMPDIR:-/tmp}
OUT=/tmp/glide-film-$LABEL
OLD=$("$T/cur" | tr -d '() ')
"$T/warp" "$X" "$Y"; sleep 0.3
"$B" --scrollcam "$X" "$Y" "$H" 2.5 > "$OUT.cam" &
CAM=$!
sleep 0.25
"$B" --inject "$@" > "$OUT.inj"
wait $CAM
"$T/warp" "${OLD%,*}" "${OLD#*,}"
echo "pointer restored to $OLD; wrote $OUT.cam $OUT.inj"
