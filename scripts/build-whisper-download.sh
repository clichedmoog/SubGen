#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH=$(uname -m)
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then ARCH=arm64; fi
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Myeongseok SEO (N9LYHMUDKA)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"
NOTARIZE="${NOTARIZE:-1}"
TAG="${TOOLS_RELEASE_TAG:-tools-$(date +%Y.%m.%d)}"
BASE_URL="${TOOLS_DOWNLOAD_BASE_URL:-https://github.com/clichedmoog/SubGen/releases/download/${TAG}}"
NAME="whisper-cli-1.8.4-macos14-${ARCH}"
DIST="${ROOT}/dist"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [ "$NOTARIZE" = 1 ]; then
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" --output-format json >"${WORK}/history.json"
fi
bash "${ROOT}/scripts/bundle-whisper.sh" "${WORK}/${NAME}"
cp "${ROOT}/build/release-sources/whisper.cpp-1.8.4/LICENSE" "${WORK}/${NAME}/LICENSE.txt"
codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "${WORK}/${NAME}/whisper-cli"
codesign --verify --strict "${WORK}/${NAME}/whisper-cli"
mkdir -p "$DIST"
ditto -c -k --keepParent "${WORK}/${NAME}" "${WORK}/${NAME}.zip"
if [ "$NOTARIZE" = 1 ]; then
    xcrun notarytool submit "${WORK}/${NAME}.zip" --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait --timeout 30m --output-format json >"${DIST}/${NAME}-notary.json"
    STATUS=$(plutil -extract status raw -o - "${DIST}/${NAME}-notary.json")
    REQUEST_ID=$(plutil -extract id raw -o - "${DIST}/${NAME}-notary.json")
    if [ "$STATUS" != Accepted ]; then
        xcrun notarytool log "$REQUEST_ID" --keychain-profile "$KEYCHAIN_PROFILE" "${DIST}/${NAME}-notary-log.json" || true
        echo "Whisper notarization ${STATUS}" >&2; exit 1
    fi
    # Standalone Mach-O executables cannot be stapled. Their signed hash is
    # notarized before publishing the ZIP; do not mutate/re-sign it afterwards.
fi
mv "${WORK}/${NAME}.zip" "${DIST}/${NAME}.zip"
python3 - "$ROOT" "$ARCH" "$BASE_URL" "$NAME" "${WORK}/${NAME}/whisper-cli" "$NOTARIZE" <<'PY'
import hashlib,json,pathlib,plistlib,sys
root,arch,base,name,binary,notarized=sys.argv[1:]
root=pathlib.Path(root)
path=root/'SubtitleGen/Resources/ToolDownloads.plist'
config=plistlib.loads(path.read_bytes()) if path.exists() else {}
entry={'url':f'{base}/{name}.zip','sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest()}
config.setdefault('whisper-cli',{})[arch]=entry
path.write_bytes(plistlib.dumps(config))
archive=root/'dist'/f'{name}.zip'
archive_hash=hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.zip.sha256').write_text(f'{archive_hash}  {archive.name}\n')
(root/'dist'/f'{name}.json').write_text(json.dumps({'architecture':arch,'minimum_macos':'14.0',
 'download':entry,'archive_sha256':archive_hash,'notarization':'accepted' if notarized=='1' else 'pending',
 'publication':'pending'},indent=2)+'\n')
PY
echo "Prepared ${DIST}/${NAME}.zip and updated ToolDownloads.plist. Publish the ZIP before distributing the app."
