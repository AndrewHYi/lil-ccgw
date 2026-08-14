#!/usr/bin/env bash
# Check the live gateway still speaks the API this app decodes.
#
# Why this exists: the gateway lives in another repo on a moving branch, and
# nothing here compiles against it. So a renamed or dropped field produces **no
# compile error and no test failure** — every rate field in Models.swift is
# optional by necessity, so a rename yields nil, and nil renders as a dash. The
# app looks broken while being entirely correct. For a tool whose whole job is a
# glanceable number, that is the worst failure mode available.
#
# The fixtures in Tests/TestSupport.swift were captured from a real gateway and
# are pinned, which keeps the unit suite deterministic and offline — and means
# the unit suite cannot notice reality moving. This script is the other half.
#
# Two checks, because either alone would miss the interesting case:
#
#   1. Structural. Every field the app consumes is present, with the right JSON
#      type. Decoding alone would not catch a rename: an absent optional decodes
#      happily to nil.
#   2. Decode. The live payloads go through the app's own Models.swift and
#      JSONDecoder configuration, and the values the UI actually shows are
#      asserted non-nil. This is the check that fails when the app would dash.
#
# Run after any gateway update, and before trusting a release. When something
# fails, fix Models.swift and update both the fixtures and
# .claude/skills/ccgw-api-contract/SKILL.md in the same commit.
#
# Usage:
#   scripts/verify-contract.sh            against the configured gateway
#   scripts/verify-contract.sh --port N   against an explicit port
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The contract is explicit: 127.0.0.1, never localhost. The gateway validates the
# Host header against loopback names to defeat DNS rebinding, and localhost can
# resolve to an IPv6 literal it rejects.
HOST="127.0.0.1"

PORT=""
for arg in "$@"; do
  case "$arg" in
    --port) shift; PORT="${1:-}" ;;
    --port=*) PORT="${arg#--port=}" ;;
    *) ;;
  esac
done

# Port comes from the gateway's own config, not a hardcoded 8484 — the app
# follows a user who moved it, and so must this.
if [[ -z "$PORT" ]]; then
  PORT="$(python3 -c '
import json, os, sys
path = os.path.expanduser("~/.ccgw/config.json")
try:
    print(json.load(open(path)).get("port", 8484))
except Exception:
    print(8484)
')"
fi

BASE="http://$HOST:$PORT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
echo "==> 1. reach the gateway at $BASE"

if ! curl -sf -m 5 "$BASE/api/health" -o "$WORK/health.json"; then
  echo "!!  no gateway answering at $BASE." >&2
  echo "    This script's whole purpose is to compare against a live gateway, so" >&2
  echo "    an unreachable one is a failure here rather than a skip. Start it with" >&2
  echo "    \`~/.ccgw/bin/ccgw start\` and re-run." >&2
  exit 1
fi
pass "gateway answering"

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","?"))' "$WORK/health.json")"
# The version the fixtures and the contract doc were captured against.
PINNED="$(grep -oE 'Verified against gateway \*\*v[0-9.]+\*\*' \
  .claude/skills/ccgw-api-contract/SKILL.md | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo unknown)"
echo "    live $VERSION, contract documented against $PINNED"
if [[ "$VERSION" != "$PINNED" ]]; then
  echo "    note: versions differ — a passing run means the fields this app uses"
  echo "          survived the change, and the doc's version line wants updating."
fi

# ---------------------------------------------------------------------------
echo "==> 2. fetch the three endpoints the app reads"

curl -sf -m 5 "$BASE/api/status" -o "$WORK/status.json" \
  && pass "GET /api/status" || fail "GET /api/status"

# The window matters: the app scopes the breakdown to the tracked budget's own
# window so the two cannot disagree. Any window works for a contract check.
FROM="$(python3 -c 'import time; print(int((time.time() - 18000) * 1000))')"
curl -sf -m 5 "$BASE/api/spend?group_by=model&from=$FROM" -o "$WORK/spend.json" \
  && pass "GET /api/spend" || fail "GET /api/spend"

[[ "$FAILURES" -eq 0 ]] || { echo "==> cannot continue without all three payloads" >&2; exit 1; }

# ---------------------------------------------------------------------------
echo "==> 3. structural check — every consumed field, with its type"

python3 - "$WORK" <<'PY' || FAILURES=$((FAILURES + 1))
import json, os, sys

work = sys.argv[1]
status = json.load(open(os.path.join(work, "status.json")))
health = json.load(open(os.path.join(work, "health.json")))
spend = json.load(open(os.path.join(work, "spend.json")))

problems = []
NUM = (int, float)


def check(container, field, types, where, optional=False):
    """Field must be present, and of an accepted type (None allowed if optional)."""
    if field not in container:
        problems.append(f"{where}: '{field}' is missing")
        return
    value = container[field]
    if value is None:
        if not optional:
            problems.append(f"{where}: '{field}' is null but the app needs a value")
        return
    if not isinstance(value, types):
        problems.append(
            f"{where}: '{field}' is {type(value).__name__}, expected {types}")


# --- /api/status -----------------------------------------------------------
check(status, "enforcement", str, "status")
check(status, "enforcement_resume_at", NUM, "status", optional=True)
check(status, "degraded", bool, "status")
# The gateway owns the soft threshold. Hardcoding 80 here, or in the app, is the
# specific mistake this line guards against.
check(status, "soft_threshold_pct", NUM, "status")
check(status, "budgets", list, "status")

if isinstance(status.get("primary"), dict):
    p = status["primary"]
    check(p, "id", str, "status.primary")
    check(p, "window", str, "status.primary")
    check(p, "fits_window", bool, "status.primary")
    # Nullable for real: a budget with no traffic has no rate at all.
    for field in ("pace", "burn_rate_hr", "sustainable_hr", "eta_hours"):
        check(p, field, NUM, "status.primary", optional=True)
elif "primary" not in status:
    problems.append("status: 'primary' is missing (null is fine, absent is not)")

for i, b in enumerate(status.get("budgets", [])):
    where = f"status.budgets[{i}]"
    for field in ("id", "scope", "window", "action"):
        check(b, field, str, where)
    for field in ("effective_limit_usd", "spent_usd", "remaining_usd", "pct"):
        check(b, field, NUM, where)
    for field in ("exhausted", "soft"):
        check(b, field, bool, where)
    for field in ("burn_rate_hr", "sustainable_hr", "pace", "bump_usd",
                  "bump_expires_at"):
        check(b, field, NUM, where, optional=True)
    if b.get("action") not in ("block", "warn", "degrade"):
        problems.append(
            f"{where}: action '{b.get('action')}' is not block/warn/degrade")

# The bumpable-budget rule depends on this: only `block` budgets count when
# picking the widest, and the widest one is the ceiling the gateway refuses to
# bump. No block budget at all means the app's ceiling logic has nothing to find.
if status.get("budgets") and not any(
        b.get("action") == "block" for b in status["budgets"]):
    problems.append("status.budgets: no 'block' budget, so nothing is the ceiling")

# --- /api/health -----------------------------------------------------------
check(health, "ok", bool, "health")
check(health, "version", str, "health")
# version and uptime_s are how a successful restart is detected — poll until one
# of them changes. Losing either silently breaks the Restart button's feedback.
check(health, "uptime_s", NUM, "health")
check(health, "upstream", str, "health")
check(health, "ledger_rows", int, "health")
check(health, "sessions_tracked", int, "health")
check(health, "telemetry_degraded", bool, "health")

# --- /api/spend ------------------------------------------------------------
check(spend, "group_by", str, "spend")
check(spend, "rows", list, "spend")
for i, r in enumerate(spend.get("rows", [])):
    where = f"spend.rows[{i}]"
    check(r, "key", str, where)
    check(r, "cost_usd", NUM, where)
    for field in ("requests", "input_tokens", "output_tokens",
                  "cache_read_tokens", "cache_write_tokens"):
        check(r, field, int, where)

if problems:
    for p in problems:
        print(f"  \033[31m✗\033[0m {p}")
    sys.exit(1)

print("  \033[32m✓\033[0m every documented field present with the expected type")
print(f"      {len(status.get('budgets', []))} budget(s), "
      f"{len(spend.get('rows', []))} spend row(s)")
PY

# ---------------------------------------------------------------------------
echo "==> 4. decode check — through the app's own types"

# The point of building this rather than re-parsing in Python: it uses
# Models.swift and the same JSONDecoder keyDecodingStrategy the app uses, so a
# field the app would silently read as nil fails here instead of in the menu.
PROBE="$WORK/probe"
mkdir -p "$PROBE"
cat > "$PROBE/main.swift" <<'SWIFT'
import Foundation

let work = CommandLine.arguments[1]
var failures: [String] = []

func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}

func load(_ name: String) -> Data {
    guard let data = FileManager.default.contents(atPath: "\(work)/\(name)") else {
        failures.append("could not read \(name)")
        return Data()
    }
    return data
}

// GatewayStatus
do {
    let status = try decoder().decode(GatewayStatus.self, from: load("status.json"))
    print("  ✓ /api/status decodes: enforcement \(status.enforcement), \(status.budgets.count) budgets")

    if status.budgets.isEmpty {
        print("  ! no budgets configured — the panel would show an empty list")
    }
    // Every value the panel actually renders per budget.
    for budget in status.budgets {
        if budget.effectiveLimitUsd <= 0 {
            failures.append("budget \(budget.id) has no usable limit")
        }
        if budget.window.isEmpty { failures.append("budget \(budget.id) has no window") }
        if budget.windowSeconds == nil {
            failures.append("budget \(budget.id) window '\(budget.window)' does not parse")
        }
    }
    // The ceiling rule the bumper depends on.
    if !status.budgets.isEmpty {
        let ceiling = status.budgets.first { $0.isCeiling(among: status.budgets) }
        if ceiling == nil {
            failures.append("no budget identifies as the ceiling; the bumper would offer a button the gateway always refuses")
        } else {
            print("  ✓ ceiling identified as \(ceiling!.id) — the bumper will hide it")
        }
    }
    if status.softThresholdPct <= 0 {
        failures.append("soft_threshold_pct is \(status.softThresholdPct); the amber band would never trigger")
    }
} catch {
    failures.append("/api/status failed to decode: \(error)")
}

// GatewayHealth
do {
    let health = try decoder().decode(GatewayHealth.self, from: load("health.json"))
    print("  ✓ /api/health decodes: v\(health.version), up \(Int(health.uptimeS))s")
    if health.version.isEmpty {
        failures.append("health.version is empty; restart detection polls for it to change")
    }
} catch {
    failures.append("/api/health failed to decode: \(error)")
}

// SpendReport
do {
    let spend = try decoder().decode(SpendReport.self, from: load("spend.json"))
    print("  ✓ /api/spend decodes: \(spend.rows.count) rows")
    for row in spend.rows where row.shortName.isEmpty {
        failures.append("spend row '\(row.key)' produces an empty display name")
    }
    if let first = spend.rows.first {
        print("  ✓ model names shorten: \(first.key) → \(first.shortName)")
    }
} catch {
    failures.append("/api/spend failed to decode: \(error)")
}

if failures.isEmpty {
    print("  ✓ every value the UI renders is present after decoding")
    exit(0)
}
for failure in failures { print("  ✗ \(failure)") }
exit(1)
SWIFT

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find "$REPO_ROOT/Sources/LilCcgw" -name '*.swift' ! -name 'LilCcgwApp.swift' | sort)

if swiftc -target "$(uname -m)-apple-macosx14.0" -o "$PROBE/bin" \
     "${SOURCES[@]}" "$PROBE/main.swift" 2>"$WORK/build.log"; then
  "$PROBE/bin" "$WORK" || FAILURES=$((FAILURES + 1))
else
  fail "the decode probe did not compile"
  sed 's/^/      /' "$WORK/build.log" | tail -20
fi

# ---------------------------------------------------------------------------
echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "==> contract holds against gateway $VERSION"
  exit 0
else
  echo "==> $FAILURES contract check(s) failed" >&2
  echo "    Fix Models.swift, then update the fixtures in Tests/TestSupport.swift" >&2
  echo "    and .claude/skills/ccgw-api-contract/SKILL.md in the same commit." >&2
  exit 1
fi
