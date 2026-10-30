# Standard recipes implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Track progress with checkbox steps.

**Goal:** Store complete semantic recipes that can change camera models without losing unavailable values, with camera-aware editing and per-photo LMO/DR adjustments.

**Architecture:** A complete standard recipe and global setting catalog own persisted values and defaults. Model profiles define physical availability separately from conversion support. Native codecs populate standard recipes at import; conversion lowers standard values into the target model's verified profile.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, XCTest, Jujutsu.

**Spec:** `docs/superpowers/specs/2026-10-30-standard-recipes-design.md`

## Global constraints

- Use Jujutsu in `/tmp/fuji-studio-standard-recipes-20261030`; checkpoint/push `codex/standard-recipes`.
- No backwards compatibility; canonical recipe payloads are mandatory in the current schema.
- Python, if needed, uses the project's `.venv`.
- Task simulator: `95090440-98F2-4470-AAC1-64796D5F01C5`; shut down/delete on completion.
- Defaults: LMO On, image quality Fine+RAW, RAW recording Lossless compressed; preserve requested values during source adjustments.
- Camera domain and conversion domain remain separate; never silently ignore an unimplemented active processing request.

## Review focus

- Switching to a smaller numeric step domain preserves an invalid selected value and prevents Save.
- Switching back, saving, and reopening retains inactive fields and original import provenance.
- Undecodable available imported fields never quietly become valid defaults.
- An unsupported source can reduce LMO On to Off, but LMO Off never enables itself.
- Film-dependent monochromatic colour stays stored while disabled and returns unchanged when re-enabled.

### Task 1: Complete standard recipe and capability catalog

**Files:** Create core `Recipes/StandardRecipe.swift`, `StandardRecipeCatalog.swift`, `StandardRecipeImport.swift`; extend `RecipeSettings.swift` identities/values; add `StandardRecipeTests.swift`.

**Interfaces:** `RecipeCameraModel`, `StandardRecipe(camera:values:)`, `value(for:)`, `setValue(_:for:)`, `isAvailable(_:)`, `accepts(_:for:)`, `invalidSettings`, `StandardRecipeCatalog.choices(for:)`, `capability(for:camera:)`.

- [x] Write tests for complete defaults and Codable round-trip, full setting coverage, model restrictions, invalid selections retained across camera switches, and dependent monochrome controls.
- [x] Run focused core tests and observe missing-interface failures.
- [x] Implement complete values, defaults, domain/step checks and dependency rules. Native import is implemented with snapshot integration in Task 2.
- [x] Run focused core tests to green; checkpoint and push with Jujutsu.

### Task 2: Canonical snapshots, import and conversion boundaries

**Files:** Modify `RecipeSnapshot.swift`, `RecipeCodecRegistry.swift`, `RecipeValueEditing.swift`, native codecs, `XT5WorkingProfile.swift`, `XE3WorkingProfile.swift`, `FujiCameraService.swift`, app execution matching and catalog; add core standard recipe conversion tests.

**Interfaces:** `RecipeSnapshot.standardRecipe`, `targetCamera`, `replacingStandardRecipe(_:name:)`, `RecipeCodecRegistry.applicationSettings(_:)`; imported native evidence stays separate from canonical identity.

- [ ] Write tests for import defaults/overlays/unknowns, retarget/save/reopen, canonical digest identity, and target-specific application that omits unavailable settings without mutating stored values.
- [ ] Run focused tests to observe failures.
- [ ] Make the standard payload authoritative and adapt native lowering, preview/export/service model checks and current persistence version. Preserve journal ownership and output checks.
- [ ] Run the core suite; correct the three baseline DR200 assertions to match existing supported behavior; checkpoint/push.

### Task 3: Camera-aware editor and save validation

**Files:** Replace app `PhoneRecipeDraft.swift` and `PhoneRecipeEditor.swift`; extend `PhoneRecipeSetting.swift`; update affected draft/catalog/UI tests.

**Interfaces:** Draft `camera`, `canSave`, `isAvailable(_:)`, `isChoiceAvailable(_:for:)`, complete `choices(for:)`, semantic `makeSnapshot()`; UI binds to these shared rules.

- [ ] Write failing draft tests for retargeting, save eligibility, persistent inactive values, full grey choice domains and monotone dependency behavior.
- [ ] Implement camera first, all settings visible, disabled rows/choices, selected-invalid values, numeric temperature choices, and disabled Save until valid.
- [ ] Run `Scripts/test-ios.sh --fast` on the task device, then affected editor UI suites. Update prior assertions that expected hidden rows or save-time validation errors.
- [ ] Checkpoint/push.

### Task 4: Per-photo LMO request/effective adjustment and final verification

**Files:** Modify raw metadata/profile/output assessment and corresponding core/app fixtures/tests; add UI cross-camera tests and validation record.

**Interfaces:** Per-photo LMO support observation plus effective helper; requested recipe remains unchanged; `EffectiveRecipeReport` reports requested and effective values separately.

- [ ] Write profile-byte and output tests for LMO default On, known unsupported photo → Off, requested Off staying Off, and retained DR400 request capped by capture DR.
- [ ] Run and observe failures, then implement bounded profile changes and one-way output adjustment admission.
- [ ] Run core suite, affected UI suites, full `Scripts/test-ios.sh`; inspect UI screenshots and record actual results.
- [ ] Request a fresh whole-branch code review, fix actionable findings, rerun affected checks, checkpoint/push; delete the task simulator.
