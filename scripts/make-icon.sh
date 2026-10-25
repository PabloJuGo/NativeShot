#!/bin/sh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift (original artwork drawn in code).
set -e
cd "$(dirname "$0")/.."
rm -rf build/AppIcon.iconset
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
