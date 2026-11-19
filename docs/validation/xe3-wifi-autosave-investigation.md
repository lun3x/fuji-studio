# X-E3 Wi-Fi original RAW transfer investigation

## Result on November 18, 2026

The X-E3 transferred the complete **19,571,312-byte `DSCF0244.RAF`** over Wi-Fi
using both Fujifilm PC AutoSave 1.3.0.0 and an independent Mac receiver. `cmp`
matched the RAF reconstructed from the official capture against the SD-card
original. A second `cmp` matched the independent receiver's output against that
verified copy. All three have SHA-256
`adce31a8169d60f1687e2d98d7139a8620ed6c50e2c61941ba94c11e65d62fa3`.
The original's EXIF Software field reads `Digital Camera X-E3 Ver1.32`.

This verifies original RAF transfer from this body and card over PC AutoSave.
A later run extracted [six RAW thumbnails in one session](#raw-thumbnails-with-partial-reads)
using 16 KiB from the start and 32 bytes from the end of each RAF.
A follow-up [previewed all 16 RAWs and imported one selected original](#preview-and-import-in-one-session)
using the same AutoSave connection for both phases.
A separate run [verified five minutes of idle browsing](#five-minute-idle-browse)
before another preview read on the original connection.
On November 19, Fuji Studio in the iOS Simulator used an
[iPhone Personal Hotspot](#fuji-studio-over-iphone-personal-hotspot) to register
the X-E3, browse its thumbnails, and save four verified RAW+JPEG pairs to Photos.
The [native iPhone acceptance record](wireless-import-acceptance.md) still governs
Fuji Studio's signing, identity, and hardware gates. The physical phone trace
below used Fujifilm Camera Remote. The [X-T5 Wi-Fi handoff](wifi-investigation-handoff-2026-11-16.md)
covers the XApp gallery path separately.

## Camera Remote on the phone

The captured connection used Bluetooth ATT traffic for phone-camera interaction
and a separate Wi-Fi transfer. The successful Wi-Fi capture contains a
camera-hosted TCP command connection on `55740` and additional TCP connections
on `55741` and `55742`. The command stream uses Fuji initialization and PTP
framing. The app selected `DF01 = 5` during setup and later `DF01 = 11` for the
viewing session. ObjectInfo responses with filenames listed JPEGs, and the
observed downloads began with JPEG data. The tested Camera Remote gallery
exposed JPEG downloads only.

## PC AutoSave setup and discovery

The Mac host ran macOS 27.0.1. Fujifilm's app would not start normally there, and
an attempt to run its helper directly reached an `IMPORT` request but rejected it
with `400` after failing to find the saved registration under an empty MAC.
Earlier attempts also encountered unreachable routes, stale or missing neighbor
information, and camera freezes that required recovery at the body. These
failures preceded PTP file transfer. Fujifilm identifies a startup issue on macOS
27 and lists the X-E3 and macOS Tahoe 26 as compatible.
[Fujifilm macOS 27 advisory](https://www.fujifilm-x.com/en-us/news/notice_of_applications_software_used_with_macos_27_golden_gate/),
[Fujifilm compatibility chart](https://www.fujifilm-x.com/en-gb/support/compatibility/software/pc-autosave/)

The control experiment installed the signed official app in a macOS Tahoe
26.6.2 Tart VM. The VM bridged the host's Wi-Fi to join the camera's IPv4 LAN.
The host captured both directions on the VM's virtual Ethernet interface. In
PC AutoSave, select **PC Auto Save Setting → Manual Setting**, then register the
VM from the X-E3's **Connection Setting → PC Auto Save Settings**. To transfer,
use **Playback → PC Auto Save**, select the registered destination, and confirm
on the camera. The official app fetched all four objects on the test card. Use
a spare card with a known small set of test files for a controlled official run.
[Fujifilm manual registration](https://app.fujifilm-dsc.com/en/pc_autosave/appendix.html),
[Fujifilm transfer instructions](https://app.fujifilm-dsc.com/en/pc_autosave/usage.html)

| Phase | Observed traffic |
| --- | --- |
| Registration discovery | Camera broadcasts UDP `DISCOVER * HTTP/1.1` to port `51542` with `SERVICE: PCAUTOSAVE/1.0`. |
| Discovery reply | Receiver connects to camera TCP `51540`, sends `NOTIFY * HTTP/1.1` with the camera endpoint in `HOST` and the assigned destination in `IMPORTER`. Camera replies `HTTP/1.1 200 OK`. This exchange also occurs during transfer discovery. |
| Registration invitation | Camera connects to receiver TCP `51542` and sends `REGISTER * HTTP/1.1` with `HOST`, `DSCNAME`, and `DSCMODEL:X-E3`. Receiver replies `200 OK` with `FOLDER: guest` and `ServiceName: PCAUTOSAVE/1.0`. |
| Transfer discovery | Camera broadcasts UDP `DISCOVER <registered destination> HTTP/1.1` to port `51541`. The receiver answers on camera TCP `51540`. The camera asks the user to confirm the upload. |
| Transfer invitation | Camera connects to receiver TCP `51541` with `IMPORT /guest HTTP/1.1`, `HOST`, `DSCNAME`, and `DSCPORT`. In the successful X-E3 capture, the entire `DSCPORT` value is the literal byte `0x5C` (backslash). The invitation ends in a single CRLF and the receiver replies `200 OK` followed by two CRLFs. |
| File session | The receiver opens camera TCP `55740` after accepting `IMPORT`. The official app succeeded with the nonnumeric `DSCPORT` value. |

The independent receiver used the Mac's existing registered destination. It
matched fresh captured discovery and invitation frames to the saved camera MAC
before making outbound TCP connections, checked the claimed name and receiver
address, and verified the initialization response identified an X-E3. It ran
from the user's Terminal because the automation shell's Node process returned
`EHOSTUNREACH` on the LAN. The MAC check is a lab safeguard tied to Ethernet
visibility. Fuji Studio's independent selected-body binding remains an
integration gate.

## Observed file session

The official app's initializer is 82 bytes. Byte offsets below are zero-based.
After the 68-byte initialization reply with type `2` and model `X-E3`, the stream
uses little-endian 12-byte PTP headers containing length, container type,
operation or response code, and transaction ID, followed by the payload. Command,
data, and response container types are `1`, `2`, and `3`.

| Initializer offsets | Value in the successful PC AutoSave session |
| --- | --- |
| `0–7` | UInt32 total length `82`, UInt32 message type `1` |
| `8–11` | UInt32 `0x8F53E4F2` |
| `12–23` | `ad a5 48 5d 87 b2 7f 0b d3 d5 de d0` |
| `24–27` | Connected receiver's IPv4 address in reverse octet order |
| `28–81` | Camera network name from `DSCNAME` in UTF-16LE, zero-padded |

1. Send `OpenSession` (`0x1002`, parameter `1`, transaction ID `1`). Read
   `0xD212` with `GetDevicePropValue` (`0x1015`). Observed event `0xDF00 = 3`
   indicated AutoSave state, and `0xD222 = 4` reported the object count. The event
   payload starts with a UInt16 count followed by UInt16 keys and UInt32 values.
2. Write `0xDF01 = 3` as a UInt16 using `SetDevicePropValue` (`0x1016`). Read
   and echo `0xDF23` as a UInt32 (`1` on this body). Write `0xD227 = 1` as a
   UInt16 before reading ObjectInfo so lengths describe the originals.
3. Read ObjectInfo (`0x1008`) in ascending handle order `1` through `4`. The
   official app read `0xD212` after handle `1` and polled eight more times after
   enumeration before its first download. It wrote `0/4` to `0xD228`. Progress
   strings are PTP strings, with a one-byte character count including the
   terminator followed by null-terminated UTF-16LE. Refresh the selected
   handle's ObjectInfo before using its filename and length.
4. Fetch each original with successive `GetPartialObject` (`0x101B`) requests
   with UInt32 parameters `[handle, offset, length]`. Use `1,048,576` bytes per
   full chunk and the exact remaining length for the final one. Each request
   completed with the requested data length, PTP status `0x2001`, and a UInt32
   response parameter matching the byte count. Check matching transaction IDs.
   For both successful RAF transfers, chunk requests were consecutive, with
   no intervening application-level heartbeat or event poll.
5. The official app updated `0xD228` after each completed object and reached
   `4/4`. At the end it wrote `0xD227 = 0` and closed the TCP write side. In the
   independent one-file run, the receiver reported `1/4`, stopped after the
   selected RAF, and sent the same `0xD227 = 0` cleanup write. The camera sent
   `0x2001` and the command connection exchanged TCP FINs.

The four handles on this card represented two JPEG/RAF pairs. The independent
receiver used the filename from refreshed ObjectInfo to select handle `2`.
Handles are session and card observations. Use the current inventory to select a
file. The official app downloaded in descending handle order after ascending
enumeration. The independent receiver proved that it could read the selected RAW
without first downloading any other object.

## Comparing the 12 MiB boundary

| Trial | What happened at byte offset `12,582,912` (`0x00C00000`) |
| --- | --- |
| Early independent receiver, chunked | `0xDF01 = 5` and event reads between chunks. The first twelve 1 MiB chunks arrived. The next `0x101B` request received no PTP data. |
| Early independent receiver, whole object | One `GetObject` (`0x1009`) requested the full RAF. The camera stopped after exactly 12 MiB of file payload despite the Mac acknowledging the bytes and advertising a positive receive window. The script later closed on its 45-second inactivity timeout. |
| Official receiver in Tahoe VM | Transaction `72` requested the usual 1 MiB at offset `0x00C00000` and got the full chunk. The app finished in 19 successful transactions for this RAF. |
| Independent receiver with matched setup | Transaction `34` requested that same chunk and got the full response. All 19 transactions for the selected RAF succeeded, including the last `696,944` bytes. |

The failed prefix matches the first `12,582,912` bytes of the full RAF and has
SHA-256 `0ecb35cdef71a598ae8365288321eabd918e1027c5caa7d5affe9ab2702e5d04`.
Both successful receivers passed the boundary using ordinary sequential chunk
requests. The independent retry changed the initializer fields, the `0xDF01`
mode, the `0xD228` updates, the enumeration order, and event polling cadence.
Those changes were sufficient for this run. The minimal fix and the camera's
reason for stopping at 12 MiB remain unverified.

The independent receiver's live run logged a shutdown timeout after the RAF was
already written and verified. The capture shows the final `0xD227` response and
FIN exchange. The Node shutdown wait left a reply unread behind its frame
iterator. Draining that iterator fixed the warning in a local replay of the
captured session, which also regenerated the identical RAF. The drain change was
validated in replay after the hardware run.

## RAW thumbnails with partial reads

The PC AutoSave ObjectInfo replies for the original four-file test reported
zero thumbnail bytes. The tested `DSCF0244.RAF` contains a 160 × 120 JPEG inside
its embedded preview's Exif data. The probe saved that thumbnail after receiving
only the first 16 KiB. In the first two trials the camera then stopped replying
at the PTP layer when the receiver moved to the next RAF. This happened both
with a fresh ObjectInfo request for the next handle and with a direct partial
read using its already enumerated handle. In both cases TCP acknowledged the
request.

The third trial used the same AutoSave setup and a card inventory of 32 objects.
It followed this sequence for each of the first six RAFs:

1. Get the handle and the exact original length `L` from ObjectInfo with
   `0xD227 = 1`. Confirm the object format is RAF (`0xB103`).
2. Send `GetPartialObject (0x101B) [handle, 0, 16384]`. The RAF header's
   big-endian UInt32 values at offsets 84 and 88 give the embedded JPEG's offset
   and length. Within the JPEG's Exif APP1 segment, use TIFF IFD1 tags `0x0201`
   and `0x0202` for the thumbnail offset and length. Check that the thumbnail
   lies entirely within the received prefix before decoding it.
3. Send `GetPartialObject (0x101B) [handle, L - 32, 32]` for the same RAF.
4. Wait for the tail response before sending the head request for the next
   handle. For each request, validate the transaction ID and data length, the
   `0x2001` response, and its returned byte count.

The camera answered all 12 requests (transactions `30` through `41` in TCP
stream `2`). Both byte ranges for `DSCF0244.RAF` matched the known original,
including the noncontiguous tail offset. The next handle started successfully
after each tail read. This establishes that reaching end-of-file with a short
read was sufficient to switch objects on the tested body. The probe kept
`0xD228` at `0/32` and cleared `0xD227` before closing.

| RAF | Handle | JPEG thumbnail bytes |
| --- | ---: | ---: |
| `DSCF0244.RAF` | 2 | 9,296 |
| `DSCF0245.RAF` | 4 | 9,364 |
| `DSCF0246.RAF` | 6 | 8,943 |
| `DSCF0247.RAF` | 8 | 9,384 |
| `DSCF0248.RAF` | 10 | 9,337 |
| `DSCF0249.RAF` | 12 | 9,169 |

All six decoded as 160 × 120 JPEGs. The capture contains **98,496 bytes of
RAF payload** across six files whose full sizes total **117,731,584 bytes**.

### Preview and import in one session

A follow-up Mac receiver opened one PC AutoSave session after the user started
AutoSave from playback. It enumerated all 32 objects and used the head and tail
sequence above for all 16 RAFs (`DSCF0244.RAF` through `DSCF0259.RAF`).
All 16 thumbnails decoded as 160 × 120 JPEGs. The preview phase used **262,656
bytes of RAF payload**. The probe kept progress at `0/32` and exposed the
selection in Terminal to model a gallery selection.

The trace shows **8.616 seconds** between the final preview reply and the first
command after the user's selection, with no intervening application payload.
The receiver refreshed ObjectInfo for `DSCF0244.RAF` (handle `2`) and read it
from offset zero using 1 MiB `GetPartialObject` requests with an exact final
remainder. All **19,571,312 bytes** matched the previously verified SD-card
original. Only the selected RAF had a full transfer. Progress advanced to
`1/32` after the download, and the camera and receiver closed their TCP sides.

The preview reads (transactions `50–81`) and the complete original reads
(transactions `83–101`) share TCP stream `7` and one `OpenSession`.
The camera needed one playback confirmation for the successful run. After an
earlier attempt was refused on TCP `55740`, the probe used a five-second
retry window for that port during startup. This run verifies a selected import
after an 8.6-second pause.

### Five-minute idle browse

The Mac receiver loaded all 16 RAW thumbnails using the same 16 KiB head and
32-byte tail reads. It then disabled its socket inactivity timeout and TCP
keepalive and waited five minutes with the original AutoSave connection open.
The camera received no further user interaction after the initial playback
confirmation.

In TCP stream `3` of the idle capture, **300.004 seconds** elapsed between the
last preview response (transaction `81`, frame `684`) and the next ObjectInfo
request (transaction `82`, frame `697`). The only intervening packet on that
stream was the Mac's TCP acknowledgement of the last preview response. The
camera answered the ObjectInfo request and both subsequent reads of
`DSCF0244.RAF` (transactions `83–84`). The new head and tail bytes matched
those from before the pause. The endpoints closed the connection after the
probe cleared `0xD227`.

Five minutes is the verified idle lower bound for resuming thumbnail reads on
this body and LAN. The maximum idle time, a full original download after a
five-minute pause, and the native iPhone workflow remain untested.

## Fuji Studio over iPhone Personal Hotspot

On November 19, 2026, the Mac running the iOS 27.1 Simulator and the physical
X-E3 joined the same iPhone Personal Hotspot as Wi-Fi clients. Fuji Studio ran
on the Mac in the simulator. After the Mac rejoined the hotspot from its usual
Wi-Fi network, the simulator received the X-E3's UDP discovery on `51542`. It
sent `NOTIFY`, received `200 OK` from the camera, and accepted the camera's
`REGISTER` request. The saved destination was available after relaunch.

In the successful playback session, the simulator received discovery on
`51541`, opened the command connection on TCP `55740`, and displayed the RAW
thumbnails in Camera Photos. The user selected and saved four captures. Fuji
Studio verified both originals for each pair by reading back their byte counts
and SHA-256 fingerprints from Photos.

| Capture | Verified RAF bytes | Verified JPEG bytes |
| --- | ---: | ---: |
| `DSCF0246` | 19,639,904 | 15,327,056 |
| `DSCF0248` | 19,953,904 | 15,002,226 |
| `DSCF0250` | 20,300,848 | 15,335,563 |
| `DSCF0251` | 20,610,864 | 15,273,015 |

The hotspot capture retained up to 160 bytes per packet. It documents the
discovery, connections, and transfer timing. The Photos receipts establish
the saved originals' equality to the bytes downloaded by the app. The four
hotspot imports have no independent SD-card comparison in this report.

An earlier `DSCF0245.RAF` import stopped in staging before submitting to Photos.
The official capture confirms that the camera reported zero width and height in
RAF ObjectInfo. Fuji Studio now takes the geometry from the validated X-E3 RAF
container when AutoSave omits those fields. It checks any dimensions the camera
does report against the recorded frame or sensor container.
[Original import validator](../../FujiStudio/Import/OriginalImportValidator.swift)

## Automatic Camera Photos flow

1. In Fuji Studio, open **Status & settings → Set up RAW transfer → Register
   destination**. On the X-E3, open **PC Auto Save Settings → Manual Setup**,
   join the shared network, and select the new destination. Registration is a
   one-time step for that saved destination.
2. With Fuji Studio open, start **Playback → PC Auto Save** on the X-E3 and
   confirm the saved destination. The app listens automatically after
   registration and on relaunch. It takes camera ownership when the registered
   camera sends an accepted invitation.
3. When the inventory is ready, Fuji Studio opens the same Camera Photos tray
   used by the X-T5. The bottom control switches between **Camera Photos** and
   **Phone Photos**. Browse the thumbnails, select captures, and save the
   selected originals from the tray.

The [invitation codec](../../Packages/FujiCameraCore/Sources/FujiCameraCore/Wireless/AutoSaveCodec.swift)
accepts the observed backslash in `DSCPORT` and keeps the fixed command port.
The [simulator AutoSave profile](../../Packages/FujiCameraCore/Sources/FujiCameraCore/Wireless/AutoSaveTransferAdapter.swift)
uses the observed initialization and `DF01 = 3`, reads 16 KiB from the start
and 32 bytes from the end of a RAF for its thumbnail, and streams each selected
original in 1 MiB requests with an exact final remainder.

The 51 focused simulator tests passed, including idle listening without camera
ownership, automatic tray entry after registration and relaunch, and staging
and revalidating an X-E3 RAF whose ObjectInfo omits dimensions. The full
simulator run was interrupted after reproducing a known landscape recipe-editor
failure.

## Remaining hardware validation

- The simulator test verifies a receiver and camera on the same hotspot. The
  case where the physical iPhone both hosts the hotspot and runs Fuji Studio
  remains untested. Physical iPhone support requires multicast provisioning,
  independent selected-camera binding, and validation of the native Photos
  import against SD-card originals.
- `0xD228` reports progress. The effect of cancellation, repeated imports, and
  progress updates on the camera's future AutoSave queue remains unverified.

## Evidence index

Captures and images contain private device identifiers or photo bytes and remain
local. The filenames and digests below identify the originals used for analysis.

| Capture | SHA-256 |
| --- | --- |
| `xe3-bluetooth.pcapng` | `61b22b86c8937820865cfd8109d2dd8c862b5ba0a9eba8a65ab804f6a1d6d7ec` |
| `xe3-wifi-import.pcapng` | `34c743f9e2b0dc33f811c40af046616a1d31aa424c5ad640eb8ecf598c74dd49` |
| `xe3-autosave-registration-and-retries.pcapng` | `89ec0e48426e10dc94160e13b83d4641b452780607545b67faf2a6f4d9f643d6` |
| `pc-autosave-xe3-raw.pcap` | `18a3e7c650fc441ff0df565e11af48bd8a4cff7e00e35b29dab5729c6063cb06` |
| `pc-autosave-get-object.pcap` | `1cc8142548c9f9051124fd981a2f2fd934141e79594c88fe3b552b06a371fde2` |
| `official-xe3-20261118-213159.pcap` | `e9d77de4a7ff0ed9f1b3bfa3e88680f44db3e1118158786358f647af3895154b` |
| `pc-autosave-matched-setup.pcap` | `97540ec0eb04c11c4c921f2ae3894bc8278fb596cc7c829a4f12c87c9090aed1` |
| `xe3-thumbnail-test.pcap`, first trial, next ObjectInfo stalled | `d0ce278e44adb9ff4b1279aabbe659fdac1c3bdf8b46a09e90d5a90cf7cae6af` |
| `xe3-thumbnail-test.pcap`, second trial, next RAF prefix stalled | `6afccf04b3fd799b4337752b9ec0e56bec86f65a343bf833b97d3c7548b03600` |
| `xe3-thumbnail-test.pcap`, third trial, six RAFs with tail reads | `7ee1ad2623a424ef12dfffdd3da3dd08ff400115c7d5b9864a9c33b4d4adaa5d` |
| `xe3-browse-select.pcap`, 16 previews and one selected original | `821643e0e48531bbc2318a2de9faa72eb78602b6ef294e1927418a6fe5f3ce31` |
| `xe3-browse-idle.pcap`, 16 previews and five minutes idle before a repeat preview | `f797d66869f0d7b82f92110092ba2b2b46360b10c19c8472c6af3c92b26a5171` |
| `registration.pcap`, iPhone hotspot registration | `ff1baadc4768c98fb66e492940e89c7119d1c5dd42b722b7f665e74c00274ddd` |
| `transfer.pcap`, iPhone hotspot playback and four verified imports | `1ff7690333fc40bb94a5083d2e7a65d0cdfab42b3d90ec0455c639c96a56c55f` |

For packet review, display UDP/TCP ports `51540`–`51542` for discovery and
invitations, then reassemble the successful `55740` stream in both directions.
The original traces use TCP stream `4` for the official VM transfer and `3` for
the successful independent receiver. Match data containers to `0x101B` commands
by transaction ID, require each `0x2001` response, and concatenate the payloads at
the request offsets for the selected handle. The two successful capture runs
reported zero kernel-dropped packets. Compare the completed RAF against the
read-only SD-card source with `cmp` and `shasum -a 256`.
