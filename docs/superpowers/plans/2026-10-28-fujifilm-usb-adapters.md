# Fujifilm USB Camera Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship X-E3 USB recipe import, editing and camera conversion through a shared Fujifilm service that also preserves the X-T5's measured support.

**Architecture:** Keep `CameraServing` as the application boundary. Extract a local Swift package containing the service, semantic recipe domain, explicit adapter registry and model codecs; native ImageCaptureCore drivers stay outside it. The laptop runner and iPhone import that same package, with model-specific capabilities driving admission and editor controls.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation/CryptoKit/ImageIO, ImageCaptureCore, SwiftUI, SwiftData, Swift Testing/XCTest, XcodeGen; existing Python comparison tools use the project's `.venv`.

**Spec:** [Approved design](../specs/2026-10-28-fujifilm-usb-adapters-design.md). Protocol evidence: [X-E3 investigation](../../validation/xe3-laptop-protocol.md). Read both before execution.

## Global Constraints

- Scope: additional **Fujifilm cameras over USB**; one connected camera active at a time.
- Initial adapters: X-T5 firmware 4.31 / observed FF179502 625-byte profile, and X-E3 firmware 1.30 / observed FF129505 601-byte profile.
- The measured X-E3 trigger-0 preview remains a later optimization; this release uses trigger 1 and full-size FINE for preview and export.
- No Wi-Fi/Bluetooth, other brands, downloadable plugins, camera shooting/live view, persistent camera-bank editing, cross-model RAF conversion, automatic cross-model recipe translation or new RAW-decoder dependency.
- The core has no UIKit, SwiftUI, PhotoKit or ImageCaptureCore lifecycle dependencies.
- Always patch a fresh per-source baseline and require exact profile readback before triggering once.
- Never replay a trigger or deletion or resume an export automatically.
- Partial imports must never replace a complete collection. The first two adapters still declare C1–C7.
- Unknown models/firmware receive a clear unsupported result. Do not infer support from a processor identifier alone.
- Reject known requested/effective setting mismatches before preview publication or saved-version creation. Required JPEG metadata and independently verified protocol evidence are distinct validation sources.
- Kelvin choices on X-E3 begin at 5000/6300/7100 only; reject 5310. Other shared-WB table positions remain unvalidated until independently measured.
- Never delete/reset the user's catalog or camera journals to make the refactor pass. Preserve frozen IDs/digests, asset associations and uncertainty; do not maintain historical API/compatibility layers.
- Always use Jujutsu. Before implementation fetch origin and create a fresh workspace under `/tmp/` from this plan bookmark; do not edit another task's workspace. Push every implementation checkpoint on `codex/fujifilm-usb-adapters`.
- Use a new task simulator; shut down/delete that simulator when execution finishes. Use focused tests or `Scripts/test-ios.sh --fast` for iterations, affected UI suites for UI work, and the complete suite for final validation.
- Hardware evidence stays separate from simulator results. A missing physical-camera or iPhone gate is outstanding work, not a pass.

## Review Focus

1. An X-E3 import deliberately reopens USB while delayed READY/DISCONNECTED callbacks arrive: adopt exactly its final verified context without recursive imports or stale work (Tasks 7, 9).
2. A phone library contains recipes from both models, including an unsupported native value: preserve it through offline edits and disable only incompatible execution (Tasks 2, 8, 9).
3. A JPEG is well-formed and owned but disagrees with the requested settings: reject publication, clean up only with the normal ownership proofs, and never replay deletion (Tasks 3, 6).
4. The process dies during forward conversion of stored catalog/journal data: retain history and delete-intent markers, and perform no camera or Photos action on recovery (Task 2).
5. A compressed X-E3 RAF cannot be decoded locally but is valid for camera conversion: report RAW-view unavailability without poisoning conversion admission or substituting its embedded JPEG (Tasks 4, 9, 10).

## File map and execution order

App, Tools and project paths below are relative to the execution workspace. Core source paths beginning `Core/`, `PTP/`, `Transport/`, `Recipes/`, `Sources/`, `Rendering/`, `Adapters/`, `Service/` or `JPEG/` are shorthand under `Packages/FujiCameraCore/Sources/FujiCameraCore/`; core test names are under `Packages/FujiCameraCore/Tests/FujiCameraCoreTests/`. Moving a declaration includes updating its imports and tests in the same checkpoint; do not leave duplicate types or aliases to the former app module.

| Area | Destination / existing files | Responsibility |
| --- | --- | --- |
| Core module | `Packages/FujiCameraCore/Package.swift`, `Sources/FujiCameraCore/` | One library product; iOS 27/macOS 27, Swift 6, no new dependencies. |
| Protocol values | `Core/CameraServing.swift`, `Core/CameraState.swift`, `Core/CameraSessionTransport.swift`, `PTP/PTPTypes.swift`, `PTP/PTPCodec.swift`, `PTP/PTPDatasets.swift` | Value-only transport/service contracts and bounded standard PTP grammar. |
| Native-independent transport | `Transport/SessionCommandTransport.swift`, `Transport/CameraSessionDriver.swift` | Existing generation/correlation/deadline state machine; injected driver, no default native driver. |
| Recipe/source domain | `Recipes/RecipeSnapshot.swift`, `Recipes/RecipeSettings.swift`, `Recipes/RecipeCapabilities.swift`, `Recipes/RecipeCodecRegistry.swift`, `Sources/RAWTypes.swift`, `Sources/RAFMetadataReader.swift`, `Rendering/RenderTypes.swift` | Semantic runtime values, passive native snapshots, source parsing and render provenance. |
| Adapters | `Adapters/FujiCameraAdapter.swift`, `Adapters/FujiCameraRegistry.swift`, `Adapters/XT5/`, `Adapters/XE3/` | Explicit model verification, import policy, assessment/encoding and conversion/output rules. |
| Service | `Service/FujiCameraService.swift`, `Service/CameraOperationIO.swift`, `Service/SerialCameraGate.swift`, `Service/CameraOperationJournal.swift`, `Service/CameraJournalStorage.swift` | Single operation owner, scoped importer access, durable intents, ownership and uncertainty. |
| JPEG evidence | `JPEG/FujiJPEGMetadataReader.swift`, `JPEG/CameraOutputAssessment.swift` | Strict bounded JPEG parser and qualified maker-note observations with evidence provenance. |
| iOS boundary | `FujiStudio/Camera/ImageCaptureTransport.swift`, `FujiStudio/Camera/CameraJournalFilePolicy.swift`, `FujiStudio/App/AppEnvironment.swift` | Native discovery/authorization/callback driver and protected storage policy; construct shared service. |
| Persistence | `FujiStudio/Catalog/{CatalogStoring,CatalogModels,SwiftDataCatalog,CatalogPayloadUpgrade}.swift`, `FujiStudio/Export/ExportModels.swift` | Complete collections, current-format data conversion, immutable phone/history records. |
| App behavior | `FujiStudio/Recipes/PhoneRecipe{Draft,Setting,Grain,Editor}.swift`, `FujiStudio/Workspace/{WorkspaceState,RecipeMenu,WorkspaceView,CameraStatusControl,RecipeSlotBadge}.swift`, `FujiStudio/App/AppModel.swift` | Capability-driven editing, model-aware selection/status and import receipt adoption. |
| Rendering | `FujiStudio/Rendering/{OriginalResourcePool,PreviewCoordinator,CameraWorkScheduler,FileRenderCache,RawDisplayRenderer}.swift`, `FujiStudio/Export/ExportCoordinator.swift` | Correct model/source/cache admission; honest local RAW failure and frozen exports. |
| Laptop | `Tools/FujiCameraLaptop/Package.swift`, `Sources/FujiCameraLaptop/{main,MacImageCaptureDriver,LaptopJournalFilePolicy,EvidenceWriter}.swift` | Executable using the core through a local package dependency. |
| Tests / fixtures | `Packages/FujiCameraCore/Tests/FujiCameraCoreTests/`, existing `FujiStudioTests/`, `FujiStudioUITests/`, `Tests/Fixtures/Protocol/` | Pure core and shared-service tests on Mac, app integration/UI on iOS, public sanitized evidence. |

Existing app paths supplying core declarations: `FujiStudio/Camera/{CameraServing,CameraState,PTPTypes,PTPCodec,PTPTransport,CameraSessionTransport,SerialCameraGate,CameraOperationJournal,XT5ProductionCameraService,XT5RecipeCodec,XT5WorkingProfile,XT5ConversionCodec,FujiJPEGMetadataReader}.swift`; source structs/checksum from `FujiStudio/Library/{PhotoSource,RAFMetadataReader}.swift`; recipe/render structs from their current files. Keep Photos resource/discovery/catalog-only values in the app. Split debug probes/importer currently colocated in `XT5CameraService.swift`; production must not depend on app debug runners.

**Sequence:** Tasks 1–3 establish the shared X-T5 path; Tasks 4–7 add the X-E3 contracts/codecs/import; Tasks 8–9 complete catalog/UI integration; Tasks 10–11 prove the shared implementation on hardware and finish delivery. Execute sequentially because the tasks share interfaces.

**Checkpoint procedure:** After each task's verification, run `jj diff --summary`, describe the checkpoint, move/push the development bookmark, then start a new change:

```sh
jj describe -m '<task checkpoint message>'
jj bookmark set codex/fujifilm-usb-adapters -r @
jj git push --remote origin --bookmark codex/fujifilm-usb-adapters
jj new
```

Do not use Git commands. Resolve genuinely new upstream overlap through Jujutsu before final integration; preserve unrelated task changes.

---

### Task 1: Extract a Mac-testable core without changing the X-T5 wire path

**Files:** Create the package, Core/PTP/Transport/Service files in the map and `Tests/FujiCameraCoreTests/{PTPCodecTests,SessionCommandTransportTests,CameraOperationJournalTests}.swift`; modify `project.yml`, `FujiStudio/Camera/ImageCaptureTransport.swift`, app/test imports and existing driver tests.

**Interfaces:**
- Consumes existing `CameraSessionDriver`, `CameraTimeoutScheduling`, `PTPTransport`, `CameraSessionTransport`, `CameraState`, `CameraExecutionContext` and current value DTOs.
- Produces public `FujiCameraCore` declarations, `@MainActor SessionCommandTransport: CameraSessionTransport`, initialized with `driver: any CameraSessionDriver`, and the existing `execute(_:data:)`, `connect()`, `currentSession()`, `close()` contracts.
- Produces `CameraJournalFilePolicy: Sendable` with `createDirectory(at: URL) throws` and `write(_: Data, to: URL, exclusive: Bool) throws`; shared journal owns names, markers, synchronization and state, injected policy owns platform directory/write attributes. `CameraOperationJournal.init(directory: URL, filePolicy: any CameraJournalFilePolicy) throws` requires an explicit policy; the app supplies `IOSCameraJournalFilePolicy`.

- [x] **Step 1: Capture baseline and extraction regressions.** Create an isolated simulator using installed device/runtime IDs from `xcrun simctl list devices available` and `xcrun simctl list runtimes`; record its UDID and export `FUJI_STUDIO_DESTINATION="platform=iOS Simulator,id=$FUJI_SIMULATOR_ID"`. Run `Scripts/test-ios.sh --fast`. Port the existing protocol/driver/journal assertions to package tests, including late callbacks after close and exclusive delete-intent markers; make them import the new module before it exists.
- [x] **Step 2: Verify the new boundary fails.** Run `swift test --package-path Packages/FujiCameraCore`; expect missing package/module before extraction. Existing baseline failures, if any, must be recorded and understood before changing behavior.

  Name the extraction regressions `lateReplyCannotCompleteNewGeneration` (`#expect(newReply.logicalTransactionID == newCommand.transactionID)`) and `deleteIntentSurvivesJournalReopen` (`#expect(throws: CameraServiceError.self) { try reopened.beginDelete(&record) }` after the first intent).
- [x] **Step 3: Move code and wire the package.** Add `packages.FujiCameraCore.path: Packages/FujiCameraCore` and a package dependency to both app and unit-test targets in `project.yml`. Separate the transport state machine from `ImageCaptureSessionDriver`; keep its native implementation in the app. Move the minimum dependency closure of current recipe/source/render DTOs without redesigning their serialized fields yet. Keep the concrete X-T5 service's behavior during this extraction. Retain file synchronization and one-shot marker rules while injecting file policy; iOS uses complete file protection, Mac tests use a private directory.
- [x] **Step 4: Verify both platforms.** Run `swift test --package-path Packages/FujiCameraCore` and `Scripts/test-ios.sh --fast`; expect all package and existing app unit tests to pass. Confirm core sources do not import UIKit, SwiftUI, Photos, SwiftData or ImageCaptureCore with `rg -n '^import (UIKit|SwiftUI|Photos|SwiftData|ImageCaptureCore)' Packages/FujiCameraCore/Sources` (no matches).
- [x] **Step 5: Checkpoint.** Commit/push `refactor: extract shared Fujifilm camera core` using the procedure above.

### Task 2: Introduce semantic recipes and preserve current durable records

**Files:** Create `Recipes/{RecipeSettings,RecipeCapabilities,RecipeCodecRegistry}.swift`, `FujiStudio/Catalog/CatalogPayloadUpgrade.swift`, core `RecipeDomainTests.swift`, app `CatalogPayloadUpgradeTests.swift`, `FujiStudioTests/Fixtures/Persistence/current-xt5.json`; modify core snapshots/render types, XT5 codecs, catalog storage and export DTO bindings.

**Interfaces:**
- Consumes Task 1 value types and current X-T5 native snapshots.
- Produces string-identity `FilmSimulation` (15 measured simulations), `WhiteBalanceMode` (auto, temperature and measured presets), `GrainSettings(strength: GrainStrength, size: GrainSize?)`, `RecipeSettings` with signed tone values in tenths, grid WB shifts, optional Kelvin/effects and semantic NR.
- `RecipeSettings` fields are `film: FilmSimulation`, `grain: GrainSettings`, `dynamicRange: Int`, `whiteBalance: WhiteBalanceMode`, `whiteBalanceRed: Int`, `whiteBalanceBlue: Int`, `kelvin: Int?`, `highlightTenths: Int`, `shadowTenths: Int`, `colorTenths: Int`, `sharpnessTenths: Int`, `noiseReduction: Int`, `colorChrome: EffectStrength?`, `colorChromeBlue: EffectStrength?`, `clarityTenths: Int?`, `lensOptimizerRequested: Bool?`. Nil means unavailable or baseline-preserved, never an invented Off. Native dormant/unknown values remain in the snapshot payload.
- Produces `RecipeSettingID` semantic cases matching those editable fields and `RecipeSettingValue` cases `.film(FilmSimulation)`, `.whiteBalance(WhiteBalanceMode)`, `.grain(GrainSettings)`, `.effect(EffectStrength)`, `.integer(Int)`. A `SettingChoice` carries typed value and label; `SettingCapability` carries support state and editable/renderable choices or integer range/step.
- Produces `RecipeAssessment { settings: RecipeSettings?, issues: [RecipeRenderingIssue] }`; `RecipeCodecRegistry.assess(_ snapshot: RecipeSnapshot) -> RecipeAssessment` and `encodeEditedRecipe(_ settings: RecipeSettings, preserving snapshot: RecipeSnapshot) throws -> RecipeSnapshot`. Registry is a Sendable injected value, usable offline.
- `RecipeCodecRegistry.capabilities(for context: RecipeCameraContext) throws -> CameraCapabilities` resolves offline editor choices from stored provenance. Live UI uses service-verified capabilities rather than treating an unverified stored context as device admission.
- Produces `CameraCapabilities { bankSlots: [RecipeSlot], settings: [RecipeSettingID: SettingCapability], recipeImport: FeatureSupport, sourceConstraints: SourceConstraints }`; setting capabilities distinguish absent/unimplemented/supported and editable versus renderable values. `RecipeSlot.id` is an Int, `label` is a String; no universal count.
- Produces `EffectiveRecipeReport` carrying requested semantic settings and per-field `SettingEvidence` with `.jpegObserved` or `.profileConfirmed`, plus explicit mismatch diagnostics. Model-native bytes remain only in snapshots/adapters.
- Produces `CatalogPayloadUpgrade.runIfNeeded() throws` before catalog readers/workers run. It converts only the currently shipped payload format to the new current format; no old service API or multi-version decoder in normal execution.

- [x] **Step 1: Add exact domain/storage tests before changing DTOs.** Capture deterministic synthetic current-format JSON containing a source, phone membership, frozen recipe, completed version, unresolved Photos submission and camera journal with delete-intent marker. Assertions:
  ```swift
  #expect(xt5Assessment.settings?.film == .classicChrome)
  #expect(xt5Assessment.settings?.whiteBalanceRed == -4)
  #expect(xe3Grain.size == nil)
  #expect(renamed.settingsDigest == original.settingsDigest)
  #expect(upgraded.phoneID == before.phoneID && upgraded.snapshotID == before.snapshotID)
  #expect(upgraded.frozenDigests == before.frozenDigests)
  #expect(upgraded.assetIDs == before.assetIDs && upgraded.uncertainty == before.uncertainty)
  #expect(upgradeEffects.cameraCommands.isEmpty && upgradeEffects.photosWrites == 0)
  ```
  Add crash/retry tests at preparation and commit boundaries; malformed data leaves the original store readable and reports a durable error. Existing X-T5 digest canonicalization remains `xt5.imported-settings.v1`; do not recompute frozen identifiers.
- [x] **Step 2: Run the failing tests.** `swift test --package-path Packages/FujiCameraCore --filter RecipeDomainTests` and `Scripts/test-ios.sh FujiStudioTests/CatalogPayloadUpgradeTests`; expect missing semantic types/upgrade behavior.

  Name the storage cases `currentPayloadUpgradePreservesFrozenHistory`, `failedUpgradeLeavesOriginalReadable` and `interruptedUpgradeRetriesWithoutSideEffects`; the Step 1 assertions apply on every reopened copy.
- [x] **Step 3: Implement projections and bounded forward conversion.** Make `RecipeSnapshot` passive: remove its direct `XT5WorkingProfile.normalize` dependency and migrate callers to injected assessment. Preserve raw fields/name bytes and unknown values on edit. For unavoidable requested/effective/source-compatibility payload changes, decode/prepare/validate the whole affected catalog in memory, commit through one SwiftData transaction, and mark the format in that transaction. Keep a recovery copy until successful verification. Upgrade journal JSON by synchronized atomic replacement with per-record format detection; preserve binary artifacts and exclusive delete markers verbatim. Restarted conversion is idempotent and never starts work. Keep current X-T5 opaque tuple restrictions inside its codec.
- [x] **Step 4: Verify.** Run both commands from Step 2 and `Scripts/test-ios.sh --fast`; reopen copied stores and assert the IDs/digests/associations/uncertainty above. Test offline assessment and an edit that leaves an unknown native field byte-identical. No store-reset fallback is allowed.
- [x] **Step 5: Checkpoint.** Commit/push `refactor: model recipe settings independently of camera wire codes`.

### Task 3: Extract the shared operation owner and X-T5 adapter

**Files:** Create `Adapters/{FujiCameraAdapter,FujiCameraRegistry}.swift`, `Adapters/XT5/XT5Adapter.swift`, `Service/{FujiCameraService,CameraOperationIO}.swift`, `JPEG/CameraOutputAssessment.swift`, core `FujiCameraServiceTests.swift`, `XT5AdapterTests.swift`; move the verified X-T5 importer/codecs into `Adapters/XT5/`; replace production construction in `AppEnvironment.swift`.

**Interfaces:**
- Consumes Tasks 1–2 domain/transport/storage; produces `FujiCameraService: CameraServing` and a statically registered `FujiCameraRegistry`.
- `FujiCameraAdapter` exposes `id`, `conversionDialect`, `recipeImportSessionPolicy`; methods `verifyDevice(_: FujiDeviceInfo, io: CameraOperationIO) async throws -> VerifiedCameraSupport`, `importRecipes(io:support:) async throws -> DecodedRecipeCollection`, `decodeRecipe(_:) throws -> RecipeAssessment`, `encodeEditedRecipe(_:preserving:) throws -> RecipeSnapshot`, `prepareConversion(baseline:source:recipe:support:policy:) throws -> PreparedConversion`, `validateOutput(_:conversion:) throws -> CameraOutputAssessment`.
- `VerifiedCameraSupport` has actual model/firmware, optional camera-reported capability, application support version and `CameraCapabilities`; service alone supplies session UUID/generation. Preserve existing `CameraExecutionContext.capability` storage as a support identifier when a camera does not report one; mark its origin explicitly in verified support.
- Add `CameraServing.support(for context: CameraExecutionContext) async throws -> VerifiedCameraSupport`; the service validates the expected current context under its operation gate before returning live capabilities. This works even when optional recipe import is unavailable.
- `PreparedConversion` contains exact profile bytes/hashes, requested semantic settings, source metadata and output expectations. `FujiRAWConversionDialect` declares upload/profile/trigger operations and upload ObjectInfo construction, not an arbitrary executable command list.
- `CameraOperationIO` offers `readDeviceInfo()`, `readProperty(_:)`, `readPropertyDescriptor(_:)`, `readSettingsBackup()` and declared `withTemporaryBankSelection(_:body:)`; every method validates owner/session lifetime. No general write/delete/connect interface.
- `CameraOutputAssessment` contains independently validated JPEG identity/geometry/quality plus `.accepted(EffectiveRecipeReport)` or `.rejected(RecipeMismatchReport)`. Unsafe/unparseable outputs throw; service owns all file and deletion decisions.
- Define the shared import contracts here: `RecipeImportSessionPolicy` cases `.currentVerifiedSession` / `.freshBeforeAndAfter`, `DecodedRecipeCollection { recipes: [RecipeSnapshot], declaredSlots: [RecipeSlot] }`, and `ImportedRecipeCollection { recipes: [RecipeSnapshot], declaredSlots: [RecipeSlot], context: CameraExecutionContext, support: VerifiedCameraSupport }`. Change `CameraServing.importRecipes() async throws -> ImportedRecipeCollection` and all conformers directly. The X-T5 receipt uses its current verified context; actual reopen behavior arrives in Task 7. Existing app/catalog bindings can unwrap `receipt.recipes` until Tasks 8–9 consume the whole receipt. The declaration must agree with `support.capabilities.bankSlots`.

- [x] **Step 1: Port service regressions and add adapter contracts.** Run the existing production safety scenarios against `FujiCameraService` and fake adapters; assert exact upload → baseline → profile/readback → one trigger → owned download → at most one deletion. Add unknown model/firmware tests and borrowed-I/O expiry tests. For a well-formed owned JPEG with a requested/effective mismatch assert no returned `CameraJPEG`, one proven cleanup and no replay after restart; an unsafe output still gets no deletion.
- [x] **Step 2: Verify failure.** Run `swift test --package-path Packages/FujiCameraCore --filter FujiCameraServiceTests`; expect missing shared owner/adapter behavior.

  Name the new cases `expiredImportIOCannotSend`, `verifiedMismatchCleansOnceWithoutPublishing` and `unsafeOutputCannotAuthorizeDelete`. Assert `#expect(wire.deletes.count == 1 && publishedJPEGs.isEmpty)` only for the verified mismatch and `#expect(wire.deletes.isEmpty)` for unsafe output. Add `oldContextCannotReadLiveCapabilities`: `await #expect(throws: CameraServiceError.self) { try await service.support(for: retiredContext) }`.
- [x] **Step 3: Implement shared ownership and X-T5 routing.** Move the existing FIFO gate, admission epochs, monitor/correlation, mutation journal, reconciliation and exact-cleanup rules once. Keep X-T5 4.31 verification, required properties/capability strings and exact 625-byte baseline class. Share standard PTP dataset parsing under `FujiDeviceInfo`/`PTPDatasets` without broadening vendor mappings. Remove `XT5CameraService` as a production API and update debug entry points/test fakes directly. Register only X-T5 until X-E3 tasks pass.
- [x] **Step 4: Implement the approved output-admission rule.** Existing X-T5 tests allow requested LMO On to return Off with an adjustment flag; change that success fixture to report On and add a distinct rejection test. Metadata mismatch is a known semantic failure, not ownership failure: store its diagnostics, retain normal hash/ObjectInfo/StorageInfo proofs, perform exact cleanup, and return failure with no preview/version. A confirmed cleanup and close can terminate the journal as aborted; unconfirmed cleanup/close remains uncertain. Never treat an arbitrary validation error as permission to delete. Protocol-only evidence is labelled as such and cannot fabricate JPEG values.
- [x] **Step 5: Verify and checkpoint.** Run package tests and `Scripts/test-ios.sh --fast`; preserve X-T5 frame/domain/import and cancellation tests, including failure while journaling delete intent. Commit/push `refactor: route X-T5 through shared Fujifilm service`.

### Task 4: Parse model-neutral RAF metadata and admit the measured X-E3 sources

**Files:** Modify core `Sources/{RAWTypes,RAFMetadataReader}.swift`, create `Adapters/XE3/XE3SourceRules.swift`, core `RAFMetadataReaderTests.swift`, `XE3SourceRulesTests.swift`; modify app `Library/PhotoSource.swift`, `Rendering/OriginalResourcePool.swift` and resource-pool tests.

**Interfaces:**
- Consumes `RAWMetadata` and `SourceConstraints`; produces a structural `RAFMetadataReader.prepare(_ resource: LocalResource) throws -> PreparedRAW` that validates bytes independently of the active camera.
- Produces `SourceCompatibility.assess(_ metadata: RAWMetadata, for support: VerifiedCameraSupport) -> RAWCompatibility` with `.unknown`, `.supported(model: String)` and `.incompatible(model: String)`; known source model is retained independently of currently attached hardware.
- Each adapter implements source validation as part of `prepareConversion`; render admission requires recipe model, RAF model and connected model to agree.

- [x] **Step 1: Add bounded parser/admission tests.** Preserve signature/checksum, payload bounds, duplicate tag, embedded-model mismatch and geometry tests. Assert the two X-E3 source classes:
  ```swift
  #expect(compressed.containerGeometry == PixelSize(width: 6048, height: 4038))
  #expect(compressed.cropTop == 21 && compressed.cropLeft == 16)
  #expect(uncompressed.containerGeometry == PixelSize(width: 6160, height: 4032))
  #expect(uncompressed.cropTop == 16 && uncompressed.cropLeft == 16)
  #expect(compressed.recordedGeometry == PixelSize(width: 6000, height: 4000))
  #expect(acceptedOrientations == Set([1, 8]))
  ```
  Assert a valid X-E3 RAF is rejected before upload on X-T5; unknown geometry/orientation/compression classes are not inferred supported from model text. Record sufficient RAF encoding/source-class metadata to distinguish the measured classes, using actual files for any unestablished compression tag encoding.
- [x] **Step 2: Verify failure.** `swift test --package-path Packages/FujiCameraCore --filter XE3SourceRulesTests` and `Scripts/test-ios.sh FujiStudioTests/OriginalResourcePoolTests`; expect missing model-aware admission.

  Name the geometry cases `compressedXE3RecordedCropIsIndependentOfEmbeddedJPEG` and `uncompressedXE3UsesItsMeasuredContainer`; use Step 1's exact assertions. `sourceFromOtherModelNeverUploads` asserts `#expect(wire.uploads == 0)` after admission failure.
- [x] **Step 3: Implement structural parsing and adapter source rules.** Move the fixed X-T5 model check out of the parser. Preserve safe tag bounds/recorded crop; do not use embedded-JPEG dimensions as RAW geometry. Replace `.xt5` compatibility writes with the parsed supported model and update app fixtures/callers. Keep original-resource retrieval independent from local pixel decoding.
- [x] **Step 4: Verify and checkpoint.** Run the targeted tests, existing `RAFMetadataReaderTests` and `ResourceTransferTests`, then package tests. Verify all seven private samples structurally without publishing images. Commit/push `feat: admit measured X-E3 RAF source classes`.

### Task 5: Implement the X-E3 conversion-profile and settings codec

**Files:** Create `Adapters/XE3/{XE3Adapter,XE3WorkingProfile,XE3NativeRecipeFields}.swift`, core `XE3WorkingProfileTests.swift`, `XE3CapabilityTests.swift`; move the sanitized committed XE3 fixtures to `Packages/FujiCameraCore/Tests/FujiCameraCoreTests/Fixtures/XE3/1.30/`, configure `.copy("Fixtures")` test resources, add provenance in a README and update repository references to that single canonical location.

**Interfaces:**
- Consumes Task 3 adapter contracts and Task 4 source rules; produces `XE3WorkingProfile.make(baseline: Data, settings: RecipeSettings, source: RAWMetadata) throws -> PreparedConversion`.
- `XE3Adapter` verifies FUJIFILM/X-E3/1.30, required operations and an actual D16E read equal to `[6,0]`, even when that property is not advertised. It must not request X-T5 D186/D187/D18C–D1A4 capabilities.
- Model support identifier: `xe3-1.30-FF129505-v1`, marked application-defined. Conversion dialect uses 900C/900D/D185/D183, 82-byte F802 upload ObjectInfo and full-size trigger `[1,0]`.

- [x] **Step 1: Add table-driven fixture assertions.** Test 601 bytes, header `[23,0,8]`, UTF-16LE FF129505 at 3..<19, reserved bytes 19..<513, signed words and unknown-byte preservation. Assert offsets DR533/film541/grain545/WB-condition553/WB557/R561/B565/K569/high573/shadow577/colour581/sharp585/NR589. Assert all 15 films, grain1/2/3, DR100/200/400, whole-step tones, every measured WB mode and NR lookup `[-4:0x8000,-3:0x7000,-2:0x4000,-1:0x3000,0:0x2000,1:0x1000,2:0,3:0x6000,4:0x5000]`. Kelvin membership is exactly `[5000,6300,7100]`; 5310 throws before upload. Chrome/FX Blue/Clarity and grain size are absent on X-E3. X-T5's five-film/renderable grain domain stays unchanged.
- [x] **Step 2: Verify failure.** Run `swift test --package-path Packages/FujiCameraCore --filter XE3WorkingProfileTests`; expect absent X-E3 codec.

  Name cases `profilePatchesOnlyDeclaredWords`, `noiseReductionLookupCoversNineLevels`, `kelvin5310IsRejected` and `xe3DoesNotWidenXT5Domain`. Assertions include `#expect(candidate.count == 601)`, `#expect(untouchedCandidateBytes == untouchedBaselineBytes)` and `#expect(throws: CameraServiceError.unsupportedSettings) { try prepare(kelvin: 5310) }` using the test fixture's preparation helper.
- [x] **Step 3: Implement profile preparation.** Patch only model-declared settings in a fresh source baseline. Require known framing/source class; support all three measured baseline fixtures rather than hard-coding the first source's settings words. Preserve exposure529, opaque549, file/size/quality/wide-DR/colour-space and other unrequested words. Set explicit WB-condition553=2 for an explicit recipe. LMO validation expectations follow the actual prepared word593; it is not a new user-editable bank setting. Do not clamp DR to captured DR. Keep native field namespaces scoped to adapter identity and include all frozen WB dependencies in `xe3.imported-settings.v1` digest canonicalization.
- [x] **Step 4: Verify and checkpoint.** Run all package tests, including negative cross-model frame cases and unchanged-byte assertions. Add X-E3 to the registry only after these and Task 6 output rules are green; until then keep it unavailable for production conversion. Commit/push `feat: encode measured X-E3 conversion profiles`.

### Task 6: Validate X-E3 JPEG output and rendering evidence

**Files:** Modify core `JPEG/{FujiJPEGMetadataReader,CameraOutputAssessment}.swift`, shared `PTPDatasets.swift`, `Adapters/XE3/XE3Adapter.swift`, `Adapters/XT5/XT5Adapter.swift`; create `XE3OutputValidationTests.swift`, parameterize shared-service tests and synthetic JPEG fixtures for both models.

**Interfaces:**
- Consumes `PreparedConversion` and `CameraOutputAssessment`; produces qualified Fuji observations for film/monochrome filter, grain, WB/shifts/Kelvin, DR, tone/detail/NR and LMO alongside existing identity/FINE/geometry checks.
- `FujiJPEGMetadata.requireFine(width:height:orientation:model:)` validates the passed exact supported identity instead of containing an X-T5 literal; adapter registration still controls model support.
- Output expectations declare allowed association types (X-E3 7/2055, X-T5 its existing 0/2055), zero ObjectInfo-dimension allowance, required JPEG fields and protocol-confirmed fields.

- [x] **Step 1: Add exact output tests.** Accept X-E3 6000×4000 FINE orientations1/8 with measured associations, including ObjectInfo width/height0 only when actual JPEG dimensions match. Reject NORMAL, wrong make/model/orientation/crop, malformed/duplicate maker-note metadata and setting disagreement. Verify FujiFilm Sharpness rather than coarse EXIF Sharpness; WB shifts divide the JPEG's signed ×20 scale. Monochrome/filter identification must handle the measured Saturation representation. Test Kelvin5310→2500 as a semantic mismatch even with exact profile readback. Omit one required field and assert failure; omit a declared protocol-evidenced field and assert honest evidence, not invented metadata.
- [x] **Step 2: Verify failure.** `swift test --package-path Packages/FujiCameraCore --filter XE3OutputValidationTests`; expect X-T5-only identity and missing evidence mappings to fail.

  Name cases `zeroObjectDimensionsRequireRealJPEGGeometry`, `qualifiedSharpnessWinsOverCoarseEXIF`, `readbackDoesNotExcuseKelvinMismatch` and `missingRequiredEvidenceBlocksPublication`. Assert `#expect(observed.sharpnessTenths == 10)` for the +1 Fuji/coarse-Hard fixture; pattern-match `.rejected` on the requested5310/observed2500 assessment. Use semantic values, never label comparison, for admission.
- [x] **Step 3: Extend bounded parsing and adapter rules.** Use the existing strict maker-note/TIFF reader; do not add an ExifTool runtime dependency. Pin tag IDs/types/scales to checked fixtures and the laptop's qualified metadata. A field without independently established mapping stays unimplemented. Keep core ownership/storage/handle/hash checks independent of per-model association rules. Apply Task 3 rejection/cleanup behavior to both adapters and register the completed X-E3 conversion path.
- [x] **Step 4: Verify and checkpoint.** Run all core tests and affected iOS camera tests. Test changed-handle/storage/payload and delayed callback cases for both models; expect no cross-model cleanup exception. Commit/push `feat: validate X-E3 camera output and effective settings`.

### Task 7: Decode X-E3 banks with service-owned session transitions

**Files:** Create `Adapters/XE3/XE3BackupRecipeCodec.swift`, core `XE3BackupRecipeCodecTests.swift`, `RecipeImportSessionTests.swift`, sanitized `xe3-bank-backup-synthetic.bin`; modify `CameraServing.swift`, `FujiCameraService.swift`, `CameraOperationIO.swift`, X-T5 importer, app/test import-return bindings.

**Interfaces:**
- Consumes Task 3's `RecipeImportSessionPolicy`, `DecodedRecipeCollection`, `ImportedRecipeCollection` and receipt-returning `CameraServing.importRecipes()`; implements `.freshBeforeAndAfter` for X-E3 while preserving `.currentVerifiedSession` for X-T5.
- `XE3BackupRecipeCodec.decode(_ backup: Data, context: RecipeCameraContext, importedAt: Date) throws -> DecodedRecipeCollection` validates 5660-byte/model framing and preserves only required native fields, bounded name bytes and shared-WB dependencies in snapshots.

- [x] **Step 1: Add bank decode and lifecycle tests.** Synthetic backups cover seven complete slots, an empty name, all known film/colour/NR encodings, truncation/bad model/unknown values and digest changes when shared WB changes. Assert film byte3909+256×index; name at film+69 bounded to16 bytes; field offsets WB−33/Kelvin−32/NR−7/DR+3/colour+7/sharp+9/high+10/shadow+11/grain+12. Shared table433..<457 decodes grid as9−byte: Temperature441/442 =13/11→−4/−2, Auto433/434 =6/13→+3/−4, Daylight443/444 =7/13→+2/−4. Unvalidated positions remain lossless and unsupported, including neutral values. Session tests assert exactly one backup read between verified fresh sessions, changed final generation/UUID, no intermediate import receipt, no repeated read on retry, cancellation at each close/open boundary and rejection of old queued work.
- [x] **Step 2: Verify failure.** Run `swift test --package-path Packages/FujiCameraCore --filter XE3BackupRecipeCodecTests` and `--filter RecipeImportSessionTests`; expect absent backup/import-receipt behavior.

  Name cases `backupFreezesSharedWBIntoSnapshot`, `neutralUncalibratedWBIsStillUnsupported`, `backupUsesExactlyOneReadBetweenFreshSessions` and `physicalDetachDuringOwnedReopenRevokesAdmission`. Assert `#expect(wire.backupReads == 1)`, `#expect(receipt.context.generation == wire.finalGeneration)` and `#expect(receipt.recipes.allSatisfy { $0.cameraContext.sessionGeneration == receipt.context.generation })`.
- [x] **Step 3: Implement lossless decode and session policy.** Use the documented distinct backup lookup tables, including descending Kelvin indices; never reuse profile-native values as backup values. Do not retain a whole private backup or serial. Service closes/confirms, opens/verifies, performs one backup read, closes/confirms, opens/verifies final context, then stamps all snapshots with that final context. Importer's borrowed I/O cannot open sessions. A planned-close token accounts for callbacks without masking a real detach; restore/reopen is bounded after cancellation and never re-admits cancelled work. Preserve X-T5 doubled bank reads and verified selector restoration.
- [x] **Step 4: Verify and checkpoint.** Run package tests and `Scripts/test-ios.sh --fast`; all fake services compile with the receipt contract. Confirm complete-but-partly-unsupported collections can be imported losslessly while partial collections cannot. Commit/push `feat: import X-E3 recipes across verified USB sessions`.

### Task 8: Store declared collections and edit phone recipes offline

**Files:** Modify `FujiStudio/Catalog/{CatalogStoring,CatalogModels,SwiftDataCatalog}.swift`, `FujiStudio/Recipes/{PhoneRecipeDraft,PhoneRecipeSetting,PhoneRecipeGrain}.swift`; create/extend `CatalogTests.swift`, `PhoneRecipeDraftTests.swift`, core `RecipeEditRoundTripTests.swift`.

**Interfaces:**
- Consumes `ImportedRecipeCollection`, `RecipeCodecRegistry` and capabilities.
- Changes `CatalogStoring.replaceRecipes(_ collection: ImportedRecipeCollection) async throws`; stores declared slot metadata with the active collection and validates exact slot membership, unique snapshot IDs and final context in one transaction.
- `PhoneRecipeDraft.init(recipe: PhoneRecipe, codecs: RecipeCodecRegistry)` uses semantic `RecipeSettingID`/typed `RecipeSettingValue`; `makeSnapshot() throws -> RecipeSnapshot` preserves immutable snapshots/phone membership. Settings choices come from the recipe's adapter even offline.
- `copyRecipeToPhone` validates a recipe's declared adapter slot rather than `1...7` and remains idempotent per source snapshot.

- [x] **Step 1: Add collection and offline edit tests.** Use a test-only three-slot capability and explicit no-bank capability, so seven is never the generic invariant. A failed/partial replacement retains the complete previous collection. Mix X-T5/X-E3 phone records, rename offline, edit a known setting and preserve unknown native bytes. Assert no USB calls, same phone membership ID, new snapshot ID on edit, frozen old version/job unchanged, digest stable for rename and changed for effective WB edits. Preserve stale-editor and disk-failure rejection behavior.
- [x] **Step 2: Verify failure.** `Scripts/test-ios.sh FujiStudioTests/CatalogTests FujiStudioTests/PhoneRecipeDraftTests`; expect fixed-seven/raw-code assumptions to fail.

  Name cases `declaredThreeSlotCollectionReopens`, `partialCollectionRetainsPreviousCompleteImport`, `mixedModelOfflineEditPreservesUnknownBytes` and `renameKeepsFrozenDigest`. Assert `#expect(reopenedSlots == [1, 2, 3])`, `#expect(editedPhone.id == originalPhone.id)` and `#expect(frozenJob.recipeSnapshot == originalSnapshot)`.
- [x] **Step 3: Implement durable collections/drafts.** Store declaration and snapshot membership atomically. Use adapter assessment/encoding, not PTP codes in `PhoneRecipeSetting`; keep unknown/imported values visible and unchanged unless explicitly edited. X-E3 uses an exact supported Kelvin choice, optional grain size and whole-step tones; X-T5 retains its editable domain and separate finite render assessment. Unknown adapter provenance can still be renamed losslessly without executing it.
- [x] **Step 4: Verify and checkpoint.** Run targeted tests, package round-trip tests and `Scripts/test-ios.sh --fast`; reopen the catalog to verify mixed recipes and frozen references persist. Commit/push `feat: persist and edit recipes through model capabilities`.

### Task 9: Integrate capabilities, import receipts and rendering admission in the app

**Files:** Modify `App/{AppModel,AppEnvironment}.swift`, `Workspace/{WorkspaceState,RecipeMenu,WorkspaceView,CameraStatusControl,RecipeSlotBadge}.swift`, `Recipes/PhoneRecipeEditor.swift`, `Rendering/{OriginalResourcePool,PreviewCoordinator,CameraWorkScheduler,FileRenderCache,RawDisplayRenderer}.swift`, `Export/ExportCoordinator.swift`, debug fixtures and related unit/UI tests.

**Interfaces:**
- Consumes all shared contracts, registry and complete collections; produces `WorkspaceAction.recipesImported(ImportedRecipeCollection)` that atomically adopts context/recipes/slots after caller lifecycle/request-token checks.
- `AppModel.refreshRecipes()` revalidates the returned final context against `camera.executionContext()` before catalog commit and UI adoption, rather than comparing to the pre-import native generation. It adopts receipt capabilities/context/recipes/slots together and marks the final session imported before handling delayed READY so planned reopens cannot cause an import loop. Before import, READY loads `camera.support(for: context)` with the same request-token checks; unsupported optional import does not hide conversion capabilities.
- `RecipeMenu` takes declared `[RecipeSlot]` and assessed phone-recipe compatibility; editor takes recipe capabilities and semantic draft values.
- Existing `RenderKey` retains actual execution context/support version plus source revision/hash, recipe digest, geometry and output policy. No key may omit adapter provenance.

- [x] **Step 1: Add receipt-race, mixed-library and rendering regressions.** Cover delayed READY/DISCONNECTED during owned reopen, actual detach during reopen, backgrounding during receipt/catalog commit, and a second refresh superseding the first. Assert no stale collection publication or recursive auto-import. Test camera switching while a preview is queued, frozen export interruption and saved-JPEG access offline. X-E3 source on X-T5 is disabled; mixed phone recipes remain visible with reasons. Test decoder failure independently: camera conversion remains eligible and original-RAW view returns `.unavailable`, with explicit paired camera-JPEG/saved-version choices.
- [x] **Step 2: Verify failure.** Run `Scripts/test-ios.sh FujiStudioTests/AppModelTests FujiStudioTests/WorkspaceStateTests FujiStudioTests/CameraExecutionContextTests FujiStudioTests/PreviewCoordinatorTests FujiStudioTests/ExportCoordinatorTests`; expect old-context equality/fixed settings/model copy to fail.

  Name cases `ownedReopenAdoptsReceiptExactlyOnce`, `detachDuringCatalogSaveCannotPublishOldContext`, `otherModelPhoneRecipeRemainsEditable`, `decodeFailureDoesNotRevokeCameraConversion` and `modelSwitchCannotReusePreviewOrResumeExport`. Assert `#expect(camera.importCount == 1)`, `#expect(state.currentCameraExecutionContext == receipt.context)` only for the admitted receipt, `#expect(originalRAWDisplay == .unavailable)` for the failing decoder fixture and `#expect(camera.renderCount == 0)` for incompatible source/model.
- [x] **Step 3: Implement atomic adoption and model-aware controls.** Retain client suspension/request tokens across planned reopens but retire the old camera context immediately. Validate receipt context/declarations at persistence and publication boundaries; delayed lifecycle events cannot overwrite a newer receipt. Replace hard-coded seven/X-T5 status strings and placeholder rows with capability data. Hide unavailable X-E3 effects/size, use the discrete Kelvin picker, preserve unsupported imports with clear reasons, and disable incompatible execution without removing editing/deletion. Keep camera-connection retry and export-suspension behavior. Never use an embedded-JPEG fallback for RAW viewing.
- [x] **Step 4: Verify unit and affected UI flows.** Run `Scripts/test-ios.sh --fast`, then `Scripts/test-ios.sh FujiStudioUITests/AppFlowTests` with both X-T5 and X-E3 fixtures. Add UI cases for X-E3 controls, mixed phone rows/offline editing, non-seven slots, failed RAW viewing and preserved saved versions. Inspect normal/large-text portrait/landscape screenshots; use the existing accessible identifiers where possible.
- [x] **Step 5: Checkpoint.** Commit/push `feat: integrate model-aware Fujifilm camera workflows`.

### Task 10: Exercise the shipping core on the connected laptop camera

**Files:** Create `Tools/FujiCameraLaptop/` files from the map and its CLI tests; modify `Scripts/CameraProbe/run.sh`, analysis input adapters and `docs/validation/xe3-laptop-protocol.md`; add sanitized validation results and core fixtures for newly established mappings.

**Interfaces:**
- Local executable package depends on `../../Packages/FujiCameraCore`; `MacImageCaptureDriver: CameraSessionDriver` implements public discovery/open/close/send callbacks with bounded correlation and authoritative close acknowledgement.
- CLI: `swift run --package-path Tools/FujiCameraLaptop FujiCameraLaptop import-recipes --output <fresh-private-directory>` and `render --raw <RAF> --slot <N> --output <fresh-private-directory>`. Optional `--recipe-file <snapshot-json>` provides a frozen offline copy instead of a slot. Exactly one source of recipe selection is allowed.
- Evidence JSON records actual adapter/model/firmware/support version, requested/effective evidence, profile hashes, cleanup/closure and source hash. Full backups/serial/photos never enter public fixtures. Python remains analysis-only; no independent bank/profile implementation is an acceptance path.

- [x] **Step 1: Add CLI/driver tests.** Assert invalid arguments fail before opening, existing output directories are rejected, cancelled/late command callbacks do not affect a new generation, and commands delegate through `FujiCameraService` rather than duplicating conversion/cleanup. Assert laptop policy creates mode0700 directories and no file-protection-only API is required on Mac. Run `swift test --package-path Tools/FujiCameraLaptop` and observe missing executable/driver behavior.

  Name cases `invalidArgumentsNeverStartDiscovery`, `existingOutputDirectoryIsNotOverwritten` and `laptopRenderUsesCoreOwnedCleanup`; assert `#expect(driver.starts == 0)` for invalid input, `#expect(existingBytes == originalBytes)` on directory refusal and `#expect(wire.deletes.count == 1)` only after the service's owned-output proofs.
- [x] **Step 2: Implement the runner.** Reuse the core command transport and native callback knowledge from the spike, with all conversion/import/cleanup decisions in the core. Preserve main-runloop/selector callback handling and confirmed close. Keep the old probe clearly labelled diagnostic-only if still useful; update `run.sh` to the shared-core entry point for normal validation. Do not keep two acceptance implementations.
- [x] **Step 3: Reproduce the admitted sample cases.** Build with `swift build --package-path Tools/FujiCameraLaptop`; cover seven sources in `/Users/louis/Pictures/XE3`, both orientations and the currently validated imported recipes. C7's Underwater dependency remains blocked until Step 4. Validate full-size FINE, exact readback, qualified setting metadata, source hashes unchanged, exact cleanup and closure. Compare C3/C4/C6 against references; use a deliberately edited DR200 snapshot via `--recipe-file` only for the documented C3 capture-reference diagnostic, while normal C3 remains DR400. Compare grain runs against repeats rather than pixel equality. Cover seven source conversions and seven bank conversions (overlap where applicable); a 49-combination sweep is unnecessary absent a new failure. Use `/Volumes/sourcecode/fuji-studio/.venv/bin/python` or the execution workspace's project `.venv`, never global Python.
- [x] **Step 4: Resolve the remaining evidence gates.** With no camera session open, request the user's manual controlled WB changes for Underwater (needed by C7), then other currently unverified preset positions intended for support; read each backup once in a fresh session, isolate the relevant byte pair, and have the user restore the original state. Keep custom measured-WB gains unsupported. Do not make persistent setting/bank writes. Confirm final WB/table and all bank bytes restored. Independently verify the remaining native Kelvin candidates from the documented index list using temporary conversion profiles; expand picker capabilities only for candidates whose JPEG Kelvin matches. When hardware interaction is pending, continue other tests but leave these steps unchecked.
- [x] **Step 5: Verify and checkpoint.** Complete the seven-source/seven-bank matrix including C7 after Step 4 passes. Run both package suites and app unit tests after any mapping changes; publish only sanitized evidence. The intended current seven banks must all have validated dependencies before claiming full X-E3 recipe support. Commit/push `test: validate shared X-E3 adapter against laptop camera` with actual passed and outstanding gates documented.

### Task 11: Complete iOS regression and physical-device acceptance

**Files:** Update relevant app/core regressions, `README.md`, `docs/validation/fujifilm-usb-adapters.md` and this plan's checkboxes; change production code only for demonstrated acceptance failures with regression coverage.

**Interfaces:**
- Consumes the finished shared core, app integration and laptop evidence; produces an exact revision/build and a validation matrix with independent Mac, simulator, X-E3/iPhone and X-T5/iPhone results.
- Physical signing uses development team `AZH3P824F3`, automatic signing and `CODE_SIGN_IDENTITY='Apple Development'` per AGENTS.md.

- [x] **Step 1: Run final software gates.** Run `swift test --package-path Packages/FujiCameraCore`, `swift test --package-path Tools/FujiCameraLaptop`, the complete `Scripts/test-ios.sh`, then a simulator Release build with `xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio -configuration Release -destination "$FUJI_STUDIO_DESTINATION" -derivedDataPath .build/ReleaseValidation CODE_SIGNING_ALLOWED=NO build`. Expect zero failures and `BUILD SUCCEEDED`; preserve result bundles and list actual coverage.
- [x] **Step 2: Install the verified physical build.** Find the phone with `xcrun devicectl list devices`, build Release with the exact AGENTS.md signing command and a task-private derived-data directory, verify the app with `codesign --verify --deep --strict`, install that exact bundle and launch `com.lun3x.FujiStudio` without fixture arguments. Reuse authorized existing signing credentials.
- [ ] **Step 3: Perform physical acceptance.** X-E3: mode/admission, seven-bank import with final context, offline edits, all supplied RAF classes/orientations, real original-RAW display outcome, preview and deliberate FINE export, saved-version viewing, reconnect/background/cancel and interruption recovery. Record real phone behavior for compressed RAF decoding. X-T5: firmware4.31 admission, bank restore, existing supported recipe/source class, preview/export and model switching. If a body or phone is unavailable, document that specific outstanding gate; do not infer it from simulated transports or laptop runs. Verify no saved camera settings/banks changed and no trigger/delete/export was replayed.
- [x] **Step 4: Review the whole branch and resolve findings.** Follow the execution method chosen at handoff for independent review. Focus on scoped I/O expiry, planned-close/detach races, mismatch cleanup, store-upgrade crash recovery, cache/model affinity and unvalidated support expansion. Fix substantive findings with focused regression tests, then rerun only affected gates unless the findings invalidate final suite results.
- [x] **Step 5: Checkpoint and hand off.** Push final checkpoints on the active bookmark. Document exact revision, passing checks and any physical gates still outstanding without calling unfinished support complete. Shut down/delete only the task's simulator. Provide the reviewable branch and validation record; do not merge or publish unrelated work.

## Self-review of this plan

- Package/platform extraction and current X-T5 safety: Tasks 1–3.
- Semantic settings, passive native snapshots, stable digests, safe durable forward conversion: Task 2; mixed/offline collections and edits: Task 8.
- Registry, actual capability origin, scoped import I/O, shared conversion and output ownership: Task 3.
- Source models/geometry and display independence: Tasks 4 and 9; physical decoder result: Task 11.
- X-E3 profile encodings, finite support, Kelvin negatives and baseline preservation: Task 5; JPEG/effective evidence: Task 6.
- Backup layout/shared dependencies, final context, bounded restore/reopen: Task 7; callback/auto-import race integration: Task 9.
- Shared laptop implementation, seven-bank reference comparisons, WB/Kelvin evidence/restoration: Task 10.
- Core/Mac/iOS/UI/Release/physical tests and final review: Task 11.
- All five Review Focus conditions have named tests in their owning task. Interfaces use the same receipt, assessment, registry and source-admission contracts throughout.
- No product code, package scaffold, dependency installation or hardware operation is part of writing this plan.

## Execution handoff

Recommendation: **Native execution** in this session using `superpowers:executing-plans`, followed by the required independent whole-branch review. The tasks are sequential and tightly coupled through recipe/storage/session contracts; keeping one implementation context reduces interface churn. Focused regressions protect the high-risk state machine at every checkpoint.

Alternative: **Subagent-driven execution** using fresh implementers and reviewers per task, then whole-branch review. This adds review isolation at each checkpoint at the cost of repeated context and handoffs.

The design is approved. Before product implementation, the writing-plans workflow calls for the user to review this concrete plan and choose the execution method. Preserve their choice for the whole execution.
