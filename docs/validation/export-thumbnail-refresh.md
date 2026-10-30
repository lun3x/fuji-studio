# Export thumbnail refresh — 30 October 2026

Reversible exports leave the original RAW resource identity unchanged. The tray
therefore kept its existing thumbnail request even after Photos reported an edit.
It now refreshes active requests for changed assets and replaces their Photos
preheat snapshots. The image request uses Photos' current version. Late callbacks
from a previous request cannot restore an older thumbnail.

The selected sources, checked state, and RAW resource/cache identities remain
stable. The same Photos change path handles edits and reverting an edit.

## Regression evidence

- Reproduced the stale image in both the actual collection cell and the export
  UI before wiring the refresh path. The UI screenshot's center pixel remained
  identical after export.
- Added coverage for affected versus unrelated requests, cancellation, late
  callbacks, and synchronous callback reentrancy. An integration test checks
  that a Photos edit refreshes the image without changing the RAW revision.
- `Scripts/test-ios.sh --fast`: 570 Swift Testing cases and 20 XCTest cases
  passed.
- `Scripts/test-ios.sh FujiStudioUITests/StatusSettingsTests`: all 3 passed.
  The new regression verifies that the checked tray image changes after export
  while the one-photo selection stays intact.
- Complete `Scripts/test-ios.sh`: 669 total, 664 passed, 2 failed, 3 skipped.
  Result bundle: `.build/TestResults/20261030-150419-70139.xcresult`.
  The two failures were existing `PhoneRecipeEditorTests` menu interactions:
  `testPhoneEditorGrainChoicesStayConvertibleAcrossSaveAndReopen` and
  `testXT5EditorOffersOnlyConvertibleFilmRangeAndBalance`. The captured grain
  screenshot showed the selected-item picker still open after XCTest's tap,
  blocking Save. Both tests passed unchanged in an isolated serial retry
  (`.build/TestResults/20261030-151535-75752.xcresult`). The full run itself
  remains recorded as failed; no recipe-editor production or test code changed.
- Independent read-only review found no actionable issues. Native PhotoKit
  rendering in a real photo library remains outside simulator fixture coverage.

Validation uses the isolated iPhone 15 Pro simulator **Fuji Export Thumbnail
Refresh** (`554CD4A0-6957-446E-83FC-A9DE7C1C4D79`, iOS 27.0).
It was shut down and deleted after validation.

## Physical iPhone installation

The Release app for fix commit `9e99480e` built with automatic signing, development
team `AZH3P824F3`, and the `Apple Development` identity. Its exact bundle at
`.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` passed
`codesign --verify --deep --strict`, installed on Louisphone (iPhone 15 Pro),
and launched as `com.lun3x.FujiStudio` with no fixture or test arguments.
Installation does not constitute a real-library export test.
