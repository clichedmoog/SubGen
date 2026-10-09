#!/bin/bash
set -euo pipefail

DESTINATION="${1:?Usage: bundle-whisper.sh <bundle MacOS directory>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH=$(uname -m)
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then ARCH=arm64; fi
VERSION=1.8.4
SHA256=b26f30e52c095ccb75da40b168437736605eb280de57381887bf9e2b65f31e66
CACHE="${ROOT}/build/release-sources"
ARCHIVE="${CACHE}/whisper.cpp-v${VERSION}.tar.gz"
SOURCE="${CACHE}/whisper.cpp-${VERSION}"
OUTPUT="${ROOT}/build/whisper-${VERSION}-${ARCH}-macos14"
mkdir -p "$CACHE" "$DESTINATION"

if [ ! -f "$ARCHIVE" ]; then
    curl -fL --connect-timeout 20 --max-time 300 --retry 2 \
        "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${VERSION}.tar.gz" -o "${ARCHIVE}.partial"
    mv "${ARCHIVE}.partial" "$ARCHIVE"
fi
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL" = "$SHA256" ] || { echo 'Whisper source checksum mismatch' >&2; exit 1; }
# Always extract the verified source; never reuse a locally edited source tree.
rm -rf "$SOURCE"
tar -xzf "$ARCHIVE" -C "$CACHE"

# Static libraries avoid build-machine dylib paths. Embedded Metal kernels travel
# with the executable; GGML_NATIVE=OFF supports earlier Apple Silicon generations.
cmake -S "$SOURCE" -B "$OUTPUT" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$OUTPUT" --config Release --target whisper-cli --parallel "$(sysctl -n hw.ncpu)"
cp "${OUTPUT}/bin/whisper-cli" "${DESTINATION}/whisper-cli"
chmod 755 "${DESTINATION}/whisper-cli"
/usr/bin/lipo -verify_arch "$ARCH" "${DESTINATION}/whisper-cli"
"${DESTINATION}/whisper-cli" --help >/dev/null 2>&1

LICENSE_DIR="${DESTINATION}/../Resources/Licenses"
mkdir -p "$LICENSE_DIR"
cp "${SOURCE}/LICENSE" "${LICENSE_DIR}/whisper.cpp-MIT.txt"
echo "  whisper-cli ${VERSION}: ${ARCH}, macOS 14+, static libraries, embedded Metal"
