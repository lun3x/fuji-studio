# Accept replaceable X-T5 starting settings

**Goal:** Apply the requested recipe to structurally supported X-T5 profiles even when the photo's initial processing settings differ from the original measured sample.

**Design:** Retain the exact 625-byte frame/header/padding and immutable-word checks. Exclude only the 17 four-byte words that `make` fully overwrites from starting-value comparisons. Continue to normalize the frozen requested recipe, patch every writable field, require exact camera readback, and validate returned JPEG settings. Starting values in fully replaced words cannot affect the candidate; opaque or unmodified bytes remain restricted to the observed frame. Advance support provenance to `xt5-4.31-0200-structured-frame-v3`.

The user approved this fix after the journal reproduction isolated four changed writable words. This extends the existing logging work in PR #36 and retains its diagnostics.

## Steps

- [x] Add regressions for the four observed starting values, all replaceable words, and an end-to-end render with a different starting profile. Keep rejection coverage for every immutable byte and invalid frame length/source geometry. Move the journal rejection fixture's mutation to an immutable field.
- [x] Run the focused profile/service tests; observe the new valid-starting-profile cases fail before implementation.
- [x] Skip comparisons only for fully overwritten words; update support provenance and comments.
- [x] Run focused tests, all iOS unit tests, shared-package tests, and independent review. Push the implementation checkpoint with Jujutsu.
- [ ] Run the complete iOS/UI suite on the task's isolated simulator. Build a signed Release, verify the exact bundle, install it on the user's phone, and launch normally.
- [ ] Record results, update PR #36 around the final fix and diagnostics, push the validation checkpoint, and delete the task simulator.

## Review focus

Every admitted variable byte must be overwritten before camera submission. Preserve all opaque words, count/header/padding checks, recipe-domain checks, exact readback, JPEG validation, checksums, and failure journaling. No private device profile or source identifiers enter version control.

## Implementation checkpoint

The new profile case and changed service case failed with `unsupportedProfile` before implementation in both package and iOS runs. After implementation, all 123 package tests and 517 iOS unit tests passed. Independent read-only review found no actionable issues and confirmed all 17 exempted words are fully overwritten while the remaining 557 bytes remain constrained. Physical conversion, full UI validation, and installation are separate pending gates.
