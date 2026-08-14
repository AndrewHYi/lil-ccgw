#!/usr/bin/env bash
# Run the unit tests.
#
# Compiles the app sources *minus* LilCcgwApp.swift — its @main attribute would
# collide with the top-level code in Tests/main.swift — together with the test
# files, then runs the resulting binary. Exits non-zero on any failed assertion.
#
# Not XCTest or swift-testing: both want SwiftPM or xcodebuild, and SwiftPM
# cannot run on a Command Line Tools-only host (see CLAUDE.md).
#
# These are pure-logic tests: decoding, derived values, formatting, and label
# state. They deliberately do not touch the network or launchctl — the gateway
# integration is verified by hand against a live gateway, per CLAUDE.md.
#
# Usage:
#   scripts/test.sh                 run the suite
#   scripts/test.sh --coverage      also measure and report line coverage
#   scripts/test.sh --coverage --gate
#                                   fail if any file regressed below its floor
#   scripts/test.sh --coverage --update-floors
#                                   record current coverage as the new floors
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FLOORS="$REPO_ROOT/scripts/coverage-floors.txt"

COVERAGE=0
GATE=0
UPDATE_FLOORS=0
for arg in "$@"; do
  case "$arg" in
    --coverage) COVERAGE=1 ;;
    --gate) GATE=1; COVERAGE=1 ;;
    --update-floors) UPDATE_FLOORS=1; COVERAGE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/lil-ccgw-tests"

APP_SOURCES=()
while IFS= read -r file; do
  APP_SOURCES+=("$file")
done < <(find "$REPO_ROOT/Sources/LilCcgw" -name '*.swift' ! -name 'LilCcgwApp.swift' | sort)

TEST_SOURCES=()
while IFS= read -r file; do
  TEST_SOURCES+=("$file")
done < <(find "$REPO_ROOT/Tests" -name '*.swift' | sort)

# Instrumentation is opt-in because it slows the binary noticeably, and the
# common case is a fast red/green loop.
INSTRUMENT=()
if [[ "$COVERAGE" == "1" ]]; then
  INSTRUMENT=(-profile-generate -profile-coverage-mapping)
fi

echo "==> compiling ${#APP_SOURCES[@]} app + ${#TEST_SOURCES[@]} test sources"
swiftc \
  -target "$(uname -m)-apple-macosx14.0" \
  "${INSTRUMENT[@]+"${INSTRUMENT[@]}"}" \
  -o "$BIN" \
  "${APP_SOURCES[@]}" "${TEST_SOURCES[@]}"

echo "==> running"
if [[ "$COVERAGE" == "1" ]]; then
  LLVM_PROFILE_FILE="$WORK/tests.profraw" "$BIN"
else
  "$BIN"
fi

[[ "$COVERAGE" == "1" ]] || exit 0

# ---------------------------------------------------------------------------
# Coverage
#
# swiftc carries the same -profile-generate/-profile-coverage-mapping flags
# SwiftPM would pass, and llvm-profdata/llvm-cov ship with the Command Line
# Tools, so measuring needs no SwiftPM and no Xcode.app.
#
# Tests/ is excluded from the report. Left in, its ~1750 lines are almost fully
# covered by definition and drag the total towards 100% while saying nothing
# about the app.
#
# LilCcgwApp.swift cannot appear here at all: it is excluded from the test binary
# above, so it carries no coverage mapping. Its logic was moved into AppScene
# (Settings.swift) for exactly that reason; what is left is the @main shell.
echo "==> coverage"
PROFDATA="$WORK/tests.profdata"
"$(xcrun --find llvm-profdata)" merge -sparse "$WORK/tests.profraw" -o "$PROFDATA"

"$(xcrun --find llvm-cov)" report "$BIN" \
  -instr-profile="$PROFDATA" \
  --ignore-filename-regex='Tests/' | sed 's/^/    /'

# The table above is the human view; this is the machine view. It reads the JSON
# export rather than scraping that table, whose column positions shift with the
# widest filename and whose branch columns collapse to "-" when a file has none.
COVERAGE_TSV="$WORK/coverage.tsv"
"$(xcrun --find llvm-cov)" export "$BIN" \
  -instr-profile="$PROFDATA" \
  --ignore-filename-regex='Tests/' \
  -summary-only >"$WORK/coverage.json"
python3 - "$WORK/coverage.json" >"$COVERAGE_TSV" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["data"][0]
for f in data["files"]:
    print("%s %.2f" % (f["filename"].split("/")[-1], f["summary"]["lines"]["percent"]))
print("TOTAL %.2f" % data["totals"]["lines"]["percent"])
PY

current_coverage() { cat "$COVERAGE_TSV"; }

if [[ "$UPDATE_FLOORS" == "1" ]]; then
  {
    echo "# Per-file line-coverage floors, enforced by scripts/test.sh --gate."
    echo "#"
    echo "# A ratchet, not a target: the gate fails when a file drops below its"
    echo "# recorded floor, so coverage can climb and cannot silently rot. Raise"
    echo "# these with --update-floors when you have added tests; never lower one"
    echo "# to make a red run green."
    echo "#"
    echo "# Regenerate: scripts/test.sh --coverage --update-floors"
    echo "#"
    echo "# Why no file reads 100, and what it would take:"
    echo "#"
    echo "#   PanelView      the confirmations, the bump form and the joke line are"
    echo "#                  behind @State, which nothing outside the view can set."
    echo "#                  Their decisions are tested in PanelDeriveTests instead."
    echo "#   SettingsView   the launch-at-login toggle calls SMAppService, which"
    echo "#                  would install a real login item on the test machine."
    echo "#   Notifier       UNUserNotificationCenter.current() traps in a process"
    echo "#                  with no bundle identifier, which is what this binary is."
    echo "#   Transport      the remainder is the real URLSession send; covering it"
    echo "#                  means a listening socket, and the suite has to keep"
    echo "#                  running with the gateway stopped."
    echo "#   Help/Settings  the NSApp.windows raise loop needs a real scene list."
    echo "#   Window"
    echo "#"
    echo "# LilCcgwApp.swift is absent entirely: test.sh excludes it because its"
    echo "# @main collides with Tests/main.swift, so it carries no coverage mapping."
    current_coverage
  } >"$FLOORS"
  echo "==> floors updated in scripts/coverage-floors.txt"
  exit 0
fi

if [[ "$GATE" == "1" ]]; then
  if [[ ! -f "$FLOORS" ]]; then
    echo "!!  no $FLOORS — create it with --update-floors" >&2
    exit 1
  fi
  REGRESSIONS=0
  while read -r name floor; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    now="$(current_coverage | awk -v n="$name" '$1 == n { print $2 }')"
    if [[ -z "$now" ]]; then
      echo "    !! $name is in the floors file but not in the report" >&2
      REGRESSIONS=$((REGRESSIONS + 1))
      continue
    fi
    # Integer comparison in tenths, since macOS bash has no float arithmetic.
    now_t=$(printf '%.1f' "$now" | tr -d '.')
    floor_t=$(printf '%.1f' "$floor" | tr -d '.')
    if [[ "$now_t" -lt "$floor_t" ]]; then
      printf '    !! %s regressed: %s%% < floor %s%%\n' "$name" "$now" "$floor" >&2
      REGRESSIONS=$((REGRESSIONS + 1))
    fi
  done <"$FLOORS"

  if [[ "$REGRESSIONS" -gt 0 ]]; then
    echo "==> $REGRESSIONS coverage regression(s)" >&2
    exit 1
  fi
  echo "==> no coverage regressions"
fi
