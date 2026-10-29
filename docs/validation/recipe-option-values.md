# Recipe editor option audit

The X-T5 editor previously reused the initial conversion test's restricted
selectors. Its codec understood more modes than the editor offered. Editing
capabilities now describe the full documented selector domain; rendering
capabilities continue to describe the existing validated conversion domain.

## Sources and agreement

- Fujifilm's [X-T5 still-image quality manual](https://fujifilm-dsc.com/en/manual/x-t5/menu_shooting/image_quality_setting/)
  establishes the camera's available choices and numeric ranges.
- [Fuji PTP Recipes properties](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/properties.md),
  pinned at `daba2d97d6b37bd1d5dbc68ca974f6b22f433071`, supplies the selector encodings.
  Film values 1–15 agree with all pre-existing codec mappings; values 16–20
  add ETERNA, Classic Neg., ETERNA Bleach Bypass, Nostalgic Neg., and REALA ACE.
  Its nine existing WB modes, explicit DR100/400 values, all nine non-linear
  noise-reduction values, and three effect strengths also agree.
  Added WB selectors are White Priority `0x8020`, Ambience Priority `0x8021`,
  and Custom 1–3 `0x8008`–`0x800a`. DR Auto is 0 and DR200 is 200.
  This upstream project reports all 14 WB selectors tested on X-H2 5.20;
  this change does not claim a new X-T5 hardware test.
- The pinned [libfuji profile constants](https://github.com/petabyt/libfuji/blob/3328efc51f74d754f8fa76af70c6becdde62271f/fp/src/fp.h)
  independently agree on existing films, DR200, preset/custom WB and noise.
  Some newer film constants there are explicitly marked guesses; the fuller
  property reference and camera manual are the basis for the added choices.

The external grain table conflicts with this project's measured X-T5 combined
strength/size mapping. It is **not** adopted. No existing mapping changes.

## Existing X-T5 editor fields

| Field | Editable domain | Result of audit |
| --- | --- | --- |
| Film simulation | All 20 simulations, including monochrome filters | Expanded from five |
| Dynamic range | Auto, 100%, 200%, 400% | Added Auto and 200% |
| Grain | Off, Weak, Strong × Small, Large | Already complete; preserve measured bytes |
| Color Chrome / FX Blue | Off, Weak, Strong | Already complete |
| White balance | All 14 modes | Expanded from two |
| Red / blue WB shift | −9…+9, whole steps | Already complete |
| Temperature | 2500…10000 K, 10 K steps | Corrected edit validation from 1 K |
| Highlights / shadows | −2…+4, half steps | Already complete |
| Colour / sharpness / high ISO NR | −4…+4, whole steps | Already complete |
| Clarity | −5…+5, whole steps | Already complete |

X-E3 keeps its 15 films, nine calibrated WB modes, whole tone steps, and
31 native Kelvin presets. Shared semantic enum additions must not leak into
its model-specific capabilities. Its existing native DR Auto encoding (0)
is now editable alongside 100/200/400; it remains outside validated rendering.
Custom measured WB on X-E3 still requires unresolved native gain/dependency
data and remains passively preserved.

This audit concerns values of existing editor fields. D Range Priority,
monochromatic colour, smooth skin and other fields not currently exposed in
the editor remain untouched in imported snapshots.

## Conversion and preservation limits

Published selector agreement is sufficient for offline save/reopen. It does
not establish new D185 conversion behavior. Rendering remains gated to the
existing X-T5 profile domain (five films, DR100/400, Auto/Temperature WB and
the measured grain subset). Newly editable recipes can therefore be saved
while their camera preview remains unsupported. Custom WB modes recall
measurements stored on the body; recording the mode does not freeze those gains.
No saved camera bank is modified by phone recipe editing.

Regression tests bind each documented film/WB/DR selector to literal wire bytes,
round-trip every advertised discrete choice through both model codecs, check
preservation of untouched native fields, and exercise phone save/reopen,
model isolation, Kelvin boundaries, and the Auto label. Validation results
are recorded below.

## Validation, 2026-10-29

- Baseline core suite: 101 tests passed.
- New selector tests first failed against the restricted capabilities. The phone
  tests also reproduced the old 0% Auto label and acceptance of invalid 1 K steps.
- Updated core suite: 105 tests passed.
- Focused phone draft suite: 12 tests passed, including native save/reopen and
  Kelvin boundary/step checks.
- Focused X-T5 and X-E3 editor UI tests: two passed on an isolated iPhone 15 Pro
  simulator with iOS 27.0. The X-T5 test selected REALA ACE, DR200, White Priority
  WB, Custom 3, and DR Auto, saving and reopening both edits.
- Laptop consumer package: six tests passed.
- Independent read-only code review: no actionable findings.
- Complete iOS unit coverage: 470 Swift Testing tests and 19 XCTest tests passed.
- Full iOS UI coverage: 32 passed, one existing guarded native-lifecycle test
  skipped. The full `Scripts/test-ios.sh` run passed all unit tests and 20 UI
  tests before its simulator shut down during the largest-text grain test.
  The stalled runner was interrupted; no successful uninterrupted full-run
  result is claimed. Restarting the task device and running the remaining 13
  UI selectors produced 12 passes, one skip, and zero failures. Every declared
  UI selector is accounted for across the two runs, and the interrupted
  largest-text test passed on resume.

An older invalid-value test used DR200; it now uses invalid DR300. No physical
camera test or newly validated conversion support is claimed. The isolated
task simulator was shut down and deleted after validation.
