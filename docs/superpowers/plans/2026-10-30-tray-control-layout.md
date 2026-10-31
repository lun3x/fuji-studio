# Tray control layout revision

The user specified the layout directly: float Select/Filter over the tray, keep Filter fixed between modes, put the selected count between Filter and clear selection, and make Select occupy exactly the count-plus-clear span. Put the circular day check before the date in portrait, below the date in both landscape directions. Use a grey circle with a light check, turning blue for a fully selected day.

Use a measured selection-control layout containing unstyled sizing labels at all times, with conditional overlays creating only the active glass controls. Reserve count width for the library's largest possible count so changes in digit count cannot shift Filter. Follow the tray's existing orientation-aware placement. Reserve the floating controls' footprint in portrait day headers, wrapping the date below that footprint at accessibility sizes when necessary. Keep landscape dates upright and at the top; inset top controls past the day-header column so they cannot obscure its date.

- [x] Fetch origin and create `/tmp/fuji-studio-tray-control-layout` from the active day-divider bookmark.
- [x] Prove existing positions fail the new controller and UI assertions.
- [x] Implement stable control layout, header placement, and circular check appearance.
- [x] Verify normal/large text, changing count digits, and both landscape orientations.
- [x] Run unit tests, affected UI suites, and the complete iOS suite; review and push checkpoints.
- [x] Refresh the signed phone build and remove the task simulator.

Task simulator: `BA2B3E78-4B84-4693-BBE5-A33170849558`.

## Validation

All unit tests passed (555 Swift Testing cases and 24 XCTest cases). Focused UI tests passed for fixed Filter placement across modes and changing digit counts, inactive control removal, portrait date/check separation, and dated photos in both landscape directions with normal and AX5 text. Native screenshots verified the circular grey/blue checks and separate browse/selection controls. Independent review found the opacity-based glass visibility issue; conditional controls fixed it, and new inactive-button assertions plus screenshots verify the fix. No remaining source-level review findings.

The complete suite (`.build/TestResults/20261030-130730-18385.xcresult`) reported 655 passed, 3 failed, and 3 skipped, out of 661 tests. Two failures were an outdated X-E3 debug camera fixture still using the capability identifier as its conversion support version. Changing it to `XE3Support.conversionVersion` fixed both `ModelRecipeTests/testXE3RAWDisplayFailureKeepsPairedJPEGAndConversionAvailable` and `RecipePhotoCompatibilityTests/testXE3RecipesAreDisabledForMixedPhotoSelection`.

All unit tests and the affected ModelRecipe, RecipePhotoCompatibility, and CameraFilter suites were rerun after that correction: 591 passed, with only `PhoneRecipeEditorTests/testXT5EditorOffersOnlyConvertibleFilmRangeAndBalance` failing. This existing test repeatedly cannot hit the Colour temperature picker option in parallel headless workers; it passed unchanged when rerun serially. Attempted test interaction workarounds did not resolve the worker issue and were reverted. Across the full run and follow-up runs, every test has a passing result (658 passed, 3 skipped), but this recipe-editor test remains unreliable under parallel execution. The skipped tests require native keyboard, Home/background delivery, or device-rotation validation.

## Physical phone

Built the Release app with automatic signing, development team `AZH3P824F3`, and `Apple Development`. `codesign --verify --deep --strict` passed for the exact `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` installed on Louisphone. After the user unlocked the phone, `com.lun3x.FujiStudio` launched successfully with no fixture or test arguments. The X-E3 fixture correction is inside `#if DEBUG` and does not affect this Release build.

The task simulator was deleted after validation; Xcode removed its worker clones. Implementation and validation checkpoints were pushed to `codex/selection-tray-days`.
