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
