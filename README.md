# Glide

A tiny native menu-bar app that makes a normal mouse wheel scroll like the MacBook trackpad.

Glide replaces Mac Mouse Fix on one Mac. It ships with the same out-of-the-box feel: High smoothness,
Medium speed, reversed mouse direction (traditional wheel while the trackpad stays natural), trackpad simulation on, and ⌘ zoom / ⌥ precise /
⇧ horizontal / ⌃ swift modifiers. It has no licence, trial, updater or helper app.

---

## How it works

```
 mouse wheel tick (discrete, IsContinuous = 0)
        │
        ▼
 CGEventTap (session, head insert) ── trackpad / Magic Mouse (IsContinuous = 1) ──► untouched
        │  swallow tick, record it in a fixed buffer (no alloc, no lock, no log)
        ▼
 kick run-loop source (same engine thread, right after the callback returns)
        │  TickAccelerator: px/tick from spin speed + fast-scroll ramp
        │  ScrollAnimator: HybridCurve = eased base push → drag-physics inertia tail
        ▼
 CADisplayLink @ display rate ──► pixel scroll events with trackpad phases
                                   Began/Changed → Ended → Momentum → MayBegin+Cancelled
                                   (+ a companion type-29 gesture event, like the trackpad driver)
```

Each tick plans a new curve that carries over what the running one hasn't delivered yet, so
distance is never lost or doubled. One notch the other way stops the scroll (throw and catch).
Apps see trackpad-like events and do their own rubber-banding and inertia.

Buttons 3/4/5 can be remapped (click / double-click / hold). Hold + drag gives three-finger swipes
(Spaces, Mission Control), and hold + scroll gives pinch zoom or Desktop & Launchpad. Remaps are off
by default, and an untouched button is never intercepted.

## What this does and does not promise

- Feel numbers (px per tick, curve lengths, drag coefficients, fast-scroll ramp) come from Mac Mouse
  Fix 3.1's source. Apps with their own momentum engines (Xcode, iPad apps, games) still behave
  their own way. Use per-app exceptions for games.
- Dock-swipe gestures on macOS 27 depend on a private IOHIDEvent attachment (`SLEventSetIOHIDEvent`).
  A macOS update can break them silently. One-shot actions (Mission Control, Show Desktop…) use
  CoreDock and are sturdier.
- The latency number is Glide's own processing time, from the tap callback to the first posted
  event. Rendering in the target app comes after that and isn't in the number.

Measured on the dev Mac (M-series MacBook, 60 Hz, macOS 27.0.1) with `tools/headless-bench.py`:

| | Result | Budget |
|---|---|---|
| Tap → first event posted | p50 0.11 ms · p99 0.71 ms · max 1.9 ms (n = 330) | < 1 frame (16.7 ms) |
| CPU idle | 0.0 % | ~0 % |
| CPU, continuous scrolling at 33 ticks/s | 1.0–1.7 % | < 3 % |
| Memory (probe / full app with menu) | 7.7 MB / 17 MB footprint | < 30 MB |
| `kill -9` mid-fling | tap count 1 → 0, input back to stock | no stuck tap |

## Stack

| Part | Choice |
|---|---|
| Language / build | Swift 6 toolchain, SwiftPM, language mode 5, no Xcode project |
| Pure logic | `GlideKit` (Foundation only), 83 XCTest unit tests |
| App | AppKit status item + SwiftUI views, CGEventTap, CADisplayLink |
| Private APIs | `dlsym` only: CoreDock, IOHIDEvent, SLEventSetIOHIDEvent, CGS spaces |
| Signing | self-signed identity in `~/.glide-signing`, so the Accessibility grant survives rebuilds |

## Getting started

```bash
scripts/make-signing-identity.sh      # once per Mac
swift test                            # unit tests
scripts/build-app.sh --install        # build, sign, copy to /Applications, launch
```

Then turn on **Glide** in System Settings → Privacy & Security → Accessibility. Until you do, the
menu shows a single "Allow Glide in Accessibility" line. Glide starts by itself once the permission
is granted.

## Commands

| Command | What it does |
|---|---|
| `swift test` | GlideKit unit tests: curves, NaN/clamping, acceleration, modifiers, settings, button state machine |
| `.build/debug/Glide --probe 30` | Runs the tap headless with the defaults, then prints counters and latency percentiles |
| `Glide --inject 12 0.03 down [continuous] [flags=shift]` | Fake mouse (or trackpad) ticks at the HID level |
| `tools/m1-film.sh x y h label …` + `tools/film-summary.py label` | Films a screen strip while injecting, then measures real on-screen motion |
| `python3 tools/headless-bench.py` | Latency, CPU, RAM and kill-safety checks without touching the screen |
| `python3 tools/m1-live.py all` | Full live proof in Safari, Finder, Hermes, gestures and the menu. Takes over the screen for about 3 minutes |
| `Glide --receiver log.jsonl` | Test window that logs every scroll event's phase, delta and timing |
| `Glide --snapshot out.png` | Renders the dropdown offscreen |
| `Glide --login-item on\|off\|status` | SMAppService launch at login, run from the installed bundle |

## Gotchas worth knowing

- **Synthesized scroll events need a location.** `CGEvent(scrollWheelEvent2Source:)` leaves it at
  (0,0), and then nothing receives the event. Glide sets the location to the cursor on every event.
- **Off-screen windows ignore scroll events.** A window on another Space or behind a full-screen app
  gets none, and `postToPid` doesn't help. Real-app tests need the window in front, under the pointer.
- **Natural scrolling is one shared system setting.** Real wheel deltas arrive already flipped. Glide
  inverts only when `reverseDirection != com.apple.swipescrolldirection`, so the trackpad keeps its
  own setting.
- **macOS 27 dock swipes ignore CGEvent fields.** They only work with an IOHIDEvent attached.

## Roadmap

| Milestone | Status |
|---|---|
| M1: headless tap with smooth, reversed, phased scrolling and the trackpad untouched | done (live app film pending) |
| M2: menu-bar dropdown, settings, launch at login | done |
| M3: remaps, drag/scroll gestures, per-app exceptions | done (live gesture check pending) |

The full Mac Mouse Fix feature checklist, with each item ticked or marked as cut, is in
[`docs/prd.md`](docs/prd.md).

## Docs
- [`docs/prd.md`](docs/prd.md): scope, the MMF parity checklist and open questions
- [`docs/security.md`](docs/security.md): threat model
- [`HERMES.md`](HERMES.md): working notes and commands
