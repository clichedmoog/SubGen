#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME=SubGen
VERSION="${VERSION:-$(date +%Y.%m.%d)}"
ARCH=$(uname -m)
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then ARCH=arm64; fi
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Myeongseok SEO (N9LYHMUDKA)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"
NOTARIZE="${NOTARIZE:-1}"
NOTARIZATION_BACKEND="${NOTARIZATION_BACKEND:-auto}"
TEAM_ID="${TEAM_ID:-N9LYHMUDKA}"
APP_BUNDLE="${ROOT}/build/${APP_NAME}.app"
DIST="${ROOT}/dist"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/subtitlegen-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
case "$NOTARIZE" in
    1) SUFFIX='' ;;
    0) SUFFIX='-signed' ;;
    *) echo 'NOTARIZE must be 0 or 1' >&2; exit 1 ;;
esac
STEM="${APP_NAME}-${VERSION}-${ARCH}${SUFFIX}"
DMG="${DIST}/${STEM}.dmg"
mkdir -p "$DIST" "${ROOT}/build"

# An App Store Connect API key (ASC_KEY_ID + ASC_ISSUER_ID, key file in ~/.appstoreconnect/private_keys)
# can notarize without a stored keychain profile or an Xcode account login.
ASC_KEY_PATH="${ASC_KEY_PATH:-${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8}"
NOTARY_AUTH=(--keychain-profile "$KEYCHAIN_PROFILE")
use_api_key() {
    [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -f "$ASC_KEY_PATH" ] || return 1
    NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
}

if [ "$NOTARIZE" = 1 ]; then
    case "$NOTARIZATION_BACKEND" in
        auto)
            if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" --output-format json >"${WORK}/history.json" 2>"${WORK}/profile.log"; then
                NOTARIZATION_BACKEND=notarytool
            elif use_api_key && xcrun notarytool history "${NOTARY_AUTH[@]}" --output-format json >"${WORK}/history.json" 2>"${WORK}/profile.log"; then
                NOTARIZATION_BACKEND=notarytool
                echo 'Using the App Store Connect API key for notarization.'
            else
                NOTARIZATION_BACKEND=xcode
                echo 'Using the developer account registered in Xcode for notarization.'
            fi ;;
        notarytool)
            use_api_key || true
            xcrun notarytool history "${NOTARY_AUTH[@]}" --output-format json >"${WORK}/history.json" ;;
        xcode) ;;
        *) echo 'NOTARIZATION_BACKEND must be auto, notarytool or xcode' >&2; exit 1 ;;
    esac
    # Preserve Xcode archives/logs so a processing submission can be resumed.
    XCODE_WORK="${ROOT}/build/notarization/${STEM}-$(date +%Y%m%d-%H%M%S)"
fi

if [ "${1:-}" = '--package-only' ]; then
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")
    [ "$BUNDLE_VERSION" = "$VERSION" ] || { echo 'Bundle version differs from VERSION' >&2; exit 1; }
elif [ $# -eq 0 ]; then
    echo "[1/5] Building ${APP_NAME} ${VERSION} (${ARCH})..."
    cd "$ROOT"
    swift build -c release --arch "$ARCH" --product "$APP_NAME"
    BIN_DIR=$(swift build -c release --arch "$ARCH" --show-bin-path)
    NEW_APP="${WORK}/${APP_NAME}.app"
    mkdir -p "${NEW_APP}/Contents/MacOS" "${NEW_APP}/Contents/Resources"
    cp "${BIN_DIR}/${APP_NAME}" "${NEW_APP}/Contents/MacOS/"
    cp "${ROOT}/SubtitleGen/Resources/Info.plist" "${NEW_APP}/Contents/"
    cp "${ROOT}/SubtitleGen/Resources/AppIcon.icns" "${NEW_APP}/Contents/Resources/"
    cp "${ROOT}/SubtitleGen/Resources/ToolDownloads.plist" "${NEW_APP}/Contents/Resources/"
    # SwiftPM does not bundle the string catalog; compile it into per-language .lproj folders.
    xcrun xcstringstool compile "${ROOT}/SubtitleGen/Resources/Localizable.xcstrings" \
        --output-directory "${NEW_APP}/Contents/Resources"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${NEW_APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${NEW_APP}/Contents/Info.plist"
    bash "${ROOT}/scripts/compile-app-icon.sh" "$NEW_APP"

    echo '[2/5] Preparing first-run tool downloads (tools are not bundled)...'
    mkdir -p "${NEW_APP}/Contents/Resources/Licenses"
    cp -R "${ROOT}/SubtitleGen/Resources/Licenses/." "${NEW_APP}/Contents/Resources/Licenses/"

    # SwiftPM may add a toolchain fallback rpath. The app links the system Swift
    # runtime and must not refer to this build machine's Xcode installation.
    python3 - "${NEW_APP}/Contents/MacOS/${APP_NAME}" <<'PY'
import re, subprocess, sys
binary = sys.argv[1]
commands = subprocess.check_output(['otool', '-l', binary], text=True)
for path in re.findall(r'\bpath (.+?) \(offset', commands):
    if not path.startswith(('@', '/usr/lib/', '/System/Library/')):
        subprocess.run(['install_name_tool', '-delete_rpath', path, binary], check=True)
PY

    echo '[3/5] Signing with Developer ID...'
    /usr/bin/codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" \
        --entitlements "${ROOT}/SubtitleGen/Resources/SubtitleGenerator.entitlements" "$NEW_APP"
    /usr/bin/codesign --verify --deep --strict "$NEW_APP"
    # Replace the old build only after the fresh bundle has been verified.
    rm -rf "$APP_BUNDLE"
    ditto "$NEW_APP" "$APP_BUNDLE"
else
    echo 'Usage: build-dmg.sh [--package-only]' >&2; exit 1
fi

# Verify actual binaries, deployment targets, and independence from Homebrew.
python3 "${ROOT}/scripts/verify-release.py" "$APP_BUNDLE" "$ARCH"

notarize() {
    local artifact="$1" label="$2" result="${DIST}/${STEM}-$2-notary.json"
    xcrun notarytool submit "$artifact" "${NOTARY_AUTH[@]}" \
        --wait --timeout 30m --output-format json >"$result"
    local status request_id
    status=$(plutil -extract status raw -o - "$result")
    request_id=$(plutil -extract id raw -o - "$result")
    if [ "$status" != Accepted ]; then
        xcrun notarytool log "$request_id" "${NOTARY_AUTH[@]}" \
            "${DIST}/${STEM}-${label}-notary-log.json" || true
        echo "Notarization ${status}; see ${result}" >&2; exit 1
    fi
}

if [ "$NOTARIZE" = 1 ]; then
    echo '[4/5] Notarizing and stapling app...'
    if xcrun stapler validate "$APP_BUNDLE" >"${WORK}/app-ticket.log" 2>&1 && spctl --assess --type execute "$APP_BUNDLE"; then
        echo 'Existing app ticket verified; reusing the notarized app.'
    elif [ "$NOTARIZATION_BACKEND" = xcode ]; then
        python3 "${ROOT}/scripts/notarize-xcode-archive.py" "$APP_BUNDLE" \
            --work-dir "${XCODE_WORK}/app" --team-id "$TEAM_ID" --signing-identity "$DEVELOPER_ID" --wait-seconds 1800
        mv "$APP_BUNDLE" "${WORK}/previous-${APP_NAME}.app"
        ditto "${XCODE_WORK}/app/notarized/${APP_NAME}.app" "$APP_BUNDLE"
        cp "${XCODE_WORK}/app/receipt.json" "${DIST}/${STEM}-app-notary.json"
    else
        ditto -c -k --keepParent "$APP_BUNDLE" "${WORK}/${APP_NAME}.zip"
        notarize "${WORK}/${APP_NAME}.zip" app
        xcrun stapler staple "$APP_BUNDLE"
    fi
    xcrun stapler validate "$APP_BUNDLE"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
else
    echo '[4/5] Signed-only package: Apple notarization is pending.'
fi

echo '[5/5] Creating and verifying DMG...'
mkdir -p "${WORK}/staging"
ditto "$APP_BUNDLE" "${WORK}/staging/${APP_NAME}.app"
ln -s /Applications "${WORK}/staging/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "${WORK}/staging" -format UDZO "${WORK}/${STEM}.dmg"
codesign --force --timestamp --sign "$DEVELOPER_ID" "${WORK}/${STEM}.dmg"
mv "${WORK}/${STEM}.dmg" "$DMG"
if [ "$NOTARIZE" = 1 ]; then
    if [ "$NOTARIZATION_BACKEND" = xcode ]; then
        python3 "${ROOT}/scripts/notarize-xcode-archive.py" "$APP_BUNDLE" \
            --work-dir "${XCODE_WORK}/dmg" --team-id "$TEAM_ID" --signing-identity "$DEVELOPER_ID" \
            --entitlements "${ROOT}/SubtitleGen/Resources/SubtitleGenerator.entitlements" \
            --payload "$DMG" --wait-seconds 1800
        cp "${XCODE_WORK}/dmg/receipt.json" "${DIST}/${STEM}-dmg-notary.json"
    else
        notarize "$DMG" dmg
        xcrun stapler staple "$DMG"
    fi
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"
(
    cd "$DIST"
    shasum -a 256 "${STEM}.dmg" >"${STEM}.dmg.sha256"
)
python3 "${ROOT}/scripts/verify-release.py" "$APP_BUNDLE" "$ARCH" \
    --dmg "$DMG" --notarized "$NOTARIZE" >"${DIST}/${STEM}.json"
echo "DMG: ${DMG}"
echo "SHA256: $(cat "${DMG}.sha256")"
echo "Size: $(du -h "$DMG" | cut -f1)"
