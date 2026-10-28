#!/bin/bash
# Off-screen M1 measurement in a real app window (works while the user keeps using the Mac:
# no pointer warp, no window switching). Films the window with --scrollcam (GLIDE_CAM_WINDOW)
# while wheel ticks are delivered either stock (straight to the app) or through Glide
# (HID-level ticks -> Glide's tap -> Glide output delivered to the window via GLIDE_TARGET).
#
# Usage: tools/m1-offscreen.sh <label> <stock|glide> <pid> <windowID> <x> <y> <strip_h> <inject args...>
#   x,y = a point inside the window, in global CG points.
set -u
LABEL=$1; MODE=$2; PID=$3; WIN=$4; X=$5; Y=$6; H=$7; shift 7
B=$(cd "$(dirname "$0")/.." && swift build --show-bin-path)/Glide
OUT=/tmp/glide-film-$LABEL
PROBE=""
if [ "$MODE" = glide ]; then
  GLIDE_TARGET="$PID,$WIN,$X,$Y" ${GLIDE_ENV:-} "$B" --probe 8 > "$OUT.probe" 2>&1 &
  PROBE=$!
  sleep 1.2
fi
GLIDE_CAM_WINDOW=$WIN "$B" --scrollcam "$X" "$Y" "$H" 3 > "$OUT.cam" &
CAM=$!
sleep 0.3
if [ "$MODE" = glide ]; then
  "$B" --inject "$@" > "$OUT.inj"
else
  "$B" --inject "$@" "direct=$PID,$WIN,$X,$Y" > "$OUT.inj"
fi
wait $CAM
[ -n "$PROBE" ] && kill "$PROBE" 2>/dev/null
exit 0
