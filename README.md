# Fuji Studio

An iOS app for developing Fujifilm RAW photos with a connected camera's own
conversion engine and saved profiles.

The initial target is a Fujifilm X-T5 connected over USB-C to an iPhone 15 Pro.

## Design specification

Read the [initial product and technical specification](docs/superpowers/specs/2026-10-26-fuji-studio-design.md)
for the approved interaction model, source/version handling, export behavior,
recommended architecture, and device acceptance criteria.

The [self-contained interaction prototype](docs/superpowers/specs/assets/fuji-studio-prototype.html)
can be opened locally in a browser. Camera operations, recipe effects, and exports
in the prototype are simulated.

The [implementation plan](docs/superpowers/plans/2026-10-26-fuji-studio-implementation.md)
sets out the hardware feasibility gates, native app tasks, and acceptance checks.

## Initial scope

- Import existing conversion profiles from the connected camera.
- Access photos already imported into the iPhone's Photos library using an SD
  card reader.
- Support both standalone RAW photos and paired RAW+JPEG library items.
- Use the original RAW component of a paired RAW+JPEG item for camera conversion,
  without requiring the user to separate or re-import the pair.
- Select multiple photos, including a mix of standalone RAW and paired RAW+JPEG
  items, and apply the same camera profile to the entire selection in one batch.
- Apply an imported profile through the connected camera's conversion engine.
- Preview recipes, compare original and saved versions, and export the viewed
  photo or a batch as new Photos assets with the original capture dates.
- Browse through a vertically scrolling, expandable photo drawer and choose
  recipes from a floating menu using Apple's Liquid Glass design language.

## Outside the initial scope

- Editing profile settings.
- Creating new profiles.

## Status

The native workspace composes the real Photos reader/writer, X-T5 camera
service, preview/export coordinators and durable local catalog. The current code
at `86eacb7a` passed the complete simulator gate: **433 passed, 3 established
native-gate skips, 0 failures**, exit 0. Its unsigned Release simulator build
passed for arm64 and x86_64, exit 0. The final scoped review approved all five
integration corrections with no new findings:

- Persisted failed, cancelled and unprocessed jobs remain visible after restart
  for explicit remaining-only Retry or Resume, preserving confirmed saves.
- Preview failures keep the matching image and version label with an actionable,
  accessible error, or resolve the current source's original without a camera retry.
- All works directly from Browse and selects the complete eligible membership.
- Detected incompatible RAW models affect selection and export admission across
  same-revision reloads; changed originals are reassessed without eager downloads.
- Obsolete original preparation is cancelled and reports progress, while admitted
  native camera work retains ownership until completion and cleanup.

Software review is clear; the branch remains unmerged. The controller signed,
verified and installed exact `86eacb7a` on the phone. A normal launch attempt
while locked timed out. After the user unlocked and opened Fuji Studio, the
controller directly observed the normal library UI with live thumbnails. This
confirms launch and library loading only; current-code interaction, conversion
and export acceptance remain open.

The earlier physical preview/export/reopen evidence belongs to reviewed
`75fbd61b`. The controller completed seven temporary same-source recipe previews
without new Photos assets, then one deliberate C7 export of the viewed paired
source. On-device checks verified a distinct asset, exact preview bytes, source
capture date, absent location preserved, unchanged originals/banks and native
closure. Relaunching with the same run ID reopened the exact saved version
without another export. Independent offline verification passed **156
assertions**; all seven new standalone previews matched their own Mac recipe
reference in exposed metadata/coding tables and ranked it nearest spatially.

The earlier software chronology remains a 419-pass complete gate with 3 skips,
followed by reviewed DEBUG corrections with 42 and 17 targeted test functions;
these are separate from the current complete gate above. Later ordinary-app
checks on `75fbd61b` exercised selection, drawer expand/collapse,
Zoom+/Fit/double-tap, recipe preview/manual RAW switching and No Recipe clear,
without another export. The user confirmed real finger range selection, main
photo pinch zoom/pan and expanded-grid vertical scrolling on that revision.

Final device acceptance remains **incomplete**: current-code physical validation,
real interruption recovery, limited/nonlocal Photos, Photos chronology UI, nonnil
GPS preservation, precise image-region/detail preservation, rotation and
accessibility, broader RAW/camera support, and a measured mixed batch of at least
50 sources remain open. The retained native observations cover two inputs on
X-T5 firmware 4.31; they do not establish general compatibility or pixel equality.
See [the acceptance record](docs/validation/acceptance.md) for the evidence
boundaries and [device-gates.md](docs/validation/device-gates.md) for chronology.

## Development

Use Jujutsu (`jj`) for version control. If Python tooling is needed, use the
project's `.venv` rather than a global Python environment.

## Build and test

Requires Xcode 27.1 (verified toolchain 27A9275), iOS 27+, and XcodeGen 2.46.0 (`brew install xcodegen`). No runtime packages are used.

```sh
Scripts/test-ios.sh
Scripts/test-ios.sh FujiStudioTests/RawResourceSelectorTests
```

The script generates the ignored `FujiStudio.xcodeproj` and shared `FujiStudio` scheme, uses `.build/DerivedData` and timestamped `.build/TestResults/*.xcresult`, and disables signing for simulator destinations. The observed simulator was iPhone Duo, iOS 27.1. Select an available destination on your machine:

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' Scripts/test-ios.sh
```

For an unsigned Release simulator build:

```sh
xcodegen generate
xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The test wrapper accepts one optional selector. For several suites, use direct
`xcodebuild test` with a separate `-only-testing:` argument for each. Native
Home, hardware-keyboard and rotation tests are explicit, unverified opt-ins;
the shell must forward `TEST_RUNNER_FUJI_STUDIO_NATIVE_LIFECYCLE=1`,
`TEST_RUNNER_FUJI_STUDIO_NATIVE_KEYBOARD=1` or
`TEST_RUNNER_FUJI_STUDIO_NATIVE_ROTATION=1` to the XCTest runner. Default skips
are reported, never counted as device passes.

For a physical device, supply a locally authorized development team in ignored `Config/Signing.local.xcconfig` (`DEVELOPMENT_TEAM = YOUR_TEAM_ID`) and use Xcode's local signing workflow. Physical destinations do not disable signing. The bundle ID is `com.lun3x.FujiStudio`; no account or provisioning changes are performed by the test script.

## Original-resource boundary

`PhotoLibraryReading` passes Sendable records and local file URLs, never PhotoKit objects. Source discovery is metadata-only, ordered by effective Photos capture date descending and identifier ascending, and streams batches of up to 64 sources. `allEligibleSources()` completes that discovery without downloading originals. Each original RAF+JPEG pair remains one source. JPEG-only assets remain inspectable by ID for saved-version viewing, but do not enter source discovery.

Only primary/alternate original roles qualify; content types distinguish RAF, JPEG and other RAW formats. A selected resource streams to a unique temporary file with iCloud progress, SHA-256 and cancellation/error cleanup. The caller owns and removes a successful local file. Missing originals and network failures remain preparation errors.

`RAFMetadataReader` verifies the file hash, RAF framing, X-T5 model, embedded JPEG model/orientation, and recorded RAF geometry without RAW pixel decoding. It keeps sensor/container dimensions separate from recorded crop dimensions and aspect. Synthetic metadata fixtures test parser branches; broader compression and geometry support still require device evidence.

## Camera and foreground operation

Connect the X-T5 by USB data cable and select **USB RAW CONV./BACKUP RESTORE**
on the camera. The observed support context is X-T5 firmware **4.31**. Import
reads the existing C1–C7 names/settings; the app has no saved-bank editor.
Conversion fails closed outside the measured supported profile/source class.
The observed full-size 3:2 outputs are FINE **7728 × 5152**, encoded orientation 8.
The retained standalone input is lossless-compressed 14-bit. Other compression,
aspect, firmware and lens classes need separate evidence. Requested lens
modulation optimization was source-adjusted to effective OFF in the observed
runs; there is no universal ON guarantee.

Keep the app foreground and the phone/camera connected during USB work. Exports
freeze the submitted sources and recipe, then process sequentially. Background
or disconnect can pause work; confirmed outputs remain, and unconfirmed saves
must reconcile before any replacement. Real interruption acceptance is still
pending. Previews do not invoke Photos saving. Export creates separate JPEG
assets with the original effective Photos capture date and available location;
Photos controls equal-time tie order.

## Hardware probe

Normal launch opens the live workspace. DEBUG-only fixture/probe routes are
explicit launch modes, isolated from normal and Release launch. Use only the
reviewed probe appropriate to its recorded gate; several historical diagnostics
perform bounded camera operations. No real source IDs, profiles or images belong
in version control.

Task13 adds the explicit `--live-acceptance-run <UUID>` route for the controller's
reviewed physical validation. It uses the same live environment/model and real
coordinators, binds the unique retained standalone A and paired B manifests,
checks current C1–C7 imports, makes seven temporary A previews, then makes one
deliberate C7 export of viewed B. A durable UUID claim is written before export.
Reusing that UUID can only reconcile/verify; missing or ambiguous job identity
stops without another save. Keep the run directories and catalog intact. Never
use a new UUID as an automatic retry. Release excludes this route and driver.

Private evidence stays in the app's `Documents/live-acceptance-private` and
ignored local `.build`/`.superpowers` artifacts. Public summaries contain only
counts, booleans and dimensions. The recorded run followed independent software
review and an exact reviewed build/install. A first unarmed attempt stopped on a retained-manifest schema
mismatch before any camera operation or export; its consumed run was preserved.
After the reviewed correction, the controller explicitly chose a new run. Total
Photos exports across those attempts: one. This route does not measure the
50-source performance corpus or establish native Home, rotation, VoiceOver, or Photos chronology UI.

API references: [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [Apple ImageCaptureCore authorization requirements](https://developer.apple.com/documentation/imagecapturecore), and the installed iOS 27.1 Photos/PhotosUI headers. RAF tag/layout research was checked against [ExifTool's FujiFilm parser](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/FujiFilm.pm); no third-party code or runtime dependency is included.
