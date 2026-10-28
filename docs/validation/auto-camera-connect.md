# Automatic camera connection validation

The app starts the existing ImageCaptureCore USB discovery automatically.
Device additions during discovery use its existing callback path; unsuccessful
attempts wait three seconds before trying again. There is no Connect button.

## Regression evidence

- Before implementation, the new startup test failed because no connection or
  recipe import happened without an explicit Connect action.
- All 402 unit tests passed after implementation, including startup idempotence,
  retry interval, absent-camera error handling, no overlapping attempts,
  inactive cancellation, foreground recovery without a prior successful session,
  denied authorization, and discovery independent of Photos loading.
- A code review found the environment-loading/initial-scene race. The new
  `testInitiallyInactiveStartupWaitsForForegroundBeforeConnecting` UI test failed
  against the old startup order, then passed after applying the recorded scene
  phase before starting the model.
- Existing conversion/export recovery tests retain explicit resume/retry;
  automatic reconnection does not replay an interrupted conversion or export.
- The explicit DEBUG acceptance route disables automatic connection, preserving
  its receipt checks and authoritative final native close. Its replay tests
  still require zero connection/render/save attempts.

## Evidence boundaries

Tests use an isolated simulator created for this task. The deterministic retry
wait advances app policy without wall-clock delays; UI tests also exercise the
real three-second wait when a fixture camera becomes available. Release builds
exclude fixture controls.

No physical camera or Photos export was used for this change. USB attachment,
unplug/replug and real camera authorization timing remain physical-device checks.
The existing supported-camera, USB mode and firmware requirements still apply.

## Final gate

- Complete simulator gate: **459 passed, 3 existing native-gate skips,
  0 failures**, exit 0 (462 tests in the xcresult summary).
- Command: `FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=A80EA824-4DAF-4C40-B841-4A31C3F43D2D' Scripts/test-ios.sh`.
- Result: `.build/TestResults/20261028-081424-44293.xcresult`.
- Unsigned generic iOS Simulator Release build: **passed**, exit 0, using
  `.build/ReleaseDerivedData`.
- Normal light-mode and largest-text dark-mode screenshots inspected: status,
  recipes, versions and drawer controls remain usable with Connect absent.
  Exported evidence is in ignored `.build/AutoConnectScreenshots` and
  `.build/AutoConnectAXScreenshots`.
- Independent review found one startup ordering issue, fixed with the UI
  regression described above. No other actionable findings were reported.
