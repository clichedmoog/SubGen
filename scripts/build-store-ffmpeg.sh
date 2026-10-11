#!/bin/bash
# Build unmodified FFmpeg for the store app, without external codec libraries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${SUBTITLEGEN_FFMPEG_SOURCE_ROOT:-${ROOT}/build/ffmpeg-store-source}"
DEST="${SUBTITLEGEN_FFMPEG_DEST:-${ROOT}/build/store-tools}"
VERSION=9.0
SHA256=7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52
ARCHIVE="${SOURCE_ROOT}/ffmpeg-${VERSION}.tar.xz"
mkdir -p "$SOURCE_ROOT" "$DEST"
if [ ! -f "$ARCHIVE" ]; then
    curl -fL --connect-timeout 20 --max-time 300 --retry 2 \
        "https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz" -o "${ARCHIVE}.partial"
    mv "${ARCHIVE}.partial" "$ARCHIVE"
fi
[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$SHA256" ] || { echo 'FFmpeg source checksum mismatch' >&2; exit 1; }
SOURCE="${SOURCE_ROOT}/ffmpeg-${VERSION}"
# Restore every upstream file from the verified archive before compiling.
tar -xf "$ARCHIVE" -C "$SOURCE_ROOT"
BUILD="${SOURCE_ROOT}/build-arm64"
mkdir -p "$BUILD"
cd "$BUILD"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
"${SOURCE}/configure" --arch=aarch64 --cpu=generic --target-os=darwin \
    --cc="$(xcrun --find clang)" --sysroot="$MAC_SDK" \
    --host-cflags="-isysroot $MAC_SDK" --host-ldflags="-isysroot $MAC_SDK" \
    --disable-autodetect --disable-gpl \
    --disable-version3 --disable-nonfree --disable-network --disable-doc \
    --disable-ffplay --disable-indevs --disable-outdevs --enable-indev=lavfi \
    --enable-static --disable-shared \
    --enable-audiotoolbox --enable-videotoolbox --enable-zlib \
    --extra-cflags=-mmacosx-version-min=14.0 \
    --extra-ldflags=-mmacosx-version-min=14.0
make -j "${SUBTITLEGEN_FFMPEG_JOBS:-8}" ffmpeg ffprobe
for tool in ffmpeg ffprobe; do
    cp "$tool" "${DEST}/${tool}.partial"
    chmod 755 "${DEST}/${tool}.partial"
    lipo -verify_arch arm64 "${DEST}/${tool}.partial"
    "${DEST}/${tool}.partial" -version
    mv "${DEST}/${tool}.partial" "${DEST}/${tool}"
done
mkdir -p "${DEST}/ffmpeg-source"
cp "$ARCHIVE" "${DEST}/ffmpeg-source/"
cp "${ROOT}/scripts/build-store-ffmpeg.sh" "${DEST}/ffmpeg-source/"
cp "${ROOT}/Store/toolchain/ffmpeg.json" "${DEST}/ffmpeg-source/"
cp "${SOURCE}/COPYING.LGPLv2.1" "${DEST}/ffmpeg-source/"
cp "${SOURCE}/LICENSE.md" "${DEST}/ffmpeg-source/"
python3 - "$DEST" <<'PY'
import hashlib, json, pathlib, sys
dest = pathlib.Path(sys.argv[1])
inventory = json.loads((dest/'ffmpeg-source/ffmpeg.json').read_text())
inventory['binaries'] = {name: hashlib.sha256((dest/name).read_bytes()).hexdigest() for name in ('ffmpeg', 'ffprobe')}
inventory['recipeSHA256'] = hashlib.sha256((dest/'ffmpeg-source/build-store-ffmpeg.sh').read_bytes()).hexdigest()
(dest/'ffmpeg-build.json').write_text(json.dumps(inventory, indent=2)+'\n')
PY
