#!/usr/bin/env bash
# Build lil-ccgw.app from source.
#
# Uses swiftc directly rather than SwiftPM. That is deliberate: on hosts with
# only the Command Line Tools installed, SwiftPM's libPackageDescription.dylib
# can be older than its bundled .swiftmodule, and *every* manifest — including
# an empty one — fails to link with an undefined Package.init symbol. swiftc has
# no such dependency, and since the .app bundle is assembled by hand anyway,
# SwiftPM was buying nothing here.
#
# Usage:
#   scripts/build.sh                 native arch, debug-ish, into dist/
#   scripts/build.sh --release       optimised
#   scripts/build.sh --universal     arm64 + x86_64 (for distribution)
#   scripts/build.sh --universal --allow-single-arch
#                                    tolerate a failed x86_64 slice — NOT for release
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="lil-ccgw"
BUNDLE_ID="com.andrewhyi.lil-ccgw"
MIN_MACOS="14.0"
DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"

# Seeded with an explicit flag rather than left empty: macOS ships bash 3.2,
# where expanding an empty array under `set -u` is an unbound-variable error, so
# an unflagged `build.sh` would abort.
OPTIMISE=(-Onone)
UNIVERSAL=0
ALLOW_SINGLE_ARCH=0
for arg in "$@"; do
  case "$arg" in
    --release) OPTIMISE=(-O) ;;
    --universal) UNIVERSAL=1; OPTIMISE=(-O) ;;
    --allow-single-arch) ALLOW_SINGLE_ARCH=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)"
SOURCES=("$REPO_ROOT"/Sources/LilCcgw/*.swift)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

build_slice() {
  local arch="$1" out="$2"
  swiftc \
    -target "${arch}-apple-macosx${MIN_MACOS}" \
    -parse-as-library \
    "${OPTIMISE[@]}" \
    -o "$out" \
    "${SOURCES[@]}"
}

if [[ "$UNIVERSAL" == "1" ]]; then
  echo "==> building universal (arm64 + x86_64)"
  build_slice arm64 "$DIST/$APP_NAME-arm64"
  # A cross-compiled x86_64 slice needs the SDK to carry that arch. If it
  # cannot, fail — this used to warn and ship arm64 anyway, but a warning
  # scrolls past in a release log and the result is a bundle an Intel Mac
  # cannot exec at all. brew install succeeds, then the app never launches.
  # --allow-single-arch is the deliberate opt-out for local builds only.
  if build_slice x86_64 "$DIST/$APP_NAME-x86_64" 2>/dev/null; then
    lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
      "$DIST/$APP_NAME-arm64" "$DIST/$APP_NAME-x86_64"
  elif [[ "$ALLOW_SINGLE_ARCH" == "1" ]]; then
    echo "!!  x86_64 slice failed — shipping arm64 only (--allow-single-arch)" >&2
    cp "$DIST/$APP_NAME-arm64" "$APP/Contents/MacOS/$APP_NAME"
  else
    rm -f "$DIST/$APP_NAME-arm64"
    echo "!!  x86_64 slice failed to build. This SDK cannot cross-compile it," >&2
    echo "    so a --universal build here would ship arm64 only and break on" >&2
    echo "    Intel. Pass --allow-single-arch if you accept that locally." >&2
    exit 1
  fi
  rm -f "$DIST/$APP_NAME-arm64" "$DIST/$APP_NAME-x86_64"
else
  echo "==> building $(uname -m)"
  build_slice "$(uname -m)" "$APP/Contents/MacOS/$APP_NAME"
fi

# LSUIElement is what makes this a Menu Bar Extra rather than a windowed app:
# no Dock icon, no app switcher entry.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>lil ccgw</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. No Developer ID is available (security find-identity
# reports zero valid codesigning identities), so notarization is impossible and
# the cask strips com.apple.quarantine instead — the same posture AeroSpace
# takes. Ad-hoc signing still gives the bundle a consistent identity, which
# SMAppService and the notification centre both prefer.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "!!  ad-hoc codesign failed; app will still run but login item may not" >&2

echo "==> built $APP (version $VERSION)"
file "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    /'
