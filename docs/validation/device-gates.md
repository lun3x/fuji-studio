# Device validation gates

Current status (2026-10-27): the entries below retain investigation chronology.
Later evidence supersedes early availability/firmware/pending-input statements.
The observed phone is iPhone 15 Pro on iOS 27.0.1; the camera is X-T5 firmware 4.31.
Reviewed `75fbd61b` completed seven temporary same-A previews, one viewed paired-B
Photos export and same-run read-only process reopen. Independent offline checks
passed 156 assertions. Gate5 now has bounded new-asset, byte, capture-date, absent
location and association proof; chronology UI and nonnil GPS remain open. Gate6 active
interruption, native gestures/accessibility and mixed-50-source measurements remain
unrun. See [acceptance.md](acceptance.md) for the current A01–A24 matrix and the
final section below for the actual run's scope. Earlier stages are not current
instructions to replay diagnostic camera operations.

## Gate 1 — actual Photos originals: PENDING

The controller observed successful original-byte retrieval on the installed `4246325e66e8ec06e8d7d249e1583c280ec52bec` build under full Photos access, including an X-T5 pair and standalone RAF. Limited-access, iCloud and cancellation experiments remain pending, so the full gate is not passed. Simulator tests are software evidence only.

- Intended phone: iPhone 15 Pro. Controller reports iOS 27.0.1 and Developer Mode enabled; pending on-device probe confirmation.
- Camera: Fujifilm X-T5. Actual firmware: **not yet recorded**.
- Build baseline: iOS 27.0, Swift 6, bundle ID `com.lun3x.FujiStudio`.
- Available simulator evidence: Xcode 27.1 (27A9275), iPhone Duo iOS 27.1. Not a hardware substitute.
- Signing/install: controller installed build `4246325e` for these physical Photos observations. This implementation worker uses unsigned simulator builds and made no Apple developer-account, provisioning or device-install changes.

Use the DEBUG **Hardware probe** from the app's initial screen. The probe lists public PhotoKit resource type discriminators, normalized original/adjusted roles, content types, filenames and available sizes without fetching bytes. Selecting **Retrieve and inspect selected originals** performs sequential original retrieval and reports actual byte sizes, SHA-256, X-T5 model verification, container/crop geometry, recorded aspect, crop origin and orientation. The controller verified that toolbar Inspect and Results work on the physical phone. Successful probe files are removed; cancelled/failed downloads remove partial files. The original-resource controls never start a camera workflow.

| Experiment | Access | Required observations | Outcome |
| --- | --- | --- | --- |
| SD-imported RAF+JPEG pair | Full | Both original resource roles/types/sizes, both byte retrievals, RAF identity/hash, X-T5 metadata; one source | Controller observed an existing X-T5 pair: JPEG 26,250,674 bytes and RAF 41,113,648 bytes. Full-resource retrieval succeeded. Import provenance remains to be recorded. |
| Standalone RAF | Full | No invented JPEG; RAF identity/hash and X-T5 metadata | Controller observed one RAF descriptor, no invented JPEG; X-T5 RAF 40,946,272 bytes retrieved and model verified. |
| Same pair and standalone | Limited | Only allowed IDs discovered, both originals still retrievable; change allowed set and rediscover | Pending |
| Cloud-evicted original | Full/limited | Descriptor retained before download, progress, original identity after download | Pending |
| Cancel cloud download | Full/limited | Cancellation outcome and partial-file removal; subsequent retrieval succeeds | Pending |
| Other Fujifilm model / renamed non-RAF | Either | Incompatible model or invalid-container error, no conversion eligibility | Controller observed an older X-E3 pair: both resources retrieved, then correctly rejected as incompatible. Renamed non-RAF experiment pending. |
| Recorded geometry | Either | Reference 3:2 X-T5 output 7728 × 5152; compare other recorded aspects/orientations and used compression modes | Both observed X-T5 sources: container 7872 × 5196, recorded 7728 × 5152, 3:2, crop top 21 / left 12, orientation 1. Other aspects/orientations/compression modes pending. |

Controller supplied these aggregate observations from physical probe screenshots kept only in ignored local build artifacts; no personal filename, local identifier, image or hash is committed. Gate 2 is incomplete; subsequent controller authorization observations are recorded below, with no successful session/PTP result. Record phone OS and actual camera firmware before further hardware experiments. Preserve redacted role/type/size and outcome evidence here; keep personal filenames, local IDs and images out of version control. Failure changes the investigation; it does not authorize dropping paired assets, reimporting, or substituting phone processing.

## Gate 2 — public USB PTP session: PENDING

Controller physical attempt on installed `b6d6013`: the user connected the X-T5 directly to the phone in the requested mode and explicitly approved OS Camera Allow. Mac Device Hub remained connected wirelessly. Connected-camera informational notices then appeared; multiple attempts expired at the previous 30-second connect deadline while notices were open. No successful camera discovery, session opening or PTP reply was observed. The driver was found to repeat native requests for already-authorized grants and time human waiting as USB work. Software now skips existing grants and starts USB timing only when authorization resolves and discovery begins; corrected physical flow remains to be tested by the controller. OS Camera Allow does not by itself establish completed ImageCaptureCore content/control authorization or PTP capability.

Later controller attempt on corrected `c0f793c`: human authorization completed and a real public USB PTP session opened, generation 1, USB vendor 1227 / product 764 (`0x04cb` / `0x02fc`). Read-only GetDeviceInfo then failed closed with `wrongTransaction(expected: 1, actual: 7)`. At that stage no decoded payload, firmware or response code had been established. The subsequent selector trace below resolved the exposed identity distinction.

Controller selector trace on installed `31f65cc` / app-reported iOS 27.0.1: sessionOpen generation 1, USB 1227:764; submitted and echoed command both type 1 / opcode 0x1001 / ID 1; context matched; raw response type 3 / code 0x2001 / wire ID 9 / 365 inbound bytes / no native error. The phase-A equality check still rejected 1/9. The corrected adapter now models framework-managed correlation and retains logical ID, observed wire ID and unchanged raw response separately. Its physical success retest and device-info/firmware decoding remain pending.

Task 2 supplies a DEBUG camera prerequisite section below Photos inspection/results and above the full source list. Camera discovery and ImageCaptureCore authorization begin only with **Discover and open public USB PTP session**. Select `USB RAW CONV./BACKUP RESTORE` on the X-T5 manually and record its firmware before starting. **Read standard PTP device info** sends only read-only standard GetDeviceInfo (`0x1001`). There is no camera reset, saved-bank write or card-object deletion. Original Photos inspection still works independently; toolbar **Inspect** invokes the same retrieval and **Results** presents selectable current Photos output with Done.

| Experiment | Required observation | Outcome |
| --- | --- | --- |
| Correct mode, connected X-T5 | Actual iPhone OS, firmware from camera screen, control/content permission statuses, discovering → opening → sessionOpen, generation, USB IDs, GetDeviceInfo response/transaction/payload length | Corrected f9a563c adapter accepted two 0x2001 GetDeviceInfo replies: logical 1/wire 11 and logical 2/wire 12, 365 bytes each. Decoded device info, firmware and detailed grants still pending. |
| Content/control permission denied or restricted | Authorization-required/denied state distinct from transport failure; no PTP request | Pending |
| Camera unplugged or invisible in mode | No visible session; explicitly record physical connection/mode, because framework absence alone cannot identify cause | Pending |
| Visible camera lacking USB PTP capability | Mode guidance; never conversion-ready | Pending |
| Disconnect and reconnect | Old generation invalidated; confirmed close or physical removal before fresh session | FAILED on f9a563c: normal Close→Connect in the same process timed out in discovery; restarting the same installed process restored immediate open. Root-cause diagnostics pending. |
| In-flight unplug, timeout or cancellation | Typed failure; no returned image success; late replies ignored; unconfirmed close quarantines reconnect until detachment | Pending |

`sessionOpen` means only the public USB PTP session opened. It does not prove X-T5 identity/firmware, selected USB mode, recipe access, or conversion support. `ready` is reserved for higher service validation in Task 3. Selector buffer labels and exposed identities now have the raw-header observation above; corrected end-to-end device-info acceptance still needs a retest; see [protocol provenance](protocol-provenance.md). The controller has now observed public sessionOpen after human authorization. Successful PTP, actual firmware and a detailed content/control status trace remain pending; sessionOpen alone does not establish those. Simulator tests do not pass this gate. The controller owns physical testing and the separate Gate 1 original-byte evidence.

For the current transaction investigation, toolbar **Camera** opens a dedicated selectable diagnostic sheet with Connect / Read info / Close controls. After read-only GetDeviceInfo completes or fails, the sheet retains at most 16 header messages (each at most 1,100 characters): submitted command, selector callback command and response lengths/types/codes/IDs plus at most 32 header bytes. It records data-phase length only, never payload bytes or serials. The corrected bridge validates the exact logical command echo and native context/run, then reports framework-managed wire association explicitly. Direct/raw decoding retains independent wire-ID matching. Capture these headers again on the corrected success path; never infer firmware from headers alone. Do not commit private device-info data or screenshots.

Additional unresolved lifecycle observation on phase-A 31f65cc: following the intentional 1/9 rejection/auto-close, one same-process reconnect discovered from 15:35:09Z until timeout 15:35:41Z with no opening/device event. The controller stopped retrying. Retest close/reopen after a corrected successful GetDeviceInfo before deciding a lifecycle change; no speculative reconnect fix is included here.

## Round 4 — in-process reconnect investigation

Controller installed `f9a563cdf631f6c05f8c0f61597e86d58d40d5b6` on iPhone 15 Pro, app-reported iOS 27.0.1. The X-T5 remained attached in user-confirmed USB RAW CONV./BACKUP RESTORE mode. Fresh process Connect at 15:46:35Z immediately opened generation 1 / USB 1227:764. Read-only GetDeviceInfo at 15:46:43Z and 15:47:33Z both succeeded: response 0x2001, logical 1/wire 11 and logical 2/wire 12, 365 bytes each. These results supersede the earlier pending corrected-adapter retest statements. They do not decode firmware or establish conversion readiness.

After one normal Close, Connect at 15:48:08Z in that same process emitted Disconnected→Discovering and timed out about 32 seconds later with no camera-added/open event. Controller then terminated and relaunched the **same installed binary**, without rebuilding, reinstalling or changing USB/camera state; Connect at 15:51:02Z immediately opened generation 1 again. This identifies an in-process lifecycle failure, not its particular cause. Camera absence, mode failure and wire-identity rejection must not be inferred from the missing callback.

Round 4's diagnostic checkpoint leaves lifecycle behavior unchanged. In **Camera**, **Refresh lifecycle snapshot** reads public browser flags/cache counts and saves the same bounded sanitized text to app-container `Documents/camera-diagnostics.txt`. The file contains at most 64 lifecycle messages × 512 characters plus the existing 16 PTP header messages × 1,100 characters. It excludes the general probe trace, user-entered firmware text, names, serials, card filenames and data/image payloads. A fixed filename is overwritten atomically; no file-sharing entitlement is needed. Automatic snapshots occur on state/command outcomes, but refresh explicitly after close and during stalled discovery to capture callbacks occurring between those outcomes.

Controller observation sequence: fresh-process Connect, optional existing read-only Read info, Close, refresh after public close completes, Connect once, refresh during the discovery stall (before its 30-second deadline), and refresh after the outcome. Preserve the file before restarting. Required evidence: browser sequence and `isBrowsing`/`isSuspended`, public device/USB-PTP counts, close request vs block/delegate callback order, `hasOpenSession`, current/stale identity flags, and whether the replacement browser sees a cached device without a new added callback. No arbitrary sleeps/retries, mode reset, bank/card write or additional permission request is added.

### Round 4 phase B — observed stop reentrancy and close sequencing fix

On installed diagnostic `feb1c473`, the controller again opened successfully and accepted GetDeviceInfo (0x2001, logical1/wire15,365 bytes). App-container snapshots captured the normal Close at16:02:31Z: `browser.stop.before` while camera/open/closing were true → synchronous `device.didRemove selected=true` while open was still true → `close.retiring`/`close.finished` → return from stop → a second finish. **No native close request or close completion occurred.** Source tracing confirms that stop's removal cleared `camera` before close() reached closeCamera(), so the live camera session's close request was skipped. This is shutdown-induced removal, not evidence of physical unplugging.

The next browser at16:03:02Z was browsing, not suspended, with both grants authorized but cache0 and no added callback. It remained so until timeout at16:03:34Z. Camera/cable were unchanged. Evidence files are ignored local `.build/task2-fix4-{after-close,during-discovery,after-timeout}.txt`; no private data is required to reproduce the reasoning.

The software correction keeps discovery running while native close is pending, including when waiting for a pending open's terminal callback. Confirmed close or independently observed removal retires camera identity/run/delegates before stopping discovery; close completion is published only after stop returns. Thus shutdown callbacks cannot skip native close or retire a reentrant replacement. A failed/unconfirmed native close retains quarantine and active discovery for real removal. No retries, persistent-browser workaround, deadline relaxation or mode change were introduced. The same diagnostic file remains available for controller verification: require `close.request` and successful native completion before `browser.stop.before`, then one same-process reconnect and read-only GetDeviceInfo. **Physical verification of this corrected sequence remains pending.**

## Task 3 phase A — identity/property probe available, Gates 3–4 pending

A DEBUG-only fresh-process launch with `--xt5-read-only-probe` now performs one bounded read-only protocol attempt and saves sanitized evidence in the app container:

- `Documents/xt5-protocol-evidence.json`: DeviceInfo model/firmware/capabilities and candidate property descriptor observations, updated incrementally.
- `Documents/xt5-protocol-status.txt`: current outcome/time/phone OS; no arbitrary camera strings.
- `Documents/camera-diagnostics.txt`: existing bounded native lifecycle and GetDeviceInfo header buffers, including close initiation only if native close has not completed yet.

The worker has run simulator parser, protocol safety, and launch opt-in tests only. No actual camera firmware, mode property value, seven-bank import, post-upload profile schema, or conversion output is claimed. The controller should capture these files from a fresh process without using in-process reconnect as a prerequisite; Task 2 recovery remains open. No saved-bank mutations, selector writes, object operations, conversion triggers, or Photos saves occur in this phase. `sessionOpen` is still not `ready`.

## Round 5 — retained discovery, physical retest pending

The controller's actual `1610709` retest confirmed successful GetDeviceInfo (logical 1 / wire 6 / 365 bytes), a native close request and successful native close completion with `hasOpenSession=false`, then browser.stop. Browser 1 still held one USB PTP device. Browser 2 remained authorized/browsing/not suspended with zero cached devices until timeout. The user confirmed Close→Connect still failed; process-only restart restored immediate discovery without camera/cable change. Round 4 fixed skipped native close but did not pass reconnect.

The driver now retains its browser across ordinary session closure and reconciles its live device list on explicit Connect. Session run/delegate identity remains separate. No session opens from an idle browser's didAdd, and no new session starts while close is unconfirmed. Simulator boundary tests are software evidence only. Gate 2 remains **PENDING**.

For the controller's combined DEBUG installation, launch a fresh app process with **`--camera-reconnect-probe`** only. This is mutually exclusive with Task 3's `--xt5-read-only-probe`; passing both runs neither. Ordinary launch remains inert. Keep camera/cable/mode unchanged throughout. The runner holds one operation gate for connect → GetDeviceInfo → confirmed closure → connect → GetDeviceInfo → confirmed closure, using actual app services/public SDK calls. Each USB operation and closure wait has the existing 30-second deadline; permission waiting remains human-paced. A closure timeout reports failure and preserves quarantine. There are no retry sleeps, saved-bank/mode/card writes, Photos saves or OS UI synthesis.

Copy **`Documents/camera-reconnect-status.txt`** and **`Documents/camera-diagnostics.txt`** after terminal outcome. Status records bounded timestamps, OS, logical/wire IDs, data length and fixed stage/outcome text. No payload or camera identity strings are exported. Physical normal-close acceptance requires two successful native `close.completion current=true errorCode=none` records, two accepted GetDeviceInfo requests, browser 1 retained throughout, second `browser.reconcile` with the connected device, and no intervening physical removal. A transport closure can also be confirmed by physical detachment, so the terminal status alone does not prove native Close→Connect. Then run Task 3's existing flag in a separate fresh process and copy its three evidence files. Actual firmware, in-flight unplug recovery and remaining permission/mode gates still need observations.

## Observed after round 5 — reconnect and phase-A identity

Controller reports installed `35af3dae86345b6d1c29e932800ecac329e8ff94` passed the explicit same-process reconnect experiment: browser 1 retained, two successful GetDeviceInfo commands and two successful native close completions, without cable removal or process restart between sessions. Independent scoped spec/quality review approved the transport correction. This passes the normal-close/reconnect observation; it does not close the other authorization, unplug, mode, or conversion acceptance items.

The separate actual phase-A capture establishes **X-T5 firmware 4.31**, iOS **27.0.1**, and the advertised capability lists. All 29 queried vendor descriptors returned `2002`. The phase-A JSON/status/lifecycle files are preserved in ignored `.build/task3-phaseA-*`. Descriptor rejection supplies no USB-mode value and does not establish failure of direct property reads.

Next controller experiment: launch DEBUG with **`--xt5-direct-values-probe` only** and copy `Documents/xt5-direct-values.json`, `Documents/xt5-direct-values-status.txt`, and `Documents/camera-diagnostics.txt`. This one-attempt read-only sequence bypasses descriptors, reads the documented advertised mode/current-slot/property values, and rereads D18C without changing it. No bank selection, saved-bank write, D185 baseline read, RAW upload, conversion, object deletion, or Photos save occurs. Other engineering flags must be absent; conflicting flags run neither workflow. The worker has simulator evidence only for this new path. Actual direct values, seven named banks, selection restoration, post-upload profile schema and full-size FINE output remain pending. `conversionValidated` stays false.

## Task 3 phase B accepted as direct-read evidence; phase C pending

Actual `cb7bc2bd` capture on X-T5 firmware 4.31 / iOS 27.0.1 completed all direct reads successfully: mode `0600` (6), both keys `X-T5_0200`, stable selector `0100` (1), valid redacted bank name and two-byte values for every one of 23 fields. This resolves descriptor availability as an import prerequisite. Grain value 7 and the four unmapped properties remain preserved and unresolved for rendering.

Next explicit DEBUG argument: **`--xt5-bank-import-probe` only**. The authorized temporary writes target D18C only. The probe reads all seven banks twice, compares complete name/settings bytes, restores the original selector and verifies the original contents. It reports restoration as verified or unconfirmed; cancellation/session failure never implies restoration. It does not write saved recipes or perform any RAW conversion.

Copy `Documents/xt5-bank-import-evidence.json`, `xt5-bank-import-status.txt`, and `camera-diagnostics.txt` as sanitized observations. Also preserve **`Documents/xt5-bank-import-private.json` only in an ignored private location** if private before/after snapshots are needed for validation; it contains names and raw settings. Acceptance requires `complete=true`, first/repeat coverage 1–7, seven true name/settings comparisons, and original/restored selector 1 with restoration `verified`. Inspect terminal status as well as JSON. The worker has software evidence only for this new sequence. Gates 3–4 remain open until actual seven-bank import and real full-resolution conversion evidence respectively; no `ready` state is emitted.

## Task 3 phase C accepted; phase D baseline experiment pending

Actual `383716d` seven-bank probe succeeded on X-T5 4.31: both scans cover slots 1–7, every name and all 23 raw fields match, original/restored selector is 1 and restoration is verified. Controller independently compared all 14 private snapshots; six names are nonempty and one is empty, with seven distinct settings snapshots. This establishes the import/preservation subgate. Full Task 3, conversion readiness and full-size output remain open.

Next controller-only native run: DEBUG **`--xt5-raw-baseline-probe` only**, with already-authorized Photos and normal public camera access. The helper selects one existing compatible RAW (preferring a 7728×5152 reference). Upload is allowed only after exact 4.31/mode6/_0200 checks and a successful empty object enumeration. Any nonempty/unknown view aborts before upload; there is no deletion/reset fallback. No conversion trigger or working profile patch is issued.

Copy sanitized `Documents/xt5-raw-baseline-evidence.json`, `xt5-raw-baseline-status.txt`, and `camera-diagnostics.txt`. Copy the unique run under **`Documents/xt5-raw-baseline-private/` only to ignored local private storage** for baseline/source comparison. It contains private image bytes, Photos identifiers, source hash, opaque D185 bytes, response handles and object metadata. Preserve the exact source RAF for subsequent X RAW Studio comparison. Inspect terminal status and JSON together. `probeFinished=true` requires accepted upload, retained baseline and confirmed native closure; it never means conversion support or confirmed upload-buffer cleanup. If aborted before upload, return the sanitized failure/counts and private bounded enumeration metadata for the next evidence decision. Do not automatically reset/delete/retry.

## Task 3 phase D accepted; unchanged-baseline output pending

Actual `07d013bc` uploaded the 35,811,472-byte standalone original, read a 625-byte post-upload profile, observed empty handles before/after upload and confirmed native close. Recorded geometry is 7728×5152 with orientation8. This passes the bounded upload/baseline observation, not conversion or buffer-cleanup gates. The declared29-word profile does not fit the plausible reference alignment; no patched settings codec is validated.

Controller's next fresh DEBUG launch: **`--xt5-unchanged-baseline-probe` only**. Keep the existing phase-D source directory in the app sandbox. Exactly one retained source run is required. This performs a new upload of the exact retained RAF, reads its baseline, confirms an empty pre-trigger object view, then issues one candidate D1830 trigger without D185 writes. No automatic second trigger, reset or deletion. Multiple objects or mismatched metadata/JPEG context fail. Native closure remains mandatory.

Copy sanitized `Documents/xt5-unchanged-baseline-evidence.json`, `xt5-unchanged-baseline-status.txt`, and `camera-diagnostics.txt`. Privately preserve the new run under **`Documents/xt5-unchanged-baseline-private/<UUID>/`**, including source-reference/source-manifest, fresh baseline, protocol/conversion manifests, object/storage metadata and—only if fully validated—`unchanged-baseline.JPG`. The original RAF remains in its phase-D run. Private manifests contain source hashes/IDs and object/storage identifiers; never commit them.

Return trigger acceptance, poll/handle counts, ObjectInfo bytes/dimensions, storage observation, JPEG dimensions/orientation/model checks, terminal status and native closure. Offline ExifTool inspection of any retained JPEG should compare selected camera tags with the same source (source quality NORMAL, orientation8, grain roughness/size0). Treat the output as an unchanged-baseline diagnostic, never an imported recipe or FINE result. Created-object and input-buffer cleanup remain unconfirmed; a later ownership decision requires these actual metadata observations. Do not rerun automatically if the remaining output makes the next precondition nonempty.

## Phase E crash and read-only recovery checkpoint

Actual phase E accepted the one D1830 trigger but crashed after the first empty poll. No JPEG or closure was proven. The private crash stack shows Swift MainActor assertion failure for ImageCaptureCore's PTP event on its operation queue. The empty callback is now explicitly nonisolated; simulator Objective-C background delivery reproduces RED and passes GREEN, including retired/current delegates and a pending command. Browser lifetime, run guards and command correlation are unchanged.

**Do not rerun the trigger probe.** Controller's next fresh DEBUG argument is **`--xt5-output-recovery-probe` only**. Keep the retained phase-D RAF. This performs exact-context read-only enumeration and accepts exactly one existing candidate for strict object/storage/JPEG validation. Zero, multiple or unexpected objects stop with evidence. There are no uploads, triggers, profile writes, deletions or automatic recovery mutations.

Copy sanitized `Documents/xt5-output-recovery-evidence.json`, `xt5-output-recovery-status.txt`, `camera-diagnostics.txt`. Privately preserve `Documents/xt5-output-recovery-private/<UUID>/`, especially conversion-manifest.json, output-object-info.bin, output-storage-info.bin if returned, and any validated recovered-candidate.JPG. Its provenance/ownership remains unconfirmed across the interrupted process. Return existing count, metadata/JPEG outcome, native-close trace and terminal status. Quality, profile schema, recipe fidelity and ownership-safe cleanup remain open even if recovery succeeds.

## Phase F actual refusal; phase G quarantine inspection pending

Actual read-only recovery survived the former callback crash and confirmed native close. One JPEG-format candidate reports4,373,716bytes, but ObjectInfo dimensions are0/0 and association is2055. Storage raw values3/2/2 were read. No JPEG bytes were downloaded; `unexpectedObjectMetadata` was the correct strict outcome. Reported standard storage capabilities do not authorize deletion.

Next controller launch: **`--xt5-output-quarantine-probe` only**. It reads the same existing object without upload/trigger/write/delete. Unknown ObjectInfo dimensions/association are permitted only for private quarantine. Known nonzero geometry mismatch still fails; exact byte count, unique-handle stability and complete raw ObjectInfo equality remain mandatory. Native closure is awaited.

Copy sanitized `Documents/xt5-output-quarantine-evidence.json`, `xt5-output-quarantine-status.txt`, `camera-diagnostics.txt`. Preserve **`Documents/xt5-output-quarantine-private/<UUID>/` only privately**, including conversion-manifest.json, output-object-info.bin, output-object-info-after.bin, output-storage-info.bin if returned and quarantined-candidate.bin if captured. Source reference/manifest link the original phase-D RAF; no new RAW/baseline is made.

Inspect quarantined bytes offline for actual JPEG type, dimensions, orientation8, camera model, quality and source context. `quarantineCaptured=true` never means validated output; `jpegRetained` staysfalse. Invalid JPEG/context remains an explicit failure even when a private quarantine exists. Return declared/actual byte counts, full metadata stability, header checks, terminal result and native closure. Do not rerun any trigger or delete the candidate. Full Task3 and conversion/fidelity/cleanup gates remain open.

## Task3 phase K — actual all-seven reference comparison and owned cleanup

Reviewed `f7934d6b` completed the real seven-candidate run at22:43:05–28Z on X-T5 firmware4.31 / iPhone iOS27.0.1. Exact initial J maintenance cleanup succeeded before the bank scan; all seven conversions then captured unique outputs and acknowledged exact owned-output deletion with empty views. Both full bank scans matched names and all23raw settings; selector2 was restored; native close was confirmed. The controller independently verified source/output hashes, exact candidate readbacks and opaque-byte preservation. No Photos writes occurred.

Independent X RAW Studio comparison of the **same original** verifies all seven outputs are FINE7728×5152/orientation8/X-T5, with181 exposed metadata comparisons and zero mismatches. Each output is closest to its own slot reference in spatial comparison; C2/C7 residuals match measured vendor-repeat scales. See protocol-provenance.md for the full measurements and limits. This fulfills the user's expanded all-seven visible-result comparison and supplies Gate3 evidence for this RAW/context, without a universal fidelity claim.

Gate4 remains partial: the actual source is standalone,3:2,lossless-compressed14-bit,orientation8. Conversion of a paired source and other recorded aspects/compression modes actually present still needs evidence. Dormant grain-off size was not serialized/applied; LMO is source-adjusted effective OFF/rejected ON. Runtime FINE validation, production CameraServing/CameraJPEG integration and broader failure/lifecycle acceptance remain open; visible output cleanup does not establish opaque RAW-buffer lifetime. Full Task3 is not complete. No new diagnostic launch is requested by this entry.

## Task4 — durable local catalog software evidence

Task4 adds a local SwiftData catalog with lossless immutable recipe history, frozen source/job snapshots, source-associated saved versions, and a durable Photos-save journal. Simulator disk-reopen and transaction tests verify complete-seven recipe replacement/rollback, equal-date source isolation, save-operation idempotence/conflicts, pinned JPEG/placeholder/attempt-time retention, unknown save confirmation, definitive-rejection retry, and inaccessible/deleted record retention. The final focused run passed **22 tests in 3 suites** (Catalog11, RawResourceSelector6, LibraryDiscovery5), exit0, on iPhone Duo simulator iOS27.1. Local evidence: `.build/task4-final-2.log` and `.build/TestResults/task4-final-2.xcresult`; full RED/GREEN details are in the Task4 report.

This supplies local persistence software evidence only. Task4 performed no physical camera interaction, Photos writes, permission requests, or device installation. Existing physical gates remain unchanged; the production camera hardware check is still pending camera availability, and Task5/Task8 own actual Photos saving and reconciliation acceptance. No new device proof or full workflow acceptance is claimed.

## Task5 — Photos writer software evidence; physical Gate5 pending

Task5 adds direct new-asset JPEG creation through public PhotoKit, with exact `FujiStudio-<Photos operation UUID>.jpg` resource identity, source capture date/location when present, untouched pinned camera-file bytes and `shouldMoveFile=false`. The Photos operation UUID is independent of the camera render attempt UUID. The native adapter forwards PhotoKit's real transaction completion; a placeholder alone never confirms a save, and cancellation after submission waits for that completion. Typed errors distinguish preflight authorization/output failure, actual transaction rejection (including authorization/storage/resource causes), and uncertainty.

The final focused simulator run passed **15 tests in 1 suite**, exit0: `.build/task5-final.log`, `.build/TestResults/20261027-021704-33763.xcresult`. Synthetic gateway tests inspect actual resource-creation options, source metadata/default assignments, callback ordering, unchanged bytes, cancellation timing, rejected/uncertain outcomes, exact-identity recovery, ambiguous identity and limited/revoked-access absence. The public native metadata fetch explicitly includes hidden/burst assets and all documented asset source types; it downloads no image/RAW payload. Full-access `.notFound` is only an absence observation and never permits automatic resubmission. A known ID is checked first, followed by exact filename fallback.

`SavedAsset.photosGeometry` is optional observed current Photos pixel geometry. Confirmed creation returns no observation; lookup can report Photos dimensions, including edited or oriented presentation dimensions. The pending `CameraJPEG` remains authoritative for encoded output dimensions and orientation; no EXIF orientation or source relationship is guessed from Photos dimensions, dates, or filenames.

This is software evidence only: the worker performed no Photos write, device installation, camera operation, permission request or privacy change. **Physical Gate5 remains pending** an authoritative paired-source production `CameraJPEG` from the next camera-available run. No probe was added because that exact input/provenance contract is not yet available. Historical standalone diagnostic JPEGs cannot stand in for paired production output. The controller must agree the exact frozen source, production output and deliberate export operation before a reviewed one-save probe is implemented/executed. Required physical observations still include source pair/resource hashes unchanged; output resource byte identity and dimensions/orientation/date/location; capture chronology/Recently Added; reopened catalog Versions association; exact-operation recovery and actual full/limited/revoked access behavior. Photos' equal-time tie ordering must be observed without claiming app control. Previously authorized Full Access/camera permission must not be requested again. See the Task5 report for test process evidence, the narrow geometry API clarification and the exact next-probe inputs.

## Task13 software phase — earlier controller evidence and open device gates

The controller's installed reviewed `88996b74` local RAW probe verified the exact
paired B asset's alternate RAF and primary JPEG roles, identity/revision/names
and RAF hash. Genuine CIRAW produced an upright 1366 × 2048 display from the
recorded 7728 × 5152 / orientation 8 original. The controller visually inspected
the upright result. No camera operation or Photos write was made by this probe.

The following production acceptance run completed three frozen C7 conversions
A–B–A through the real camera service: full FINE 7728 × 5152 / orientation 8,
with output sizes 26,369,498 / 26,130,950 / 26,371,588 bytes. A's render key was
stable, B's distinct; requested LMO ON was effective OFF with adjustment reported.
All seven bank names and 23 raw settings stayed unchanged and matched the frozen
capture. Exact owned outputs were deleted with empty-view acknowledgement;
native close was confirmed once. Complete JPEG decoding/Exif supplied geometry;
PTP ObjectInfo's zero dimensions were not treated as proof. No Photos writes
occurred. An independent private offline verification passed 91 assertions.

For the same A input, the production C7 result matched all 26 exposed tags and
five code tables and was spatially closest to C7's retained Mac reference.
Residuals were consistent with Fujifilm repeat-render variation. Paired B has
no Mac B reference, so its geometry, identity and effective metadata were checked
without a visual-fidelity claim. The earlier seven-slot diagnostic comparison
remains separate evidence for its exact input/context. General source support
and opaque uploaded-RAW buffer lifetime remain unproven.

At this historical software checkpoint, the guarded DEBUG live validation driver
had not yet run. Physical Gate5 (new asset, exact bytes/date/location, reopened
Versions and observed Photos chronology), Gate6 (real interruption/uncertain
save/recovery), limited/cloud cases, native accessibility/rotation and the
mixed-50-source Instruments measurements were open at that stage. No worker
operated the phone/camera or wrote to Photos during the software phase.

## Task13 current live composition — bounded preview/export/reopen pass

After software review, the first explicit live run on `a5023386` stopped before
camera connection, preview or export because the historical standalone manifest
had no recorded RAW discriminator. Its consumed claim and unarmed receipt were
preserved, with no job or Photos output. The reviewed `75fbd61b` correction uses
the actual retained A contract, keeps B descriptors strict, and captures separate
LIVE source descriptors checked around every materialization. It neither rewrites
retained proof nor retries an existing UUID.

The controller built/signed/verified/installed exact `75fbd61b` and deliberately
selected one new controlled run after confirming the first was unarmed. Genuine
no-recipe A RAW/B original-JPEG defaults were verified. Seven A recipe previews
left the native Photos identity set unchanged. All seven imported names and all
23 raw settings matched retained values before/after. Eight real camera outputs
(seven A previews and B-C7) were FINE 7728 × 5152, orientation 8, with requested
LMO ON/effective OFF reported. Each native operation retained exact provenance,
candidate/readback equality and owned-output deletion/empty acknowledgement.

One deliberate Browse-mode export saved viewed B-C7 as a distinct new Photos
asset. On-device coded checks compared its materialized original bytes with the
held actual preview, preserved the source capture date and absent location,
verified unchanged original RAFs/JPEG and saved-version/source association, and
confirmed native close from the service. Both source locations were nil; this
is no evidence of nonnil GPS preservation. The saved original was removed from
temporary storage after comparison, so the offline audit does not claim an
independent second PhotoKit resource hash.

The controller terminated and relaunched the same run UUID. Read-only reopen
verified the exact saved version without another export. Receipt/job/version
were unchanged; all 40 native journal files for eight operations were identical
byte for byte, with no new camera work. **Total actual Photos exports across both
attempts: one.** No user Photos asset was deleted. The failed first run remains
consumed and preserved.

Independent offline verification passed 156 assertions, including actual output
hashes, bindings, native journals and all-seven same-A Mac comparison. All exposed
metadata and five coding/table segments matched; each result ranked its own slot
nearest. C2/C7 residuals track measured vendor repeats; C5 has no own repeat, and
no pixel-perfect/universal fidelity claim is made. B has no same-source Mac
reference. [Protocol provenance](protocol-provenance.md#task13--current-production-seven-slot-comparison)
records the bounded comparison.

Device Hub screenshots let the controller inspect the upright B image,
RAW/original-JPEG/saved-C7 labels, two-row grid and read-only reopen status. The
validation route disables workspace controls; this observation does not prove
manual native gestures, menu interaction, accessibility or rotation. Termination
after completed saving also does not prove interruption during active work.

Later the controller launched the ordinary app with no validation flag and actual
coordinate taps worked; the previous remote-input blocker did not recur, with
cause unknown. Select added checkboxes without a visible grid/two-row size change;
All selected 761 eligible sources and None cleared to zero. Expand overlaid four
rows across most of the viewer. Done/source navigation kept the drawer expanded,
and manual Collapse retained the viewed standalone A tile. Genuine RAW, Zoom+,
Fit and double-tap zoom/reset were directly observed in returned device images.
No new local screenshot path is claimed.

The actual floating menu displayed seven slots, including one legitimately
unnamed slot. C3 selection plus normal Connect reached Camera Ready and a color
Temporary Preview with one-source Export enabled outside Select. Manual RAW
switching preserved C3/Export eligibility; returning to Temporary Preview worked.
No Recipe restored RAW and disabled Export despite the ready camera. No Export
was tapped, so the total Photos export count stays one.

Two remote drag attempts selected only an endpoint and a wheel attempt did not
scroll. The user subsequently confirmed on the installed reviewed build that all
crossed photos became checked during a real finger sweep across thumbnails and
the next row: a bounded human-observed range-selection pass. The user subsequently
answered “Both work” to the explicit pinch zoom/pan of the main photo and expanded
grid vertical-scroll check on installed `75fbd`. These are bounded human
observations, not a physical pass of the later final-correction code or evidence
for precise detail preservation, performance, rotation or VoiceOver. The earlier
remote-input cause is not asserted. These ordinary UI observations postdate the fixed
156-assertion snapshot. Normal C3 preview may involve native/cached camera work;
the byte-identical journal proof applies only to the earlier reopen interval.

Still NOT RUN: active Home/background/disconnect/unknown-save recovery,
Photos chronological UI/tie order, nonnil GPS, limited/cloud cases, native
rotation/VoiceOver/hardware-keyboard and precise detail checks, broader
firmware/lens/aspect/
compression classes and mixed-50-source Instruments measurements. This bounded
pass does not close full device acceptance. All exact run/source/asset values,
media and verification artifacts remain in ignored private storage.
