#!/bin/bash
# M1 receiver test: park the pointer on the Glide Receiver window, inject mouse-like wheel ticks
# and a trackpad-like continuous burst, then put the pointer back where it was.
# Usage: tools/m1-inject.sh <x> <y> <bin>
set -u
X=$1; Y=$2; B=$3
T=${TMPDIR:-/tmp}
OLD=$("$T/cur" | tr -d '()' | tr -d ' ')
"$T/warp" "$X" "$Y"; sleep 0.25
"$B" --inject 1 0.05 down > /tmp/inj1.out; sleep 0.8
"$B" --inject 12 0.03 down > /tmp/inj2.out; sleep 1.6
"$B" --inject 10 0.016 down continuous > /tmp/inj3.out; sleep 0.6
"$B" --inject 6 0.05 up flags=shift > /tmp/inj4.out; sleep 0.8
"$B" --inject 6 0.05 down flags=opt > /tmp/inj5.out; sleep 0.8
"$T/warp" "${OLD%,*}" "${OLD#*,}"
echo "restored pointer to $OLD"
