# Recipe option values implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this change.

**Goal:** Offer every documented value for the recipe editor's existing X-T5 settings, using published mappings that agree with existing native values.

**Architecture:** Expand semantic film and WB enums and adapter mappings; derive editor choices from model-specific tables. Keep editable and camera-renderable choices distinct: new selector knowledge does not validate conversion dependencies. Preserve unknown and untouched native bytes.

**Tech Stack:** Swift, Swift Testing, SwiftUI, XCTest; Jujutsu workspace under `/tmp`.

**Spec:** User request: audit all existing recipe options, including missing DR200 and WB presets; accept a published source agreeing with existing wire values.

## Global constraints

- Use Jujutsu and push checkpoints to `codex/recipe-option-values`.
- Use an isolated simulator and remove it after validation.
- Do not replace measured grain mappings with the conflicting upstream grain table.
- Keep X-E3's native tables scoped to that model; measured custom WB gains remain unresolved.
- Existing conversion-profile validation remains in force.

## Review focus

- Every offered selector must encode and reopen with the correct semantic value.
- Unsupported imported fields must survive an unrelated edit exactly.
- Expanding shared enums must not add unsupported X-E3 choices.
- DR Auto must display as Auto, not 0%.
- Valid 10 K temperature steps must save; fractional steps and out-of-range values must fail.

## Task 1: Complete model-specific recipe choices

**Files:** `RecipeSettings.swift`, `XT5RecipeSettingsCodec.swift`, `RecipeCodecRegistry.swift`, `XE3Capabilities.swift`, `PhoneRecipeSetting.swift`, core `RecipeEditRoundTripTests.swift`, app `PhoneRecipeDraftTests.swift`, and `AppFlowTests.swift`.

**Interfaces:** Existing `RecipeCodecRegistry.capabilities`, `editableValues`, `encodeEditedValues`, and `PhoneRecipeDraft.choices/makeSnapshot` remain unchanged.

- [x] Add regression tests for the literal documented film/WB wire tables and all offered choice round trips; run and observe the missing-choice failures.
- [x] Expand X-T5 to 20 films, 14 WB modes, and DR Auto/100/200/400. Retain explicit renderable subsets. Restrict X-E3 selectors to its native tables; expose native DR Auto as editable only.
- [x] Label DR Auto correctly and validate X-T5 Kelvin in 10 K increments.
- [x] Exercise newly offered selectors through the phone draft and UI, including save/reopen.
- [x] Run the core suite, focused app/UI suites, and complete iOS suite on the task simulator. The full run was interrupted by simulator shutdown; all remaining UI tests passed on resume. See the validation record.
- [x] Document the audit, sources, agreements/conflicts, and remaining conversion limits; review, commit, and push checkpoint with Jujutsu.
