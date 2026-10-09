#!/bin/bash
set -euo pipefail
ROOT="${SRCROOT:?Xcode build environment required}"
DEST="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
mkdir -p "$DEST"
for tool in ffmpeg ffprobe whisper-cli; do
    SOURCE="${ROOT}/build/store-tools/${tool}"
    [ -f "$SOURCE" ] || { echo 'Run python3 scripts/prepare-store-tools.py before building.' >&2; exit 1; }
    cp "$SOURCE" "${DEST}/${tool}"
    chmod 755 "${DEST}/${tool}"
    if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
        IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
        [ -n "$IDENTITY" ] || IDENTITY=-
        codesign --force --options runtime --sign "$IDENTITY" \
            --identifier "${PRODUCT_BUNDLE_IDENTIFIER}.${tool}" \
            --entitlements "${ROOT}/Store/Resources/Tool.entitlements" "${DEST}/${tool}"
        codesign --verify --strict "${DEST}/${tool}"
    fi
done
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "${RESOURCES}/FFmpegSource" "${RESOURCES}/Licenses"
cp -R "${ROOT}/build/store-tools/ffmpeg-source/." "${RESOURCES}/FFmpegSource/"
cp "${ROOT}/Store/Resources/THIRD-PARTY.txt" "${RESOURCES}/Licenses/THIRD-PARTY.txt"
cp "${ROOT}/build/store-tools/ffmpeg-source/COPYING.LGPLv2.1" "${RESOURCES}/Licenses/FFmpeg-LGPLv2.1.txt"
rm -f "${RESOURCES}/Licenses/FFmpeg-GPLv2.txt" "${RESOURCES}/Licenses/FFmpeg-GPLv3.txt"
