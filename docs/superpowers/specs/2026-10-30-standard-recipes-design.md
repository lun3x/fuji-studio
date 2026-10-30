# Standard recipes across camera models

Status: implementation design, incorporating the user's full-inventory scope and subsequent default/per-photo corrections.

## Intent

Store recipes as camera-independent, explicit semantic settings so the same recipe can be adapted for another supported camera without losing its values. Camera-specific wire encodings belong at import and application boundaries. The selected camera controls availability and validity, rather than the shape of the saved recipe.

The user's requested behavior is authoritative: every setting has a default; importing fills available settings; the editor starts with a camera selector; unavailable settings and choices remain visible and disabled; switching cameras preserves selections even when they become invalid; Save stays disabled until every available setting is valid; unavailable settings do not block saving and are omitted when applying.

## Current implementation and constraints

`RecipeSnapshot` stores native property blocks and a digest of those bytes. X-T5 and X-E3 codecs decode different property IDs and encodings. Phone editing patches those blocks and uses the import camera context as the target. Consequently a phone recipe cannot change camera models and keep fields that the new model cannot encode.

`RecipeCodecRegistry` and `XE3Capabilities` already describe model-specific choices, numeric steps, and separate editable and renderable domains. The editor currently hides absent settings and filters out choices that cannot be converted. These are useful capability sources, but they must no longer define which values can exist in storage.

Only X-T5 and X-E3 are currently supported, with existing firmware/profile verification. RAW admission still requires the source photo to be supported by the connected camera. Sharing recipe settings does not add cross-model RAW conversion.

Use Jujutsu exclusively, work under `/tmp/fuji-studio-standard-recipes-20261030`, and push checkpoints to a dedicated `codex/standard-recipes` bookmark. Use an isolated task simulator for iOS validation and delete it afterwards. No legacy payload compatibility or new camera/firmware support is included.

## Approaches

1. **Complete semantic recipe plus camera capability profiles (recommended).** Persist all values independently of camera support and translate only at the boundaries. This directly supports preservation across camera changes, disabled controls, and consistent validation.
2. **Continue storing native blocks and translate when changing cameras.** This needs a second store for unsupported values and makes original bytes, translated bytes, and retained values compete as sources of truth. It does not provide the standard storage the user requested.

The first approach follows the requested storage model. The precise Swift type names and internal decomposition remain implementation choices.

## Complete setting inventory

Audit the still-image recipe/image-quality settings of both supported models, rather than equating the existing editor with the complete recipe. Include these additional fields in the standard schema, editor, capability profiles, import audit, and tests:

| Additional field | Global domain | Default |
| --- | --- | --- |
| D Range Priority | Off, Weak, Strong, Auto | Off |
| Monochromatic colour, warm/cool and magenta/green | Independent signed axes, −18…18 | 0 / 0 |
| Smooth skin | Off, Weak, Strong | Off |
| Long exposure noise reduction | Off, On | Off |
| Lens modulation optimizer | Off, On | On |
| Colour space | sRGB, Adobe RGB | sRGB |
| Image size and aspect | Large/Medium/Small; 3:2, 4:3, 16:9, 5:4, 1:1 | Large, 3:2 |
| Image quality | Fine, Normal, Fine+RAW, Normal+RAW, RAW | Fine+RAW |
| RAW recording | Uncompressed, Lossless compressed, Compressed | Lossless compressed |
| Output format | JPEG, HEIF | JPEG |
| ISO selection | Camera-supported fixed levels and Auto 1/2/3 | Auto 1 |

The [X-T5 image-quality manual](https://fujifilm-dsc.com/en/manual/x-t5/menu_shooting/image_quality_setting/) establishes its additional processing/output controls and their domains. Its HEIF mode disables clarity and requires sRGB; active D Range Priority takes control of DR and tone. Represent those dependencies without overwriting retained settings.

The [X-E3 image-quality manual](https://fujifilm-dsc.com/en/manual/x-e3/menu_shooting/image_quality_setting/index.html) supplies the smaller domain and explicitly lists ISO among saved custom settings. Its image-size aspects are 3:2, 16:9, and 1:1, and its RAW recording lacks the lossy Compressed option. The [X-E3 ISO manual](https://fujifilm-dsc.com/en/manual/x-e3/menu_shooting/shooting_setting/index.html#iso) documents fixed sensitivities, extended levels, and Auto presets. Store Auto selection as a camera preset reference, not fabricated frozen exposure parameters.

Interpret recipe scope as saved still-image rendering/output settings and capture settings explicitly saved with those recipes. Pixel mapping, bank-management actions, autofocus, connection preferences, and per-lens mount-adapter calibration are not recipe values. Verify the per-bank subset separately from global image-quality settings; a global camera value must not be mislabeled as a value read from every bank. ISO is retained capture intent and cannot change an already captured RAF. RAW recording likewise describes capture intent rather than recompressing the source during JPEG conversion.

For the broad inventory, distinguish physical camera support, bank import support, offline editing, and conversion support. A setting supported by the camera but not yet decoded by this app remains represented and its read status must be explicit. A bank-saved value that cannot be decoded is unresolved and requires explicit selection before saving, as for X-E3 ISO. Settings absent from the exposed USB bank response, such as X-T5 RAW recording and output format, use canonical defaults with a visible import notice; they must not be described as camera readings. Values absent from a model or not stored in a bank use the canonical default.

Custom 1/2/3 white balance references are valid camera choices on both models. They refer to the target body's measured slot; they do not imply portable measured gains. Preserve any captured calibration evidence, but conversion remains unavailable if the application cannot reproduce the requested custom measurement safely. Never claim that switching cameras copies a body's measured white balance.

Published [native property documentation](https://github.com/ILFforever/fujifilm-ptp-recipes/blob/daba2d97d6b37bd1d5dbc68ca974f6b22f433071/docs/properties.md) identifies D Range Priority, both monochrome axes, and Smooth Skin in the existing X-T5 block. Its four remaining property identifications are provisional. Do not use provisional mappings or another camera's successful write as proof of X-T5/X-E3 conversion behavior. Obtain model-specific evidence for any further native mapping needed to complete import/application.

## Standard schema and defaults

Create a typed, Codable standard settings value with a complete field set. Every persisted recipe contains every modeled setting; absence is represented by a camera capability, not `nil` in recipe storage. Keep grain strength and grain size independently addressable so an X-E3 can apply grain strength while omitting size.

Initial fields and proposed defaults:

| Setting | Default |
| --- | --- |
| Film simulation | PROVIA / Standard |
| Dynamic range | 100% |
| Grain strength / size | Off / Small |
| Color Chrome / Color Chrome FX Blue | Off / Off |
| White balance | Auto |
| Red / blue shift | 0 / 0 |
| Temperature | 5000 K |
| Highlights / shadows | 0 / 0 |
| Colour / sharpness / noise reduction | 0 / 0 / 0 |
| Clarity | 0 |
| Additional settings | Defaults from the inventory above |

DR100 and 5000 K are neutral, valid shared values in the existing supported domains. The user specified Lens modulation optimizer On, Fine+RAW image quality, and Lossless compressed RAW recording. Add lens optimizer's camera-domain choices as part of the full inventory.

Provide one global setting catalog with the union of known enum choices and numeric domains, explicit defaults, and stable setting identities. Camera profiles narrow that catalog using their own support flags, choices, ranges, and steps. Include the complete audited inventory above; the scope does not claim coverage of future Fujifilm models.

## Snapshot identity, import, and persistence

A recipe snapshot contains the standard settings and an explicit target camera model. Keep its immutable ID, name, original slot/copy provenance, import timestamp, and import camera context. Target camera selection must not rewrite the import camera's identity or pretend that a new live camera session occurred.

The canonical standard settings are authoritative for editing, saving, assessment, and application. Native properties may remain attached as import evidence where useful for unresolved fields or journal diagnostics, but applying an edited or retargeted recipe must not depend on decoding the old model's property block.

At import, start from defaults and overlay each known setting the importing camera provides. Unsupported options remain at defaults. Do not silently turn an undecodable value of an available setting into a valid default: retain an explicit invalid/import issue for that field, display an unavailable selection, and require a supported replacement before saving or applying. Unmapped native dependencies continue to block conversion where the adapter cannot safely reproduce their meaning.

Persist a versioned current schema and calculate the recipe digest deterministically from the target camera and the complete canonical settings, including retained inactive values. Digests must not depend on native property ordering or import-session identity. Any unresolved dependency that affects output must also be represented in assessment/cache identity; reject an incomplete conversion rather than reusing an unrelated cached result.

Copies, renames, editor saves, catalog storage, preview/export requests, operation journals, and saved-version references must preserve the standard payload. Older native-only payloads are outside this change's compatibility scope; do not add silent fallback decoders, silently erase a catalog, or reinterpret undecodable historical values as defaults. Surface an explicit unsupported-format error when encountering incompatible stored data.

## Editor behavior

Add a Camera picker as the first section of the phone recipe editor, above Name. It lists X-T5 and X-E3 and initially selects the imported camera. Existing camera-bank entries remain read-only imports; users edit their phone copies through the existing workflow.

Show every standard setting. An unavailable setting is grey and disabled but still shows its retained value. Available setting menus show the complete standard choice domain with unavailable choices grey and unselectable. For numeric domains, retain the existing descending order; profile-specific step restrictions count as unavailable values, not only out-of-range values.

Changing Camera changes capabilities immediately and never clamps, defaults, or otherwise changes a setting. If a selected value becomes unavailable, keep it selected and grey. Switching back restores its availability without requiring the user to re-enter it. This includes half-step tones, non-native Kelvin presets, film simulations, and grain size.

Save is disabled for an empty name, an invalid available setting, or an unresolved available imported value. The save operation repeats the same validation so programmatic callers cannot bypass it. Values in unavailable settings do not participate in validation. Dependent controls remain visible: temperature is inactive unless temperature white balance is selected; grain size is inactive with grain Off or a camera without grain-size support; monochrome axes require an applicable monochrome film; active DR Priority disables manual DR/highlights/shadows; output-format dependencies follow the camera profile. Inactive dependent values are retained and do not block saving. An active incompatible combination, such as a format requiring sRGB while Adobe RGB is retained, needs an explicit valid replacement and blocks Save rather than silently coercing the colour-space selection.

Distinguish the camera's editable domain from the app's conversion domain. A physically supported value may be saved when it is valid for the selected camera even if conversion is not yet implemented. Existing conversion admission continues to refuse that recipe with a setting-specific unavailable reason. This does not claim new conversion support for DR Auto, custom WB gains, unverified grain combinations, or newly modeled processing/output settings. Complete storage and editing cover the full inventory; conversion must either reproduce a requested active processing value or explicitly refuse it. Camera availability determines editor validation; conversion support remains a separate assessment.

## Applying a recipe

Require a connected supported camera matching the recipe's selected target model and a compatible RAW source. Derive an application settings view from the standard payload and the verified camera profile. Omit settings the target camera does not support, including grain size on X-E3. Do not overwrite or discard them in the saved recipe.

Each adapter maps the resulting semantic values to its own native profile words. Validate active values and unresolved dependencies before upload or trigger. Skip settings physically absent from the camera, not supported-but-unimplemented processing requests. For a supported processing/output setting that the application cannot reproduce, refuse conversion explicitly instead of ignoring it, replacing it with a fixed profile value, or returning a result with mismatched quality, size, format, or colour space. Capture-only intent is retained as such and does not claim to alter a captured RAF. Keep the current transport serialization, readback checks, output validation, dynamic-range source cap, cleanup ownership, and journal recovery guarantees.

Lens modulation optimizer has a per-photo effective value: keep the saved request On, but omit it or set Off when the particular photo cannot support it. Capture LMO Off is not proof of unavailability. Use the separate source availability flag when present and recognized; otherwise preserve the request and accept only the camera's one-way observed On-to-Off adjustment. This adjustment must not make the recipe invalid or change its stored request. Preserve the existing analogous DR cap: a DR400 request on a DR200/DR100 source produces at most DR200/DR100. Record requested and effective lens-optimizer and DR values separately. Monochromatic colour axes remain visible and grey/disabled for film simulations that do not support them, without clearing their stored values.

Changing the target changes execution eligibility throughout the chooser, previews, export coordinator, and service. Original import context remains provenance only; connection matching for execution uses the target model and the currently verified adapter profile. Advance conversion/cache support versions when the request representation changes.

## Validation

- Test that every audited standard field has a serialized default and every global choice is representable, including each newly modeled setting and the full camera-native WB domains.
- Import both camera fixtures and verify known values overlay defaults while absent options keep defaults.
- Test X-T5 → X-E3 → X-T5 without value loss, including disabled effects, grain size, film, half-step tones, and non-native Kelvin.
- Test that invalid available fields disable Save, unavailable/inactive fields do not, and selecting valid replacements restores Save. Repeat validation at persistence and application boundaries.
- Save/reopen canonical recipes after retargeting and verify stable chooser identity, revised snapshot identity, complete values, target, and original provenance.
- Inspect generated conversion bytes to prove physically unavailable settings are omitted and never leak through source-model bytes; verify that supported-but-unimplemented active requests are explicitly refused; exercise preview/export model matching and existing output/journal guarantees.
- Verify default LMO On, Fine+RAW, and Lossless compressed; test per-photo LMO Off adjustment without mutating the saved request, and the one-way rule that a requested Off cannot become On. Verify monochromatic colour controls disable on colour films and re-enable with retained values on compatible monochrome films.
- Add affected editor UI coverage for visible disabled rows, grey unselectable choices, preserved invalid selections, Save enablement, and camera switching at large text sizes.
- Run the core package tests, `Scripts/test-ios.sh --fast` during iteration, affected UI suites, and the complete `Scripts/test-ios.sh` suite on the task simulator for final validation.

The unchanged baseline core run currently reports 138 tests and three failed assertions in `XE3CapabilityTests` and `RecipeOptionValuesTests`. All three still assert that X-T5 DR200 is unsupported, whereas the current capability and working-profile implementations support it. Update those related assertions when implementing this feature without weakening the remaining unsupported-domain tests.

## Remaining implementation choices

The builder may choose the standard Swift type structure, reuse or split the existing adapter-only `RecipeSettings` projection, and choose a compact UI for large numeric choice domains. Those choices must preserve all behaviors above. Source-backed camera-domain definitions and native decoding are required for the expanded inventory. Any mapping still lacking evidence must be surfaced as an implementation limitation, not called a completed import or silently treated as an absent camera feature.
