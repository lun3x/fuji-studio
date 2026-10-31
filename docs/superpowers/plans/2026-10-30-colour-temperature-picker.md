# Colour temperature picker Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this focused fix inline.

**Goal:** Make the X-T5 Colour temperature editor check reliable with parallel simulator workers.

**Architecture:** The failing test checks keyboard presence before a delayed software keyboard appears. Its native picker subsequently opens underneath that keyboard. Establish and dismiss the Name keyboard explicitly before using editor pickers, matching the working keyboard-sensitive editor tests; retain every capability, save/reopen, and conversion assertion.

**Tech Stack:** Swift, XCTest UI automation, iOS 27 simulator, Jujutsu.

**Spec:** User request to investigate and fix the Colour temperature issue; prior failure documented in `2026-10-30-horizontal-landscape-selection.md`.

## Global Constraints

- Use a fresh `/tmp/` Jujutsu workspace and task-owned simulator.
- Keep parallel execution enabled for reproduction and final validation.
- Preserve selection of Colour temperature and all existing persistence/conversion assertions.

## Review Focus

- A late keyboard must not cover the white-balance menu.
- Explicit keyboard setup must not edit the recipe name.
- Existing film and range selections must still be saved and reopened.
- Both X-T5 and X-E3 editor suites must remain usable.
- A serial rerun is not proof that this parallel failure is fixed.

## Task 1: Reproduce, fix, and verify the keyboard precondition

**Files:** Modify `FujiStudioUITests/PhoneRecipeEditorTests.swift`; record evidence here. No production change is planned unless investigation shows it is necessary.

- [x] Reproduce the current test with two workers alongside `ModelRecipeTests`: five passed, X-T5 Colour temperature failed as before. Result: `.build/TestResults/20261030-144849-61642.xcresult`.
- [x] Inspect failure activity and hierarchy: keyboard was absent at the helper check, then covered the menu option (option y=640; keyboard begins y=551).
- [x] Explicitly focus Name, wait for the keyboard, and reveal Film through the existing Return-dismissal helper before opening the film menu.
- [x] Run the identical two-worker reproduction group, then the affected editor suites and all unit tests.
- [x] Run the complete `Scripts/test-ios.sh` suite with two workers and verify the original failure passes there.
- [x] Review, push checkpoints to `codex/colour-temperature-picker`, and shut down/delete the isolated simulator.

Workspace: `/tmp/fuji-studio-colour-temperature-picker`.
Simulator: `C4BF03AA-6380-4DFA-A3DB-6830BA73D7FD`.
Baseline log: `/tmp/fuji-colour-baseline-parallel.log`.

The identical two-worker reproduction passed all six tests after the keyboard precondition change: `/tmp/fuji-colour-precondition-parallel.log`. The original Colour temperature tap, saved film/range/balance assertions, and final conversion check are unchanged. A follow-up assertion verifies that focusing Name and submitting Return leaves its value unchanged.

The all-unit plus editor-suite parallel run passed 585 tests, including every unit test and the updated Colour temperature case. One existing grain-choice case failed at the immediate `XCTAssertFalse(size.isEnabled)` after selecting Off; a later hierarchy already showed Off with Grain Size disabled, followed by a missed Strong menu opening. This is a separate UI state-timing failure, with no keyboard in its failure hierarchy. The full suite will recheck it unchanged. Affected-run log: `/tmp/fuji-colour-affected-parallel.log`; result: `.build/TestResults/20261030-145817-66978.xcresult`.

Fresh code review found no actionable issues and verified the two-worker baseline/fixed commands and preserved assertions. Full parallel validation remains the final gate: `/tmp/fuji-colour-full-parallel.log`, result `.build/TestResults/20261030-150555-71551.xcresult`.

Ruling: Keep this fix scoped to the reproduced automation keyboard race. Deliberately leaving the Name keyboard open retains existing native Form/picker behavior; this patch does not claim to change that separate interaction. If that interaction is also faulty, it needs separate reproduction and an app-level fix.

Ruling: Leave the grain state-timing test unchanged. Its failed disabled-state assertion differs from the keyboard obstruction and the later hierarchy shows the correct state; broadening this patch would mix two root causes. The existing grain test may still be intermittent, and the final full run will report its actual outcome.

Final verification: the complete two-worker suite passed **658 tests, 0 failures, 3 skips** (661 total), including all seven phone editor tests and the unchanged grain-choice test. Colour temperature passed in three separate parallel runs: the original reproduction group, the all-unit/editor group, and the complete suite. All original picker persistence and conversion assertions passed. Result: `.build/TestResults/20261030-150555-71551.xcresult`; log: `/tmp/fuji-colour-full-parallel.log`.

Fresh review found no issues. The task simulator was shut down/deleted and no task-named XCTest worker clones remain. User authorized PR creation and merge after the full suite passed.
