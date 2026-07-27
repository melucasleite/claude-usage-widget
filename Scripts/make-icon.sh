#!/usr/bin/env bash
#
# Turn one square PNG into Resources/AppIcon.icns.
#
#   ./Scripts/make-icon.sh ~/Downloads/whatever-you-generated.png
#
# Everything else is already wired: Scripts/build-app.sh copies the .icns into
# the bundle, and project.yml references it for the Xcode target. Rebuild and
# the icon is there.
#
# Needs nothing installed — sips and iconutil ship with macOS.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  echo "usage: ./Scripts/make-icon.sh <source.png>" >&2
  echo "       a square PNG, ideally 1024x1024" >&2
  exit 2
fi
[[ -f "$SRC" ]] || { echo "error: no such file: $SRC" >&2; exit 1; }

W=$(sips -g pixelWidth "$SRC" 2>/dev/null | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$SRC" 2>/dev/null | awk '/pixelHeight/{print $2}')
[[ -n "$W" && -n "$H" ]] || { echo "error: not a readable image: $SRC" >&2; exit 1; }

echo "==> source: ${W}x${H}  $SRC"

if [[ "$W" != "$H" ]]; then
  echo "    not square — padding to $(( W > H ? W : H ))px with transparency"
fi
if (( W < 1024 || H < 1024 )); then
  echo "    warning: smaller than 1024px; the largest icon sizes will be upscaled"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SQUARE="$WORK/square.png"

# Pad (never crop) to a square canvas. `sips -z` alone would distort a
# non-square source, and cropping would quietly eat someone's artwork.
SIDE=$(( W > H ? W : H ))
sips -s format png "$SRC" --out "$SQUARE" >/dev/null 2>&1
if [[ "$W" != "$H" ]]; then
  sips -p "$SIDE" "$SIDE" "$SQUARE" --out "$SQUARE" >/dev/null 2>&1
fi

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# The exact filenames iconutil expects. Both scale factors for every size, so
# the icon stays crisp everywhere from the menu bar to Get Info.
emit() { # size, filename
  sips -z "$1" "$1" "$SQUARE" --out "$ICONSET/$2" >/dev/null 2>&1
}
emit 16    icon_16x16.png
emit 32    icon_16x16@2x.png
emit 32    icon_32x32.png
emit 64    icon_32x32@2x.png
emit 128   icon_128x128.png
emit 256   icon_128x128@2x.png
emit 256   icon_256x256.png
emit 512   icon_256x256@2x.png
emit 512   icon_512x512.png
emit 1024  icon_512x512@2x.png

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

echo "==> wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
echo
echo "Next:"
echo "  ./Scripts/build-app.sh --run          # SwiftPM build"
echo "  xcodegen generate                     # refresh the Xcode project"
