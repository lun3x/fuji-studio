# RAW+JPEG Pair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task in this chat, as the user previously chose.

**Goal:** Convert RAW-only originals to verified RAW+JPEG pairs on export when the existing setting is enabled.

**Architecture:** A journaled pair service owns creation, read-back verification,
and conditional removal. The export coordinator preserves its read-only passive
recovery contract. Catalog aliases and a workspace replacement event adopt the
new Photos identity without rewriting frozen jobs.

**Tech Stack:** Swift 6, PhotoKit, SwiftData, ImageIO, CryptoKit, XCTest/Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-30-raw-jpeg-pair-design.md`

## Global Constraints

- Use Jujutsu in `/tmp/fuji-studio-raw-jpeg-pair`; push `codex/reversible-export` checkpoints.
- iOS deployment target 27.0; use the task's own simulator and remove it afterward.
- Preserve original RAW bytes; no deletion before successful read-back verification.
- Existing pairs retain reversible edits; setting remains red and defaults off.
- Passive recovery never starts a Photos transaction or camera conversion.

## Review Focus

- A changed or corrupt replacement must never authorize original removal (Task 1).
- Interrupted creation/removal must recover without a duplicate or passive deletion (Tasks 1–2).
- Photos notifications before catalog confirmation must preserve selection/history (Task 2).
- Mixed RAW-only/paired batches must continue through their own removal events (Tasks 2–3).
- Unavailable metadata/albums and rejected removal must retain the original (Tasks 1–3).

### Task 1: Journaled pair creation and native boundary

**Files:** Create `FujiStudio/Export/PhotoPairJournal.swift`,
`PhotoLibraryPairer.swift`, `NativePhotoPairGateway.swift`, and
`FujiStudioTests/Export/PhotoLibraryPairerTests.swift`.

**Interfaces:** `PhotoLibraryPairer.saveJPEG(_:edit:onPlaceholder:)`,
`findExport(operationID:sourceID:knownAssetID:)`,
`completeReplacement(operationID:assetID:)`, and `sourceReplacements()`.

- [x] Write tests proving exact RAW/JPEG verification before removal, metadata
  forwarding, corrupt read-back/changed asset refusal, durable reopen, one
  creation across interruption, read-only lookup, and explicit cleanup retry.
- [x] Run the focused selector and observe missing behavior fail.
- [x] Implement durable intent storage, injected native boundary, byte/geometry
  verification, and guarded removal. Map all failures after creation to uncertain.
- [x] Run `Scripts/test-ios.sh FujiStudioTests/PhotoLibraryPairerTests`; expect pass.
- [x] Checkpoint with `jj` and push the active bookmark.

### Task 2: Writer, recovery, catalog and workspace integration

**Files:** Modify `PhotoLibraryWriter.swift`, `PhotoLibraryWriting.swift`,
`ExportModels.swift`, `ExportCoordinator.swift`, `CatalogModels.swift`,
`CatalogStoring.swift`, `SwiftDataCatalog.swift`, `WorkspaceState.swift`,
`AppModel.swift`, `AppEnvironment.swift`; add affected unit regressions.

**Interfaces:** Task 1's service; `SaveLookup.needsReplacementCleanup`, writer
`completeReplacement`/`sourceReplacements`, catalog `replaceSource`, and
workspace `sourceReplaced` event. Add internal `ExportDestination.createPair`.

- [x] Write failing routing, recovery, alias/confirmation ordering, checked/viewed
  source replacement, history preservation and batch-continuation regressions.
- [x] Observe focused failures, then implement the interfaces. Keep pending JPEG
  pins until creation and cleanup are classified. Only explicit Resume may retry
  replacement cleanup. Frozen source snapshots remain immutable.
- [x] Run `Scripts/test-ios.sh --fast`; expect affected and existing unit checks pass.
- [x] Checkpoint with `jj` and push the active bookmark.

### Task 3: Picker, fixtures, settings and final validation

**Files:** Modify `VersionList.swift`, the settings explanation, fixture writer
and library, affected version/settings unit/UI tests, and validation report.

- [x] Write a failing end-to-end UI test: select a RAW-only source, export with
  the setting enabled, keep one checked replacement with RAW and Paired JPEG;
  a second export edits that same pair and shows only the latest edit.
- [x] Implement fixture replacement and picker/copy behavior. Run affected UI
  suites, then the complete `Scripts/test-ios.sh` on the isolated simulator.
- [x] Obtain one read-only whole-change review; fix material issues with observed
  failing regressions, then appropriate suite verification.
- [x] Build signed Release, verify the exact bundle, install and launch on the
  user's connected iPhone under existing installation authorization.
- [x] Record results, clean up the simulator, and push final documentation.
