# Device validation gates

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

Task 2 supplies a DEBUG camera prerequisite section below Photos inspection/results and above the full source list. Camera discovery and ImageCaptureCore authorization begin only with **Discover and open public USB PTP session**. Select `USB RAW CONV./BACKUP RESTORE` on the X-T5 manually and record its firmware before starting. **Read standard PTP device info** sends only read-only standard GetDeviceInfo (`0x1001`). There is no camera reset, saved-bank write or card-object deletion. Original Photos inspection still works independently; toolbar **Inspect** invokes the same retrieval and **Results** presents selectable current Photos output with Done.

| Experiment | Required observation | Outcome |
| --- | --- | --- |
| Correct mode, connected X-T5 | Actual iPhone OS, firmware from camera screen, control/content permission statuses, discovering → opening → sessionOpen, generation, USB IDs, GetDeviceInfo response/transaction/payload length | Pending |
| Content/control permission denied or restricted | Authorization-required/denied state distinct from transport failure; no PTP request | Pending |
| Camera unplugged or invisible in mode | No visible session; explicitly record physical connection/mode, because framework absence alone cannot identify cause | Pending |
| Visible camera lacking USB PTP capability | Mode guidance; never conversion-ready | Pending |
| Disconnect and reconnect | Old generation invalidated; confirmed close or physical removal before fresh session | Pending |
| In-flight unplug, timeout or cancellation | Typed failure; no returned image success; late replies ignored; unconfirmed close quarantines reconnect until detachment | Pending |

`sessionOpen` means only the public USB PTP session opened. It does not prove X-T5 identity/firmware, selected USB mode, recipe access, or conversion support. `ready` is reserved for higher service validation in Task 3. Completion buffer mapping also needs a real read-only GetDeviceInfo observation; see [protocol provenance](protocol-provenance.md). No successful session/PTP trace, actual firmware or completed ImageCaptureCore content/control authorization result has been recorded; the user-approved OS Camera grant and failed notice-time attempts above are the current physical evidence. Simulator tests do not pass this gate. The controller owns physical testing and the separate Gate 1 original-byte evidence.
