---
name: install-lil-ccgw
description: Build and install lil-ccgw.app locally, after verifying the hard prerequisite that the cc-gateway plugin is installed and the ccgw gateway is actually running. Use when installing or reinstalling the app, setting it up on a fresh machine, or diagnosing an app that shows only dashes.
---

# Install lil-ccgw

**Run the preflight first. It is a blocker, not a warning.**

`lil-ccgw` is a *display and control surface* for ccgw. It owns no data, no
budgets, and no proxy. If the gateway is not installed and running, the app
installs fine, launches fine, and then shows nothing but dashes — which reads as
a broken app rather than a missing dependency. That confusion is the single most
likely support question, so the gate exists to catch it before install, not
after.

## Preflight — all four must pass

Run this. Every line must report `ok`:

```sh
# 1. A marketplace serving cc-gateway is registered.
#    Matched by which marketplace actually provides the plugin rather than by
#    name, so this keeps working if it moves.
python3 -c "
import json, os, sys
p = os.path.expanduser('~/.claude/plugins/installed_plugins.json')
keys = [k for k in json.load(open(p)).get('plugins', {}) if k.startswith('cc-gateway@')]
print('ok   marketplace:', keys[0].split('@', 1)[1]) if keys \
  else sys.exit('BLOCKED  no marketplace providing cc-gateway is registered')
"

# 2. The cc-gateway plugin is installed
python3 -c "
import json, os, sys
p = os.path.expanduser('~/.claude/plugins/installed_plugins.json')
e = next((v for k, v in json.load(open(p)).get('plugins', {}).items()
          if k.startswith('cc-gateway@')), None)
print('ok   plugin: cc-gateway', e[0]['version']) if e \
  else sys.exit('BLOCKED  cc-gateway plugin not installed')
"

# 3. The gateway binary exists
test -x ~/.ccgw/bin/ccgw \
  && echo "ok   binary: ~/.ccgw/bin/ccgw" \
  || echo "BLOCKED  ccgw binary missing — the plugin is installed but never set up"

# 4. The gateway is actually answering
curl -sf -m 2 http://127.0.0.1:8484/api/health \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok   running: ccgw', d['version'], 'up', int(d['uptime_s']//60), 'min')" \
  || echo "BLOCKED  gateway not responding on 127.0.0.1:8484"
```

### If any check fails — stop and fix that first

| Failure | Remediation |
|---|---|
| Marketplace not registered | Register the marketplace that serves `cc-gateway` — it's organisation-internal, so ask whoever administers yours |
| Plugin not installed | `claude plugin install cc-gateway@<marketplace>`, then restart Claude Code |
| Binary missing | Plugin installed but never set up. In Claude Code: `/cc-gateway:gateway-setup`, or ask *"set up the cost gateway"* |
| Not responding, agent loaded | `launchctl kickstart -k gui/$UID/io.ccgw.gateway`, then re-check. Logs: `~/.ccgw/logs/launchd.err.log` |
| Not responding, agent absent | `~/.ccgw/bin/ccgw service install` then `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.ccgw.gateway.plist` |
| Responding on another port | Read `port` from `~/.ccgw/config.json`; set it in the app's Settings → General |

**Do not proceed past a BLOCKED line, and do not install the app "so it's ready
for later."** An installed app with no gateway behind it is worse than no app: it
occupies menu bar space and misreports the system as broken.

> If your marketplace is registered against a branch rather than its default,
> that pin goes stale once the branch merges and will quietly install an old
> gateway. Check the ref before blaming this app for missing fields.

## Install

```sh
cd <repo>
./scripts/test.sh                      # must pass before installing
./scripts/build.sh --release
cp -r dist/lil-ccgw.app /Applications/
open /Applications/lil-ccgw.app
```

Requires only the Command Line Tools — **no Xcode**. There is no `Package.swift`
on purpose; see CLAUDE.md.

For a release build to hand to someone else, use `--universal` and see the
`release-cask` skill.

## Verify the install

1. **The item appears** in the menu bar, e.g. `$20.59/$75 5h`. No Dock icon
   (`LSUIElement`), so Settings is reached from the panel, not the Dock.
2. **The title updates on its own.** Watch it for a minute without clicking. A
   title that only changes when the panel opens means the label is reading the
   `@Observable` model outside `body` and never registered a dependency — see
   `MenuBarTitle` in `MenuBarLabel.swift`.
3. **Numbers match the gateway** — the panel's budgets come from the same
   `/api/status` the dashboard uses, so they must agree:

   ```sh
   curl -s 127.0.0.1:8484/api/status | python3 -c "
   import json,sys
   for b in json.load(sys.stdin)['budgets']:
       print(f\"  {b['id']:16} {b['window']:4} \${b['spent_usd']:.2f}/\${b['effective_limit_usd']:.0f}\")"
   ```

   **Expect small drift, not disagreement.** At a typical burn of ~$14/hr, spend
   moves ~$0.24 a minute, and `/dash` polls status every 4s while the app's
   closed-panel title polls every 30s. Opening the panel forces a fresh read, so
   compare with the panel open. A difference of a few cents is timing; a
   difference of dollars is a bug.

4. **Controls respond** — Restart should change `uptime_s` in
   `/api/health` without severing in-flight requests.

## Uninstall

```sh
osascript -e 'quit app "lil-ccgw"' 2>/dev/null
rm -rf /Applications/lil-ccgw.app
defaults delete com.andrewhyi.lil-ccgw 2>/dev/null
```

This removes only the menu bar app. The gateway, its budgets, and its ledger are
untouched — use `/cc-gateway:gateway-remove` for those.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Panel shows all dashes | Gateway not running. Re-run the preflight. |
| Can't find Settings | No Dock icon, so there's no Dock menu. Click the menu bar item, then **Settings…** at the bottom of the panel (⌘, while it's open). |
| Settings does nothing when clicked | The window opened behind everything. `LSUIElement` apps never activate on their own — `SettingsWindow.present` calls `NSApp.activate` for exactly this. |
| Title frozen until the panel is opened | The label read the `@Observable` model outside `body`. Use `MenuBarTitle`. |
| Icon is a warning triangle | Same — the app's down state. |
| Menu bar doesn't match Anthropic's usage page | Not a bug — the title tracks a 5h rolling window, that page is month-to-date. Compare the panel's `monthly 30d` row, and expect a few percent from pre-proxy spend plus list-rate pricing. |
| Numbers off by dollars against `/api/status` | Real bug. Check `ccgw-api-contract` for a renamed field. |
| Buttons fail with HTTP 401/403 | `api_token: true` in config; the app sends `~/.ccgw/token`, so confirm that file exists and is readable. |
| Stop appears to do nothing | Pre-fix behaviour. `KeepAlive=true` respawns a SIGTERM; the app uses `launchctl bootout` instead. |
| Launch-at-login won't stay on | Expected on an ad-hoc-signed build. Approve in System Settings → General → Login Items. |
| No notifications | Also expected unsigned; the Alerts pane says so. |
