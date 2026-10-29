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

## Separate output-metadata failure and explicit reset

A later report on 2026-10-29 involved a camera that continued flashing after
unplugging and switching its power off. The phone's latest three operation
records show two completed conversions followed by an acknowledged trigger and
an output handle, then `invalidOutput` before ObjectInfo/storage metadata had
been saved. This is a separate failure from the LMO mismatch above. The journal
recorded confirmed native closure; that does not establish that camera firmware
finished processing or recovered.

While the camera was stuck, macOS USB enumeration showed no Fujifilm device.
After the user removed/reinserted the battery, enumeration returned. One
read-only Mac session successfully read DeviceInfo and USB mode 6, observed an
empty object view, and confirmed native closure. No conversion or deletion was
performed by that probe. The rejected metadata was lost across the reset, so
the precise firmware-lockup cause remains unproven. Private phone records and
probe evidence are retained outside the repository.

At the user's request, metadata validation failures now retain a valid native
session, publish a connected attention state, and block further conversions.
The camera icon turns red; the existing status page shows the specific error
and a **Reset camera connection** action. Rejected ObjectInfo and storage
datasets are saved before decoding, bounded to 4 KiB each. Invalid handle
datasets are treated as metadata errors rather than native transport failures.

Reset is a single explicit lifecycle operation. It first reconciles missing
output or discards a failed temporary conversion only with same-session
ownership, an acknowledged trigger following an empty view, the exact handle,
recognized temporary storage, stable metadata, and two matching payload reads.
An exclusive deletion marker prevents replay. Discard evidence is separate
from the original rejected metadata, and discarded output never becomes a
successful render. If metadata or ownership cannot be trusted, reset still
tries one native close/reopen without deleting that output. It returns ready
only after a fresh empty view; otherwise the error remains visible. Real USB
loss, native transaction failure, and unconfirmed closure retain their existing
lifecycle handling.

Camera-core regressions cover retained errors, explicit reset followed by a
new render, persistent malformed metadata, unsafe/changed outputs, ambiguous
deletion, cancellation, and settling a previously unconfirmed native close.
These software checks do not prove recovery from firmware that no longer
enumerates over USB.

### Metadata captured on the updated iPhone build

The user reproduced a red-icon error while the session remained open. Two
rejected records report JPEG format `0x3801`, protection 0, roughly 25.2 MB,
unknown ObjectInfo dimensions 0/0, and association `0x0007`. A completed record
from the same camera/firmware reports association `0x0807`. The shipping X-T5
dialect accepted only 0 and `0x0807`, explaining this reproducible rejection
before storage or JPEG download. The original rejected bytes are now retained
in the journal, with closure honestly recorded as `notRequested`.

The X-T5 dialect now also accepts the observed `0x0007`. Storage identity,
JPEG geometry/quality/recipe validation, source provenance, and cleanup checks
remain mandatory; X-E3 is unchanged. The new shared-service regression failed
with `uncertainOperation` before this correction and passes for both observed
values afterwards. Unknown association 9 still stops before download/deletion
and retains the connected error state. All 120 core tests pass.

An initial parallel iOS validation exposed a test synchronization error in
`explicitCameraResetIsSingleFlightAndDoesNotReplayFailedPreview`: the test
asserted the camera call count after the UI progress flag was set, before the
camera API had necessarily entered. The test now waits for its existing held
reset barrier before checking the unchanged single-flight assertion. A focused
AppModel run and the subsequent complete unit run pass. Earlier interrupted
full runs are not counted as final full-suite validation.

The corrected signed Release bundle passed strict codesign verification and was
installed and launched normally on the physical iPhone. The user retried the
same photo and recipe and confirmed that the photo now renders successfully.
This verifies the reproduced metadata-admission case on the physical camera;
recovery from a firmware state that no longer enumerates over USB remains
unproven. Final complete iOS validation is recorded below.

### Final validation and delivery

- All 120 shared camera-core tests and 6 laptop-runner tests pass.
- Complete `Scripts/test-ios.sh` validation on the task's isolated iPhone 15 Pro
  simulator passed with the current two-worker runner: **604 logical tests,
  601 passed, zero failed, three existing native-device gates skipped**. The
  result tree contains 70 passing UI tests plus the three gates, including the
  new error → status → reset → fresh render flow.
- Result bundle: `.build/TestResults/20261029-150427-12167.xcresult`.
- Independent core/UI reviews found no remaining actionable issues after the
  lifecycle, selection-preservation, and synchronization corrections.
- The signed physical-iPhone Release bundle passed
  `codesign --verify --deep --strict`, was installed from
  `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app`, and was
  launched normally without fixture or test arguments. The user confirmed the
  formerly failing photo/recipe now renders.
- The task simulator and both native XCTest worker clones were shut down and
  deleted. The UI implementer's separate simulator was also deleted. Unrelated
  simulators were left untouched.

Changes are published in [PR #34](https://github.com/lun3x/fuji-studio/pull/34).
