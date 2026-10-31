# Selection tray day dividers

Control placement and day-check styling are superseded by [the tray control layout revision](2026-10-30-tray-control-layout.md).

**Goal:** Group photos by capture day, with a date on the left and a checkbox on the right that selects that day's photos.

**Design:** Use collection view sections in the existing tray, preserving incoming photo order. Format dates as `Fri, Oct 23, 2026` using the current time zone. Undated photos have no date divider. A checkbox starts selection if needed, selects the whole visible day when partially selected, and deselects a fully selected day without affecting other days or the viewed photo. Filtered-out photos are excluded.

**Architecture:** Add a reusable UIKit day header and capture-day grouping. Update the grid's flat-index geometry to use section layout attributes for scroll anchors, reveal, sweep selection, and thumbnail caching. Add a dedicated workspace action for day toggles. Place selection controls in the drawer handle row so they cannot cover dates or checkboxes. Reserve the first day header's measured height in the collapsed tray. Wrap dates for accessibility fonts; in landscape, counter-rotate header contents and wrap the date into an upright column.

**Constraints:** Use Jujutsu in `/tmp/fuji-studio-selection-tray-days`, based on latest origin main. Use task simulator `2ADEC24D-3EC9-4E0B-AD13-550358BC939B`; remove it after validation. Push checkpoints on `codex/selection-tray-days`.

- [x] Add failing controller tests proving date headers and date metadata regrouping.
- [x] Add sectioned layout, header selection states, and section-aware geometry.
- [x] Add day selection action and tests for starting selection, preserving other days, partial selection, and filtering.
- [x] Add generated multi-day UI fixture coverage for day checkboxes and cross-day scrolling/sweeps.
- [x] Run focused tests, `Scripts/test-ios.sh --fast`, affected UI suites, and the complete suite.
- [x] Review the diff, push the final checkpoint, and remove the task simulator.

## Validation and review

- Controller day-section tests failed against the original single-section grid, then passed after implementation.
- Selection tests failed with the new action unimplemented, then passed for browse entry, partial/full day toggles, and camera filtering.
- All five PhotoGrid UI tests passed, including multi-day selection from browse and partial/full checkbox states.
- Independent review identified control overlap, collapsed-row clipping, sideways date headers, and accessibility truncation. Reproduced overlap/clipping in the workspace UI test and truncation in a controller test before fixing. Both workspace tests now pass, including both landscape directions.
- Updated existing live-composition/reconnect/pinch assertions to include the date header in the collapsed viewport, and the selection-control assertion to use the handle row.
- Complete `Scripts/test-ios.sh` run: 647 passed, 3 failed, 3 skipped. Two failures were the old layout assertions above. The other was `PhoneRecipeEditorTests/testXT5EditorOffersOnlyConvertibleFilmRangeAndBalance`, where the software keyboard covered the Colour temperature menu option.
- After updating the two layout assertions, all three failures passed in a focused serial rerun (3 tests, 0 failures). The recipe-editor test passed unchanged. Across the complete run and reruns, every test has a passing result: 650 passed, 3 skipped. Skips require native keyboard, native Home/background delivery, or native device rotation validation.
- Result bundles: complete run `.build/TestResults/20261030-081345-65084.xcresult`; focused rerun recorded in `/tmp/fuji-tray-days-rerun.log`.
- Final feature checkpoint pushed on `codex/selection-tray-days`. The task simulator was shut down and deleted; Xcode removed its worker clones automatically.

## Physical iPhone installation — 2026-10-30

- Rebased the day-divider changes onto latest origin main (`db935a1b`) to retain the source dynamic-range conversion fix.
- Updated the X-E3 test receipt fixture to use `XE3Support.conversionVersion` after that upstream version change. Its model-switch test initially failed three assertions with the old fixture version; the complete unit rerun passed (555 Swift Testing cases and 23 XCTest cases).
- Built Release for the connected physical iPhone 15 Pro with automatic signing, team `AZH3P824F3`, and `Apple Development` identity.
- `codesign --verify --deep --strict` passed for `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app`. Installed that exact bundle and successfully launched `com.lun3x.FujiStudio` without fixture or test arguments.
- Removed the isolated simulator used for the unit rerun.
