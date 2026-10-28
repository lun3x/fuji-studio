#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: Scripts/test-ios.sh [--fast | Target[/Suite[/Test]] ...]

  --fast       Run all unit tests (FujiStudioTests), without UI tests.
  --help, -h   Show this help.
  No arguments Run the complete unit and UI test suite.

Supply one or more test selectors to run focused unit or UI tests.
--fast must be used alone. FUJI_STUDIO_DESTINATION selects the device.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --fast)
    if [[ $# -ne 1 ]]; then
      echo 'error: --fast must be used alone; use test selectors for focused runs.' >&2
      exit 2
    fi
    set -- FujiStudioTests
    ;;
esac
for selector in "$@"; do
  if [[ -z "$selector" || "$selector" == -* ]]; then
    echo "error: invalid test selector: $selector" >&2
    usage >&2
    exit 2
  fi
done

xcodegen generate
# Use iPhone 15 Pro by default; task-specific simulators can override this.
destination="${FUJI_STUDIO_DESTINATION:-platform=iOS Simulator,name=iPhone 15 Pro}"
mkdir -p .build/TestResults
result=".build/TestResults/$(date +%Y%m%d-%H%M%S)-$$.xcresult"
args=(-project FujiStudio.xcodeproj -scheme FujiStudio -destination "$destination" -derivedDataPath .build/DerivedData -resultBundlePath "$result")
if [[ "$destination" == *"Simulator"* ]]; then
  args+=(CODE_SIGNING_ALLOWED=NO)
fi
for selector in "$@"; do args+=("-only-testing:$selector"); done
xcodebuild test "${args[@]}"
