# Phone Grain Controls Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development inline.

**Goal:** Separate Grain effect (Off/Weak/Strong) and Grain size (Small/Large); disable size when Off and remember it.
**Architecture:** Project the existing combined grain property into typed effect/size values. Draft changes encode back to the same raw property; immutable snapshot/catalog behavior remains unchanged. All six combinations can be saved. The measured camera renderer keeps its existing support checks; no unvalidated conversion mapping or hardware experiment is added.
**Tech stack:** Swift, SwiftUI, Swift Testing, XCTest.
**Spec:** The user's explicit two-control request in this conversation. Keep native menu pickers in the existing Look section.

## Task — split the grain controls

- [ ] Add failing draft tests for six raw combinations, independent changes, remembering dormant size across Save/reopen, unknown/legacy no-op preservation and invalid grain rejection. Add a UI test for picker choices, greyed/disabled size, and Save/reopen.
- [ ] Add PhoneRecipeGrain effect/size representation, draft setters and separate native pickers. Update the editor's save domain without widening the renderer domain. Preserve unknown values until an explicit user change.
- [ ] Run all unit tests, affected editor UI cases and screenshot checks; push a Jujutsu checkpoint to codex/phone-recipes.
- [ ] Complete one independent review, the full test wrapper and signed Release build/install; report any existing startup-test or runtime limitations accurately. Update PR #16 and validation notes, push and delete this task's simulator.

## Review focus

- Off retains size, including Large, in the saved raw snapshot; selecting size while Off cannot mutate the draft.
- Weak/Strong and Small/Large choices change only their own component.
- Legacy Off and unknown imports remain byte-identical on opening/no-op Save.
- Newly saveable combinations are not silently rendered with another grain strength/size; existing renderer support remains fail-closed.
- Controls preserve accessibility text size and remain usable offline.

## Encoding sources

The pinned primary protocol reference documents active combinations as 2 Weak/Small, 3 Strong/Small, 4 Weak/Large, 5 Strong/Large and legacy 1 Off. Existing measured project evidence resolves bank reads 6 Off/Small and 7 Off/Large. These are phone snapshot values, not writes to camera banks. References: pinned fujifilm-ptp-recipes `docs/properties.md` at `daba2d97d6b37bd1d5dbc68ca974f6b22f433071`, and `docs/validation/protocol-provenance.md`'s bank-to-vendor grain observations.
