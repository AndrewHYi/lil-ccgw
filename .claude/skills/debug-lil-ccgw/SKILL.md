---
name: debug-lil-ccgw
description: Symptom-to-cause guide for lil-ccgw and its ccgw gateway — frozen menu bar title, everything showing dashes, Stop or Settings appearing to do nothing, numbers disagreeing with the dashboard, high CPU, jittering icons, bumper 400s, and broken Homebrew after brew audit. Use when something is misbehaving, before re-deriving a diagnosis from scratch.
---

# Debugging lil-ccgw

Every entry below is a failure that actually happened, with the cause that turned
out to be true. Check here before theorising.

## First: is the gateway even up?

Most "the app is broken" reports are "the gateway isn't running", and the two look
identical from the menu bar.

```sh
curl -sf -m2 http://127.0.0.1:8484/api/health && echo " ← up"
launchctl print gui/$(id -u)/io.ccgw.gateway >/dev/null 2>&1 && echo "agent loaded" || echo "agent NOT loaded"
lsof -nP -iTCP:8484 -sTCP:LISTEN            # what, if anything, is serving
```

Those three can disagree, and the combination is the diagnosis:

| Health | Agent | Meaning |
|---|---|---|
| up | loaded | normal |
| down | loaded | wedged process — `launchctl kickstart -k gui/$(id -u)/io.ccgw.gateway` |
| down | not loaded | deliberately stopped — `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.ccgw.gateway.plist` |
| **up** | **not loaded** | **orphan.** A process outlived its agent. `bootout` exits 3 and does nothing; `ccgw stop` says "not running" because its pidfile is gone. Kill the listener by PID. |

## Symptom → cause

**Menu bar title never updates; it only changes when I open the panel.**
The label read the `@Observable` model outside `body`. SwiftUI only registers a
dependency on properties read *during* body evaluation, so the label renders once
and freezes while polling continues happily. Use `MenuBarTitle`, which does the
read inside its own `body`. Never add a `MenuBarLabel.init(model:)` convenience —
that was the bug. Tell-tale: the panel is correct and current while the title is
stale.

**Everything shows dashes / the icon is a warning triangle.**
The gateway isn't answering. Run the checks above, or the four-point preflight in
`install-lil-ccgw`. This is a state, not an error — the app is working correctly.

**Stop appears to do nothing.**
Two separate traps, both real:
1. `ccgw stop` only SIGTERMs the pid, and the LaunchAgent sets `KeepAlive=true`, so
   launchd respawns it within a second.
2. `launchctl bootout` **exits 3 and does nothing** when the agent isn't loaded,
   which is exactly the orphan case above.
`ServiceControl.stop()` therefore unloads first (tolerating exit 3), then
terminates whatever still holds the port.

**Settings does nothing when clicked.**
`LSUIElement` apps never become active on their own, so the window opens *behind*
whatever the user was in. `SettingsWindow.present` calls
`NSApp.activate(ignoringOtherApps:)` and raises it. Any new window needs the same.

**There's no Dock icon, so how do I quit or open Settings?**
Both live in the panel. That's forced by `LSUIElement` — there is no Dock menu to
put them in.

**Panel numbers disagree with `/dash`.**
In order of likelihood:
1. **Timing.** At ~$14/hr, spend moves ~$0.24 a minute. `/dash` polls status every
   4s; the closed panel every 30s. Opening the panel forces a read. Cents apart is
   timing; dollars apart is a bug.
2. **Different windows.** The panel's model breakdown covers the *tracked budget's*
   window and labels it. The dashboard's breakdown defaults to 1 day with its own
   selector.
3. **Different questions.** The title tracks a 5-hour rolling window; Anthropic's
   usage page is month-to-date. Compare the panel's `monthly 30d` row instead.
4. **A renamed field.** Then it's genuinely broken — check `ccgw-api-contract`.

**ccgw's monthly total doesn't match Anthropic's usage page.**
Two effects that partly cancel, both expected:
- ccgw only sees what it proxied. Spend from before `ANTHROPIC_BASE_URL` was wired
  is absent. Find when capture began:
  `sqlite3 -readonly ~/.ccgw/ledger.db "SELECT datetime(MIN(ts)/1000,'unixepoch') FROM requests;"`
- ccgw prices at published API list rates by design, so it runs a few percent high
  on negotiated plans.

A few percent is the measurement model. A large or growing gap is worth digging into.

**High CPU while idle.**
Icon animation. Measured: ~10% of a core at `melt` (0.18s frames), ~7% at `crit`,
~5% at `warm`, **0% static**. It is the cost of invalidating a hosted menu bar view
per frame — isolating the icon into its own nested view was tried and changed
nothing. Levers: the animate toggle in Settings → Display, or the frame intervals.

**Menu bar icons shuffle sideways while the icon animates.**
The glyph is rendering at natural width. Each tier animates between two different
SF Symbols with different widths (up to 6pt apart), so the status item resizes
every tick. `MenuBarLabel` renders the glyph into a fixed 20pt slot for this
reason; `RenderTests` asserts frame pairs measure equal.

**A budget's `+ bumper` returns 400.**
The overall ceiling — the widest-window `block` budget — cannot be bumped, by
design. The UI hides the button there via `Budget.isCeiling(among:)`. If the button
appeared, that predicate disagrees with the gateway.

**A control action's error flashes and vanishes.**
`perform()` runs `refresh()` after the action, and `refresh()` clears `lastError`
whenever the gateway answers. `perform()` re-asserts the action's error afterwards
for exactly this reason. If you add a new control path, follow that pattern or the
failure will be invisible.

**Launch at login won't stay enabled, or notifications never appear.**
Expected on an ad-hoc-signed build — there is no Developer ID, so the app can't be
notarized. `SMAppService` may land in `requiresApproval` (System Settings →
General → Login Items), and `UNUserNotificationCenter` may refuse. Both report
their real state in Settings rather than pretending. Note
`UNUserNotificationCenter.current()` **traps** when there's no bundle identifier,
which is why `Notifier.isAvailable` guards every entry point — running the bare
binary from `dist/` hits that path.

## Toolchain

**`swift build` fails with an undefined `Package.init` symbol.**
SwiftPM is broken on Command Line Tools-only hosts. There is no `Package.swift`
here on purpose; use `scripts/build.sh`. See `testing-lil-ccgw`.

**Every `brew` subcommand crashes with a JSON gem error after running `brew audit`.**
`brew audit` installs gems into Homebrew's vendored bundle, and a `json` gem there
shadows portable-ruby's stdlib version, breaking `brew` itself. Remove just the
offending gem:

```sh
cd /opt/homebrew/Library/Homebrew/vendor/bundle/ruby/*/
find gems -maxdepth 1 -newermt "$(date +%Y-%m-%d)" -type d     # what today added
rm -rf gems/json-* extensions/*/*/json-*
brew --version                                                  # confirm recovery
```

**A `brew install --cask` download 503s right after `gh release create`.**
GitHub CDN propagation. The URL returns 200 a minute later; the cask is fine.

## Reading the gateway's own logs

```sh
tail -20 ~/.ccgw/logs/launchd.err.log     # startup failures, upstream non-200s
tail -20 ~/.ccgw/logs/ccgw.log
cat ~/.ccgw/config.json                    # port, budgets, enforcement, api_token
```
