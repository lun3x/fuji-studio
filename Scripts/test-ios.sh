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
FUJI_STUDIO_TEST_WORKERS selects simulator UI test workers (default: 2).
Set it to 1 for serial execution. Unit-only and physical-device runs are unchanged.
FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure enables verbose failure diagnostics.
The default is never; normal test results and attachments are still collected.
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

workers="${FUJI_STUDIO_TEST_WORKERS-2}"
if [[ ! "$workers" =~ ^[1-9][0-9]*$ ]]; then
  echo 'error: FUJI_STUDIO_TEST_WORKERS must be a positive integer.' >&2
  exit 2
fi
diagnostics="${FUJI_STUDIO_TEST_DIAGNOSTICS-never}"
case "$diagnostics" in
  never|on-failure) ;;
  *) echo 'error: FUJI_STUDIO_TEST_DIAGNOSTICS must be never or on-failure.' >&2; exit 2 ;;
esac
includes_ui=false
if [[ $# -eq 0 ]]; then includes_ui=true; fi
for selector in "$@"; do
  case "$selector" in FujiStudioUITests|FujiStudioUITests/*) includes_ui=true ;; esac
done

xcodegen generate
# Use iPhone 15 Pro by default; task-specific simulators can override this.
destination="${FUJI_STUDIO_DESTINATION:-platform=iOS Simulator,name=iPhone 15 Pro}"
mkdir -p .build/TestResults
result=".build/TestResults/$(date +%Y%m%d-%H%M%S)-$$.xcresult"
args=(-project FujiStudio.xcodeproj -scheme FujiStudio -destination "$destination" -derivedDataPath .build/DerivedData -resultBundlePath "$result")
args+=(-collect-test-diagnostics "$diagnostics")
if [[ "$destination" == *"Simulator"* ]]; then
  args+=(CODE_SIGNING_ALLOWED=NO)
  if [[ "$includes_ui" == true ]]; then
    if [[ "$workers" == 1 ]]; then
      args+=(-parallel-testing-enabled NO)
    else
      args+=(-parallel-testing-enabled YES -parallel-testing-worker-count "$workers")
    fi
  fi
fi
for selector in "$@"; do args+=("-only-testing:$selector"); done
xcodebuild test "${args[@]}"
