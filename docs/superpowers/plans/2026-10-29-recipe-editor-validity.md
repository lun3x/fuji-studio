# Convertible phone recipe editing

> Implement inline using the executing-plans and test-driven-development skills.

**Goal:** A phone recipe edit must not turn a convertible recipe into settings that cannot be applied.

**Design:** Remove the obsolete five-film X-T5 conversion allowlist, retain all 20 documented films, and recognize their returned JPEG metadata. Offer the intersection of editable and renderable capabilities for the remaining editor settings, including the separate grain controls. Validate the complete encoded snapshot before saving settings. Preserve existing unsupported values until explicitly replaced, allow unchanged/rename-only snapshots, and let users repair an unsupported recipe. Keep model-specific encodings, source/profile validation and saved recipes intact.

**Evidence:** The phone's current X-T5 “Bright Summer” snapshot uses film selector 3 (ASTIA), while its original uses 11 (Classic Chrome). The editor used editable capabilities, and the X-T5 converter accepts only its measured film subset. The latest two edited revisions used Velvia and ASTIA, both outside that subset.

**Approach:** Correct the converter’s film domain using the documented selector/profile values and verify ASTIA on the connected X-T5. Filter the other editor settings and enforce conversion at its save boundary. Saving then warning fails the requested invariant. ASTIA uses X-T5 recipe selector 3, conversion UInt32LE 3 at byte 541, and JPEG FilmMode 0x120; the X-E3 backup selector is separately 1.

**Constraints:** Jujutsu workspace under `/tmp`; push checkpoint commits on `codex/recipe-editor-validity`; task-specific iPhone 15 Pro/iOS 27.0 simulator; use `Scripts/test-ios.sh --fast` for iteration and the complete wrapper for final validation. No camera bank writes, automatic recipe migrations, or changes to core offline codecs.

**Review focus:** Existing unsupported recipes; grain effect changes from dormant Large; X-E3 DR Auto; partially repaired recipes; catalog persistence after a rejected save.

## Task 1: Enforce convertible editor choices and saving

Core files: `Packages/FujiCameraCore/Sources/FujiCameraCore/Adapters/XT5/XT5WorkingProfile.swift`, `Packages/FujiCameraCore/Sources/FujiCameraCore/Recipes/RecipeCodecRegistry.swift`, `Packages/FujiCameraCore/Sources/FujiCameraCore/JPEG/FujiJPEGMetadataReader.swift`, `Packages/FujiCameraCore/Tests/FujiCameraCoreTests/XT5FilmSimulationTests.swift`.

Editor files: `FujiStudio/Recipes/PhoneRecipeDraft.swift`, `FujiStudio/Recipes/PhoneRecipeEditor.swift`, `FujiStudioTests/Recipes/PhoneRecipeDraftTests.swift`, `FujiStudioTests/Catalog/CatalogTests.swift`, `FujiStudioUITests/PhoneRecipeEditorTests.swift`.

- [x] Add failing regressions: every offered choice produces renderable settings; all 20 documented film selectors produce correct conversion words and matching JPEG metadata; DR200/unsupported WB/grain edits are refused; X-E3 excludes DR Auto; a partial repair cannot save; rejected catalog update leaves the original recipe intact.
- [x] Run focused draft/catalog tests and verify behavioral failures.
- [x] Filter `choices(for:)`, derive grain strength/size choices, keep effect transitions inside the convertible domain, validate changed values for rendering and assess the complete encoded snapshot before returning it.
- [x] Update native pickers to offer only those choices and label existing unsupported values without offering them as new edits. Keep invalid-temperature feedback and existing rename behavior.
- [ ] Update old tests that required saving unconvertible choices. Run focused unit and editor UI suites; checkpoint and push using Jujutsu.

## Task 2: Verify and deliver

- [x] Start complete `Scripts/test-ios.sh`; stop at the user’s explicit request and defer completion. Run only focused film/workflow checks afterwards.
- [x] Request an independent read-only review of the complete change, address substantive issues and verify any fixes.
- [x] Record results, commit and push the final checkpoint; shut down and delete the simulator. Deliver the cause, repair steps for Bright Summer and the reviewable change.

## Added verification requested by the user

- [x] Run a controlled physical X-T5 conversion for each of the 20 film simulations.
- [x] Independently inspect every exact profile readback and returned JPEG film/filter metadata.
- [x] Confirm full-resolution FINE output, cleanup, preserved camera banks and native closure.
- [x] Restore the normal Release app, record focused workflow results, push the evidence checkpoint and clean up task resources.
