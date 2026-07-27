#!/usr/bin/env bash
#
# Builds ClaudeUsageWidget.app from the SwiftPM executable.
#
# This project intentionally has no .xcodeproj — it builds with plain
# `swift build`, which works with the Command Line Tools alone and needs no
# full Xcode install. The only thing SwiftPM will not do for us is wrap the
# binary in a bundle with an Info.plist, so we do that here.
#
#   ./Scripts/build-app.sh              # release build into dist/
#   ./Scripts/build-app.sh --debug      # debug build
#   ./Scripts/build-app.sh --run        # build, then launch it
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
RUN=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --release) CONFIG="release" ;;
    --run) RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="ClaudeUsageWidget"
APP_DIR="dist/${APP_NAME}.app"

# --- toolchain selection ------------------------------------------------
#
# SwiftUI's @State (and friends) are macros now, expanded at compile time by
# libSwiftUIMacros.dylib. That plugin ships inside Xcode, *not* with the
# standalone Command Line Tools — so on a CLT-only machine the build fails with
# "plugin for module 'SwiftUIMacros' not found".
#
# Rather than demanding a full `xcode-select` switch (which needs sudo), we
# look for any Xcode that has the plugin and borrow it for this build only, via
# DEVELOPER_DIR. Set DEVELOPER_DIR yourself to override.
find_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    echo "$DEVELOPER_DIR"; return
  fi
  local current
  current="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$current" && -f "$current/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
    echo "$current"; return
  fi
  local candidate
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
    [[ -d "$candidate" ]] || continue
    if [[ -f "$candidate/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
      echo "$candidate/Contents/Developer"; return
    fi
  done
  echo ""
}

DEV_DIR="$(find_developer_dir)"
if [[ -z "$DEV_DIR" ]]; then
  cat >&2 <<'EOF'
error: could not find a toolchain with libSwiftUIMacros.dylib.

  SwiftUI property wrappers are macros and need the plugin that ships with
  Xcode. The standalone Command Line Tools do not include it.

  Install Xcode (any recent version is fine), or point DEVELOPER_DIR at one:

      DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build-app.sh
EOF
  exit 1
fi
export DEVELOPER_DIR="$DEV_DIR"
echo "==> toolchain: $DEVELOPER_DIR"

echo "==> swift build -c ${CONFIG}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "$BIN" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# --- signing --------------------------------------------------------------
#
# This matters more than it looks. Keychain access grants ("Always Allow") are
# bound to the application's *code identity*. An ad-hoc signature has no stable
# identity — its hash changes with every rebuild — so each new build looks like
# a brand new application and macOS asks for permission all over again. That is
# the "I keep clicking Always Allow and it never sticks" symptom.
#
# Signing with a real identity (any Apple Development certificate will do; this
# is never distributed) gives a stable designated requirement, so the grant
# survives rebuilds. Fall back to ad-hoc if no certificate exists.
#
# Set CODESIGN_IDENTITY to pick a specific one.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(.*\)"/\1/p' | head -1
  )"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> codesign: ${CODESIGN_IDENTITY}"
  codesign --force --sign "$CODESIGN_IDENTITY" \
    --identifier "us.lucasleite.ClaudeUsageWidget" \
    --options runtime \
    "$APP_DIR" 2>/dev/null \
    || codesign --force --sign "$CODESIGN_IDENTITY" \
      --identifier "us.lucasleite.ClaudeUsageWidget" \
      "$APP_DIR" >/dev/null 2>&1 \
    || echo "   (signing failed; falling back to ad-hoc)"
else
  echo "==> codesign (ad-hoc — expect repeated Keychain prompts after rebuilds)"
  codesign --force --sign - \
    --identifier "us.lucasleite.ClaudeUsageWidget" \
    "$APP_DIR" >/dev/null 2>&1 || echo "   (ad-hoc signing skipped)"
fi

echo "==> built ${APP_DIR}"

if [[ "$RUN" == "1" ]]; then
  echo "==> launching"
  open "$APP_DIR"
fi
