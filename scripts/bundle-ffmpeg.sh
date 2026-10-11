#!/bin/bash
set -euo pipefail

DESTINATION="${1:?Usage: bundle-ffmpeg.sh <bundle MacOS directory>}"
ARCH=$(uname -m)
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then ARCH=arm64; fi
SOURCE_DIR="${FFMPEG_STATIC_DIR:-${HOME}/Library/Application Support/SubtitleGenerator/bin}"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$DESTINATION"

usable_static_binary() {
    [ -x "$1" ] || return 1
    /usr/bin/lipo -verify_arch "$ARCH" "$1" >/dev/null 2>&1 || return 1
    "$1" -version >/dev/null 2>&1 || return 1
    # A copied Homebrew executable would require that user's local dylibs.
    /usr/bin/otool -L "$1" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*) ;;
            *) return 1 ;;
        esac
    done
}

for tool in ffmpeg ffprobe; do
    target="${DESTINATION}/${tool}"
    if usable_static_binary "$target"; then
        echo "  ${tool}: existing ${ARCH} static binary verified"
        continue
    fi
    candidate="${SOURCE_DIR}/${tool}"
    if usable_static_binary "$candidate"; then
        cp "$candidate" "$target"
    else
        case "$ARCH:$tool" in
            arm64:ffmpeg) suffix=9arm; checksum=591260c945d0eef150e3bf82b0ef988bd36a9cecc18ff05d6679617159f0a95e ;;
            arm64:ffprobe) suffix=9arm; checksum=e11c17e8200b3ee4c4c186d245e2b4053f01d56957336c1817fca0b997469106 ;;
            x86_64:ffmpeg) suffix=80intel; checksum=df3f1e3facdc1ae0ad0bd898cdfb072fbc9641bf47b11f172844525a05db8d11 ;;
            x86_64:ffprobe) suffix=80intel; checksum=5228e651e2bd67bb55819b27f6138351587b16d2b87446007bf35b7cf930d891 ;;
            *) echo "Unsupported CPU architecture: $ARCH" >&2; exit 1 ;;
        esac
        echo "  Downloading ${tool} for ${ARCH}..."
        mkdir -p "${TEMP_DIR}/${tool}"
        curl -fL --connect-timeout 20 --max-time 300 --retry 2 \
            "https://www.osxexperts.net/${tool}${suffix}.zip" -o "${TEMP_DIR}/${tool}.zip"
        unzip -q "${TEMP_DIR}/${tool}.zip" -d "${TEMP_DIR}/${tool}"
        candidate="${TEMP_DIR}/${tool}/${tool}"
        actual=$(shasum -a 256 "$candidate" | awk '{print $1}')
        [ "$actual" = "$checksum" ] || { echo "${tool}: checksum mismatch" >&2; exit 1; }
        chmod 755 "$candidate"
        usable_static_binary "$candidate" || { echo "${tool}: native/static execution check failed" >&2; exit 1; }
        cp "$candidate" "$target"
    fi
    chmod 755 "$target"
    usable_static_binary "$target"
    echo "  ${tool}: ${ARCH} static binary bundled"
done
