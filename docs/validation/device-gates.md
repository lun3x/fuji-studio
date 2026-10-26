# Device validation gates

## Gate 1 — actual Photos originals: PENDING

No actual iPhone RAF/JPEG resource retrieval has been observed by this implementation task. Simulator tests are software evidence only and do not pass this gate.

- Intended phone: iPhone 15 Pro. Controller reports iOS 27.0.1 and Developer Mode enabled; pending on-device probe confirmation.
- Camera: Fujifilm X-T5. Actual firmware: **not yet recorded**.
- Build baseline: iOS 27.0, Swift 6, bundle ID `com.lun3x.FujiStudio`.
- Available simulator evidence: Xcode 27.1 (27A9275), iPhone Duo iOS 27.1. Not a hardware substitute.
- Signing: simulator builds unsigned. Controller reports the existing provisioning profile belongs to another app; a valid profile for this bundle ID is still required. No Apple developer account or provisioning changes were made.

Use the DEBUG **Hardware probe** from the app's initial screen. The probe lists public PhotoKit resource type discriminators, normalized original/adjusted roles, content types, filenames and available sizes without fetching bytes. Selecting **Retrieve and inspect selected originals** performs sequential original retrieval and reports actual byte sizes, SHA-256, X-T5 model verification, container/crop geometry, recorded aspect, crop origin and orientation. Successful probe files are removed; cancelled/failed downloads remove partial files. The original-resource controls never start a camera workflow.

| Experiment | Access | Required observations | Outcome |
| --- | --- | --- | --- |
| SD-imported RAF+JPEG pair | Full | Both original resource roles/types/sizes, both byte retrievals, RAF identity/hash, X-T5 metadata; one source | Pending |
| Standalone RAF | Full | No invented JPEG; RAF identity/hash and X-T5 metadata | Pending |
| Same pair and standalone | Limited | Only allowed IDs discovered, both originals still retrievable; change allowed set and rediscover | Pending |
| Cloud-evicted original | Full/limited | Descriptor retained before download, progress, original identity after download | Pending |
| Cancel cloud download | Full/limited | Cancellation outcome and partial-file removal; subsequent retrieval succeeds | Pending |
| Other Fujifilm model / renamed non-RAF | Either | Incompatible model or invalid-container error, no conversion eligibility | Pending |
| Recorded geometry | Either | Reference 3:2 X-T5 output 7728 × 5152; compare other recorded aspects/orientations and used compression modes | Pending |

Record phone OS and actual camera firmware before these experiments. Preserve redacted role/type/size and outcome evidence here; keep personal filenames, local IDs and images out of version control. Failure changes the investigation; it does not authorize dropping paired assets, reimporting, or substituting phone processing.

## Gate 2 — public USB PTP session: PENDING

Task 2 supplies a DEBUG camera prerequisite section below Photos inspection/results and above the full source list. Camera discovery and ImageCaptureCore authorization begin only with **Discover and open public USB PTP session**. Select `USB RAW CONV./BACKUP RESTORE` on the X-T5 manually and record its firmware before starting. **Read standard PTP device info** sends only read-only standard GetDeviceInfo (`0x1001`). There is no camera reset, saved-bank write or card-object deletion. Original Photos inspection still works independently; toolbar **Inspect** invokes the same retrieval and **Results** presents selectable current Photos output with Done.

| Experiment | Required observation | Outcome |
| --- | --- | --- |
| Correct mode, connected X-T5 | Actual iPhone OS, firmware from camera screen, control/content permission statuses, discovering → opening → sessionOpen, generation, USB IDs, GetDeviceInfo response/transaction/payload length | Pending |
| Content/control permission denied or restricted | Authorization-required/denied state distinct from transport failure; no PTP request | Pending |
| Camera unplugged or invisible in mode | No visible session; explicitly record physical connection/mode, because framework absence alone cannot identify cause | Pending |
| Visible camera lacking USB PTP capability | Mode guidance; never conversion-ready | Pending |
| Disconnect and reconnect | Old generation invalidated; confirmed close or physical removal before fresh session | Pending |
| In-flight unplug, timeout or cancellation | Typed failure; no returned image success; late replies ignored; unconfirmed close quarantines reconnect until detachment | Pending |

`sessionOpen` means only the public USB PTP session opened. It does not prove X-T5 identity/firmware, selected USB mode, recipe access, or conversion support. `ready` is reserved for higher service validation in Task 3. Completion buffer mapping also needs a real read-only GetDeviceInfo observation; see [protocol provenance](protocol-provenance.md). No actual camera trace, firmware or ImageCaptureCore permission outcome has been recorded by Task 2, and simulator tests do not pass this gate. The controller owns physical testing and the separate Gate 1 original-byte evidence.
