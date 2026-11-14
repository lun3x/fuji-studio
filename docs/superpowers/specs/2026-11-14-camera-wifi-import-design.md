# Camera WiFi import for X-T5 and X-E3

Date: 2026-11-14. Status: proposed specification, awaiting user review.
Independent builder check completed: no important planning questions remained.
Agreed approach: native Swift protocol adapters with capability detection,
covering both cameras and firmware generations wherever reasonably possible.
Research: [wireless protocol evidence](../../validation/wireless-protocol-research.md).
This is a substantial feature spanning connection, camera browsing, import and
recovery. It requires physical camera and iPhone validation as well as tests.

## Intent

Import original Fujifilm camera photos over WiFi, preserving a capture's JPEG
and RAF together as one RAW+JPEG item in the iPhone Photos library. This removes
the need to transfer the two components separately or use a card reader for
supported wireless transfers.

After initial pairing, the app should keep its selected camera's Bluetooth
connection ready while the app is open. Tapping the existing status control
opens connection settings. Connect over WiFi starts the camera network and
uses the native iPhone confirmation to join it, followed by camera browsing.

The user explicitly requested both X-T5 and X-E3, including older firmware as
far as feasible. This authorizes firmware compatibility work despite the
project's default of not maintaining backwards compatibility. It does not imply
that a camera can expose capabilities its firmware lacks.

## Scope and success

- Pair and remember both supported camera models; connect to one selected
  wireless camera at a time.
- Support legacy token pairing and secure Bluetooth bonding where advertised.
- Reconnect automatically while foregrounded, with no repeated pairing or
  WiFi join prompts during normal photo browsing.
- Start WiFi explicitly from status, then browse and select camera captures.
- Transfer complete original JPEG+RAF pairs; support standalone RAF captures.
- Save each selected pair as one Photos asset, preserving original bytes and
  capture metadata. Make imported RAW sources available in the existing tray.
- Retain useful progress, completed imports and explicit recovery after a
  disconnect, cancellation or app restart.
- Investigate and implement X-E3 PC AutoSave as the RAW-capable fallback if
  target-device verification establishes it works on iPhone.

Success includes both original resources being retrievable from the same Photos
asset and matching the camera/card originals byte for byte. A successful BLE
connection or joined WiFi network alone is not successful import support.

Not included: wireless RAW conversion, recipe import/writes over WiFi, live
view, remote shutter, automatic upload of new shots, firmware updates, deleting
camera files, or transfer while the app remains backgrounded. Existing USB
processing retains its own support rules. Movies and HEIF import are outside
this first feature.

Unacceptable outcomes include reporting JPEG-only success for a requested pair,
saving unrelated RAF/JPEG files together, silently resizing originals, repeating
a Photos save after an uncertain outcome, or showing USB processing as ready
merely because Bluetooth or WiFi is connected.

## Approaches

1. **Native Swift adapters, selected by capabilities — chosen.** Use
   CoreBluetooth and Apple's network APIs, adapting the published protocols
   into the existing Swift architecture. This permits explicit lifecycle and
   import ownership, deterministic tests and targeted firmware differences.
   The app must maintain the protocol implementation and its evidence record.
2. **Embed libfuji and provide an iOS platform layer.** This follows upstream
   more directly but brings C/runtime integration and provisional behaviors
   that still require adaptation and hardware checks. It is a reference source
   for the chosen approach, not a new runtime dependency.
3. **Manual WiFi or recent-X-T5-only support.** Less connection work, but misses
   the requested Bluetooth handoff or two-camera scope. Rejected.

The user agreed to the recommendation after reviewing the research. Exact UI
details and defaults below are proposed design decisions, not additional user
requirements. The user requested a text spec without browser mockups.

## Evidence and firmware policy

The linked research record pins inspected source revisions and separates
official documentation, external hardware reports, source implementation and
unverified assumptions. Use it for protocol details rather than copying a
single model's full command sequence into every adapter.

| Target | Intended connection | RAW evidence / restriction |
| --- | --- | --- |
| X-T5 before 3.01 | Advertised legacy pairing and available phone-transfer mode | Wireless RAW is unverified; do not reject connection solely for age, and do not invent RAW access. |
| X-T5 3.01–4.21 | Legacy BLE plus negotiated phone-transfer protocol | Fujifilm documents RAW transfer starting at 3.01; original paired import still needs local proof. |
| X-T5 4.30 onward | Secure BLE bonding plus negotiated phone-transfer protocol | Security transition documented at 4.30; public updated-X-T5 reconnect report exists. |
| X-E3 across available firmware | Legacy BLE/phone WiFi; guided PC AutoSave for RAW where verified | No inspected source proves original RAF retrieval through the normal phone-transfer path. AutoSave is the candidate fallback. |

These ranges describe known transitions, not an exact-version allowlist or a
promise about untested future firmware. Discover GATT services, negotiate known
protocol versions and inspect supported operations/file exposure. Prefer a
recognized protocol over rejecting an unknown firmware string. Unknown protocol
structures fail with a useful unsupported-connection message; do not cycle
through speculative writes. A camera refusing RAW must remain usable for its
supported connection functions, with the limitation visible before import.

Maintain a support matrix by model, firmware, BLE family, transfer mode and
tested feature. Distinguish locally verified, externally reported, unverified
and observed unsupported. Record exact firmware in diagnostics. Universal
firmware support is a target; only measured combinations are certified.

## Status and connection screens

The existing status button continues opening **Status & settings**. Add a
**Camera connection** section near the top with the selected camera, Bluetooth
state, WiFi state and a primary action appropriate to that state. Keep existing
Photos access, USB errors, export recovery and settings available.

The status button remains compact. Its accessibility description distinguishes
USB processing readiness, Bluetooth readiness and wireless import progress.
Bluetooth readiness alone does not use the existing Camera ready meaning.
The builder may choose the exact supplementary icon treatment; text and
accessibility values must preserve the distinctions.

Connection section actions:

- **Pair camera** when none is selected. Explain the camera's pairing-menu
  step, list supported nearby cameras and let the user choose explicitly.
  Display the system/camera confirmation when the protocol requires it.
- **Connect over WiFi** for the selected saved camera. If Bluetooth is still
  reconnecting, this single explicit request may wait through a bounded attempt
  and continue when ready; show progress and Cancel rather than require another
  tap. Failure ends the request and offers Retry.
- **Browse camera photos** once the transfer session is usable.
- **Disconnect WiFi**, **Change camera**, and **Forget camera** as secondary
  actions. Forget removes the app's saved connection credentials, not import
  history or Photos assets. Explain any required system/camera unpairing steps
  when the OS does not provide an app-side removal API.

Both X-T5 and X-E3 can be remembered. The last explicitly selected camera is
the reconnect target. Never auto-select whichever camera answers first. Changing
cameras during import requires cancelling/pausing the current job first.

Initial permissions arise from an explicit Pair camera or connection action.
After setup, foreground reconnection is automatic. Denial leaves an actionable
state and Settings guidance; it does not generate repeated OS prompts. WiFi
joining requires a user action even when BLE is already connected. A refusal
or cancelled join does not disable ordinary Bluetooth readiness.

## Foreground Bluetooth and WiFi lifecycle

After setup, make a single asynchronous reconnect attempt for the selected
camera on activation. React to relevant discovery callbacks and retry completed
transient failures with bounded backoff. The proposed default is 3, 6, 12 and
then 30 seconds while foregrounded; successful connection resets it. Camera
absence is normal, not a recurring error alert. Authentication failure stops
automatic attempts until the user repairs pairing or explicitly retries.

Stop discovery/retry work on genuine background entry. No background BLE mode
or location permission is needed for this requirement. On returning, reconnect
BLE automatically, but never automatically rejoin WiFi, restart a file transfer
or resume a Photos write whose result is unresolved.

Treat temporary inactivity from a pairing, WiFi, Local Network or Photos system
prompt separately from background suspension. Preserve the explicit connection
intent and await its result; do not cancel it simply because the confirmation
made the scene inactive. Use operation generations so cancelled or superseded
callbacks cannot start a later join or adopt an old session.

One explicit WiFi attempt owns this sequence:

1. Acquire exclusive camera-use ownership and establish authenticated BLE.
2. Obtain the target camera's network information through its recognized
   protocol and request WiFi activation.
3. Wait for protocol-confirmed readiness, within a bounded deadline. Missing
   credentials or timeout are failures, never implicit open-network success.
4. Apply NEHotspotConfiguration with session-oriented lifetime and await the
   native join result. Do not disconnect from the user's network before this.
5. Establish the camera's PTP transport on the WiFi interface, identify the
   peer where the protocol permits, and negotiate the appropriate import mode.
6. Mark transfer-ready only after usable enumeration succeeds.

Network association, PTP readiness and permission failures must be reported
separately with an action the user can take. A joined but unresponsive network
must time out. Do not send camera protocol traffic through a cellular route or
assume that an arbitrary host at the usual camera address is the selected body.
Where the protocol lacks strong identity, bind the session to the explicitly
selected network and describe that limitation in the technical evidence.

On Disconnect, close the PTP session, release sockets and app-owned temporary
network configuration, and return to Bluetooth readiness where possible. Do
not promise automatic restoration of a specific prior WiFi network: iOS owns
network selection. Do not remove networks configured by the user or other apps.
Recheck BLE after WiFi teardown; some camera modes may drop it during transfer.

## X-E3 RAW fallback

Offer **Set up RAW transfer** when phone mode cannot expose RAF files. Explain
that this route uses the camera's **PC AUTO SAVE** function, even though the
receiving device is the iPhone. The proposed flow is:

1. Put the camera and iPhone on the same suitable WiFi network.
2. Open Fuji Studio's AutoSave setup and follow the camera-side registration
   instructions to register Fuji Studio as a destination.
3. Start PC AUTO SAVE on the camera; discover and accept only the selected
   camera's session, then enumerate and import through the same browser/job UI.

This is explicitly a guided fallback, not an asserted BLE-triggered camera
hotspot equivalent. Remember completed setup where the protocol permits.
Provide bounded waiting, Cancel and network troubleshooting. Retain the
selected camera identity across the different transport without trusting its
display name alone. Validate how registration identifies the camera and how
AutoSave completion/transfer markers behave before shipping this path.

AutoSave is part of the intended two-camera solution, subject to a hardware and
iOS feasibility gate. It requires broadcast discovery and therefore appropriate
signed-iPhone multicast entitlement support. A shared network without client
isolation is the initial supported topology. Personal Hotspot, routerless
AutoSave and BLE-triggered AutoSave are unverified and not acceptance promises.

If the gate fails, document the exact failed step and bring the limitation back
for a scope decision. Do not replace X-E3 RAW support with a working-looking
button, silently import JPEG alone, or mark the whole feature complete. The
X-T5 path can be validated independently while this remains open.

## Camera browser and selection

Present a dedicated camera-photo browser from the connection sheet, using the
app's native visual language, date grouping and multi-selection conventions.
The main tray continues representing Photos assets. Camera thumbnails do not
enter it until import is confirmed.

Enumerate metadata and thumbnails incrementally. Show one row/tile per capture
with date, preview, a format label and import status. Labels distinguish
**RAW+JPEG**, **RAW**, **JPEG only**, **Checking files**, and **RAW unavailable**.
Prefer newest captures first using camera metadata, with a deterministic
fallback for missing dates. Do not block useful browsing on all thumbnails.

The first version imports RAW+JPEG and standalone RAF. JPEG-only, HEIF and
movie items can be identified but are not selectable for import; explain why.
This is a proposed scope choice because Fuji Studio's existing source discovery
requires RAF. In particular, JPEG-only is not an inference that no RAF exists
when the current transfer mode does not expose RAW at all.

Resolve mates before admitting a paired import. Use camera identity, storage,
directory, capture metadata and filename relationship; filename alone is not
enough. Enumerate both X-T5 cards when accessible, including RAW-on-one-card /
JPEG-on-the-other arrangements. An incomplete or ambiguous match is visible
and not automatically paired. Do not synthesize the camera JPEG from the RAF's
embedded preview.

When a RAF is accessible but a JPEG mate is missing, inaccessible or ambiguous,
offer an explicit **Import RAW only** choice for that capture. It must never
be the automatic fallback for a previously selected pair. Freeze the chosen
resources and import policy when the job starts. If they change, require a new
selection rather than import a different capture under the same job.

The primary action is **Import N photos**, counting captures rather than files.
Show an original-byte estimate where sizes are known. Previously confirmed
imports are marked Imported. Selecting new captures does not automatically
download their full originals.

## Transfer, Photos save and recovery

One job owns a fixed capture list and processes captures sequentially, streaming
files to private staging storage. This bounds memory and recovery complexity.
Track per-file byte progress and per-capture stages: downloading, validating,
saving to Photos, verifying and imported. Count a capture complete only after
post-save verification, not after its first component arrives.

Before saving, verify supported file signatures, complete reported lengths,
parseable metadata and an unambiguous pair relationship. Request original-size
transfer using the known protocol and verify full dimensions. Physical
acceptance compares hashes with card/USB originals; do not claim a remote
cryptographic checksum when the camera protocol supplies none. Do not alter
global camera resize preferences without a separately designed restoration
contract; use verified session controls or tell the user what setting is needed.

Create a new Photos asset per capture. For a pair, add JPEG as `.photo` and RAF
as `.alternatePhoto` in the same PhotoKit transaction, with JPEG as the initial
display resource where supported. For RAW-only, create a RAW asset. Preserve
both original filenames and bytes, capture date and embedded location when
available; do not invent location or timezone. Prefer embedded original
metadata; define a documented deterministic fallback to camera ObjectInfo and
then import time for a missing date. Never rewrite media just to set library
metadata. Camera originals remain untouched.

The existing pair replacement path must not be called for camera import: it
requires an existing source and includes removal/album replacement behavior.
Add a creation-only gateway, reusing resource validation and streaming helpers
where appropriate. The Update original in Photos setting does not change
camera-import behavior.

Persist a journal before download and before Photos submission. Keep job ID,
camera record, selected object descriptors, exact local file hashes/lengths,
pair policy, stage, Photos placeholder identifier and verified asset receipt.
Camera handles are session-local, never durable identities. Reconnection must
rediscover objects and revalidate their fingerprints before retrying. If
identity cannot be established after a card swap or reused filename, require
fresh selection. Completed receipts survive disconnect, restart and forgetting
a Bluetooth pairing.

After a successful Photos transaction, read back both original resources and
verify role, length and hashes against the staged originals. Only then mark the
receipt complete and release its staged files. Support full and limited
read/write Photos access where the created asset is inspectable. If permission
prevents verification, retain a saved-but-unverified state and explain the
access needed; do not resubmit it as a new import.

Reconcile an interrupted Photos submission before any retry. First inspect the
recorded placeholder; if unavailable, use a narrow candidate lookup and compare
complete resource fingerprints. Filenames/timestamps alone never prove a match
or absence. An uncertain or inaccessible result stays blocked from resubmission
with staged originals retained. Do not promise exactly-once saves without this
uncertain-state handling. Never delete a candidate asset to resolve uncertainty.

Deduplication guarantees cover this app's verified import receipts. Do not scan
or hash the entire Photos library to deduplicate photos imported by other apps.
Before skipping a repeated capture, verify the recorded asset is still present
and contains the expected resources. Confirmed deletion permits a new explicit
import; limited access is not proof of deletion. Full content hashes prevent
reused camera filenames from being mistaken for old imports.

Cancel stops admitting new work and ends downloads safely. A Photos transaction
already submitted must settle/reconcile; its confirmed result is kept. Completed
captures remain imported. Delete unsubmitted partial files on cancellation;
retain complete validated components needed for an explicitly resumable job,
and all files protecting an uncertain Photos save. Offer Resume remaining and
Discard remaining for non-uncertain jobs. Discard never deletes Photos assets.

On background entry or connection loss, pause at a safe boundary and persist
the job; bounded OS completion time may settle in-flight work, but ongoing
background transfer is not promised. On return, show Resume remaining. Do not
automatically join WiFi or resume import. Reuse a complete validated staged
component; restart partial files from byte zero in the first version. One
failed capture pauses the queue with Retry, Skip capture or Cancel remaining;
an uncertain Photos submission must be reconciled before it can be retried.

Preflight estimated storage for staged originals and Photos copying. Treat it
as an estimate, handle actual out-of-space errors, and preserve uncertain-save
evidence. Never evict unfinished originals as ordinary cache data. Display the
retained-storage consequence when recovery is blocked.

After verified imports, refresh Photos discovery incrementally, preserving the
existing viewer and selection. Show the new import count and a View imported
action; that action selects the newly imported sources and reveals the newest
one. WiFi stays available for more imports until explicitly disconnected or
the app backgrounds. Existing USB processing remains a separate next action.

## USB coordination and permissions

Use one app-level camera-use arbiter. Wireless import and USB recipe/conversion
work do not operate the camera simultaneously, even if distinct devices are
attached in the first version. Active USB export disables starting wireless
transfer and explains that it must finish or be cancelled. A Connect over WiFi
request may cancel an obsolete preview, await its existing cleanup and close
an idle USB session before proceeding. Never switch transport while native
operation cleanup is unresolved.

During wireless browsing/import, suspend USB automatic attempts and disable
recipe processing. Bluetooth readiness may coexist with idle USB discovery only
when device testing proves that it does not disrupt USB; otherwise release BLE
during USB ownership and reconnect after release. On wireless close, restore
ordinary foreground USB discovery. No reconnect resumes a render/export job.

Use public iOS APIs and the existing iOS 27 / Swift 6 project baseline. Add clear
Bluetooth and Local Network usage descriptions, update Photos save wording,
and configure Hotspot Configuration. Verify the AutoSave multicast entitlement
on a signed physical build. Do not introduce location permission just to pair.
Store app pairing tokens/network credentials in Keychain, keep media private,
and redact credentials and personal identifiers from shareable diagnostics.

## Architecture and responsibilities

Names below are illustrative; exact types and file placement are builder calls.

| Component | Responsibility |
| --- | --- |
| Wireless connection coordinator | Selected camera, foreground lifecycle, bounded reconnect, explicit join intent, generation/cancellation and value-only observable state. |
| BLE adapters and native BLE driver | Protocol discovery, legacy/secure pairing, saved reconnect, credentials and WiFi activation; CoreBluetooth objects remain at the platform boundary. |
| WiFi join gateway | Native configuration/confirmation and app-owned network teardown, injectable for tests. |
| Wireless PTP transport and mode adapters | Bounded framed TCP I/O, serialized transactions, legacy/XApp/AutoSave setup, capabilities, enumeration and streaming download. |
| Camera browser model | Incremental metadata/thumbnails, capture grouping, pair confidence, selection and import status. |
| Import coordinator and journal | Frozen jobs, exclusive ownership, staging, original validation, save/reconciliation and receipts. |
| Photos import gateway | Creation-only pair/RAW save plus resource readback, with explicit rejected versus uncertain outcomes. |
| AppEnvironment / AppModel integration | Own the services, lifecycle and status UI; refresh existing library sources after confirmed import. |

Reuse portable PTP primitives where they fit, but do not pass wireless import
through `FujiCameraService`'s USB RAW-conversion readiness. Keep transfer
capabilities distinct from rendering capabilities. Fuji's transport uses its
own framing after initialization; a generic standards-only PTP/IP client is
not enough. Validate packet sizes, counts, transaction IDs and response types;
bound allocations/timeouts and discard an out-of-sync session. Never assume a
TCP read contains exactly one complete PTP frame.

Known session/configuration writes needed to enter transfer mode are in scope.
Speculative opcodes, firmware modification and saved-recipe writes are not.
Retain attribution/license notices for adapted open-source code and record its
exact source revision and local protocol corrections.

## Validation and delivery gates

1. **Protocol feasibility:** record BLE discovery, authentication, WiFi launch,
   native join, PTP setup and both-original download separately on available
   X-T5 and X-E3 firmware. Test X-E3 AutoSave on Mac as a diagnostic if useful,
   but only an iPhone success establishes the app fallback. If it cannot expose
   both originals, stop claiming that path and report the evidence.
2. **Deterministic tests:** packet framing/fragmentation, bounds, transactions,
   both BLE families, capability selection without strict firmware pinning,
   late callbacks, denial, join cancellation and temporary inactivity. Include
   reconnect, card changes, cross-card pairing, duplicate filenames and
   unsupported RAW exposure.
3. **Import correctness:** pair/RAW fixtures; interrupted first/second download;
   lengths, metadata and hashes; failed/uncertain Photos completion; cancellation
   during save; limited access; full storage; relaunch and receipt-based retry.
   No successful pair receipt may reference a single-resource Photos asset.
4. **UI and regression:** status entry point, first pairing, both saved cameras,
   progress/errors, AutoSave guidance, RAW-only choice, resume/discard and USB
   exclusion in portrait, both landscape orientations and accessibility sizes.
   Use `Scripts/test-ios.sh --fast` during implementation, affected UI suites,
   then the complete `Scripts/test-ios.sh` suite before delivery.
5. **Physical acceptance:** signed iPhone build, real prompts/permissions,
   Bluetooth reconnect across camera power cycles, WiFi teardown, a mixed batch
   of at least 20 captures per supported transfer path where available, split
   X-T5 cards, cancellation/background/relaunch and exact-byte Photos readback.
   Include a supported compressed RAF and an uncompressed RAF where the camera
   provides them. No camera/card file changes or unintended Photos duplicates.
6. **Firmware coverage:** exercise real available versions and replay captured
   older/newer protocol fixtures. Never downgrade a camera solely to fill the
   matrix without a separate user decision. Report untested versions honestly;
   replay/simulator evidence is not physical certification.

Use isolated Jujutsu workspaces under `/tmp/`, push each checkpoint to the active
development bookmark, use the project's `.venv` for Python and task-owned
simulators for app tests. Clean up task simulators after use. Follow repository
signing instructions for physical installs. Documentation-only checks do not
require an app build or establish any hardware support.

## Proposed defaults to review

- Both cameras can be saved, with one explicitly selected reconnect target.
- Initial pairing is explicit; reconnect happens while foregrounded; WiFi and
  imports always start from a user action.
- Camera browsing lives inside the status connection flow. The main tray remains
  a view of imported Photos assets.
- First-version import covers pairs and RAF-only captures. JPEG-only/HEIF/movie
  import is not included.
- X-E3 uses guided shared-network AutoSave if necessary and verified. Its
  one-button RAW handoff is not promised without new evidence.
- Transfers are sequential; interrupted partial files restart, completed staged
  files can be reused, and unfinished jobs require explicit Resume.
- USB processing and wireless import are mutually exclusive; wireless import
  does not enable wireless recipe processing.

## Left to the builder

Choose concrete protocol/type names, actor boundaries within these ownership
rules, UI icon details, pagination/chunk sizing, bounded attempt deadlines,
thumbnail caching, journal serialization and migration mechanics. Refine these
with measured camera behavior without weakening the original-byte, pair,
permission, recovery or firmware-evidence contracts. Any change to supported
import formats, user flow or the X-E3 fallback feasibility comes back as a
documented scope decision rather than an invisible implementation shortcut.
