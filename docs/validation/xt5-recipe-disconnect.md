# X-T5 recipe application disconnect, 2026-10-29

## Cause and introduction

Applying either an imported camera recipe or a phone recipe produced a valid
JPEG, then disconnected/reconnected the X-T5 and cleared the recipe selection.
Copied operation records from the connected phone show the rejection:
`lensOptimizer: requested true, observed false`. The affected records had already
validated the output, deleted only their owned temporary output, and verified
an empty camera object view before aborting and closing the session.

The regression first appears in `cabee195` (2026-10-28), which routes X-T5 through
the shared Fujifilm service. Its X-T5 adapter requires effective LMO to equal the
requested value. Before that change, `XT5WorkingProfile.effective` records the
measured source/lens adjustment from requested ON to effective OFF and accepts
the image. `d1ebe18a` subsequently moves the strict check into the shared output
assessor. Failed phone records include both X-T5 support versions v1 and v2, so
the later grain mapping correction is not the introduction point.

## Correction

Only the X-T5 adapter opts into accepting an observed LMO adjustment. The report
retains the requested value, actual JPEG value, adjustment flag, and JPEG
evidence. Missing LMO metadata and other recipe mismatches remain failures;
X-E3 retains strict LMO validation. Camera transaction ownership and cleanup are
unchanged. A successful adjusted output now completes with the same session
context and returns the camera to ready.

The historical production diagnostic still requires effective LMO ON for its
explicit acceptance experiment. Its test now checks that an adjusted output is
recorded before that stricter diagnostic stops after one trial.

## Validation

- The new service regression failed with `invalidOutput` for effective LMO OFF
  before the fix and passed afterwards for both ON and OFF. It checks effective
  reporting, completed journal, unchanged context, ready state, one owned cleanup,
  and no session close during rendering.
- All 110 core tests passed. Other-film mismatch rejection is tested with LMO
  OFF, and a real JPEG fixture verifies that X-E3 LMO mismatch remains rejected.
- An offline check used seven retained failed phone JPEGs, verified their
  recorded checksums, and recovered each requested recipe from an earlier
  successful record with the same settings digest. All seven passed the actual
  X-T5 JPEG validator and corrected assessor with adjusted LMO OFF. Private
  records, image files, and the temporary check are not committed.
- The initial full iOS attempt exposed the diagnostic's stale zero-trial
  expectation and was stopped. After updating that assertion, all 488 Swift
  Testing tests and 19 XCTest unit tests passed. The complete
  `Scripts/test-ios.sh` run then passed: 579 tests total, 576 passed, no failures,
  and three existing native-device gates skipped (Home backgrounding, physical
  rotation, and hardware Escape delivery). All 69 enabled UI tests passed.
  Result bundle: `.build/TestResults/20261029-125808-49770.xcresult`.
  The isolated task simulator was shut down and deleted after validation.
- Independent code review found no actionable issues.
- A physical-iPhone Release build succeeded with automatic Apple Development
  signing and team `AZH3P824F3`. The resulting
  `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` passed
  `codesign --verify --deep --strict`; its bundle and team identifiers match the
  existing application. At the user's request, that exact bundle was installed
  on the connected physical iPhone and launched normally as
  `com.lun3x.FujiStudio`, without fixture or test arguments. A subsequent process
  listing confirmed the installed bundle was running.

No new physical-camera transaction is claimed by these checks.
