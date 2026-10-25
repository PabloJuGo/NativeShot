#!/bin/sh
# Release artefacts: build/dist/NativeShot-<version>.zip and .dmg plus SHA256SUMS.
# Signing: SIGN_IDENTITY (e.g. "Developer ID Application: …") for distribution; SIGN_IDENTITY=- gives an ad-hoc build,
# which Gatekeeper blocks on first launch until the user picks System Settings › Privacy & Security › Open Anyway.
# Without SIGN_IDENTITY the local or ad-hoc identity from scripts/bundle.sh is used.
# Notarization needs an Apple account: set NOTARY_PROFILE (xcrun notarytool store-credentials) to submit and staple.
set -e
cd "$(dirname "$0")/.."
UNIVERSAL=1 scripts/bundle.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/NativeShot.app/Contents/Info.plist)
DIST=build/dist
rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="$DIST/NativeShot-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/NativeShot.app "$ZIP"
STAGE=$(mktemp -d)
cp -R build/NativeShot.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/NativeShot-$VERSION.dmg"
hdiutil create -quiet -volname "NativeShot $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
(cd "$DIST" && shasum -a 256 *.zip *.dmg > SHA256SUMS)
cat "$DIST/SHA256SUMS"
