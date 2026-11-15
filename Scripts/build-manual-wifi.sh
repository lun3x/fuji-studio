#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -eq 0 ]]; then
  echo "Usage: Scripts/build-manual-wifi.sh -destination '<Xcode destination>' [xcodebuild settings]" >&2
  exit 2
fi

# XcodeGen generates this project without the product's signing capabilities.
spec=$(mktemp "$PWD/.manual-wifi-project.XXXXXX")
trap 'rm -f "$spec"' EXIT
awk '
  /^name: / { print "name: FujiManualWiFi"; next }
  /CODE_SIGN_ENTITLEMENTS:/ { next }
  /INFOPLIST_KEY_NSLocalNetworkUsageDescription:/ {
    print "        INFOPLIST_KEY_NSLocalNetworkUsageDescription: Fuji Manual WiFi uses your local network to identify the selected Fujifilm camera."
    next
  }
  /INFOPLIST_KEY_CFBundleDisplayName:/ {
    print "        INFOPLIST_KEY_CFBundleDisplayName: Fuji Manual WiFi"
    print "        SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) MANUAL_WIFI_DIAGNOSTIC"
    next
  }
  { print }
' project.yml > "$spec"
xcodegen generate --spec "$spec"
xcodebuild -project FujiManualWiFi.xcodeproj -scheme FujiStudio -configuration Debug \
  -derivedDataPath .build/ManualWiFi "$@" build
