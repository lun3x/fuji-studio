# Reversible Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent setting that saves exports as reversible Photos edits and hides replaced edits from the version picker.

**Architecture:** Freeze an export destination in each durable job. Extend the Photos writer with a content-editing path that stores an operation marker and recipe in adjustment data. Resolve and display only the rendition that still matches that marker.

**Tech Stack:** Swift, SwiftUI Observation, PhotoKit, SwiftData, Swift Testing, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-30-reversible-export-design.md`

## Global Constraints

- Use only Jujutsu, a task workspace under /tmp, a task-specific simulator, and the project's test script.
- Do not add compatibility shims for historical data.
- The setting label is red; default is off; the sheet is titled **Status & settings**.
- Never delete/recreate a source asset or silently fall back to a separate photo.
- Uncertain submitted saves are never automatically resubmitted.
- Hide superseded/reverted edited exports from the version picker.

## Review Focus

- A second export must not leave the first recipe attached to the second export's pixels.
- External edits or Revert to Original must hide the corresponding Fuji Studio edit.
- An app settings change during a batch must not change its saved destination.
- RAW-only assets must use the same content-editing path as RAW+JPEG assets.
- Rotated camera JPEGs must satisfy PhotoKit's upright edited-output contract.

---

### Task 1: Reversible writing and durable destination

**Files:**
- Create `FujiStudio/Export/PhotoLibraryEditor.swift` for editing/lookup and JPEG normalization.
- Modify `FujiStudio/Export/PhotoLibraryWriting.swift`, `PhotoLibraryWriter.swift`, `ExportModels.swift`, and `ExportCoordinator.swift`.
- Modify `FujiStudio/Catalog/SwiftDataCatalog.swift` for destination validation.
- Test `FujiStudioTests/Export/PhotoLibraryWriterTests.swift`, `ExportCoordinatorTests.swift`, and new `PhotoLibraryEditorTests.swift`.

**Interfaces:**
- Add `ExportDestination: String, Codable, Sendable` with `.separatePhoto` and `.updateOriginal`.
- Add destination to `ExportJob` and `SavedVersion`, defaulting to `.separatePhoto` for source-level constructors.
- Extend `ExportCoordinator.start(sources:recipe:destination:)` with a `.separatePhoto` default argument; capture destination before asynchronous admission.
- Extend `PhotoSaveRequest` with destination and original source/recipe information for editing.
- Extend `PhotoLibraryWriting.findExport` to carry destination and source identity, retaining exact operation-ID recovery.
- Create `PhotoEditAdjustment: Codable, Sendable` containing operation ID, source ID, and frozen recipe, with an app-specific identifier and format version.
- Isolate native editing behind a testable `PhotoEditGateway` that prepares an edit, commits it, and reads its adjustment marker.

- [ ] Write failing tests: an original update targets the existing source ID, preserves source resources, and stores its operation/recipe; both RAW-only and paired inputs take this path.
- [ ] Add failure tests: denied access, unsupported asset, missing JPEG, stale source, native transaction rejection, uncertain completion, cancellation retaining the output until completion, and recovery refusing a different/reverted adjustment.
- [ ] Add a rotated-JPEG test asserting upright pixels/orientation and swapped geometry where appropriate.
- [ ] Run `Scripts/test-ios.sh FujiStudioTests/PhotoLibraryEditorTests FujiStudioTests/ExportCoordinatorTests` with the task's `FUJI_STUDIO_DESTINATION`; confirm the new behavior fails before implementation.
- [ ] Implement the interfaces above. Use `requestContentEditingInput`, `PHContentEditingOutput`, `PHAdjustmentData`, and `PHAssetChangeRequest.contentEditingOutput`; submit only after preparation. Keep preflight failures distinct from uncertain submissions.
- [ ] Freeze destination in jobs, forward it to writer/recovery, and retain it in confirmed saved records. Extend catalog immutable-field/confirmation validation accordingly.
- [ ] Verify the same focused suites and `Scripts/test-ios.sh --fast` pass; checkpoint with `jj` and push `codex/reversible-export`.

### Task 2: Correct current-edit resolution and version picker

**Files:**
- Modify `FujiStudio/Library/PhotoLibraryReader.swift` and resource identity helpers.
- Modify `FujiStudio/Workspace/PhotoViewer.swift`, `VersionList.swift`, and `FujiStudio/App/AppModel.swift`.
- Test `FujiStudioTests/Workspace/VersionImageResolverTests.swift`, `VersionListTests.swift`, library tests, and `FujiStudioTests/App/AppModelTests.swift`.

**Interfaces:**
- Add a value-boundary library method for finding the current edited JPEG only when adjustment data matches an asset's expected operation ID.
- Keep original resource revisions independent of reversible appearance edits; distinguish the current full-size edited resource from other adjusted resources.
- Resolver uses original JPEG resources for `.separatePhoto` and an operation-verified edited resource for `.updateOriginal`.
- Availability is per saved operation when multiple exports share one source asset. The version list excludes unavailable original updates while retaining existing separate-photo behavior.

- [ ] Write failing tests: two original updates show only the matching latest operation; revert/external edit hides it; selecting stale records never displays unrelated pixels; RAW and camera JPEG remain available.
- [ ] Add identity tests: reversible edits preserve original identity, while an actual changed original descriptor rejects stale resource tokens.
- [ ] Run the affected selectors and observe the expected failures.
- [ ] Implement operation-checked resource resolution and per-operation availability. Verify identity again after materializing the edited resource to reject races.
- [ ] Make version-list filtering apply both on initial load and library changes. Refresh an already selected edited version when the library changes, without falsely treating source originals as replaced.
- [ ] Run the affected selectors and `--fast`; checkpoint with `jj` and push the development bookmark.

### Task 3: Persistent settings and final validation

**Files:**
- Create `FujiStudio/App/AppSettings.swift` using an injectable UserDefaults store and observable state.
- Modify `FujiStudio/App/AppModel.swift` and `FujiStudio/Workspace/ExportProgressView.swift`.
- Test new `FujiStudioTests/App/AppSettingsTests.swift`, model tests, and `FujiStudioUITests/AppFlowTests.swift`.

**Interfaces:**
- `AppSettings.updateOriginalInPhotos: Bool`, default false and persisted on mutation.
- `AppModel` owns settings and snapshots `.updateOriginal` or `.separatePhoto` when the user starts an export.
- Status sheet has a Settings section, red **Update original in Photos** toggle, and supporting text about preserved originals and Revert in Photos.

- [ ] Write failing tests: default off, persistence across settings instances, isolation between test stores, and destination captured before any asynchronous export work.
- [ ] Add a UI test that opens **Status & settings**, verifies the setting and explanatory text, toggles it, and verifies persistence after relaunch. Use an isolated fixture defaults store.
- [ ] Run the focused tests to confirm the new cases fail, then implement the settings model, binding, and accurate status text for both modes.
- [ ] Run `Scripts/test-ios.sh --fast`, the affected UI suite, and the complete `Scripts/test-ios.sh` suite using the isolated task simulator.
- [ ] Inspect the settings screen and review the final diff against the spec. Address substantive findings and rerun affected checks.
- [ ] Record validation and any physical PhotoKit RAW validation limit; checkpoint and push via Jujutsu. Shut down and delete the task simulator.
