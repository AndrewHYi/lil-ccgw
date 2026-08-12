# ccgw — the gateway this app front-ends

`lil-ccgw` is only a menu bar surface. All the behaviour it displays and controls
belongs to **ccgw**, a separate project distributed as a Claude Code plugin.

> **ccgw is a hard prerequisite.** The app has no data of its own — without a
> running gateway it shows dashes and looks broken. The `install-lil-ccgw` skill
> gates installation on a four-point preflight; do not skip it, and do not
> install the app ahead of the gateway.

## Is it already set up?

```sh
curl -sf -m2 http://127.0.0.1:8484/api/health && echo " ← up"
python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')))
e=[v for k,v in d.get('plugins',{}).items() if k.startswith('cc-gateway@')]
print('plugin:', e[0][0]['version'] if e else 'NOT INSTALLED')"
```

Install records live in `~/.claude/plugins/installed_plugins.json`, keyed
`cc-gateway@<marketplace>`. Matching on the `cc-gateway@` prefix rather than a
specific marketplace keeps the check working if the plugin is served from a
different one.

## Where it comes from

ccgw ships as a Claude Code plugin from an **organisation-internal marketplace**,
so it is not publicly obtainable and this document deliberately does not name the
source repository or branch. If you have access, ask whoever administers your
Claude Code plugin marketplace for the `cc-gateway` plugin; if you don't, this
app has nothing to display and there is no public substitute.

## Install

Register your organisation's marketplace, install the plugin, then run its own
setup skill from inside Claude Code — *"set up the cost gateway"*, or:

```
/cc-gateway:gateway-setup
```

That skill handles preflight, install, budget configuration, service
registration (launchd on macOS, systemd user unit on Linux), `settings.json`
wiring, and verification. The `ANTHROPIC_BASE_URL` change takes effect in the
**next** Claude Code session.

Its own README is the canonical reference for everything below, and it travels
with the plugin — read it there rather than trusting this summary to stay current.

## What ccgw is

A local reverse proxy between the Claude Code CLI and the Anthropic API. It
enforces spend budgets with **preflight** checks — before tokens are bought,
not after — and records per-request cost telemetry to a local SQLite ledger.

It exists because short rolling windows are what catch a cost runaway early,
while it is still a small problem rather than a month-end surprise. Limits and
windows are configured per install in `~/.ccgw/config.json`; this app reads
whatever is there and hardcodes no policy of its own.

Everything binds to `127.0.0.1`. Credentials pass through untouched and
unlogged.

## Surfaces

| Surface | Where |
|---|---|
| Dashboard | <http://127.0.0.1:8484/dash> |
| Statusline | inside Claude Code — `$4.20/$75 5h │ $148/$1200 mo` |
| MCP server | `http://127.0.0.1:8484/mcp` — read-only spend tools |
| Commands | `/gateway:status`, `:report`, `:budget`, `:pause` |
| **This app** | menu bar |

## Local paths

| Path | What |
|---|---|
| `~/.ccgw/config.json` | budgets, port, `soft_threshold_pct`, `enforcement` — the app reads these, never sets them |
| `~/.ccgw/bin/ccgw` | CLI — **not on `PATH`** |
| `~/.ccgw/token` | API token, when `api_token: true` |
| `~/.ccgw/logs/` | launchd stdout/stderr |
| `~/Library/LaunchAgents/io.ccgw.gateway.plist` | the agent, `KeepAlive=true` |

## Escape hatches

If the gateway misbehaves, Claude Code fails closed — connection refused on
every request. Two ways out, both reachable from this app's menu:

```sh
~/.ccgw/bin/ccgw bypass   # unwire settings.json; next Claude Code start goes direct
~/.ccgw/bin/ccgw wire     # re-enable
```

Full uninstall is `/cc-gateway:gateway-remove`.

## The icon's escalation is ported from here

The menu bar glyph reproduces the dashboard's `#skit` element — the pixel-art
intern whose plant thrives at a sustainable pace and whose desk catches fire as
burn rate climbs. Tier names, thresholds (0.85 / 1.2 / 1.6 / 2.0 × sustainable),
the ten-minute meltdown-to-acceptance clock, the `exhausted && block && global`
funeral condition, and the first-of-the-month reset all match
`plugins/cc-gateway/src/dashboard.html`.

Presentation does not match, and can't: those are animated sprite grids on a web
page. In a 22pt menu bar they become SF Symbols. The captions and asides here are
original rather than copied, since this repo has to go public for the Homebrew
cask while the dashboard's are internal.

If the upstream thresholds change, `.claude/skills/menubar-ergonomics/SKILL.md`
and `Tests/SkitTests.swift` pin ours — the test suite asserts every boundary from
both sides and will fail rather than drift silently.

## The API this app depends on

See [`.claude/skills/ccgw-api-contract/SKILL.md`](../.claude/skills/ccgw-api-contract/SKILL.md)
for the exact endpoints and field names, and why each one matters. The gateway is
on a moving branch, so that file is the thing to check when this app starts
showing dashes.
