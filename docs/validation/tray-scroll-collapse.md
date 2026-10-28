# Photo-grid pull to collapse the tray — 27 October 2026

Implementation: `b39f865c`, on `codex/tray-scroll-collapse`, in
[PR #11](https://github.com/lun3x/fuji-studio/pull/11).

An active downward scroll in the expanded photo tray consumes the remaining
distance to the grid's top, then drags the tray directly with the finger. Release
uses the divider's existing detents, spring and viewed-photo reveal. Reversing
past full expansion returns movement and momentum to native photo scrolling.
Browse and Select retain the viewed photo, checked set and persistent grid.

## Validation

- The new collapse UI regression failed against the original implementation,
  then passed in Browse and Select. Recorded native frame trajectories verify
  continuous motion and no release reset.
- Independent code review found that reversing beyond full expansion kept the
  grid pinned. The added regression failed at the expected scroll-offset and
  deceleration assertions, then passed after returning ownership to the grid.
- All 13 grid-controller tests passed, including top crossing, reversal,
  cancellation, collapsed-tray admission, untracked bounce, source anchoring,
  range selection and thumbnail lifecycle.
- The focused short-pull/top-crossing UI test passed. Both new UI tests also
  passed in the full run, together with divider gestures, range selection,
  photo scrolling, collapse reveal, accessibility and viewport-layout checks.

The complete `Scripts/test-ios.sh` run on the isolated iOS 27.1 simulator
recorded **455 tests: 451 passed, 3 established skips, 1 runner termination**,
exit 65. The interrupted test was
`PhotoViewerTests.testZoomPersistsAcrossMatchingVersionsAndResetsForNewSource`;
its runner received SIGTERM while waiting for a version-menu row. The test uses
the standalone viewer fixture, without a photo tray. Its cause was not
determined. A focused rerun of that test on unchanged code **passed**, exit 0.
The full-run failure remains recorded in its result bundle.

After test execution, Xcode waited on its task-specific `simctl diagnose`
collector. A process sample located that wait; the collector was stopped to
allow result finalization. This occurred after the viewer runner interruption.
No test process or simulator belonging to another task was stopped.

The three established skips are native Home/background delivery, physical
rotation and hardware Escape delivery. No physical-device gesture validation
was performed. The task simulator `50213F02-26A8-43CE-86DD-F5EF91474FE4` was deleted.

## Local evidence

Retained under the ignored `.build/` directory in
`/tmp/fuji-studio-tray-scroll-collapse/`:

- `tray-scroll-collapse/red.log` and `green.log`: initial regression cycle.
- `tray-scroll-collapse/reversal-red.log` and `controller-green.log`: reversal
  regression and all 13 controller tests.
- `tray-scroll-collapse/handoff-green.log`: focused short-pull/top-crossing UI.
- `tray-scroll-collapse/final-suite.log` and
  `TestResults/20261027-230733-88020.xcresult`: complete run and runner termination.
- `tray-scroll-collapse/viewer-rerun.log` and
  `TestResults/20261027-232241-91704.xcresult`: successful viewer rerun.
- `tray-scroll-collapse/final-collapse-attachments/` and
  `final-handoff-attachments/`: screenshot, native bounds and gesture trajectories.
- `tray-scroll-collapse/xcodebuild-finalization.sample.txt`: diagnostics wait.
