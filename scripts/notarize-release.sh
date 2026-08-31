#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 path/to/Codex-Quota.zip" >&2
  exit 2
fi

: "${CODEX_METER_NOTARY_PROFILE:?Set CODEX_METER_NOTARY_PROFILE to an xcrun notarytool keychain profile}"

ARCHIVE="$1"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$CODEX_METER_NOTARY_PROFILE" --wait
echo "Notarization accepted. Staple the app before recreating the final archive."
