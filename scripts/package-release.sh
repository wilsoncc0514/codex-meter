#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${CODEX_METER_VERSION:-0.4.2}"
BUILD_NUMBER="${CODEX_METER_BUILD_NUMBER:-16}"
if [ "${CODEX_METER_UNIVERSAL:-0}" = "1" ]; then
  ARCH="universal"
else
  ARCH="$(uname -m)"
fi
OUTPUT_DIR="${CODEX_METER_OUTPUT_DIR:-$ROOT_DIR/dist}"
ARCHIVE="$OUTPUT_DIR/Codex-Quota-v${VERSION}-build${BUILD_NUMBER}-macos-${ARCH}.zip"

mkdir -p "$OUTPUT_DIR"
CODEX_METER_VERSION="$VERSION" CODEX_METER_BUILD_NUMBER="$BUILD_NUMBER" scripts/build-app.sh >/dev/null
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/build/Codex 额度.app" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
unzip -t "$ARCHIVE" >/dev/null

echo "$ARCHIVE"
echo "$ARCHIVE.sha256"
