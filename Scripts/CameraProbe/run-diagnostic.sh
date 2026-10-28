#!/bin/zsh
# Historical protocol experiments only. Shipping-core acceptance uses run.sh.
set -eu
probe_root="${0:A:h:h:h}"
mkdir -p "$probe_root/.build/CameraProbe"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$probe_root/Packages/FujiCameraCore/Sources/FujiCameraCore/PTP/PTPTypes.swift" \
  "$probe_root/Packages/FujiCameraCore/Sources/FujiCameraCore/PTP/PTPCodec.swift" \
  "$probe_root/Scripts/CameraProbe/main.swift" \
  -o "$probe_root/.build/CameraProbe/diagnostic-probe"
exec "$probe_root/.build/CameraProbe/diagnostic-probe" "$@"
