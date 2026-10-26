# Device validation gates

## Gate 1 — actual Photos originals: PENDING

No actual iPhone RAF/JPEG resource retrieval has been observed by this implementation task. Simulator tests are software evidence only and do not pass this gate.

- Intended phone: iPhone 15 Pro. Controller reports iOS 27.0.1 and Developer Mode enabled; pending on-device probe confirmation.
- Camera: Fujifilm X-T5. Actual firmware: **not yet recorded**.
- Build baseline: iOS 27.0, Swift 6, bundle ID `com.lun3x.FujiStudio`.
- Available simulator evidence: Xcode 27.1 (27A9275), iPhone Duo iOS 27.1. Not a hardware substitute.
- Signing: simulator builds unsigned. Controller reports the existing provisioning profile belongs to another app; a valid profile for this bundle ID is still required. No Apple developer account or provisioning changes were made.

Use the DEBUG **Hardware probe** from the app's initial screen. The probe lists public PhotoKit resource type discriminators, normalized original/adjusted roles, content types, filenames and available sizes without fetching bytes. Selecting **Retrieve and inspect selected originals** performs sequential original retrieval and reports actual byte sizes, SHA-256, X-T5 model verification, container/crop geometry, recorded aspect, crop origin and orientation. Successful probe files are removed; cancelled/failed downloads remove partial files. It never starts a camera workflow.

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
