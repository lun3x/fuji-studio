# Connected-camera tray filter validation

Date: 2026-10-29. Development bookmark: `codex/camera-tray-filter`.
Workspace: `/tmp/fuji-studio-camera-filter-20261029`.

## Behavior

Optional native floating glass menu with All Photos and a connected-model label:
Compatible with X-E3 / Compatible with X-T5. Unknown and unsupported originals
remain hidden while the filter is active. Assessments use the existing strict
camera source rules; they do not invoke USB conversion or Photos saving.
The viewer is preserved, hidden batch members are removed, and disconnecting
returns to All Photos. Selecting the compatible option again retries transient
failures while retaining successful assessments.

## Evidence

Isolated simulator: iPhone 15 Pro, iOS 27.0,
`C158548E-C358-47A3-B3FE-45FDA8DF71FE`. The installed iOS 27.1 runtime rejects
this device type, so the compatible 27.0 runtime was used. Xcode 27.1 toolchain.

- Baseline: 468 Swift Testing tests passed, plus the existing XCTest unit suites.
- Metadata assessment tests: RED missing API, then all 8 focused tests passed.
- Reducer and initial worker: RED missing behavior, then 479 Swift Testing tests
  passed along with the XCTest unit suites.
- Four initial native filter cases passed sequentially: X-T5 menu/strict mixed
  results and clearing, X-E3 batch pruning with preserved viewer in dark mode,
  empty results, and expanded landscape controls.
- Fresh independent code review found two material issues. Both were reproduced
  with failing tests: unavailable originals could not recover, and status text
  fell outside both landscape windows. After correction, all 52 AppModel tests
  and the both-landscape status UI regression passed.
- Unsigned Release simulator build passed for arm64 and x86_64.
- Complete final unit/UI suite: pending completion at the time of this draft.

An expansion test originally used a moving coordinate; its geometry wait resolves
that automation issue. An overlapping local test runner invalidated a follow-up
run; the four initial cases above were rerun sequentially after restarting only
this task's simulator.

Local logs, xcresult bundles and generated fixture screenshots are under
`.build/camera-filter` and `.build/TestResults` in the workspace. Inspected
screenshots cover the native menu, active X-T5 results, dark X-E3 selection and
empty state. Landscape geometry assertions pass in both orientations; native
screen capture is pending for the final visual check because app-only screenshot
cropping is unreliable across rotation.

## Bounds

This verifies simulator behavior using generated pixels and synthetic metadata.
Physical attachment, real iCloud download timing and very large-library
performance are not established by these checks. Existing camera compatibility
rules are unchanged. No physical camera conversion or Photos export was run for
this feature. The task simulator is shut down and deleted after final validation.
