# One RAW removal confirmation per batch — 31 October 2026

Multi-RAW exports previously deleted each original inside its save operation.
Each deletion requested separate iOS confirmation. Transient scene inactivity
also restored the normal idle timer, allowing a delayed confirmation to lead to
background suspension before the next conversion.

Exports now stage verified RAW+JPEG pairs and durable pending saves, retaining
the old assets and pinned JPEGs. Remaining conversions finish before one guarded
PhotoKit change block removes the originals together. Resume follows the same
order; passive recovery never deletes. The idle timer stays disabled through
transient inactive presentations and is restored on real backgrounding or after
the worker ends. An already admitted deletion is drained and all real results
are recorded, including when backgrounding occurs during confirmation.

Pair verification still checks exact RAW/JPEG hashes, JPEG decode/geometry,
metadata, resource identity and stable snapshots. The native transaction checks
every original and pair before issuing one `deleteAssets` call. Journal event
sequence replays owned insertions and confirmed atomic removals so album order
guards remain valid through split cleanup/retry; external order changes remain
protected.

## Regression evidence and review

- Repeated deletion, ignored native deferral and inactive idle timer tests failed
  before implementation (`/tmp/fuji-batch-pair-behavior-red.log`).
- Split album cleanup recovery failed before its journal-event fix
  (`/tmp/fuji-batch-album-recovery-red-2.log`).
- Independent final review found one Important lifecycle-admission gap during
  lengthy revalidation. Both cancellation and background regressions reproduced
  deletion after stop (`/tmp/fuji-batch-admission-red.log`). The owned coordinator
  now rechecks admission after verification/journaling, immediately before
  removal submission. No Critical or Minor findings remain.
- Final fast suite: **604 Swift Testing tests and 25 XCTest cases passed**
  (`/tmp/fuji-batch-pair-final-unit.log`). Covers one cleanup for two genuine
  RAW-only sources, interruption/resume before cleanup, true backgrounding after
  submission, revocation during revalidation, corrupt pair rejection, exact
  metadata/album guards and split cleanup recovery.
- Affected UI suites: **3 passed** (`20261031-095716-59918.xcresult`). Three RAWs
  finish conversions before held cleanup, stay awake during injected inactivity
  and complete without Resume. Existing single-pair and explicit recovery flows
  also pass. The fixture confirms app behavior, not native Photos dialog UI.

Review boundaries: actual Photos confirmation presentation requires a user
export on the phone. Final UI results are checked by the implementer; the
reviewer ran no builds. Historical feature behavior before `3f46bce2` has its
earlier reviews and validation records.

## Integration baseline

Current main (`5d8bb996`) is integrated. Main's day/tray/editor updates are
retained alongside export thumbnail tests. The pre-batch complete run recorded
**710 total, 706 passed, 1 failed, 3 skipped**
(`20261031-093440-46602.xcresult`). The existing largest-text editor test failed
while the common helper sent newline to an app without keyboard focus. The
helper now taps the visible Return key directly and waits for dismissal; the
final complete run includes that coverage.

The task uses the isolated **Fuji Batched RAW Cleanup** iPhone 15 Pro simulator,
`F5B3A3E1-038B-4BCC-AF36-5B356B25F17F`. Complete validation and the signed
Release rebuild were in progress at the implementation checkpoint.

## Final validation

The complete run finished with **717 total, 713 passed, 1 failed, 3 skipped**
(`20261031-100341-63145.xcresult`). All export, batch cleanup, lifecycle admission,
recovery, version-picker and settings checks passed. The editor keyboard-focus
failure from the integration baseline also passed after the helper correction.

The one failure was the existing
`WorkspaceAccessibilityTests.testLargestTextDoesNotOverlap` initial
`workspace.select.isHittable` assertion (line 37). It passed unchanged in the
isolated serial retry (`/tmp/fuji-batch-pair-accessibility-retry.log`). The
complete parallel run remains recorded as failed, not relabeled as passing.

Integration ruling: proceed with the user's requested PR merge with this
documented workspace accessibility flake. The same test passed in the baseline
and the unchanged serial retry; its static workspace fixture and hit-test are
outside the batch cleanup changes. Cost if that assessment is wrong: an
intermittent largest-text Select control issue remains. No app or test behavior
was changed for that isolated failure.

Both the integration-baseline and batched-cleanup task simulators were shut
down/deleted after validation. Xcode removed their worker clones; cleanup was
verified without changing other task simulators.

## Phone build

Code checkpoint `c9a32bce` rebuilt successfully in signed Release with development
team `AZH3P824F3` and automatic `Apple Development` signing. The exact bundle at
`.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` passed
`codesign --verify --deep --strict` and installed successfully on Louisphone.
The normal launch attempt was denied because the phone was locked (CoreDevice
10002). Requested unlock; no real-library creation or deletion was run by tests.
