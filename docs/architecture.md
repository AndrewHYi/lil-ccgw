# How lil-ccgw works

Where the numbers come from, and how often. UI and animation are out of scope.

lil-ccgw is a menu bar window onto a local proxy's database. It stores nothing and
computes nothing — it asks the proxy for fresh numbers every few seconds.

## The shape of it

There's a toll booth on the road between your laptop and Anthropic.

Claude Code doesn't talk to `api.anthropic.com` directly. `ANTHROPIC_BASE_URL`
points at `127.0.0.1:8484`, so requests go through **ccgw**, a proxy running on
your own machine. ccgw waves each request through and writes down what it cost, in
a SQLite file at `~/.ccgw/ledger.db`. It also refuses requests once you're over
budget — that's the toll part.

lil-ccgw is a display bolted to the booth. Every few seconds it asks ccgw what the
ledger says and puts the answer in the menu bar.

Which means the app has no numbers of its own. A blank display is a closed booth,
not a broken display — and a closed booth means Claude Code has stopped working
too.

```
Claude Code
    │   ANTHROPIC_BASE_URL = http://127.0.0.1:8484
    ▼
┌─────────────────────────────────────────────┐
│  ccgw  (local proxy, separate project)      │
│                                             │
│  • checks budgets BEFORE forwarding         │
│  • forwards to api.anthropic.com            │
│  • reads the streamed reply for the real    │
│    token counts, prices them, appends a     │
│    row to ~/.ccgw/ledger.db                 │
│  • serves an HTTP API describing all of it  │
└─────────────────────────────────────────────┘
    │   HTTP on 127.0.0.1:8484        ▲
    ▼                                 │
api.anthropic.com          ┌──────────┴──────────┐
                           │  lil-ccgw (this app)│
                           │  polls, displays,   │
                           │  sends commands     │
                           └─────────────────────┘
```

ccgw is a separate project, shipped as a Claude Code plugin. This app is a client
of its HTTP API and nothing else.

## How the proxy does it

One server, two hats, split by URL path:

| Path | Behaviour |
|---|---|
| `/v1/*` | passthrough — forwarded to `api.anthropic.com` |
| `/api/*` | ccgw's own API, which this app polls |
| `/dash` | the web dashboard |
| `/mcp` | an MCP server, so Claude can query its own spend |

That split is why Claude Code never notices. `/v1/messages` looks identical whether
it lands on `api.anthropic.com` or on loopback; only the hostname changed.

Cost comes from the reply, not the request:

1. **Preflight** — budgets are checked before anything is forwarded. Over budget
   means the request is never sent, so no tokens are bought.
2. **Forward** — headers copied through minus the hop-by-hop ones, then `fetch`
   upstream. Credentials pass through untouched and unlogged.
3. **Tee** — the reply streams. ccgw forwards those bytes byte-for-byte while
   parsing a *copy* for `message_start` (input tokens, plus the cache read/write
   breakdown) and the final `message_delta` (authoritative output tokens). Parsing
   a copy is what keeps it from corrupting or delaying the stream.
4. **Price and record** — apply a rate table, append one ledger row.

So token counts are measured from Anthropic's response rather than estimated. The
model is read from the response too, which means an upstream model substitution
can't skew the price.

A blocked request returns a deliberate **403**, not 429 or 503. Claude Code retries
those, so a budget stop would become a retry storm; the 403 surfaces immediately
with the reason in the message text. ccgw also refuses any request whose `Host`
header isn't a loopback name, which stops a web page in your browser from driving
your gateway.

## Three endpoints

Every refresh hits the same three reads. That's the whole data layer.

| Endpoint | Gives us | Used for |
|---|---|---|
| `GET /api/status` | every budget's spend, limit, percentage; burn rate; pace; whether enforcement is on | almost everything |
| `GET /api/health` | version, uptime | the header, and "is it alive" |
| `GET /api/spend?group_by=model` | cost per model | the top-models list |

`/api/status` does most of the work. It arrives as JSON and decodes into plain
Swift structs in `Models.swift` — no database, no cache, no local state.

The spend request needs a time window, and that window comes from whichever budget
the menu bar is tracking. If the title shows the 5-hour budget, the breakdown is
fetched over 5 hours, which is why the two always add up. Getting this wrong once
produced a $41 breakdown sitting under a $27 budget, which read as an arithmetic
bug.

## Polling

No push, no websocket, no server-sent events. The app asks, repeatedly.

```
loop forever:
    fetch status + health   (concurrently)
    fetch spend             (after — it needs the tracked budget's window)
    sleep <interval>
```

| Situation | Interval | Why |
|---|---|---|
| Dropdown open | 5s | you're looking at it |
| Dropdown closed | 30s | ambient; keep it cheap |
| Gateway unreachable | 5s | Claude Code is broken right now, so noticing recovery beats being polite |

Opening the dropdown also forces an immediate fetch, so you never read a
30-second-old number while staring at it.

Polling rather than streaming because ccgw's `/api/events` isn't server-sent
events despite the name — it returns a JSON array of rows since a timestamp. There
is nothing to subscribe to. The cost is trivial; these are loopback requests that
finish in milliseconds.

The visible consequence: the menu bar can lag the dashboard by up to 30 seconds. At
a typical burn rate that's a few cents, which is where *cents apart is timing,
dollars apart is a bug* comes from.

## Reading versus writing

The app is read-only about money. It never touches the ledger, never edits budgets,
and can't make spend appear or disappear.

It does send a small fixed set of commands, all of which ask ccgw to change its own
behaviour:

| Command | Effect |
|---|---|
| `POST /api/restart` | restart the gateway gracefully |
| `PUT /api/budgets {enforcement: off}` | pause enforcement for N minutes; auto-reverts |
| `PUT /api/budgets {bump: ...}` | temporarily raise one budget's limit |

There is no stop or start endpoint, and that asymmetry is deliberate. A restart is
a request a server can survive answering; a start is one it can't, because a dead
process can't accept the request telling it to come alive.

So the app has **two control channels**, and every button in the panel belongs to
one or the other:

| Button | What it actually does |
|---|---|
| Restart | `POST /api/restart` |
| Pause, `+ bumper` | `PUT /api/budgets` |
| Recover / Start | `launchctl kickstart -k gui/$UID/io.ccgw.gateway`, falling back to `launchctl bootstrap gui/$UID …/io.ccgw.gateway.plist` |
| Stop | `launchctl bootout gui/$UID/io.ccgw.gateway`, then `/bin/kill <pid>` if anything still holds the port |
| Bypass / Reconnect | `~/.ccgw/bin/ccgw bypass` / `wire` — edits `settings.json` |

HTTP handles *change your behaviour*, and works only while the gateway is alive.
Subprocesses handle *exist, or stop existing*, and work when it's dead — which is
exactly when you need them. That split is why `ServiceControl.swift` is a separate
file from `GatewayClient.swift` rather than folded into it.

`/api/restart` is worth knowing in detail, because the app's behaviour around it
follows from the mechanism:

1. It replies `200 {restarting, mode, in_flight}` **first**, so the caller gets an
   answer instead of a dropped connection.
2. It checks whether it's supervised — `XPC_SERVICE_NAME` under launchd,
   `INVOCATION_ID` under systemd.
3. It **drains**, polling until in-flight requests reach zero, with a 60-second
   timeout so one wedged request can't block the restart forever.
4. Supervised, it closes the server and exits **64** — deliberately non-zero, so
   `KeepAlive` treats it as a failure and relaunches. It doesn't restart itself; it
   asks to be replaced. Unsupervised, it spawns a detached `cli.js serve` child and
   then exits.

The same `KeepAlive=true` that makes stopping the gateway awkward is what makes
restarting it easy. And because of the drain, the app waits before polling
`/api/health` for a changed `uptime_s` rather than assuming the restart is
instant.

## When something breaks

| What breaks | What you see |
|---|---|
| One endpoint fails | that section disappears; the rest still works |
| Gateway is down | warning icon, and a panel saying Claude Code requests are failing, with a Recover button |
| Gateway is up but a field was renamed | dashes where a number should be, and no error |

That last row is why the repo keeps a written contract of every field it reads, in
`.claude/skills/ccgw-api-contract/SKILL.md`. Nothing here compiles against ccgw's
API, so the coupling is real and the compiler can't see it.

## The short version

Claude Code talks to a proxy on my laptop instead of straight to Anthropic. The
proxy prices every request, writes it to a local database, and blocks requests once
I'm over budget. The menu bar app polls that proxy every few seconds and shows the
numbers — it has no data of its own, so if it's blank the proxy is down, and that
means Claude Code has stopped working.

## Where to look in the code

| File | Role |
|---|---|
| `GatewayClient.swift` | the three reads and the commands; one HTTP funnel |
| `Transport.swift` | the seam that makes the client testable |
| `Models.swift` | Swift mirrors of ccgw's JSON |
| `GatewayModel.swift` | the poll loop, the cadence, the snapshot everything reads |
| `ServiceControl.swift` | `launchctl` and CLI paths, for when HTTP can't help |
