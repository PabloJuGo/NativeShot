#!/bin/sh
# Runs the test suite. With Command Line Tools only (no Xcode), Swift Testing lives outside the
# default search paths (and its Foundation overlay ships without a module), so point the
# compiler and linker at it and skip cross-import overlays.
set -e
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if ! xcode-select -p | grep -q Xcode.app && [ -d "$CLT/Testing.framework" ]; then
  exec swift test -Xswiftc -F"$CLT" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F"$CLT" -Xlinker -rpath -Xlinker "$CLT" "$@"
fi
exec swift test "$@"
