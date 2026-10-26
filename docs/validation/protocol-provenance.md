# Public USB PTP transport provenance

## Evidence status — 2026-10-26

Transport software and deterministic simulator tests are implemented. **No physical X-T5/iPhone PTP session or device trace has been observed by Task 2.** Firmware, phone permissions, callback payload mapping, USB mode, and RAW conversion capability remain physical gates. No device build/install, authorization request, camera setting change, recipe-bank write, card deletion, or provisioning change was performed by Task 2.

The native baseline remains iOS 27.0 / Swift 6 / `com.lun3x.FujiStudio`. Development evidence uses Xcode 27.1 (27A9275), iPhoneOS/iPhoneSimulator 27.1 SDK and the iPhone Duo iOS 27.1 simulator. Simulator availability is not evidence of camera support.

## Primary API sources

Checked the installed public SDK headers under `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/ImageCaptureCore.framework/Headers/`, and extracted the SDK's Swift symbol graph to verify imported spellings.

| API contract | Installed public header | Official reference |
| --- | --- | --- |
| Public asynchronous PTP command, separate outbound data and completion buffers; capability required | `ICCameraDevice.h`, `requestSendPTPCommand:outData:completion:` (iOS 13.0); delegate overload discussion names `inData` and `response` separately | [PTP completion](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:)), [PTP capability requirement and delegate payload names](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:sendcommanddelegate:didsendcommand:contextinfo:)) |
| Separate control and content authorization; authorized, denied, restricted, not determined | `ICDeviceBrowser.h` (iOS 14.0) | [Device browser](https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser) |
| Session open/close completion may run on any queue; session open property | `ICDevice.h`, `requestOpenSessionWithOptions:completion:`, `requestCloseSessionWithOptions:completion:` (iOS 13.0) | [Device session API](https://developer.apple.com/documentation/imagecapturecore/icdevice) |
| Camera delegate is required for ICCameraDevice; inherited device lifecycle notifications; main-thread delegate delivery | `ICCameraDevice.h` / `ICDevice.h` | [Camera delegate](https://developer.apple.com/documentation/imagecapturecore/iccameradevicedelegate) |
| USB transport and public PTP capability | `ICDevice.h` / `ICCameraDevice.h`; imported names `ICDeviceTransport.transportTypeUSB`, `ICDeviceCapability.cameraDeviceCanAcceptPTPCommands` | [USB transport constant](https://developer.apple.com/documentation/imagecapturecore/icdevicetransport/1508049-transporttypeusb) |

The existing project NSCameraUsageDescription supplies the iOS external-camera rationale required by [Apple’s ImageCaptureCore overview](https://developer.apple.com/documentation/imagecapturecore/). No entitlement/provisioning edits were needed for this software work.

Apple documentation is proprietary reference documentation; no sample-code source has been copied. All app code in Task 2 is original Swift using the public framework. No libusb dependency or private API is introduced.

**Completion buffer interpretation:** the installed header calls its first buffer `responseData` and its second `ptpResponseData`; the implementation treats the first as the inbound data phase and the second as the PTP response container. Apple's short prose merely lists response/data/error and does not unambiguously establish the byte layout. This mapping and the standard PTP USB container layout are therefore explicitly **pending physical confirmation**. The read-only standard GetDeviceInfo probe provides that check. An unexpected mapping cannot silently succeed: response type, exact container length, transaction ID, success code, parameter count and payload size are checked. The code never swaps buffers opportunistically or interprets a JPEG marker as transport success.

## Transport contract for subsequent tasks

- `PTPTransport.execute(_:data:)` accepts a command opcode, up to five UInt32 parameters, caller-supplied transaction ID, and an optional data-phase payload. It returns the original opcode, response parameters/code/transaction identity and raw inbound data. Commands use standard little-endian USB PTP containers. Responses must be type 3, exactly 12–32 bytes, aligned parameters, matching transaction, and success `0x2001`. Non-success responses are typed failures even when accompanied by JPEG bytes.
- Data phase limits default to 128 MiB each direction; response parsing caps the container before copying/parsing. ImageCaptureCore itself allocates its completion buffers, so this app-level check cannot bound the framework's internal allocation. Task 7 must maintain the one-active-original/conversion-payload policy.
- `SerialCameraGate.withExclusiveAccess` owns an explicit FIFO asynchronous permit across a whole upload/convert/download operation. Actor isolation by itself is insufficient. Do not recursively acquire the same gate. Queued cancellation removes only that waiter; active cancellation releases the permit only when its operation actually returns.
- The transport separately rejects a second wire command while one is pending. A 30-second default USB discovery/open deadline starts only after authorization succeeds and discovery begins; command deadlines remain per transaction. Expiration or cancellation invalidates the session generation before resuming the caller and initiates public session close. `disconnect()` invalidates immediately; it does not claim the underlying close has completed. `connect()` returns `sessionClosing` until confirmed close or physical removal. An uncertain/failed close remains quarantined; detachment is the recovery, without a mode reset.
- Opening has no public cancellation operation. On cancellation/deadline, the driver waits for the open completion and then closes. Every completion hops back to MainActor; session generations and command/close UUIDs reject old callbacks. A subsequent connection uses a fresh browser and generation. A late close callback cannot release a newer quarantine.
- **`sessionOpen` is deliberately distinct from `ready`.** The transport emits `sessionOpen` for a successful USB PTP session; it never emits `ready`. The higher camera service must read and validate X-T5 identity, firmware and RAW conversion capability before producing a conversion-ready state. The public framework does not expose the selected Fujifilm USB mode or firmware.
- Discovery considers Fujifilm USB vendor `0x04cb`, checks USB transport and the public PTP capability, and opens at most one camera. It does not assume every Fujifilm device is an X-T5. A visible Fujifilm device without USB PTP capability yields mode guidance. No visible device could mean unplugged, wrong USB mode, power/cable failure, or framework invisibility: absence is not claimed to identify one of these.

## Upstream vendor research held for Task 3

Task 2 uses no vendor recipe/conversion codec. These pins preserve the research handoff; they are not device evidence, and no source from them was ported in Task 2.

| Reference | Immutable pin | License / use |
| --- | --- | --- |
| [Daniel Cook, libfuji](https://github.com/petabyt/libfuji/tree/3328efc51f74d754f8fa76af70c6becdde62271f) | `3328efc51f74d754f8fa76af70c6becdde62271f` | [MIT, copyright 2026 Daniel Cook](https://github.com/petabyt/libfuji/blob/3328efc51f74d754f8fa76af70c6becdde62271f/LICENSE); fetched pinned LICENSE to verify. No copied code. |
| [Fuji PTP Recipes contributors, documentation](https://github.com/ILFforever/fujifilm-ptp-recipes/tree/daba2d97d6b37bd1d5dbc68ca974f6b22f433071) | `daba2d97d6b37bd1d5dbc68ca974f6b22f433071` | [Documentation CC BY 4.0, example code MIT](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/LICENSE); verified cached pinned license. Research credit retained here. No copied codec. |

## Physical trace — PENDING

There is no sanitized physical trace to attach yet. All test PTP bytes are hand-authored synthetic containers. The DEBUG probe logs state transitions, timestamps, session generation, USB vendor/product IDs, observed phone OS, manually entered firmware, and read-only GetDeviceInfo response code/transaction/payload byte count. It does not log serial numbers, card filenames or image payloads.

Before Gate 2 acceptance, record actual phone OS, actual X-T5 firmware, camera-screen `USB RAW CONV./BACKUP RESTORE`, granted/restricted/denied ImageCaptureCore control and content permissions, successful session lifecycle plus standard GetDeviceInfo, timeout/unplug recovery, and the no-visible-device/wrong-mode experiments. Preserve sanitized observed values and outcomes in `device-gates.md`; do not replace pending fields with simulator fixtures. Vendor mode verification and C1–C7/RAW conversion remain Task 3.

## Review correction — discovery scope and terminal detachment

The public browser now explicitly combines `ICDeviceTypeMask.camera` (`0x001`) with `ICDeviceLocationTypeMask.local` (`0x100`) before browsing; assigned mask `0x101` is verified at the real driver's browser boundary. This follows the installed SDK and [Apple's mask construction contract](https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser/browseddevicetypemask?language=objc). It remains software configuration evidence, not a physical discovery result.

Observed detachment retires the driver's run identity, clears the opening state and camera delegate/reference before publishing removal. A synchronously requested close therefore completes without waiting for the detached camera's pending open callback. A late callback from that run is rejected even after a replacement session opens. New `ImageCaptureSessionDriverTests` exercise the actual public driver's discovery setter, delegate lifecycle and completion bodies using controlled subclasses of the public browser/camera. Browser creation and arbitrary-queue completion delivery are injectable in the existing Task 2 driver file; production defaults still create ICDeviceBrowser and hop completion bodies to MainActor. No new production file/module owns these interfaces.

## On-device authorization correction — permission wait versus USB timing

The controller observed on installed `b6d6013` that the user granted OS Camera Allow, but repeated native authorization requests produced connected-camera notices while the previous 30-second connection timer was already running. No public session or PTP response succeeded in those attempts. This is authorization-flow evidence, not proof of cable failure or conversion support.

The public driver now reads each authorization status before requesting it. Authorized grants skip the native request entirely; only not-determined grants request a user decision; denied/restricted statuses fail without browsing or asking again. Authorization callbacks retain run checks. `CameraDriverEvent.discoveryStarted` is a Task 2 internal boundary event: both grants are authorized and the driver is about to call `ICDeviceBrowser.start()`. The transport leaves its opening deadline absent throughout human permission waiting, then arms the existing bounded discovery/open deadline on the first current-attempt discoveryStarted event. Repeated events do not restart that deadline. Successful open, denial, cancellation and disconnect clean up optional deadlines; stale timers retain attempt IDs and cannot affect a later session. Command timing and uncertain-close quarantine are unchanged. Permission waiting remains cancellable even while arbitrarily delayed.

The worker exercised this through the actual public driver's SDK-subclass boundary and controlled callbacks/timers, without OS grants, device installation or camera access. A physical retest of the corrected flow, actual content/control statuses, firmware and read-only GetDeviceInfo is still required.
