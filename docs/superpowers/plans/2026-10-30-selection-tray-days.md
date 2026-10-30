# Selection tray day dividers

**Goal:** Group photos by capture day, with a date on the left and a checkbox on the right that selects that day's photos.

**Design:** Use collection view sections in the existing tray, preserving incoming photo order. Format dates as `Fri, Oct 23, 2026` using the current time zone. Undated photos have no date divider. A checkbox starts selection if needed, selects the whole visible day when partially selected, and deselects a fully selected day without affecting other days or the viewed photo. Filtered-out photos are excluded.

**Architecture:** Add a reusable UIKit day header and capture-day grouping. Update the grid's flat-index geometry to use section layout attributes for scroll anchors, reveal, sweep selection, and thumbnail caching. Add a dedicated workspace action for day toggles. Place selection controls in the drawer handle row so they cannot cover dates or checkboxes. Reserve the first day header's measured height in the collapsed tray. Wrap dates for accessibility fonts; in landscape, counter-rotate header contents and wrap the date into an upright column.

**Constraints:** Use Jujutsu in `/tmp/fuji-studio-selection-tray-days`, based on latest origin main. Use task simulator `2ADEC24D-3EC9-4E0B-AD13-550358BC939B`; remove it after validation. Push checkpoints on `codex/selection-tray-days`.

- [x] Add failing controller tests proving date headers and date metadata regrouping.
- [x] Add sectioned layout, header selection states, and section-aware geometry.
- [x] Add day selection action and tests for starting selection, preserving other days, partial selection, and filtering.
- [x] Add generated multi-day UI fixture coverage for day checkboxes and cross-day scrolling/sweeps.
- [ ] Run focused tests, `Scripts/test-ios.sh --fast`, affected UI suites, and the complete suite.
- [ ] Review the diff, push the final checkpoint, and remove the task simulator.

## Validation and review

- Controller day-section tests failed against the original single-section grid, then passed after implementation.
- Selection tests failed with the new action unimplemented, then passed for browse entry, partial/full day toggles, and camera filtering.
- All five PhotoGrid UI tests passed, including multi-day selection from browse and partial/full checkbox states.
- Independent review identified control overlap, collapsed-row clipping, sideways date headers, and accessibility truncation. Reproduced overlap/clipping in the workspace UI test and truncation in a controller test before fixing. Both workspace tests now pass, including both landscape directions.
- Final complete suite is in progress. The existing live-composition height assertion now includes the real day header; controller and hosting XCTest cases passed in this run.
