#!/usr/bin/env bash
#
# Build a drag-to-Applications disk image.
#
#   ./Scripts/make-dmg.sh 1.0.1 [--app dist/ClaudeUsageWidget.app]
#
# Produces dist/ClaudeUsageWidget-<version>.dmg containing the app beside a
# symlink to /Applications, so opening it gives the familiar drag-across
# window.
#
# Uses only hdiutil and osascript, both of which ship with macOS.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudeUsageWidget"
VOL_NAME="Claude Usage Widget"

VERSION="${1:-}"
shift || true
APP="dist/${APP_NAME}.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "usage: ./Scripts/make-dmg.sh <version> [--app PATH]" >&2; exit 2; }
[[ -d "$APP" ]] || { echo "error: no app bundle at $APP" >&2; exit 1; }

DMG="dist/${APP_NAME}-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; hdiutil detach "/Volumes/${VOL_NAME}" -quiet 2>/dev/null || true' EXIT

echo "==> staging"
# ditto rather than cp -R: it preserves the bundle's extended attributes and
# symlinks. A mangled bundle fails signature verification on the far side,
# which is a miserable thing to debug after someone has downloaded it.
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

echo "==> creating image"
rm -f "$DMG"
RW_DMG="$(mktemp -d)/rw.dmg"

# Build read/write first so Finder can be told how to lay the window out, then
# convert to a compressed read-only image for distribution.
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" \
  -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

MOUNT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)"
echo "    mounted at $MOUNT"

# Window layout. This drives Finder over AppleScript, which needs Automation
# permission the first time and is not available at all on a headless machine —
# so a failure here is downgraded to a warning. The image still works; it just
# opens with default icon positions.
if ! osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 800, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "${APP_NAME}.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT
then
  echo "    (could not set window layout — Finder automation unavailable;"
  echo "     the image is still valid, just with default icon positions)"
fi

sync
hdiutil detach "$MOUNT" -quiet || true

echo "==> compressing"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$(dirname "$RW_DMG")"

echo "==> $(du -h "$DMG" | cut -f1)  $DMG"
