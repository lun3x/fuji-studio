#!/bin/zsh
set -eu
root="${0:A:h:h:h}"
build="${MAC_WIRELESS_PROBE_BUILD_DIR:-$root/.build/MacWirelessProbe}"
package="$root/Packages/FujiCameraCore"
wireless="$root/FujiStudio/Wireless"
app="$build/MacWirelessProbe.app"

xcrun swift build --package-path "$package" --scratch-path "$build/core" >&2
core="$(xcrun swift build --package-path "$package" --scratch-path "$build/core" --show-bin-path)"
mkdir -p "$app/Contents/MacOS"
cp "$root/Scripts/MacWirelessProbe/Info.plist" "$app/Contents/Info.plist"

xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx27.0" -D DEBUG \
  -parse-as-library -I "$core" \
  "$root/Scripts/MacWirelessProbe/"*.swift \
  "$wireless/AutoSaveGateway.swift" "$wireless/BluetoothGateway.swift" \
  "$wireless/CoreBluetoothConnections.swift" "$wireless/CoreBluetoothDriver.swift" \
  "$wireless/KeychainCameraStore.swift" "$wireless/NativeBluetoothGateway.swift" \
  "$wireless/NetworkByteChannel.swift" "$wireless/SavedCameraStore.swift" "$core/libFujiCameraCore.a" \
  -o "$app/Contents/MacOS/MacWirelessProbe"

codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
