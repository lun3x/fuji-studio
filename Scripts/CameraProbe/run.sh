#!/bin/zsh
set -eu
probe_root="${0:A:h:h:h}"
mkdir -p "$probe_root/.build/CameraProbe"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$probe_root/FujiStudio/Camera/PTPTypes.swift" \
  "$probe_root/FujiStudio/Camera/PTPCodec.swift" \
  "$probe_root/Scripts/CameraProbe/main.swift" \
  -o "$probe_root/.build/CameraProbe/probe"
exec "$probe_root/.build/CameraProbe/probe" "$@"
