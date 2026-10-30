# Standard recipe storage and camera-aware editing

The request is stored independently of native camera properties. Every recipe has a complete standard setting dictionary and an explicit target camera. Native bytes and import context remain evidence/provenance. Standard payloads are mandatory; this change does not introduce legacy-native fallback decoding or silently clear an incompatible catalog.

Defaults include Lens modulation optimizer On, Fine+RAW image quality, and Lossless compressed RAW recording. Camera changes retain all values, including unavailable fields and selected invalid steps. The editor shows the complete domain with disabled rows/actions, and disables Save until all active available settings are valid. Inactive monochromatic colour, Kelvin, grain size, and DR/tone dependencies retain their values.

Camera-valid values outside implemented conversion support may be saved. Conversion refuses active unsupported processing values with the setting name and requested value. It does not silently drop Long exposure NR On, Adobe RGB, HEIF, active nonzero monochromatic colour, or other unimplemented requests. ISO and RAW recording are capture intent and cannot alter an existing RAF.

## Native mapping audit

The official [X-T5](https://fujifilm-dsc.com/en/manual/x-t5/menu_shooting/image_quality_setting/) and [X-E3](https://fujifilm-dsc.com/en/manual/x-e3/menu_shooting/image_quality_setting/index.html) manuals establish the camera domains. Menu availability, bank importability, and conversion support are separate.

The pinned [native block-builder analysis](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/reverse-engineering/xrfc-value-tables.md) identifies X-T5 D18E as size/aspect, D18F as quality, D1A3 as LMO, and D1A4 as colour space. Its [property reference](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/properties.md) covers DR Priority, monochromatic axes and Smooth Skin in the existing bank block.

The size table is represented semantically as Small/Medium/Large plus aspect. Existing measured D18E=7 corresponds to Large 3:2. Quality 1–5 is mapped to RAW, Fine, Normal, Fine+RAW, Normal+RAW through the documented live/slot correspondence and the primary [libgphoto2 table](https://github.com/gphoto/libgphoto2/blob/5f55706807397169f7d5deb7b16ff043f4ca4073/camlibs/ptp2/config.c#L1523). That correspondence is a source-backed inference; it is not a new hardware sweep.

Offline examination of installed official X RAW Studio 1.27.0 `XRFC.dylib` confirms its initialized LMO table On=1/Off=2 and colour-space table sRGB=1/Adobe RGB=2. Binary SHA-256: `84a397c29e79c373b84e80ec1ca759c3482b477f33882355f4d70dbe15e23098`. No camera methods were called for this examination.

Known import gaps are explicit:

- X-T5 RAW recording and JPEG/HEIF are bank-saved but absent from the currently exposed 23-property response. They start at the standard defaults and the editor discloses that they were not read.
- The X-E3 bank-saved ISO backup offset is not verified. It is stored as an unresolved selection; users must choose a value before saving an edited phone recipe. It does not prevent applying the other settings to an already captured RAF.
- Settings not stored in a model's bank are defaults, not fabricated per-bank readings. Unknown selectors actually present in native data remain invalid until replaced.

## Source-dependent lens optimizer and DR

Capture MakerNote 1045 records the original LMO state. It must not be used to infer whether the RAF supports enabling LMO later.

The official native binary's ARM64 parser maps MakerNote 4534 to per-image storage at offset CB0. `ImageClass::GetExifShootingCondition` tests that field separately; scope 1 enables the model's On/Off list and the other scope offers Off only. The capture state is stored independently at 9A6. A synthetic MakerNote passed through the native parser confirmed that a type-5, count-3 payload preserves its first 64-bit word. The app reads recognized flags 0/1 from that bounded payload; missing, malformed and unfamiliar flags remain unknown. This is static native-code evidence plus synthetic parser verification, not corroboration against a newly measured physical RAF.

A recognized unavailable source caps an On request to profile Off. A recognized available source may enable LMO even when captured Off. For unknown availability the request is preserved, and JPEG output may establish a one-way On-to-Off adjustment. Requested Off can never be admitted as effective On. The saved request remains unchanged and effective reports retain both states.

DR behavior remains the existing cap by capture DR, with missing/unrecognized capture DR using 100. A stored DR400 request therefore remains DR400 while a DR200/DR100 photo produces at most DR200/DR100.

## Verification record

- Core baseline: 138 tests, three stale assertions that X-T5 DR200 was unsupported. Related assertions now exercise DR Auto instead, retaining unsupported-domain coverage.
- Standard schema/import/projection and draft tests were added before implementation. Missing interfaces and behavioral failures were observed before their fixes.
- Fast iOS iteration: 543 Swift Testing tests and 19 XCTest cases passed before final review. The updated final suite includes the additional unresolved-ISO regression.
- Explicit affected UI run: all 13 existing editor/model cases passed, including large text, landscape, temperature editing and save/reopen.
- Both new UI cases passed: retained invalid half-step and blocked Save when retargeting, plus retained monochromatic colour across film changes. The first run exposed native Picker's selected-disabled entry still being enabled; explicit disabled Menu actions fixed it and the regression passed.
- Fresh independent branch review found four Important issues: captured-state LMO inference, unread X-E3 ISO, ignored Long exposure NR On, and generic conversion refusals. Four regression tests first failed with five assertions; the fixes pass in the complete 159-test core suite, including synthetic availability parsing and one-way output checks.
- Laptop consumer: six tests passed after correcting its existing fixture to declare capture DR400, matching the DR400 JPEG it supplies. Missing capture DR correctly caps conversion to DR100 and must not be excused by test data.
- The first complete iOS run reported 635 passes, three failures and three existing gated skips (641 unique cases). Two tests still expected pre-review behavior: a mixed-model save had not explicitly selected unread X-E3 ISO, and a workspace assertion expected a generic refusal. The remaining UI test attempted a clipped White Balance menu entry. Updated the expectations and scrolled that menu entry into view.
- Main `5b57f92b` (PR #42) merged without conflicts. The focused integrated rerun passed all 42 relevant unit tests and the previously failing White Balance UI case.
- The second complete run reported 652 passes, one White Balance UI failure and three gated skips (656 unique cases). Its hierarchy showed a keyboard obscuring the menu. Menu gestures were bounded to the visible upper portion because iOS reports content extending beyond the screen; the focused regression passed. Meanwhile main `69a1e122` (PR #43) landed a separately reproduced fix for this delayed-keyboard race. Its explicit Name keyboard setup/dismissal and unchanged-name assertion are integrated here, preserving the standard-domain, save/reopen and conversion assertions.
- The third complete run, with four parallel workers, passed White Balance and every existing editor/model case. It reported 652 passes, one new monochromatic-colour UI failure and three gated skips. The recording shows the same late Name keyboard covering the film menu; the test subsequently selected the film and passed all monochromatic state/value assertions. Added the verified explicit keyboard setup/dismissal and unchanged-name assertion to that new test. All three focused parallel regressions passed: monochromatic colour, cross-camera validation and White Balance. The final complete run is pending. No physical iPhone installation or new camera conversion sweep is claimed.

## Implementation rulings

1. Use Jujutsu equivalents and a task-local ignored ledger instead of Git-based skill helpers, honoring the repository's exclusive Jujutsu workflow.
2. Integrate native import with the mandatory snapshot payload in Task 2 rather than exposing a disconnected import helper in Task 1; no behavior/scope change.
3. Defaults with disclosure are appropriate for settings not returned by the USB bank response. This is distinct from a present-but-unrecognized selector or a bank-saved value with an unresolved decoder. X-E3 ISO therefore requires explicit selection. Treating all three cases as valid default readings would lose imported intent.
4. Unknown LMO availability preserves On until the camera establishes effective Off. Capture Off does not establish unavailability. Recognized source flags cap effective values without mutating the recipe.
5. UI interaction/layout is verified by simulator tests; static native mapping evidence is documented at its actual confidence; final-suite readiness depends on the final test run. These address the review's explicitly unjudged areas without claiming new physical measurements.

No Minor review findings were deferred.
