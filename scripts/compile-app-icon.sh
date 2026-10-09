#!/bin/bash
# Compile the native Liquid Glass icon and attach it to a prepared app bundle.
# Requires Xcode 27 or newer; the separately generated ICNS is preserved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 1 ]; then
    echo 'Usage: compile-app-icon.sh /path/to/SubGen.app' >&2
    exit 1
fi
APP_BUNDLE="$1"
INFO="${APP_BUNDLE}/Contents/Info.plist"
SOURCE="${ROOT}/SubtitleGen/Resources/IconSource/AppIcon.icon"
[ -f "$INFO" ] || { echo "App bundle has no Info.plist: ${APP_BUNDLE}" >&2; exit 1; }
[ -f "${SOURCE}/icon.json" ] || { echo "Icon Composer source missing: ${SOURCE}" >&2; exit 1; }
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun actool "$SOURCE" --compile "$WORK" --platform macosx \
    --minimum-deployment-target "$MINIMUM" --app-icon AppIcon \
    --output-partial-info-plist "${WORK}/partial-info.plist" \
    --output-format human-readable-text --warnings --errors

# Validate the compiled name and layers before touching the app bundle.
python3 - "$WORK" "$APP_BUNDLE" <<'PY'
import json, pathlib, plistlib, shutil, subprocess, sys
work, app = map(pathlib.Path, sys.argv[1:])
partial = plistlib.loads((work / 'partial-info.plist').read_bytes())
if partial.get('CFBundleIconName') != 'AppIcon' or partial.get('CFBundleIconFile') != 'AppIcon':
    raise SystemExit('Unexpected compiled app icon metadata')
assets = json.loads(subprocess.check_output(['/usr/bin/assetutil', '--info', str(work / 'Assets.car')]))
appearances = {item.get('Appearance') for item in assets
               if item.get('AssetType') == 'IconImageStack' and item.get('Name') == 'AppIcon'}
if not {'NSAppearanceNameAqua', 'NSAppearanceNameDarkAqua', 'ISAppearanceTintable'} <= appearances:
    raise SystemExit('Native icon is missing appearance layers')
resources = app / 'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(work / 'Assets.car', resources / 'Assets.car')
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info.update(partial)
info_path.write_bytes(plistlib.dumps(info))
print('Attached native Liquid Glass icon (light, dark, tinted) and retained ICNS fallback')
PY
