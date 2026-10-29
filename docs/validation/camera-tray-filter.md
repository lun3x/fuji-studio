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
- Complete unit/UI suite at `7c707b09`: **564 passed, 3 established native opt-in
  skips, 0 failures**, exit 0. This comprises 480 Swift Testing tests, 19 XCTest
  unit tests and 65 passing UI cases. Result bundle:
  `.build/TestResults/20261029-093252-3869.xcresult`.
- The final screenshot/copy follow-up adds full-screen landscape attachments and
  corrects the singular failure label. Both affected landscape UI cases passed;
  the final singular-label revision passed the both-orientations case again.
  The Release build passed again after this copy correction.

An expansion test originally used a moving coordinate; its geometry wait resolves
that automation issue. An overlapping local test runner invalidated a follow-up
run; the four initial cases above were rerun sequentially after restarting only
this task's simulator.

Local logs, xcresult bundles and generated fixture screenshots are under
`.build/camera-filter` and `.build/TestResults` in the workspace. Inspected
screenshots cover the native menu, active X-T5 results, dark X-E3 selection and
empty state. Full-screen landscape captures were inspected in both orientations:
the status capsule stays within the tray and beside the filter, the controls
remain upright, and the expanded menu remains usable. Native captures are under
`.build/camera-filter/native-screens` and `.build/camera-filter/final-screens`;
app-only screenshot cropping is unreliable across rotation.

## iPhone installation

On 2026-10-29, built feature revision `ed9d2b4c` in Release for the connected
physical iPhone 15 Pro using the existing automatic-signing team `AZH3P824F3`
and `Apple Development` identity. The build passed. The exact resulting
`.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` passed
`codesign --verify --deep --strict`; its bundle and team identifiers matched.
`devicectl device install app` completed successfully, followed by a normal
launch of `com.lun3x.FujiStudio` with no fixture/probe arguments. A subsequent
process query confirmed the installed app was running. Local build, signature,
install and launch logs are under `.build/camera-filter/phone-*.log`.

## Bounds

This verifies simulator behavior using generated pixels and synthetic metadata.
Physical attachment, real iCloud download timing and very large-library
performance are not established by these checks. Existing camera compatibility
rules are unchanged. No physical camera conversion or Photos export was run for
this feature. The task simulator was shut down and deleted after final validation;
its absence was verified with `simctl list devices`.

## Placement follow-up

The user requested the filter immediately left of Select in portrait and below
Select in either landscape direction, with the selection count back in its
original leading corner. Revision `26cbb71d` groups filter/Select at the trailing
edge and reserves the original leading slot for the count. Checking/failure
status follows the relocated filter group.

Work took place in `/tmp/fuji-studio-filter-placement-20261029`, based on the
previously installed filter branch. The existing native placement case was
extended to check the 12-point control gap, the count's original 12-point
portrait inset, both landscape directions and menu access. It failed against
the old layout, then passed with the correction. The other affected camera
filter/status and dark selection cases passed. Full-screen landscape captures
were inspected, and a fresh read-only code review found no material issues.

The complete unfiltered project scheme passed with Xcode's parallel testing
override and three isolated workers on a task-specific iPhone 15 Pro / iOS 27.0
simulator: **564 passed, 3 established native opt-in skips, 0 failures**, exit 0.
The result has no runtime warnings. Result bundle:
`.build/TestResults/filter-placement-full.xcresult`.

The signed Release build of `26cbb71d` passed with the existing team and identity,
and the exact app passed `codesign --verify --deep --strict`. It was installed
on the physical iPhone 15 Pro and launched normally after the user unlocked the
phone; a process query confirmed it was running. Follow-up logs and screenshots
are under `.build/filter-placement` in the new workspace.
The task simulator was deleted after validation; no matching devices remain in
either the normal CoreSimulator device set or Xcode's XCTestDevices worker set.
