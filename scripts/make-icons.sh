#!/bin/bash
# Redraws the logo (Sources/Utter/Logo.swift) into Resources/AppIcon.icns and the previews in design/icons.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Utter
TMP=$(mktemp -d)
"$(swift build -c release --show-bin-path)/Utter" --make-icons "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
mkdir -p design/icons && cp "$TMP"/icon-*.png "$TMP"/menubar-*.png design/icons/
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns and design/icons/"
