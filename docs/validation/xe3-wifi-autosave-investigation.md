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

## Fuji Studio integration gaps

- The [current invitation codec](../../Packages/FujiCameraCore/Sources/FujiCameraCore/Wireless/AutoSaveCodec.swift)
  requires numeric `DSCPORT`. A sanitized replay of the observed `0x5C` token
  should exercise any X-E3 parser change. The command endpoint remains the
  validated camera address on fixed TCP `55740`.
- The [current AutoSave adapter](../../Packages/FujiCameraCore/Sources/FujiCameraCore/Wireless/AutoSaveTransferAdapter.swift)
  selects `DF01` from `DF24`, whereas the successful official path directly
  selected `3`. Carry over the measured initialization, original-size scope,
  enumeration, and download behavior as an X-E3 AutoSave profile, with bounded
  reads and transaction validation. Preserve the X-T5 gallery path.
- The observed `0xD228` values are progress updates. Queue advancement and the
  effect of cancellation, repeated imports, or progress writes on future
  visibility are still unverified. Verify the Photos receipt separately.
- Signed iPhone multicast provisioning and the independent `DeviceInfo`
  selected-body binding remain gates. The independent Mac probe verified the
  saved MAC and initialization model. A fresh `GetDeviceInfo` check is pending.
  Hardware validation still needs the native signed app to register, enumerate,
  receive originals, compare against the card, and verify the Photos receipt.
  The evidence covers the tested body, firmware, card, and LAN.

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

For packet review, display UDP/TCP ports `51540`–`51542` for discovery and
invitations, then reassemble the successful `55740` stream in both directions.
The original traces use TCP stream `4` for the official VM transfer and `3` for
the successful independent receiver. Match data containers to `0x101B` commands
by transaction ID, require each `0x2001` response, and concatenate the payloads at
the request offsets for the selected handle. The two successful capture runs
reported zero kernel-dropped packets. Compare the completed RAF against the
read-only SD-card source with `cmp` and `shasum -a 256`.
