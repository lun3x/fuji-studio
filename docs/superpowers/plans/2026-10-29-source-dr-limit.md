# Per-photo Dynamic Range Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Apply every supported explicit-DR recipe using the lower of its DR and the original photo's capture DR without rejecting the combination.

**Architecture:** Parse capture DR from the original RAF's embedded JPEG. Share one effective-DR calculation between model-specific profile serialization and output validation; preserve requested settings in provenance and record effective DR.

**Tech Stack:** Swift 6, FujiCameraCore, Swift Testing, iOS 27, Jujutsu.

**Spec:** `docs/superpowers/specs/2026-10-29-source-dr-limit-design.md`

## Global Constraints

- All changes in `/tmp/fuji-source-dr-cap-20261029`; Jujutsu only.
- Keep saved recipes and settings digests intact.
- Capture DR missing/malformed/unrecognized falls back to DR100.
- Full simulator suite remains deferred; use the task's isolated simulator.

## Review Focus

- A lower recipe DR must remain lower even for a higher-DR source.
- A DR200 source with a DR400 recipe must send 200 and accept a 200 JPEG.
- Missing or unrecognized embedded DR must never cause a DR400 request.
- JPEG validation must still reject unexplained DR or other-setting mismatches.
- New conversion support must invalidate old cached renders without invalidating imported recipes.

### Task 1: Resolve and validate per-photo DR

**Files:**
- Modify: `Packages/FujiCameraCore/Sources/FujiCameraCore/Sources/RAWTypes.swift`, `Sources/RAFMetadataReader.swift`.
- Modify: `Adapters/FujiCameraAdapter.swift`, `Adapters/XE3/XE3WorkingProfile.swift`, `Adapters/XE3/XE3Capabilities.swift`, `Adapters/XE3/XE3Adapter.swift`, `Adapters/XT5/XT5WorkingProfile.swift`.
- Modify: `JPEG/CameraOutputAssessment.swift`, `Rendering/RenderTypes.swift`, `Recipes/RecipeCodecRegistry.swift` within the same source root.
- Test: package `SourceDynamicRangeTests.swift`, `XE3ServiceContractTests.swift`, and affected profile/output fixture tests; iOS `SourceDynamicRangeTests.swift` and affected profile tests.

**Interfaces:**
- `RAWMetadata.captureDynamicRange: Int?` retains the original's validated DR.
- `RAWMetadata.effectiveDynamicRange(for: Int) -> Int` resolves the minimum with safe fallback.
- `PreparedConversion.effectiveDynamicRange: Int` supplies output validation.
- `EffectiveRecipeReport.dynamicRangeEffective: Int?` records resolved conversion DR while `requested` remains unchanged.

- [x] Write a failing regression using real RAF metadata and literal expected D185 words: all nine 100/200/400 combinations for both models, plus missing/invalid capture metadata.
- [x] Run the focused tests and observe failures at the DR profile bytes.
- [x] Add capture metadata, shared minimum calculation and model profile patches; enable explicit DR200 on X-T5. Keep native recipe bytes untouched.
- [x] Add and observe failing output-validation tests: accept effective 200 for requested 400, reject unexpected 400 and unrelated setting mismatches.
- [x] Validate effective DR and retain requested/effective provenance; version conversion support independently of X-E3 recipe format identity.
- [x] Run package regression suites and focused `Scripts/test-ios.sh` selectors using isolated simulator `C190592F-4290-4012-8BF7-048649F92FC8`. Expect zero failures.
- [x] Verify service-level successful completion/cleanup for requested 400 on capture 200. Update affected fixtures to declare their intended capture DR.
- [x] Push a Jujutsu checkpoint on `codex/xe3-phone-conversion-audit`.
- [x] Request a fresh whole-change review, resolve material findings with regression tests, and update the audit record.
- [x] Build the signed Release app, verify its signature, install and launch normally on the connected phone. Update PR #40 with final scope and actual verification before the user-requested merge.

## Verification outcome

78 focused core tests, 105 focused iOS unit tests and one affected editor UI test passed. The actual private RAF parsed as DR200 and generated a DR200 profile for a DR400 request. The Release phone build and strict signature check passed; it was installed and launched normally. The additional live C2/C5 run stopped at camera connection with unsupportedContext, before conversion, and is not counted as a pass. Review's stale unsubmitted export finding was reproduced RED, fixed and verified GREEN. Full suite remains deferred.

## Integration with newer main

Main advanced to `48301bd7` with persisted metadata-only camera filtering. Preserve that parser refactor, include capture DR in its shared parsing path, bump disposable metadata parser cache to version 2, and treat unrecognized capture DR in decoded metadata as unknown. Both integration regressions were observed failing before their fixes. The final selected suites run on the combined source.
