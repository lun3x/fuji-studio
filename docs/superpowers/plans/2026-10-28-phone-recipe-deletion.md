# Phone Recipe Deletion and Connection State

> Execute inline using superpowers:executing-plans and test-driven-development.

**Goal:** Delete saved phone recipes and give their selection rows the same disconnected behavior as camera recipes.

**Design:** Add an independent trash icon to each phone row with an in-app deletion confirmation. Deletion works offline and removes only phone-list membership, preserving immutable snapshots, saved photos and active export history. Successful deletion of the selected recipe clears selection and pending preview; failure keeps the recipe visible/selected with an actionable error. Phone selection requires a camera connection, is greyed/disabled offline, and is cleared on disconnect just like camera selection. Camera copies remain available offline.

**Integration:** Continue PR #16 and its development bookmark in a fresh Jujutsu workspace, merging current origin/main (automatic camera connection and fast-test tooling). Preserve both sets of tests and explicitly disable automatic connection where a test needs an offline fixture.

## Task 1 — persistence and state

- [ ] Integrate latest main and verify a clean baseline with Scripts/test-ios.sh --fast on a new task-owned simulator.
- [ ] Add failing catalog tests: durable deletion, repeated deletion, recopy after deletion, and preserved frozen job/version history.
- [ ] Add failing reducer/model tests: offline selection rejected; disconnect clears selection; selected deletion invalidates preview; unrelated deletion preserves it; failed deletion keeps state and history.
- [ ] Implement deletePhoneRecipe(id:) in the catalog/model, phoneRecipeDeleted in the reducer, and matching connection gating. Update catalog test doubles.
- [ ] Run the unit gate and push a checkpoint with Jujutsu.

## Task 2 — native controls and verification

- [ ] Add/adjust UI cases for offline dimmed/disabled phone rows with enabled deletion, cancel/confirm, selected deletion, recopy, connection transitions and largest text; observe failures before implementing.
- [ ] Add separate accessible delete controls, confirmation and failure feedback; forward through the workspace and deterministic fixture.
- [ ] Run affected UI cases, then the complete Scripts/test-ios.sh suite, a Release build and one fresh read-only review. Inspect screenshots.
- [ ] Push/update the existing PR and validation record, install the verified signed build on the user's phone, and clean up the task simulator.
