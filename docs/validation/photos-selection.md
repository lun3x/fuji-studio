# Photos-style tray selection — 27 October 2026

The tray replaces All/None with a floating glass Select button. Select becomes
an X that clears batch membership and returns to the viewed photo. Checked
thumbnails have a grey overlay and a white check in a blue circle at bottom
right. Taps, range sweeps, scrolling and drawer position are retained. The
unused full-library select-all task and collector have been removed.

The user confirmed that this appearance looked good on the phone, then requested
the floating count only in Select mode. That follow-up is implemented at
`01317f94`: Browse has no count badge, and cancelling selection hides it again.
The count reads checked membership directly, without sorting the source index.

## Software validation

- Test-first UI verification failed against the old All/None controls, fixed
  header position and Done label, then passed with floating Select/X controls.
- Focused model/reducer/discovery/grid checks and the selection UI flow passed.
- Fresh code review identified one badge/check overlap at large text sizes;
  the existing badge test reproduced it before the fix, then all nine grid
  unit cases passed after reserving space for the check.
- The complete simulator gate for the selection implementation and corrected
  range-test setup passed **439 tests, 3 established opt-in skips, 0 failures**,
  exit 0. The skips remain native Home, hardware keyboard and rotation gates.
  The two-worker run used the ordinary project scheme with verbose failure
  diagnostics disabled, which avoids Xcode stalling while gathering sysdiagnoses.
- The later count-only refinement passed all three focused UI cases: floating
  selection/cancel, largest text layout, and manual collapse retaining checks.
  This refinement has focused coverage in addition to the preceding full gate.
- Final unsigned Release simulator builds passed for arm64 and x86_64. The
  final signed iPhone build passed using the existing local development
  profile, and `codesign --verify --deep --strict` succeeded.

Removing the old header increases the photo viewport, exposing letterboxing
beneath the floating recipe/version buttons. XCTest's automatic hit-point
heuristic reports those buttons obscured even though screen taps open the
menus. The large-text test now exercises actual opening/dismissal through the
existing coordinate-tap helper, while retaining Export hit testing and
pinch/fit assertions. Both the original baseline and the final interaction
checks were run; no viewer behavior change was made for that test artifact.

The range UI fixture now selects its starting photos through taps rather than
All. Its expected viewed photo is therefore the final setup tap, source-2;
the sweep still must preserve that identity while changing membership.

Local evidence is retained under ignored `.build/photos-selection/`:
`verified-suite.xcresult`, `count-mode.xcresult`, the RED/GREEN inspection
results, Release/phone build logs, and exported light/dark/large-text screenshots.

## Phone validation

Both the initial tray update and final count-only refinement were installed and
ordinarily launched on the connected iPhone 15 Pro. The final phone package
contains the count refinement. The user confirmed the first appearance before
requesting that refinement. This validation performed no camera operation or
Photos export and made no signing-account or provisioning changes.
