#!/bin/bash
# Regenerates SubtitleGen/Resources/AppIcon.icns and the 1024px preview from the
# SVG masters in SubtitleGen/Resources/IconSource/.
#   AppIcon-16.svg -> 16px rendition (pixel-grid tuned)
#   AppIcon-32.svg -> 32px rendition (pixel-grid tuned)
#   AppIcon.svg    -> 64px and larger
# Requires rsvg-convert (brew install librsvg) and iconutil (Xcode CLT).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${ROOT}/SubtitleGen/Resources/IconSource"
FULL="${SOURCE}/AppIcon.svg"
SMALL_16="${SOURCE}/AppIcon-16.svg"
SMALL_32="${SOURCE}/AppIcon-32.svg"
PREVIEW="${SOURCE}/AppIcon-1024.png"
ICNS="${ROOT}/SubtitleGen/Resources/AppIcon.icns"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil not found (xcode-select --install)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "$ICONSET"

render() {
    rsvg-convert --width "$2" --height "$2" --format png "$1" --output "${ICONSET}/$3"
}

render "$SMALL_16" 16 icon_16x16.png
render "$SMALL_32" 32 icon_16x16@2x.png
# Omit ic05 (32pt @1x): actual macOS 27.2 rendering adds a grey enclosing tile
# when it is present. ic11 (16pt @2x) supplies the same physical 32px size.
render "$FULL" 64 icon_32x32@2x.png
render "$FULL" 128 icon_128x128.png
render "$FULL" 256 icon_128x128@2x.png
render "$FULL" 256 icon_256x256.png
render "$FULL" 512 icon_256x256@2x.png
render "$FULL" 512 icon_512x512.png
render "$FULL" 1024 icon_512x512@2x.png

iconutil --convert icns "$ICONSET" --output "${WORK}/AppIcon.icns"
iconutil --convert iconset "${WORK}/AppIcon.icns" --output "${WORK}/check.iconset"
python3 - "$ICONSET" "${WORK}/check.iconset" <<'PY'
from pathlib import Path
import sys
expected, decoded = map(Path, sys.argv[1:])
names = {p.name for p in expected.iterdir()}
if len(names) != 9 or names != {p.name for p in decoded.iterdir()}:
    raise SystemExit('ICNS round-trip is missing representations')
PY

cp "${ICONSET}/icon_512x512@2x.png" "$PREVIEW"
cp "${WORK}/AppIcon.icns" "${ICNS}.tmp"
mv "${ICNS}.tmp" "$ICNS"
echo "Wrote ${ICNS}"
echo "Wrote ${PREVIEW}"
