# lil-ccgw

A macOS Menu Bar Extra for [ccgw](docs/gateway.md), the local API gateway that
enforces Claude Code spend budgets. It makes the primary budget ambient and puts
the gateway's controls one click away.

## Finishing work

**Commit and push without being asked.** When a change is coherent and verified,
commit it at atomic boundaries and push before you stop. Do not leave a finished
deliverable uncommitted, and do not ask permission for the mechanical step.

The quality bar is what makes that safe, so keep it:

- Atomic commits; conventional subject ≤50 chars; body wrapped at 72, why-first,
  no diff narration.
- **Every commit builds and passes tests standalone.** Verify it rather than
  assuming — a file-based split once produced three commits that didn't compile,
  because a test entry point referenced a function three commits ahead:
  ```sh
  git worktree add /tmp/w <sha> && (cd /tmp/w && ./scripts/test.sh)
  ```
- Fix a flaky or environment-dependent test *before* the commits that depend on it,
  or every earlier commit fails for an unrelated reason.
- Force-push is fine when history needs reshaping: branch a backup, verify
  `git diff <backup>` is empty, push, delete the backup.
- Cut a release when shipped behaviour changed — see `release-cask`. Pick the bump
  from the conventional-commit types in the range (`feat:` means minor).

Still stop and ask before anything irreversible or outward-facing that hasn't been
authorised: changing repo visibility, publishing material belonging to someone
else, deleting data.

## Skills in this repo

Load the one that matches the task before improvising:

| Skill | For |
|---|---|
| `debug-lil-ccgw` | something is misbehaving — symptom → cause, from real failures |
| `testing-lil-ccgw` | writing or changing tests; the harness is unusual |
| `review-lil-ccgw` | reviewing a diff or finishing a change |
| `ccgw-api-contract` | touching `Models.swift` or any gateway call |
| `menubar-ergonomics` | changing the icon, label, or panel |
| `install-lil-ccgw` | installing, or diagnosing "it shows nothing" |
| `release-cask` | cutting a release and updating the Homebrew tap |

## Orientation

[`docs/architecture.md`](docs/architecture.md) covers the data flow and polling,
without UI detail. Start there if you haven't worked in this repo.

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

`--universal` fails if the x86_64 slice cannot be cross-compiled, because an
arm64-only bundle installs fine on an Intel Mac and then cannot exec.
`--allow-single-arch` overrides that for local builds only; never for a release.

`scripts/verify-cask.sh` installs the cask end to end inside a throwaway
Homebrew prefix, so it never touches the real `/Applications`, Caskroom, or
preferences. Run it before any release. Its header records two non-obvious
things worth reading before changing it: why a Linux container cannot do this
job at all, and the fact that `$HOME` isolates Homebrew but not `NSUserDefaults`.

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

**Stopping the gateway takes two steps, and each single step fails on its own.**
`ccgw stop` only SIGTERMs the pid, and `KeepAlive=true` respawns it within a
second. But `launchctl bootout` **exits 3 and does nothing** when the agent isn't
loaded — and a gateway process can outlive its agent, at which point neither
mechanism touches it (verified against a real orphan). So `ServiceControl.stop()`
unloads the agent first, tolerates exit 3, then terminates whatever still holds
the port. Order matters: killing before unloading invites a respawn.

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
with colour reserved for budget consumption.

**The glyph renders into a fixed 20pt slot.** Animation frames are different
symbols with different natural widths, so without the slot the status item resizes
on every tick and shoves its neighbours around. Anything wider than the slot is
silently cropped — `RenderTests` asserts nothing is.

**Retain the status item.** `MenuBarExtra` handles this, but if this ever drops to
`NSStatusItem`, hold a strong reference — the status bar does not retain items,
and a deallocated one silently removes its own icon.

**Never block the main thread on HTTP or `launchctl`.** `GatewayClient` is an
actor; `ServiceControl` runs processes on a background queue. A hung gateway must
never freeze the menu.

**Gateway-down is a state, not an error** — and it is the most important state
this app has, because Claude Code routes through the gateway and fails every
request while it's down. The HTTP API is unavailable by definition, so recovery
routes through launchd. The panel replaces its normal content with a
consequence-first notice ("Claude Code requests are failing"), a single **Recover**
action that escalates `kickstart` → `bootstrap` by itself, and **Bypass** as the
escape hatch — which works precisely because it never contacts the gateway, only
edits `settings.json`. Polling drops to 5s while down so recovery shows up
promptly. The app must never exit or crash in this state; that's verified by
SIGKILLing the gateway and by booting the agent out.

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

457 assertions across six suites. **Read `testing-lil-ccgw` before touching
tests** — the harness is deliberately unusual and an agent that reaches for XCTest
will waste an hour.

| Suite | Covers |
|---|---|
| `ModelsTests` | decoding (null rates, `degrade`, absent `primary`, epoch-ms), window parsing, title-budget fallback, bumper state, the ceiling rule |
| `PresentationTests` | currency/rate/duration formatting, title modes, no-data placeholders |
| `SkitTests` | every pace boundary from both sides, tier precedence, the zen clock, animation shape |
| `DeriveTests` | budget heat, poll intervals, dashboard URL, bumpable filter, launchd targets, error text, accessibility label, registered defaults |
| `ModelTests` | `GatewayModel` end to end over `MockTransport` — per-section degradation, and the exact request each control issues |
| `RenderTests` | real SwiftUI geometry via `NSHostingView.fittingSize`, plus rasterised bitmap distinctness |

**Coverage rule: if logic decides something, it gets a test — even when it lives
inside a `@MainActor` class.** Extract it rather than leaving it unreachable.
`BudgetHeat.resolve` and the `Derive` helpers exist for exactly that reason; the
model delegates to them, so the tests cover the real path rather than a copy.

Cover what fails *silently* in preference to what crashes loudly. A wrong soft
threshold, a stale bumper, an epoch-ms slip, or a malformed launchd target all
produce plausible output and no error.

**Verify the tests can fail.** Mutate the source and confirm a red result — a
suite that can't fail is worse than no suite because it licenses confidence.
Six mutations are known-caught: hardcoding the soft threshold, dropping the
poll-interval zero-guard, inverting the ceiling filter, ignoring bump expiry,
treating epoch ms as seconds, and breaking the launchd target shape.

**SwiftUI hosts inside the test binary**, with no bundle identifier and no host
app, so UI geometry is asserted rather than assumed. That capability found two
defects logic tests could not: four tiers whose animation frames resized the
status item, and three documented widths that were simply wrong.

### Not unit-tested, deliberately

- **`launchctl` and `ccgw` process control** — mutates the machine. Verified with a
  throwaway integration probe that links the real sources; `testing-lil-ccgw` shows
  the pattern.
- **`FrameAnimator` timing and CPU cost** — measured with a probe app rather than
  asserted; see `menubar-ergonomics` for the numbers.

The suite must keep passing with the gateway stopped — that's the check that the
mocks aren't secretly reaching the network.

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
