# lil-ccgw

A macOS Menu Bar Extra for [ccgw](docs/gateway.md), the local API gateway that
enforces Claude Code spend budgets. It makes the primary budget ambient and puts
the gateway's controls one click away.

## The gateway is a hard prerequisite

This app is a display and control surface. It owns no data, no budgets, no proxy.
**Nothing here works unless the cc-gateway plugin is installed and the gateway is
answering on `127.0.0.1:8484`** — without it the app launches happily and shows
dashes, which reads as a broken app rather than a missing dependency.

Before installing, debugging "it shows nothing", or trusting any manual test, run
the four-point preflight in `.claude/skills/install-lil-ccgw/SKILL.md`. It checks
the marketplace registration, the plugin install record, the `~/.ccgw/bin/ccgw`
binary, and a live `/api/health`, with remediation for each. Treat a failed check
as a blocker.

## Build

**Use `scripts/build.sh`. There is no `Package.swift`, on purpose.**

SwiftPM is unusable on hosts with only the Command Line Tools installed: its
`libPackageDescription.dylib` can ship older than the bundled
`PackageDescription.swiftmodule`, and then *every* manifest — including an empty
one — fails to link with an undefined `Package.init` symbol. `swiftc` has no such
dependency, and the `.app` bundle is assembled by hand regardless, so SwiftPM was
buying nothing. If you add a manifest back, verify it builds on a CLT-only host
first.

```sh
scripts/build.sh              # native arch
scripts/build.sh --release    # optimised
scripts/build.sh --universal  # arm64 + x86_64, for release
open dist/lil-ccgw.app
```

A file named `main.swift` would be treated as top-level code and collide with
`@main`; the entry point lives in `LilCcgwApp.swift` and the build passes
`-parse-as-library`.

## Rules that are not obvious from the code

**The gateway's API is an external contract.** ccgw lives in a *different repo on
a moving branch*, served from an organisation-internal plugin marketplace (see
`docs/gateway.md`). A renamed field in `/api/status` breaks this app silently,
with no compile error. Before touching `Models.swift`, read
`.claude/skills/ccgw-api-contract/SKILL.md`, which pins every field this app
depends on.

**Address the gateway as `127.0.0.1`, never `localhost`.** It validates the Host
header against loopback names to defeat DNS rebinding, and a `localhost`
resolution can arrive as an IPv6 literal it rejects.

**`ccgw stop` does not stop the gateway.** It sends SIGTERM to the pid, and the
LaunchAgent sets `KeepAlive=true`, so launchd respawns it within about a second.
A real stop must `launchctl bootout` the agent. This is why `ServiceControl.stop()`
uses launchctl and why the UI confirms first — booting out also disables
autostart until `start()` bootstraps it again.

**`~/.ccgw/bin/ccgw` is not on `PATH`.** Always invoke it by absolute path.

**Send `X-CCGW-Token` whenever `~/.ccgw/token` exists**, even though `api_token`
currently defaults to `false`. Mutations are open on loopback today; sending the
token unconditionally means flipping that config flag later doesn't silently
break every button.

**`/api/events` is not SSE**, despite the name. It returns a JSON array of rows
since a timestamp. Live updates are a poll loop, not a stream.

## Design invariants

**`MenuBarLabel` renders both the live status item and the Settings preview.**
That sharing *is* the WYSIWYG guarantee — there is no second code path that could
drift from what the menu bar shows. Never fork it for the preview.

**Menu bar glyphs must be shape-distinct, not just colour-distinct.** SwiftUI
renders `MenuBarExtra` labels as template images in most configurations, which
flattens colour. Each state gets its own SF Symbol so it reads in monochrome,
with colour as reinforcement.

**Retain the status item.** `MenuBarExtra` handles this, but if this ever drops to
`NSStatusItem`, hold a strong reference — the status bar does not retain items,
and a deallocated one silently removes its own icon.

**Never block the main thread on HTTP or `launchctl`.** `GatewayClient` is an
actor; `ServiceControl` runs processes on a background queue. A hung gateway must
never freeze the menu.

**Gateway-down is a state, not an error.** When the gateway is unreachable the
HTTP API is unavailable by definition, so recovery routes through launchd. The
panel swaps Restart for Start rather than showing a failed request.

## Constraints inherited from the signing situation

There is no Developer ID on this machine (`security find-identity -p codesigning`
reports zero valid identities), so the app is **ad-hoc signed and cannot be
notarized**. Two features degrade as a result, and both must say so in the UI
rather than appearing to work:

- **Launch at login** (`SMAppService.mainApp`) needs a real bundle and is
  finickier when unsigned. `LoginItem` surfaces errors and the
  `requiresApproval` state.
- **Notifications** trap outright if the process has no bundle identifier, which
  is the case when running the bare binary from `dist/`. `Notifier.isAvailable`
  guards every entry point so `swiftc && ./lil-ccgw` stays a usable dev loop.

## Tests

```sh
scripts/test.sh     # compiles sources minus LilCcgwApp.swift + Tests/, runs them
```

Hand-rolled harness in `Tests/TestSupport.swift`, ~40 lines, because XCTest and
swift-testing both want SwiftPM or xcodebuild. It reports file and line and exits
non-zero on failure — verify that by breaking an assertion, not by trusting it.

Cover the things that fail *silently*: decoding (null rates, the `degrade`
action, `primary` absent, epoch-ms conversion), window parsing, title-budget
fallback, formatting, and glyph-per-state. Fixtures are captured verbatim from a
live gateway with numbers pinned.

Do not write tests that hit the network or `launchctl`. Those paths are verified
by hand against a live gateway, below.

## Testing against a live gateway

Run the preflight first. Then cross-check any number the panel shows against
`/api/status` and `/dash`.

**Expect drift, not disagreement.** At a ~$14/hr burn, spend moves ~$0.24 a
minute; `/dash` polls status every 4s while the closed-panel title polls every
30s. Opening the panel forces a fresh read, so compare with it open — a few cents
apart is timing, dollars apart is a bug.

One deliberate difference: the panel's model breakdown covers the **tracked
budget's window** (labelled `5h`, `30d`, …), while the dashboard's breakdown
defaults to 1 day with its own selector. Scoping the breakdown to the budget
above it is what keeps the panel internally consistent; it does mean the two
surfaces only match when the windows match.
