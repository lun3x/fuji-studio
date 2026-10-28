# Phone Recipe Deletion and Connection State

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development to execute this plan inline.

**Goal:** Delete saved phone recipes and give their selection rows the same disconnected behavior as camera recipes.

**Architecture:** Delete only SwiftData phone-collection membership, then publish successful deletion through the workspace reducer. Keep selection and deletion as separate SwiftUI buttons so connection gating does not prevent offline management.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing and XCTest.

**Spec:** Follow-up section of docs/superpowers/specs/2026-10-28-phone-recipes-design.md.

**Design:** Add an independent trash icon to each phone row with an in-app deletion confirmation. Deletion works offline and removes only phone-list membership, preserving immutable snapshots, saved photos and active export history. Successful deletion of the selected recipe clears selection and pending preview; failure keeps the recipe visible/selected with an actionable error. Phone selection requires a camera connection, is greyed/disabled offline, and is cleared on disconnect just like camera selection. Camera copies remain available offline.

**Integration:** Continue PR #16 and its development bookmark in a fresh Jujutsu workspace, merging current origin/main (automatic camera connection and fast-test tooling). Preserve both sets of tests and explicitly disable automatic connection where a test needs an offline fixture.

## Global constraints and review focus

Use Jujutsu in the isolated temporary workspace and push checkpoint commits.
Use the task's simulator, fast unit iterations and the complete final test
wrapper. Reuse existing phone signing credentials for installation. Editing
remains deferred. Review selected-recipe deletion during pending preview, failed
persistence, active export history, deleted-recipe recopy and disconnected
selection; Task 1 tests each, and Task 2 exercises their native controls.

## Task 1 — persistence and state

- [x] Integrate latest main and verify a clean baseline with Scripts/test-ios.sh --fast on a new task-owned simulator.
- [x] Add failing catalog tests: durable deletion, repeated deletion, recopy after deletion, and preserved frozen job/version history.
- [x] Add failing reducer/model tests: offline selection rejected; disconnect clears selection; selected deletion invalidates preview; unrelated deletion preserves it; failed deletion keeps state and history.
- [x] Implement deletePhoneRecipe(id:) in the catalog/model, phoneRecipeDeleted in the reducer, and matching connection gating. Update catalog test doubles.
- [x] Run the unit gate and push a checkpoint with Jujutsu.

## Task 2 — native controls and verification

- [x] Add/adjust UI cases for offline dimmed/disabled phone rows with enabled deletion, cancel/confirm, selected deletion, recopy, connection transitions and largest text; observe failures before implementing.
- [x] Add separate accessible delete controls, confirmation and failure feedback; forward through the workspace and deterministic fixture.
- [x] Run affected UI cases, then the complete Scripts/test-ios.sh suite, a Release build and one fresh read-only review. Inspect screenshots.
- [x] Push/update the existing PR and validation record, install the verified signed build on the user's phone, and clean up the task simulator.
