#!/bin/zsh
set -eu
root="${0:A:h:h:h}"
source_dir="$root/Scripts/MacWirelessProbe"
package="$root/Packages/FujiCameraCore"
build="$root/.build/MacWirelessProbeTests"

xcrun swift build --package-path "$package" --scratch-path "$build/core" >&2
core="$(xcrun swift build --package-path "$package" --scratch-path "$build/core" --show-bin-path)"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx27.0" -parse-as-library -I "$core" \
  "$source_dir/ProbeSecureStatusComparison.swift" "$source_dir/Tests/SecureStatusComparisonTests.swift" \
  "$core/libFujiCameraCore.a" -o "$build/SecureStatusComparisonTests"
"$build/SecureStatusComparisonTests"
