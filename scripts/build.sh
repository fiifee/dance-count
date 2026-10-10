#!/bin/bash
# Usage: scripts/build.sh [ios|device|install|run-ios|test|bench]
#   install: Release build onto the first paired physical iPhone (or DEVICE=<udid>)
#   run-ios: extra args go to the app, e.g. scripts/build.sh run-ios -demo salsa
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ACTION="${1:-ios}"
SIM="${SIM:-iPhone 17 Pro}"
BUNDLE_ID=com.raikoevestus.DanceCount

COMMON=(-project DanceCount.xcodeproj -scheme DanceCount -configuration Debug -derivedDataPath build -quiet)
IOS_APP="build/Build/Products/Debug-iphonesimulator/Dance Count.app"

case "$ACTION" in
  ios|device|install|run-ios) xcodegen generate --quiet ;;
esac

case "$ACTION" in
  ios) xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,name=$SIM" build ;;
  device) xcodebuild "${COMMON[@]}" -destination "generic/platform=iOS" -allowProvisioningUpdates build ;;
  install)
    xcodebuild -project DanceCount.xcodeproj -scheme DanceCount -configuration Release -derivedDataPath build -quiet \
      -destination "generic/platform=iOS" -allowProvisioningUpdates build
    DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && (/available/ || /connected/) {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}"
    [ -n "$DEVICE" ] || { echo "No paired iPhone found — connect it (cable or same Wi-Fi) and unlock it" >&2; exit 1; }
    xcrun devicectl device install app --device "$DEVICE" "build/Build/Products/Release-iphoneos/Dance Count.app"
    ;;
  run-ios)
    xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,name=$SIM" build
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl install "$SIM" "$IOS_APP"
    xcrun simctl terminate "$SIM" $BUNDLE_ID 2>/dev/null || true
    xcrun simctl launch "$SIM" $BUNDLE_ID "${@:2}"
    ;;
  test) (cd BeatKit && perl -e 'alarm 900; exec @ARGV' swift test) ;;
  bench) (cd BeatKit && swift run -c release beatcli bench) ;;
  *) echo "Unknown action: $ACTION" >&2; exit 1 ;;
esac
