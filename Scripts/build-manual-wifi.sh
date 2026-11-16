#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -eq 0 ]]; then
  echo "Usage: Scripts/build-manual-wifi.sh -destination '<Xcode destination>' [xcodebuild settings]" >&2
  exit 2
fi

# XcodeGen generates this project without the product's signing capabilities.
spec=$(mktemp "$PWD/.manual-wifi-project.XXXXXX")
capturePlist=
trap 'rm -f "$spec"; if [[ -n "$capturePlist" ]]; then rm -f "$capturePlist"; fi' EXIT
if [[ -n ${FUJI_XAPP_CAPTURED_CLIENT_NAME:-} || ${FUJI_XT5_REFERENCE_APP_FLAGS:-0} == 1 ]]; then
  capturePlist=$(mktemp "$PWD/.manual-wifi-info.XXXXXX")
  cp Config/FujiStudio-Info.plist "$capturePlist"
  if [[ -n ${FUJI_XAPP_CAPTURED_CLIENT_NAME:-} ]]; then
    plutil -insert FujiCapturedXAppClientName -string "$FUJI_XAPP_CAPTURED_CLIENT_NAME" "$capturePlist"
  fi
  if [[ ${FUJI_XT5_REFERENCE_APP_FLAGS:-0} == 1 ]]; then
    plutil -insert FujiXT5ReferenceAppFlags -bool YES "$capturePlist"
  fi
fi
awk -v capturePlist="${capturePlist##*/}" '
  /^name: / { print "name: FujiManualWiFi"; next }
  /CODE_SIGN_ENTITLEMENTS:/ { next }
  /^[[:space:]]+INFOPLIST_FILE:/ && capturePlist != "" { print "        INFOPLIST_FILE: " capturePlist; next }
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
