# Fujifilm wireless import protocol research

Research date: 2026-11-14. Repository baseline: `8eec2a26` (`main@origin`).
Status: research only; no Fuji Studio wireless implementation or physical wireless
camera test has been performed. External observations below belong to their
authors, not to this project.

Scope update, 2026-11-14: the user subsequently chose **latest firmware only**
for both cameras. The [current design](../superpowers/specs/2026-11-14-camera-wifi-import-design.md)
supersedes the broad-firmware request and recommendations below. Current targets
are X-T5 4.32 and X-E3 1.32. The historical protocol findings remain reference
material, not requirements to support older releases.

## Requested behavior

Support X-T5 and X-E3 across firmware versions wherever reasonably possible.
Reconnect to the user's paired camera over Bluetooth while the app is open.
The existing status button opens connection settings; an explicit WiFi action
asks the camera to start its network, then uses the iPhone's join confirmation.
Import the original camera JPEG and RAF as one Photos asset when both exist.

## Findings

There are public implementations and some hardware-confirmed protocol reports.
They provide a credible starting point, but not proof of the entire requested
flow on both models or every firmware release. Bluetooth pairing, WiFi startup,
PTP session setup, original-file access, and Photos pairing are separate gates.

| Camera / firmware family | Evidence | Proposed support policy |
| --- | --- | --- |
| X-T5 before 3.01 | Fujifilm's 3.01 release notes introduce RAW transfer to XApp. Earlier wireless RAW access is not established by the sources inspected. | Attempt the known advertised connection protocol; expose only verified file capabilities. Do not promise RAW based on model alone. |
| X-T5 3.01 through 4.21 | Official RAW transfer support; predates the documented 4.30 security transition. | Target the older BLE pairing flow and the available XApp transfer protocol. Confirm both full originals on hardware. |
| X-T5 4.30 and newer, through current 4.32 | Official pairing/security transition in 4.30. Public secure BLE implementation and an updated-X-T5 reconnection report exist. | Support secure bonding as well as the original pairing flow; select by discovered protocol, with firmware retained for diagnostics. |
| X-E3, through current 1.32 | Official phone transfer, Bluetooth, and PC AutoSave support. Its transfer-order documentation excludes RAW. No inspected third-party report proves original RAF download through its phone-transfer mode. | Target legacy phone connectivity; investigate PC AutoSave for RAW+JPEG. Do not silently substitute JPEG-only imports. |

Firmware boundaries come from the [X-T5 release history](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/).
The [X-E3 history](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/)
records a Camera Remote freeze fix in 1.31, an Android 16 pairing fix in 1.32,
and router stability improvements in 1.22. These are reasons to retain recovery
and troubleshooting paths; they do not establish an iOS failure on every older
release. Future firmware is not implicitly certified.

## Published protocol sources and evidence strength

### 1. Furble: BLE pairing and reconnect

The [protocol documentation](https://github.com/gkoh/furble/wiki/Protocol-Documentation)
describes the Fujifilm manufacturer advertisement, token-based legacy pairing,
client identification, and notification subscriptions. It distinguishes older
unencrypted connections from newer bonding-based connections.

The [tested-camera list](https://github.com/gkoh/furble/tree/0cac22aacc3d9ef250be40849118af78a5f39f27#supported-cameras)
includes X-T5, but does not list X-E3. This is BLE remote-control evidence, not
image-transfer evidence.

In [issue 208](https://github.com/gkoh/furble/issues/208#issuecomment-3235389619),
the maintainer specifically reported reconnection working with an updated X-T5.
The thread tracks captured HCI traffic, iterative hardware tests, and subsequent
release in v3.5.0. The report does not specify the exact X-T5 firmware version.
Other models initially had reconnect problems; a successful initial pair is not
sufficient acceptance for our foreground reconnect loop.

Source revision inspected: `0cac22aacc3d9ef250be40849118af78a5f39f27`.
[FujifilmSecure.cpp](https://github.com/gkoh/furble/blob/0cac22aacc3d9ef250be40849118af78a5f39f27/lib/furble/FujifilmSecure.cpp)
contains secure connection, a four-byte status read/acknowledgement, client-name
write and subscription ordering. Its ESP32/NimBLE transport must be adapted to
CoreBluetooth; it is not an iOS library. MIT licensed.

### 2. Libfuji / Fudge: BLE-to-WiFi and file transfer

[Libfuji](https://github.com/petabyt/libfuji/tree/3b9932a46d025405dae505ddb624733b6ea3edd1)
implements legacy and secure BLE, camera-hosted WiFi, PC AutoSave and other Fuji
modes. Source revision inspected: `3b9932a46d025405dae505ddb624733b6ea3edd1`.
The current Fudge frontend is Android; no complete native iOS integration follows
from that support claim. MIT licensed protocol code.

[bluetooth.c](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/bluetooth.c)
contains the missing handoff pieces:

- SSID characteristic `bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4` and password
  characteristic `e809256a-915c-4967-92e8-53b7d4cad213` under service
  `4e941240-d01d-46b9-a5ea-67636806830b`.
- WiFi launch write `04 00` to `600655e6-3637-42f1-8fb2-44efc5c63b13` under
  service `6514eb81-4e8f-458d-aa2a-e691336cdfac`.
- Legacy pairing service `91f1de68-dff6-466e-8b65-ff13b0f16fb8` and secure
  pairing service `123d8f06-62a1-4935-9322-833c531ee225`.

These are implementation observations, not a universal command contract. The
file retains uncertainty about WiFi readiness, BSSID correspondence and mode
selection. In particular, do not copy timeout-to-success behavior or assume a
missing password characteristic proves an open network.

[fuji.c](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/lib/fuji.c)
implements distinct Camera Remote and XApp setup, version properties, card
selection, object enumeration and chunked GetPartialObject downloads. It uses
different original-size controls in the two transfer modes. Its mode-selection
heuristic remains explicitly provisional. The presence of generic object
download code does not prove RAF exposure on an X-E3.

[Issue 7](https://github.com/petabyt/libfuji/issues/7) provides a concrete X-E5
1.12 BLE pairing and WiFi association report, followed by a PTP connection
failure. The author later attributed it to an Android permission. It confirms
parts of the handoff on that body, not a successful X-T5/X-E3 RAW import.
Some older documentation still says Bluetooth is unsupported; current source
and dated commits supersede that statement, not the other way around.

### 3. Packet captures: modern JPEG and RAF enumeration

The independent [ptpsim image-transfer record](https://github.com/epsalmond/ptpsim/blob/a2cea30d8622ba9e71d49338b0d0eda20b664689/packages/camera-config-data/fuji/gfx100ii/evidence/IMAGE_TRANSFER_FW230.md)
documents reference-app wire captures and direct observations on **GFX100 II
2.30**. It records JPEG and RAF ObjectInfo responses, filtered object handles,
and chunked object downloads. The sequence includes client mode 20, version
property DF28, card selection D244, and the ordered 9054/9055/9050/9053 setup
before D620/D621 enumeration. Omitting steps caused an observed timeout.

This is stronger evidence than a list of guessed opcodes. It is still evidence
for another model. The record explicitly says the BLE import-launch write was
not captured. Its chunk sizes and advisory-property types must not be copied
into an all-firmware contract without target-camera verification.

Revision inspected: `a2cea30d8622ba9e71d49338b0d0eda20b664689`.

### 4. Older WiFi and PC AutoSave

The Fudge author's [2024 protocol write-up](https://danielc.dev/blog/fudge1/)
describes working older-camera downloads and Fuji's unusual transport: a PTP/IP
initial handshake followed by USB-style PTP framing over TCP, normally on port
55740. It also describes PC AutoSave as a route for RAF, JPEG and MOV files over
a shared network. Its then-future Bluetooth work is historical, not the current
implementation status.

[Libfuji's AutoSave protocol notes](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/autosave.md)
publish discovery/registration messages and ports 51540, 51541 and 51542; the
example identifies an X-H1. Its [developer notes](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/dev.md)
explicitly distinguish RAF-capable AutoSave from older phone WiFi transfer.
That broad older-mode statement must not be applied to newer RAW-capable XApp.

Fujifilm [lists X-E3 as PC AutoSave compatible](https://www.fujifilm-x.com/global/support/compatibility/software/pc-autosave/).
Its [wireless manual](https://fujifilm-dsc.com/en-int/manual/x-e3/connections/wireless/index.html)
describes joining a network and starting PC AutoSave from the camera.
Its [playback manual](https://fujifilm-dsc.com/en/manual/x-e3/playback/menu_playback/index.html)
excludes RAW from smartphone transfer orders. That exclusion alone is not proof
that every possible PTP download route rejects RAW.

**Conclusion:** PC AutoSave is a credible X-E3 wireless RAW fallback to test.
No inspected source verifies triggering it over Bluetooth with the requested
one-button camera-hotspot flow. Plan for a shared WiFi network and camera-side
setup/start unless a hardware experiment proves otherwise. An iPhone Personal
Hotspot topology is also unverified and must not be promised as equivalent.

## iOS and existing-app implications

- Use CoreBluetooth for saved-camera reconnection while foregrounded. Initial
  pairing requires an explicit camera selection; reconnect should not pair with
  arbitrary nearby cameras or repeatedly prompt after a refusal. Keep WiFi
  activation explicit. Pairing credentials need protected local storage.
- Apple's [NEHotspotConfigurationManager](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager)
  supplies the native join prompt and requires the Hotspot Configuration
  capability. Joining alone does not establish a usable camera PTP session.
- [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
  requires Local Network permission and explains that iOS broadcast/multicast
  reception needs the multicast entitlement. AutoSave's discovery therefore has
  a separate signed-device/provisioning gate. A simulator cannot validate that.
- The status sheet is in `FujiStudio/Workspace/ExportProgressView.swift`.
  `AppModel` already coordinates foreground-only USB discovery. Wireless import
  needs its own state and capability reporting so BLE-connected is not mistaken
  for USB recipe-processing readiness.
- `NativePhotoPairGateway` already creates a JPEG `.photo` plus RAF
  `.alternatePhoto`. Its current caller also replaces an existing library asset;
  camera import must instead create a new pair without invoking replacement
  deletion. Preserve original files and capture metadata, verify both saved
  resources, and retain a durable import receipt for retry deduplication.

## Recommended approach and alternatives

**Recommended:** native Swift protocol adapters selected from advertised GATT
services and negotiated PTP capabilities, informed by the pinned MIT sources.
Implement both pairing generations and both phone-transfer protocols. Add a
guided X-E3 AutoSave path if hardware verification confirms original RAF+JPEG
access. This best fits the existing Swift app and broad firmware requirement.

**Alternative:** embed libfuji with its C/runtime dependencies and provide an iOS
platform layer. This follows upstream more directly, but is not a drop-in
library: current code includes app/runtime integration and provisional behavior
that the importer would still need to contain and validate.

Restricting support to new X-T5 firmware would simplify implementation but does
not meet the requested two-camera scope. A manual-WiFi-only implementation also
does not meet the requested Bluetooth handoff.

## Required verification before claiming support

1. On each available body, record firmware, discovered BLE services and transfer
   capabilities. Verify first pairing, saved reconnect, camera power cycling,
   app foreground transitions and denied/cancelled permission recovery.
2. Prove WiFi launch, native iPhone join, PTP readiness and clean disconnect as
   separate steps. Verify that stale credentials and dropped sessions recover.
3. With known RAW+JPEG captures, enumerate and download both originals. Compare
   hashes against card/USB copies; test resize settings, RAW-only captures,
   missing mates, repeated filenames and X-T5 split-card pairs.
4. Test X-E3 AutoSave registration, discovery, full-original download and the
   signed-iPhone network entitlement before claiming an iOS fallback works.
5. Verify a single Photos item contains both original resources. Test interrupted
   downloads, insufficient storage and uncertain Photos completion without
   duplicate pairs. Camera originals must remain on the card.
6. Exercise packet fixtures for both BLE and PTP families, then affected UI tests
   and the complete project suite using an isolated simulator. Simulator success
   establishes software behavior, not camera/firmware compatibility.

The compatibility policy should distinguish externally reported, locally
verified and unverified firmware/protocol combinations. Avoid exact-firmware
allowlists where a known protocol works, while refusing unsupported operations
and never labelling a JPEG-only transfer as a completed RAW+JPEG import.
