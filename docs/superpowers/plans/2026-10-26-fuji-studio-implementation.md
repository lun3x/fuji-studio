# Fuji Studio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved iPhone app for previewing and batch exporting existing standalone RAF and RAW+JPEG Photos assets through the connected X-T5 using its C1–C7 recipes.

**Architecture:** A native SwiftUI workspace uses UIKit for the zoom viewer and vertically scrolling selection grid. PhotoKit, an ImageCaptureCore camera adapter, and a SwiftData catalog sit behind value-based service contracts; one coordinator serializes complete camera operations and another journals export/save recovery. A custom in-app drawer overlays a persistent viewer, preserving its framing as the drawer expands.

**Tech Stack:** Swift 6 language mode; Xcode 27 SDK family; iOS 27+; SwiftUI, UIKit, PhotoKit, ImageCaptureCore, Core Image RAW, SwiftData, CryptoKit; Swift Testing and XCTest UI tests; XcodeGen for the project; Jujutsu for version control.

**Spec:** [Approved product and technical specification](../specs/2026-10-26-fuji-studio-design.md), including the linked interactive prototype.

## Global Constraints

- Initial hardware: Fujifilm X-T5 and iPhone 15 Pro connected over USB-C; record actual camera firmware and phone OS before hardware testing.
- Native iOS 27+ baseline. No older-OS compatibility paths; no assumption that the phone already runs this OS.
- Read existing C1–C7 recipes, including names. Never edit/create recipes or write saved banks.
- Original standalone RAF and paired RAW+JPEG Photos assets are conversion inputs; pairs remain one source. No reimport or separation.
- Previews create zero Photos assets. Explicit exports create independent, full-size FINE JPEGs preserving recorded geometry, effective Photos capture date, available location, orientation, and camera metadata.
- Full-size uncropped 3:2 X-T5 reference output: **7728 × 5152**. Validate other recorded aspects rather than assuming that size for every source.
- No Select mode means the viewed source is the effective selection. Export also requires a selected recipe, a ready camera, and no active export.
- Square thumbnails, vertical scrolling, two complete collapsed rows, unchanged geometry across Select modes. Photo taps never collapse the drawer.
- Zoom from fit through 8× fit; double-tap fit/2×. Preserve inspection region for matching versions of one source; reset on source change.
- Foreground USB processing, sequential camera operations, immutable submitted jobs, durable uncertain-save reconciliation, one active original/conversion payload.
- No phone-filter substitute, wireless transport, app server, catalog sync, older-export guessing, or recipe editor.
- Use `jj` for every version-control operation. Use the project `.venv` for any Python tooling.

## Review Focus

1. RAW may be primary or alternate, resources may arrive in any order, and adjusted JPEGs may coexist: choose original RAF and original JPEG by role and type. Test in Task 1.
2. Limited access may narrow during download/save, or an output may become inaccessible after a crash: retain history and reconcile before retrying; inaccessible is not proof of absence. Test in Tasks 5 and 12.
3. An actor can reenter during `await`, and a disconnected session can deliver late callbacks: keep whole conversion transactions exclusive and never delete unrelated card objects. Test in Tasks 2 and 3.
4. C3 can keep its name while settings change, or a user can choose an original while a render is pending: preserve job/version snapshots and reject stale display replacement. Test in Tasks 6–8.
5. A long grid can be rotated, resized for larger text, or interrupted mid-sweep: retain selection/anchors, avoid overlapping rows, preserve viewer framing, and keep the viewed tile visible after manual collapse. Test in Tasks 10 and 11.

---

## Execution order and checkpoints

This is one integrated app, not several independently shippable projects. Complete Tasks 1–3 and their hardware gates before building the full workspace. Task 5 proves the Photos save/association contract before relying on it in a batch engine. If a hardware gate fails, investigate and record the actual limitation; do not mark the gate passed or replace its requirement with a simulation.

As inspected on 26 October 2026, this Mac has Xcode **27.1 (27A9275)** and Swift **6.4**. XcodeGen is not installed. The available iOS 27.1 simulator is **iPhone Duo**, ID `5277B203-F40D-4AEF-98E9-164D7C653887`; use it for simulator checks, and the physical iPhone 15 Pro for camera/Photos gates. Re-enumerate destinations if unavailable later.

At execution time, establish an isolated **Jujutsu workspace** if needed, preserving unrelated changes. Task completion means its checks pass and evidence is recorded. Each task ends with this checkpoint, replacing the message appropriately:

```sh
jj diff --stat
jj status
jj describe -m 'feat: resolve original Photos RAW resources'
jj new
```

Do not move/push `main` automatically at each checkpoint. Review the complete result before integration. Test fixtures and protocol research must contain no personal images, device serial numbers, or access tokens.

## File structure and ownership

Paths are relative to the repository root. Create files only in their owning task. Protocols and associated value types live with their feature rather than in a general utilities module.

| Task | Files to create or modify | Responsibility |
| --- | --- | --- |
| 1 | `project.yml`, `Config/Base.xcconfig`, `Scripts/test-ios.sh`, `FujiStudio/App/FujiStudioApp.swift`, `FujiStudio/Library/{PhotoSource,RawResourceSelector,PhotoLibraryReader,RAFMetadataReader}.swift`, `FujiStudio/Debug/HardwareProbeView.swift`, `.gitignore`, `README.md` | Build/test entry point and real original-resource retrieval. |
| 2 | `FujiStudio/Camera/{PTPTypes,PTPCodec,PTPTransport,ImageCaptureTransport,SerialCameraGate,CameraState}.swift` | Public transport, session state, packet validation, exclusive operations. |
| 3 | `FujiStudio/Camera/{XT5CameraService,XT5RecipeCodec,XT5ConversionCodec}.swift`, `FujiStudio/Recipes/RecipeSnapshot.swift`, `FujiStudio/Rendering/RenderTypes.swift`, `ThirdPartyNotices.md` when required | Validated C-bank reads and camera conversion. |
| 4 | `FujiStudio/Catalog/{CatalogModels,CatalogStoring,SwiftDataCatalog}.swift`, `FujiStudio/Export/ExportModels.swift` | Durable recipes, sources, versions, export journal. |
| 5 | `FujiStudio/Export/{PhotoLibraryWriting,PhotoLibraryWriter}.swift` | Independent Photos save and exact operation reconciliation. |
| 6 | `FujiStudio/Workspace/WorkspaceState.swift` | Pure navigation, recipe, selection, and drawer state transitions. |
| 7 | `FujiStudio/Rendering/{RawDisplayRenderer,OriginalResourcePool,FileRenderCache,CameraWorkScheduling,PreviewCoordinator}.swift` | Real RAW display, bounded files, coalesced previews, scheduling contract. |
| 8 | `FujiStudio/Export/ExportCoordinator.swift`, `FujiStudio/Rendering/CameraWorkScheduler.swift` | Durable batch processing, priority, cancellation/recovery. |
| 9 | `FujiStudio/Workspace/{VersionList,PhotoViewer,ZoomPhotoView}.swift` | Version comparison and useful zoom. |
| 10 | `FujiStudio/Workspace/{PhotoGrid,PhotoGridController,GridGeometry,RangeSelection}.swift`, `FujiStudio/Library/ThumbnailProvider.swift` | Virtualized square grid and range selection. |
| 11 | `FujiStudio/Workspace/{PhotoDrawer,DrawerGeometry,RecipeMenu,WorkspaceView}.swift` | Persistent overlay drawer and native Liquid Glass controls. |
| 12 | `FujiStudio/App/{AppEnvironment,AppModel}.swift`, `FujiStudio/Workspace/ExportProgressView.swift`, `FujiStudio/Debug/FixtureEnvironment.swift`, existing app entry point | Service composition, permissions, lifecycle, actionable states. |
| 13 | `docs/validation/acceptance.md`, existing README and validation records | Complete physical acceptance and performance evidence. |

Tests live in `FujiStudioTests/<Feature>/<Suite>.swift` and `FujiStudioUITests/<Suite>.swift`, with exact suite names below. Test-only doubles live in `FujiStudioTests/Support/` and are added when the corresponding protocol exists. Synthetic JPEGs and redacted protocol fixtures live in `Tests/Fixtures/`; real RAFs and private captures live only in ignored `Tests/Fixtures/Private/`. Tasks 1–5 maintain `docs/validation/device-gates.md`; Tasks 2–3 maintain `docs/validation/protocol-provenance.md`.

## Shared value conventions

Use `SourceID = String` for a Photos local identifier. Internal recipe, job, version, and operation IDs are UUIDs. Service boundaries pass `Sendable` value records, file URLs, and typed errors; never pass a `PHAsset`, SwiftData model, `UIImage`, or entire batch of RAW bytes between actors.

- `ResourceToken`: owning Photos asset ID, resource role, content-type identifier, format, original filename, and a stable resource discriminator. Role is primary original, alternate original, or adjusted; format is RAF, JPEG, or other. The selector returns `OriginalResources(raf: ResourceToken, jpeg: ResourceToken?)`.
- `PhotoSource`: ID, original resources, effective Photos capture date, optional location, resource revision, and compatibility (`unknown`, `xt5`, or incompatible model). Discovery is metadata-only; validate camera model when the RAF is materialized.
- `PreparedRAW`: local file URL, SHA-256, source ID/revision, and verified `RAWMetadata` containing camera model, recorded geometry/aspect, and orientation. Keep container geometry distinct from recorded output crop.
- `RecipeSnapshot`: UUID, slot `1...7`, name, normalized conversion settings plus preserved imported representation, settings digest, camera model/identity/firmware context, and import time. Hash conversion settings deterministically; names/import times are not look settings. Every successful refresh creates new snapshot IDs.
- `CameraJPEG`: file URL, source ID, rendering-provenance recipe snapshot ID, source/settings hashes, camera context, geometry, and quality (`fullResolutionFine`). `OutputPolicy.fullSizeFineRecordedGeometry` is the initial policy. Reusing identical cached pixels does not change a new job's chosen recipe snapshot/label; saved-version labels come from that job, not the old cache entry.
- `RenderKey`: source ID/revision/hash, recipe settings digest, camera context, output geometry/policy, and quality. A slot number alone is never a key.
- `VersionID`: `.raw`, `.cameraJPEG`, `.saved(UUID)`, `.preview(RenderKey)`. `SavedVersion` includes source/output IDs, recipe snapshot, operation UUID, actual export time, geometry, and availability.
- `ExportJob`: immutable ordered source snapshots and recipe snapshot, plus mutable job/item states. Item states distinguish queued, preparing, converting, pending save, saved, failed, cancelled/unprocessed, and unresolved. A pending save carries its operation UUID, exact filename, optional placeholder ID, and pinned local JPEG.

Errors distinguish per-source preparation/unsupported settings, transport/session failure, authorization/inaccessibility, insufficient storage, and unresolved save. The owner task defines associated data and readable copy; later tasks must not collapse these into one generic failure.

## Task 1: Retrieve the actual RAF from existing Photos pairs

**Files:** Task 1 row above; test `FujiStudioTests/Library/RawResourceSelectorTests.swift`; create `docs/validation/device-gates.md`.

**Interfaces:** Produce `RawResourceSelector.select(_ resources: [ResourceToken]) throws -> OriginalResources`; `PhotoLibraryReading.requestAccess() async -> LibraryAccess`, `sources() async -> AsyncThrowingStream<[PhotoSource], Error>`, `allEligibleSources() async throws -> [PhotoSource]`, `source(id: SourceID) async throws -> PhotoSource`, `resources(assetID: String) async throws -> [ResourceToken]`, `changes() async -> AsyncStream<LibraryChange>`, `materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalResource`; `RAFMetadataReader.prepare(_ resource: LocalResource) throws -> PreparedRAW`. `allEligibleSources()` completes metadata discovery across the authorized library before returning; no RAW downloads. Resource inspection/materialization also supports JPEG-only exported IDs for version viewing; only source discovery filters for original RAFs. `LocalResource` holds the token, file URL, and checksum. `LibraryChange` supplies changed/removed IDs and access-scope changes. Declare the reading protocol in `PhotoLibraryReader.swift`.

- [ ] **1. Establish the runnable test target.** Create the minimal SwiftUI app, unit/UI test targets, and shared `FujiStudio` scheme using [XcodeGen's project spec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md). Install XcodeGen with `brew install xcodegen` at execution time and record its version. Set deployment `27.0`, Swift language mode `6`, bundle ID `com.lun3x.FujiStudio`, display name `Fuji Studio`. Use an optional ignored `Config/Signing.local.xcconfig` for the development team. Add exact Photos read/write and external-camera usage descriptions. Ignore generated `FujiStudio.xcodeproj/`, private fixtures, signing config, and test output. `Scripts/test-ios.sh [Target/Suite]` generates the project and runs `xcodebuild test` with `-only-testing:` when supplied, `.build/DerivedData`, `.build/TestResults`, and `FUJI_STUDIO_DESTINATION` overriding the inspected simulator ID. Use unsigned simulator builds; physical builds use local signing. No runtime package dependencies initially.
- [ ] **2. Write selector tests.** Construct typed resource fixtures using real resource-role values mapped at the adapter boundary. Pin these assertions in the named suite:

```swift
@Test func originalChoiceIsIndependentOfOrderAndPrimaryRole() throws {
    // Repeat for primary RAF + alternate JPEG and primary JPEG + alternate RAF.
    // Include an adjusted JPEG and reverse each input array.
    #expect(try RawResourceSelector.select(resources).raf == originalRAF)
    #expect(try RawResourceSelector.select(resources).jpeg == originalJPEG)
}
@Test func jpegOnlyAndDNGAreNotRAF() {
    #expect(throws: ResourceError.noOriginalRAF) {
        try RawResourceSelector.select(jpegAndDNGResources)
    }
}
```

  Define those fixture values locally in the tests; also assert standalone RAF yields `jpeg == nil`, and adjusted resources cannot replace originals.
- [ ] **3. Confirm the red test.** Run `Scripts/test-ios.sh FujiStudioTests/RawResourceSelectorTests`; expect a compile failure for the absent selector, not a provisioning or destination failure.
- [ ] **4. Implement original-resource access.** Use PhotoKit resource roles/content types, with actual RAF metadata verification before conversion; do not use a picker display image. Discover incrementally in capture-date descending/ID order, without downloading all originals. Materialize a chosen resource to a cancellable temporary file with iCloud progress, checksum, and cleanup on failure; resource absence/network failure never changes a pair into JPEG-only. `RAFMetadataReader.prepare` rejects other models for X-T5 conversion without depending on Core Image decode support. The DEBUG hardware probe lists descriptors and inspects one chosen asset; it is not production import UI.
- [ ] **5. Run the suite to green.** Run the Step 3 command; expect all selector tests to pass. Confirm the app launches in the simulator without requesting camera access until that workflow is invoked.
- [ ] **6. Pass hardware Gate 1.** On iPhone 15 Pro, retrieve and inspect both original resources of an SD-imported pair plus a standalone RAF under full and limited access. Verify actual RAF file identity and X-T5 metadata; test a cloud-evicted item/download cancellation. Record phone OS, firmware, resource roles/types/sizes and outcomes in `device-gates.md`, without personal files. If the phone cannot run the approved baseline, report this concrete dependency before wider implementation.
- [ ] **7. Checkpoint with `jj`.** Message: `feat: resolve original Photos RAW resources`.

## Task 2: Establish an exclusive public PTP transport

**Files:** Task 2 row; tests `FujiStudioTests/Camera/{PTPCodecTests,SerialCameraGateTests}.swift`; `docs/validation/protocol-provenance.md`.

**Interfaces:** Consume no vendor codec yet. Produce `PTPTransport.execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply`; `SerialCameraGate.withExclusiveAccess<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T`; `ImageCaptureTransport.connect() async throws`, `disconnect() async`, and `states() async -> AsyncStream<CameraState>`. Commands/replies carry opcode, parameters, transaction ID, response code, and bounded data. Camera state covers disconnected, discovering, authorization required/denied, opening, wrong mode, ready, busy, recoverable error; session identity has a generation.

- [ ] **1. Write transport and exclusivity tests.** Use a controllable fake transport with continuations, not wall-clock sleeps:

```swift
@Test func operationStaysExclusiveAcrossSuspension() async throws {
    // Suspend A between upload and convert; enqueue B; then release A.
    #expect(recordedSteps == ["A.upload", "A.convert", "A.download", "B.upload"])
}
@Test func disconnectedGenerationRejectsLateReply() async {
    #expect(acceptedRepliesFromOldSession == 0)
}
```

  In `PTPCodecTests`, assert truncated/oversized containers, bad response codes, wrong transaction IDs, and timeouts produce typed failures, never image success. In the gate suite, assert cancellation of a queued waiter does not release an active operation's lock.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/PTPCodecTests` and `Scripts/test-ios.sh FujiStudioTests/SerialCameraGateTests`; expect missing-type/signature failures.
- [ ] **3. Implement the transport and gate.** Wrap ImageCaptureCore discovery/control authorization/session APIs and [public PTP passthrough](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:)). Validate response identity and enforce timeout/size limits before parsing. The gate holds an explicit asynchronous permit for an entire operation; actor isolation alone is insufficient across awaits. Invalidate old-session callbacks on disconnect. Never add a libusb dependency or a destructive camera reset fallback.
- [ ] **4. Confirm green.** Run both Step 2 commands; expect passes with deterministic event ordering and no leaked continuations.
- [ ] **5. Verify the real session prerequisite.** Extend the DEBUG probe to discover/open the X-T5 in `USB RAW CONV./BACKUP RESTORE`, and distinguish unplugged, authorization denied, and wrong-mode cases. Record a sanitized trace, OS permissions, firmware, reference commit SHAs/licenses, and session lifecycle in validation docs. No saved setting writes or card-object deletions.
- [ ] **6. Checkpoint with `jj`.** Message: `feat: add serialized ImageCaptureCore PTP transport`.

## Task 3: Read all seven recipes and prove full-resolution conversion

**Files:** Task 3 row; extend the hardware probe; tests `FujiStudioTests/Camera/{XT5RecipeCodecTests,XT5ConversionTests}.swift`; sanitized protocol fixtures.

**Interfaces:** Consume Task 1 `PreparedRAW`, Task 2 `PTPTransport`/exclusive gate. Produce `CameraServing.states() async -> AsyncStream<CameraState>`, `connect() async throws`, `importRecipes() async throws -> [RecipeSnapshot]`, `render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws -> CameraJPEG`, `disconnect() async`. Define this protocol in `XT5CameraService.swift`, with `XT5CameraService` implementing it. Recipes/render value records follow the shared conventions.

- [ ] **1. Write codec/transaction tests using redacted observed fixtures.** Record the supported X-T5 fields and offsets before treating a mapping as established:

```swift
@Test func readsExactlySevenNamedBanksWithoutSavedBankWrites() async throws {
    #expect(recipes.map(\.slot) == Array(1...7))
    #expect(savedBankWriteCommands.count == 0)
    #expect(decodedNamesAndSettings == fixtureExpectedNamesAndSettings)
}
@Test func conversionDeletesOnlyOwnedTemporaryObjects() async throws {
    #expect(deletedHandles.isSubset(of: createdTemporaryHandles))
    #expect(deletedHandles.isDisjoint(with: preexistingCardHandles))
}
```

  Add assertions for unknown film/settings values returning unsupported rather than approximated looks, malformed profile lengths, stale object handles/session generations, and cleanup after partial conversion failure.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/XT5RecipeCodecTests` and `Scripts/test-ios.sh FujiStudioTests/XT5ConversionTests`; expect missing codec/service failures.
- [ ] **3. Implement only the validated X-T5 conversion path.** Inspect and pin [libfuji's USB conversion code](https://github.com/petabyt/libfuji/blob/master/lib/fuji_usb.c) and [profile parser](https://github.com/petabyt/libfuji/tree/master/fp) as references. Port the necessary protocol logic through Task 2, retaining required license notices. Document which encodings are confirmed on X-T5; do not copy another model's C-bank addresses unverified. Read all seven named banks; preserve unknown representation and reject unsupported conversion settings. Serialize the entire upload/baseline/settings/convert/download/owned-cleanup operation. Output policy controls format/size/recorded crop independently from recipe look settings. Validate returned JPEG dimensions/type/context before publishing its file.
- [ ] **4. Confirm green.** Run Step 2 commands; expect the validated fixture traces and ownership assertions to pass.
- [ ] **5. Pass hardware Gates 2–4.** Snapshot C1–C7 before/after; read names/settings with no persistent changes. Convert the same RAF using two deliberately distinct imported recipes through the iPhone, compare with X RAW Studio on the same camera/firmware/settings, and inspect full-resolution output. Prove 7728 × 5152 for a 3:2 original, plus actual recorded aspect/orientation and RAW compression modes in the user's library. Record unsupported settings honestly, baseline ordering, transfer/render times, and provenance. Grain/noise need not be byte-identical; explain the comparison used. Do not proceed to the broad UI until public transport, all seven imports, and real full-size output are demonstrated.
- [ ] **6. Checkpoint with `jj`.** Message: `feat: read X-T5 recipes and render full-size camera JPEGs`.

## Task 4: Persist recipe snapshots, version identity, and export journals

**Files:** Task 4 row; tests `FujiStudioTests/Catalog/CatalogTests.swift`.

**Interfaces:** Consume `PhotoSource`, `RecipeSnapshot`, `CameraJPEG`. Produce `CatalogStoring.upsertSources(_ sources: [PhotoSource]) async throws`, `replaceRecipes(_ snapshots: [RecipeSnapshot]) async throws`, `recipes(camera: CameraContext) async throws -> [RecipeSnapshot]`, `versions(sourceID: SourceID) async throws -> [SavedVersion]`, `saveJob(_ job: ExportJob) async throws`, `job(id: UUID) async throws -> ExportJob`, `unfinishedJobs() async throws -> [ExportJob]`, `confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) async throws`, `setAvailability(assetID: String, availability: AssetAvailability) async throws`. `confirmSaved` atomically records the version and marks the item saved. Define journal/snapshot DTOs in `ExportModels.swift`, persistence models privately in `CatalogModels.swift`.

- [ ] **1. Write disk-reopen and atomicity tests.** Use a temporary on-disk store, close/reopen it, and pin:

```swift
@Test func restartPreservesDistinctSourcesWithEqualCaptureDates() async throws {
    #expect(reopenedVersionsForA.map(\.sourceID) == ["A"])
    #expect(reopenedVersionsForB.isEmpty)
    #expect(reopenedJob.items.first?.operationID == originalOperationID)
}
@Test func partialRecipeRefreshCannotReplaceCollection() async throws {
    #expect(visibleRecipes.count == 7)
    #expect(visibleRecipes.map(\.id) == previousSnapshotIDs)
}
```

  Also assert `confirmSaved` is idempotent for one operation ID, two deliberate export operation IDs create two versions, and an inaccessible asset retains its durable record. Successful refresh replaces all seven atomically with new IDs while old job/version snapshots remain readable.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/CatalogTests`; expect absent store/record failures.
- [ ] **3. Implement `SwiftDataCatalog`.** Use a dedicated model actor; cross its boundary with DTOs only. Store snapshots independently of a mutable slot pointer, retain imported representation, and validate exactly seven unique slots before collection replacement. Make each journal write durable before acknowledging it. Keep source association by IDs, never inferred timestamps/filenames. Missing/inaccessible records are marked, not used to delete Photos assets. Use one initial schema; do not add speculative migration/compatibility code.
- [ ] **4. Confirm green.** Run Step 2; expect all tests to pass against actual reopened stores rather than only in-memory mocks.
- [ ] **5. Checkpoint with `jj`.** Message: `feat: persist immutable recipes and export journals`.

## Task 5: Save independent Photos assets and reconcile uncertain saves

**Files:** Task 5 row; tests `FujiStudioTests/Export/PhotoLibraryWriterTests.swift`; extend probe and `device-gates.md`.

**Interfaces:** Consume `CameraJPEG`, source date/location, and operation UUID. Produce `PhotoLibraryWriting.saveJPEG(_ request: PhotoSaveRequest, onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset`, `findExport(operationID: UUID, knownAssetID: String?) async throws -> SaveLookup`. `PhotoSaveRequest` holds the pinned camera file, operation ID, source date/location; its exact resource filename is `FujiStudio-<operationUUID>.jpg`. `SavedAsset` holds Photos ID, operation ID, and geometry. `SaveLookup` is `.found(SavedAsset)`, `.notFound`, or `.inaccessible`.

- [ ] **1. Write writer/reconciliation tests with a fake Photos gateway.** Keep the gateway behind the adapter so tests inspect change requests and save callbacks:

```swift
@Test func savesCameraBytesAsNewAssetWithSourceDate() async throws {
    #expect(createdAssetCount == 1)
    #expect(originalMutationCount == 0)
    #expect(savedCaptureDate == sourceCaptureDate)
    #expect(savedResourceSHA256 == cameraJPEGSHA256)
}
@Test func limitedAccessCannotProveAnUncertainSaveAbsent() async throws {
    #expect(lookup == .inaccessible)
    #expect(replacementSaveCount == 0)
}
```

  Assert source location is retained, absent date/location leaves system defaults without inventing source values, exact UUID filename finds the correct output when dates collide, placeholder callback precedes confirmed completion, and a failed save is never returned as saved.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/PhotoLibraryWriterTests`; expect missing writer/gateway failures.
- [ ] **3. Implement direct resource creation/reconciliation.** Use PhotoKit asset/resource creation from the JPEG file with `shouldMoveFile = false`; the engine owns file lifetime. Set capture date/location on the new asset and preserve camera bytes. Search known ID first, then the exact operation filename under authorized access; the filename identifies a save operation, not a guessed source relationship. Limited scope or revoked access yields inaccessible when absence cannot be established. Do not rewrite EXIF timestamps or promise Photos' equal-time adjacency.
- [ ] **4. Confirm green.** Run Step 2; expect all assertions to pass, including metadata and unchanged bytes.
- [ ] **5. Pass hardware Gate 5.** Save a camera result as a new photo next to its source in capture-date chronology; inspect original pair unchanged, output dimensions/orientation/location/date, Recently Added, and visible Versions association after catalog reopen. Exercise full/limited authorization and a pending save with a recorded operation filename. Document the system's tie ordering without claiming app control of it.
- [ ] **6. Checkpoint with `jj`.** Message: `feat: save Photos versions with exact recovery identity`.

## Task 6: Model browsing, recipes, and effective selection

**Files:** `FujiStudio/Workspace/WorkspaceState.swift`; test `FujiStudioTests/Workspace/WorkspaceStateTests.swift`.

**Interfaces:** Consume source IDs, seven recipe snapshots, `VersionID`, and camera/job readiness. Produce value `WorkspaceState` with `viewedSourceID`, `displayedVersion`, `selectedRecipe`, `isSelecting`, `checkedSourceIDs`, `drawerDetent`, `effectiveSourceIDs`, and `canExport`. `mutating func reduce(_ action: WorkspaceAction) -> [WorkspaceEffect]` processes source tap, select/done/all/none, version/recipe selection, atomic recipe refresh, source/access changes, drawer movement, and preview completion. Effects request previews or scroll-to-visible; reducer does no I/O. All receives the full accessible eligible source ID set from the library index, not visible cells.

- [ ] **1. Write state-transition tests.** Pin the approved distinctions:

```swift
@Test func browseExportsViewedPhotoWithoutEnteringSelect() {
    #expect(state.effectiveSourceIDs == ["viewed"])
    #expect(state.canExport == true) // Recipe + ready camera + no active job.
}
@Test func tappingPhotoNeverCollapsesExpandedDrawer() {
    #expect(state.drawerDetent == .expanded) // Repeat in both selection modes.
    #expect(effects.contains(.requestPreview(sourceID: "next", recipeID: c3.id)))
}
@Test func refreshedC3ChangesFutureTargetNotOldSnapshot() {
    #expect(state.selectedRecipe?.id == refreshedC3.id)
    #expect(submittedJob.recipe.id == originalC3.id)
}
```

  Cover Select seeds viewed item; None empties checked set/disables export; Done restores viewed singleton; All includes offscreen IDs and enters Select; no source/no recipe/disconnect/active job disables Export; manual version selection retains recipe; clearing recipe chooses paired JPEG or RAW. A same-name/different-settings refresh requests a new preview; failed refresh preserves seven previous slots with stale state.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/WorkspaceStateTests`; expect missing reducer failures.
- [ ] **3. Implement the pure reducer and export predicate.** Make state changes explicit and keep drawer detent independent from photo/recipe/selection. Incompatible sources may be viewed but cannot be submitted; show a reason rather than feeding them to the X-T5. Readiness for an unchecked source must not disable an otherwise valid selection. Use stable capture-date/ID ordering when freezing effective IDs. Library removals drop invalid checked/viewed references while preserving unrelated selections.
- [ ] **4. Confirm green.** Run Step 2; expect all transitions to pass without camera/Photos UI dependencies.
- [ ] **5. Checkpoint with `jj`.** Message: `feat: model workspace navigation and effective selection`.

## Task 7: Render true RAW displays and coalesce temporary previews

**Files:** Task 7 row; tests `FujiStudioTests/Rendering/{FileRenderCacheTests,PreviewCoordinatorTests}.swift`.

**Interfaces:** Consume Task 1 reader, Task 3 camera, Task 6 effects. Produce `RawDisplayRenderer.render(_ raw: PreparedRAW) async throws -> URL`; `OriginalResourcePool.withPreparedRAW<T: Sendable>(source: PhotoSource, operation: @Sendable (PreparedRAW) async throws -> T) async throws -> T`; `FileRenderCache.lookup(_ key: RenderKey) async -> CameraJPEG?`, `store(_ jpeg: CameraJPEG, key: RenderKey) async throws`, `pin(_ key: RenderKey) async throws -> URL`, `unpin(_ key: RenderKey) async`, `invalidate(sourceID: SourceID) async`; `PreviewCoordinator.request(source: PhotoSource, recipe: RecipeSnapshot?) async`, `selectStoredVersion(_ version: VersionID) async`, `events() async -> AsyncStream<PreviewEvent>`. Pin returns the durable file URL used by a pending-save journal. `PreviewEvent` carries generation, source/version identity, loading/progress/error or ready file; the main actor accepts only its current display generation.

Define `CameraWorkScheduling` here with `withPreview(_ operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG`, `withExportItem(jobID: UUID, operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG`, `beginExport(jobID: UUID) async throws`, and `endExport(jobID: UUID) async`. Inject a deterministic fake in this task's tests; Task 8 supplies the production implementation. Admission wraps preparation **and** render, rather than queueing an already-materialized RAF. All original RAW access, including local RAW display, uses the shared resource pool.

- [ ] **1. Write bounded-cache and stale-result tests.** Use controlled completion order:

```swift
@Test func latePreviewCannotReplaceManualOriginal() async throws {
    #expect(displayedVersion == .cameraJPEG)
    #expect(photoLibrarySaveCount == 0)
}
@Test func renamedOrRefreshedSlotDoesNotReuseWrongSettings() async throws {
    #expect(oldSettingsKey != refreshedSettingsKey)
    #expect(sameSettingsRenamedKey == oldSettingsKey)
}
```

  Assert latest source/recipe wins; late valid result may populate only its own cache; source hash/revision, firmware, crop, quality invalidate keys; a lower-size result is rejected for export. With a 100-byte injected test budget, oldest unpinned entry is evicted, pinned pending-save output survives, and partial files never appear as hits. RAW decode failure yields RAW-display unavailable while RAF/camera conversion stays available. Suspend one pool lease and request another: assert only one RAF materialization begins until the first closes, including local RAW display during a batch.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/FileRenderCacheTests` and `Scripts/test-ios.sh FujiStudioTests/PreviewCoordinatorTests`; expect absent cache/coordinator failures.
- [ ] **3. Implement temporary rendering/cache.** Decode RAF through `CIRAWFilter`; never label an embedded/paired JPEG as RAW. Use file-backed, downsampled display images and decode more detail for zoom on demand. Set production cache budget to **1 GiB** of unpinned JPEG entries, at most one active materialized RAF, and one current full-detail display decode; make limits injectable. The resource pool explicitly leases preparation/use across awaits and removes the RAW when the closure ends; waiting requests do not download first. Pin pending-save JPEGs in Application Support with the journal, outside purgeable cache; remove abandoned partial resources. Coalesce preview requests to latest generation, retaining a correctly labelled available version on failure. Reuse only a validated exact full-resolution cache result for export.
- [ ] **4. Confirm green.** Run Step 2; expect deterministic stale-generation, zero-save, and eviction assertions to pass. Probe a real RAF's display separately from its camera conversion; report local decoder unavailability without hiding the source.
- [ ] **5. Checkpoint with `jj`.** Message: `feat: add RAW display and generation-safe camera previews`.

## Task 8: Run recoverable immutable batch exports

**Files:** Task 8 row; tests `FujiStudioTests/Export/ExportCoordinatorTests.swift`, `FujiStudioTests/Rendering/CameraWorkSchedulerTests.swift`.

**Interfaces:** Consume `PhotoLibraryReading`, `CameraServing`, `CatalogStoring`, `PhotoLibraryWriting`, `FileRenderCache`, `OriginalResourcePool`, and Task 7's `CameraWorkScheduling`. Produce `ExportCoordinator.start(sources: [PhotoSource], recipe: RecipeSnapshot) async throws -> UUID`, `cancel(jobID: UUID) async`, `resume(jobID: UUID) async throws`, `retry(jobID: UUID) async throws`, `recover() async throws`, `events() async -> AsyncStream<ExportEvent>`. `ExportEvent` includes job ID, frozen recipe label, current stage/item, completed/failed/skipped/unprocessed counts, pause/unresolved state, and terminal summary. `CameraWorkScheduler` implements `CameraWorkScheduling`: it drains the current preview before export admission, prioritizes that job's item closures, and retains only the latest deferred preview. Closures call `CameraServing.render` directly, never recursively acquire scheduler admission; recipe imports also wait for the underlying exclusive camera gate.

- [ ] **1. Write journal/crash-window tests.** Use fakes recording method order and simulated relaunch with the actual Task 4 disk store:

```swift
@Test func mixedBatchUsesSubmittedRecipeAfterUIRefresh() async throws {
    #expect(renderedSourceIDs == ["paired", "standalone"])
    #expect(renderedRecipeIDs == [originalC3.id, originalC3.id])
    #expect(maxConcurrentRAWPreparations == 1)
}
@Test func crashAfterPhotosSaveBeforeConfirmationDoesNotDuplicate() async throws {
    #expect(saveCallCountAcrossRelaunch == 1)
    #expect(recoveredSavedVersions.count == 1)
}
```

  Test crashes before save submission, after placeholder, after Photos success, and after catalog confirmation; unresolved lookup never starts another save. Assert cancellation finishes/reconciles active save and starts no next item; retry excludes saved items; a bad RAF continues to next while disconnect pauses. A submitted job pins its recipe/source revision even if C3 refreshes; changed source resources produce an explicit item error, never silently different input. Export from same-settings/renamed-recipe cache uses the submitted recipe's new label. Scheduler tests assert one camera operation, export priority, only latest deferred preview, and busy status does not accidentally reject the scheduler's own exports.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/ExportCoordinatorTests` and `Scripts/test-ios.sh FujiStudioTests/CameraWorkSchedulerTests`; expect missing engine/scheduler failures.
- [ ] **3. Implement the sequential journaled engine.** Validate submission, durably freeze sources/recipe, admit an item before obtaining its RAW lease, reuse exact full-size cached output or request camera render, then persist `pendingSave` with pinned file/operation filename **before** calling PhotoKit. Persist a placeholder as soon as available; after success use `confirmSaved`. On recovery, reconcile pending states by ID/exact filename; saved is terminal, inaccessible stays unresolved, definitive absence permits an explicit resume/retry. A first empty lookup alone does not prove a previously submitted system transaction absent; keep ambiguous submission unresolved and recheck on library changes rather than automatically resaving. Cancel sets a stop flag, not cancellation of an unclassifiable Photos transaction. End export priority in all terminal/pause paths, releasing only files no longer needed for recovery. Deliberate new exports receive fresh operation IDs.
- [ ] **4. Confirm green.** Run Step 2; expect all simulated crash positions and queue traces to pass. Use events to prove UI browsing can continue while camera work is queued; no full-size batch preloading.
- [ ] **5. Exercise hardware Gate 6's engine portion.** Run a mixed batch; disconnect during upload/conversion, cancel during save, reconnect with changed C3, and relaunch. Reconcile before resuming and record completed/failed/unresolved outcomes and actual Photos asset counts. Do not claim exactly-once save from mock tests alone.
- [ ] **6. Checkpoint with `jj`.** Message: `feat: add immutable recoverable batch exports`.

## Task 9: Compare versions with a pinch-zoom viewer

**Files:** Task 9 row; tests `FujiStudioTests/Workspace/VersionListTests.swift`, `FujiStudioUITests/PhotoViewerTests.swift`.

**Interfaces:** Consume Task 6 state/actions and Task 7 file events; query `CatalogStoring.versions(sourceID:)`. Produce `VersionList(source: PhotoSource, saved: [SavedVersion], preview: CameraJPEG?)`, `PhotoViewer(sourceID: SourceID, version: VersionID, imageURL: URL?, geometry: ImageGeometry?, onVersionSelected: (VersionID) -> Void)`, and `ZoomPhotoView` wrapping a `UIScrollView`. Expose accessibility identifiers `viewer.image`, `version.raw`, `version.cameraJPEG`, `version.saved.<UUID>`, and `version.preview`.

- [ ] **1. Write version/zoom tests.** `VersionListTests` pins RAW/paired JPEG/own saved outputs/temporary preview only; two same-recipe exports have distinct labels including export time. `PhotoViewerTests` uses generated detailed image fixtures and pins:

```swift
func testZoomPersistsAcrossMatchingVersionsAndResetsForNewSource() {
    // Pinch around a landmark, switch same-source/same-geometry version.
    XCTAssertEqual(zoomAfterVersionSwitch, zoomBeforeSwitch, accuracy: 0.01)
    XCTAssertEqual(normalizedCenterAfterSwitch, normalizedCenterBeforeSwitch)
    XCTAssertEqual(zoomAfterSourceChange, 1.0, accuracy: 0.01)
}
```

  Measure normalized center/zoom through a DEBUG-only accessibility value; test fit/2× double-tap, maximum 8× fit, pan clamping/orientation, absent RAW display, and manual version resisting late preview. Add a minimal DEBUG viewer fixture entry point now; Task 12 will consolidate fixture composition.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/VersionListTests` and `Scripts/test-ios.sh FujiStudioUITests/PhotoViewerTests`; expect absent view/test fixture failures.
- [ ] **3. Implement the file-backed viewer.** Keep zoom state by source and matching geometry, using normalized inspected region rather than pixel offsets across orientation changes. Resolve saved JPEGs through the library reader's `resources(assetID:)`/`materialize` methods, including iCloud progress. Versions select stored content without reapplying the selected recipe; Export target remains state-owned. Provide accessible version labels, RAW-unavailable state, and high-detail loading without decoding every saved version. No pinch implementation on a low-resolution thumbnail.
- [ ] **4. Confirm green.** Run Step 2; expect version identities and zoom assertions to pass. Visually inspect a real full-resolution camera JPEG at zoom on the phone.
- [ ] **5. Checkpoint with `jj`.** Message: `feat: compare photo versions with focal-point zoom`.

## Task 10: Browse a stable square grid and sweep-select ranges

**Files:** Task 10 row; tests `FujiStudioTests/Workspace/{GridGeometryTests,RangeSelectionTests}.swift`, `FujiStudioUITests/PhotoGridTests.swift`.

**Interfaces:** Consume Task 6 actions/state and incremental library records. Produce `GridGeometry.metrics(width: CGFloat, preferredTile: CGFloat, spacing: CGFloat, insets: UIEdgeInsets) -> GridMetrics` with square tile size/columns/content rows; `RangeSelection.begin(index: Int, checked: Set<SourceID>, orderedIDs: [SourceID])`, `update(index: Int) -> Set<SourceID>`, `cancel() -> Set<SourceID>`; `PhotoGrid` takes stable source IDs, checked set, selection mode, viewed ID, and action callbacks. `ThumbnailProvider` adapts `PHCachingImageManager` to visible/prefetch cells, cancels reuse requests, and never supplies conversion input.

- [ ] **1. Write geometry/range tests.** Use 1,000 synthetic sources, a fixed width in both modes, and edge scrolling:

```swift
@Test func selectionDoesNotChangeSquareGridGeometry() {
    #expect(browseMetrics == selectMetrics)
    #expect(browseMetrics.tileWidth == browseMetrics.tileHeight)
    #expect(zip(rowRects, rowRects.dropFirst()).allSatisfy { $0.0.maxY <= $0.1.minY })
}
@Test func cancelledSweepRestoresStartingSelection() {
    #expect(selectionAfterCancellation == startingSelection)
}
```

  Assert checked-start sweep removes, unchecked-start adds, reversing the endpoint recalculates from starting selection, and edge scrolling extends beyond initially visible cells. `PhotoGridTests` checks vertical scroll in both modes, unchanged first tile size/scroll anchor after Select, accessible toggle alternatives, and All selecting all 1,000 eligible IDs, including offscreen.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/GridGeometryTests`, `Scripts/test-ios.sh FujiStudioTests/RangeSelectionTests`, and `Scripts/test-ios.sh FujiStudioUITests/PhotoGridTests`; expect absent grid/range components.
- [ ] **3. Implement the virtualized grid.** Use a UIKit collection view/diffable data source with fixed square geometry derived from available width. Select adds checkboxes/checkmarks only. Default vertical swipe scrolls; deliberate horizontal sweep begins range selection, then can cross rows with top/bottom autoscroll. Snapshot starting selection and add/remove mode for stable reversal/cancel behavior. Drawer dragging starts only at its header/grabber. Preserve source-ID anchors as metadata batches arrive or authorization narrows. Incompatible RAF tiles remain identifiable and explain why conversion is unavailable.
- [ ] **4. Confirm green.** Run Step 2; expect non-overlapping rows and selection assertions to pass. Inspect a long library at both detents and verify thumbnail requests are bounded to visible/prefetch ranges.
- [ ] **5. Checkpoint with `jj`.** Message: `feat: add vertical square photo grid and sweep selection`.

## Task 11: Compose the expanding drawer and floating recipe menu

**Files:** Task 11 row; tests `FujiStudioTests/Workspace/DrawerGeometryTests.swift`, `FujiStudioUITests/WorkspaceLayoutTests.swift`.

**Interfaces:** Consume `PhotoViewer`, `PhotoGrid`, `WorkspaceState.reduce`. Produce `DrawerGeometry.detents(container: CGSize, safeArea: EdgeInsets, headerHeight: CGFloat, grid: GridMetrics, recipeControlFrame: CGRect) -> DrawerDetents`; `PhotoDrawer` with bound detent, resize progress, and grid/header content; `RecipeMenu` with current snapshot, seven cached snapshots/stale status, select/clear/refresh callbacks. `WorkspaceView` owns a persistent viewer frame with fixed collapsed-drawer reservation and overlays expanded drawer content. Grid scroll-to-visible is an explicit callback after manual collapse.

- [ ] **1. Write detent and integration tests.** Pin measured values instead of prototype pixels:

```swift
@Test func collapsedViewportContainsExactlyTwoCompleteRows() {
    #expect(gridViewportHeight == 2 * tileHeight + rowGap + verticalPadding)
    #expect(expandedTop >= recipeControlFrame.maxY + requiredClearance)
}
func testExpandedPhotoTapKeepsDrawerAndUnderlyingFraming() {
    XCTAssertEqual(drawerDetentAfterPhotoTap, "expanded")
    XCTAssertEqual(viewerFrameBeforeExpansion, viewerFrameAfterExpansion)
    XCTAssertTrue(recipeControl.isHittable)
}
```

  Repeat photo taps in Select and browse modes; assert manual collapse fully reveals viewed tile and retains checked IDs. Test rotation/larger text preserves a sensible anchor, no toolbar overlap, equal grid geometry in both modes, grabber tap/accessible actions, and active sweep cancellation during relayout. The recipe trigger/menu tests cover No recipe, C3 label/checkmark, scrollable seven slots, import/refresh, outside/Escape dismissal without changing selection, and no reserved sidebar width.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/DrawerGeometryTests` and `Scripts/test-ios.sh FujiStudioUITests/WorkspaceLayoutTests`; expect absent drawer/workspace integration.
- [ ] **3. Implement measured detents and native appearance.** Measure toolbar/text/safe areas; compute collapsed drawer from exactly two grid rows and expanded drawer below the usable recipe trigger, covering most of the photo. Expansion overlays content and never reframes the viewer; detent changes never follow a photo tap. Snap with native motion respecting Reduce Motion. Use Apple's [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and system semantic colors/materials for functional chrome; keep image content untreated. Provide solid/legible accessibility fallbacks, meaningful labels/counts, and accessible alternatives for gestures. Keep Select/Done, All, None, Export usable when text wraps; no hardcoded mockup dimensions.
- [ ] **4. Confirm green.** Run Step 2. Inspect portrait/landscape, light/dark, largest supported accessibility text, Increase Contrast, Reduce Transparency, Reduce Motion, and VoiceOver focus. Record any device/simulator limits rather than asserting unseen settings passed.
- [ ] **5. Checkpoint with `jj`.** Message: `feat: compose Liquid Glass workspace and expandable photo drawer`.

## Task 12: Connect services, permissions, progress, and lifecycle recovery

**Files:** Task 12 row; tests `FujiStudioTests/App/AppModelTests.swift`, `FujiStudioUITests/AppFlowTests.swift`; consolidate DEBUG fixtures.

**Interfaces:** Consume all completed service contracts. Produce `@MainActor AppModel` owning workspace state plus `send(_ action: WorkspaceAction)`, `start() async`, `sceneChanged(_ phase: ScenePhase) async`, and `refreshRecipes() async`. `AppEnvironment.live()` composes real adapters/catalog/scheduler; `FixtureEnvironment` supplies deterministic services only under `#if DEBUG` and launch argument `--ui-fixtures`. `ExportProgressView` renders `ExportEvent` with cancel/resume/retry actions. No production simulated camera fallback.

- [ ] **1. Write lifecycle/access-flow tests.** `AppModelTests` pins foreground processing and scope changes:

```swift
@Test func scopeNarrowingDuringPreparationPreservesCompletedOutputs() async throws {
    #expect(visibleSourceIDs.isSubset(of: authorizedIDs))
    #expect(completedOutputDeleteCalls == 0)
    #expect(interruptedItemWasReportedSaved == false)
}
@Test func backgroundingPausesAndRestoresIdleTimer() async throws {
    #expect(newCameraOperationsAfterPause == 0)
    #expect(isIdleTimerDisabled == false)
    #expect(resumeRequiresFreshSessionAndReconciliation == true)
}
```

  Also test ready-connect imports seven slots once per session generation (busy/ready transitions do not form a refresh loop), atomic refresh/error retention, cached offline browsing, deleted output hidden/marked unavailable, deleted source invalidated without deleting exports, permission denial/manage-limited-access action, wrong mode guidance, iCloud/storage errors, and idle timer restored on every export exit. `AppFlowTests` drives paired photo → C3 temporary preview → single export → persisted version, then mixed multi-select export while changing UI recipe and manual version.
- [ ] **2. Confirm red.** Run `Scripts/test-ios.sh FujiStudioTests/AppModelTests` and `Scripts/test-ios.sh FujiStudioUITests/AppFlowTests`; expect missing composition/lifecycle behavior.
- [ ] **3. Implement composition and actionable states.** Subscribe once to library/camera/preview/export streams and route accepted generations on the main actor. All awaits `allEligibleSources()` with a loading indication before reducing the complete ID set; it never means only the currently loaded page. Hook Export to effective eligible selection and frozen snapshot; disable with a clear reason for no recipe, empty selection, incompatible source, disconnected camera, or active job. Show per-stage progress, frozen batch recipe, summary counts, cancellation/resume/retry. Backgrounding requests safe pause within available execution time, invalidates session as required, and foreground return reopens/reconciles before resuming. Keep screen awake only during active foreground export, restoring prior idle behavior afterward. Use system Photos access-management UI, accurate camera permission copy, USB mode/data-cable guidance, and errors retaining available versions.
- [ ] **4. Confirm green.** Run Step 2; expect real service composition and fake-backed flow tests to pass. Ensure Release builds exclude fixture/probe launch paths and private fixtures.
- [ ] **5. Finish hardware Gate 6.** Background/suspend/return and disconnect/reconnect during actual conversion and Photos save. Reopen the app to the same saved versions, classify active item before resume, and record asset counts/progress/recovery results in `device-gates.md`. Confirm no background/locked-screen completion guarantee appears in product UI.
- [ ] **6. Checkpoint with `jj`.** Message: `feat: integrate permissions progress and interruption recovery`.

## Task 13: Validate the complete app on the target hardware

**Files:** Create `docs/validation/acceptance.md`; update validation docs and README. No new product features.

**Interfaces:** Consume all prior tests, hardware evidence, and spec checks A01–A24; produce a reproducible acceptance record with pass/fail/not-run, hardware/software context, measurements, and any remaining limitations. A screenshot or simulator fixture cannot substitute for a camera gate.

- [ ] **1. Run the complete simulator suite.** Run `Scripts/test-ios.sh`; expect every unit and UI suite to pass. Build Release for simulator with `xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`; expect `BUILD SUCCEEDED`. Investigate failures in their owner task; rerun affected suites after fixes, then this complete gate once.
- [ ] **2. Execute the physical acceptance matrix below.** Use the actual SD-imported pair/standalone corpus, all relevant compression/aspect cases, two distinct C recipes, and a long gallery. Confirm original resource checksums and saved C-bank settings before/after, full output geometry, original dates, output counts, and saved-version identity after relaunch. Record failures/not-run explicitly; do not declare native functionality verified from the prototype.
- [ ] **3. Measure bounded operation.** With Instruments on iPhone 15 Pro, record peak resident memory, one-item RAW temporary size, JPEG cache size, first/cached preview latency, per-stage export times, and scrolling behavior during a mixed batch of at least **50** sources. Assert at most one original materialization/conversion payload and one camera transaction concurrently; no RAW-sized memory growth proportional to selection count. Numeric latency/memory thresholds are not product promises yet: report actual values and investigate stalls, crashes, or cumulative growth.
- [ ] **4. Record delivery state.** Update README with Xcode/XcodeGen setup, `.xcconfig` signing instructions, test commands, camera mode, foreground requirement, supported firmware/settings evidence, and hardware limitations. Mark gates passed only with the recorded physical observations; list unresolved gates as blockers to claiming a working app.
- [ ] **5. Checkpoint with `jj`.** Message: `docs: record Fuji Studio device acceptance and performance`. Obtain whole-branch review through the chosen execution workflow before integration; integrate/push using `jj`, retaining the private repository.

## Acceptance traceability

| Spec check | Implementation owner | Required proof |
| --- | --- | --- |
| A01–A02 | 1, 8 | Real paired RAF retrieval + mixed batch; reordered primary/alternate unit fixtures. |
| A03 | 3, 4, 6, 12 | All seven slots accurate, atomic refresh, before/after camera values unchanged. |
| A04 | 6, 7, 12 | Original default/clear, Export disabled without recipe, zero saves for previews. |
| A05 | 6–7, 9 | Controlled late renders/navigation/manual version and settings refresh. |
| A06–A07 | 4–5, 9, 12 | Version identity/labels, equal-date distinct sources, real relaunch/reconnect. |
| A08 | 6, 12 | Viewed-source single export without Select. |
| A09–A10 | 6, 10–11 | Select/Done/All/None, long-library sweeps, unchanged geometry. |
| A11–A13 | 10–11 | Square non-overlapping vertical rows, two-row collapsed measurement, overlay framing, no automatic collapse, visible viewed tile. |
| A14 | 7, 9 | Actual image detail, pinch/pan/region preservation/reset on device. |
| A15 | 11–12 | Floating slot menu, no recipe, seven names, dismissal/accessibility. |
| A16–A17 | 3, 7–8 | Real original RAF/full-size recipe result, frozen mixed job, exact cache eligibility. |
| A18–A19 | 5, 8 | New PhotoKit assets, source unchanged, original date/location, Photos chronological position. |
| A20 | 4–5, 8 | Journal/crash-window tests plus real uncertain-save reconciliation/cancel/retry. |
| A21–A22 | 1–3, 8, 12 | Physical failure states, suspension/disconnect, no false completion. |
| A23 | 9–12 | Both orientations, accessibility settings and actions, usable non-overlapping controls. |
| A24 | 7–8, 10, 13 | Bounded cache/payload/concurrency, zero preview saves, long gallery and measured physical batch. |

## Plan review and handoff

Planning self-review checked every spec section, interface ownership/signatures, all five Review Focus cases, and A01–A24 against these tasks. Local documentation links, task order, and acceptance traceability were verified. Hardware gates remain unrun; no app code, native build, or device capability is claimed by this planning work.

Recommended execution: **subagent-driven**, with a fresh implementer and reviewer per task, because the camera protocol, Photos resource identity, and crash-recovery contracts merit independent checks before later UI work depends on them. The alternative is **native inline execution**, with one final independent branch review, using less review overhead. The user chooses after reviewing this plan; neither workflow can substitute for access to the physical camera/phone at the marked gates.
