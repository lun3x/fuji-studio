# Camera WiFi Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import byte-identical JPEG+RAF pairs and standalone RAF files from an X-T5 or X-E3 on its latest firmware, using foreground Bluetooth readiness, explicit WiFi connection and recoverable Photos saves.

**Architecture:** Put portable Bluetooth protocol profiles, wireless PTP framing, firmware admission and camera capture descriptions in FujiCameraCore. Put CoreBluetooth, network joining, protected credentials, Photos creation, journals and observable UI coordinators in the iOS app. Keep one app-level camera-use arbiter above the existing USB service and the wireless session; import never enters USB conversion readiness or the existing Photos replacement workflow.

**Tech Stack:** Swift 6, iOS 27, Swift actors/Observation/SwiftUI, CoreBluetooth, Network, NetworkExtension, Security/Keychain, PhotoKit, CryptoKit, ImageIO, XCTest, XcodeGen, Jujutsu. No new third-party runtime library.

**Spec:** [Approved camera WiFi import design](../specs/2026-11-14-camera-wifi-import-design.md), approved 2026-11-14. [Pinned protocol research](../../validation/wireless-protocol-research.md) supplies evidence, not an alternative compatibility policy.

## Global Constraints

- “Support both X-T5 and X-E3 on their latest official stable firmware only.” Targets checked again on 2026-11-14: X-T5 **4.32**, X-E3 **1.32**; recheck official releases at implementation start and release validation.
- “Target one latest stable firmware per model in each app release.” Bundled exact admission table; reject older, newer/unvalidated and unreadable firmware before browsing or file transfer. Pairing and identity reads may precede admission.
- “Both X-T5 and X-E3 can be remembered. The last explicitly selected camera is the reconnect target.” Never automatically select another body.
- Reconnect backoff: **3, 6, 12 and then 30 seconds** while foregrounded. Authentication failure requires explicit repair/retry. Preserve explicit intent during system-prompt inactivity; genuine background entry pauses work.
- “The first version imports RAW+JPEG and standalone RAF.” JPEG-only, HEIF and movies are informational, not selectable. Never silently downgrade a selected pair.
- “Create a new Photos asset per capture.” JPEG `.photo` and RAF `.alternatePhoto` belong to the same asset; import does not call pair replacement or delete originals.
- “Reconcile an interrupted Photos submission before any retry.” Inaccessible/uncertain saves retain staged files and cannot be resubmitted merely because lookup returns no asset.
- “Use public iOS APIs and the existing iOS 27 / Swift 6 project baseline.” No location permission, background BLE mode or ongoing background transfer.
- X-E3 AutoSave requires a signed-iPhone feasibility gate. If it fails, report the precise limitation for a scope decision; the two-camera feature is not complete.
- “Wireless import and USB recipe/conversion work do not operate the camera simultaneously, even if distinct devices are attached in the first version.” Native cleanup must finish before transport handoff.
- No wireless rendering, recipe writes, remote shutter, live view, camera/card deletion, firmware installation or global resize-setting mutation.
- Use `jj`, isolated `/tmp/` workspaces, task-owned simulators, the project `.venv` for Python, and push every checkpoint to `codex/camera-wifi`. Follow repository signing instructions.

## Review Focus

These are additional adverse inputs to pin explicitly, beyond ordinary success-path coverage. Each is assigned below.

1. Reused filenames/handles after a card swap: never resume against a different original or suppress it as already imported (Tasks 7, 9, 11).
2. Process death between Photos creation and durable confirmation: retain evidence and reconcile without creating a duplicate (Tasks 9–11).
3. A delayed Bluetooth/join callback after Cancel or Change camera: never adopt the old session or initiate a new join (Tasks 3, 5).
4. A USB close that returns without confirming native teardown: wireless must remain blocked, including after preview cancellation (Task 8).
5. Camera-provided names, lengths and counts that are malformed or enormous: no path traversal, unbounded memory, overflow or partial-file success (Tasks 4, 7, 9).

---

## Execution order, workspace and checks

This is one integrated plan because the transport identity, frozen capture policy and durable save receipt cross every subsystem. The independently testable checkpoints are separate tasks; splitting into unrelated plans would obscure those contracts. Tasks 1–6 establish protocol feasibility before substantial production UI work. Tasks 7–11 implement browsing and safe import; Tasks 12–14 integrate and validate it.

The planning baseline is `3f9aa60c`, descended from `main@origin` `8eec2a26`; source paths below were inspected there. Before implementation, fetch origin and reconcile any newer main changes in the isolated implementation workspace. Do not modify another worker's workspace.

```sh
jj git fetch --remote origin
jj workspace add /tmp/fuji-studio-wifi-implementation -r codex/camera-wifi@origin
cd /tmp/fuji-studio-wifi-implementation
xcrun simctl list runtimes
xcrun simctl list devicetypes
```

Select an installed iOS 27 runtime identifier from that output; create a new iPhone 15 Pro simulator and save its UDID. Set `FUJI_STUDIO_DESTINATION="platform=iOS Simulator,id=$WIFI_SIMULATOR_UDID"` and `FUJI_STUDIO_TEST_WORKERS=1` for every app test command. Run baseline `swift test --package-path Packages/FujiCameraCore` and `Scripts/test-ios.sh --fast`; record unrelated failures before changing code. At finish, shut down and delete only that task's simulator. Do not use another task's simulator or global Python.

Commands below assume those environment variables remain exported. Package tests use `swift test --package-path Packages/FujiCameraCore --filter SuiteName`; app tests use `Scripts/test-ios.sh FujiStudioTests/SuiteName`. Each test-first step must demonstrate the intended assertion failing, or a missing new interface at first; unrelated build failures are not evidence. After the implementation step, the same command must pass with zero failures. Run `Scripts/test-ios.sh --fast` at integration checkpoints, affected UI suites after UI changes, and the full runner at Task 14. A simulator cannot certify Bluetooth, AutoSave entitlements or camera firmware support.

The XCTest contracts use local fixture variables populated by the described scenarios; they specify assertions, not new production interfaces. Implement the additional named scenarios in the same owning suites.

Every task ends with this checkpoint, substituting its stated message. Use `jj new` after pushing to keep each next task a new change. If the bookmark moved concurrently, fetch and reconcile rather than overwriting it.

```sh
jj diff --stat
jj describe -m '<task checkpoint message>'
jj bookmark set codex/camera-wifi -r @
jj git push --remote origin --bookmark codex/camera-wifi
jj new
```

## File and interface map

Paths named in task Files blocks are exact. `Core/` below abbreviates `Packages/FujiCameraCore/Sources/FujiCameraCore/`; `CoreTests/` abbreviates `Packages/FujiCameraCore/Tests/FujiCameraCoreTests/`. Other paths are repository-relative. Each task creates only the files it owns; the map describes responsibilities, not a scaffolding task.

| Location | Responsibility |
| --- | --- |
| `Core/Wireless/` | Value types, exact firmware support, BLE profile reducers, bounded wire codec and transfer session/adapters. No Apple UI/framework objects. |
| `FujiStudio/Wireless/` | Native BLE/network/Keychain boundaries, connection coordinator and USB ownership. |
| `FujiStudio/Import/` | Pair resolution, browser model, private staging, durable journal/receipts, Photos creation/readback and sequential import. |
| `FujiStudio/Workspace/` | Status connection section, camera browser, transfer/recovery views. |
| `FujiStudio/Debug/WirelessProtocolProbe.swift` | Explicit DEBUG-only physical protocol probe using production adapters; no auto-probe on normal launch. |
| `FujiStudioTests/Wireless/`, `FujiStudioTests/Import/` | Injected drivers, manual clock, byte streams, journal fault injection, Photos transaction fakes. |
| `docs/validation/wireless-import-acceptance.md` | Per-model/firmware/mode evidence and physical acceptance results. |

All cross-actor values are `Sendable`; durable values are `Codable`, with `Hashable` identities. CoreBluetooth/PhotoKit objects stay inside their native gateway. Actor coordinators expose value snapshots/streams; SwiftUI observes main-actor models. A canceled consumer must terminate its stream and close the owned session, never leave an unbounded producer running.

## Task 1: Define firmware admission and evidence-backed protocol profiles

**Files:** Create `Core/Wireless/WirelessTypes.swift`, `Core/Wireless/WirelessSupportPolicy.swift`, `Core/Wireless/WirelessLimits.swift`, `CoreTests/WirelessSupportPolicyTests.swift`, `docs/validation/wireless-import-acceptance.md`.

**Interfaces:**
- `WirelessCameraModel`: `.xt5`, `.xe3`; `WirelessMode`: `.xApp`, `.phone`, `.autoSave`.
- `WirelessCameraID` wraps a UUID generated on explicit pairing; a display name/model is never identity. `WirelessIdentity` carries camera ID, model, firmware and optional protected protocol peer key. `WirelessSupportPolicy.assess(model: String, firmware: String?) -> WirelessAdmission` returns `.supported(WirelessCameraModel)`, `.updateRequired(String)`, `.unverified(String?)` or `.unsupportedModel`.
- `WirelessCapabilities` has `mode`, `rawExposure` (`.available`, `.unavailable`, `.unknown`), `storageIDs: [UInt32]`, `originalSizeVerified: Bool` and `evidenceID: String`. Capability presence cannot bypass admission.
- `WirelessFailure` distinguishes permission kind, authentication, unsupported firmware/protocol, timeout stage, peer mismatch, malformed data, unavailable storage and connection loss; do not embed secret payloads.
- `WirelessLimits` centralizes the builder-chosen defaults: saved reconnect 30 s, explicit first pairing 90 s, WiFi readiness 15 s, join-result wait 120 s, TCP/setup 15 s, per-transaction inactivity 30 s, AutoSave registration wait 120 s; async clock injected by callers. Native prompt dismissal remains OS-owned after timeout.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testOnlyCurrentFirmwareIsAdmitted() {
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.32"), .supported(.xt5))
    XCTAssertEqual(policy.assess(model: "X-E3", firmware: "1.31"), .updateRequired("1.32"))
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.33"), .unverified("4.33"))
}
```

- [ ] **1. Write failing `WirelessSupportPolicyTests`.** Assert exact targets succeed; X-T5 4.31/X-E3 1.31 require update; 4.33/1.33 and nil/garbage are unverified; a different camera is unsupported. Parse version components numerically, not floating point. Accept only observed normalization (trim surrounding whitespace and a leading `Ver.`); preserve raw text in private evidence.
- [ ] **2. Run** `swift test --package-path Packages/FujiCameraCore --filter WirelessSupportPolicyTests`; confirm the missing-policy failure.
- [ ] **3. Implement the types, policy and limits.** Keep this separate from `FujiCameraRegistry` and USB support rules. Include official instructions URLs in support records; no network lookup during app use.
- [ ] **4. Populate the evidence template.** Recheck [X-T5](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/) and [X-E3](https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/) releases. Record target versions and unknowns for BLE, identity, WiFi readiness, original-size control, both cards, RAW exposure and AutoSave markers. Distinguish source observations from local captures; do not label targets verified yet. Before porting each protocol sequence, inspect its exact pinned source from the research, including its license.
- [ ] **5. Re-run the policy suite**, expected all pass.
- [ ] **6. Checkpoint:** `feat: define latest-firmware wireless admission`.

## Task 2: Implement current-model BLE pairing and protected saved cameras

**Files:** Create `Core/Wireless/FujiBLEProfile.swift`, `Core/Wireless/XT5BLEProfile.swift`, `Core/Wireless/XE3BLEProfile.swift`, `CoreTests/FujiBLEProfileTests.swift`; create `FujiStudio/Wireless/BluetoothGateway.swift`, `FujiStudio/Wireless/NativeBluetoothGateway.swift`, `FujiStudio/Wireless/SavedCameraStore.swift`, `FujiStudio/Wireless/KeychainCameraStore.swift`; create `FujiStudioTests/Wireless/BluetoothGatewayTests.swift`, `FujiStudioTests/Wireless/SavedCameraStoreTests.swift`; create `docs/third-party/wireless-protocol-notices.md`; modify `project.yml`.

**Interfaces:**
- Core `FujiBLEProfile.receive(_ event: BLEProtocolEvent) throws -> [BLEProtocolAction]` consumes service/characteristic values and emits ordered reads/writes/subscriptions or authenticated/readiness results. Events/actions contain UUID strings and bounded `Data`, never CB objects. Use separate profiles for current X-T5 secure bonding and current X-E3 pairing.
- App `BluetoothGateway: Sendable`: `discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error>`, `pair(_ camera: DiscoveredCamera) async throws -> SavedCamera`, `reconnect(_ camera: SavedCamera) async throws`, `activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork`, `disconnect() async`. Discovery is invoked only after explicit user intent; reconnect cannot create a new pairing.
- `DiscoveredCamera` holds peripheral UUID, advertised model hint and display name; hints are not firmware admission. `SavedCamera` holds camera ID, peripheral UUID, model, display name and optional verified peer-key reference. `CameraNetwork` holds SSID, explicit security kind and credential reference with redacted descriptions.
- `SavedCameraStore: Sendable`: `cameras() async throws -> [SavedCamera]`, `selected() async throws -> WirelessCameraID?`, `save(_ camera: SavedCamera) async throws`, `select(_ id: WirelessCameraID) async throws`, `forget(_ id: WirelessCameraID) async throws`. Credential access stays inside the gateway/store implementation.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testSavedReconnectDoesNotPairAgainOrExposeSecrets() {
    XCTAssertEqual(recordedPairingWrites.count, 0)
    XCTAssertEqual(reconnectedPeripheralIDs, [selectedPeripheralID])
    XCTAssertFalse(exportedDiagnostics.contains(testPassword))
}
```

- [ ] **1. Add replay tests** for ordered secure authentication/subscription, X-E3 token exchange, missing characteristics, malformed four-byte status, authentication failure and reconnect without pairing writes. Add store tests saving both models, selecting one, relaunching, and forgetting only its credentials; receipts must be unaffected. Fake peripheral callbacks stay on the native driver's serial executor.
- [ ] **2. Run** `swift test --package-path Packages/FujiCameraCore --filter FujiBLEProfileTests` and `Scripts/test-ios.sh FujiStudioTests/BluetoothGatewayTests FujiStudioTests/SavedCameraStoreTests`; verify intended failures.
- [ ] **3. Implement profiles and the CoreBluetooth boundary.** Adapt only the pinned sequences in the research; do not add historical X-T5 pairing. CoreBluetooth owns OS bonding. Verify service/characteristic membership before any write. A missing password is an error, not an open network. WiFi readiness needs a recognized response/read, not elapsed-time success. If no target-confirmed readiness signal exists, record that as a Task 5 gate failure.
- [ ] **4. Implement protected persistence and permission behavior.** Use app-owned Keychain items with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; persist selected ID without secret material in app preferences. Do not initialize a prompting central on first ordinary launch. Add `NSBluetoothAlwaysUsageDescription`: “Fuji Studio connects to your selected Fujifilm camera to prepare photo transfers.” Keep diagnostics free of tokens, SSIDs, passwords, serials and peripheral identifiers. Include upstream MIT notices for adapted code.
- [ ] **5. Re-run all three suites**, expected all pass. Add a diagnostics assertion that secret test strings never occur in exported descriptions.
- [ ] **6. Checkpoint:** `feat: pair current Fujifilm cameras over Bluetooth`.

## Task 3: Own foreground reconnect and explicit connection intent

**Files:** Create `FujiStudio/Wireless/WirelessConnectionCoordinator.swift`, `FujiStudio/Wireless/WirelessConnectionState.swift`; create `FujiStudioTests/Wireless/WirelessConnectionCoordinatorTests.swift`, `FujiStudioTests/Support/ManualWirelessClock.swift`.

**Interfaces:**
- Actor `WirelessConnectionCoordinator` consumes `BluetoothGateway`, `SavedCameraStore`, injected sleep/clock and limits. `states() -> AsyncStream<WirelessConnectionState>`, `setActivity(_ activity: WirelessActivity) async`, `select(_ id: WirelessCameraID) async throws`, `forget(_ id: WirelessCameraID) async throws`, `retryBluetooth() async`, `cancelConnection() async`; Task 5 adds WiFi operations.
- `WirelessActivity`: `.active`, `.inactive`, `.background`. State independently carries saved/selected cameras, Bluetooth readiness, WiFi phase and actionable failure. `connectionGeneration: UInt64` tags all asynchronous completions.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testTransientRetriesBackOffAndAuthFailureStops() {
    XCTAssertEqual(recordedRetrySeconds, [3, 6, 12, 30, 30])
    XCTAssertEqual(attemptsAfterAuthFailureAndClockAdvance, 0)
    XCTAssertEqual(wifiJoinCallsAfterForeground, 0)
}
```

- [ ] **1. Write coordinator tests** with a manual clock and controlled gateway: initial unauthorized launch makes zero driver calls; selected saved camera gets one activation attempt; transient failures retry after exactly `[3, 6, 12, 30, 30]` seconds; success resets backoff. Assert authentication denial halts retries and explicit retry restarts. Never reconnect to the other saved camera.
- [ ] **2. Add lifecycle tests:** inactivity preserves an explicit intent; background cancels discovery/retry and invalidates generations; foreground reconnects Bluetooth only. Delayed discovery/authentication callbacks after Cancel, Forget or selection change cannot adopt old state. Selection change with an active transfer is rejected until pause/cancel completes.
- [ ] **3. Run** `Scripts/test-ios.sh FujiStudioTests/WirelessConnectionCoordinatorTests`, expected intended failures.
- [ ] **4. Implement the coordinator.** One attempt at a time; cancellation drains native callbacks before reusing the driver. Absence is a normal status, not recurring alerts. No WiFi join or permission retry is implicit in Bluetooth readiness. Hold explicit connect intent through its bounded attempt instead of requiring another tap when BLE becomes ready.
- [ ] **5. Re-run the suite**, expected all pass.
- [ ] **6. Checkpoint:** `feat: maintain selected camera Bluetooth readiness`.

## Task 4: Add bounded Fuji wireless framing and streaming I/O

**Files:** Create `Core/Wireless/WirelessByteChannel.swift`, `Core/Wireless/FujiWirelessFrameDecoder.swift`, `Core/Wireless/WirelessPTPTransport.swift`, `CoreTests/WirelessPTPTransportTests.swift`; create `FujiStudio/Wireless/NetworkByteChannel.swift`, `FujiStudioTests/Wireless/NetworkByteChannelTests.swift`.

**Interfaces:**
- `WirelessByteChannel: Sendable`: `read(maximumBytes: Int) async throws -> Data` (empty means EOF), `write(_ data: Data) async throws`, `close() async`. Native implementation uses a WiFi-required `NWConnection`; endpoint comes from the recognized mode, not an arbitrary fallback.
- `WirelessPTPTransport` is an actor with `initialize(_ request: Data) async throws -> Data`, `execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply`, `receive(_ command: PTPCommand, expectedBytes: UInt64, sink: @Sendable (Data) async throws -> Void) async throws -> PTPReply`, `close() async`. Streaming `receive` returns an empty `reply.data`; it awaits each sink write for backpressure.
- Decoder accepts incremental bytes, handles PTP/IP initialization separately from Fuji USB-style frames and validates command/data/response correlation. Reuse `PTPCommand`, `PTPReply`, `PTPError`, `PTPDatasets` where their formats apply; never run the USB conversion initialization.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testSlowSinkBoundsMemoryAndEOFDoesNotSucceed() {
    XCTAssertEqual(readsWhileSinkBlocked, 0)
    XCTAssertLessThanOrEqual(streamingPayloadBufferHighWaterBytes, 131_072)
    XCTAssertEqual(truncatedTransferSuccessCount, 0)
}
```

- [ ] **1. Add byte-fixture tests** for every split in a header, one-byte reads, multiple coalesced frames, EOF mid-payload, wrong transaction/opcode/type, truncated lengths, invalid UTF-16/count fields and timeout. A response for a previous generation must fail the session. Replay provenance must distinguish synthetic fixtures from local camera captures.
- [ ] **2. Add backpressure tests:** a blocked sink prevents further reads; transfer of a generated large stream never accumulates the file. Reject metadata payloads over 16 MiB, counts over 100,000 objects per storage, or checked arithmetic overflow. Cap individual native reads at 64 KiB; negotiated partial-object requests at 1 MiB or a smaller verified device limit. Streaming payload lengths may exceed metadata limits but never the frozen original length.
- [ ] **3. Run** `swift test --package-path Packages/FujiCameraCore --filter WirelessPTPTransportTests` and `Scripts/test-ios.sh FujiStudioTests/NetworkByteChannelTests`, expected failures.
- [ ] **4. Implement framing, serialized transactions and native channel.** Bound metadata allocations before allocation, validate response codes and close on desynchronization. Map route/permission denial separately from camera timeout. No cellular route; no concurrent PTP transactions. With cancellation, close the channel to unblock pending reads and complete continuations exactly once.
- [ ] **5. Re-run both suites**, expected all pass; record measured byte-buffer high-water mark in the large-stream test.
- [ ] **6. Checkpoint:** `feat: stream bounded Fujifilm wireless PTP transactions`.

## Task 5: Complete camera-hosted WiFi handoff and prove original retrieval

**Files:** Create `Core/Wireless/WirelessTransferSession.swift`, `Core/Wireless/WirelessObjectDescriptor.swift`, `Core/Wireless/XAppTransferAdapter.swift`, `Core/Wireless/PhoneTransferAdapter.swift`, `CoreTests/WirelessTransferSessionTests.swift`; create `FujiStudio/Wireless/WiFiJoinGateway.swift`, `FujiStudio/Wireless/NativeWiFiJoinGateway.swift`, `FujiStudio/Debug/WirelessProtocolProbe.swift`, `FujiStudioTests/Wireless/WiFiHandoffTests.swift`, `Config/FujiStudio.entitlements`; modify `FujiStudioTests/Wireless/WirelessConnectionCoordinator.swift`, `project.yml`, `FujiStudio/App/FujiStudioApp.swift`, and the acceptance record.

**Interfaces:**
- `WirelessObjectDescriptor` freezes camera ID, session UUID, storage ID, transient handle, directory, filename, format, byte length, capture date, dimensions and available capture-specific metadata. Durable matching excludes session UUID/handle; absent fields remain absent, not invented. `WirelessStorageInventory` records completeness per storage and RAW exposure.
- `WirelessTransferSession: Sendable`: `open() async throws -> WirelessIdentity`, `capabilities() async throws -> WirelessCapabilities`, `enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, Error>`, `thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data`, `download(_ object: WirelessObjectDescriptor, to sink: @Sendable (Data) async throws -> Void) async throws`, `close() async throws`. `WirelessInventoryBatch` contains object additions and storage-completion changes. Download uses original-size mode and validates fresh ObjectInfo before admission.
- `WiFiJoinGateway`: `join(_ network: CameraNetwork) async throws -> JoinedCameraNetwork`, `leave(_ network: JoinedCameraNetwork) async`. Returned value records whether this attempt owns a temporary configuration; successful association alone is not peer identity or transfer readiness.
- Coordinator adds `connectWiFi() async`, `disconnectWiFi() async`, `transferSession() async throws -> any WirelessTransferSession`; inject a session factory and camera-ownership gateway (fake until Task 8). No session is publicly usable before firmware admission and first usable inventory, including a valid empty card.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testCancelledJoinCannotAdoptLateCompletion() {
    XCTAssertEqual(ptpOpenCallsAfterCancelledJoin, 0)
    XCTAssertEqual(removedSSIDs, [ownedAttemptSSID])
    XCTAssertFalse(removedSSIDs.contains(preexistingSSID))
}
```

- [ ] **1. Write setup/handoff tests:** BLE authenticated → credentials → confirmed readiness → native join → PTP identity → exact firmware admission → inventory. Denial, timeout, missing credentials and mismatched camera identity fail at their own stage. Empty valid storage becomes ready; joined-but-dead PTP does not. An old/native join completion after cancellation must clean up only its owned configuration and never open PTP.
- [ ] **2. Write adapter replay tests** for current XApp mode negotiation, current X-E3 phone mode, card enumeration, original-size control and RAW-unavailable reporting. Firmware rejection permits identity reads but zero enumeration, thumbnail or full-file commands. Unknown setup structures fail without speculative writes.
- [ ] **3. Run** `swift test --package-path Packages/FujiCameraCore --filter WirelessTransferSessionTests` and `Scripts/test-ios.sh FujiStudioTests/WiFiHandoffTests`, expected failures.
- [ ] **4. Implement the gateways/adapters.** Set `joinOnce = true`; Apple documents its [foreground lifetime and removal behavior](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce). Snapshot app-owned configurations before applying; do not remove a previously existing/user-managed network on cancellation. Treat “already associated” as requiring PTP peer validation, not success. Network information/peer binding remains protected; describe any lack of strong protocol identity in evidence.
- [ ] **5. Add configuration and an explicit debug probe.** Set `CODE_SIGN_ENTITLEMENTS` through `project.yml`; enable `com.apple.developer.networking.HotspotConfiguration`. Add `NSLocalNetworkUsageDescription`: “Fuji Studio uses your local network to retrieve original photos from your selected Fujifilm camera.” The probe runs only with `--wireless-protocol-probe`, performs explicit selection and downloads to private staging; no Photos write or USB mutation. Route it to a separate debug composition before constructing AppModel or any USB discovery/service; disconnect the camera's USB cable for the experiment. Normal/fixture launch cannot run it. This makes early physical investigation safe before Task 8 supplies production ownership. Use current pinned reference sequences; record any corrections and required camera resize setting without changing that global setting.
- [ ] **6. Re-run both suites and `Scripts/test-ios.sh --fast`**, expected all pass. Build/sign/install the physical probe using repository instructions. On each target firmware record first pairing, saved reconnect, WiFi readiness and native join. On X-T5, enumerate and download one original pair and a RAF-only capture; compare SHA-256 with independently obtained card originals. Record exact identity and original-size control evidence. X-E3 phone-mode RAF exposure is a measured result, not a prerequisite assumed true.
- [ ] **7. Evaluate the physical gate.** If hardware/latest firmware is unavailable, record pending acceptance and continue only work that does not depend on guessed commands. If the target sequence fails, fix it against captures before certifying that adapter. Do not install camera firmware automatically.
- [ ] **8. Checkpoint:** `feat: connect camera WiFi and negotiate original transfer`.

## Task 6: Establish X-E3 AutoSave on a signed iPhone

**Files:** Create `Core/Wireless/AutoSaveCodec.swift`, `Core/Wireless/AutoSaveTransferAdapter.swift`, `CoreTests/AutoSaveCodecTests.swift`; create `FujiStudio/Wireless/AutoSaveGateway.swift`, `FujiStudio/Wireless/NativeAutoSaveGateway.swift`, `FujiStudioTests/Wireless/AutoSaveGatewayTests.swift`; modify the debug probe, coordinator, entitlements, saved-camera store and acceptance record.

**Interfaces:**
- `AutoSaveGateway: Sendable`: `register(camera: SavedCamera) async throws -> AutoSaveRegistration`, `waitForSession(registration: AutoSaveRegistration) async throws -> any WirelessTransferSession`, `cancel() async`. Registration records selected camera ID, verified protocol peer binding and protected destination credentials. Display name alone cannot match an incoming session.
- Coordinator adds `setUpAutoSave() async` and `waitForAutoSave() async`; these use the same exclusive ownership and generation rules as phone WiFi. The returned adapter implements Task 5's transfer session and firmware gate.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testAutoSaveAcceptsOnlyRegisteredCameraAndCancellationStopsWait() {
    XCTAssertEqual(acceptedPeerKeys, [registeredPeerKey])
    XCTAssertEqual(sessionsAdoptedAfterCancel, 0)
    XCTAssertEqual(acceptedUnknownFirmwareSessions, 0)
}
```

- [ ] **1. Write codec tests** using pinned AutoSave discovery/registration transcripts: bounded datagrams, correct ports 51540/51541/51542 per message role, malformed lengths, unrelated peer, replayed/late registration and truncated identity. Test waiting deadline, Cancel, Local Network denial, entitlement-unavailable and router client isolation as distinct actionable failures where detectable.
- [ ] **2. Run** `swift test --package-path Packages/FujiCameraCore --filter AutoSaveCodecTests` and `Scripts/test-ios.sh FujiStudioTests/AutoSaveGatewayTests`, expected failures.
- [ ] **3. Implement broadcast registration/session acceptance and secure persistence.** Use the pinned libfuji AutoSave message definitions; map endpoint roles from that source, not guessed service names. Do not require Bonjour declarations for a protocol that does not use Bonjour. The supported topology is camera and iPhone on a shared WiFi network without client isolation, with PC AUTO SAVE started on camera.
- [ ] **4. Verify entitlement feasibility immediately.** Add `com.apple.developer.networking.multicast` only with provisioning that actually grants it; inspect both the built signature and embedded provisioning profile. Never count a simulator or a Mac receiver as this gate passing. If signing access must be enabled externally, report that exact prerequisite and keep AutoSave unavailable rather than shipping a misleading enabled button.
- [ ] **5. Re-run the suites**, expected all pass. On X-E3 1.32 and the signed iPhone register Fuji Studio, restart the session, accept only that camera, enumerate/download both originals and compare card hashes. Establish completion-marker behavior with cancellation, retry and a second session; a network transfer acknowledgement is not a Photos import receipt. Record whether markers hide objects and how verified re-enumeration works without modifying originals.
- [ ] **6. Gate the result.** Success permits production AutoSave UI. Failure or inability to retrieve both originals is documented with the failing step and returned for the spec's scope decision. Continue independent X-T5/import work if useful, but do not mark X-E3 support or the whole feature complete. Do not replace the agreed flow with Personal Hotspot or BLE-triggered AutoSave without evidence and a scope decision.
- [ ] **7. Checkpoint:** `feat: add verified X-E3 AutoSave transfer path` only when verified; otherwise use `docs: record X-E3 AutoSave feasibility blocker` and describe implemented/tested code accurately.

## Task 7: Resolve captures and model camera browsing

**Files:** Create `FujiStudio/Import/CameraCapture.swift`, `FujiStudio/Import/CaptureResolver.swift`, `FujiStudio/Import/CameraBrowserModel.swift`; create `FujiStudioTests/Import/CaptureResolverTests.swift`, `FujiStudioTests/Import/CameraBrowserModelTests.swift`.

**Interfaces:**
- `CameraCaptureID` is a digest of normalized descriptive evidence and camera ID, not a PTP handle; collisions remain separate/ambiguous. `CameraCapture` holds constituent descriptors and availability (`checking`, `pair`, `rawOnly`, `jpegOnly`, `rawUnavailable`, `ambiguous`, `unsupported`).
- `CaptureResolver.resolve(objects: [WirelessObjectDescriptor], inventory: WirelessStorageInventory) -> [CameraCapture]` is pure. `ImportSelection` freezes capture ID, camera identity, descriptors and `ImportPolicy` (`pair`, `rawOnly`); `CameraBrowserModel.selectionForImport() throws -> [ImportSelection]` refuses unresolved pairs.
- `@MainActor @Observable CameraBrowserModel`: `load(session: any WirelessTransferSession) async`, `select(_ id: CameraCaptureID, policy: ImportPolicy) throws`, `cancel()`. It publishes captures, selected capture count and known-byte estimate; receipt annotation is added in Task 11.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testDuplicateBasenamesNeverBecomeAnAutomaticPair() {
    XCTAssertEqual(automaticallyAdmittedPairs.count, 0)
    XCTAssertTrue(captureRequiresExplicitRAWOnlyChoice)
    XCTAssertEqual(fullOriginalDownloadsDuringSelection, 0)
}
```

- [ ] **1. Write resolver tests** for same-card and split-card pairs, duplicate basenames in different folders/cards, same timestamp burst, missing dates, inaccessible second card, unknown RAW exposure and explicit RAW-only choice. A pair requires a unique match by camera, directory/capture metadata and compatible filename relationship; absence/ambiguity never promotes a pair. Test card swap and identical handles on distinct sessions.
- [ ] **2. Write browser tests:** newest first with nil dates last and stable identity tie-break; progressive metadata before thumbnails; all accessible cards checked before mate absence is final; JPEG-only/HEIF/movie disabled; one pair counts as one selected photo; selecting does not download originals. Cache thumbnails by session plus object fingerprint, cap at 32 MiB and cancel obsolete requests.
- [ ] **3. Run** `Scripts/test-ios.sh FujiStudioTests/CaptureResolverTests FujiStudioTests/CameraBrowserModelTests`, expected failures.
- [ ] **4. Implement resolver/model.** Cross-card pairing needs corroborating capture metadata, not basename alone. Missing evidence leaves an explicit RAW-only decision. If RAW exposure is unknown/unavailable, distinguish that from a verified JPEG-only capture. Freeze selections at submission; resource changes require new selection. Browser metadata may accumulate to the explicit Task 4 limit; thumbnails remain bounded.
- [ ] **5. Re-run both suites**, expected all pass.
- [ ] **6. Checkpoint:** `feat: browse and select original camera captures`.

## Task 8: Enforce USB and wireless ownership through confirmed teardown

**Files:** Create `FujiStudio/Wireless/CameraUseArbiter.swift`, `FujiStudio/Wireless/ArbitratedCameraService.swift`, `FujiStudioTests/Wireless/CameraUseArbiterTests.swift`; modify `Core/Core/CameraServing.swift`, `Core/Service/FujiCameraService.swift`, `CoreTests/FujiCameraServiceTests.swift`, `FujiStudio/Rendering/CameraWorkScheduler.swift`, `FujiStudio/App/AppEnvironment.swift`, `FujiStudio/App/AppModel.swift` and test doubles implementing `CameraServing` found by `rg -n ': CameraServing'`.

**Interfaces:**
- Add `CameraServing.disconnectConfirmed() async throws`; retain `disconnect() async` for existing lifecycle callers. Implement confirmed close using the existing serial gate and `closeUncancelled()` Boolean; a swallowed error from today's `disconnect()` is not a handoff receipt. Fakes must explicitly model success/failure, not receive a success default.
- Actor `CameraUseArbiter`: `withUSB<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T`, `beginUSBExport(_ jobID: UUID) async throws`, `endUSBExport(_ jobID: UUID) async`, `acquireWireless(quiesceUSB: @Sendable () async throws -> Void) async throws -> CameraUseLease`, `releaseWireless(_ lease: CameraUseLease) async`. `CameraUseLease` contains owner/generation UUIDs.
- `ArbitratedCameraService: CameraServing` wraps every active USB connect/reset/import/render operation with the arbiter; forwards state/support reads. Confirmed handoff closes the underlying service through the reserved arbiter path, avoiding recursive lease acquisition. Scheduler holds the USB export reservation across the entire job, including between items.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testUnconfirmedUSBCloseRetainsOwnership() {
    XCTAssertEqual(wifiActivationCalls, 0)
    XCTAssertEqual(wifiJoinCalls, 0)
    XCTAssertTrue(handoffRequiresExplicitRecovery)
}
```

- [ ] **1. Write failing service/arbiter tests:** background USB connect versus WiFi start; preview cancellation with native operation still running; close returning false; recipe import cleanup; export reservation between items; stale lease release; wireless close failure. Assert zero BLE activation/network join until native teardown confirms, and no new USB operation after wireless reservation begins.
- [ ] **2. Run** `swift test --package-path Packages/FujiCameraCore --filter FujiCameraServiceTests` and `Scripts/test-ios.sh FujiStudioTests/CameraUseArbiterTests FujiStudioTests/CameraWorkSchedulerTests`, expected new failures.
- [ ] **3. Implement confirmed close and the arbiter/wrapper.** Reserve wireless intent atomically, reject active export, stop USB auto-admission, invalidate obsolete preview, wait for native operations, then close confirmed. Failed/unresolved close keeps a blocked handoff state until explicit recovery confirms teardown; timeout does not release ownership. Do not use task cancellation or `PreviewCoordinator.invalidate()` as proof of native completion.
- [ ] **4. Wire scheduler and composition.** All production USB entry points, including automatic discovery and reset, receive the same wrapped service. Restore ordinary USB discovery after confirmed wireless close without resuming a render/export. Initially release BLE during USB ownership; enable idle coexistence only if physical tests establish it safe. Update all fixture environments to inject the same ownership boundary without live hardware access.
- [ ] **5. Re-run focused suites and `Scripts/test-ios.sh --fast`**, expected all pass, including old USB cleanup/recovery behavior.
- [ ] **6. Checkpoint:** `feat: arbitrate USB and wireless camera ownership`.

## Task 9: Persist frozen jobs and validate staged originals

**Files:** Create `FujiStudio/Import/ImportTypes.swift`, `FujiStudio/Import/ImportJournal.swift`, `FujiStudio/Import/ImportStagingStore.swift`, `FujiStudio/Import/OriginalImportValidator.swift`; create `FujiStudioTests/Import/ImportJournalTests.swift`, `FujiStudioTests/Import/ImportStagingStoreTests.swift`, `FujiStudioTests/Import/OriginalImportValidatorTests.swift`.

**Interfaces:**
- `ImportJob` has UUID, selected camera snapshot, frozen selections, ordered per-capture stages and receipts. `ImportStage`: queued, downloading, validating, readyToSave, submitting, savedUnverified, imported, paused, skipped, failed. Job pause reason is independent of a possibly unresolved save stage.
- `StagedOriginal` contains generated relative path, original filename, role, UInt64 byte count, SHA-256 and decoded metadata. `ValidatedCapture` combines selection, validated resources and capture metadata. `ImportReceipt` records capture ID, full fingerprints, Photos ID and verified time.
- Actor `ImportJournal`: `save(_ job: ImportJob) throws`, `loadJobs() throws -> [ImportJob]`, `recordPlaceholder(jobID: UUID, captureID: CameraCaptureID, assetID: String) throws`, `recordReceipt(_ receipt: ImportReceipt, jobID: UUID) throws`. A synchronous locked helper `persistPlaceholder(...) throws` supports the PhotoKit changes-block callback in Task 10 without waiting on actor/MainActor work.
- `ImportStagingStore`: `write(object: WirelessObjectDescriptor, session: any WirelessTransferSession, progress: @Sendable (UInt64) -> Void) async throws -> StagedOriginal`; `OriginalImportValidator.validate(_ selection: ImportSelection, originals: [StagedOriginal], importDate: Date) throws -> ValidatedCapture`.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testStaleJournalWriteCannotErasePlaceholderOrEscapeStaging() {
    XCTAssertEqual(reloadedPlaceholderID, persistedPlaceholderID)
    XCTAssertFalse(staleSnapshotWasAccepted)
    XCTAssertTrue(createdURLs.allSatisfy { $0.deletingLastPathComponent() == stagingRoot })
}
```

- [ ] **1. Write crash/fault-injection tests** for before download, after first full resource, before submission, after placeholder and after receipt. JSON schema v1 uses atomic replace and durable flush before side effects; corrupt/unknown-version journals are quarantined with recovery error, never silently reset. Test an actor save racing the synchronous placeholder callback: a stale snapshot must never overwrite a persisted placeholder or receipt. Tests use unique temporary roots, no production files.
- [ ] **2. Test staging/validation:** `../` and absolute filenames cannot escape storage; negative/overflowing/truncated/overlong data fails; zero-size RAF/JPEG fails; incorrect signature/dimensions and mismatched capture metadata fail. Disk-full at each write leaves uncertain-save evidence intact. Reconnect with changed fingerprints refuses reuse; validated complete components are reusable but partial files restart at byte zero.
- [ ] **3. Run** `Scripts/test-ios.sh FujiStudioTests/ImportJournalTests FujiStudioTests/ImportStagingStoreTests FujiStudioTests/OriginalImportValidatorTests`, expected failures.
- [ ] **4. Implement private staging and durable state.** Use `Application Support/FujiStudio/wireless-import`, opaque generated filenames, data protection, backup exclusion, and no disposable-cache eviction. Share one locked revisioned backing store between journal actor and synchronous placeholder callback; reject stale snapshot writes. Stream hashes; do not load originals into `Data`. Estimate required staging plus Photos copy as twice remaining known original bytes plus 64 MiB headroom; unknown lengths must be resolved before import, actual ENOSPC still handled. No remote checksum claim.
- [ ] **5. Implement original validation/metadata.** Reuse RAF/JPEG metadata readers where sufficient and ImageIO header metadata, without rewriting or full RAW decode. Require full dimensions and verified original-size mode. Prefer embedded capture date/location; then valid ObjectInfo date; finally frozen import time. Convert wall-clock metadata to an absolute Photos date only with an explicit or protocol-verified offset; otherwise preserve its original date components in the file and use the deterministic import-time fallback. Record the missing-offset reason rather than inventing a timezone or GPS coordinates. Add `testMissingTimezoneUsesFrozenImportDate` asserting the fallback date, nil invented location and unchanged original hash.
- [ ] **6. Re-run the suites**, expected all pass. Test journal persistence failure prevents download/Photos submission and never destroys validated originals.
- [ ] **7. Checkpoint:** `feat: journal and validate staged camera originals`.

## Task 10: Create and reconcile new Photos pairs without replacement

**Files:** Create `FujiStudio/Import/PhotoImportGateway.swift`, `FujiStudio/Import/NativePhotoImportGateway.swift`, `FujiStudio/Import/ImportPhotoVerifier.swift`; create `FujiStudioTests/Import/PhotoImportGatewayTests.swift`, `FujiStudioTests/Import/ImportPhotoVerifierTests.swift`, `FujiStudioTests/Import/NativePhotoImportIntegrationTests.swift`; modify Photos permission copy in `project.yml`.

**Interfaces:**
- `PhotoImportGateway: Sendable`: `create(_ capture: ValidatedCapture, onPlaceholder: @escaping @Sendable (String) throws -> Void) async -> PhotoImportOutcome`, `inspect(assetID: String) async throws -> ImportedAssetInspection`, `candidates(for capture: ValidatedCapture) async throws -> [String]`. Inspection streams each original resource for SHA-256/length/role verification.
- `PhotoImportOutcome`: `.submitted(assetID: String)`, `.rejected(PhotoImportFailure)`, `.uncertain(assetID: String?)`. `.rejected` means definitively no new asset, not simply any error/cancellation.
- `PhotoImportFailure`: authorization, invalidResource, storage, unavailable or missingConfirmation. `ImportedAssetInspection` distinguishes a found snapshot, inaccessible/unavailable result and authoritative absence. A found snapshot contains asset ID and original-resource fingerprints (role, original filename, byte count, SHA-256); it is not just a list of filenames.
- `ImportPhotoVerifier.reconcile(capture: ValidatedCapture, placeholder: String?) async -> ImportReconciliation`: `.verified(ImportReceipt)`, `.definitivelyAbsent`, `.savedUnverified(String?)`, `.uncertain`. Absence requires authoritative library access/availability and complete candidate inspection; limited visibility, multiple matches, cloud-resource failure or missing evidence cannot prove it.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testPairCreatesOneAssetAndReadbackRequiresBothOriginals() {
    XCTAssertEqual(createdAssetCount, 1)
    XCTAssertEqual(addedResourceTypes, [.photo, .alternatePhoto])
    XCTAssertEqual(deleteAssetCalls, 0)
    XCTAssertEqual(verifiedReceiptsForSingleResourceAsset.count, 0)
}
```

- [ ] **1. Write gateway tests:** a pair creates exactly one asset with `.photo` JPEG and `.alternatePhoto` RAF and preserved filenames; RAF-only creates one RAW resource. Assert no source lookup, album replacement or delete call occurs, regardless of Update original in Photos. Assert initial JPEG display selection where supported, creation date/location passed without media rewrite.
- [ ] **2. Write reconciliation tests** for process death before placeholder persistence, after placeholder, completion callback loss, canceled save, callback failure after changes were issued, limited library access, mismatched hash, extra/missing role and two candidate matches. Filename/date alone cannot produce a verified receipt; a one-resource asset never completes a pair.
- [ ] **3. Run** `Scripts/test-ios.sh FujiStudioTests/PhotoImportGatewayTests FujiStudioTests/ImportPhotoVerifierTests`, expected failures.
- [ ] **4. Implement the creation-only gateway.** Use one PhotoKit transaction, `shouldMoveFile = false`, and `supportsAssetResourceTypes` preflight. Persist submitting intent before calling PhotoKit. Once a placeholder exists invoke the synchronous durable callback immediately; failure there is uncertain because Photos may still commit. Do not block that callback on an actor scheduled by the caller. Native transaction settlement is owned independently of UI task cancellation.
- [ ] **5. Implement readback/reconciliation.** Inspect placeholder first, then a candidate search using expected capture metadata and original filenames with complete role/hash comparison. Photos creationDate is the assigned capture date, not the submission date: never search only an import-time window. Narrow filters locate candidates but cannot establish absence unless their completeness is demonstrated; otherwise remain uncertain. Request access only through explicit import/Manage Photos actions; require inspectable full or limited read/write access, not add-only. Retain saved-unverified originals when access prevents readback. Stream originals using `PHAssetResourceManager`; network/iCloud unavailability remains unresolved. Update permission text to include explicitly imported original RAW+JPEG photos.
- [ ] **6. Re-run suites**, expected all pass. Add an explicitly invoked native integration test that saves a known pair and RAF-only fixture and independently reads back original hashes; record real PhotoKit result separately from fake-gateway unit results. Do not automatically delete user Photos to clean up tests.
- [ ] **7. Checkpoint:** `feat: create and verify original Photos imports`.

## Task 11: Run sequential imports with pause, deduplication and recovery

**Files:** Create `FujiStudio/Import/CameraImportCoordinator.swift`, `FujiStudio/Import/ImportRecovery.swift`, `FujiStudio/Import/ImportEvent.swift`; create `FujiStudioTests/Import/CameraImportCoordinatorTests.swift`, `FujiStudioTests/Import/ImportRecoveryTests.swift`; modify browser receipt annotation and the journal as needed.

**Interfaces:**
- Actor `CameraImportCoordinator`: `start(_ selections: [ImportSelection], session: any WirelessTransferSession) async throws -> UUID`, `pause(jobID: UUID) async`, `resume(jobID: UUID, session: any WirelessTransferSession) async throws`, `retryCapture(jobID: UUID) async throws`, `skipCapture(jobID: UUID) async throws`, `cancelRemaining(jobID: UUID) async`, `discardRemaining(jobID: UUID) async throws`, `reconcile() async`, `events() -> AsyncStream<ImportEvent>`.
- `ImportEvent` carries monotonic sequence, job/capture IDs, bytes/stages, pause/action availability, completed receipts and retained bytes. `ImportRecovery` consumes journal, staging and verifier; it never opens WiFi or submits a new save without explicit user intent.
- Browser receipt lookup returns verified, inaccessible, definitively deleted or different-content. An Imported badge requires current asset existence plus expected resources; receipts survive forgetting a pairing.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testRelaunchWithUncertainSaveNeverResubmits() {
    XCTAssertEqual(photoCreateCallsAfterRelaunch, 0)
    XCTAssertEqual(retainedOriginalURLs.count, 2)
    XCTAssertFalse(resumeWouldSubmitUnresolvedCapture)
}
```

- [ ] **1. Write deterministic end-to-end tests:** three captures serialize; first/second component interruption; pair mate changes; storage exhaustion; failure pauses queue with Retry/Skip/Cancel. A failed selected pair never calls RAW-only save. Cancelling stops new work, removes unsubmitted partial files, keeps completed receipts and waits/reconciles any submitted save.
- [ ] **2. Write recovery tests** restarting at every journal boundary; reuse validated full components, restart partial bytes at zero, and rediscover fresh handles on reconnect. Card swaps/reused names require fresh selection unless full identity/fingerprints prove sameness. Lost callbacks/limited access block resubmission and retain storage. `discardRemaining` must refuse unresolved submitted captures, never delete Photos, and explain retained bytes.
- [ ] **3. Test deduplication** with existing receipt/live verified asset, identical names but different hashes, forgotten-and-repaired camera, definitive deletion under full access and missing visibility under limited access. Hashes prove original content; a descriptor match is only a candidate. Explicit reimport after confirmed deletion is allowed; uncertain absence is not.
- [ ] **4. Run** `Scripts/test-ios.sh FujiStudioTests/CameraImportCoordinatorTests FujiStudioTests/ImportRecoveryTests`, expected failures.
- [ ] **5. Implement the sequential loop and crash recovery.** Journal every irreversible transition, reserve before side effects, validate both resources before save and inspect both after it. Candidate receipt lookup must also work across a forgotten pairing/new camera UUID: use complete downloaded fingerprints plus a verified existing asset, not the old camera ID alone. Persist verified receipt before deleting staging. On background/loss pause admission, drain bounded work and leave any outstanding Photos transaction recoverable. Foreground reconcile may read existing Photos but cannot rejoin WiFi, download or submit a new save automatically.
- [ ] **6. Re-run suites**, expected all pass. Assert each capture only reaches imported after a matching verified receipt, and every non-verified submitted record still owns its staged originals.
- [ ] **7. Checkpoint:** `feat: recover camera imports without duplicate Photos saves`.

## Task 12: Compose wireless services and refresh imported library sources

**Files:** Modify `FujiStudio/App/AppEnvironment.swift`, `FujiStudio/App/AppModel.swift`, `FujiStudio/Workspace/WorkspaceState.swift`, `FujiStudio/Debug/FixtureEnvironment.swift`, `FujiStudio/Debug/ModelCameraFixtures.swift`; create `FujiStudio/Debug/WirelessFixture.swift`, `FujiStudioTests/App/WirelessAppModelTests.swift`; modify existing fixture/test environment initializers found by `rg -n 'AppEnvironment\(' FujiStudio FujiStudioTests`.

**Interfaces:**
- Environment owns one connection coordinator, arbiter, browser, import coordinator and durable journal; construction failures surface rather than silently switching to volatile storage. Unit/UI fixture routes inject fakes before any live central/network/Photos gateway exists.
- AppModel adds `connectCameraWiFi() async`, `disconnectCameraWiFi() async`, `importSelectedCaptures() async`, `viewImported(jobID: UUID) async`; observes wireless/import value events independently of USB `CameraState`.
- Workspace state adds a wireless-ownership restriction to recipe/export admission. `viewImported` resolves verified receipt IDs through `reader.source(id:)`, upserts sources in catalog, explicitly selects the imported set and reveals the newest source. Automatic receipt handling only merges sources; it preserves current viewer/selection.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testVerifiedImportPreservesViewerUntilViewImported() {
    XCTAssertEqual(automaticallyUpdatedViewerID, originalViewerID)
    XCTAssertEqual(automaticallyUpdatedSelection, originalSelection)
    XCTAssertEqual(selectionAfterViewImported, Set(verifiedImportedSourceIDs))
}
```

- [ ] **1. Write app tests** for inactive system prompt versus background, foreground BLE-only reconnect, automatic/manual USB paths obeying ownership, library merge preserving selection/viewer, receipt order and View imported. Verify unresolved Photos saves never add a tray source as successfully imported. Import ignores Update original in Photos.
- [ ] **2. Test fixture isolation**: every existing unit/UI route constructs zero live Bluetooth/network gateways; existing callers compile with explicit fake wireless services. App startup loads unfinished jobs but never resumes one automatically.
- [ ] **3. Run** `Scripts/test-ios.sh FujiStudioTests/WirelessAppModelTests FujiStudioTests/AppModelTests FujiStudioTests/ExportSuspensionTests`, expected new failures.
- [ ] **4. Implement composition and lifecycle forwarding.** Forward all three scene phases to the wireless coordinator before existing early returns. Keep `.inactive` distinct from `.background`; background closes transfer and persists import, active reconciles receipts and reconnects BLE only. Merge imported assets incrementally without forcing a full permission prompt or resetting current display. Keep existing Photos change observation working.
- [ ] **5. Re-run focused suites and `Scripts/test-ios.sh --fast`**, expected all pass.
- [ ] **6. Checkpoint:** `feat: integrate wireless import with app lifecycle and library`.

## Task 13: Add status connection, camera browser and recovery UI

**Files:** Create `FujiStudio/Workspace/CameraConnectionSection.swift`, `FujiStudio/Workspace/CameraBrowserView.swift`, `FujiStudio/Workspace/CameraImportProgressView.swift`, `FujiStudio/Workspace/AutoSaveSetupView.swift`; modify `FujiStudio/Workspace/ExportProgressView.swift`, `FujiStudio/Workspace/CameraStatusControl.swift`, `FujiStudio/Debug/WirelessFixture.swift`; create `FujiStudioUITests/WirelessConnectionTests.swift`, `FujiStudioUITests/CameraImportTests.swift`; modify `FujiStudioUITests/StatusSettingsTests.swift`, `FujiStudioUITests/WorkspaceAccessibilityTests.swift` and `FujiStudioTests/Workspace/CameraIndicatorTests.swift`.

**Interfaces:** Views consume connection/browser/import models and call their explicit intent methods. Keep existing `app.status` button and Status & settings sheet, existing Photos/settings/USB errors and export recovery. Add stable accessibility identifiers under `wireless.*`, `cameraBrowser.*`, `cameraImport.*`.

Representative named XCTest contract (fixture arrangement follows the test steps below):

```swift
func testStatusSeparatesBluetoothFromUSBReadiness() {
    XCTAssertNotEqual(app.buttons["app.status"].value as? String, "Camera ready")
    app.buttons["app.status"].tap()
    XCTAssertTrue(app.buttons["wireless.connect"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["wireless.connect"].label, "Connect over WiFi")
}
```

- [ ] **1. Write UI tests** opening `app.status`, pairing each model, switching between two saved cameras, Connect over WiFi during BLE reconnect, Cancel/Retry/Forget, firmware update-required and unverified-version guidance. Bluetooth-ready accessibility value must not equal “Camera ready”; USB readiness, Bluetooth and wireless import are named separately.
- [ ] **2. Write import UI tests** for format labels (RAW+JPEG, RAW, JPEG only, Checking files, RAW unavailable), progressive browsing, selection counts, byte estimate, explicit Import RAW only, immutable active selection, progress, saved-unverified access guidance, retained bytes, Resume/Discard, Retry/Skip/Cancel, View imported and USB exclusion. Add X-E3 guided same-network registration/camera-start flow, with unavailable feasibility state having no misleading active import control.
- [ ] **3. Run** `Scripts/test-ios.sh FujiStudioUITests/WirelessConnectionTests FujiStudioUITests/CameraImportTests`, expected missing-controls/behavior failures against deterministic fixtures.
- [ ] **4. Implement native SwiftUI screens.** Use “Pair camera”, “Connect over WiFi”, “Browse camera photos”, “Disconnect WiFi”, “Change camera”, “Forget camera”, “Set up RAW transfer”, “Import N photos”, “Resume remaining”, “Discard remaining” and “View imported”. One pair counts as one photo. Clearly distinguish permission denial, network association, PTP readiness, RAW limitation and firmware guidance. No thumbnail enters the main tray before a verified import.
- [ ] **5. Validate portrait, both landscape orientations and accessibility text sizes** in fixture UI tests; provide per-control VoiceOver labels/progress, keep Cancel and recovery actions reachable, and preserve all existing status/settings actions. OS permission/join dialogs remain physical acceptance, not mocked UI proof.
- [ ] **6. Run** `Scripts/test-ios.sh FujiStudioUITests/WirelessConnectionTests FujiStudioUITests/CameraImportTests FujiStudioUITests/StatusSettingsTests FujiStudioUITests/CameraConnectionTests FujiStudioUITests/WorkspaceAccessibilityTests FujiStudioUITests/WorkspaceOrientationTests` and `Scripts/test-ios.sh --fast`, expected all pass.
- [ ] **7. Checkpoint:** `feat: expose camera connection and original import in status`.

## Task 14: Complete regression and physical acceptance

**Files:** Update `docs/validation/wireless-import-acceptance.md`, protocol fixtures with sanitized provenance manifests, and this plan's completed checkboxes. Fix code/tests only for observed failures, then re-run affected verification.

**Interfaces:** The deliverable is the integrated app plus reproducible evidence for each target firmware/mode. Do not turn pending hardware checks into passing automated tests or claim the two-camera feature complete while X-E3 RAW remains unproved.

- [ ] **1. Run** `swift test --package-path Packages/FujiCameraCore` and the complete `Scripts/test-ios.sh` on the task simulator. Expected: all package, app unit and UI tests pass; retain xcresult paths and exact revision. A fast-only pass is insufficient.
- [ ] **2. Recheck current official firmware** and reconcile the bundled support table with it. If a new release appeared, validate that version before release; old firmware hardware tests cannot substitute. Replay rejection tests for old, higher/unvalidated and unreadable versions without installing/downgrading camera firmware.
- [ ] **3. Build the signed Release** with `xcodegen generate` and the repository's `xcodebuild` command, development team `AZH3P824F3`, `CODE_SIGN_IDENTITY='Apple Development'`, task-owned derived data and actual connected phone UDID. Run `codesign --verify --deep --strict`, inspect Hotspot/multicast grants, install that exact bundle, then launch `com.lun3x.FujiStudio` normally without fixture/probe arguments.
- [ ] **4. Verify real connection behavior** for both targets: first pairing, remembered reconnect after camera power cycle, selected-camera-only reconnect with both nearby, denied/revoked Bluetooth and Local Network permission, native join accept/refuse, inactivity while prompt is open, connection loss, background and clean WiFi teardown. Confirm no automatic WiFi rejoin/transfer resume and no camera-ready USB claim from wireless state.
- [ ] **5. Import at least 20 mixed captures per supported transfer path where available.** Include same-card pairs, X-T5 split cards, RAW-only, repeated filenames, missing mates, supported compressed/uncompressed RAF, disabled JPEG/HEIF/movie and large originals. Verify each imported Photos asset contains the expected roles and independently hash every resource against card originals. Record exact source acquisition and results; do not treat staged-to-Photos equality alone as proof of original-size transfer.
- [ ] **6. Exercise destructive-to-the-process recovery, not destructive media operations:** terminate during first/second file, between pair validation and save, during Photos submission and after save before receipt; cancel/background/relaunch; test limited/full/denied Photos access and storage exhaustion. Confirm explicit resume, no silent pair downgrade or duplicate save, no accidental camera/card changes, no deletion of existing Photos, and safe USB handoff including unresolved cleanup.
- [ ] **7. Record outcome per gate**, including X-E3 registration/marker behavior, signed entitlement evidence, protocol identity limitations and unresolved failures. If a required gate is blocked, report it and continue only independent work; release completion remains pending until passed or the user explicitly changes scope.
- [ ] **8. Review the integrated diff against the spec and run the selected execution method's final review.** Address findings and rerun checks affected by fixes. Shut down/delete the task simulator; retain journals/media that protect unresolved real imports. Checkpoint: `test: validate latest-firmware wireless original import` only when evidence supports that claim.

## Plan self-review and handoff

Coverage: firmware/evidence (1, 5, 6, 14); Bluetooth/credentials/lifecycle (2, 3, 5, 12); WiFi/PTP/AutoSave (4–6); pairing/browser/formats (7, 13); USB cleanup (8); original validation/storage/metadata (9); creation/readback/reconciliation (10, 11); progress/recovery/library refresh (11–13); accessibility and signed-device acceptance (13, 14). All five Review Focus cases have explicit owning tests. Every task has a testable deliverable and a pushed checkpoint; protocol and physical gates distinguish unknowns from supported behavior.

Execution is not started by writing this plan. Review it, then choose subagent-driven task implementation/review or native execution with final independent review. Subagent-driven execution is recommended here because protocol parsing, native lifecycle and Photos recovery have separate failure modes, and an import error could create duplicate or incorrectly paired library assets.
