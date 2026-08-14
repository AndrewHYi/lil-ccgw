---
name: testing-lil-ccgw
description: How the lil-ccgw test suite works and how to add to it — the hand-rolled harness, why there is no XCTest or SwiftPM, mock transport for gateway behaviour, render tests that measure real SwiftUI geometry, the mutation-check requirement, and the async patterns that do and do not work. Use before writing or changing any test here.
---

# Testing lil-ccgw

```sh
scripts/test.sh          # everything; exits non-zero on any failed assertion
```

**Do not reach for XCTest or swift-testing.** Both want SwiftPM or `xcodebuild`,
and neither works on a Command Line Tools-only host — SwiftPM's
`libPackageDescription.dylib` can ship older than its own `.swiftmodule`, at which
point *every* manifest fails to link, including an empty one. That is why there is
no `Package.swift`. An agent that "fixes" the missing test framework by adding one
will spend an hour and end up back here.

## How the harness works

`scripts/test.sh` compiles the app sources **minus `LilCcgwApp.swift`** (its
`@main` would collide with the top-level code in `Tests/main.swift`) together with
everything in `Tests/`, then runs the binary.

`Tests/TestSupport.swift` holds ~40 lines of assertions:

| Call | Use |
|---|---|
| `T.suite("name") { }` | groups assertions; a throw inside is reported, not fatal |
| `T.expect(cond, "msg")` | boolean |
| `T.equal(actual, expected, "msg")` | any `Equatable`, prints both values |
| `T.close(a, b, "msg", tolerance:)` | doubles |
| `T.currentSuite = "name"` | for `do { }` blocks in async suites, which can't use `T.suite` |

Failures print `file:line`. `T.report()` returns the exit code.

## The suites

| File | Covers |
|---|---|
| `ModelsTests` | decoding, window parsing, bumper state, the ceiling rule |
| `PresentationTests` | formatting, title modes, placeholders |
| `SkitTests` | pace boundaries both sides, tier precedence, the zen clock |
| `DeriveTests` | budget heat, poll cadence, URLs, launchd targets, defaults |
| `ModelTests` | `GatewayModel` end to end over `MockTransport` |
| `RenderTests` | real SwiftUI geometry and rasterised output |
| `ViewTests` | panel, settings panes and help rendered in every reachable state |
| `PanelDeriveTests` | the panel's colour and breakdown decisions |
| `ServiceControlTests` | launchd and CLI control over a fake process environment |
| `RecoveryTests` | `recover()`'s escalation, stop's note ordering |
| `NotifierRuleTests` | the fire-once-and-re-arm rule |
| `TransportTests` | request building, response mapping, notifier explanations |
| `WindowTests` | the two window helpers call their injected open action |
| `GapTests` | odds and ends coverage showed nothing had ever executed |

Add a suite by writing a global `func runFooTests()` in `Tests/FooTests.swift` and
calling it from `Tests/main.swift` before `exit(T.report())`. `test.sh` globs the
file automatically, but nothing discovers the function — an uncalled suite
compiles, runs nothing, and reports success.

## Measure coverage rather than counting assertions

```sh
scripts/test.sh --coverage         # per-file line coverage
scripts/test.sh --gate             # fail on a per-file regression
scripts/test.sh --coverage --update-floors
```

`swiftc` accepts the same `-profile-generate -profile-coverage-mapping` flags
SwiftPM would pass, and `llvm-profdata`/`llvm-cov` ship with the Command Line
Tools — so the no-manifest constraint never precluded this. Nobody had tried.

The floors in `scripts/coverage-floors.txt` are a ratchet, not a target. A hard
100% gate would be permanently red and therefore ignored; a floor fails only on a
drop. **Never lower one to make a run green.** That file also records, per file,
why it does not read 100 and what covering the rest would cost.

Trust the measured number over the assertion count. Two files totalling 789 lines
sat entirely untested while the count read a healthy 457.

## Four seams exist for tests; use them rather than adding a fifth

| Seam | Reaches |
|---|---|
| `GatewayClient(transport:)` | every request the app issues, and what it sends |
| `GatewayClient(token:)` | the `X-CCGW-Token` rule, without depending on `~/.ccgw/token` existing |
| `GatewayModel(settle:)` | lifecycle actions without their real multi-second waits |
| `ServiceControl.environment` | `launchctl`, `lsof`, `/bin/kill` and the ccgw CLI, without spawning any |

Always restore `ServiceControl.environment` in a `defer`. A leaked fake makes
later suites spawn nothing; worse, a leaked *real* one makes them spawn
`launchctl` against the machine running the tests.

## Fixtures are captured from a live gateway

`Tests/TestSupport.swift` holds `statusFixture`, `healthFixture`, `spendFixture`
and variants, captured verbatim from `curl 127.0.0.1:8484/api/...` with the
numbers pinned. They deliberately retain the parts that break naive decoders:
`null` rates on an untrafficked budget, the `degrade` action, an absent `primary`,
and objects the app doesn't model at all.

When the gateway version changes, re-capture rather than hand-editing, and check
the field names against `ccgw-api-contract`.

## Testing gateway behaviour: MockTransport

`GatewayClient` funnels every request through one private `send`, and that is the
seam. `Transport` is the protocol; `URLSessionTransport` is production;
`MockTransport` (test-only) is canned responses **plus a recording of every
request**.

```swift
let t = MockTransport.healthy()          // all read endpoints stubbed
    .fail("/api/spend")                  // make one endpoint fail
let m = GatewayModel(client: GatewayClient(transport: t))
await m.refresh()

t.request(to: "/api/budgets")?.jsonBody  // assert what was SENT
t.url(for: "/api/spend")                 // including query parameters
t.callCount("/api/status")
```

**Assert what the app sends, not only what it does with the reply.** Two real bugs
here were wrong-request bugs: a breakdown fetched over 30 days while the budget
above it covered 5 hours, and a bumper aimed at the one budget the gateway
refuses. Both return valid JSON. Only the outgoing request reveals them.

## Testing the UI: real geometry, no host app

SwiftUI **does** host inside this binary despite there being no bundle
identifier. `NSHostingView(rootView:).fittingSize` returns real layout geometry
and `ImageRenderer` rasterises. So assert measurements rather than estimates:

```swift
let host = NSHostingView(rootView: someView)
host.layout()
host.fittingSize          // e.g. 108.0 x 16.0
```

What `RenderTests` uses this for, and why each one exists:

- **Per-mode widths** — the docs previously carried estimates wrong by up to 20pt.
- **Frame pairs must measure equal** — four tiers used to resize the status item on
  every animation tick. This assertion is the regression test; it failed before
  the fixed-width glyph slot and passes after.
- **No glyph outgrows `MenuBarLabel.glyphSlotWidth`** — anything wider is silently
  cropped.
- **Bitmap hashes differ per tier** — a symbol-name test would pass even if two
  names rendered identical art.
- **Nothing renders empty** — a mistyped SF Symbol name ships an invisible icon.

Render tests need the main actor: `await MainActor.run { runRenderTests() }`.

## Async: the pattern that works, and the one that deadlocks

Top-level `await` in `Tests/main.swift` works, because the file runs as an async
context:

```swift
await runModelTests()
```

**Never** block the main thread waiting on a `@MainActor` task:

```swift
let sem = DispatchSemaphore(value: 0)          // DEADLOCKS
Task { @MainActor in ...; sem.signal() }
sem.wait()
```

The blocked main thread starves the actor the task needs. This hangs until killed.

## Keep tests deterministic

Anything reading the clock must accept an injected `now`. `Budget.baseLimitUsd`
originally called `Date()` internally, which made a fixture with a
`now + 1h` expiry pass in the morning and fail in the evening. It takes
`now:` for that reason.

## Mutation-check anything you add

A suite that cannot fail is worse than no suite, because it licenses confidence.
After adding a test, break the source and confirm red:

```sh
T=$(mktemp -d); cp -R Sources Tests "$T/"
sed -i '' 's/OLD/BROKEN/' "$T/Sources/LilCcgw/File.swift"
# compile + run out of $T, expect failures naming your assertion
```

Known-caught mutations, worth re-verifying after a refactor: hardcoding the soft
threshold the gateway owns; dropping the poll-interval zero-guard; inverting the
bumpable-budget filter; ignoring bump expiry; treating epoch ms as seconds;
breaking the launchd target string; changing the glyph slot width.

## Deliberately not unit-tested

`launchctl` and `ccgw` process control. Those mutate the machine, so they are
verified with a throwaway integration probe that links the real sources:

```sh
# builds the app sources plus a main.swift that calls ServiceControl directly
swiftc -o /tmp/probe $(find Sources/LilCcgw -name '*.swift' ! -name 'LilCcgwApp.swift') probe.swift
```

That is how `stop()` and `recover()` were confirmed against a real agent. Don't
add those to the suite — it must stay runnable with the gateway stopped, which is
also the check that the mocks aren't secretly reaching the network.
