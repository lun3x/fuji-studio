# Wi-Fi investigation checkpoint — 2026-11-16

This is the current handoff for the X-T5 JPEG+RAW Wi-Fi investigation. Read it
before repeating a hardware test. The detailed chronological record is
[wireless-import-acceptance.md](wireless-import-acceptance.md). Earlier statements
there that a particular trial is pending are superseded by the results below.
The approved [feature specification](../superpowers/specs/2026-11-14-camera-wifi-import-design.md)
and [implementation plan](../superpowers/plans/2026-11-14-camera-wifi-import.md)
remain on this branch as well.

## Current outcome

- Camera: X-T5 firmware **04.31**. Approved support policy: X-T5 **4.30 or later**,
  X-E3 **1.32**. X-E3 Wi-Fi hardware acceptance remains outstanding.
- Native Bluetooth registration, Wi-Fi launch, manual iPhone association, native
  TCP/PTP setup and JPEG gallery enumeration have worked. **Native RAW exposure
  and a successful native JPEG+RAW download have not been established.**
- The prior full metadata trial used source revision `1885339990c5c156ac8bb15c28a981ead92dfe6c`.
  The user forgot the phone bond and paired again. Image-viewing launch `03 00`
  succeeded on its **first** acknowledged request; positive readiness followed
  about seven seconds later. No busy retry was needed in this trial.
- The camera still returned **DF28 = 2**. Card 2 had **548** handles before and
  after the JPEG+RAW filter. All 548 ObjectInfo results were JPEG, format `3801`.
  There were no RAF entries and no `101B` download requests. Slot 1 was unavailable.
  Session cleanup completed; this was not a TCP timeout.
- The count and validated handle list arrived about **1.215 seconds** after TCP
  startup. Scanning all metadata and closing took **235.124 seconds**.
- Fresh official XApp on the same camera exposed **1,239** unfiltered objects:
  **548 JPEG + 619 RAW + 72 other**. A combined JPEG+RAW inventory would therefore
  be 1,167 for that observed card state. Counts change with card content; neither
  548 nor 1,167 is a production admission rule or a format classifier.
- The user reports that switching between XApp and Fuji Studio requires forgetting
  the phone's X-T5 bond and pairing again. The latest native log first reported
  no paired camera found, then recorded successful new pairing. This does not
  establish the cause of the cross-app pairing problem. Do not treat such switches
  as preserving an unchanged registration baseline.

## Code and next diagnostic

Source revision `9fd5b43d87c7bf2bb23744aed44a4aadabab5cb7` adds **Check photo counts**
to the existing Debug manual Wi-Fi screen. It requires the same camera selection,
registration confirmation and manual network confirmation as the full scan.
It uses the same gallery setup, JPEG+RAW filter, D620 count and validated D621 list,
checks both card slots, then awaits native session closure before showing results.
It distinguishes an unavailable card from an available empty card.

This action does not loop over `1008` ObjectInfo, change D226, stage a pair or fetch
original files. The required `9055` gallery setup can still return a thumbnail.
Its trace kind is distinct from full scans and pair downloads. Full metadata scan
and **Test JPEG+RAW download** remain separate explicit actions.

### First physical count trial

The X-T5 on firmware 04.31 reconnected using the saved Fuji Studio pairing.
The first `03 00` launch write was acknowledged and positive readiness followed
about five seconds later. The count run started at 17:36:02 UTC on November 16.

| Milestone | Result | Elapsed from count start |
| --- | --- | ---: |
| DF28 validation | Camera offered 2 and the app echoed 2 | 735 ms |
| Card 2 initial inventory | 548 validated handles | 1,248 ms |
| Card 2 after acknowledged JPEG+RAW filter | 548 validated handles | 1,460 ms |
| Card 1 gallery open | `0x2013`, card unavailable | 1,644 ms |
| CloseSession and socket closure | Completed | 1,654 ms |
| Count attempt | Completed | 1,655 ms |

The count reproduces the prior restricted inventory size. Format evidence comes
from the earlier full scan, which classified all 548 entries as JPEG. Use the
count action for subsequent negotiation experiments. A larger count still needs
format enumeration and a validated pair download to establish JPEG+RAW support.

Earlier in the same app session, a pair attempt also read DF28 = 2 and counted
548 handles before and after the filter. It then changed card 2's D226 from 0 to 2
and was cancelled during ObjectInfo after classifying 15 JPEGs. The socket closed
and the trace marked restoration of D226 to 0 unconfirmed. The intervening Wi-Fi
handoff expired before a TCP probe. The successful count run did not read D226,
so its starting transfer mode is unknown. The pair attempt had already hit the
same DF28 and handle counts before writing D226.

## Protocol facts established by captures

### TCP startup and gallery negotiation

The command socket is camera-hosted TCP port 55740. Native Fuji framing and the
initialization exchange are implemented directly; do not substitute a generic
PTP/IP handshake. The manual initialization is 82 bytes with the established
version word `8f53e4f2`, a 16-byte field, and a padded UTF-16 client name.
The manual field is the fixed prefix
`ad a5 48 5d 87 b2 7f 0b d3 d5 de d0` followed by the connected local IPv4 octets
in reverse order. It requires an actual ready IPv4 socket. The previous random
field was corrected and matching bytes were confirmed in a real native capture;
this **did not** change DF28 or expose RAW. The client name still differs from XApp.

The latest complete XApp socket begins:

1. OpenSession `1002 [1]`.
2. Read D212; initial access state DF00 is 6.
3. Set DF01 to UInt16 20 (`14 00`).
4. Read DF28: **3**, then echo UInt32 3.
5. Read D244, read D212, confirm D244, and configure the selected card.

Native uses the same command prefix but reads **2**, then echoes 2. The difference
exists before the DF28 setter. The older official trace's apparent cold socket
was actually a second socket: capture of its first session started mid-session.
The fresh capture began before XApp connection and confirms the first complete
socket already reads 3. No missing earlier PTP command was found on that socket.
The capture was restricted to TCP 55740 and does not rule out other network or
Bluetooth setup.

Timing remains an untested variable: XApp waited about 205–207 ms after OpenSession
ACK before D212; native waited about 1 ms. In the fresh XApp trace, D212 ACK to
DF01 request was about 392 ms, versus about 1 ms native. These are observations,
not proof of a required delay. No arbitrary delay or forced DF28 = 3 was added.

Native gallery configuration confirms D244 per slot, uses `9054 [10000001]`,
`9055 [10000001]`, `9050`, D212, D22B, and then `9053 [0,30000]`, D212, D620, D621.
It validates the cold inventory before applying the filter and refreshing again.
Only the final validated handles drive the scan. D22B is not assumed to be the
object count. Unavailable slots are recognized by `9054` response `2013`.

GetDeviceInfo (`1001`) returned an actual empty data container followed by success
on the physical X-T5. The Debug gallery follows the captured startup without
GetDeviceInfo or DF24. The separate connection check can report this empty result.
**Production independent Wi-Fi identity/admission has not been weakened** to
manufacture identity from Bluetooth or a successful socket.

### Captured filter bytes

Operation `9051` has **zero command parameters**. Its data phase is:

| Filter | Exact payload |
| --- | --- |
| JPEG | `01 00 00 00 08 00 00 00 04 d6 01 00` |
| RAW | `01 00 00 00 08 00 00 00 04 d6 10 00` |
| JPEG+RAW | `01 00 00 00 08 00 00 00 04 d6 11 00` |
| Empty filter reset | `00 00 00 00` |

Official captures demonstrated changing format inventories. In an earlier card
state, combined was exactly the union of 542 JPEG and 613 RAW handles, totaling
1,155; unfiltered was 1,227. Later content added six JPEG and six RAW entries.
Native's 548 handles include every earlier JPEG handle plus the additions and
none of the observed RAW handles. Native ACKed the exact combined payload yet
returned a byte-identical 548-handle list. Both the empty reset and combined-filter
experiments were insufficient to resolve native RAW exposure.

### D212 event records

The normal layout is UInt16 count plus fixed six-byte records: UInt16 property
and UInt32 value. XApp additionally returned these exact short terminal forms:

- Single D22F: `01 00 2f d2 01 00 00`.
- Numeric D21B = 15 followed by short D22F:
  `02 00 1b d2 0f 00 00 00 2f d2 01 00 00`.

The latter occurred after repeated unavailable-slot-1 replies in XApp. The decoder
now accepts the exact five-byte terminal D22F suffix only in XApp mode, with the
declared count and one-byte total-length deficit checked. It preserves preceding
numeric records and does not invent a numeric D22F value. Full-width numeric
D22F, strict malformed-data rejection, and legacy behavior remain intact.
The regression replay places the mixed batch after switching to slot 2; that
placement tests possible queued delivery and was not the observed XApp ordering.

### Original-size JPEG observations

An official original JPEG download was captured successfully. Initially ObjectInfo
reported 167,936 bytes at 7,728×5,152. D226 = UInt16 1 changed it to 3,345,240 bytes
at 3,840×2,560. D226 = UInt16 2 changed it to 24,667,151 bytes at 7,728×5,152;
the captured partial-object responses delivered exactly that count and decoded
at those dimensions. XApp used two chunks of 12,582,880 and 12,084,271 bytes.
No D227 access appeared in that capture. Cross-session/per-card persistence of
D226 was not established, nor was independent equality with card bytes.

The native full-scan/pair diagnostic selects and confirms D226 = 2 before freezing
ObjectInfo and rechecks it before transfer. It keeps bounded 1 MiB chunks and
exact object/length checks. When it changes D226, it restores the saved value on
the appropriate card before switching or closing; uncertain restoration blocks
publication. This mechanism has not yet produced a successful native RAF pair.

## Bluetooth, platform constraints, and earlier investigation

The secure profile uses an OS bond, reads the four-byte secure status and echoes
its first three bytes with fourth byte `20`, then identifies the client. Firmware,
subscriptions and camera-side registration must actually complete; an OS pairing
prompt alone was not proof of a saved camera registration. Earlier one-subscription
attempts left the camera waiting. Registration and later access-point tests required
the investigated notification subscriptions; their chronology and individual trials
are retained in the main acceptance record. The phone destination is **Fuji iPhone**.

Mac testing isolated camera-side confirmation, process signing identity, registration
subscriptions and Wi-Fi activation. Later, macOS Location/Wi-Fi visibility differed
between the GUI parent and its helper, even after authorization. The user moved
back to iPhone testing so the Mac could retain internet Wi-Fi. Do not silently
move the Mac onto the camera network.

The user has only Personal Team `AZH3P824F3`. Normal Hotspot/Access WiFi Information
capabilities could not be signed. The user authorized a separate signed **Debug
manual Wi-Fi diagnostic**, with those capabilities omitted and the user joining
the camera network in Settings. Production entitlements and association checks
are unchanged. The diagnostic cannot independently read/verify the current SSID.

Earlier `03 00` attempts stopped on the first busy reply, so the diagnostic used
`04 00` during much of the TCP investigation. Verified reference implementations
identify 3 as image viewing and 4 as remote shooting, with bounded busy retries for
image viewing. The current Debug wrapper sends 3, retries only after busy and ACK,
waits 200 ms, and allows at most three writes. It cancels pending work on a positive
readiness result, disconnect, selection change or cancellation. Launching `02 80`
is not treated as success. Production and Mac probe behavior were not changed by
that Debug wrapper fix. The latest real `03 00` success with DF28 still 2 means the
launch correction did not, by itself, resolve the RAW discrepancy.

## Reference implementations and evidence limits

- [libfuji pinned implementation](https://github.com/petabyt/libfuji/tree/3b9932a46d025405dae505ddb624733b6ea3edd1):
  `lib/fuji.c`, `lib/bluetooth.c`, `lib/fujiptp.h`, and its
  [X-T5 test log](https://github.com/petabyt/libfuji/blob/3b9932a46d025405dae505ddb624733b6ea3edd1/docs/testsuite/fudge-log-x5.txt).
  Its X-T5 log reads DF28 = 3 before a PTP setter, but omits preceding BLE/retained
  state and firmware. Its generic event parsing is not proof that short data is safe.
- [Fuji Bridge Bluetooth implementation](https://github.com/Th0rgal/fuji-bridge/blob/38fc4275574c2016a1f13ece13496b0ad1e9b452/FujiBridge/FujiBluetooth.swift):
  XApp-derived launch mapping and 200 ms busy recovery, at most three requests.
- [Dial In protocol observations](https://github.com/maam00/dialin-tools/blob/848a651c926a44c6f7b5bc1d1f44b27e8a50b959/docs/FUJIFILM-PROTOCOL.md)
  and [TCP implementation](https://github.com/maam00/dialin-tools/blob/848a651c926a44c6f7b5bc1d1f44b27e8a50b959/ios/DialInCamera/Sources/DialInCamera/Import/FujiPTPIPTransport.swift):
  initialization field and X100VI launch observations. Cross-model observations
  are not X-T5 RAW acceptance, and no verified native RAW success was inferred.
- [Apple Bluetooth tracing](https://developer.apple.com/videos/play/wwdc2019/901/)
  and [logging profiles](https://developer.apple.com/feedback-assistant/profiles-and-logs/):
  an iOS Bluetooth ATT/HCI capture would directly compare XApp's pre-TCP setup.
  RVI captures used so far contain IP traffic, not GATT. No such ATT capture has
  yet been collected, and no logging profile was installed for this investigation.

## Local evidence inventory

Raw captures and app logs remain private local evidence, not repository content.
The portable findings and relevant non-identifying payloads are recorded above.
Do not delete these workspaces while the investigation continues:

| Location | Contents |
| --- | --- |
| `/tmp/fuji-raw-exposure-probe/.build/ReferenceCapture` | Original XApp filter and original-JPEG captures, normalized captures, TSVs, analyzers, private JPEG hash metadata. First filter capture starts mid-session. |
| `/tmp/fuji-gallery-sequence-fix/.build/SequenceCapture` | Native startup failing on short D22F, before parser correction. |
| `/tmp/fuji-gallery-event-version/.build/EventVersionCapture` | Native corrected initialization and parser trial: still DF28 2 / 548 JPEGs. |
| `/tmp/fuji-gallery-event-version/.build/PhoneEvidence/event-version-trial` | Matching native app trace and phase evidence. |
| `/tmp/fuji-gallery-negotiation/.build/XAppFreshCapture` | Full first XApp socket, DF28 3, slot transition, 1,239 inventory and RAW filter 619; `analyze.cjs`, TSV and count summary. |
| `/tmp/fuji-gallery-negotiation/.build/ImageViewingCapture` | Latest native `03 00` trial's TCP capture, 548 JPEG scan, successful close. |
| `/tmp/fuji-gallery-negotiation/.build/PhoneEvidence/image-viewing-trial` | Latest `bluetooth.json`, `phase.json`, `identity.json`. |
| `/tmp/fuji-gallery-negotiation/.superpowers/negotiation` | Protocol audit, implementation briefs, reports and reviews for launch/parser changes. |
| `/tmp/fuji-quick-gallery-count/.superpowers/count` | Count feature brief, progress, report, diff and review. |
| `/tmp/fuji-iphone-count-evidence.vPwfCE` | iPhone Bluetooth, probe and identity traces for the first physical count trial and preceding retries. |

macOS tcpdump sometimes prepended a 24-byte classic PCAP header before PCAPNG;
normalization strips it only when the PCAPNG magic is present at byte 24.
Use Wireshark's tshark at `/Applications/Wireshark.app/Contents/MacOS/tshark` and
Node at `/opt/homebrew/bin/node`. The newer analyzers reassemble all TCP streams,
deduplicate retransmissions and reject gaps/truncation. The original filter
analyzer intentionally selects its later stream; do not mistake it for first-session
evidence. Python, if needed, must use the project's `.venv`.

## Verification and resumption

- `22def991`: full iOS suite 1,023 passed, six skipped, zero failed; its simulator
  and clones were removed.
- `18853399`: portable tests 95 XCTest + 141 Swift Testing passed; combined iOS
  fast run 912 passed, two skipped, zero failed. Full iOS suite passed **1,029**,
  with six skips and zero failures, including the settings test and all five
  manual Wi-Fi UI tests. The owned simulator and its clones were removed.
- The intermediate launch-only candidate had an export-settings second-export
  timing failure. Base runs and an instrumented run passed. The combined revision's
  fast run passed the test, as did its full run's unit phase. The underlying cause
  was not proven; do not erase this history or call it a confirmed baseline failure.
- `9fd5b43d`: portable tests 97 XCTest + 141 Swift Testing passed; focused probe
  tests 26 passed; the complete affected manual Wi-Fi UI suite passed **6/6**.
  The frozen fast run passed **913**, with two skips and zero failures in Xcode's
  grouped summary (999 parameter-expanded passes). Source review approved
  specification, quality and integration. The complete iOS suite is still running
  at this checkpoint, monitored by `/root/quick_gallery_count_impl` with log
  `/tmp/fuji-quick-count-final-full.log`. That agent owns final reporting and cleanup
  of simulator `2950EC3D-15B4-4CF9-A120-0E318768861A` and its test clones.

### Phone state at checkpoint

The signed count-check Debug app from `9fd5b43d` was built successfully, verified
with strict codesign, installed, and launched normally on the iPhone. The exact
bundle is `/tmp/fuji-quick-gallery-count/.build/ManualWiFi/Build/Products/Debug-iphoneos/FujiStudio.app`.
Its installation container is `4F0B1C79-6E1B-4AB2-A482-034667FDF7B8`. The code at
this documentation checkpoint is unchanged from that source revision. Entitlements
were the application identifier, team identifier and development get-task-allow;
unsupported Hotspot/Wi-Fi-info entitlements were absent. The user had put the phone
on normal Wi-Fi for installation. The same build completed the first physical
count trial described above.

### Working conventions

The root uses Jujutsu exclusively, with isolated `/tmp` workspaces and task-owned
simulators. Development work goes to `codex/camera-wifi`, not main. The user has
requested `gpt-6.1-sol` subagents. Do not repeat already authorized pairing cleanup
permission questions, but avoid resetting a valid pairing for an unrelated test.

Build the phone diagnostic using `Scripts/build-manual-wifi.sh`, automatic signing,
`DEVELOPMENT_TEAM=AZH3P824F3`, and `CODE_SIGN_IDENTITY='Apple Development'`.
Verify the exact Debug bundle with `codesign --verify --deep --strict`, install
that bundle, then launch `com.lun3x.FujiStudio` normally without test arguments.
The display name is **Fuji Manual WiFi**. A plain Release build excludes this UI.
Keep the phone on normal internet Wi-Fi for installation/developer verification.

Before relaunching after a hardware test, copy these app Documents files with
`xcrun devicectl device copy from --domain-type appDataContainer
--domain-identifier com.lun3x.FujiStudio`: `ManualWiFiIdentityTrace.json`,
`ManualWiFiBluetoothTrace.json`, and `ManualWiFiProbe.json`. They reset at launch.
Discover the attached phone with `xcrun devicectl list devices`.

No RVI capture is currently running: the latest capture was stopped after 3,499
packets with zero kernel drops, and `rvi0` was removed. Start a fresh bounded capture
before the next packet-level trial if needed. Use the completed count as the
baseline for comparison of pre-TCP and retained camera state. Keep the existing
Fuji Studio pairing for native trials and record the DF28 value the camera offers.
Use changes in negotiation or inventory to decide when to repeat a full scan.
