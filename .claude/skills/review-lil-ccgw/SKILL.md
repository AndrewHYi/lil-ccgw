---
name: review-lil-ccgw
description: Review checklist for changes to lil-ccgw — the invariants that produce silent, plausible-looking failures when broken, each paired with the bug it prevents. Use when reviewing a diff here, before opening a PR, or before declaring a change done.
---

# Reviewing lil-ccgw

Every item is an invariant that has already been violated at least once in this
repo, and each violation produced a *plausible-looking* result rather than a
crash. That's what makes them worth a checklist: none of them fail loudly.

Work top to bottom; the first section catches the most.

## Observation and rendering

- [ ] **`@Observable` state is read inside `body`, never in an initialiser.**
      Reading it in an init means SwiftUI never registers the dependency, so the
      view renders once and freezes while the data underneath keeps updating.
      `MenuBarTitle` exists solely to do this correctly. A diff that adds a
      `MenuBarLabel.init(model:)` convenience is reintroducing the original bug.
- [ ] **`MenuBarLabel` is not forked for the Settings preview.** One view renders
      both the live status item and the preview; that sharing *is* the WYSIWYG
      guarantee. A second "preview version" drifts the first time either changes,
      and the drift is invisible until a user notices.
- [ ] **The glyph keeps its fixed-width slot.** Removing
      `.frame(width: glyphSlotWidth)` restores the jitter where the status item
      resized on every animation tick.
- [ ] **New glyphs fit the slot.** Anything wider than 20pt is silently cropped.
      `RenderTests` asserts this; don't weaken the assertion to accommodate a
      symbol — raise the slot instead, and re-measure.
- [ ] **Every state is shape-distinct, not merely colour-distinct.**
      `MenuBarExtra` labels render as template images in most configurations,
      flattening colour. Two states sharing a silhouette are one state.
- [ ] **Colour still means budget consumption and the glyph still means burn
      rate.** Those are independent axes on purpose. Collapsing them loses the
      "calm pace but 85% spent" state.
- [ ] **New windows activate the app.** `LSUIElement` apps never come forward on
      their own; see `SettingsWindow.present`.

## The gateway contract

- [ ] **Field names match `ccgw-api-contract`.** The gateway is a different repo on
      a moving branch, and nothing here compiles against it — a renamed field is a
      dash in the menu, never a build error.
- [ ] **Nullable numerics stay optional.** A budget with no traffic reports `null`
      rates. Making them non-optional throws on decode and blanks the whole panel.
- [ ] **Timestamps are epoch *milliseconds*.** Dividing by 1000 is not optional;
      forgetting it puts the resume time in 1970 and the UI claims enforcement is
      already back.
- [ ] **`127.0.0.1`, never `localhost`.** The gateway validates the Host header
      against loopback names, and `localhost` can resolve to an IPv6 literal it
      rejects.
- [ ] **`X-CCGW-Token` is sent whenever `~/.ccgw/token` exists**, regardless of the
      `api_token` config flag. Otherwise every button breaks the day that flag
      flips.
- [ ] **`/api/events` is not SSE** despite the name. It returns rows since a
      timestamp. Anything `EventSource`-shaped is wrong.
- [ ] **`~/.ccgw/bin/ccgw` is invoked by absolute path.** It isn't on `PATH`.
- [ ] **The overall ceiling is never offered a bumper.** The widest-window `block`
      budget returns 400. `Budget.isCeiling(among:)` must agree with the gateway;
      only `block` budgets count when picking the widest.
- [ ] **Bumper liveness is decided by `bump_expires_at`, not `bump_usd`.** The
      amount outlives its expiry in config, so trusting it shows a stale bumper.

## Process control

- [ ] **Stop unloads the agent before killing anything.** `KeepAlive=true` respawns
      a bare SIGTERM within a second; killing first just invites that.
- [ ] **`bootout` exit code 3 is tolerated.** It means the agent wasn't loaded,
      which is a valid starting state, not a failure.
- [ ] **Stop verifies the port actually stopped answering.** A process can outlive
      its agent, and then neither `bootout` nor `ccgw stop` touches it.
- [ ] **Destructive actions confirm, and say what breaks.** Claude Code routes
      through this gateway, so stopping it fails every request. Bypass takes effect
      on the *next* Claude Code start, not immediately — the confirmation must say
      so.
- [ ] **Nothing blocks the main thread on HTTP or `launchctl`.** `GatewayClient` is
      an actor with a 3s timeout; `ServiceControl` runs processes off-actor. A hung
      gateway must never freeze the menu.

## Error handling and states

- [ ] **Control-action errors are re-asserted after `refresh()`.** `refresh()`
      clears `lastError` whenever the gateway answers, so an error set before it
      vanishes within milliseconds. This made a rejected bumper look like a button
      that did nothing.
- [ ] **Gateway-down is a state with its own UI, not an error toast.** And it leads
      with the consequence — Claude Code is failing — not the technical fact.
- [ ] **A recovery path exists that doesn't need the gateway.** Bypass is pure
      `settings.json` editing precisely so it works when everything else is broken.
- [ ] **Per-section degradation is preserved.** One failing endpoint hides its own
      section; it must not blank the panel.
- [ ] **Missing data renders a dash, never a zero or a stale value.**

## Tests

- [ ] **New logic has a test, even if it lives in a `@MainActor` class.** Extract it
      to `Derive` or a pure function rather than leaving it unreachable — that
      extraction is why `BudgetHeat.resolve` and `Derive` exist.
- [ ] **The new test was mutation-checked.** Break the source, confirm red. A test
      that cannot fail licenses false confidence.
- [ ] **Nothing reads the clock without an injectable `now`.** A fixture with a
      relative expiry otherwise passes in the morning and fails in the evening.
- [ ] **Boundary values are asserted from both sides.** The pace thresholds are
      copied constants from the dashboard; an off-by-epsilon shows a thriving plant
      during a runaway.
- [ ] **The suite still passes with the gateway stopped.** That's the check that the
      mocks aren't quietly reaching the network.

## Publishing

- [ ] **No internal identifiers.** This repo is public; the gateway's marketplace is
      organisation-internal. No repo name, branch name, internal URL, or configured
      budget figures. Grep for them.
- [ ] **Measured claims are actually measured.** Widths, CPU percentages, and
      thresholds in the docs were wrong by up to 20pt when they were estimates.
      If a number is in a doc, something should assert it.
- [ ] **Version numbers and assertion counts in docs match reality.**

## Commits

- [ ] Atomic, conventional subject ≤50 chars, body wrapped at 72, why-first.
- [ ] No fixup or "address review" commits left on the branch — squash them.
- [ ] Behaviour tests ship *inside* the commit that adds the behaviour, not after.
- [ ] Each commit builds and passes tests standalone. Verify with a worktree:
      `git worktree add /tmp/w <sha> && cd /tmp/w && ./scripts/test.sh`
