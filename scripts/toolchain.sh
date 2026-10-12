#!/usr/bin/env bash
# Sourced by build.sh and test.sh, not run directly.
#
# The macOS 27 SDK declares SwiftUI's @State as a macro, and the Command Line
# Tools ship no SwiftUIMacros plugin to expand it. Every file using @State then
# fails with "plugin for module 'SwiftUIMacros' not found", followed by dozens
# of "'self' is immutable" errors that point at the closures rather than the
# cause. The Tools still carry the 26.x SDKs, where @State is an ordinary
# property wrapper, so fall back to the newest SDK that compiles.
#
# A caller-set SDKROOT always wins, and a host whose default SDK compiles is
# left alone, so this changes nothing where nothing is broken.

lil_ccgw_sdk_compiles_state() {
  # $1: SDK path, or empty for the toolchain's default.
  local probe_dir="$1" sdk="$2"
  SDKROOT="$sdk" swiftc -typecheck \
    -target "$(uname -m)-apple-macosx14.0" \
    "$probe_dir/probe.swift" >/dev/null 2>&1
}

lil_ccgw_select_sdk() {
  [[ -n "${SDKROOT:-}" ]] && return 0

  local probe_dir
  probe_dir="$(mktemp -d)"
  cat > "$probe_dir/probe.swift" <<'EOF'
import SwiftUI

struct Probe: View {
    @State private var count = 0
    var body: some View { Text("\(count)") }
}
EOF

  # An empty SDKROOT is how swiftc spells "use the default".
  if lil_ccgw_sdk_compiles_state "$probe_dir" ""; then
    rm -rf "$probe_dir"
    return 0
  fi

  local sdk_dir sdk
  sdk_dir="$(dirname "$(xcrun --show-sdk-path 2>/dev/null)")"
  while IFS= read -r sdk; do
    [[ -d "$sdk" ]] || continue
    if lil_ccgw_sdk_compiles_state "$probe_dir" "$sdk"; then
      echo "==> default SDK cannot expand @State; building against $(basename "$sdk")" >&2
      export SDKROOT="$sdk"
      rm -rf "$probe_dir"
      return 0
    fi
  done < <(ls -d "$sdk_dir"/MacOSX*.sdk 2>/dev/null | sort -rV)

  rm -rf "$probe_dir"
  echo "warning: no SDK under $sdk_dir can compile SwiftUI @State; set SDKROOT or install Xcode" >&2
}
