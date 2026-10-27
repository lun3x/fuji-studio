# Fuji Studio acceptance record

Recorded 2026-10-27. **Software review is clear at `86eacb7a`; device acceptance
is incomplete.** The original physical preview/export/reopen and later human
interaction evidence belongs to `75fbd61b`. A later ordinary-app two-source C3
mixed batch passed on `86eacb7a`; a C4 Home interruption is paused with recovery
still in progress. These bounded results do not establish complete product
acceptance.

The accepted app composition entered Task13 at `fd94d301`. Earlier paired local
RAW and production C7 A–B–A observations used reviewed `88996b74`. The recorded
live run used independently reviewed `75fbd61b`, which the controller built,
signed, verified, installed and launched. Exact run identities, signing records,
source values and artifacts remain in ignored private evidence.

## Environment and software evidence

- Xcode 27.1, build 27A9275; XcodeGen 2.46.0; Swift 6; deployment target iOS 27.0.
- Observed simulator: iPhone Duo, iOS 27.1.
- Physical target: iPhone 15 Pro, iOS 27.0.1; Fujifilm X-T5 firmware 4.31.
- Camera mode: USB RAW CONV./BACKUP RESTORE, direct USB data cable. Processing is foreground only.
- Full Photos Access and Camera Allow were already granted. All physical actions were controller-owned; implementation workers did not operate devices or write to Photos.

Reproducible commands, selecting an available simulator on the local machine:

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' Scripts/test-ios.sh
xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

### Current code gate and review clearance

The final runtime revision `86eacb7a43b3e11087dc11a0afdcb4db86324560` passed
one complete simulator gate after all five integration corrections: **433 passed,
3 established skips, 0 failures**. This comprises 396 Swift Testing functions in
50 suites, 11 native XCTest cases and 29 UI cases (26 passed, 3 skipped). Exit 0 /
TEST SUCCEEDED. The skips remain native Home/background, device rotation and
hardware Escape delivery; none counts as physical proof. The subsequent unsigned
Release simulator build passed, exit 0 / BUILD SUCCEEDED, with universal arm64
and x86_64 output. No runtime changes followed these gates.

The single scoped re-review of the correction package closed all five findings:

| Corrected integration seam | Verified behavior |
| --- | --- |
| Restart-visible retryable jobs | Failed/cancelled/unprocessed items remain discoverable; explicit Retry or Resume processes only remaining items, retaining frozen identity and confirmed saves. |
| Labelled preview fallback and error | The matching source/revision/version/file lease remains visible, or the current source's original resolves without a camera retry; the full actionable error is accessible alongside the image. |
| All directly from Browse | The actual enabled All control enters Select with complete eligible membership. |
| Detected RAW incompatibility | Shared revision-scoped knowledge reaches reload, All and export admission without eager RAW downloads or frozen-job mutation; a changed revision is reassessed. |
| Cancellable preparation and progress | Obsolete PhotoKit preparation cancels and cleans up before ownership is released; current progress is visible, and admitted native camera work remains owned and awaited through completion. |

The verdict was **APPROVED: I1–I5 addressed; 0 Critical, 0 Important, 0 Minor new
findings**. Software review is clear for integration; the branch remains unmerged
and main remains at `b53723cd`. This is not release acceptance. Exact commands,
RED→GREEN history and the full review remain in ignored `final-fix-report.md`
and `final-fix-review.md`. Current raw evidence is
`.build/TestResults/final-fix-full.log`, `final-fix-full.xcresult` and
`final-fix-release.log`. Review found zero unsafe SQLite unlink/API-violation/
open-fd pattern matches in both current logs. Known AppIntents/SDK/simulator
notices are not claimed absent.

The controller subsequently signed exact `86eacb7a`, verified its code signature
(exit 0), and installed it successfully on the physical phone. Normal launch
while the phone was locked timed out after 20 seconds (exit 2). The user then
reported the phone unlocked and Fuji Studio open. The controller then directly
observed the exact installed build in the normal Photos route: light theme, live
photo thumbnails with RAF and RAW+JPEG badges, camera disconnected, Browse with
selection count 0, All enabled and None disabled. This confirms **launch and
library UI loading only**. Device Hub remote clicks on All and a paired thumbnail
produced no visible state transition; they establish no current physical
selection/version-interaction pass, and no cause is assigned. No additional
Photos writes or native conversions were performed during that launch check. The earlier physical
interaction and native evidence below retains its original revision and limits.

### Earlier software chronology

The earlier complete software gate passed **419 tests, 3 explicitly skipped**:
384 Swift Testing cases in 49 suites, 11 native XCTest unit cases, and 27 UI cases (24
passed, 3 skipped: native Home, rotation and hardware keyboard). Exit 0 / TEST
SUCCEEDED; all three unsafe SQLite unlink/API-violation/open-fd counts were zero.
The equivalent final complete invocation used the wrapper's scheme/settings
with `-collect-test-diagnostics never` and no selectors. Its exact destination
and command are retained in the ignored Task13 report. The first wrapper run
exposed a stale historical recipe-support expectation; test-only owner triage
preserved unknown-film rejection. That failed run and its interrupted automatic
diagnostic collector remain recorded.

Release initially exposed a missing direct PhotosUI import. That compiler-only
import was added after the complete runtime gate; the Release command then
passed for arm64 and x86_64, with the DEBUG route/driver/private-directory strings
and FixtureEnvironment name absent from the binary. These are the software-phase
results at `56410f7d`, not fresh whole-suite/Release runs after later fixes.

Two independently reviewed DEBUG validation corrections followed:

| Revision | Correction | Targeted result |
| --- | --- | --- |
| `a5023386` | Authoritative camera-service close outcome and uninterrupted foreground completion; an already-satisfied wait cannot bypass suspension. | 42 test functions in 3 suites passed, exit 0. |
| `75fbd61b` | Respect standalone A's actual historical schema; require paired B's recorded descriptors; capture separate LIVE descriptors and recheck source equality before/after materialization. | 17 test functions in 3 suites passed, exit 0. |

Both fixes have observed runtime RED→GREEN evidence. The second reproduced the
actual first device-run failure. Full-suite/UI/Release reruns were not performed
for these scoped DEBUG corrections. The controller subsequently signed and built
the exact reviewed second revision for the successful physical run.

Earlier M3–M7 triage passed 54 Swift Testing cases plus 12 UI passes and two native
skips. Catalog-bearing test roots now survive the test process for OS cleanup,
preserving real disk/reopen assertions without unlinking live SwiftData stores.
Required finite viewer metrics, literal drawer detents, blank-padding menu taps
and actual held-preparation scope narrowing replace the deferred weak tests.

Logs and result bundles are ignored: `task13-full-simulator-final`,
`task13-release-simulator-final`, `task13-release-debug-exclusion`,
`task13-fix1-green` and `task13-fix2-green` under `.build`. Full commands, failures,
counts and diagnostic classifications remain in the Task13 report. Known
AppIntents/SDK/simulator notices and deliberate invalid-RAW decoder diagnostics
are not claimed absent. Final complete and targeted logs contain zero unsafe
SQLite warning patterns.

## Current native mixed batch and interruption

The ordinary physical app at `86eacb7a` completed one C3 export job containing
the known standalone RAW and RAW+JPEG sources: **2 saved, 0 failed, 0 cancelled,
0 remaining, 0 unconfirmed**. Both visible status and human report agree with
the copied catalog's one new job and two distinct saved associations. Native
records bind the frozen recipe, exact retained source hashes, full FINE geometry,
candidate readbacks and owned-output cleanup. One source used its cached preview;
this is not a two-fresh-conversion performance run. Original resource descriptors
and the previous saved job/version remain unchanged.

A separately deliberate C4 job was interrupted with physical Home and reopened:
**0 saved, 2 remaining**, with an uncertain timed-out camera operation and confirmed
native close. The app retained the existing job, blocked Resume until camera
readiness, and created no additional saved version. Explicit camera reconciliation
and remaining-item recovery are in progress. This is camera uncertainty, not an
observed uncertain PhotoKit transaction. See the [native validation record](native-batch-recovery.md)
for the exact scope and remaining proof.

## Original `75fbd61b` live run and evidence boundaries

The first explicit run stopped on a missing `rafDiscriminator` field in the
historical standalone manifest. Its durable claim remained consumed;
`exportArmed=false`, no job ID, zero previews and no camera/export actions were
recorded. The historical capture had never contained that field. The reviewed
correction preserved its identity/revision/role/name/hash/geometry proof and
captured the current descriptor separately, without rewriting retained evidence.
Only after this unarmed failure was verified did the controller deliberately
choose a new run. There was no automatic retry or replacement save.

The second run completed on `75fbd61b` through the one real AppEnvironment,
AppModel, preview/export coordinators and catalog:

- Original defaults: genuine standalone A RAW display and paired B original JPEG; A's retained display independently decodes to upright 1366 × 2048, orientation 1.
- Seven sequential A previews: the native Photos asset identity set stayed unchanged. Every current C1–C7 name/imported-name bytes and all 23 raw settings matched the retained banks before and after.
- One viewed-source export: Browse mode, without Select, exported the actual paired-B C7 preview as one distinct new Photos asset. Its complete camera JPEG is FINE 7728 × 5152, orientation 8, 26,127,706 bytes. The actual preview lease/CameraJPEG was retained through byte comparison.
- On-device verification: materialized saved original JPEG bytes matched that preview; source capture date matched; original A/B RAF and B JPEG hashes/descriptors remained unchanged; operation, saved version and source association matched; authoritative native close succeeded.
- Location: both source locations were absent. This verifies **absence preservation only**, not a real nonnil GPS-coordinate case. No GPS tags were present in the retained B output.
- Same-run reopen: the controller terminated and relaunched with the same UUID. Read-only verification reopened the exact saved association without resaving. Receipt, job and version remained identical; all 40 files in eight camera-operation journals were byte-identical, with zero new camera operations/files.

**Total actual Photos exports across both attempts: one.** No user Photos asset
was deleted. The failed first run remains preserved and consumed.

Independent offline verification passed **156 assertions**. It recomputed all
eight retained output hashes, source/bank/key/profile bindings, candidate/readback
identity and native operation cleanup evidence. Each of the seven new same-A
previews matched its Mac slot reference in all exposed tags (25–27 per slot,
zero mismatches) and all five coding/table segments; each ranked its own slot
nearest spatially. C2/C7 residuals closely match their measured vendor repeats.
C5 has no own-slot repeat; no pixel-perfect or universal fidelity claim follows.
See [protocol provenance](protocol-provenance.md#task13--current-production-seven-slot-comparison)
for the current measurements and limits.

The asset-set check, exact saved PhotoKit bytes, capture date, absent location,
unchanged originals and native closure are reviewed **on-device coded
observations**. The temporary saved-asset materialization was removed after its
comparison; no separately retained Photos original exists for a second offline
hash assertion. Offline inspection verifies the retained preview and saved
records, not a new PhotoKit query. Export time is not substituted for capture date.

The controller also viewed the physical phone through Device Hub screenshots:
an upright B image, RAW/original-JPEG/saved-C7 labels, a two-row drawer and the
read-only reopen status. The validation route disables workspace controls, so
these are visual observations, **not manual gesture, menu or accessibility proof**.

### Later ordinary-app interaction observations on `75fbd61b`

After the recorded reopen interval, the controller launched normally with no
validation flag. Actual coordinate taps worked; the earlier remote-input blocker
was not reproduced, and its cause is unknown. The controller directly viewed the
returned phone images; no new local screenshot file is claimed for these checks.

- Paired B showed its original JPEG and own saved C7 version. Select added checkboxes with a visually unchanged two-row square grid. All selected 761 eligible sources; None returned the count to zero. This was selection only, not a 761-source export or performance run.
- Expand showed four rows over most of the viewer. Done returned to Browse; tapping standalone A kept the drawer expanded. Manual Collapse kept A's tile visible. A showed its genuine RAW image.
- Zoom+, Fit and double-tap visibly zoomed/reset the image. Pinch, pan and precise image-region/detail preservation were not proved by these actions.
- The floating picker displayed seven slots, including one legitimately unnamed slot. Selecting C3 and connecting normally reached Camera Ready with a visible color Temporary Preview and Export enabled for one viewed source outside Select. Manually choosing RAW changed the image while C3 and Export stayed selected/enabled; returning to Temporary Preview worked. No Recipe cleared C3, restored RAW and disabled Export while the camera remained ready.

No Export was tapped during these ordinary checks: total Photos exports remain
one. Two remote drag attempts across/between rows selected only an endpoint, and
one wheel attempt produced no scrolling. The user subsequently performed a real
finger sweep across thumbnails and the next row on the installed reviewed build
and confirmed: “All crossed photos become checked.” This supplies a bounded
**human-observed range-selection pass**, separate from the remote drag attempts.
The user then answered “Both work” when asked to confirm pinch zoom/pan of the
main photo and vertical scrolling of the expanded grid on the installed
`75fbd` build. This adds bounded human-observed pinch/pan and vertical-scroll
passes. It is not a physical check of the later final-correction code, a precise
region/detail measurement, or performance, rotation or VoiceOver evidence. No
cause is assigned to the earlier remote-input result.

These later interactions are outside the fixed 156-assertion audit snapshot.
Normal Connect/C3 preview may involve native or cached work; the earlier identical
journal tree proves zero new camera work only across the recorded read-only
reopen interval, not across all later interaction.

Private evidence includes `task13-live-run2-root-record.json`,
`task13-live2-first-complete-evidence.json`, `task13-live2-reopened-evidence.json`,
selected run/journal copies and `task13-live2-verification` under ignored `.build`.
The ignored independent verification report names the exact files and commands.
Committed documentation omits run/source/asset identifiers, personal filenames,
full hashes, profile values and media.

## A01–A24 traceability

“Software covered” does not replace physical proof. A bounded pass below applies
only to the observed inputs/context on the recorded revisions. Physical rows
refer to earlier evidence unless they explicitly identify the current-code C3
batch or C4 interruption. Unrelated variants remain open.

| Check | Software evidence | Physical status and remaining proof |
| --- | --- | --- |
| A01 paired RAF retrieval | Original-role selection/discovery/transfer tests keep a pair one source. | **Partial:** actual paired original roles/revisions/hashes verified, including the live conversion. Limited/cloud variants remain unrun. |
| A02 mixed standalone/pair batch | Frozen mixed-source tests; shared original pool. | **Bounded pass:** ordinary current-code C3 job saved the two known standalone/paired sources; one fresh render and one cached preview. Larger and broader batches remain open. |
| A03 seven recipes, unchanged banks | Atomic import/catalog and fresh-session assertions. | **Bounded pass:** current live C1–C7 imports/previews; all seven names and 23 fields preserved. Broader settings remain unproved. |
| A04 original default/clear, zero preview saves | Reducer/AppModel/preview tests; no-recipe Export disabled. | **Bounded pass:** original defaults and seven no-save previews passed; ordinary No Recipe restored RAW and disabled Export while camera-ready. |
| A05 late render/navigation safety | Generation/revision/manual-version regressions. | **Not run:** fast physical interaction with real camera/library. |
| A06 independent version choices/labels | Resolver, viewer and AppFlow tests. | **Partial:** saved C7 association/labels and ordinary RAW↔Temporary Preview switching observed without clearing C3/export eligibility. Broader independent version cases remain open. |
| A07 restart associations/equal dates | Disk reopen/equal-date identity and recovery tests. | **Partial:** actual same-UUID process relaunch reopened the exact saved version without resaving. Real equal-date cases remain unrun. |
| A08 viewed source without Select | Browse export/effective-selection tests. | **Bounded pass:** one deliberate viewed paired-B export through the actual model in Browse. |
| A09 Select/Done/All/None/sweeps | Reducer, metadata All and grid/sweep tests. | **Bounded pass:** ordinary Select/Done, All (761), None (0); user confirmed all crossed thumbnails became checked during a real finger sweep across the next row. Remote endpoint-only drags remain separate observations. |
| A10 unchanged thumbnail geometry | Native geometry assertions across selection modes. | **Partial:** two-row square grid looked unchanged when Select added checkboxes. Precise physical geometry measurement remains unrun. |
| A11 square vertical rows/two collapsed rows | Measured native layout/long synthetic grid tests. | **Partial:** two collapsed/four expanded rows observed. User confirmed expanded-grid vertical scrolling on installed `75fbd`; the earlier wheel attempt did not scroll. Precise layout/performance measurement remains unrun. |
| A12 drawer overlay/framing | Native hosting/viewport/literal-detent tests. | **Partial:** ordinary expansion overlaid most of the viewer and manual collapse worked. Drag/accessibility paths remain unrun. |
| A13 no automatic collapse/viewed reveal | Browse/Select and manual-collapse visibility tests. | **Bounded pass:** Done/source navigation kept the drawer expanded; manual collapse kept the viewed A tile visible. Broader navigation remains open. |
| A14 detail/zoom/version region/reset | UIKit viewer finite-metric/detail/reset tests. | **Partial:** upright RAW/B display plus actual Zoom+, Fit and double-tap zoom/reset observed. User confirmed real pinch zoom/pan on installed `75fbd`; exact region/detail comparison remains unrun. |
| A15 floating recipe menu | Native selection/clear/dismissal/padding/size tests. | **Partial:** actual floating seven-slot menu, C3 selection and No Recipe clear observed. Hardware Escape/accessibility remain unverified; simulator key synthesis did not deliver Escape or an independent control key. |
| A16 frozen original-RAF job | Mixed-job/cache/revision/immutable snapshot tests. | **Bounded pass:** current-code two-source C3 job retained exact source hashes and one frozen recipe through both saved associations. Physical recipe changes during active export remain open. |
| A17 full FINE geometry/orientation/fidelity | Strict profile/JPEG validation. | **Partial:** eight actual live FINE outputs and all-seven same-A Mac comparison passed. No Mac B reference or broader formats/firmware/lens proof. |
| A18 new asset/source preserved/date/location | Writer/journal/original-resource tests. | **Partial:** one new asset, exact bytes, original capture date and unchanged originals passed on device. Location absence preserved; nonnil GPS case remains unrun. |
| A19 Date Captured chronology | Writer preserves effective Photos capture date. | **Partial:** exact date equality passed on device; Photos chronological UI/tie ordering remain unobserved. |
| A20 cancel/retry/uncertain save | Crash-window/exact-lookup/pin/no-replay tests. | **Partial:** successful saved-run read-only reopen passed. Actual uncertain save, active cancellation and retry/reconciliation remain unrun. |
| A21 actionable failure states | Authorization/cloud/storage/transport fixtures. | **Partial:** historical transport/reconnect and incompatible-model refusal, plus explicit unarmed validation failure. Current app limited/cloud/wrong-mode/disconnect matrix remains unrun. |
| A22 suspension preserves truthful outcome | Injected-scene/admission/held-save/recovery tests; authoritative-close regression. | **Partial:** physical Home during the current C4 job left 0 saved/2 remaining; camera timeout/uncertainty and confirmed close were retained, with Resume blocked. Explicit reconciliation/resume remains in progress; disconnect/uncertain-Photos windows remain open. |
| A23 orientation/accessibility controls | Largest-text/dark/compact native tests. | **Not run:** native rotation, VoiceOver, Reduce Motion/Transparency, contrast and hardware-keyboard physical checks. Screenshot/resize is not interaction evidence. |
| A24 bounded operation/scrolling/zero saves | Shared pool/scheduler/cache and sequential-export tests. | **Partial:** seven physical previews produced no Photos assets. Mixed-50-source Instruments memory/cache/latency/concurrency/scrolling measurements remain unrun. |

## Support boundary and remaining validation

The observed context is two retained lossless-compressed 14-bit, 3:2,
orientation-8 sources on X-T5 firmware 4.31 in the measured lens/profile class.
Requested LMO ON produced effective OFF with the adjustment reported on all
eight outputs. Broader firmware, lens, aspect and compression support remains
unproved. No Mac B reference exists; B has identity/geometry/FINE/effective
metadata/save proof, without same-source Mac visual-fidelity proof. Opaque
uploaded-RAW buffer lifetime remains unknown despite owned-output cleanup.

Earlier diagnostic seven-slot and production C7 A–B–A evidence remains historical,
separate from the recorded `75fbd61b` live run. It is not relabeled as additional
Photos exports. Full acceptance still requires the open physical rows above and
Instruments on at least 50 mixed sources: peak resident memory, one-item RAW
temporary size, JPEG cache size, first/cached preview latency, per-stage export
times and scrolling behavior. No numeric performance promise or inferred pass
is made. The whole-branch review and its final scoped correction review are
complete; software review is clear. Final integration remains pending, and the
branch is unmerged.

## Controlled validation route

The DEBUG `--live-acceptance-run <explicit UUID>` route rejects mixed modes and
uses the one displayed live composition. It durably claims the run before any
export intent. Reusing a UUID never invokes export/conversion, including after a
death before job-ID recording. Known jobs can reconcile/verify read-only;
unknown outcomes stop without replacement. Preserve the private run and catalog;
never erase them or substitute a fresh UUID as an automatic retry. Any additional
physical write must be a separately deliberate controller action after review.
This route does not perform the remaining interruption, chronology, accessibility
or 50-source performance acceptance.
