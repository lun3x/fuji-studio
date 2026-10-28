# Phone Recipes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Copy and durably save imported camera recipes, then select them from a Phone tab.

**Architecture:** Keep immutable RecipeSnapshot values for rendering, adding optional copy provenance and a separate catalog membership record for phone copies. Workspace state distinguishes camera slots from phone snapshot identities; the menu calls an asynchronous save before displaying the phone collection.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, XCTest, XcodeGen.

**Spec:** docs/superpowers/specs/2026-10-28-phone-recipes-design.md

## Global Constraints

- Use SwiftUI and the existing durable SwiftData catalog.
- No edit screen, blank recipe creation, deletion, syncing, sharing, or new camera/setting support is included in this increment.
- Copying never changes camera banks or writes Photos assets.
- Use Jujutsu in the temporary workspace and push the development bookmark at each checkpoint.
- Use a fresh task-specific simulator; shut down and delete it when finished.

## Review Focus

- Repeat taps must not create duplicate copies of the same import.
- Camera refreshes must not replace a selected phone copy with its source C-slot.
- Disconnect/reconnect must preserve phone selection while maintaining camera admission checks.
- An unsupported import must retain its exact values and remain blocked from rendering.
- A failed save must not appear successful or alter recipe selection.

### Task 1: Durable phone copies and selection

**Files:** RecipeSnapshot.swift; CatalogStoring.swift; CatalogModels.swift; SwiftDataCatalog.swift; WorkspaceState.swift; AppModel.swift; catalog test doubles; CatalogTests.swift; WorkspaceStateTests.swift; AppModelTests.swift.

**Interfaces:**
- `RecipeSnapshot.copiedFromRecipeID: UUID?`, `isPhoneRecipe: Bool`, `copiedToPhone() -> RecipeSnapshot`.
- `CatalogStoring.copyRecipeToPhone(_ recipe: RecipeSnapshot) async throws -> RecipeSnapshot`, `phoneRecipes() async throws -> [RecipeSnapshot]`.
- `WorkspaceAction.phoneRecipesLoaded([RecipeSnapshot])`, `.phoneRecipeSelected(UUID)` and `WorkspaceState.phoneRecipes`.
- `AppModel.copyRecipeToPhone(id: UUID) async -> Bool` persists before publishing; leaves selection unchanged.

- [x] Write tests proving exact copy/provenance and repeat-save idempotence through durable reopen and camera refresh; prove phone identity selection, offline reconnect, unsupported admission, and unchanged selection on copy.
- [x] Run the targeted tests and observe failure from missing phone behavior.
- [x] Implement immutable copies, separate catalog membership and atomic persistence, reducer selection and model load/save/error paths. Update protocol test doubles explicitly.
- [x] Run all unit tests, including phone export with a frozen snapshot and a forced persistence failure.
- [x] Commit and push the development bookmark.

### Task 2: Recipe chooser UX and verification

**Files:** RecipeMenu.swift; WorkspaceView.swift; ExportProgressView.swift; VersionList.swift; WorkspaceFixture.swift; AppFlowTests.swift; VersionListTests.swift; README.md.

**Interfaces:**
- RecipeMenu consumes `phoneSnapshots` and `onCopyToPhone: (UUID) async -> Bool`, `onSelectPhone: (UUID) -> Void`.
- WorkspaceView forwards phone copy/select callbacks; AppWorkspaceView binds the model method.
- VersionList derives phone labels from `RecipeSnapshot.isPhoneRecipe`.

- [x] Add a UI test for empty Phone tab, offline cached copy, automatic Phone-tab reveal without selection, selection/dismissal, repeat-copy reuse, relaunch persistence and camera refresh independence; observe failure. Restart persistence is exercised by catalog reopen and fresh-model integration tests because UI fixtures intentionally use a fresh catalog for each launch.
- [x] Implement native segmented tabs, separate accessible copy buttons, inline save errors and saving state, phone rows/indicator, and saved-version phone badges.
- [ ] Run relevant UI suites and all unit tests; inspect normal and large-text screenshots; build Release for the simulator.
- [ ] Request one fresh whole-branch review, address substantive findings with regression tests, then commit/push and create a draft PR. Shut down/delete the task simulator.
