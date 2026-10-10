#!/bin/sh
# Build and install gsd on the connected iPhone (free Personal Team; 7-day expiry).
#   apple/scripts/deploy.sh [device-name-or-udid]
set -eu
cd "$(dirname "$0")/.."
[ -f Local.xcconfig ] || { echo "Create apple/Local.xcconfig (see Local.xcconfig.example)"; exit 1; }
xcodegen generate >/dev/null
DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && !/simulated/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-/) { print $i; exit } }')}
[ -n "$DEVICE" ] || { echo "No iPhone found: connect it, unlock it, and trust this Mac"; exit 1; }
xcodebuild -project GSD.xcodeproj -scheme GSD -configuration Debug \
  -destination "generic/platform=iOS" -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
APP=build/DerivedData/Build/Products/Debug-iphoneos/GSD.app
[ -d "$APP" ] || exit 1
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed. First run: Settings > General > VPN & Device Management > trust your developer profile."
