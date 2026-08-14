---
name: ccgw-api-contract
description: The exact ccgw HTTP endpoints and JSON field names lil-ccgw depends on, plus the token, Host-header, and polling rules. Use before editing Models.swift or GatewayClient.swift, when the panel starts showing dashes, or after the gateway version changes.
---

# ccgw API contract

The gateway lives in **another repo on a moving branch**, served from an
organisation-internal plugin marketplace (see `docs/gateway.md`). Nothing in this
repo compiles against it, so a renamed field produces **no compile error** — just
`nil` where a number should be, and dashes in the menu. This file is the tripwire.

Verified against gateway **v0.1.52**. Re-verify after a gateway update.

## Rules before endpoints

1. **`127.0.0.1`, never `localhost`.** The gateway validates the Host header
   against loopback names to defeat DNS rebinding; `localhost` may resolve to an
   IPv6 literal it rejects.
2. **Send `X-CCGW-Token` whenever `~/.ccgw/token` exists**, even though
   `api_token` defaults to `false` and mutations are currently open on loopback.
   Read the file per request — it can be rotated at runtime. Not doing this means
   every button breaks the day that flag flips.
3. **`/api/events` is NOT SSE.** Despite the name it returns
   `{"rows": [...]}` — events since a `from` timestamp. Live updates are a poll
   loop. Do not write an `EventSource`-shaped client.
4. **Port comes from `~/.ccgw/config.json`** (`port`, default 8484). Don't
   hardcode.

## GET /api/status — the primary read

One request covers almost the whole UI. Fields consumed:

```
enforcement            "on" | "off"
enforcement_resume_at  epoch ms, or null   → when a pause auto-reverts
degraded               bool
soft_threshold_pct     number (80)         → the amber threshold; the gateway
                                             owns this, do not hardcode 80
primary                object, or null     → which budget the app should track
  .id .window
  .pace                burn ÷ sustainable, or null
  .burn_rate_hr        $/hr over last hour, or null
  .sustainable_hr      limit ÷ window, or null
  .eta_hours           hours to limit, or null
  .fits_window         bool
budgets[]
  .id .scope .window
  .effective_limit_usd limit + any active bump
  .spent_usd .remaining_usd
  .pct                 0–100, CAN EXCEED 100
  .action              "block" | "warn" | "degrade"
  .exhausted .soft     bool
  .burn_rate_hr .sustainable_hr .pace   (nullable)
  .bump_usd .bump_expires_at            (nullable)
```

**`primary` is the gateway's own nomination** of which budget matters most
(currently `session` / 5h). The app follows it unless the user overrides in
Settings → Display. Never hardcode "5h".

**Nullability is real.** A budget with no traffic has no pace, burn, or ETA.
Every rate field is optional in `Models.swift` for this reason — don't
"simplify" them to non-optional.

## GET /api/health

```
ok bool · version string · uptime_s number · upstream string
ledger_rows int · sessions_tracked int · telemetry_degraded bool
```

`version` and `uptime_s` are how a successful restart is detected: poll until one
of them changes.

## GET /api/spend?group_by=model&from=<epoch_ms>

```
group_by string · rows[]{ key, requests, input_tokens, output_tokens,
                          cache_read_tokens, cache_write_tokens, cost_usd }
```

`key` is a raw model id (`claude-haiku-4-5-20251001`). `SpendRow.shortName`
trims the `claude-` prefix and a trailing 8-digit date stamp.

## POST /api/restart — graceful restart

Mutating. Drains in-flight requests, then exits. The gateway detects supervision
itself (`XPC_SERVICE_NAME` / `INVOCATION_ID`) and lets launchd respawn rather
than self-spawning, so **this is the correct restart path on a managed install**.

Returns `{restarting, mode, in_flight, note}`. Confirm by polling `/api/health`
until `version`/`uptime_s` changes.

Unreachable gateway ⇒ this cannot work. Fall back to
`launchctl kickstart -k gui/$UID/io.ccgw.gateway`.

## PUT /api/budgets — enforcement pause

Mutating. Pause:

```json
{"enforcement": "off", "pause_minutes": 60}
```

`pause_minutes` clamps server-side to 1…1440 (default 60). Spend keeps
recording; the gateway auto-resumes at `enforcement_resume_at`, so a pause
cannot be forgotten. Resume early:

```json
{"enforcement": "on"}
```

## PUT /api/budgets — bumper

Mutating. A temporary extra allowance on one budget:

```json
{"bump": {"budget_id": "session", "amount_usd": 25, "minutes": 60}}
{"bump": {"budget_id": "session", "clear": true}}
```

- `amount_usd` must be > 0 and ≤ 10000; the stacked total is also capped at 10000.
- `minutes` clamps to 5…10080. **Omit it** to get the budget's own window length.
- **Bumps stack.** Re-bumping an active bumper *adds* to it and keeps the later
  expiry, so topping up never needs a clear first. Verified live: $50 + $10 → $60
  with the original expiry intact.
- **There is no set verb, and that makes lowering a bumper dangerous.** Since a
  bump only ever adds, the only way *down* is `clear` then a fresh `amount_usd`.
  In the gap between those two calls the budget sits at its bare `limit_usd`, so
  if `spent_usd` has already passed that limit the gateway blocks every request
  until the second call lands. Issue them back to back with nothing awaited
  between — `GatewayModel.setBump` does this inside a single `perform`. The
  residual risk is unavoidable from the client: if the clear succeeds and the
  re-bump is refused, the budget is left with no bumper at all.
- **Re-bumping restarts the clock.** A bump issued without `minutes` expires a
  full window from *now*, so replacing an amount silently extends the duration
  unless the remaining minutes are passed explicitly
  (`Derive.remainingBumpMinutes`).
- `effective_limit_usd` then includes the bump; derive the base by subtracting
  `bump_usd`, or a bumped budget looks permanently larger than configured.
- `bump_usd` outlives its expiry in config, so **`bump_expires_at` is the
  authority** for whether a bumper is live.

**The overall ceiling cannot be bumped.** The widest-window `action: "block"`
budget returns 400 — *"bumping it would raise total spend"* — because a bump is
meant to reshape when you spend, not how much. `Budget.isCeiling(among:)` must
identify the same budget the gateway does, or the UI offers a button that always
fails. Only `block` budgets count when picking the widest; a wider `warn` or
`degrade` budget is not the ceiling.

The same endpoint also accepts `budgets`, `soft_threshold_pct`, `admission`,
`effort_cap`, `model_cap`, `model_routes`, `api_token`, and `hook_telemetry`.
**`lil-ccgw` touches only `enforcement` and `bump`** — budget limits and the
effort/model governors are deliberate-decision surfaces that belong to the
dashboard and `/gateway:budget`, not a glance-and-click menu.

## What the API cannot do

**There is no `/api/stop` and no `/api/start`.** Don't go looking, and don't invent
one. A restart is a request the server can survive answering; a start is one it
can't, because a dead process cannot accept the request telling it to come alive.

Gateway lifecycle therefore lives entirely outside HTTP, in `ServiceControl.swift`:

| Need | Mechanism |
|---|---|
| stop | `launchctl bootout <service-target>`, then kill any surviving listener |
| start | `launchctl bootstrap <domain-target> <plist>` |
| restart a wedged process | `launchctl kickstart -k <service-target>` |
| unwire / re-wire Claude Code | `~/.ccgw/bin/ccgw bypass` / `wire` |

`POST /api/restart` is the one lifecycle action that *is* HTTP, and only because the
gateway is alive to answer it. Everything else must keep working when the API does
not — that is the whole reason the app has a second, subprocess-based control
channel.

## Not used, and why

| Endpoint | Why not |
|---|---|
| `/api/sessions`, `/api/context`, `/api/requests` | per-session and context detail is dashboard-grade; too much for a menu |
| `/api/pricing` | rate table is reference material, not a live metric |
| `/api/annotate` | writes user annotations; no menu affordance for it |
| `/api/update-check`, `/api/update` | updates go through `gateway-update`, which also rebuilds the binary |
| `effort_cap` / `model_cap` / `model_routes` | governors change how requests are served, not just when — a deliberate decision, not a menu click |

## Verifying after a gateway update

```sh
scripts/verify-contract.sh
```

This replaces eyeballing `curl | json.tool` against the tables above. It does two
things, and either alone would miss the case that matters:

1. **Structural** — every field listed here is present with the right JSON type.
2. **Decode** — the live payloads go through the real `Models.swift` and the same
   `keyDecodingStrategy` the app uses, then the values the UI renders are asserted
   non-nil.

The first check is the one that catches a rename, and it is worth understanding
why the second cannot. Every rate field here is optional because nullability is
real, so a renamed field decodes happily to `nil` — the decode check passes and
the panel shows a dash. Verified by pointing the script at a proxy that renamed
`burn_rate_hr`: the structural check failed and the decode check reported success.

The decode check earns its place on different failures: a budget window that no
longer parses, an empty `health.version` (restart detection polls for it to
change), a `soft_threshold_pct` of zero, or no `block` budget at all — which would
leave `Budget.isCeiling(among:)` finding nothing and the bumper offering a button
the gateway always refuses.

If a check fails, fix `Models.swift` and update both the fixtures in
`Tests/TestSupport.swift` and this document in the same commit.

The script fails rather than skips when no gateway is answering: comparing against
a live gateway is its entire purpose. The unit suite is the opposite — it must
stay runnable with the gateway stopped, which is also how we know its mocks are
not quietly reaching the network.
