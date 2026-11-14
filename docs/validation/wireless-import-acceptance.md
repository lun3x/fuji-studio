# Wireless import acceptance

## Firmware targets

Fujifilm’s official U.S. release pages were checked on 2026-11-14. Recheck both before release validation. The bundled policy admits one firmware version per model. Firmware admission and transfer capabilities are separate checks. Pairing and identity reads can establish admission before browsing or transfer begins.

| Camera | Latest official release | Intended path | Physical acceptance |
| --- | --- | --- | --- |
| X-T5 | 4.32, published 2026-11-10. [Release and update instructions](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/) | Secure BLE and XApp transfer | Pending |
| X-E3 | 1.32, published 2026-06-23. [Release and update instructions](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/) | Legacy BLE and phone transfer, with guided PC AutoSave for RAF if needed and verified | Pending |

## Evidence matrix

No Fuji Studio camera or signed-iPhone wireless captures have been collected for these targets. The observations below come from public sources. See the [wireless protocol research](wireless-protocol-research.md) for the earlier investigation and its limits.

| Check | X-T5 4.32, XApp | X-E3 1.32, phone or AutoSave |
| --- | --- | --- |
| BLE pairing and reconnect | Fujifilm documents its 4.30 pairing security change and the switch to XApp on iOS. Furble’s maintainer reported secure reconnect on an updated X-T5 without specifying its firmware. The target’s service layout, iOS confirmation and saved reconnect are unknown. [Firmware history](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/), [Furble report](https://github.com/gkoh/furble/issues/208#issuecomment-3235389619) | Fujifilm reports a Camera Remote Bluetooth pairing fix for Android 16 in 1.32. Libfuji implements legacy pairing. The target’s service layout, iOS confirmation and saved reconnect are unknown. [Firmware history](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/), [Libfuji BLE source](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/bluetooth.c) |
| Peer identity and firmware | Unknown which authenticated values are stable across BLE and WiFi and which field carries the body firmware on this release. Capture pairing, reconnect and same-model peer rejection. | Unknown which values bind the saved BLE peer to phone and AutoSave sessions. Capture body firmware and cross-transport identity for the selected body. |
| WiFi readiness | Libfuji shows credential reads and a WiFi launch write. The positive readiness signal and usable TCP setup on this firmware are unknown. [Libfuji BLE source](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/bluetooth.c) | The manual documents wireless phone transfer and camera-initiated PC AutoSave on a shared network. Positive phone-mode readiness and signed-iPhone AutoSave discovery are unknown. [Wireless transfer manual](https://fujifilm-dsc.com/en-int/manual/x-e3/connections/wireless/index.html) |
| Original-size control | Libfuji uses the XApp compression control (D226) before download. The target’s accepted control, response and original JPEG/RAF byte equality are unknown. [Libfuji PTP source](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c) | Libfuji toggles the D227 file-size control in phone mode. Original-size behavior and byte equality are unknown for both target modes. [Libfuji PTP source](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c) |
| Card enumeration | The manual confirms two physical slots and separate RAW/JPEG recording. Wireless storage IDs, per-slot enumeration and split-card pairing are unknown. [Memory card manual](https://fujifilm-dsc.com/en-int/manual/x-t5/first_step/insert_card/) | The manual describes a single card slot. Its wireless storage ID and empty/absent-card behavior are unknown in both modes. [Memory card manual](https://fujifilm-dsc.com/en/manual/x-e3/first_step/insert_battery_card/index.html) |
| RAW exposure | Fujifilm added XApp RAW transfer in 3.01. External JPEG and RAF wire captures are for GFX100 II 2.30. Target firmware exposure of same-card pairs, split-card pairs and standalone RAF in Fuji Studio is unknown. [Firmware history](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/), [External capture](https://github.com/epsalmond/ptpsim/blob/a2cea30d8622ba9e71d49338b0d0eda20b664689/packages/camera-config-data/fuji/gfx100ii/evidence/IMAGE_TRANSFER_FW230.md) | Fujifilm excludes RAW from phone transfer orders. Libfuji reports RAW through AutoSave generally. Exposure of original RAF on X-E3 1.32 remains unknown in each mode. [Playback manual](https://fujifilm-dsc.com/en/manual/x-e3/playback/menu_playback/index.html), [Libfuji developer notes](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/dev.md) |
| AutoSave registration and transfer markers | Outside the XApp target path. | Fujifilm lists the X-E3 as desktop AutoSave compatible. Libfuji’s registration and import examples identify an X-H1. X-E3 peer binding, registration, queue advancement and completion markers are unknown. Require a signed iPhone with effective multicast entitlement to prove broadcast discovery and original transfer. [Fujifilm compatibility](https://www.fujifilm-x.com/global/support/compatibility/software/pc-autosave/), [Libfuji AutoSave notes](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/autosave.md), [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) |

## Protocol source pins

Check the exact source file and applicable license at each pin before adapting a sequence. Retain license notices for adapted code. This checkpoint introduces no ported protocol sequences.

| Source | Pinned material | License |
| --- | --- | --- |
| Furble | `0cac22aacc3d9ef250be40849118af78a5f39f27` · [Secure BLE](https://github.com/gkoh/furble/blob/0cac22aacc3d9ef250be40849118af78a5f39f27/lib/furble/FujifilmSecure.cpp) | [MIT](https://github.com/gkoh/furble/blob/0cac22aacc3d9ef250be40849118af78a5f39f27/LICENSE) |
| Libfuji | `3b9932a46d025405dae505ddb624733b6ea3edd1` · [BLE](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/bluetooth.c), [PTP](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c), [AutoSave](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/autosave.md) | [MIT](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/LICENSE) |
| ptpsim | `a2cea30d8622ba9e71d49338b0d0eda20b664689` · [GFX100 II 2.30 capture record](https://github.com/epsalmond/ptpsim/blob/a2cea30d8622ba9e71d49338b0d0eda20b664689/packages/camera-config-data/fuji/gfx100ii/evidence/IMAGE_TRANSFER_FW230.md) | Dual-licensed [MIT](https://github.com/epsalmond/ptpsim/blob/a2cea30d8622ba9e71d49338b0d0eda20b664689/LICENSE-MIT) or [Apache 2.0](https://github.com/epsalmond/ptpsim/blob/a2cea30d8622ba9e71d49338b0d0eda20b664689/LICENSE-APACHE). Capture record is reference evidence. |

## Local capture record

Add one entry per tested firmware and transfer mode with the following fields. Use an evidence ID that can be referenced by the session’s capability report. Keep raw firmware text and any required raw protocol material in private evidence. Publish sanitized outcomes with no tokens, SSIDs, passwords, camera serials, peripheral IDs, filenames or packet bodies containing them.

| Field | Record |
| --- | --- |
| Run | Date, app revision, iPhone model, iOS version, signing/entitlement result, body model, normalized firmware, mode, evidence ID |
| BLE | Service family, explicit confirmation, saved reconnect after camera power cycle and app foreground, cancellation and permission outcomes |
| Identity and admission | Body identity/firmware sources, same-model wrong-peer rejection, firmware gate result before inventory |
| WiFi and PTP | Positive readiness signal, native prompt and association outcome, setup completion, disconnect and failure stage |
| Storage | Observed storage IDs, populated/empty/unavailable results, card scan completion, X-T5 slot 1 and slot 2 separately and together |
| Originals | Verified original-size control, RAW exposure, standalone RAF, same-card and X-T5 split-card pairing, byte counts and SHA-256 against card originals |
| AutoSave on X-E3 | Signed iPhone broadcast discovery, camera-side registration, selected peer, RAF/JPEG transfer, completion markers and failure stage if any |
| Photos | One new asset per capture, resource verification, interrupted submission recovery, originals still present on the camera |

Synthetic packet fixtures verify software behavior. Record them with synthetic provenance. A successful signed-iPhone run on each target is required for physical acceptance.

### Camera-hosted probe on 2026-11-14

The deterministic replays use synthetic packets. XApp setup follows the pinned
libfuji vendor properties and the ordered gallery reads in the GFX100 II
capture. The phone adapter uses the referenced legacy gallery commands and
omits live view. The target firmware's response to these sequences remains
pending. The separate debug route `--wireless-protocol-probe` initializes only
Bluetooth and Wi-Fi services. The operator explicitly selects the camera and
chooses files to stage privately. The probe writes an observation log and
per-resource SHA-256 receipts under
`Library/Application Support/WirelessProtocolProbe/<run-id>`.

| Gate | Observed result |
| --- | --- |
| Signed iPhone with native camera Wi-Fi | The configured personal development team cannot provision the Hotspot Configuration or Access Wi-Fi Information capabilities. Xcode denied the app development profile with and without automatic provisioning. Native Wi-Fi and PTP measurements remain pending on both target bodies. |
| Signed iPhone Bluetooth-only diagnostic | A temporary project without Wi-Fi entitlements built, passed strict signature verification and installed on an iPhone 15 Pro running iOS 27.0.1. The device refused the explicit diagnostic launch with a profile trust or signature error. The app identifier, team, signer certificate and target device matched the embedded profile. Pairing, protected storage and reconnect remain pending. |
| Wi-Fi network binding | The app resolves the authenticated BLE credential at the native join boundary. It checks the currently associated secured SSID through `NEHotspotNetwork.fetchCurrent` before opening PTP and again before browsing. This requires both the Wi-Fi Information entitlement and API eligibility for the current network. Unreadable or different associations fail the handoff. A previously configured network must already be associated before reuse. |
| Peer binding | The PTP adapter checks the model and the exact firmware from DeviceInfo before transfer setup. An observed DeviceInfo serial can be retained as a redacted digest for protected comparison. Its stability and relationship to BLE or AutoSave remain unverified. A matching secured SSID and matching model and firmware cannot distinguish peers with those same values. |
| Original size | The XApp adapter reads D226 and allows original transfer only when it observes the reference value 2. The app never writes D226 or changes the camera's resize setting. Libfuji and the GFX100 II capture use different write widths and do not establish persistence scope on the target. Legacy phone D227 obtains the actual byte length before freezing a descriptor. That control leaves the representation unverified. Only the debug probe can stream phone diagnostic candidates for independent hash comparison, and its receipts label them as such. |
| RAW exposure | Replay observes XApp RAF files and a phone gallery with no declared or observed RAF support. The X-E3 1.32 card test and the separate signed AutoSave multicast gate remain pending. |

A signed wireless build needs a development team and device profile granting
`com.apple.developer.networking.HotspotConfiguration` and
`com.apple.developer.networking.wifi-info`. To run after provisioning, build the
Debug configuration with normal automatic development signing, verify the app
with `codesign --verify --deep --strict`, install that bundle, then launch
`com.lun3x.FujiStudio` with `--wireless-protocol-probe`. Approve Bluetooth,
camera, Wi-Fi and Local Network prompts when asked. Run first pairing and
reconnect for each body after unplugging its USB cable. Check the camera's
**Resize Image for Smartphone** setting before an original-size test. Select
the JPEG and RAF of a known paired capture and a standalone RAF in the X-T5
probe inventory. Compare the staged receipts with SHA-256 of files copied
independently from the card.

### X-E3 1.32 PC AutoSave feasibility

On 2026-11-15, Fujifilm’s official pages still listed X-E3 1.32 and X-T5
4.32. The PC AutoSave physical gate is blocked at provisioning. The
multicast-only automatic development signing attempt used the app’s bundle ID
and development team `AZH3P824F3`. Xcode rejected it because Personal
development teams cannot provision Multicast Networking. It also reported that
Apple must approve and assign the capability to the team and bundle ID. The
existing signed Bluetooth diagnostic’s code signature and embedded development
profile were inspected separately. Both lacked
`com.apple.developer.networking.multicast`. The next signing prerequisite is
an eligible team and a profile for the app ID with Apple’s granted capability.
The project leaves multicast out of its entitlements and reports AutoSave
unavailable. [Apple provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities),
[Fujifilm X-E3 firmware](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/),
[Fujifilm X-T5 firmware](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/)

| Check | Result |
| --- | --- |
| Source-derived handshake | The bounded codec and native implementation use UDP/TCP 51542 for registration, UDP/TCP 51541 for transfer discovery and invitation, TCP 51540 for NOTIFY and TCP 55740 for the camera command socket. The intended topology is both devices on the same Wi-Fi network with client isolation disabled. The native handshake has no Bonjour dependency. Replay uses the pinned X-H1 transcript and synthetic X-E3 data. |
| Selected-camera binding | REGISTER and IMPORT carry a claimed name. Setup completes only after the first transfer returns an exact DeviceInfo key previously verified for the selected camera, along with the expected manufacturer, model and firmware. The binding and the destination token are stored together in the selected camera’s device-local Keychain record. A fresh, scoped importer token rejects old destination discoveries. Retries recheck the stored registration and the command peer. The token travels in plaintext and the PTP serial is a device claim, so neither establishes cryptographic authentication of the LAN peer. Whether this X-E3 supplies a usable, stable DeviceInfo identifier is pending. |
| Failure stages | The app allows up to 120 seconds for registration and its first transfer verification, and 60 seconds for a later session wait. A failed discovery candidate leaves the receiver waiting within that deadline. After IMPORT, the app allows up to five seconds within the original deadline for the selected camera’s command port to accept a connection. Retries end when the command connection opens. The timing is a software bound and remains unverified on the X-E3. Detected Local Network denial is reported separately from Wi-Fi route failure and missing multicast provisioning. If discovery arrives and unicast fails, the probe suggests checking client isolation. A network that also drops discovery can only be reported as a timeout. |
| Files | Synthetic replay enumerates a JPEG and a RAF and streams bounded Debug-only candidates after refreshing their ObjectInfo. D227 scopes ObjectInfo length reporting and does not certify original bytes. The production original-size flag remains false. Signed-iPhone discovery, camera-side registration, command identity, enumeration and both independent card-hash comparisons are all pending. |
| Completion and retry | The adapter sends no D228 database status or other AutoSave completion write. The protocol’s registration/import acknowledgement and the PTP close are network operations. Documentation describes D228 tentatively, so any implicit queue advancement, behavior after cancellation or retry, and object visibility in a second session are pending physical validation. A Photos receipt must come from the import transaction. |

The app’s X-E3 AutoSave path stays unavailable pending the signed-iPhone
result and original-file verification. A Debug build for that run also needs
the probe wired to the verified signed grant and an independent selected-body
DeviceInfo identity provider. Its current initializer supplies an unavailable
gate and an empty provider. The pinned source for the replay and diagnostic
commands is libfuji at `3b9932a46d025405dae505ddb624733b6ea3edd1`.
[Handshake notes](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/autosave.md),
[Port handling](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/discovery.c),
[PTP setup and streaming](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c)
