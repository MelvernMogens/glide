# glide

## What this is
Glide is a native macOS menu-bar app that makes a normal mouse wheel feel like the trackpad:
smooth, inertial, rubber-banding scroll events with trackpad phases, plus optional button remaps
and gestures. It replaces Mac Mouse Fix for Melvern's own Mac; the defaults are his MMF settings
(High smoothness, Medium speed, reversed = natural, trackpad simulation on, ⌘ zoom / ⌥ precise /
⇧ horizontal / ⌃ swift, no remaps).

## Stack
- Swift 6 toolchain, SwiftPM, language mode 5, no Xcode project — matches the other menu-bar apps (kopi, fader).
- `GlideKit` (Foundation only): settings, scroll curves, tick acceleration, button state machine — all unit-tested.
- `Glide` executable: CGEventTap engine thread, event synthesis, AppKit status item + SwiftUI views.
- Private APIs via `dlsym` only (CoreDock, IOHIDEvent, SLEventSetIOHIDEvent, CGS spaces).
- Rejected: Xcode project (SwiftPM is enough), Karabiner/DriverKit (needs a driver), a HID-level tap like MMF (spec asks for a session tap; own events are tagged instead).

## Commands
- Test: `swift test` (GlideKit unit tests)
- Build debug: `swift build` → `.build/debug/Glide`
- Build + install app: `scripts/build-app.sh --install` (signs with `~/.glide-signing`; run `scripts/make-signing-identity.sh` once on a new Mac)
- Icon: `swift scripts/make-icon.swift`
- Headless proof: `.build/debug/Glide --probe 30` (tap with defaults, prints counters + latency percentiles)
- Fake mouse: `Glide --inject <n> <interval> [up|down] [continuous] [horizontal] [flags=cmd,opt,shift,ctrl]`
- Film real scrolling: `tools/m1-film.sh <x> <y> <h> <label> <inject args>` then `python3 tools/film-summary.py <label>`
- Event log window: `Glide --receiver /tmp/rx.jsonl` · menu snapshot: `Glide --snapshot out.png`
- App flags: `--settings` opens the settings window, `--open-menu` pops the dropdown
- CPU/RAM: `top -l 3 -pid $(pgrep -x Glide) -stats pid,cpu,mem`

## Milestones — status and which model to use
Product scope, the MMF feature checklist, non-goals, and open questions live in `docs/prd.md`.

| # | Scope | Status | Model / effort |
|---|---|---|---|
| M1 | Headless tap: smooth + reversed + phased scrolling, trackpad untouched, latency < 1 frame | done | strongest / high |
| M2 | Menu-bar dropdown, settings, launch at login | done | strongest / high |
| M3 | Button remaps, drag/scroll gestures, per-app exceptions | done (gestures need real-mouse check) | strongest / high |

Default is your strongest model + high effort.

**State the model and effort at the start of every milestone, before working.**

## Gotchas (each cost a debugging round)
- Synthesized events are routed by their `location`; `CGEvent(scrollWheelEvent2Source:)` does not fill it — set it to the cursor or nothing receives the event.
- Occluded windows (other Space, behind a full-screen app) don't receive or render scroll events, so real-app tests need the target window frontmost under the pointer. `postToPid` does not help.
- macOS "Natural scrolling" flips real wheel deltas before the tap; Glide inverts only when `reverseDirection != system natural`.
- macOS 27 dock swipes ignore CGEvent fields; they need an IOHIDEvent attached with `SLEventSetIOHIDEvent`.
- TuckBar hides new status items: `defaults write com.melvern.tuckbar sections -dict-add com.melvern.glide visible` and restart TuckBar.

## Conventions
- Ask before adding a dependency (there are none).
- Never commit secrets; the signing keychain lives in `~/.glide-signing`.
- No allocation, logging or locks inside the tap callback path.

## House rules
- Show a plan before multi-file changes.
- Before adding a feature to working code, run the tests FIRST.
- Before committing a feature, run `git diff --stat` and justify every file.
- If the diff contradicts a sentence in a doc, that sentence is part of the diff.
- After editing, run the test command and report the real result, not the expected one.
- If you are unsure, say so instead of guessing.
