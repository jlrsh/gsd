#!/bin/bash
# Build the Mac app, install it in /Applications (or ~/Applications), and start it.
#   apple/scripts/deploy-mac.sh            signed with the Personal Team (run from a GUI session)
#   apple/scripts/deploy-mac.sh --adhoc    ad-hoc signature (works over SSH; Keychain re-asks after each build)
set -eu
cd "$(dirname "$0")/.."
[ -f Local.xcconfig ] || { echo "Create apple/Local.xcconfig (see Local.xcconfig.example)"; exit 1; }
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
xcodegen generate >/dev/null

SIGN=(-allowProvisioningUpdates)
[ "${1:-}" = "--adhoc" ] && SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
mkdir -p build
if ! xcodebuild -project GSD.xcodeproj -scheme GSDMac -configuration Release -destination "platform=macOS" \
    -derivedDataPath build/DerivedData "${SIGN[@]}" build >build/mac-build.log 2>&1; then
  grep -E "error:|BUILD FAILED" build/mac-build.log | head -20
  echo "Build failed; full log in apple/build/mac-build.log"
  exit 1
fi

APP=build/DerivedData/Build/Products/Release/GSD.app
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -TERM -x GSD 2>/dev/null && sleep 1 || true  # quits cleanly: checked items are filed and saved
rm -rf "$DEST/GSD.app"
ditto "$APP" "$DEST/GSD.app"
open "$DEST/GSD.app"
codesign -dv "$DEST/GSD.app" 2>&1 | grep -E "^(Authority|Signature)=" | head -1
echo "Installed $DEST/GSD.app. Summon it with ⌃⌥G (change in Settings)."
