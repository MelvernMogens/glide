#!/usr/bin/env python3
"""Summarise a tools/m1-film.sh run: direction, distance, smoothness, visual latency."""
import re, sys

label = sys.argv[1]
cam = open(f"/tmp/glide-film-{label}.cam").read()
inj = open(f"/tmp/glide-film-{label}.inj").read()
ticks = [float(m) for m in re.findall(r"INJECT \d+ t=([\d.]+)", inj)]
frames = [(float(t), float(s)) for t, s in re.findall(r"SCROLLCAM t=([\d.]+) shift=(-?[\d.]+)", cam)]
if not ticks:
    sys.exit("no ticks")
if not frames:
    print(f"{label}: ticks={len(ticks)} NO MOTION SEEN"); sys.exit(0)
t0 = ticks[0]
moving = [f for f in frames if f[0] >= t0]
total = sum(s for _, s in moving)
first = moving[0][0] - t0 if moving else float("nan")
span = moving[-1][0] - moving[0][0] if moving else 0
biggest = max(abs(s) for _, s in moving) if moving else 0
signs = {1 if s > 0 else -1 for _, s in moving}
print(f"{label}: ticks={len(ticks)} frames_with_motion={len(moving)} total={total:+.1f}pt "
      f"biggest_frame={biggest:.1f}pt motion_span={span*1000:.0f}ms first_motion_after={first*1000:.1f}ms "
      f"direction={'content-up' if total < 0 else 'content-down'} sign_flips={'yes' if len(signs) > 1 else 'no'}")
