#!/usr/bin/env bash
set -euo pipefail

# Release asset digest reported by the XcodeGen 2.46.0 GitHub release API and verified by downloading
# xcodegen.zip on 2026-10-11. Keep this one installer shared by every CI workflow that generates the app.
XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

: "${RUNNER_TEMP:?GitHub Actions must provide RUNNER_TEMP}"
archive="$RUNNER_TEMP/xcodegen.zip"
distribution="$RUNNER_TEMP/xcodegen-dist"

mkdir -p "$distribution"
curl -fsSL --retry 3 \
  -o "$archive" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
echo "$XCODEGEN_SHA256  $archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$distribution"
