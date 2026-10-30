# Landscape selection controls and date footer

The selected-photo counter stays physically to the left of clear selection in portrait and both landscape orientations. Select occupies exactly that horizontal pair's footprint and keeps the same native width and height when rotating. Filter retains its position between browse and selection modes.

Latest steering: in both landscape directions, place the date at the bottom, eight points above the day checkbox. Restore Select and Filter to the tray's top corner by removing the day-header inset. Portrait day layout stays unchanged.

The previous `TraySelectionControlLayout` converts child sizes to portrait canvas coordinates, sums their heights in landscape, then rotates the combined span back into a tall button. Lay out this subgroup directly in window coordinates. Its parent continues positioning the subgroup and Filter on the tray.

The landscape detent reserves at least the measured control width plus its 24-point padding across the entire grid. At AX5, widen the date column enough to wrap the date between the top controls and bottom checkbox without overlap.

- [x] Verify the updated landscape UI assertions fail on the old layout.
- [x] Remove orientation conversion from the selection subgroup.
- [x] Run focused portrait/landscape UI checks, unit tests, and the complete suite.
- [x] Review and push the change, refresh the signed phone app, and delete the isolated simulator.

Isolated simulator: `C483CDFB-660A-4CCA-9BCF-593FDAF70393`.
Regression log: `/tmp/fuji-horizontal-selection-red.log`.
Focused checks after the AX5 clearance fix: `/tmp/fuji-horizontal-selection-green.log`.
Footer regression log: `/tmp/fuji-landscape-footer-red.log` (old date-to-checkbox gap was 288 points instead of 8).
Latest focused checks: `/tmp/fuji-landscape-footer-focused.log`.

Verification:

- Focused controller, tray-control, and both-landscape UI checks: 23 passed, including normal and AX5 text sizes.
- `Scripts/test-ios.sh --fast`: 555 Swift Testing cases and 24 XCTest cases passed.
- Code review found no issues with the native control sizing or date footer geometry.
- Signed Release build passed; `codesign --verify --deep --strict` passed for the exact app installed on Louisphone. Installation and normal launch both succeeded.
- Implementation checkpoint pushed to `codex/selection-tray-days` at `70b63dbd`.

Full regression log: `/tmp/fuji-landscape-footer-full.log`.
Full regression result bundle: `.build/TestResults/20261030-141754-49965.xcresult`.

The complete parallel run finished with 656 passed, 2 failed, and 3 skipped (661 tests). Both failures were in existing phone recipe picker interactions: `testPhoneEditorSavesNameAndFilmOfflineAndCancelDiscardsChanges` could not find the offscreen `PROVIA / Standard` menu item, and `testXT5EditorOffersOnlyConvertibleFilmRangeAndBalance` could not tap `Colour temperature`. The latter also failed in earlier parallel runs. The tray UI and orientation tests passed.

The first serial editor rerun passed six tests, including the Colour temperature case, and reproduced the offscreen PROVIA dependency. The offline save/cancel test now selects the initially visible ACROS option while preserving its name, film-persistence, and cancellation assertions. This changes only test input; the phone app's source remains the verified, installed implementation checkpoint.

The final serial editor-suite rerun passed all seven tests with no failures. Across the full run and affected-suite rerun, all 658 executable tests have a passing result; three platform-dependent cases were skipped. The parallel-run Colour temperature limitation remains recorded above. Final serial log: `/tmp/fuji-landscape-footer-editor-green.log`; result: `.build/TestResults/20261030-143856-58093.xcresult`. Final test-only code review found no issues. The isolated simulator was shut down and deleted after validation.

Pull request: https://github.com/lun3x/fuji-studio/pull/42 (target: `main`).
