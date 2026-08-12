---
name: menubar-ergonomics
description: Design and implementation guardrails for the lil-ccgw menu bar surface — template rendering, status item lifetime, width, LSUIElement, poll cadence, main-thread rules. Use when changing the menu bar label, the dropdown, or anything about how the app presents itself.
---

# Menu bar ergonomics

Constraints for a macOS Menu Bar Extra, and the reasoning behind each. These are
easy to regress because breaking them usually still compiles and often still
looks fine on the machine it was written on.

## Colour cannot be relied on

SwiftUI renders `MenuBarExtra` labels as **template images** in most
configurations, which flattens colour to monochrome. A design that encodes state
only in colour reads as no state at all.

So every state gets its **own SF Symbol**, distinguishable by shape:

| State | Glyph |
|---|---|
| healthy | `circle.lefthalf.filled` |
| over soft threshold | `exclamationmark.circle.fill` |
| exhausted | `xmark.octagon.fill` |
| enforcement paused | `pause.circle.fill` |
| gateway down | `exclamationmark.triangle.fill` |
| unknown / starting | `circle.dotted` |

Colour is applied as reinforcement where it survives. **Never** add a state whose
only distinguishing feature is its tint.

Use SF Symbols rather than a bundled image: they are template-rendered, adapt to
light and dark menu bars for free, and scale with the menu bar's font metrics.

## Read the model inside `body`, never in an initialiser

This one has already shipped as a bug once. `MenuBarLabel` stores plain values,
so handing it `model.snapshot` from an initialiser reads the `@Observable` model
*outside* body evaluation — and SwiftUI only registers a dependency on
properties read *during* body. The title renders once and freezes. Polling keeps
working, the data stays fresh, and the menu bar silently lies until something
else forces a redraw, which is why it appeared to update "only when I open the
dropdown".

`MenuBarTitle` exists solely to do that read inside `body`. Keep the pure
`MenuBarLabel` for rendering and testing; never add a
`MenuBarLabel.init(model:)` convenience back.

Symptom to watch for: the panel updates correctly (it holds `@Bindable` and
reads in `body`) while the bar title does not.

## No Dock icon means no Dock menu

`LSUIElement` removes the Dock icon, which also removes every affordance users
habitually reach for. Two consequences:

- **Quit and Settings must live in the panel.** They are the only way out.
- **`openSettings()` alone is not enough.** An accessory app never becomes
  active on its own, so the settings window opens *behind* whatever the user was
  in and reads as a dead button. `SettingsWindow.present` calls
  `NSApp.activate(ignoringOtherApps:)` and raises the window. Any future window
  needs the same treatment.

## Animating the icon: two measured facts

**`TimelineView` does not drive a `MenuBarExtra` label.** A probe app that logged
every label body evaluation produced **1 tick in 6 seconds** from
`TimelineView(.periodic(by: 0.32))`, against **17** from an `@Observable` frame
counter advanced by a `Task`. Menu bar labels are hosted differently from
ordinary views. Use `FrameAnimator`; don't reach for `TimelineView` again.

**Each tick costs real CPU, and it is not optimisable from here.** Measured as an
8-sample average of `%cpu`:

| tier | interval | %CPU |
|---|---|---|
| `melt` | 0.18s | 10.0 |
| `crit` | 0.26s | 7.0 |
| `warm` | 0.32s | 5.3 |
| `rip` | 0.9s | 3.3 |
| any | static | **0.0** |

Roughly 1.5% per tick-per-second plus a ~1.6% floor. Isolating the icon into its
own nested view so a tick invalidated only the `Image` was tried and changed
nothing (10.03 → 9.97 at 0.18s), which locates the cost in macOS re-hosting the
status item rather than in anything the body does. **The only levers are tick
rate and the animate toggle.**

Two consequences worth keeping:

- **`ok` is static**, so the common case costs nothing. Animation only runs above
  0.85 pace.
- **The toggle is real, not decoration.** Anyone bothered by a menu bar that
  costs 10% of a core during a runaway needs a way off, and the dashboard sets
  the precedent by gating its own heat vignette behind a preference.

## The preview must share the label's code path

`MenuBarLabel` renders both the live status item and the preview strip in
Settings → Display. That sharing *is* the WYSIWYG guarantee the settings UI
promises. A separate "preview version" of the label would drift the first time
either side changed, and the drift would be invisible until a user noticed the
menu bar disagreeing with the preview that sold them the setting.

When the gateway is unreachable the preview falls back to
`MenuBarLabel.sampleSnapshot()` and **says so in the UI**. Showing zeros as
though they were live is worse than showing nothing.

## Width

Menu bar space is contested — other extras, and the notch on laptop displays.

- Icon-only ≈ 22pt (`NSSquareStatusItemLength` equivalent).
- Text modes use variable width; keep them short and `monospacedDigit()` so the
  item does not jitter as digits change.
- The statusline mode is ~190pt. It is offered because parity with the Claude
  Code statusline is genuinely useful, but it is **not** the default for this
  reason.

Never let width vary with every poll. `monospacedDigit()` on all numerals is what
prevents that.

## Status item lifetime

`MenuBarExtra` manages this. **If this ever drops to `NSStatusItem` directly**,
hold a strong reference to it (`private var statusItem: NSStatusItem!`). The
system status bar does not retain items, and a deallocated item silently removes
its own icon — the classic "my icon vanished immediately" bug.

## LSUIElement

`Info.plist` sets `LSUIElement=true`: no Dock icon, no app switcher entry. This is
what makes it a menu bar app rather than an app that happens to have a menu bar
item. Do not remove it — and note that with no Dock icon, **the only quit
affordance is the one in the panel**, so it must stay.

## Never block the main thread

A hung gateway must never freeze the menu.

- `GatewayClient` is an `actor` with a 3s request timeout.
- `ServiceControl` runs `launchctl` and `ccgw` on a background queue via a
  continuation.
- All three reads in `refresh()` are concurrent `async let`, so one slow endpoint
  does not serialise behind another.

## Poll cadence

`/api/events` is not SSE, so there is no push option — updates are polled.

- Panel open: 5s (default). Fast enough to feel live while watching a burn.
- Panel closed: 30s (default). The menu bar number can lag half a minute; that is
  fine for an ambient signal and keeps the gateway's ledger quiet.

Both are user-configurable in Settings → General. Do not poll faster than 1s.

## Degrade per section, never blank the panel

`refresh()` fetches status, health, and spend independently and stores each on the
snapshot. One failing endpoint hides its own section; it does not empty the panel.
Gateway-down is its own layout with a Start affordance, not an error toast over an
empty panel.

## Destructive actions confirm, and say what breaks

Claude Code points `ANTHROPIC_BASE_URL` at this gateway, so stopping it makes
every Claude request fail with connection refused. Both destructive verbs confirm
first, and the confirmation states the actual consequence:

- **Stop** — also unloads the launchd agent, so it will not return at login until
  Start. (Necessary: `KeepAlive=true` means SIGTERM alone is respawned within a
  second.)
- **Bypass** — takes effect on the **next** Claude Code start, not immediately.

Restart and Pause are non-destructive and do not confirm. Pause auto-reverts, so
it cannot be forgotten.

## Features that degrade when unsigned

There is no Developer ID on the build machine, so the app is ad-hoc signed.

- `UNUserNotificationCenter.current()` **traps** when the process has no bundle
  identifier — true when running the bare binary from `dist/`. `Notifier.isAvailable`
  guards every entry point.
- `SMAppService.mainApp` needs a real bundle and can land in `requiresApproval`.

Both surface their real state in Settings rather than presenting a toggle that
silently does nothing.
