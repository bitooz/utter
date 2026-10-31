#!/bin/bash
# Builds Utter.app (and the TestPad.app used by the self-test) into ./build.
# Signs with your Apple Development identity when there is one, so macOS keeps the
# Accessibility/Microphone grants across rebuilds; otherwise signs ad hoc.
#
#   BUILD   the bundle's build number (CFBundleVersion), default 1; the release workflow passes its own.
#           The version (CFBundleShortVersionString) is the one in ./VERSION.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD="${BUILD:-1}"
case "$BUILD" in '' | *[!0-9]*) echo "BUILD is a whole number, not '$BUILD'" >&2; exit 1 ;; esac

swift build -c release
BIN=$(swift build -c release --show-bin-path)

IDENTITY="${UTTER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"

bundle() { # name bundle-id exec extra-plist-keys [icon.icns]
  local app="build/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$BIN/$3" "$app/Contents/MacOS/$1"
  if [ -n "${5:-}" ]; then mkdir -p "$app/Contents/Resources" && cp "$5" "$app/Contents/Resources/AppIcon.icns"; fi
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleDisplayName</key><string>$1</string>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  $4
</dict></plist>
PLIST
  codesign --force --sign "$IDENTITY" "$app" >/dev/null
  echo "built $app $VERSION ($BUILD) (signed: $IDENTITY)"
}

bundle Utter dev.utter.Utter Utter '<key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key><string>Utter listens only while you hold (or have pressed) your dictation hotkey, and turns your speech into text.</string>' Resources/AppIcon.icns
bundle TestPad dev.utter.TestPad TestPad ''
