#!/bin/sh
# Builds NativeShot.app into build/. Usage: scripts/bundle.sh [debug|release]
# Signing: SIGN_IDENTITY if set, else the "NativeShot Local Dev" identity (scripts/dev-cert.sh) if present,
# else ad-hoc. Ad-hoc signatures change every build, so macOS asks for permissions again after rebuilding.
# Extra swift build flags can be passed in SWIFT_FLAGS (scripts/selftest.sh uses it).
# UNIVERSAL=1 builds arm64 and x86_64 and joins them with lipo (used for releases).
set -e
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" $SWIFT_FLAGS
BIN="$(swift build -c "$CONFIG" $SWIFT_FLAGS --show-bin-path)/NativeShot"
APP=build/NativeShot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ -n "$UNIVERSAL" ]; then
  swift build -c "$CONFIG" $SWIFT_FLAGS --triple x86_64-apple-macosx15.0
  X86="$(swift build -c "$CONFIG" $SWIFT_FLAGS --triple x86_64-apple-macosx15.0 --show-bin-path)/NativeShot"
  lipo -create "$BIN" "$X86" -output "$APP/Contents/MacOS/NativeShot"
else
  cp "$BIN" "$APP/Contents/MacOS/NativeShot"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"NativeShot Local Dev"/ {print $2; exit}')
fi
codesign --force --options runtime --timestamp=none --entitlements Resources/NativeShot.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
