#!/bin/bash
# Build "Recomp Helper.app", optionally sign, notarize and package it as a DMG.
#
#   scripts/build-app.sh                       unsigned local build in dist/
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<profile> scripts/build-app.sh
#
# NOTARY_PROFILE is a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Nothing personal is stored in this repo: identity and profile come from the environment.
#
# The engine copied into the app comes from `git archive HEAD`, so only committed
# files ship: never build output, downloaded editors or game data.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git rev-list --count HEAD)"
DIST=dist
APP="$DIST/Recomp Helper.app"

if ! git diff --quiet HEAD -- recomp.py recomp tools stubs; then
    echo "warning: uncommitted engine changes are NOT included (the app bundles HEAD)" >&2
fi

echo "==> Building RecompHelper $VERSION ($BUILD), universal"
swift build -c release --package-path app --arch arm64 --arch x86_64
BIN="app/.build/apple/Products/Release/RecompHelper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/RecompHelper"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" app/Info.plist > "$APP/Contents/Info.plist"
[ -f app/AppIcon.icns ] && cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
git archive HEAD recomp.py recomp tools stubs LICENSE | tar -x -C "$APP/Contents/Resources/engine"

if [ -z "${SIGN_ID:-}" ]; then
    codesign --force --sign - "$APP"
    echo "==> Ad-hoc signed (set SIGN_ID to sign for distribution): $APP"
    exit 0
fi

echo "==> Signing with hardened runtime"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/RecompHelper"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

DMG="$DIST/RecompHelper-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Recomp Helper" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (this waits for Apple)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi
echo "==> $DMG"
