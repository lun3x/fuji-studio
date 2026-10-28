# Photo loading ring validation

Date: 2026-10-28

## Change

Replace the segmented photo spinner with a fixed 48-point ring. Download
progress fills clockwise from twelve o'clock. No numerical percentage is drawn;
the download value remains available through accessibility. Processing rotates
a short arc in the same frame. The system Reduce Motion setting pauses rotation.

The existing dimmed previous photo, zoom state, viewport, error presentation,
and noninteractive overlay behavior are retained.

## Evidence

- The old UI reproduced an 11.33-point indicator shift when download text
  appeared (center y=391.1667 → 379.8333).
- The regression now measures the ring itself across loading → downloading →
  processing. Center and dimensions must remain within one point; this allows
  native accessibility rounding of rotated paths while rejecting the old jump.
- UI assertions verify the accessible 25% value and absence of visible 25%
  text. The photo frame and zoom are checked before and after loading.
- A separate UI case covers the same loading transitions without an existing
  image and the return to unavailable-image presentation afterward.
- Screenshots of the ring at 25% were inspected both over a dimmed image and
  without an image. The fill runs clockwise from twelve to three o'clock and
  neither view displays percentage text.
- A fresh independent code review found no actionable issues.

## Test runs

- Baseline loading regression: passed before strengthening the measurement.
- Strengthened regression against old code: failed on the measured 11.33-point
  shift, as expected.
- First ring iteration: two loading cases failed exact frame comparisons due
  to less than 0.25-point accessibility rounding. Comparisons now use the
  existing one-point centering tolerance for all four frame measurements.
- Final full `Scripts/test-ios.sh`: **517 passed, 3 established native-gate
  skips, 0 failures**, exit 0. This includes 462 unit tests (443 Swift Testing
  and 19 XCTest) and all 58 UI cases on the task-specific iPhone 15 Pro simulator
  with iOS 27.0.
- Result bundle: `.build/TestResults/20261028-172904-54455.xcresult`.
  The final passed loading test screenshot was also exported and inspected at
  `.build/loading-final/A0A70410-DD44-4EAD-84C3-B8BAB45A517B.png`.
- The run took approximately 38 minutes. An existing rotation test repeatedly
  waited 60 seconds for simulator animation notifications and eventually passed
  after 1,222 seconds. Its fixture does not display the loading ring.

## Physical iPhone installation

The user requested a phone installation after simulator validation. The Release
build from `5d9b4c9c` succeeded for the connected physical iPhone 15 Pro using
the existing automatic signing configuration. `codesign --verify --deep --strict`
passed before installation. That exact signed bundle was installed with
`devicectl`, and `com.lun3x.FujiStudio` was launched normally without fixture or
test arguments. Device process inspection confirmed Fuji Studio remained running.

## Light grey refinement

The user requested a lighter grey after viewing the ring on the phone. Commit
`270c6f26` changes the active arc and download fill from the theme's primary
color to `UIColor.lightGray`. The Release phone build succeeded, strict code
signature verification passed, and that exact bundle was installed and launched
normally on the connected iPhone 15 Pro.

The full simulator suite passed again: **517 passed, 3 established native-gate
skips, 0 failures**, exit 0. Result bundle:
`.build/TestResults/20261028-182422-73899.xcresult`. The passed loading regression
screenshot at `.build/grey-ring-final/7B4DEACF-8274-4069-95C2-117B4223AB3C.png`
was inspected and confirms the lighter grey fill with no visible percentage.
The task-specific simulator was shut down and deleted after validation.

## Remaining device checks

Reduce Motion's static branch was reviewed in code; runtime setting changes
and spoken VoiceOver output were not exercised. No camera conversion or Photos
export was performed for this UI change. Visual acceptance of the loading ring
on the physical phone remains a user check.
