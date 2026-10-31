#!/bin/bash
# Builds website/public/Utter.dmg, the file behind the site's Download button (/download redirects to it).
#
# The app is the one scripts/build.sh builds, with its binary rebuilt universal (Apple silicon and Intel) from the
# same sources, signed with the Developer ID identity and the hardened runtime, notarized and stapled. The disk image
# (the app beside an Applications shortcut) is then signed, notarized and stapled too, so both open without
# Gatekeeper's prompt. The app's code and scripts/build.sh are left as they are.
#
#   SIGN_IDENTITY    default: the keychain's "Developer ID Application" identity (Filo's)
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#                    an App Store Connect API key; read from website/.release.env when it's there (not committed)
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ -f website/.release.env ]; then . website/.release.env; fi
: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH (or website/.release.env)}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?NOTARY_ISSUER}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then echo "No Developer ID Application identity in the keychain" >&2; exit 1; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Submits $1 for notarization, waits, and fails with Apple's log unless it's accepted.
notarize() {
  local out id status
  out=$(xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait --output-format json)
  id=$(printf '%s' "$out" | plutil -extract id raw -o - -)
  status=$(printf '%s' "$out" | plutil -extract status raw -o - -)
  echo "Notarization of $(basename "$1"): $status ($id)"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2
    exit 1
  fi
}

# Staples the ticket to $1 and checks it, a few tries apart (stapling goes over the network to Apple).
staple() {
  local tries=0
  until xcrun stapler staple "$1" && xcrun stapler validate "$1"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 5 ]; then echo "Couldn't staple $1" >&2; exit 1; fi
    sleep 30
  done
}

scripts/build.sh
app="$work/Utter.app"
ditto build/Utter.app "$app"

swift build -c release --arch arm64 --arch x86_64 --product Utter
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Utter" "$app/Contents/MacOS/Utter"
echo "Architectures: $(lipo -archs "$app/Contents/MacOS/Utter")"

# The hardened runtime blocks the microphone unless the app asks for it.
cat > "$work/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST

echo "Signing with $IDENTITY"
codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$work/entitlements.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$work/Utter.zip"
notarize "$work/Utter.zip"
staple "$app"

staging="$work/dmg"
mkdir "$staging"
ditto "$app" "$staging/Utter.app"
ln -s /Applications "$staging/Applications"
dmg="$work/Utter.dmg"
hdiutil create -volname Utter -srcfolder "$staging" -fs HFS+ -format ULMO -ov "$dmg" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp --identifier dev.utter.Utter.dmg "$dmg"
notarize "$dmg"
staple "$dmg"

spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
spctl --assess --type execute --verbose=2 "$app"

cp "$dmg" website/public/Utter.dmg
echo "website/public/Utter.dmg: $(stat -f %z website/public/Utter.dmg) bytes, sha256 $(shasum -a 256 website/public/Utter.dmg | cut -d' ' -f1)"
