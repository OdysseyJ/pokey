#!/bin/bash
# 배포용 Pokey.app: 유니버설 빌드(arm64 + x86_64) → Developer ID 서명(hardened runtime, timestamp) → 공증 → staple → zip.
#
#   scripts/release.sh            # build/Pokey-<version>.zip 과 sha256 을 찍는다
#
# 필요한 것: .signing-identity(또는 POKEY_SIGN_IDENTITY)에 Developer ID Application 인증서 이름,
# 그리고 공증 인증 정보 — 한 번만:
#   xcrun notarytool store-credentials pokey --apple-id <Apple ID> --team-id <TEAMID>
# (프로필 이름을 바꾸려면 POKEY_NOTARY_PROFILE)
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${POKEY_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing-identity ]]; then IDENTITY="$(head -n1 .signing-identity)"; fi
[[ "$IDENTITY" == Developer\ ID\ Application:* ]] || { echo "Developer ID Application 인증서가 필요해요 (.signing-identity)"; exit 1; }
PROFILE="${POKEY_NOTARY_PROFILE:-pokey}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
APP=build/release/Pokey.app
ZIP="build/Pokey-$VERSION.zip"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Pokey"
rm -rf build/release && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 공증은 zip 으로 보내고, 통과하면 앱에 표를 붙여(staple) 다시 묶는다.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

echo
echo "version: $VERSION"
echo "zip:     $ZIP"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
