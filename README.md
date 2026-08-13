# lil-ccgw

Menu bar app for [ccgw](docs/gateway.md), the local gateway that enforces Claude
Code spend budgets. ccgw already reports spend through a statusline, an MCP
server, and a dashboard at <http://127.0.0.1:8484/dash>, but all three need you
to go look. This keeps the number in the menu bar.

```
$20.59/$75 5h
```

Click it:

```
◐  ccgw 0.1.52 · up 3h 16m
──────────────────────────────────────
session   5h   $20.59 / $75     27.5%  ▓░░░░░░░░
weekly    7d   $34.36 / $300    11.5%  ▓░░░░░░░░
monthly  30d   $34.36 / $1200    2.9%  ░░░░░░░░░
──────────────────────────────────────
burn  $14.32/hr  vs $15.00/hr sustainable
pace  0.95×      · 3.8h to limit
──────────────────────────────────────
top models                          5h
opus-5                          $19.13
sonnet-5                         $3.74
──────────────────────────────────────
enforcement  on
[Restart] [Pause 60m]
[Stop…] [Bypass…] [Re-wire]
──────────────────────────────────────
Dashboard  Settings…            Quit
```

[`docs/architecture.md`](docs/architecture.md) covers where the numbers come from
and how often they refresh.

## ccgw has to be running first

This app displays and controls ccgw. It holds no data of its own, so with no
gateway behind it every figure renders as a dash — which looks like a broken app
rather than a missing dependency. Check before installing:

```sh
curl -sf -m2 http://127.0.0.1:8484/api/health && echo " ← up"
```

If that fails, set the gateway up first ([docs/gateway.md](docs/gateway.md)). The
`install-lil-ccgw` skill runs a four-point preflight — marketplace, plugin
record, `~/.ccgw/bin/ccgw`, live health — with a remedy for each failure.

## Install

macOS 14 or later.

```sh
brew install --cask AndrewHYi/tap/lil-ccgw
```

Upgrade with `brew upgrade --cask AndrewHYi/tap/lil-ccgw`.

### From source

Needs the Swift toolchain from Command Line Tools; Xcode is not required.

```sh
git clone git@github.com:AndrewHYi/lil-ccgw.git
cd lil-ccgw
scripts/test.sh
scripts/build.sh --release
cp -r dist/lil-ccgw.app /Applications/
open /Applications/lil-ccgw.app
```

There's no `Package.swift` on purpose — SwiftPM can't run on a CLT-only host, and
[CLAUDE.md](CLAUDE.md) explains why.

## Settings

There's no Dock icon, so Settings lives in the panel: click the menu bar item,
then **Settings…** at the bottom (⌘, works while the panel is open). Three panes:

- **General** — launch at login, gateway host and port, refresh intervals,
  default pause duration.
- **Display** — what the menu bar shows, and which budget drives it.
- **Alerts** — threshold and gateway-down notifications, plus which panel
  sections are visible.

Display has a live preview strip that renders the real menu bar label with your
current numbers, so you can see each option before committing menu bar width to
it. It falls back to sample data when the gateway is unreachable and says so.

Five formats:

| Mode | Renders | Width |
|---|---|---|
| Spend / limit + window *(default)* | `$20.59/$75 5h` | 108pt |
| Spend only | `$20.59` | 61pt |
| Icon only | icon alone | 20pt |
| Pace | `0.91×` | 61pt |
| Statusline | `$20.59/$75 5h │ $34/$1200 30d` | 215pt |

Widths are measured, not estimated, and asserted in the test suite — statusline
costs over twice the default, which is why it isn't one.

The tracked budget defaults to whichever one the gateway nominates as primary —
the 5-hour window, unless you pick another in Display.

## The icon

Two independent signals. The **glyph** and its animation speed report **pace** —
burn rate ÷ sustainable rate — ported from the dashboard's `#skit` escalation with
the same thresholds:

| Pace | Icon | Caption |
|---|---|---|
| idle or ≤ 0.85× | leaf | sustainable pace |
| ≤ 1.2× | thermometer | running warm |
| ≤ 1.6× | flame | over sustainable |
| ≤ 2.0× | flame / alarm | burning down the window |
| > 2.0× | running figure | runaway |
| 10 min of runaway | meditation | past caring |
| budget exhausted | rain | `<budget>` is spent |
| 1st of the month | confetti | budgets reset |

**Colour** reports something different: how much of the budget is *spent*. Normal,
amber at the gateway's soft threshold, red when exhausted. So a calm leaf in amber
is a real state — sustainable burn, but most of the window already gone.

One caveat if you compare scenes with `/dash`: the thresholds match, but the input
windows don't. This app reads the gateway's `pace`, computed over the last 60
minutes; the dashboard recomputes its own over 20 minutes, so it escalates roughly
three times faster during a burst. Deliberate — an ambient icon that re-tiers every
twenty seconds is noise — but it means the two can legitimately show different
stages at the same moment.

The panel header carries the caption and a rotating aside, re-rolled each time you
open it. Settings → Display has an animate toggle and a "Force scene" picker for
walking all eight without waiting for a runaway.

**Animation costs CPU.** Roughly 5% of a core at `warm`, 10% at `melt`, and
**zero** when static or below 0.85× pace. That's the cost of invalidating a hosted
menu bar view on every frame; it isn't optimisable, so the toggle is there for
when you'd rather have the ladder without the flicker. The glyph still escalates
through all eight stages either way.

## Controls

| | |
|---|---|
| **Restart** | `POST /api/restart` — drains in-flight requests, then launchd respawns it |
| **Pause** | Pauses budget enforcement for N minutes; the gateway auto-resumes |
| **Stop** | `launchctl bootout`, then terminates any surviving listener — confirms first |
| **Bypass** | Unwires `ANTHROPIC_BASE_URL` so Claude Code goes direct |
| **+ bumper** | Adds a temporary allowance to one budget, per row |

Each budget row carries its own bumper: **+ bumper** opens an inline amount and
duration form, an active one shows as `+$50.00 until 7:41 PM` with the base limit
beside it, and **+ more** stacks on top (the later expiry wins). Duration defaults
to the budget's own window.

The overall ceiling — the widest-window `block` budget — has no bumper button,
because the gateway refuses to raise it. That's the design: a bump reshapes when
you can spend, not how much, so it comes out of remaining headroom and the
sustainable pace for the rest of the window drops to match.

Stop uses `bootout` rather than `ccgw stop` because the LaunchAgent sets
`KeepAlive=true` — a plain SIGTERM gets respawned within the second, so the
button would look broken. Booting out also unloads the agent, which means the
gateway won't return at login until you recover it.

`bootout` alone isn't sufficient either: it exits 3 and does nothing when the
agent isn't loaded, and a gateway process can outlive its agent. So Stop unloads
first, then terminates whatever is still listening on the port — verified against
a real orphaned process that neither `bootout` nor `ccgw stop` could kill.

Stop and Bypass both confirm first, and the confirmation says what breaks:
Claude Code points at this gateway, so a stopped gateway means every request
fails with connection refused. Bypass takes effect on the **next** Claude Code
start, not immediately.

## When the gateway dies

Claude Code sends every request through the gateway, so a dead gateway means
every request fails with connection refused. This app is the thing that tells you
why, and it's built not to become another casualty.

- **It never exits.** Verified by SIGKILLing the gateway and by booting the agent
  out: the app keeps the same PID, logs no crash report, and keeps polling.
- **The icon switches to a warning triangle** and the panel leads with *"Claude
  Code requests are failing"* — the consequence, not the technical state — then
  names the address it tried, so a wrong port is diagnosable at a glance.
- **It retries every 5 seconds while down** instead of the usual 30, so recovery
  shows up almost immediately. A refused connection costs microseconds.
- **A notification fires once** when the gateway drops, if you've enabled it.

Two ways out, both in the panel:

| | |
|---|---|
| **Recover gateway** | Escalates by itself: `launchctl kickstart` if the agent is loaded, `bootstrap` if it isn't, and reports what it tried plus the log path if both fail. You don't need to know which case you're in. |
| **Bypass** | Unwires `ANTHROPIC_BASE_URL` so Claude Code talks to the API directly. **This works while the gateway is down** — it's pure `settings.json` editing and never contacts the gateway. Budgets stop being enforced and it takes effect on the next Claude Code start. |

A plain crash usually self-heals: the LaunchAgent sets `KeepAlive=true`, so the
gateway is back within a couple of seconds and the icon follows. Recovery is for
the cases that don't — a wedged process, or an agent that was booted out.

## Tests

```sh
scripts/test.sh
```

457 assertions over the parts that fail *quietly* — where being wrong produces
plausible output rather than an error: decoding the gateway's payloads (null
rates, the `degrade` action, a missing `primary`, epoch-ms timestamps), every
pace boundary from both sides, the bumper's ceiling rule, budget-window parsing,
soft-threshold colour, launchd target strings, formatting, and the glyph each
state maps to.

The suite is mutation-checked: breaking the source has to turn it red. Six known
mutations are caught, including hardcoding the soft threshold, ignoring bump
expiry, and treating epoch milliseconds as seconds.

Rendering is tested too. SwiftUI hosts inside the plain test binary, so
`NSHostingView.fittingSize` and `ImageRenderer` give real geometry: the suite
pins each title mode's width, requires every tier's animation frames to measure
identically, checks no glyph outgrows its slot, and hashes the rendered bitmaps
so eight tiers must actually look different rather than merely be named
differently.

The gateway itself is mocked at the transport boundary, which lets the suite
assert **what the app sends** — the method, path, and JSON body of every control
action, and that the spend breakdown is requested over the tracked budget's
window. Wrong-request bugs are invisible if you only check responses.

`launchctl` calls remain hand-verified against a live agent; the rest of the
suite runs with the gateway stopped and produces identical results.

## Comparing against Anthropic's usage page

The menu bar tracks a **5-hour rolling window** by default, so it will not match
the month-to-date figure on Anthropic's usage page. Those are different
questions, and the answers are meant to differ:

```
menu bar   $41.62/$75 5h      last 5 hours
Anthropic  $57.74 of $1,200   month to date, resets Aug 31
```

Compare the **monthly 30d** row in the panel instead. Two reasons it still won't
match exactly, both expected:

- **Spend from before the proxy existed is invisible to ccgw.** It only sees what
  it proxied. Requests you sent before wiring `ANTHROPIC_BASE_URL` went straight
  to the API and are absent from the ledger. Find when capture began with
  `sqlite3 -readonly ~/.ccgw/ledger.db "SELECT datetime(MIN(ts)/1000,'unixepoch') FROM requests;"`.
  The distortion ages out of the 5h window within hours and out of 30d within a
  month.
- **ccgw prices at published API list rates**, which its README documents
  deliberately. If your plan bills at negotiated rates, ccgw runs a few percent
  high on the traffic it did capture.

Those two pull in opposite directions and largely cancel. On this machine a
$6-ish missing window against a ~7% overcount left the monthly figures about 4%
apart. Treat a few percent as the measurement model, and a large or growing gap
as worth investigating.

If you want the bar comparable to the usage page, set Track budget to
`monthly · 30d` in Settings → Display, or pick Statusline to see both. The 5h
window is the default because it's what catches a runaway early — a monthly
number at 5% used hides a burn rate of 1.5× sustainable.

## Comparing against the dashboard

Budgets come from the same `/api/status` the dashboard reads, so they agree by
construction. Two things to know before treating a difference as a bug:

- **Timing.** At $14/hr, spend moves about $0.24 a minute. `/dash` polls every
  4s; the closed panel polls every 30s. Opening the panel forces a fresh read,
  so compare with it open. Cents apart is timing. Dollars apart is a bug.
- **Breakdown window.** The panel's model breakdown covers the tracked budget's
  window and labels it, so the total matches the budget above it. The
  dashboard's breakdown defaults to 1 day with its own selector, so the two only
  line up when the windows do.

## Signing

Ad-hoc signed, not notarized — there's no Developer ID on the build machine,
same position [AeroSpace](https://github.com/nikitabobko/AeroSpace) takes. The
cask strips `com.apple.quarantine` so Gatekeeper doesn't block it. Two things
degrade as a result and say so in the UI instead of pretending to work: launch
at login may need approval in System Settings → General → Login Items, and
notifications may be refused.

It only talks to `127.0.0.1`. Port comes from `~/.ccgw/config.json`, and it sends
`~/.ccgw/token` when that file exists.

## License

MIT
