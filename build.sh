#!/bin/bash
# Release build → .app bundle → codesign → (optionally) install to /Applications and relaunch.
#
# Signing identity: $POKEY_SIGN_IDENTITY, else the first line of .signing-identity (git-ignored), else ad-hoc ("-").
# Sign every build with the same real certificate and macOS keeps the Accessibility grant across rebuilds;
# with ad-hoc signing you'll have to re-grant it after each build.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${POKEY_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing-identity ]]; then IDENTITY="$(head -n1 .signing-identity)"; fi
IDENTITY="${IDENTITY:--}"
APP=build/Pokey.app

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Pokey "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Pokey 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Pokey.app
  cp -R "$APP" /Applications/
  open /Applications/Pokey.app
fi
