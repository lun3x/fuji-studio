# Recipe editor availability implementation plan

> **For agentic workers:** Use superpowers:executing-plans for inline execution.

**Goal:** Hide unavailable settings/choices while preserving invalid selections visibly in red until repaired.

**Architecture:** Filter draft UI choices through existing standard capabilities and dependencies. SwiftUI omits unavailable rows and styles invalid active selections without changing storage.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XCTest, Jujutsu.

**Spec:** `docs/superpowers/specs/2026-10-31-recipe-editor-availability-design.md`

## Global constraints

- Work in `/tmp/fuji-studio-recipe-editor-availability-20261031`, use only Jujutsu, push checkpoints to `codex/standard-recipes`.
- Simulator `01AFB4B4-3104-4F30-ACE0-1858940850E5`; shut down and delete it at completion.
- Preserve hidden and invalid values in the complete standard recipe; retain existing Save/application validation.

## Review focus

- Camera changes that invalidate a film or numeric step preserve the selected value and block Save.
- Film, white-balance, grain, DR-priority and HEIF dependencies hide inactive rows without losing values.
- Unknown imports and invalid typed Kelvin remain repairable and clearly identified.
- Kelvin search never reintroduces unavailable values.
- Large text and landscape keep Save/Cancel and valid choices usable.

## Task 1: Filter presentation and retain repairable selections

**Files:** `FujiStudio/Recipes/PhoneRecipeDraft.swift`, `PhoneRecipeEditor.swift`, corresponding draft tests and `StandardRecipeEditorTests`, `PhoneRecipeEditorTests`, `ModelRecipeTests`, `AppFlowTestCase`.

**Interfaces:** `choices(for:)` returns available choices only; existing `isAvailable(_:)` and `isChoiceAvailable(_:for:)` identify visible rows and invalid retained selections.

- [x] Establish the draft-test baseline. Write filtering/retained-selection/temperature dependency regressions and observe failures.
- [x] Filter draft choices; hide unavailable rows, mark active invalid selections red with accessible status, and filter Kelvin search.
- [x] Update UI assertions to require absent unavailable controls/choices, red invalid status, repair/Save behavior, and restored retained values. Run affected UI suites and inspect screenshots.
- [ ] Run `Scripts/test-ios.sh --fast`, then the complete `Scripts/test-ios.sh` suite; require green results. Get a fresh review of this follow-up delta and address actionable findings with regressions.
- [ ] Record results, checkpoint/push, update PR #45 and delete the task simulator.
