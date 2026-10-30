# PRD — Glide

Status: MVP built (M1–M3). Living document — correct it when reality disagrees.

## 1. The problem
A normal mouse wheel on macOS scrolls in hard, line-sized jumps with no inertia and no rubber-band,
and side buttons do nothing useful. Melvern used Mac Mouse Fix (MMF) to fix that; Glide replaces it
for his own use with the same out-of-the-box feel and no licence, trial or updater.

## 2. What we are building
A native menu-bar app (Swift, SwiftPM, no Xcode project). One session-level CGEventTap swallows
discrete wheel ticks from a normal mouse and re-emits them as display-synced, trackpad-like pixel
scroll events (gesture phase → momentum phase → rest tap), so apps rubber-band and glide. The
trackpad and Magic Mouse (continuous events) are never touched. Optional button remaps and
gestures (dock swipes, pinch, smart zoom) reuse the same tap.

## 3. Who it is for
Melvern, on his MacBook (macOS 27), with whatever USB/Bluetooth mouse he plugs in. Single user,
not distributed.

## 4. What "done" means for the MVP
Builds clean; unit tests green with counts; `glide --probe` proven on real scrolling in Safari,
Finder and Hermes (Electron) with tap-to-post latency < 1 frame; trackpad untouched; menu verified
on screen; launch at login works; idle CPU ≈ 0 %, scrolling CPU < 3 %, RAM < 30 MB; pushed to a
private GitHub repo.

## 5. Scope
### In
- Smooth scrolling (off / low / medium / high), speed (slow / medium / fast), mouse-only reverse
  direction, trackpad simulation, scroll modifiers ⌘ zoom · ⌥ precise · ⇧ horizontal · ⌃ swift.
- Button remaps for buttons 3/4/5 (click / double-click / hold) → Mission Control, App Exposé,
  Show Desktop, Launchpad, Back/Forward, Smart Zoom, middle-click, custom shortcut. Off by default.
- Hold button + drag → three-finger swipe (Spaces, Mission Control, App Exposé).
- Hold button + scroll → pinch zoom, or four-finger pinch (Desktop & Launchpad), or Spaces.
- Per-app exceptions: smoothing off in chosen apps (games).
- Menu-bar dropdown + small dark settings window + launch at login.

### Out (deliberately, for now)
Licensing, updates, localisation, pointer speed/acceleration, MMF's capture-a-button "+" field,
triple-click and click-and-drag scroll ("Scroll & Navigate"), rotate gesture. See §10 and the
feature checklist below.

## 6. What not to oversell
- Safe to say: "the wheel scrolls like the trackpad in normal AppKit, WebKit and Chromium/Electron
  views — inertia and rubber-band included."
- Not safe to say: "identical to MMF in every app". Curves follow MMF 3.1's published numbers, but
  apps with their own momentum engines (Xcode, iPad apps, games) behave their own way, and dock
  swipes on macOS 27 rely on a private IOHIDEvent attachment (`SLEventSetIOHIDEvent`) that Apple
  can break in any update — MMF documents the same fragility ("transitions sometimes get stuck").
- The latency claim is Glide's own processing (tap callback → first event posted). Pixels on
  screen also wait for the app to render and the compositor, which Glide doesn't control.

## 7. Constraints that shape the build
- Accessibility permission is required for an active tap. A stable self-signed identity
  (`scripts/make-signing-identity.sh`) keeps the grant across rebuilds.
- The tap callback must never block: no allocation, no logging, no locks. Everything runs on one
  engine thread (tap + kick run-loop source + CADisplayLink), so state needs no locking.
- Private APIs (CoreDock notifications, IOHIDEvent, SLEventSetIOHIDEvent, CGS spaces) are resolved
  with `dlsym`; a missing symbol disables that feature instead of crashing.
- macOS's "Natural scrolling" is one shared setting for mouse and trackpad; Glide's reverse toggle
  makes the mouse natural regardless, leaving the trackpad alone.

## 8. Parts inventory
Engine thread · event tap + re-enable · tick accelerator · hybrid curve animator · event synthesis
(scroll + gesture companion, magnify, smart zoom, navigation swipe, dock swipe, keys, clicks) ·
button state machine · gesture glue · settings store · menu-bar UI · settings window · launch at
login · permission watcher · probe / inject / scrollcam / receiver / snapshot tools · signing + bundle.

### Feel parity (numbers taken from MMF 3.1 `ScrollConfig.swift`)
| Smoothness | px/tick at Medium (slow→fast spin) | Base curve | Inertia tail v' = −a·vᵇ | Fast-scroll ramp |
|---|---|---|---|---|
| Off | passthrough (direction/axis only) | – | – | – |
| Low (= MMF Regular) | 60 → 120 | linear 180→110 ms | a 23, b 1.0, stop 30 px/s | t 3, p 1.33, c 7.5 |
| Medium | 75 → 150 | linear 200 ms | a 32, b 0.85 | t 2 |
| High (= MMF High) | 90 → 180 | linear 220 ms (MMF LineHybridCurve) | a 40, b 0.7, stop 30 px/s | t 2, p 1.33, c 7.5 |
| ⌥ Precise | 10 → 20 | linear 140 ms | a 15, b 1.05, stop 50 | none |
| ⌃ Swift | 0.5 → 1.5 × 85 % of screen height | linear 300 ms | a 30, b 0.7 | t 1, p 2, c 10 |
| ⌘ Zoom | 60 → 120 / 800 magnification | ease 250 ms | none | t 3 |

Spin speed maps 6.25 → 66.7 ticks/s (160 ms → 15 ms intervals) onto min → max px.
Trackpad phases: Began/Changed for at least the first 160 ms and during the base curve, Ended,
momentum Begin/Continue/End for the tail, then a MayBegin+Cancelled rest tap.

### Mac Mouse Fix 3.1 feature checklist (source: macmousefix.com, GitHub releases, MMF source @ d1b42d7)
Legend: ✅ in Glide · 🔶 partial / different · ❌ cut (reason)

**Scrolling**
- ✅ Smoothness Off / Regular / High → Glide Off / Low (=Regular) / Medium (between) / High
- ✅ Trackpad Simulation (rubber-band, app momentum) — default ON
- ✅ Speed Low / Medium / High → Slow / Medium / Fast · ❌ "macOS" speed (Melvern uses Medium)
- ❌ Always-on "Scroll Precisely" checkbox (the ⌥ modifier covers it)
- ✅ Reverse Direction = flip the system direction for the mouse only (natural trackpad → traditional wheel)
- ✅ Keyboard modifiers: Zoom ⌘ · Horizontal ⇧ · Swift ⌃ · Precise ⌥, each reassignable, one behaviour per modifier
- ✅ Acceleration by wheel speed · ✅ fast-scroll ramp over consecutive swipes
- ✅ Throw and catch: one notch the other way stops the animation
- ✅ Horizontal wheel / tilt smoothed and inverted like vertical
- 🔶 Free-spinning wheels: 64-tick buffer + curve; not MMF's exact duration cap
- ✅ VSync-synced output (CADisplayLink at the display rate)
- ✅ Two-finger "rest tap" (MayBegin+Cancelled) so apps stop their own momentum
- ✅ Trackpad / Magic Mouse ignored (IsContinuous) · ❌ Wacom-specific filter (no tablet here)
- 🔶 ~0 % CPU when idle (display link paused; the tap stays installed — MMF removes it when settings equal stock)
- ❌ Speed scales with display size (10 % effect; skipped)

**Buttons**
- ❌ "+" capture field and arbitrary buttons 3–32 → Glide: buttons 3, 4, 5 via pickers (as asked)
- ✅ Click / Double Click / Hold · ❌ Triple click, click-and-hold combos, keyboard-modifier + button triggers
- Actions: ✅ Smart Zoom · ✅ Middle Click · ✅ Back / Forward (per-app universal routing) · ✅ Mission Control
  · ✅ App Exposé · ✅ Show Desktop · ✅ Launchpad · ✅ Keyboard Shortcut… · ❌ Look Up & Quick Look
  · ❌ Primary/Secondary click · ❌ Move Left/Right a Space (use the drag gesture) · ❌ media/brightness keys
- ✅ Click and Drag → "Spaces & Mission Control" (dock swipes, 1:1 with the pointer) · ❌ "Scroll & Navigate" drag
- ✅ Click and Scroll → Zoom · ✅ Desktop & Launchpad · ✅ Move Between Spaces · ❌ Horizontal / Rotate / Swift / Precise variants
- ❌ Lock pointer during drag gestures (trackball option)
- ❌ 3-button / 5-button default presets (no remaps by default, as asked)

**App-specific**
- ✅ Per-app exceptions (smoothing off) — MMF 3 removed these; Glide brings them back
- ✅ Universal Back/Forward routing · ❌ Chromium zoom boost

**Settings / UI**
- ✅ Menu-bar item: on/off, smoothness, speed, reverse, Settings…, Quit
- ✅ Small dark settings window · ✅ Accessibility state shown inline, no modal
- ❌ Tabs/animated window, toasts, Restore Defaults, localisation, About/licence/trial/Sparkle/beta channel

**Misc**
- ✅ Launch at login (SMAppService) · ❌ licensing, iCloud licence sync, Homebrew cask, helper app

## 9. Milestones
| # | Slice | Proof |
|---|---|---|
| M1 | Headless tap + smoothing + reverse + phases (`glide --probe`) | Safari / Finder / Hermes filmed, trackpad passthrough, latency numbers |
| M2 | Menu-bar dropdown, settings persistence, launch at login | Screenshot of the live menu, SMAppService status |
| M3 | Remaps, drag/scroll gestures, per-app exceptions | Button state-machine tests + live Mission Control / Spaces check |

## 10. Backlog
Look Up action · triple-click triggers · Scroll & Navigate drag · rotate · Chromium zoom boost ·
display-size speed scaling · remove the tap when every setting equals stock · pointer lock during
drag · per-app exceptions for remaps (not only smoothing).

## 11. Open questions
- Which physical mouse is the daily one? Free-spinning wheels (Logitech MX) may need MMF's stricter
  animation cap; tune after real use.
- If Apple changes the IOHIDEvent attachment again (as macOS 27 did), dock-swipe gestures break
  silently. One-shot Mission Control / Show Desktop actions use CoreDock and keep working.
- Launch at login uses SMAppService.mainApp, which needs the app in /Applications; moving the app
  breaks it (re-toggle in Settings).
