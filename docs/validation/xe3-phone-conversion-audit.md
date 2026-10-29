# X-E3 phone conversion audit: source dynamic range and colour corruption

Date: 2026-10-29. Base: main `434b9d84`. Bookmark:
`codex/xe3-phone-conversion-audit`.

## Finding

The user's reported yellow/green cast is reproducible on the physical X-E3
through the production iPhone conversion service. The selected original RAW
and its paired original camera JPEG both record development dynamic range
200. Applying DR400 produces a severe colour cast even though the camera
accepts the profile, echoes it exactly, and writes DR400 into JPEG metadata.

A controlled DR-only comparison holds every other setting fixed. DR100 and
DR200 produce normal colour. DR400 produces the yellow/green result. At
600×400, mean RGB values are approximately:

| Requested DR | Mean red | Mean green | Mean blue |
| --- | ---: | ---: | ---: |
| 100 | 111.21 | 90.65 | 71.40 |
| 200 | 112.11 | 91.53 | 72.26 |
| 400 | 116.81 | 131.44 | 34.81 |

[Fujifilm's RAW conversion guidance](https://digitalcamera-support-en.fujifilm.com/digitalcameraengpcdetail?aid=000004643)
explicitly limits conversion DR to the capture DR or below: a DR200 capture
supports DR100/200; DR400 requires a DR400 capture. Successful profile readback
and output metadata are insufficient to establish visual correctness for a
request outside this source limit.

## Imported native bytes and camera-menu confirmation

The current camera backup stores native DR code 3 in C1–C4, C6 and C7;
our existing X-E3 decoder interprets that code as DR400. C5 stores code 1,
interpreted as DR100. Each raw value reaches the imported snapshot unchanged.
The user independently read C2's saved Dynamic Range in the physical X-E3's
EDIT/SAVE CUSTOM SETTING menu and confirmed **DR400**. That bank contains native
code 3, so this menu observation corroborates the decoder's code-3 label.
C2's DR400 value was correctly imported from the camera.

The saved recipe and a photograph's capture settings are separate values.
The controlled conversion experiment independently proves that sending literal
D185 DR400 for this DR200 RAW corrupts its colour. A valid saved DR400 recipe
can therefore exceed a particular photo's conversion limit. The history of why
a current bank setting differs from this earlier capture has not been established.

All seven decoded recipe settings were independently reconstructed from the
actual 5660-byte backup using the model's current literal field positions,
lookup tables, Kelvin indices and shared WB offsets. They match the
application's requested settings under those mappings. The complete shared WB
table and saved bank regions were unchanged before/after the audit.

## Physical protocol and metadata coverage

A disposable DEBUG runner used the exact Photos RAW from the user's latest
X-E3 preview, verified its checksum, and retained its paired original camera
JPEG. It called the shipping `FujiCameraService` and X-E3 adapter/working-profile
logic. A temporary instrumentation hook retained the backup bytes already read
by the normal importer; it added no additional camera command or setting write.

The physical X-E3 (firmware 1.30) completed 104 controlled conversions:

- Seven current camera recipes and one neutral reference.
- Two recreations of the original camera JPEG's capture settings.
- All nine supported WB modes, with explicit tagged shifts.
- All 31 native Kelvin presets.
- Red/blue shift endpoints and zero.
- All nine colour and high-ISO noise-reduction levels.
- Highlight/shadow and sharpness boundaries and zero.
- DR100/200/400 and all three grain strengths.
- All 15 X-E3 film simulations, including monochrome/ACROS filters.

Every result was 6000×4000 FINE with the source orientation. An independent
ExifTool/profile audit checked 1064 actual JPEG metadata values and 1282
profile words; all matched their requests. All complete profile readbacks
were exact. Each owned output was cleaned up, the camera banks and shared
WB table were preserved, and native closure was confirmed.

These are protocol/metadata results. The unsupported DR400 cases fail visual
fidelity despite passing those checks. Film, WB, Kelvin and individual-control
sweeps used a source-compatible neutral DR100 base.

## Original-JPEG comparison

The original capture is Classic Chrome, Auto WB, R+3/B−4, colour +4,
highlights/shadows −1, DR200, NR−4, grain Off. Reconstructing these settings
through the phone's conversion path produces nearly the original image:

| Comparison to original JPEG | Mean absolute RGB error (0–255) | Mean signed channel shift |
| --- | ---: | --- |
| Matching original settings | 1.26177 | Each channel below 0.0005 |
| Independent repeat | 1.26188 | Each channel below 0.0006 |

The small high-frequency residual is distinct from the large colour shift in
DR400 recipe conversions. The original camera JPEG and matching-settings
conversion look alike; C2 and C4 at DR400 have the obvious yellow/green cast.
Private contact sheets retain that comparison and the DR-only isolation.

## Conversion policy after the audit

The user selected `conversion DR = min(capture DR, recipe DR)` and explicitly
required the recipe to remain applicable. The implementation reads capture DR
from the RAF's embedded original JPEG and limits the X-E3 and X-T5 working
profiles for each conversion. JPEG validation expects that effective DR while
render provenance retains the original requested settings and records effective
DR. Saved camera/phone recipes and their digests are unchanged.

Missing, malformed or unrecognized capture DR falls back to DR100, which stays
within every supported capture's limit without failing recipe application.
Conversion support versions change so older cached renders cannot be reused;
the X-E3 native recipe format identifier remains stable.

The normal signed Release app was restored and launched after the temporary probe.
The full simulator suite remains deferred at the user's request. No new
full-suite pass is claimed by this audit. Private RAFs,
JPEGs, full backups, source identifiers, journals and disposable instrumentation
remain in ignored `.build`; only this sanitized report is committed.

## Source-safe recipe follow-up

Seven additional physical conversions used temporary copies of the imported
recipes with DR limited to the capture value: C1–C4, C6 and C7 used DR200;
C5 retained its requested DR100. Saved camera/phone recipes were not edited.
All other requested settings and candidate profile bytes remained identical.
Independent checking passed 71 JPEG metadata values and 86 profile words.
The strong yellow/green cast disappeared. C1 remains deliberately warm under
its 7100 K request; this is distinct from the unsupported-DR corruption.

The temporary C3/DR200 result nearly reproduces the original camera JPEG:
MAE 1.26207/255, mean signed RGB approximately (+0.00060,+0.00024,+0.00049).
All four full camera backups across both audit runs are byte-identical.

A fresh read-only reviewer independently reproduced the 104-case and seven-case
checks and confirmed the DR-only causal isolation. Its evidence concern about
the native code-3 interpretation was subsequently resolved by the user's C2
camera-menu check above. No broad visual-fidelity claim is made for every WB
mode merely from metadata matching.

## Implementation verification, 2026-10-30

- 78 focused core tests passed across nine suites, including all explicit
  capture/recipe DR combinations, fallback handling, effective-DR JPEG validation,
  requested/effective provenance and successful service completion/cleanup.
- The exact original RAF from this audit was read by the production parser:
  capture DR200 was recovered, requested DR400 stayed intact, and its working
  profile carried effective DR200.
- 105 focused iOS unit tests passed across nine suites. One affected editor UI
  test passed, saving/reopening the now-convertible X-T5 DR200 choice.
- Fresh review identified an old pinned-export path that bypassed render-version
  invalidation. A regression first reproduced the stale save. The fix durably
  requeues unsubmitted old-version exports and releases unreferenced old pins;
  the regression and export suites pass. Already submitted/unknown Photos
  transactions retain their reconciliation semantics.
- A new live phone probe of unchanged C2/C5 stopped during connection with
  `unsupportedContext`, before any conversion. It is not counted as physical
  verification of the new automatic policy. The earlier physical DR-only and
  source-safe recipe tests remain the colour-fidelity evidence.
- Temporary probe source was restored. The signed Release app built, passed
  strict/deep signature verification, and was installed/launched normally on the
  phone. Full simulator/UI-suite validation remains deferred by the user.

The implementation was rebased onto main `48301bd7` to include the newer RAW-metadata filter/cache work. Capture DR is available through both full preparation and metadata-only inspection. Metadata parser-cache version 2 discards records created before capture DR was recorded. Regression tests first reproduced legacy-cache reuse and invalid DR in decoded metadata, then passed after cache invalidation and safe DR validation at use. The combined core, iOS and affected UI checks above ran after this integration.
