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

So every state gets its **own SF Symbol**, distinguishable by shape. The pace
ladder (see below) supplies eight of them; three more cover the app's own states:

| State | Glyph |
|---|---|
| gateway unreachable | `wifi.slash` |
| enforcement paused | `pause.circle.fill` |
| no data yet | `circle.dotted` |

`RenderTests` asserts all eleven are distinct — both by symbol name and by
rasterised output, since two different names can render identical art. **Never** add
a state whose only distinguishing feature is its tint, and note that
`exclamationmark.triangle.fill` now belongs to the `crit` tier, so the down state
uses `wifi.slash` instead.

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

## The glyph tracks pace; colour tracks percentage

Two independent axes, and it matters that they stay independent:

- **Glyph and animation speed** come from `pace` — burn rate ÷ sustainable rate.
- **Colour** comes from how much of the tracked budget is spent.

So an amber leaf is a real, useful state: calm burn with most of the window gone.
The one crossover is `rip`, which fires on `exhausted` (a percentage condition) and
outranks the whole pace ladder.

### The app and the dashboard use different pace windows

The thresholds are ported exactly (0.85 / 1.2 / 1.6 / 2.0). **The input is not.**

| Surface | Source | Window |
|---|---|---|
| lil-ccgw | `/api/status.primary.pace` | last 60 min, computed by the gateway |
| `/dash` | recomputed from `/api/requests` | last 20 min, extrapolated ×3 |

Measured simultaneously on one machine: the app read pace 1.10× (`warm`) while the
dashboard read 2.00× (`crit`) — different scenes at the same instant. The dashboard
is roughly three times more responsive to a burst.

This is currently a deliberate difference, not a bug: an ambient menu bar icon that
re-tiers every twenty seconds is noise, and the smoother signal is the one worth
trusting at a glance. The trade is that the app escalates later than `/dash` during
a sudden runaway. If that trade is ever revisited, matching the dashboard means
computing burn from `/api/requests` over 20 minutes rather than reading
`primary.pace` — and this table should be updated, not deleted.

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

## Width — measured, not estimated

Menu bar space is contested (other extras, the notch), so these are real numbers
from `NSHostingView.fittingSize` with the sample snapshot, asserted in
`RenderTests.swift`. An earlier version of this section carried estimates that
were wrong by up to 20pt.

| Mode | Width | Renders |
|---|---|---|
| Icon only | 20pt | glyph in a fixed slot |
| Spend only | 61pt | `$9.34` |
| Pace | 61pt | `0.32×` |
| **Spend / limit + window** (default) | **108pt** | `$9.34/$75 5h` |
| Statusline | 215pt | `$9.34/$75 5h │ $23/$1200 30d` |

Statusline is genuinely wide — over twice the default — which is why parity with
the Claude Code statusline is offered but not the default.

### The glyph gets a fixed-width slot

`MenuBarLabel.glyphSlotWidth` is 20pt and the icon renders into
`.frame(width:)`, not at its natural size. This is load-bearing, and it was a
real bug before the fix:

> Each tier animates between two *different* SF Symbols, and different symbols
> measure differently. Natural widths differed by up to 6pt (`payday` 20→14,
> `zen` 18→13, `crit` 13→16, `melt` 15→13), so the status item resized on every
> animation tick and shoved its menu bar neighbours sideways several times a
> second — during `crit` and `melt`, exactly when the icon most needs to be
> readable.

20pt because it's the widest glyph any state uses (`party.popper.fill`); 16pt
clipped both that and `figure.mind.and.body` at 18. **A new glyph wider than the
slot is silently cropped**, so `RenderTests` asserts nothing outgrows it.

### What `monospacedDigit()` actually buys

It equalises the *advance width of digit glyphs*, so `$11.11` and `$88.88`
render identically. It does **not** stop the item growing as the number gains
characters: `$9.34/$75 5h` is 108pt and `$100.00/$75 5h` is ~120pt. Earlier
wording here claimed it prevented width variation outright — it doesn't, and no
formatting choice can, short of padding to a fixed character count.

The rule that matters: **width must never change between two renders of the same
data.** Frame swaps and digit shapes are covered; genuine growth as spend climbs
is acceptable and bounded by a test.

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
