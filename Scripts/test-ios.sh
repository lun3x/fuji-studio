#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
# Inspected with xcrun simctl list devices available (iOS 27.1, iPhone Duo).
destination="${FUJI_STUDIO_DESTINATION:-platform=iOS Simulator,id=5277B203-F40D-4AEF-98E9-164D7C653887}"
mkdir -p .build/TestResults
result=".build/TestResults/$(date +%Y%m%d-%H%M%S)-$$.xcresult"
args=(-project FujiStudio.xcodeproj -scheme FujiStudio -destination "$destination" -derivedDataPath .build/DerivedData -resultBundlePath "$result")
if [[ "$destination" == *"Simulator"* ]]; then
  args+=(CODE_SIGNING_ALLOWED=NO)
fi
if [[ $# -gt 0 ]]; then args+=("-only-testing:$1"); fi
xcodebuild test "${args[@]}"
