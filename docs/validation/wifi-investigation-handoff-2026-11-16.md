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
- With the two BLE app flags enabled, the native gallery exposed the same 548
  JPEG and 619 RAF handles identified in the prior captures. Native JPEG+RAW
  pair download is a separate hardware check.
- The prior full metadata trial used source revision
  `1885339990c5c156ac8bb15c28a981ead92dfe6c`. The user forgot the phone bond and
  paired again. Image-viewing launch `03 00`
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

### Matching the first XApp socket

A byte comparison of `xapp-fresh.pcapng` and `fuji-image-viewing.pcapng` found
identical outbound PTP command and data frames up through the DF28 read. The
82-byte opening request had the same first 28 bytes, including the local IPv4.
Its remaining 54 bytes contained different zero-padded UTF-16LE client names.
The camera's initialization reply matched and its first D212 reply already
differed, before DF01 or the DF28 read.

| Before the DF28 reply | Fresh XApp | Fuji Studio baseline | Fuji Studio with XApp timing |
| --- | ---: | ---: | ---: |
| Initialization reply to OpenSession command | 11 ms | 54 ms | 14 ms |
| OpenSession reply to D212 command | 207 ms | 2 ms | 223 ms |
| D212 reply to DF01 command | 392 ms | 1 ms | 403 ms |
| DF01 reply to DF28 command | 1 ms | 1 ms | 1 ms |
| First D212 `D220` | 0 | 1 | 1 |
| First D212 `D222` and `D401` | 0 | 548 | 548 |
| DF28 reply | 3 | 2 | 2 |

The older XApp capture's second socket returned D220 = 1 and D222/D401 = 1,227,
then offered version 3 with only 1 ms from the D212 reply to the DF01 command.
That prior socket demonstrates that D220 = 1 can coexist with version 3 and
that a 392 ms wait is unnecessary in at least one already-active XApp session.

The signed manual Debug build can set `FUJI_XAPP_CAPTURED_CLIENT_NAME` when
running `Scripts/build-manual-wifi.sh`. The supplied name goes into the TCP
opening frame and enables the measured 11/207/392 ms response-to-command delays
for gallery actions. The build keeps the saved Fuji Studio BLE registration.
Pass `Fuji iPhone` as the value to test timing with the registered TCP name.

In the first comparison run at 17:49:20 UTC on November 16, the saved Fuji Studio
pairing reconnected and the camera acknowledged the first BLE `03 00`. The new
TCP opening frame matched all 82 bytes of XApp's captured frame. The X-T5 ACKed
the bytes at TCP level and sent no initialization payload. The app timed out
waiting for the header after 32 seconds and closed the socket. This happened
before OpenSession, so the run exercised the XApp name under the Fuji Studio
pairing and ended before the timing changes or the DF28 read. The next attempt
sent the same 82 bytes and again received a TCP ACK without an initialization
payload. This suggests the TCP name is tied to Bluetooth identity or retained
camera state. The condition the camera checks remains unknown.

The timing-only build kept `Fuji iPhone` in the TCP opening frame. The run at
17:57:54 UTC established a session and sent the same PTP frames as XApp through
the DF28 read. The on-wire delays are shown above. The first D212 payload was
byte-identical to the earlier Fuji Studio baseline. The camera returned DF28 = 2
and card 2 had 548 handles both before and after JPEG+RAW filtering. Card 1 was
unavailable and the attempt closed cleanly after 2,068 ms. The captured timing
changes alone did not account for the version or inventory difference.

For an end-to-end comparison with XApp, start a Bluetooth trace before reconnect
and continue through the first TCP reply. Capture Fuji Studio with its saved
pairing first. Then capture XApp's first connection and include registration if
switching apps requires re-pairing. Compare GATT reads, writes and subscriptions
by characteristic, plus the timing from `03 00` through the TCP request.
Apple's [Bluetooth for iOS/iPadOS profile](https://developer.apple.com/feedback-assistant/profiles-and-logs/)
and [PacketLogger live capture](https://developer.apple.com/videos/play/wwdc2019/901/)
provide the Bluetooth evidence missing from the TCP-only RVI traces.

### Independent X-T5 reference

[Marnix Janssen's tests on X-T5 4.31](https://github.com/mjanssen/fujifilm-camera-protocol-data/blob/853e3647cafbdf56c6a920887bf5553c823d8aad/x-t5.md#31-pairing-and-session-setup)
document two BLE writes of `01` immediately after the client name. Fuji Studio
previously advanced from the name write to SSID and notification setup without
writing either flag. This is a concrete difference before the camera's first
TCP reply. The reference gives neither the flags' meanings nor the DF28 value
observed during its successful JPEG and RAF transfers.

Build the controlled count probe with `FUJI_XT5_REFERENCE_APP_FLAGS=1` and
`FUJI_XAPP_CAPTURED_CLIENT_NAME='Fuji iPhone'` using `Scripts/build-manual-wifi.sh`.
This Debug build discovers the flags by characteristic UUID across services.
It writes `01` to `CAEDB497-83BF-482C-91EF-91CF6F1216FF` and then
`98934B2C-756C-4632-AA2F-DCBA1BFEC824`, waiting for each acknowledgment before
continuing. Missing or rejected flags stop the attempt and are recorded by
ordinal. The first physical attempt acknowledged both flags and the `03 00`
Wi-Fi launch, then timed out before readiness. The user power-cycled the X-T5
and repeated with the same saved pairing. Both flags were acknowledged again,
and the first Wi-Fi launch received positive readiness about seven seconds
later.

At 19:50:28 UTC, **Check photo counts** completed in 2.412 seconds. The X-T5
offered `DF28 = 3`, unlike the previous timing-only run's `2`. The first D212
event values matched XApp, including D220, D222 and D401 all at zero. Card 1 was
unavailable. Card 2 returned the same 1,239 unfiltered handles as XApp, then
1,167 filtered handles. The filter's result matched the disjoint union of the
548 handles classified as JPEG in the earlier Fuji Studio scan and the 619
handles selected by the earlier XApp RAW filter. CloseSession and socket
cleanup completed. The combined flags variant and camera restart succeeded.
The trial did not isolate the individual flags or the effects of the restart.
The installed iOS Bluetooth profile also captured the two ATT writes (`01` to
handles `0x4516` and `0x4519`) in the phone's sysdiagnose. The successful attempt
then wrote `03 00` to `0x6003` and received `01 80` on `0x5003` about seven
seconds later.

The first pair attempt classified all 1,167 objects as 548 JPEG and 619 RAF and
selected a pair. With D226 = 2, it reached 11,534,336 of 40,011,808 expected RAF
bytes, then rejected the next `101B` response before it streamed a payload. The
trace did not retain that response's advertised length. Cleanup discarded the
pending files. The corrected X-T5 transport accepts a positive, correctly framed
partial response up to the requested length and resumes at the actual byte
offset. Final lengths and embedded pair metadata are still validated before save.

The reference also NUL-terminates the BLE name, configures more notification
services, answers the camera's clock request, reads AP status before launch,
and periodically reads a BLE keep-alive characteristic. Those are separate
differences for a subsequent trial. Preserve the current handshake for the
two-flag comparison.

For original transfers, the [same reference](https://github.com/mjanssen/fujifilm-camera-protocol-data/blob/853e3647cafbdf56c6a920887bf5553c823d8aad/x-t5.md#4-wi-fi-photo-browsing-and-import)
sets `D226 = 0` then `D227 = 1`, refreshes ObjectInfo, and reads `D235` before
sending bounded `101B` requests. The current X-T5 diagnostic uses `D226 = 2`,
which an earlier XApp capture used to fetch a full JPEG. The camera selects
DF28 before either original-transfer sequence is used.

The product X-T5 Wi-Fi path writes both BLE flags and checks AP status before
requesting image viewing. It binds the TCP session to the secured camera network
verified by the iOS join gateway, checks the X-T5 model in the initialization
reply, and uses authenticated BLE firmware evidence. The gallery session uses
the observed XApp startup, keeps idle PTP alive, and restores D226 on card switch
or normal closure. The existing camera import job stages and validates the JPEG
and RAF, then adds both resources to the same PhotoKit asset in one transaction.

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
| `/tmp/fuji-iphone-df28-evidence.C7FRKj` | USB RVI packet capture and app traces for the TCP startup comparison. |
| `/tmp/fuji-iphone-app-flags.Tytj7Y` | App traces and USB count capture for the two BLE app flags; Bluetooth logs from the user's installed iOS profile. |

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
  specification, quality and integration. The complete iOS suite also succeeded
  (`/tmp/fuji-quick-count-final-full.log`).
- `aa3f1c41`: the portable suite passed 98 XCTest and 141 Swift Testing tests.
  The fast iOS run passed 913 with two skips. The full iOS suite passed 1,031
  with six skips and zero failures, including all six manual Wi-Fi UI tests.
  The isolated simulator and its test clones were removed.
- `2ab055fd`: full iOS suite 1,032 passed, six skipped, zero failed.
- `db6e81b1`: the portable suite passed 101 XCTest and 141 Swift Testing tests.
  The production X-T5 replay covers both files, including a short RAF response,
  recovery of the next offset, and D226 restoration. An unrelated camera name
  in the TCP opening reply stops the session before OpenSession. The iOS Release
  simulator build succeeded. Both opt-in native PhotoKit tests passed, including
  an asset with one primary JPEG and one alternate RAF. Both resources were read
  back and matched byte-for-byte against the fixtures. The complete iOS suite
  passed 1,032 with six skips and zero failures. Task simulators and their test
  clones were removed.

### Phone state at checkpoint

The iPhone has the signed manual Debug diagnostic with both BLE app flags and
the corrected short-read handling. On November 17, the corrected transport
received all 40,011,808 expected RAF bytes. The first file then failed
validation, before the JPEG transfer or pair validation could start. The
camera acknowledged D226 restoration and CloseSession, and the pending
file was removed. The trace recorded the validation error as `other`.

The updated signed diagnostic records the failed validation check in
`validationCheck`, with bounded geometry or orientation values when relevant.
It passed strict codesign verification and was installed and launched normally.
The rerun uses a USB TCP trace to reconstruct the transferred object if the
validation requires further analysis. The current iPhone Release provisioning profile lacks the
Hotspot Configuration and Access Wi-Fi Information entitlements, so Xcode
could not sign the production app for this phone.

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

The successful count capture ended with 196 packets and zero kernel drops.
Use the saved Fuji Studio pairing on the installed manual build for the next
physical download. Read the failed validation check or the completed pair
receipt, depending on the outcome.
