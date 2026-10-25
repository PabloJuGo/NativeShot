#!/bin/sh
# End-to-end self-test of the real app (QARunner). Usage: scripts/selftest.sh [outdir]
# Optional: NS_QA_ONLY=CAP-REGION,OCR to run a subset.
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/nsqa/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT/library"
SWIFT_FLAGS="-Xswiftc -DNATIVESHOT_QA" scripts/bundle.sh release >/dev/null
# The fixture needs its own bundle id: ScreenCaptureKit excludes apps by bundle, so it would vanish with ours.
rm -rf build/NSQAFixture.app && cp -R build/NativeShot.app build/NSQAFixture.app
plutil -replace CFBundleIdentifier -string app.nativeshot.qafixture build/NSQAFixture.app/Contents/Info.plist
codesign --force --sign - build/NSQAFixture.app 2>/dev/null
pkill -x NativeShot 2>/dev/null || true
NS_QA_LIBRARY="$OUT/library" NS_QA_ONLY="${NS_QA_ONLY:-}" build/NativeShot.app/Contents/MacOS/NativeShot --qa-selftest "$OUT" ${NS_QA_APP_ARGS:-} >"$OUT/app.log" 2>&1 || true
grep "\[QA\]" "$OUT/app.log" || true
echo "Report: $OUT/report.md"
