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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BIN="$(mktemp -d)/lil-ccgw-tests"

APP_SOURCES=()
while IFS= read -r file; do
  APP_SOURCES+=("$file")
done < <(find "$REPO_ROOT/Sources/LilCcgw" -name '*.swift' ! -name 'LilCcgwApp.swift' | sort)

TEST_SOURCES=()
while IFS= read -r file; do
  TEST_SOURCES+=("$file")
done < <(find "$REPO_ROOT/Tests" -name '*.swift' | sort)

echo "==> compiling ${#APP_SOURCES[@]} app + ${#TEST_SOURCES[@]} test sources"
swiftc \
  -target "$(uname -m)-apple-macosx14.0" \
  -o "$BIN" \
  "${APP_SOURCES[@]}" "${TEST_SOURCES[@]}"

echo "==> running"
"$BIN"
