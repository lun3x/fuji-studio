# Fuji Studio acceptance record

Recorded 2026-10-27. **Device acceptance is incomplete.** Software verification and
physical observations are separate below. The current app cannot yet be claimed
fully accepted on the target hardware.

The software baseline entering this task is `fd94d301e5aa548758ac0e4082da59da9ed03a79`
(Task12 accepted composition and fixes). Physical production/local-RAW observations
were made on reviewed `88996b743435`, not the later composition. The final Task13
checkpoint is the commit containing this record; its exact ID and local runner
artifacts are retained in the ignored Task13 implementation report.

## Environment and reproducible software gate

- Xcode 27.1, build 27A9275; XcodeGen 2.46.0; Swift 6; deployment target iOS 27.0.
- Simulator: iPhone Duo, iOS 27.1, destination UUID `5277B203-F40D-4AEF-98E9-164D7C653887`.
- Observed physical target: iPhone 15 Pro, iOS 27.0.1; Fujifilm X-T5 firmware 4.31.
- Camera mode: USB RAW CONV./BACKUP RESTORE, direct USB data cable. Processing is foreground only.
- Physical Full Photos Access and Camera Allow were already granted. This software phase requested no permissions and operated no physical device.

```sh
Scripts/test-ios.sh
xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Final software result: **419 passed, 3 explicitly skipped; Release build passed**.
The complete runtime gate contains 384 Swift Testing cases in 49 suites, 11 native
XCTest unit cases, and 27 UI cases (24 passed, 3 skipped: native Home, rotation and
hardware keyboard). It finished with exit 0 / TEST SUCCEEDED. Raw unsafe-SQLite
unlink/API-violation/open-fd matches: **zero**.

The exact final complete invocation was:

```sh
xcodebuild test -project FujiStudio.xcodeproj -scheme FujiStudio -destination 'platform=iOS Simulator,id=5277B203-F40D-4AEF-98E9-164D7C653887' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/task13-full-simulator-final.xcresult -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
```

This is equivalent to the wrapper's complete scheme/settings, with automatic
failure diagnostics disabled. The first wrapper run exposed one stale historical
recipe-support test expectation; owner triage corrected the test and preserved
unknown-film rejection. Its runtime failure and interrupted automatic diagnostic
collector remain recorded in the implementation report.

Release first exposed a missing direct PhotosUI import for the limited-library
picker. Adding that import was the only code change after the passing runtime
gate; it changes compiler namespace visibility, not behavior. The exact Release
command above then finished with exit 0 / BUILD SUCCEEDED for arm64 and x86_64.
The built binary contains none of the new DEBUG route/driver/private-directory
strings or FixtureEnvironment name. No extra UI rerun was made for that
compiler-only import correction.

Logs: ignored `.build/task13-full-simulator-final.log`,
`.build/TestResults/task13-full-simulator-final.xcresult`,
`.build/task13-release-simulator-final.log` and
`.build/task13-release-debug-exclusion.json`. All failed attempts, commands and
actual exit codes remain in the ignored Task13 report. The run still emits
separately classified toolchain/simulator notices and expected invalid-RAW decoder
diagnostics; “passed” is not a claim of a warning-free runtime.

Focused M3–M7 triage passed 54 Swift Testing cases across Catalog,
ExportCoordinator and AppModel, plus 14 UI cases: 12 passed and two existing native
rotation/keyboard skips. Raw log scanning found no `vnode unlinked while in use`,
`database integrity compromised by API violation`, or `invalidated open fd` after
the test-store lifetime correction. The earlier reproduction passed assertions
but emitted those real diagnostics; it was not a clean store-lifetime pass.

Catalog-bearing test roots now survive the test process for OS/sandbox cleanup.
This preserves real disk/reopen/journal assertions without unlinking live
SwiftData stores. Ordinary rendering-only cleanup remains unchanged. The viewer
zoom regression now requires finite metrics before every comparison; drawer tests
assert the intended detent; recipe blank-padding taps are covered; scope narrowing
is exercised while a real coordinator item waits in original preparation with a
previous completed item retained.

The DEBUG live route guards have runtime RED/GREEN evidence for malformed/mixed
flags, durable claims, retained resource discriminator/filename changes, and fresh
current-session bank imports. Missing/corrupt receipts or a claimed run without a
recorded job produce zero camera connections, renders or saves in synthetic
integration tests. These tests do not claim the live physical sequence ran.

## A01–A24 traceability

“Software covered” means the implementation has the named automated evidence;
it does not replace the physical column. “Partial” physical evidence applies only
to the exact retained inputs, firmware and observed operation.

| Check | Software evidence | Physical status and remaining proof |
| --- | --- | --- |
| A01 paired RAF retrieval | Resource selection/discovery/transfer tests preserve primary/alternate originals as one source. | **Partial:** actual paired B alternate RAF and primary JPEG identity/revision/hash verified. Limited/cloud variants remain open. |
| A02 mixed standalone/pair batch | ExportCoordinator frozen mixed-source tests; one original payload at a time. | **Partial:** actual production A–B–A supports both retained input identities. A real mixed export job remains unrun. |
| A03 seven recipes, unchanged banks | Atomic catalog/import tests and live-driver fresh-session assertions. | **Partial:** earlier seven-slot diagnostic and production C7 A–B–A preserved seven names and 23 raw fields. Current live composition C1–C7 proof pending. |
| A04 original default/clear, zero preview saves | AppModel/reducer/preview tests; no-recipe Export disabled. | **Partial:** genuine paired local RAW decoded on reviewed build. No-recipe standalone RAW, paired JPEG and all-seven live previews pending. |
| A05 late render/navigation safety | PreviewCoordinator, WorkspaceState and AppModel generation/revision/manual-version regressions. | **Not run:** fast interaction with real camera/live library. |
| A06 independent version choices/labels | Version resolver, native viewer and AppFlow tests. | **Not run:** actual saved export version switching in current live composition. |
| A07 restart associations/equal dates | Disk catalog reopen and equal-date identity tests; canonical recovery/version refresh tests. | **Not run:** real Photos save then process relaunch/reconnect to the same version. |
| A08 viewed source without Select | AppModel/AppFlow browse export and effective-selection tests. | **Not run:** one deliberate viewed paired-B export through current live model. |
| A09 Select/Done/All/None/sweeps | Reducer, full metadata All, grid controller and UI sweep tests. | **Not run:** physical long-library interactions. |
| A10 unchanged thumbnail geometry | Native controller/hosting/UI geometry assertions across selection modes. | **Not run:** target phone inspection. |
| A11 square vertical rows/two collapsed rows | Native layout and long synthetic grid tests with measured bounds. | **Not run:** physical long-library scrolling/layout. |
| A12 drawer overlay/framing | Measured native hosting/UI tests, actual viewport resize and literal detents. | **Not run:** physical drag/accessibility interactions. |
| A13 no automatic collapse/viewed reveal | Expanded browse/Select tests and manual-collapse visibility checks. | **Not run:** physical camera-preview navigation. |
| A14 detail/zoom/version region/reset | Actual UIKit viewer tests with required finite metrics, detail leases and source reset. | **Partial:** upright genuine paired RAW display observed. Physical pinch/pan/detail comparison remains open. |
| A15 floating recipe menu | Native selection/clear/outside dismissal, blank-padding taps and accessibility-size tests. | **Not run:** native hardware Escape; simulator synthesis did not deliver Escape or independent control key. |
| A16 frozen original-RAF job | Mixed-job, cache identity, source revision and immutable snapshot tests. | **Partial:** production A–B–A used real retained originals and one frozen C7. Real mixed Photos batch pending. |
| A17 full FINE geometry/orientation/fidelity | Strict production profile/JPEG verification and complete output validation tests. | **Partial:** actual 7728 × 5152 FINE/orientation 8 production outputs; same-A C7 reference comparison. No paired-B Mac reference or broader format/firmware/lens proof. |
| A18 new Photos asset/source preserved/date/location | Real writer gateway contract, journal and original-resource tests. | **Not run:** actual one-save bytes/new identity/date/location/source checksum proof. |
| A19 Date Captured chronology | Writer preserves effective Photos capture date. | **Not run:** Photos chronological UI observation. Equal-time tie ordering is not controlled or promised. |
| A20 cancel/retry/uncertain save | Durable crash-window, exact operation lookup, reopen/pin and no-replay tests. | **Not run:** real uncertain-save/cancel/retry/reconciliation. |
| A21 actionable failure states | Authorization/cloud/storage/transport fixtures and live model UI states. | **Partial:** historical real transport/reconnect investigations and incompatible X-E3 rejection. Current app limited/cloud/wrong-mode/disconnect matrix pending. |
| A22 suspension preserves truthful outcome | Deterministic injected-scene, admission, held-save and recovery tests. | **Not run:** real phone Home/interruption. Strict simulator Home boundary failed to reach background and remains an explicit default skip. |
| A23 orientation/accessibility controls | Measured largest-text/dark/compact viewport native tests; actual fit/zoom/control taps. | **Not run:** native rotation, VoiceOver, Reduce Motion/Transparency and increased-contrast physical checks. Synthetic resize is not native rotation evidence. |
| A24 bounded operation/scrolling/zero saves | Shared pool/scheduler/cache, sequential export, synthetic grid and preview no-writer tests. | **Not run:** Instruments on a mixed corpus of at least 50 sources. No physical memory/latency/scrolling thresholds are claimed. |

## Existing physical evidence and support boundary

The reviewed production run completed three C7 operations A–B–A with complete
FINE JPEG decoding/Exif geometry 7728 × 5152, orientation 8, and byte counts
26,369,498 / 26,130,950 / 26,371,588. Requested lens optimization ON was effective
OFF with adjustment reported. The A key was unchanged; B was distinct; all seven
banks were unchanged; exact owned-output deletion/empty acknowledgement and
native close were confirmed. No Photos writes occurred. The independent offline
verification passed 91 assertions against private retained files/journals.

Earlier all-seven diagnostic comparison on the same retained standalone input
had 181 exposed metadata comparisons with no mismatch, and each output was
spatially closest to its own Mac reference. The newer production same-A C7
matched 26 exposed tags and five code tables; residuals fit measured vendor
repeat variation. This does not prove visual fidelity for paired B (no Mac B
reference), or general firmware, lens, compression and aspect support. The
retained standalone source is lossless-compressed 14-bit, 3:2, orientation 8.
Opaque uploaded-RAW buffer lifetime remains unknown.

Private artifacts are retained only in ignored `.build` and `.superpowers`
locations: `task12-local-raw-*`, `task12-production-acceptance-*`, the production
camera diagnostics and the independent Task12 verification report. Public docs
exclude personal source IDs, hashes, filenames, profile names and settings.

## Controller-only remaining validation

After independent review, build/install the reviewed checkpoint and launch the
DEBUG route `--live-acceptance-run <explicit new UUID>` once. Keep the retained
standalone/pair/bank manifests in the app sandbox. The route rejects mixed
fixture/probe flags before constructing live services and uses the one real
AppEnvironment/AppModel already displayed by AppEntryView.

The driver checks exact retained roles, revisions, descriptors and live RAF hashes;
requires current imported banks to match retained names/settings; displays genuine
no-recipe A RAW and B JPEG; retains seven sequential same-A preview files; checks
that the native photo identity set is unchanged; then retains actual paired-B C7
CameraJPEG and its live lease while calling the model's viewed-source export once.
It verifies the new PhotoKit operation/asset, exact original bytes, dimensions,
date/location, original source checksums and saved-version association. It does
not delete any user Photos asset.

The UUID claim and export intent are synchronized to disk before export. An
existing UUID never invokes export or conversion, even if the earlier process
died before a job ID was recorded. Known jobs can reconcile and verify read-only;
unknown outcomes stop without replacement. Relaunch the same UUID after a real
process termination to obtain actual reopened-catalog evidence. Preserve its
private directory and catalog; do not erase state or substitute a fresh UUID as
a retry. A partial first run remains incomplete even if its saved output later
verifies. Root records actual results before this matrix is promoted.

Native Photos chronology UI may remain unobserved if viewport interaction is
unavailable; exact date/location proof must be reported separately. The driver
does not substitute for real Home/disconnect/uncertain-save tests, VoiceOver or
the mixed-50-source Instruments run. Record peak resident memory, one-item RAW
temporary size, JPEG cache size, first/cached preview latency, per-stage export
times and scrolling behavior on that corpus. Those measurements are **not run**;
no numbers, thresholds or passes are inferred from synthetic fixtures.
