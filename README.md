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

The native workspace now composes the real Photos reader/writer, X-T5 camera
service, preview/export coordinators and durable local catalog. Hardware evidence
includes original paired/standalone RAF access, genuine local RAW display, an
all-seven diagnostic reference comparison, and a production C7 A–B–A conversion
run on X-T5 firmware 4.31. These observations cover the specific retained inputs
and settings; they do not establish broad RAW compatibility.

The complete simulator gate passed **419 tests with 3 explicit native-gate skips**,
and the unsigned Release simulator build passed. Final device acceptance is **incomplete**. The current live app's deliberate
Photos export/reopen proof, real interruption recovery, native rotation and
accessibility checks, and a measured mixed batch of at least 50 sources remain
open. See [the acceptance record](docs/validation/acceptance.md) for individual
checks and [device-gates.md](docs/validation/device-gates.md) for historical
observations. A simulator fixture or the prototype does not close a camera gate.

## Development

Use Jujutsu (`jj`) for version control. If Python tooling is needed, use the
project's `.venv` rather than a global Python environment.

## Build and test

Requires Xcode 27.1 (verified toolchain 27A9275), iOS 27+, and XcodeGen 2.46.0 (`brew install xcodegen`). No runtime packages are used.

```sh
Scripts/test-ios.sh
Scripts/test-ios.sh FujiStudioTests/RawResourceSelectorTests
```

The script generates the ignored `FujiStudio.xcodeproj` and shared `FujiStudio` scheme, uses `.build/DerivedData` and timestamped `.build/TestResults/*.xcresult`, and disables signing for simulator destinations. Its default simulator was inspected locally: iPhone Duo, iOS 27.1, UUID `5277B203-F40D-4AEF-98E9-164D7C653887`. Override it on other machines:

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

`RAFMetadataReader` verifies the file hash, RAF framing, X-T5 model, embedded JPEG model/orientation, and recorded RAF geometry without RAW pixel decoding. It keeps sensor/container dimensions separate from recorded crop dimensions and aspect. Synthetic metadata fixtures test parser branches; actual compression and geometry support require the pending device gate.

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
counts, booleans and dimensions. Independent software review must precede the
controller's live run. This route does not measure the 50-source performance
corpus or establish native Home, rotation, VoiceOver, or Photos chronology UI.

API references: [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [Apple ImageCaptureCore authorization requirements](https://developer.apple.com/documentation/imagecapturecore), and the installed iOS 27.1 Photos/PhotosUI headers. RAF tag/layout research was checked against [ExifTool's FujiFilm parser](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/FujiFilm.pm); no third-party code or runtime dependency is included.
