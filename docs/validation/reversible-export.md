# Reversible export and status settings — 30 October 2026

The status sheet is now **Status & settings**. Its red **Update original in Photos**
setting defaults off, persists across launches, and is captured when an export
job starts. Enabled exports use PhotoKit content editing on the source asset;
they preserve the original RAW and camera JPEG and store an operation/recipe
marker for exact recovery. Only the current matching edit is selectable.

## Validation

- `Scripts/test-ios.sh --fast`: **566 tests passed** after the review fixes.
- `swift test --package-path Packages/FujiCameraCore`: **138 tests passed**.
- `StatusSettingsTests`: **2 passed**, including persistence across relaunch and
  hiding an older edit after a second export.
- Affected `ExportFlowTests`: **7 passed**, **1 existing native Home-boundary test
  skipped**.
- Complete `Scripts/test-ios.sh` run: **663 total, 660 passed, 0 failed, 3 skipped**
  using the supported four-worker mode.
  Result bundle: `.build/TestResults/20261030-135111-38515.xcresult`.

All iOS checks use the task-specific **Fuji Reversible Export** iPhone 15 Pro
simulator (`C108EF1E-9E8D-4FE1-9A22-DC4D92068459`, iOS 27.0). It was shut down
and deleted after validation.
The rendered settings screenshot was inspected: red label and switch, readable
explanatory text, and working Done control.

## Review and implementation decisions

A fresh independent review found two important issues, both reproduced before
fixing and then covered by passing regressions:

- Current edits now verify live adjustment/resource identity after Photos access
  is restored, rather than trusting a stale inaccessible catalog flag.
- Optional PhotoKit size hints cannot change an original's revision or frozen
  source identity as an iCloud download completes. Resource listings retain size
  diagnostics, and strict resource-token equality remains unchanged.

Edited-version availability is derived per operation in the displayed snapshot.
The catalog's existing asset-wide availability setter cannot distinguish several
historical operations on the same asset. Resolution independently verifies the
live operation marker before and after transferring the edited JPEG.

Jujutsu equivalents replaced Git-based workflow scripts, following the repository
instructions. Stale test expectations were updated to the existing measured
X-E3 conversion version (unit and UI fixtures) and X-T5 DR200 support; no camera capability behavior was
changed. Two existing recipe-editor UI tests were corrected to scroll an
off-screen menu option and use a measured tap for an iOS 27 popover child with
incorrect accessibility hittability.

No deferred review findings remain. Historical payload compatibility shims were
not added, following the project instruction.

## Physical iPhone installation

The Release build was signed with development team `AZH3P824F3`, verified with
`codesign --verify --deep --strict`, and installed on the connected iPhone 15 Pro.
`com.lun3x.FujiStudio` launched successfully with no fixture or test arguments.

## Physical-device limit

The simulator fixtures exercise the app's writer, recovery and viewer contracts;
they replace the native PhotoKit boundary. Editing real Fujifilm RAW-only and
RAW+JPEG assets through PhotoKit still requires physical-device validation.
