# Wireless import acceptance

## Firmware targets

Fujifilm’s official U.S. release pages were rechecked on 2026-11-15. The X-T5 firmware requirement is 4.30 or later, the secure pairing series. The X-E3 firmware requirement remains exactly 1.32. Firmware admission and transfer capabilities are separate checks. Pairing and identity reads can precede admission. The Mac diagnostics read `04.31` over Bluetooth on the available X-T5. The X-E3 firmware has yet to be verified by a local protocol read.

| Camera | Bundled admission | Latest official release | Intended path | Physical acceptance |
| --- | --- | --- | --- | --- |
| X-T5 | 4.30 or later | 4.32, published 2026-11-10. [Release and update instructions](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/) | Secure BLE and XApp transfer | Transfer pending on the available 4.31 body |
| X-E3 | 1.32 | 1.32, published 2026-06-23. [Release and update instructions](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/) | Legacy BLE and phone transfer, with guided PC AutoSave for RAF if needed and verified | Pending |

## Integrated regression run

The tested source revision is `835b675207d7fb25a7ae48615a8f8aaf08e29797`. The runs used Xcode 27.1 (27A9275) and an isolated iPhone 15 Pro simulator on iOS 27.0. Logs and xcresults listed below are retained locally. The [fixture provenance manifest](../../Packages/FujiCameraCore/Tests/FujiCameraCoreTests/Fixtures/Wireless/provenance.json) records the origins and limits of the protocol replays and public media.

`swift test --package-path Packages/FujiCameraCore` passed 55 XCTest cases and 141 Swift Testing cases in 20 suites. Firmware replays exercised X-T5 4.31, 4.33 and unreadable firmware and X-E3 1.31, 1.33 and unreadable firmware. iOS handoff tests also checked a contradictory BLE report. An explicit Debug probe records exact peer reports privately. Shared guidance uses the trusted target and categorical reason. Rejection precedes inventory. Log `/tmp/fuji-wifi-final-core.log`.

The complete `Scripts/test-ios.sh` run used one simulator worker, prepared native PhotoKit inputs, and `TEST_RUNNER_FUJI_STUDIO_NATIVE_LIFECYCLE=1`. It passed 248 app XCTest cases, 613 Swift Testing cases in 73 suites and 114 UI XCTest cases, with zero failures. The two UI opt-in skips were native viewer rotation and hardware Escape. Both Home and activate tests passed with a held export save and a held wireless download. The wireless import paused and required explicit reconnect. Log `/tmp/fuji-wifi-final-full.log` and xcresult `/tmp/fuji-studio-wifi-final-fixes/.build/TestResults/20261115-071507-36029.xcresult`.

Focused regressions covered saved-body reconnect before and after a pair commit, camera calendar groups and dates, held download and local Photos progress, idle-timer restoration, both mixed D226 observation orders, D227 restoration after an acknowledged enable, and unsupported requests rejected before camera I/O. An unresolved Photos submission blocks a second create for the same full verified RAF fingerprint across RAW-only and pair policy. Exact verified receipt reuse remains available. Tests covered a repeated filename with different verified RAW bytes and retry after the earlier save resolves. Logs `/tmp/fuji-wifi-final-focused-green.log`, `/tmp/fuji-wifi-final-layout-green.log` and `/tmp/fuji-wifi-final-accessibility-settled.log`.

The scoped review approved the software changes and confirmed all 14 original findings were addressed. It recorded one remaining Minor UI issue. If Camera imports opens during an explicit Bluetooth camera search, a staged job can show enabled Retry or Skip even though tapping it has no effect. Return to Status & settings, cancel the camera search, then return to Camera imports and retry the action.

The startup regression holds the saved-camera selection read while the active snapshot reaches AppModel. Before the fix it observed one USB discovery during the hold and then timed out waiting for the selected camera's BLE readiness. The fix waits for the saved preference before admitting automatic USB, reconnects the selected camera with zero USB attempts, and starts USB automatically after a successful empty selection read. A read failure remains visible at startup and explicit USB can still connect through the arbiter. The affected suites passed 69 cases. Logs `/tmp/fuji-wifi-task14-red.log` and `/tmp/fuji-wifi-task14-green.log`.

The generic Simulator Release built successfully for arm64 and x86_64 using the final production and project inputs. Only XCUI test harness edits followed the build. Demangled symbols and binary strings confirmed the wireless probe routes, private firmware observer, fixture flags and diagnostic download are present in Debug and absent in Release. Release retains the production transfer actor and its plist contains Boolean `PHPhotoLibraryPreventAutomaticLimitedAccessAlert=true`. The plist does not declare background modes. Logs `/tmp/fuji-wifi-final-release-simulator.log` and `/tmp/fuji-wifi-final-release-boundary.log`.

## Native Photos resource readback

The explicit native PhotoKit run on the tested source revision passed both cases with zero skips or failures. Both also passed during the complete run. Independent fixture verification matched every input hash and checked the X-T5 embedded JPEG's exact range. Logs `/tmp/fuji-wifi-final-native.log` and `/tmp/fuji-wifi-final-fixture-inputs.log`. Explicit xcresult `/tmp/fuji-studio-wifi-final-fixes/.build/TestResults/20261115-071504-36079.xcresult`.

The native integration tests import public CC0 RAF samples on the isolated simulator. PhotoKit creates one new asset for the X-T5 pair and one for the X-E3 standalone RAF. The tests use `PHAssetResourceManager.writeData` to read each original into a separate temporary file and verify its role, byte count and SHA-256. They also check exact filename, assigned date and location, the pair's initial JPEG display choice, the durable placeholder, and staging retention. The JPEG is the exact embedded preview of the public X-T5 RAF. These cases establish native Photos resource behavior with the listed inputs. The files enter as local staged resources, so the results do not establish camera-produced pairing or wireless fidelity against card originals. [X-T5 RAF](https://raw.pixls.us/getfile.php/6122/nice/Fujifilm%20-%20X-T5%20-%2014bit%2014bit%20compressed%20(3:2).RAF), [X-E3 RAF](https://raw.pixls.us/getfile.php/1865/nice/Fujifilm%20-%20X-E3%20-%2014bit%2014bit%20compressed%20(3:2).RAF), [CC0 license](https://creativecommons.org/publicdomain/zero/1.0/)

| Fixture | PhotoKit original role | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| X-T5 RAF | `.alternatePhoto` in pair | 43,113,376 | `b2a067e7fda16338f15c2532caa12b238b2415dc1c75a96a6d24d3445cfd0ae3` |
| X-T5 embedded JPEG | `.photo` in pair | 4,016,595 | `80f410d7f09c1d9fbd902c9c0bf52b859aa0ada585d8e6e17aa517d0b27daab4` |
| X-E3 RAF | `.photo` in standalone asset | 27,799,280 | `03d6e79ae79107c51d0e1c1c9e488a0ab20268cd9fe43f47d8ea3ea310df35c6` |

To reproduce, install the test host with a regular test run on an isolated simulator. Download the public samples as `X-T5.RAF` and `X-E3.RAF` and check them against the manifest. The X-T5 RAF supplies the JPEG offset and length as two consecutive big-endian UInt32 values starting at byte 84. Extract those bytes as `X-T5-embedded.JPG`. Copy all three inputs to `Library/Caches/NativePhotoImportFixtures` in the data container from `xcrun simctl get_app_container "$sim" com.lun3x.FujiStudio data`. Create a `RUN` marker in that directory and grant Photos read/write access with `xcrun simctl privacy "$sim" grant photos com.lun3x.FujiStudio`. Use `FUJI_STUDIO_DESTINATION="platform=iOS Simulator,id=$sim" FUJI_STUDIO_TEST_WORKERS=1 Scripts/test-ios.sh FujiStudioTests/NativePhotoImportIntegrationTests`. Leave the marker in place to include these cases in an opted-in full run. Query the data container again after the last native run and remove the marker. The tests leave their imports in the isolated simulator.

## Physical acceptance gates

| Gate | Status and evidence |
| --- | --- |
| Signed iPhone Release | **Blocked at provisioning.** The repository Release build command with development team `AZH3P824F3` and automatic signing targeted the connected iPhone 15 Pro. Xcode exited 65 because the available development profile lacks Hotspot Configuration and Access Wi-Fi Information. The exact Release bundle was unavailable for strict signature verification, entitlement inspection, installation or normal launch. The separate earlier provisioning attempt also identified the team as Personal. Logs `/tmp/fuji-wifi-task14-release-phone.log` and `/tmp/fuji-task05-phone-provisioning.log`. |
| On-device state | The Bluetooth-only Debug probe from `74eedf3c` was signed, verified, installed and launched explicitly on the iPhone. It reached Bluetooth Ready once on the X-T5. Saved reconnect disconnected during the secure status write. The probe was stopped when connection testing moved to the Mac. The integrated Release awaits provisioning. |
| Native connection and teardown | **Pending for both bodies.** Verify first pairing, reconnect after camera power cycle, selected-body-only reconnect with both nearby, denied/revoked Bluetooth and Local Network permission, native join accept/refuse, prompt inactivity, connection loss and safe WiFi teardown and USB handoff. Confirm no automatic WiFi rejoin or transfer resume and no USB Camera ready indication from the wireless state. Fixture runs exercise app admission and lifecycle. The native camera, permissions and join exchange still require the phone. |
| X-E3 PC AutoSave | **Blocked at capability and identity gates.** Apple's managed Multicast Networking grant must be available to an eligible team and the app ID. Native discovery also requires an independently verified identity for the selected body. Registration, identity stability, original RAF/JPEG exposure, queue advancement and completion markers remain pending. The default native integration reports AutoSave unavailable. Log `/tmp/fuji-task06-multicast-provisioning.log`. |
| Original bytes against card | **Pending for every route.** Acquire independent card originals and test at least 20 mixed captures per supported path where available. Include X-T5 split cards, same-card pairs, RAW-only, repeated filenames, missing mates, supported compressed and uncompressed RAF, disabled JPEG-only/HEIF/movie rows and large originals. Verify count, roles and SHA-256 of each Photos asset's originals against the independently copied card resources. The previous protected phone fixture could be listed but its bytes could not be copied and it supplied no target card evidence. |
| Physical interrupted recovery | **Pending.** Terminate during each component, between validation and save, during Photos submission and after save before receipt. Also verify cancel/background/relaunch, denied/limited/full Photos access, storage exhaustion, explicit resume, no pair downgrade or duplicate save, preservation of existing Photos and camera files, and confirmed USB handoff or visible unresolved close. Unit, fixture UI and native PhotoKit resource tests cover narrower cases. |

The release remains pending on signing, normal launch of the integrated Release,
AutoSave identity and capability verification, and the physical tests above.

## X-T5 Bluetooth model identification

On 2026-11-15 the instrumented iPhone probe reproduced the initial pairing
failure three times. The BLE link connected, service discovery succeeded, and
the camera returned Fujifilm's published X-T5 product number in Device
Information. The app rejected the model before the secure status read, and the
camera stayed in Pairing Registration. The fix recognizes this exact public
product number alongside the existing model names. The regression tests cover
secure pairing with a renamed X-T5, a conflicting model hint, and an unsupported
product number.
[Fujifilm X-T5 declaration of conformity](https://dl.fujifilm-x.com/global/products/cameras/x-t5/pdf/x-t5_doc-ysk.pdf)

The `74eedf3c` Bluetooth-only iPhone probe read and acknowledged secure status,
sent client identification, read the network-name attribute, subscribed to
eight characteristics and read the firmware attribute. The app reached Bluetooth
Ready once. The user saw the iPhone pairing dialog and a camera confirmation
number. Camera-side pairing completion remains unconfirmed. Later attempts read
secure status and disconnected before the write acknowledgement with CoreBluetooth
error 7 (`peripheralDisconnected`). Saved reconnect remains unverified.
[Fujifilm X-T5 pairing instructions](https://fujifilm-dsc.com/en/manual/x-t5/connections/usage_smartphone_app/index.html),
[Apple Core Bluetooth error](https://developer.apple.com/documentation/corebluetooth/cberror-swift.struct/code/peripheraldisconnected)

The first Mac probe attempt with the Keychain adapter from `6e2b9e6a`
discovered the X-T5, connected and identified its model. The secure status read
triggered a macOS numeric confirmation. After the Mac confirmation, the camera
reported that pairing was canceled. The status read failed with ATT error 15
(`insufficientEncryption`), and CoreBluetooth reported error 7. The probe
did not reach the acknowledgement write or save a Mac pairing.

A controlled second Mac attempt followed instructions to compare both codes,
press camera MENU/OK, then confirm on the host. The button sequence was not
independently observed. The probe completed secure
status acknowledgement, client identification, subscriptions and firmware read,
then saved its selected X-T5 record in the Mac Keychain. After an explicit
disconnect, saved reconnect established an encrypted Bluetooth link and read
secure status, but the camera disconnected during its acknowledgement write,
before an acknowledgement arrived. This reproduces the iPhone's reconnect
failure independently of iOS provisioning. The user reported “Connection lost”
and an empty pairing list; the exact camera submenu is not confirmed. Camera-side
registration and reliable saved reconnect therefore remain open. The manual
distinguishes smartphone destinations from the separate Bluetooth device list.
[Fujifilm code confirmation sequence](https://digitalcamera-support-en.fujifilm.com/digitalcameraengpcdetail?aid=000008450),
[X-T5 pairing destination menus](https://fujifilm-dsc.com/en-int/manual/x-t5/connections/network_usb_menu/)

After the user approved forgetting the Mac's X-T5 bond, the development-signed
`738f173d` probe completed the expected first-pair GATT sequence at 11:58:06 UTC
on November 15, 2026. It retained the four-byte secure-status value in memory.
The controller explicitly disconnected at 11:58:23. The next saved reconnect
read a valid four-byte value for the same verified camera; its first three bytes
differed from the first-pair baseline. The normal acknowledgment write was
followed by CoreBluetooth error 7 before a write response. Only equality flags
were recorded, not the values or hashes.

The user reported that the camera still displayed “please confirm the connection
on your device” after confirming on the Mac, then displayed “connection lost.”
The probe's ready state therefore establishes completion of its expected GATT
operations, not completion of camera-side registration. The controller's explicit
disconnect may have interrupted registration; the missing step remains unknown.
A guarded diagnostic reconnect intended to reuse the original registration
acknowledgment timed out before establishing a Bluetooth link. No substituted
acknowledgment was sent, so that hypothesis remains untested. No WiFi activation,
network join or photo transfer occurred in this run.

A later run of the buffered notification probe at `1694a307` repeated first
pairing after removing the Mac's previous X-T5 bond. Local GATT readiness was
reached at 13:01:19 UTC. The controller left the link open until 13:04:12, a
173-second hold. The user reported that the camera still displayed the code,
confirmed that MENU/OK had already been pressed to accept it, and reported that
pressing MENU/OK again had no effect. No qualifying notifications from the eight
subscribed characteristics appeared in the buffered trace after link retirement.
That result concerns callbacks delivered to the probe, not packets observed on
air. Waiting longer and repeating the camera confirmation did not produce a
camera-side completion indication in this run.

The next normal reconnect again read a different status prefix and disconnected
during its acknowledgment at 13:06:13. A guarded original-registration-value
trial connected at 13:06:25 and submitted the substituted acknowledgment to the
production Bluetooth driver. The driver logged the write, then the link closed
with CoreBluetooth error 7 before a write callback. Unlike the earlier timed-out
trial, this attempt reached the substituted write; it did not reach authenticated
readiness.
Camera receipt of that write remains unobserved. Camera-side registration, WiFi
activation and photo transfer remain unverified.

The one-subscription diagnostic at `75d41a59` then added only the geotag-request
subscription, after the configuration subscription and before the network-name
subscription. CoreBluetooth reported it active at 13:21:41 UTC. The user observed
“Pairing complete,” return to shooting, and the correct saved camera-side
registration. Buffered geotag-request callbacks followed every ten seconds. After
an explicit disconnect, the unchanged saved-reconnect path completed at 13:22:57;
both the status prefix and full value matched the successful first-pair baseline.
This run supports adding the missing subscription to first registration. It does
not establish all power-cycle, multi-camera or phone acceptance cases.

The diagnostic's WiFi activation command was rejected by its firmware admission
check at 13:23:33, before activation. After restarting the probe, normal saved
reconnect succeeded again at 13:30:01. The bounded firmware diagnostic reported
`04.31`, which the admission check at the time rejected because it required
exactly `4.32`. These hardware results
therefore do not verify firmware 4.32. No WiFi network was activated or joined
and no photo was transferred in this run.

### Follow-up automated verification

The X-T5 model fix at `74eedf3c` passed the 12 Bluetooth gateway tests on a
fresh iPhone 17 Pro simulator on iOS 27.0. The two new gateway tests reproduced
the model recognition and disagreement failures before the fix. The fast and
complete runs each executed 250 app XCTest cases with zero failures and two
native PhotoKit fixture skips. Each also passed 613 Swift Testing cases in 73
suites. Earlier native PhotoKit executions are recorded above.

The complete run used one simulator worker and enabled both native Home
lifecycle tests, which passed. It executed 116 UI XCTest cases. The native
viewer rotation and hardware Escape cases skipped. Four drawer and grid
fixture cases failed with six assertion failures. These fixture routes
construct their workspace or grid directly, without starting the native
Bluetooth gateway. The tests exercised these selectors:

- `DrawerTrajectoryTests.testShortPhotoPullSpringsBackAndScrollHandsOffOnlyAfterReachingTop`
- `PhotoGridTests.testCheckedStartSweepRemovesAndEdgeScrollExtendsRange`
- `PhotoGridTests.testDayCheckboxSelectsWholeDayFromBrowseAndReflectsPartialSelection`
- `PhotoGridTests.testFinalTwoRowViewportRevealsViewedTileAndPreservesCheckedSet`

Running these four selectors at pre-fix revision `ab44a48d` on the same
iPhone 17 Pro simulator reproduced all six failures at the same assertions.
The earlier iPhone 15 Pro full run passed these four cases.
The focused comparison log is at
`/tmp/fuji-studio-xt5-ble-ui-control/.build/ui-control-baseline.log`.

The full log and xcresult are at
`/tmp/fuji-studio-xt5-ble-diagnosis/.build/xt5-model-full.log` and
`/tmp/fuji-studio-xt5-ble-diagnosis/.build/TestResults/20261115-093657-45911.xcresult`.
The same source also built as an unsigned Simulator Release for arm64 and
x86_64. The Release binary contained the model comparison in the native gateway
with the diagnostic launch flags and report strings present only in Debug.

## Evidence matrix

The X-T5 observations above cover discovery, model identification and pairing,
including a successful Mac registration and saved reconnect on the 4.31 body.
WiFi and original file transfer remain unverified.
The other protocol observations below come from public sources. See the
[wireless protocol research](wireless-protocol-research.md) for source details.

| Check | X-T5 4.30 or later, XApp | X-E3 1.32, phone or AutoSave |
| --- | --- | --- |
| BLE pairing and reconnect | Fujifilm documents its 4.30 pairing security change and the switch to XApp on iOS. Furble’s maintainer reported secure reconnect on an updated X-T5 without specifying its firmware. The iPhone probe reached Bluetooth Ready once and later disconnected during saved reconnect. The first Mac probe disconnected during encryption setup; a later Mac diagnostic with the geotag subscription confirmed registration and saved reconnect on 4.31. [Firmware history](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/), [Furble report](https://github.com/gkoh/furble/issues/208#issuecomment-3235389619) | Fujifilm reports a Camera Remote Bluetooth pairing fix for Android 16 in 1.32. Libfuji implements legacy pairing. The target’s service layout, iOS confirmation and saved reconnect are unknown. [Firmware history](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/), [Libfuji BLE source](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/bluetooth.c) |
| Peer identity and firmware | Bluetooth reported 04.31 on the available body. PTP firmware and cross-transport peer binding remain unverified. Capture same-model peer rejection. | Unknown which values bind the saved BLE peer to phone and AutoSave sessions. Capture body firmware and cross-transport identity for the selected body. |
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
chooses files to stage privately. The probe writes an observation log, fully file-protected private firmware JSON
and per-resource SHA-256 receipts under
`Library/Application Support/WirelessProtocolProbe/<run-id>`.

| Gate | Observed result |
| --- | --- |
| Signed iPhone with native camera Wi-Fi | The configured personal development team cannot provision the Hotspot Configuration or Access Wi-Fi Information capabilities. Xcode denied the app development profile with and without automatic provisioning. Native Wi-Fi and PTP measurements remain pending on both target bodies. |
| Signed iPhone Bluetooth-only diagnostic | A temporary project without Wi-Fi entitlements built, passed strict signature verification and installed on an iPhone 15 Pro running iOS 27.0.1. The device refused the explicit diagnostic launch with a profile trust or signature error. The app identifier, team, signer certificate and target device matched the embedded profile. Pairing, protected storage and reconnect remain pending. |
| Wi-Fi network binding | The app resolves the authenticated BLE credential at the native join boundary. It checks the currently associated secured SSID through `NEHotspotNetwork.fetchCurrent` before opening PTP and again before browsing. This requires both the Wi-Fi Information entitlement and API eligibility for the current network. Unreadable or different associations fail the handoff. A previously configured network must already be associated before reuse. |
| Peer binding | The PTP adapter checks the model and applies that model’s firmware requirement to DeviceInfo before transfer setup. An observed DeviceInfo serial can be retained as a redacted digest for protected comparison. Its stability and relationship to BLE or AutoSave remain unverified. A matching secured SSID and matching model and firmware cannot distinguish peers with those same values. |
| Original size | The XApp adapter reads D226 and allows original transfer only when it observes the reference value 2. Conflicting original-size observations block originals for the current session, and an eligible transfer rechecks its selected card immediately before reading bytes. The camera operator controls the resize setting. Libfuji and the GFX100 II capture use different write widths and do not establish persistence scope on the target. Legacy phone D227 obtains the actual byte length before freezing a descriptor. That control leaves the representation unverified. Only the debug probe can stream phone diagnostic candidates for independent hash comparison, and its receipts label them as such. |
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

### Integrated registration and firmware validation, 2026-11-15

The integrated production source at `03c794f7` includes the required X-T5
first-registration subscription and the user-approved firmware policy of
X-T5 4.30 or later; X-E3 remains exactly 1.32. The complete
`Scripts/test-ios.sh` run passed 977 tests with zero failures and six opt-in
skips (two PhotoKit and four UI cases). Parameter expansion accounts for
1,046 passing instances in the device summary. The Release simulator build
also passed. The retained result is
`/tmp/fuji-xt5-registration.1Lb6fz/.build/TestResults/20261115-144749-82380.xcresult`.

On the available X-T5, the Mac probe read firmware `04.31` and completed
normal saved reconnect. With the updated firmware policy, the explicit WiFi
command passed admission, read the password and received a response to the
standard `04 00` launch write. It received no qualifying readiness notification
and timed out after 15 seconds. Camera wake state was not recorded for that
attempt. This does not establish whether the camera started its access point.
No network was joined, no PTP session was opened and no photo was transferred.
The reviewed Mac-only diagnostics at `b1148b1c` separately test an additional
reconnect subscription and the `03 00` image-viewing launch; their hardware
outcomes remain pending. Neither the automated suite nor Bluetooth registration
constitutes WiFi JPEG+RAW acceptance.

### X-T5 access-point readiness, 2026-11-15

The user awakened the 04.31 body to its shooting screen before a repeat of the
unchanged saved-reconnect flow. The `04 00` launch write was acknowledged at
14:23:24 UTC; the recognized readiness indication did not arrive before the
15-second deadline. The reviewed Mac diagnostic then added only the passive
geotag-request subscription after configuration NOT1 and before SSID. With
the same launch bytes, the camera returned the recognized readiness indication
at 14:24:36 UTC, five seconds after the write acknowledgment. The probe reported
WiFi ready and WPA Personal. macOS WiFi settings independently showed the
camera's secured access point. This comparison supports the missing reconnect
subscription as the cause of the observed readiness failure on this body.

The Mac did not join the network during this trial. The camera later displayed
a connection-wait timeout. One saved Bluetooth reconnect timed out before a
native connection was established. After the user selected BACK to return to
shooting, saved reconnect succeeded without re-pairing. No PTP session or photo
transfer was attempted. Subsequent tests will retain Bluetooth through WiFi
session establishment. The `03 00` image-viewing launch remains untested.

The production reconnect fix and Mac integration at `459fc731` subsequently
passed the complete `Scripts/test-ios.sh` suite: 978 tests (866 unit and 112 UI),
zero failures, and six opt-in skips. The expanded device summary counts 1,047
passing instances. The Release simulator build also passed. The retained
result is
`/tmp/fuji-xt5-wifi-subscription.w6QW0c/.build/TestResults/20261115-153431-91003.xcresult`.

The Mac-only identity diagnostic at `2af22413` passed six hardware-free checks
and source review. Its signed app completed normal saved Bluetooth reconnect
on the 04.31 body using the production subscription sequence. Its WiFi
preflight requested macOS Location authorization to read network identifiers,
which the user granted. The user then moved the Mac to WiFi without a wired
uplink. The probe correctly stopped with `wiredRouteUnavailable` before network
mutation. A WiFi-only trial requires a separately verified local recovery
procedure before changing to the camera network. The diagnostic is limited to
PTP initialization, opening a session, DeviceInfo, and session cleanup; it does
not enumerate or read photos.

The reviewed WiFi-only recovery implementation at `dfaba4a4` has not yet been
exercised on the Mac. Read-only preflight passed the parent Location gate but
failed to identify the current WiFi network in its helper. macOS Settings showed
Location access enabled. The read-only inspection at `e44a4264`, deployed at a
fixed app path, isolated that failure at 16:10:10 UTC: both processes saw one
powered, service-active interface, but only the GUI parent could read its SSID.
The helper could not. The first inspection in the new process reported
`notDetermined`; the second reported `authorizedAlways` without another grant.
Network association, recovery rehearsal, and PTP remain physically unverified.

The follow-up at `0cabea86` waits for the initial Location authorization
callback. On a fresh launch its first inspection recognized the existing grant
without another prompt. At 16:16:57 UTC a separate diagnostic initialized
Location in the worker: the worker reported `authorizedAlways`, but its SSID
read was still unavailable while the parent's remained available. Initializing
the worker's authorization alone did not resolve network visibility. No network
mutation or camera action occurred in either inspection.

The user subsequently returned testing to the available physical iPhone to
keep the Mac on its internet WiFi network. The Mac probe was stopped. A fresh
normal Release build from `0cabea86` failed provisioning; a second build with
automatic profile updates enabled confirmed that Personal Team `AZH3P824F3`
does not support Access WiFi Information or Hotspot. Both builds exited 65
before producing an installable app. An eligible Apple Developer Program team
and profile are still required for this iPhone WiFi trial. No replacement app
was installed, and no iPhone camera connection was attempted in this retry.

### Manual iPhone diagnostic, 2026-11-15

The user approved a temporary manual-join test with the Personal Team. The
separate Debug build opens directly as Fuji Manual WiFi and omits the product's
Hotspot and Access WiFi Information capabilities. Its network exchange is
limited to WiFi-bound XApp initialization, OpenSession, DeviceInfo and cleanup.
The user confirms the network in Settings; this diagnostic cannot independently
verify the current SSID. The normal product entitlements and association gates
are unchanged.

The signed diagnostic at `32672108` installed and launched on the physical
iPhone after strict signature verification. The first attempt read X-T5
firmware `04.31`, then activation using `03 00` failed with the profile's
`cameraBusy` result. Reading firmware and reaching the local authenticated
state did not establish that the camera had saved a phone registration. The
user subsequently completed phone pairing and explicitly confirmed successful
registration on the camera. That attempt also returned `cameraBusy` during
WiFi activation. No phone WiFi association, PTP identity or photo transfer was
verified.

The user observed two same-name saved app records and two camera destinations
named Fuji Studio. Neither list's names establish which entry is current.
The reviewed diagnostic at `73a40f69` uses the distinct Bluetooth identification
name Fuji iPhone, separates Bluetooth setup from WiFi startup, and requires
explicit user confirmation of the named camera destination. It labels local
records separately and offers nearby reconnect only for one exact saved
peripheral/model match, without deleting or merging records. Fourteen focused
unit tests and the manual-flow UI test passed. Its signed bundle was verified,
installed and launched. The user then removed both old camera destinations,
forgot the camera on the phone, and completed a fresh pairing. The camera
displayed Fuji iPhone, which the user confirmed in the diagnostic. The subsequent
`03 00` activation still returned `cameraBusy` before any WiFi-ready result.
The earlier Mac registration is no longer present after that user-initiated
reset. The duplicate app records were not deleted by the diagnostic.

The diagnostic at `407d9d03` uses the guarded standard `04 00` activation for
the next controlled trial, retaining the named-registration and manual-join
checks. Its 16 focused unit tests and UI test passed, and the signed build was
verified, installed and launched. The standard command's iPhone hardware
outcome is pending. The full simulator suite at the earlier `32672108` passed
989 tests with zero failures and six skips (1,058 expanded passing instances).
The task simulator and its test clones were removed after validation.

On 2026-11-16, the signed manual diagnostic at `81d9a731` found the saved
X-T5 using its reconnect advertisement. Bluetooth reconnected and reported
firmware `04.31` at 09:31:40 UTC. The user confirmed the phone registration
at 09:31:48 UTC. The standard activation phase began at 09:31:49 UTC and
ended with `wifiReadinessTimeout` at 09:32:04 UTC. The camera remained on its
normal shooting display. The phone did not reach manual WiFi handoff or PTP
identity verification.

The phase report records the requested launch mode and final timeout. The
Debug-only `ManualWiFiBluetoothTrace.json` in Documents records protected,
bounded evidence for the next trial, including the known subscriptions,
password-read milestones, guarded standard-write submission, write
acknowledgement, and readiness notification classifications and lengths.
The trace starts fresh with the manual diagnostic and excludes identifiers,
credentials, and raw notification data.

### Empty DeviceInfo during the manual iPhone connection check

The next physical trace reached the camera's PTP socket, received a 68-byte
initialization acknowledgement and opened a session. The GetDeviceInfo
transaction consumed a 12-byte data header and a 12-byte success response.
The trace shows the data and final response phases completed before the
dataset parser rejected the zero-byte payload. The ACK size does not
identify the camera. Libgphoto2 documents this empty data phase for Fuji Wi-Fi
on an X-T4 and substitutes a driver dataset. Fuji Studio only reports fields
it received from the relevant link.
[Libgphoto2 Fuji Wi-Fi data handler](https://github.com/gphoto/libgphoto2/blob/31a2f4089f19aec6caca7920b03e3eb7a251c5b6/camlibs/ptp2/fujiptpip.c#L503-L540)

After this exact empty-success result, the Debug manual check reads D212
(EventsList) and polls every 100 ms until DF00 reports access state 6.
It verifies a four-byte DF24 (RemoteVersion) in the supported XApp range
`0x20007...0x2000c`. The startup checks use the core's 30-second budget
and remain subject to the manual check's existing 20-second deadline.
Pinned libfuji polls D212 and reads DF24 after opening the session.
Its public X-T5 log shows DF00 = 6 and DF24 = `0x2000b`, with camera firmware
unspecified. On the 04.31 body, the startup sequence and any later availability
of standard DeviceInfo still require physical evidence.
[Libfuji camera-hosted setup](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c#L399-L501)
[Libfuji X-T5 capture](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/testsuite/fudge-log-x5.txt#L5-L85)

For the next trial, use the paired X-T5, verify Fuji iPhone on the camera,
join the camera network in Settings, then choose **Check camera connection**.
If DeviceInfo is available, expect the existing identified result. If the
camera answers with the empty dataset and passes both startup checks, expect
`sessionResponding`, Bluetooth-sourced model and firmware, and Wi-Fi identity
unavailable. Confirm the zero-byte DeviceInfo milestone, access and version
validation, and socket cleanup in the bounded trace. The check issues no
gallery writes, inventory requests, or photo operations. Independent Wi-Fi
identity and transfer admission still require validated DeviceInfo.

### Manual X-T5 gallery diagnostic

The connection check at `3ffe900e` opened a PTP session on the 04.31
X-T5, received empty DeviceInfo, then validated access state 6 and a supported
remote version before closing. The trace reached the result in 182 ms.
The user reported that the camera stayed on “Waiting for connected” and later
showed “Not found.” This was a brief protocol response, with no confirmed
gallery connection or independent Wi-Fi identity.

The first Debug gallery test reused the camera-hosted session and gallery setup used
by the adapter. After the Bluetooth firmware guard, it opens a fresh session
and validates DeviceInfo when present, waits for XApp access, and checks
RemoteVersion before the first gallery write. The sequence uses DF01 mode 20,
echoes DF28, confirms each D244 card selection, and runs 9054, 9055, 9050,
D212, D22B and 9053 in that order before reading D620 and D621. The card
handles must agree with both counts. The test requested GetObjectInfo for at
most the first 32 handles per available card, in the order returned by the
camera. The on-screen JPEG, RAF and other counts described that sample.
A card with zero objects is distinct from an unavailable card (9054 returning
StoreNotAvailable). The phone displays reported filenames, formats and sizes
after cleanup. It does not fetch thumbnails or originals or write to Photos.
The camera's 9055 setup response may include preview bytes; the transport
bounds and discards that response.
[Libfuji gallery setup and card inventory](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c#L211-L245)
[Libfuji XApp setup and ordered listing](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c#L310-L535)
[GFX100 II firmware 2.30 transfer capture](https://github.com/epsalmond/ptpsim/blob/a2cea30d8622ba9e71d49338b0d0eda20b664689/packages/camera-config-data/fuji/gfx100ii/evidence/IMAGE_TRANSFER_FW230.md)

The reference capture is from a different body. The diagnostic does not
replay its D226/D227 resize writes: property widths and persistence on the
X-T5 are unverified. If gallery setup fails, the omitted writes are one
unresolved protocol difference. The implementation does not change production
peer admission. Empty DeviceInfo is acceptable for this bounded test and
remains inadequate to admit production transfer.

#### Physical gallery listing on X-T5 04.31

The signed iPhone diagnostic at `648de221` completed gallery setup with empty
DeviceInfo. Card 2 returned 542 handles and the first 32 ObjectInfo datasets
were JPEG. Card 1 returned StoreNotAvailable (0x2013) at 9054. The camera moved
from “Waiting for connected” to a dark display and continued answering.
CloseSession and native socket teardown completed, with 2,665 ms from the
start of the gallery attempt to closure. This establishes metadata access to
the available card. RAW exposure beyond the 32-object sample and independent
Wi-Fi identity remained unverified.

#### Full scan and one pair candidate on the next iPhone trial

Use the existing Fuji iPhone pairing, start a new Bluetooth handoff and join
the camera network in Settings. Confirm the join in the diagnostic, then tap
**Test JPEG+RAW download**. **Scan all photos** performs the metadata portion
alone. Both actions read every validated handle on available cards within the
existing 100,000-object limit per card. The result reports full JPEG, RAF and
other counts and distinguishes unavailable cards. The app shows at most the
first 32 rows per card. If reading an available card fails, the scan is
incomplete and the pair test cannot select files. The 10-minute foreground
deadline includes socket teardown and the app keeps the screen awake during
the operation. The connection-only check retains its 20-second deadline.

The pair test uses the complete inventory to find a reciprocal, unambiguous
pair. It prefers a same-card pair and can select a corroborated split-card
pair. If no pair qualifies, the app closes the connection without requesting
file bytes. Otherwise it rereads the correct slot and ObjectInfo as needed,
then streams the RAF and JPEG serially using GetPartialObject (101B), bounded
to 1 MiB per request. It reads D226 before each candidate and records the
observation without changing D226 or D227.
[Libfuji XApp transfer reference](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c#L875)
[GFX100 II firmware 2.30 transfer capture](https://github.com/epsalmond/ptpsim/blob/a2cea30d8622ba9e71d49338b0d0eda20b664689/packages/camera-config-data/fuji/gfx100ii/evidence/IMAGE_TRANSFER_FW230.md)

The completed private manifest is at `Documents/ManualWiFiPair/completed/manifest.json`
inside the diagnostic's container. It records exact lengths, SHA-256 hashes,
camera filenames and validation evidence for the two candidate files. JPEG and
RAF validation checks the file structure, model, and agreement of the embedded
capture times with the selected ObjectInfo timestamps. The app
publishes the pair after socket teardown and maintains the previous complete
pair through a failed replacement. The shared trace reports stages, counts,
byte totals, response codes and validation outcomes without filenames, object
handles or file paths. No file is saved to Photos.

Record the full card results, any files transferred, the observed D226 values,
and the camera display through socket close. Compare each private SHA-256
against the corresponding independently read SD or USB card file before
claiming original-size byte equality. A D226 value of 2 records the reference
control state only. A complete pair trial remains pending on the physical X-T5.
