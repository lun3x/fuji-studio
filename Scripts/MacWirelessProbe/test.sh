#!/bin/zsh
set -eu
source_dir="${0:A:h}"
build="$source_dir/../../.build/MacWirelessProbeTests"
mkdir -p "$build"
xcrun swiftc -swift-version 6 -parse-as-library \
  "$source_dir/RunDirectory.swift" "$source_dir/Tests/RunDirectoryTests.swift" \
  -o "$build/RunDirectoryTests"
"$build/RunDirectoryTests" "$source_dir/control.sh"
