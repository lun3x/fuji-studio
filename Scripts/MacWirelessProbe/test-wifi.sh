#!/bin/zsh
set -eu
root="${0:A:h:h:h}"
source_dir="$root/Scripts/MacWirelessProbe"
wireless="$root/FujiStudio/Wireless"
package="$root/Packages/FujiCameraCore"
build="$root/.build/MacWirelessProbeTests"

xcrun swift build --package-path "$package" --scratch-path "$build/core" >&2
core="$(xcrun swift build --package-path "$package" --scratch-path "$build/core" --show-bin-path)"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx27.0" -parse-as-library -I "$core" \
  "$source_dir/ProbeWiFiActivation.swift" "$source_dir/Tests/ProbeWiFiActivationTests.swift" \
  "$source_dir/ProbeFirmwareObservation.swift" \
  "$wireless/AutoSaveGateway.swift" "$wireless/BluetoothGateway.swift" "$wireless/SavedCameraStore.swift" \
  "$core/libFujiCameraCore.a" -o "$build/ProbeWiFiActivationTests"
"$build/ProbeWiFiActivationTests"
