# Convertible phone recipes and X-T5 ASTIA

Date: 2026-10-29. Development bookmark: `codex/recipe-editor-validity`.

## Cause and change

The phone's edited X-T5 “Bright Summer” recipe correctly stored ASTIA as
selector 3 in D192. Conversion refused it locally because the X-T5 working
profile still admitted only the five films in the original test collection.
The failure occurred before any conversion request reached the camera.

The converter now accepts all 20 documented X-T5 film selectors, retaining
their existing native encodings. JPEG FilmMode recognition includes ETERNA,
Classic Neg., ETERNA Bleach Bypass, Nostalgic Neg., and REALA ACE. The support
version advances to v4. Existing saved recipes are reassessed without rewriting
their settings or historical export snapshots.

The editor offers the intersection of editable and convertible choices for
each model. It derives grain effect/size choices from the supported combined
values. Settings saves validate both changed values and the complete encoded
snapshot before catalog mutation. Existing unsupported imports can still be
left unchanged or renamed; settings changes require a complete repair.

This film expansion does not establish new DR Auto/DR200, custom WB, or grain
conversion mappings. Those independent limitations remain enforced rather
than allowing new edits that the converter will refuse.

## Separate encodings

| Representation | ASTIA value |
| --- | --- |
| X-T5 recipe property D192 | UInt16LE 3: `03 00` |
| X-T5 D185 profile, byte offset 541 | UInt32LE 3: `03 00 00 00` |
| X-E3 native backup film selector | UInt8 1 |
| X-E3 conversion film word | UInt32LE 3 |
| Fuji JPEG MakerNote FilmMode, tag 1401 | UInt16 0120 hex |

The selector table is documented in
[Fuji PTP Recipes](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/properties.md#film-simulation-0xd192).
The profile enum independently gives ASTIA as 3 in
[libfuji fp.h](https://github.com/petabyt/libfuji/blob/3328efc51f74d754f8fa76af70c6becdde62271f/fp/src/fp.h).
That libfuji revision marks newer film constants 18–20 as guesses; the
documented recipe table corroborates their selector values. JPEG values come
from [ExifTool 13.55 FujiFilm.pm](https://github.com/ExifTool/exiftool/blob/13.55/lib/Image/ExifTool/FujiFilm.pm).
These are distinct formats; no EXIF value is sent as a camera film selector.

## Physical X-T5 verification

The first attempt found no camera and stopped with zero conversions and
confirmed native closure. After the user explicitly connected the X-T5, a
controlled run used the exact saved ASTIA “Bright Summer” snapshot and the
existing production camera service. Disposable DEBUG instrumentation lived
in a separate Jujutsu workspace and is excluded from the shipping change.

All three A–B–A conversions completed on X-T5 firmware 4.31 / X-T5_0200,
using two retained, distinct original RAW photos. Each output was
7728×5152, orientation 8, FINE. All requested profile readbacks matched
exactly; the word at byte 541 was 3. Independent ExifTool inspection of
each downloaded JPEG returned FilmMode 288 decimal / 0120 hex (ASTIA).
Output cleanup and native closure were confirmed; before/after imported
camera banks matched. The existing requested LMO ON → effective OFF lens
adjustment was reported by all three outputs and accepted by the service.

This is direct ASTIA hardware evidence, not a claim that all 20 film choices
were individually exercised on the physical camera. All 20 have literal
conversion-word and JPEG metadata tests, including monochrome/sepia filters.
Private photos, profiles, identifiers, source bindings, and journals remain
in ignored `.build/RecipeEvidence`.

The final signed Release bundle passed `codesign --verify --deep --strict`,
was installed on the paired iPhone, and launched normally without fixture or
probe arguments. The saved recipe's ASTIA setting was retained.

## Automated verification

- Six editor/catalog regressions first reproduced unsupported choices,
  invalid full-snapshot saves, and unsafe grain combinations.
- Film tests separately reproduced the old allowlist and missing JPEG modes.
- Core package: 126 tests passed.
- iOS unit iteration: 532 Swift Testing tests passed; native XCTest results
  and complete UI validation are recorded in the final checkpoint below.
- Independent read-only review: no actionable correctness findings. Its
  monochrome coverage limitation was addressed with explicit tests for all
  nine monochrome/sepia variants; the core suite passed again afterwards.
- Complete iOS suite: running at this checkpoint.
