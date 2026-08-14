#!/usr/bin/env bash
# Verify the Homebrew cask install end to end, without touching the real install.
#
# What this replaces: release-cask/SKILL.md step 6 used to untap/tap/install into
# the developer's own /Applications and eyeball the result. That mutates the
# machine you are releasing from, and "it looked fine" is not an assertion.
#
# Why not Docker: a Linux container cannot install this cask at all. Homebrew's
# own guard (extend/os/linux/cask/installer.rb) raises "This cask requires macOS"
# for any cask whose depends_on requires macOS or whose artifacts are macOS-only
# — and lil-ccgw.rb is both (`depends_on macos:` and an `app` stanza). Docker on
# macOS only runs Linux containers, so there is no container path to this test.
# The payload is a Mach-O bundle, the postflight shells out to /usr/bin/xattr,
# and the assertions that matter (Gatekeeper, LaunchServices) have no Linux
# equivalent.
#
# So the isolation is done on macOS instead, with three layers:
#
#   1. A throwaway Homebrew prefix. Caskroom.path is HOMEBREW_PREFIX/"Caskroom"
#      (cask/caskroom.rb) and HOMEBREW_PREFIX is derived from the brew script's
#      own path (bin/brew), so a separate clone gets a separate Caskroom. There
#      is no HOMEBREW_CASKROOM env override — the clone is the only way.
#   2. --appdir, via HOMEBREW_CASK_OPTS, so the app never lands in /Applications.
#   3. A tap created inside that prefix. Homebrew refuses a bare .rb path
#      ("Homebrew requires casks to be in a tap"), and testing through a real tap
#      is closer to the user's actual flow anyway.
#
# Two things that bit during development, recorded so they don't bite again:
#
#   * HOMEBREW_PREFIX must not sit inside HOMEBREW_TEMP, which defaults to
#     /private/tmp on macOS. check-prefix-is-not-tmpdir (brew.sh) is a plain
#     prefix-string comparison, so a prefix under /private/tmp aborts. That is
#     why the clone is cached under ~/.cache and not in mktemp -d.
#   * $HOME isolates Homebrew but NOT preferences, and the asymmetry matters.
#     NSUserDefaults goes through cfprefsd, which resolves the home directory
#     from the user record and ignores $HOME — verified by writing a pref with
#     HOME redirected and finding it in the real home. Homebrew's own `~`
#     expansion (in `zap trash:`) does respect $HOME. So: launching the app here
#     writes the user's real preference domain, while `brew zap` looks only
#     inside the room. That is why the zap check plants a decoy plist in the
#     room rather than asserting against the real one, and why the real plist is
#     snapshotted and restored regardless.
#
# Usage:
#   scripts/verify-cask.sh              build from the working tree and verify
#   scripts/verify-cask.sh --zap        also verify the zap stanza (see above)
#   scripts/verify-cask.sh --fresh      re-clone the cached Homebrew first
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="lil-ccgw"
BUNDLE_ID="com.andrewhyi.lil-ccgw"
REAL_APP="/Applications/$APP_NAME.app"
REAL_PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lil-ccgw/verify-cask"
BREW="$CACHE/brew"

DO_ZAP=0
FRESH=0
for arg in "$@"; do
  case "$arg" in
    --zap) DO_ZAP=1 ;;
    --fresh) FRESH=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

FAILURES=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else fail "$1: got '$2', want '$3'"; fi; }

ROOM=""
PREFS_BACKUP=""
cleanup() {
  local code=$?
  # Restore the real preferences first — this is the only thing here that can
  # damage anything the user cares about.
  if [[ -n "$PREFS_BACKUP" && -f "$PREFS_BACKUP" ]]; then
    cp "$PREFS_BACKUP" "$REAL_PREFS" 2>/dev/null || true
    # cfprefsd caches, so a file-level restore is invisible until it reloads.
    killall -u "$USER" cfprefsd 2>/dev/null || true
  fi
  [[ -n "$ROOM" && -d "$ROOM" ]] && rm -rf "$ROOM"
  # Leave the cached brew clone; wipe only the state this run created.
  rm -rf "$BREW/Caskroom" "$BREW/Library/Taps/local" 2>/dev/null || true
  return $code
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "==> 0. recording the real install so we can prove it was untouched"

REAL_APP_BEFORE="$(ls -ldi "$REAL_APP" 2>/dev/null | awk '{print $1, $NF}' || echo absent)"
REAL_CASKROOM_BEFORE="$(ls /opt/homebrew/Caskroom/$APP_NAME 2>/dev/null | sort | tr '\n' ' ' || echo absent)"
if [[ -f "$REAL_PREFS" ]]; then
  PREFS_BACKUP="$(mktemp)"
  cp "$REAL_PREFS" "$PREFS_BACKUP"
  pass "backed up real preferences ($(wc -c <"$PREFS_BACKUP" | tr -d ' ') bytes)"
else
  pass "no real preferences to back up"
fi

# ---------------------------------------------------------------------------
echo "==> 1. throwaway Homebrew prefix"

[[ "$FRESH" == "1" ]] && rm -rf "$BREW"
if [[ ! -x "$BREW/bin/brew" ]]; then
  mkdir -p "$CACHE"
  echo "    cloning Homebrew (cached at $BREW for future runs)"
  git clone --depth 1 https://github.com/Homebrew/brew "$BREW" 2>&1 | tail -1
fi
rm -rf "$BREW/Caskroom"

ROOM="$(mktemp -d "$CACHE/room.XXXXXX")"
mkdir -p "$ROOM/Applications" "$ROOM/tmp" "$ROOM/home"

# HOMEBREW_TEMP lands inside the room so downloads and staging go with it.
# HOMEBREW_PREFIX ($BREW) deliberately sits outside it — see the header.
brew_room() {
  env HOME="$ROOM/home" \
      HOMEBREW_TEMP="$ROOM/tmp" \
      HOMEBREW_CASK_OPTS="--appdir=$ROOM/Applications" \
      HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_ANALYTICS=1 \
      HOMEBREW_NO_ENV_HINTS=1 \
      HOMEBREW_NO_INSTALL_FROM_API=1 \
      "$BREW/bin/brew" "$@"
}
check "prefix is isolated" "$(brew_room --prefix)" "$BREW"

# ---------------------------------------------------------------------------
echo "==> 2. build and package exactly as a release does"

./scripts/build.sh --universal >/dev/null
BUILT_ARCHES="$(lipo -archs "dist/$APP_NAME.app/Contents/MacOS/$APP_NAME" | tr -s ' ')"
check "built binary is universal" "$BUILT_ARCHES" "x86_64 arm64"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "dist/$APP_NAME.app/Contents/Info.plist")"
echo "    version $VERSION"

# ditto, not zip: it preserves the bundle's symlinks and resource forks.
ZIP="$ROOM/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "dist/$APP_NAME.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "    sha256 $SHA"

# ---------------------------------------------------------------------------
echo "==> 3. local tap pinned at that artifact"

TAP="$BREW/Library/Taps/local/homebrew-test"
mkdir -p "$TAP/Casks"
# Mirrors the real cask (AndrewHYi/homebrew-tap Casks/lil-ccgw.rb); only the url
# is repointed at the local zip. Keep the stanzas in step with the real one, or
# this verifies a cask nobody ships.
cat > "$TAP/Casks/$APP_NAME.rb" <<RB
cask "$APP_NAME" do
  version "$VERSION"
  sha256 "$SHA"

  url "file://$ZIP"
  name "$APP_NAME"
  desc "Menu bar app for the ccgw Claude Code cost gateway"
  homepage "https://github.com/AndrewHYi/$APP_NAME"

  depends_on macos: :sonoma # macOS 14

  app "$APP_NAME.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/$APP_NAME.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]
end
RB
git -C "$TAP" init -q
git -C "$TAP" add -A
git -C "$TAP" -c user.email=verify@local -c user.name=verify commit -qm "local verification tap"
pass "tap created at local/test"

# ---------------------------------------------------------------------------
echo "==> 4. install"

if brew_room install --cask "local/test/$APP_NAME" >"$ROOM/install.log" 2>&1; then
  pass "brew install --cask succeeded"
else
  fail "brew install --cask failed"
  sed 's/^/      /' "$ROOM/install.log"
  exit 1
fi

INSTALLED="$ROOM/Applications/$APP_NAME.app"

# ---------------------------------------------------------------------------
echo "==> 5. assert the installed bundle"

if [[ -d "$INSTALLED" ]]; then pass "bundle landed in the room's appdir"
else fail "bundle missing at $INSTALLED"; exit 1; fi

check "installed binary is universal" \
  "$(lipo -archs "$INSTALLED/Contents/MacOS/$APP_NAME" | tr -s ' ')" "x86_64 arm64"

check "installed version matches the build" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")" \
  "$VERSION"

# The real Gatekeeper assertion. `spctl --assess` deliberately is NOT used: this
# app is ad-hoc signed and cannot be notarized, so spctl always fails it.
# Gatekeeper only enforces on quarantined files, so the absence of the
# quarantine xattr is what actually proves the postflight worked.
if xattr "$INSTALLED" 2>/dev/null | grep -q "com.apple.quarantine"; then
  fail "com.apple.quarantine still present — the postflight xattr did not run"
else
  pass "no com.apple.quarantine (postflight ran)"
fi

# ditto preserves the signature; a plain `zip` would corrupt it.
if codesign --verify --deep --strict "$INSTALLED" 2>/dev/null; then
  pass "code signature survived the round trip"
else
  fail "codesign --verify failed on the installed bundle"
fi

# ---------------------------------------------------------------------------
echo "==> 6. launch it"

# The bundle's binary is launched directly rather than via `open`, so this
# process (and its exit) stays controllable. Note this shares the real
# preference domain — see the header on cfprefsd.
#
# disown after backgrounding: otherwise bash reports "Terminated: 15" for the
# job when it is killed, which reads as a failure in the middle of a passing run.
"$INSTALLED/Contents/MacOS/$APP_NAME" >"$ROOM/run.log" 2>&1 &
APP_PID=$!
disown "$APP_PID" 2>/dev/null || true
sleep 3
if kill -0 "$APP_PID" 2>/dev/null; then
  pass "launched and still alive after 3s"
  kill -TERM "$APP_PID" 2>/dev/null || true
  sleep 1
  if kill -0 "$APP_PID" 2>/dev/null; then
    fail "did not exit on SIGTERM"
    kill -9 "$APP_PID" 2>/dev/null || true
  else
    pass "exited cleanly on SIGTERM"
  fi
else
  fail "died within 3s of launch"
  sed 's/^/      /' "$ROOM/run.log"
fi

# ---------------------------------------------------------------------------
echo "==> 7. uninstall"

DECOY="$ROOM/home/Library/Preferences/$BUNDLE_ID.plist"
UNINSTALL_ARGS=(uninstall --cask "$APP_NAME")
if [[ "$DO_ZAP" == "1" ]]; then
  # `zap` is a flag on uninstall, not a subcommand — `brew zap` is not a command
  # and fails with "Unknown command", which an earlier `|| true` here hid.
  UNINSTALL_ARGS=(uninstall --cask --zap "$APP_NAME")

  # Homebrew expands the zap stanza's `~` against $HOME, so a decoy planted in
  # the room is what zap actually reaches, and the real plist is never at risk.
  # This still catches the failure that matters: a zap path that doesn't match
  # where the app really stores preferences, which silently leaves cruft behind
  # on every uninstall.
  #
  # Written as a literal file rather than with `defaults write`. For a domain
  # that is currently live — the user's own lil-ccgw is usually running, so
  # cfprefsd owns com.andrewhyi.lil-ccgw — `defaults write <path> key value`
  # returns 0, creates nothing at the path given, and routes the key into the
  # live domain instead, where the running app flushes it to the user's real
  # plist. So it both failed to plant the decoy (making this check pass
  # vacuously) and polluted real preferences. A plain file write does neither.
  mkdir -p "$(dirname "$DECOY")"
  cat > "$DECOY" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>verifyCaskDecoy</key><true/></dict>
</plist>
PLIST
  if [[ -f "$DECOY" ]]; then pass "planted decoy preferences in the room"
  else fail "could not plant the decoy"; exit 1; fi
fi

if brew_room "${UNINSTALL_ARGS[@]}" >"$ROOM/uninstall.log" 2>&1; then
  pass "brew ${UNINSTALL_ARGS[*]:0:3} succeeded"
else
  fail "brew ${UNINSTALL_ARGS[*]:0:3} failed"
  sed 's/^/      /' "$ROOM/uninstall.log"
fi

if [[ -d "$INSTALLED" ]]; then fail "bundle survived uninstall"; else pass "bundle removed"; fi
if [[ -d "$BREW/Caskroom/$APP_NAME" ]]; then fail "Caskroom entry survived uninstall"
else pass "Caskroom entry removed"; fi

if [[ "$DO_ZAP" == "1" ]]; then
  if [[ -f "$DECOY" ]]; then
    fail "zap left $BUNDLE_ID.plist behind — check the zap stanza's path"
    sed 's/^/      /' "$ROOM/uninstall.log"
  else
    pass "zap removed the preferences plist"
  fi
fi

# ---------------------------------------------------------------------------
echo "==> 8. assert the real install was never touched"

check "real /Applications bundle unchanged" \
  "$(ls -ldi "$REAL_APP" 2>/dev/null | awk '{print $1, $NF}' || echo absent)" \
  "$REAL_APP_BEFORE"

check "real Caskroom unchanged" \
  "$(ls /opt/homebrew/Caskroom/$APP_NAME 2>/dev/null | sort | tr '\n' ' ' || echo absent)" \
  "$REAL_CASKROOM_BEFORE"

# ---------------------------------------------------------------------------
echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "==> cask verified: $APP_NAME $VERSION"
  echo "    sha256 $SHA"
  exit 0
else
  echo "==> $FAILURES check(s) failed" >&2
  exit 1
fi
