# Independent phone grain controls

Date: 2026-10-28. Implementation: `79fe1059`, following the phone editor in PR #16.

Follow-up, 2026-10-29: the shared-adapter grain codec is corrected to write the
published 1 Off, 2 Weak/Small, 3 Strong/Small, 4 Weak/Large, and 5 Strong/Large.
Readbacks 6/7 remain preserved until grain is edited. Off stores no size: the
draft remembers it while open, but a saved Off value reopens with Small.
See [the correction record](recipe-option-values.md#grain-mapping-correction-2026-10-29).
The original implementation and verification record below is historical.

The Look section now has separate Grain effect (Off/Weak/Strong) and Grain size
(Small/Large) native pickers. Off disables and greys out the size value. The
last size survives effect changes and Save/reopen; changing size preserves
effect. All six combinations can be saved on the phone. Untouched legacy and
unknown grain values retain their original raw bytes.

The stored combined property uses 2 Weak/Small, 3 Strong/Small, 4 Weak/Large,
5 Strong/Large, 6 Off/Small and 7 Off/Large. Active values are cross-checked
against the [pinned primary protocol table](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/properties.md#grain-effect-0xd195).
The project's [measured bank/vendor observations](protocol-provenance.md)
establish the dormant size for 6/7. Legacy 1 Off remains unchanged unless edited;
Small is the editor's initial size for that size-unspecified value.

This is a saving/editing change. The camera renderer's support remains unchanged:
Off/Small, Off/Large and Strong/Small. Weak and Strong/Large recipes are saved
accurately and remain unsupported for conversion. The user requested removal of
the explanatory grain/unsupported-value footer from the form. No camera bank
write, working-profile domain expansion or new hardware
conversion experiment is included.

Verification:

- Red tests demonstrated rejected new combinations (2/4/5) and missing separate
  controls before implementation.
- All **441 Swift Testing tests and 18 native XCTest unit tests passed**. Tests
  cover six stored combinations, independent component changes, ignored size
  changes while Off, dormant size across reopen, legacy/unknown no-op retention,
  invalid values, unrelated-setting preservation and existing renderer refusal.
- All four editor UI cases passed, including independent picker choices,
  disabled-size appearance, Save/reopen, name/film/Cancel, temperature validation
  and genuine largest-accessibility text. Screenshots inspected.
- The known inactive-startup UI assertion failed in the targeted run: the actual
  prompt was “X-T5 ready for conversion.” before the injected foreground action.
  No startup/lifecycle code was changed; the prior editor record documents its
  timing-sensitive baseline/rerun behavior. The targeted five-case invocation
  therefore had four passes and one failure; it is not claimed fully green.
- One independent read-only review found no substantive issues. It verified
  storage mappings and the unchanged renderer boundary; it did not independently
  rerun tests or establish conversion fidelity for unsupported combinations.
- Full `Scripts/test-ios.sh` regression suite at `79fe1059`: **511 total,
  508 passed, 3 established native-gate skips, 0 failures**. The previously
  timing-sensitive inactive-startup case passed in this full run; no startup
  behavior was changed. Skips are native Home, physical rotation and hardware
  Escape acceptance.
- During that full run, the user requested removal of the explanatory footer.
  The final copy-only correction removes the Look footer without changing
  controls or saving behavior. All four editor UI cases passed again on that
  final form; screenshots confirm the text is gone and size remains greyed out
  while Off. The full-run result above predates this copy removal.
- Both simulator and signed iPhone Release builds passed, including rebuilds
  after the footer removal. The final exact bundle passed strict/deep signature
  verification, was installed on the connected iPhone 15 Pro and launched
  normally without fixture arguments. A device-process query confirmed the
  installed executable running.

Local results, screenshots and logs remain in ignored `.build`. The full project
wrapper is `FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=<TASK_SIMULATOR_UDID>' Scripts/test-ios.sh`.
Use a task-specific iPhone 15 Pro / iOS 27.0 simulator and delete it after checks.
