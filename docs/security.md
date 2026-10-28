# Threat model — Glide

Re-read at the start of each milestone.

## What we protect, and from whom

| Asset | Adversary | Why it matters |
|---|---|---|
| Every mouse/scroll event on the machine | A bug in Glide (hung or crashed tap) | A stuck tap freezes input system-wide |
| The Accessibility grant | Any other binary signed with Glide's identity | Accessibility = control of the whole desktop |
| Keyboard shortcut remaps | Glide replaying the wrong keys | A shortcut posted to the wrong app can do damage (⌘Q, ⌘⌫) |

Glide has no network, no accounts and no secrets. Its attack surface is local input handling.

## Current posture
- The tap callback never blocks and never allocates; taps disabled by timeout/user input are
  re-enabled immediately. If Glide dies, the system drops its tap and input returns to stock.
- Glide only taps scroll + other-mouse events (no keyboard tap), so it cannot keylog.
- Own events are tagged (`eventSourceUserData`) and skipped, so Glide never feeds back on itself.
- The signing key lives in `~/.glide-signing` (own keychain, outside the repo). Anyone holding it
  could sign a binary that inherits the grant — acceptable on a single-user Mac.
- Private APIs are resolved with `dlsym` and optional; a missing symbol disables a feature.

## Rules that must hold
- No allocation, logging or locks in `tapCallback` / `Engine.handleScroll` / `ButtonGlue.handle`
  (buffers are fixed-size and pre-allocated; enforced by review).
- Shortcut remaps only post the exact key + modifiers the user recorded (enum-driven actions,
  nothing assembled from external data).
- `.glide-signing`, `*.p12` and `*.pem` never get committed (CI secret scan).

## Accepted risks
- `SLEventSetIOHIDEvent` and `CoreDockSendNotification` are private and can change in any macOS
  update; the failure mode is "gesture does nothing", not a crash.
