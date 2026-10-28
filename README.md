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
- Copy imported camera recipes into a durable Phone collection and select them
  independently of C1–C7, including after camera refreshes.
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
- Creating recipes from scratch.

## Status

The recipe selector has Camera and Phone tabs. The copy icon beside an imported
camera recipe saves its exact name/settings on the phone and opens the Phone tab
without changing the current recipe. Repeated taps reuse the saved copy of that
import. Copies survive restarts and camera refreshes and can be saved/selected
offline; preview and export still require a compatible connected camera. Editing
is deferred so this first increment can focus on the copy/save UX. See the
[phone recipe design](docs/superpowers/specs/2026-10-28-phone-recipes-design.md).

The floating top-right photo control shows Image versions when no recipe is
selected and becomes an Export icon when a recipe is selected. Export no longer
appears in the top status row. Clear the recipe to browse the original RAW,
camera JPEG and saved exports; temporary previews are not version-menu entries.

The photo tray now uses a floating glass Select button at the top right. Select
becomes an X to cancel the batch; checked thumbnails are greyed with a blue
checkmark at the bottom right. The floating count appears only in Select mode.
All and None, including the full-library scan
triggered by All, have been removed. Tap and range selection retain the existing
viewed photo and scrolling behavior. See the
[selection design](docs/superpowers/specs/2026-10-27-photos-selection-design.md).
The selection implementation passed **439 tests, 3 established skips, 0
failures**; the count-only follow-up passed three focused UI cases. Final
Release and signed phone builds passed, and the refined build is installed on
the phone. See the [selection validation](docs/validation/photos-selection.md)
for the exact gate boundaries and screenshot evidence.

Pulling down past the top of the expanded photo grid now drags the tray down.
Release uses the divider's detents and spring; reversing past full expansion
returns the remaining movement to normal photo scrolling. Browse and Select
keep the viewed photo and checked set through the gesture.

The native workspace composes the real Photos reader/writer, X-T5 camera
service, preview/export coordinators and durable local catalog. The workspace layout
at `2e45055b` passed the complete simulator gate: **442 passed, 3 established
native-gate skips, 0 failures**, exit 0. Its unsigned Release simulator build
passed for arm64 and x86_64, exit 0. The UI correction makes letterboxing follow
the light/dark theme, removes the visible expansion label, shows one full row
plus the top of the next when collapsed, fixes release/tap arbitration and motion,
and removes the bottom material overlay. Status, Export and Connect now share
one measured top row, with the title removed to give space back to the photo.
Version selection is a floating top-right glass menu, and the zoom buttons and
inline versions strip are removed. Pinch/pan, double-tap fit and native
accessibility inspection remain available on the photo itself.
Saved-version rows now put the recipe name above a smaller grey local timestamp
in `dd/MM/yy HH:mm` format. This presentation follow-up at `5594f110` passed five
focused unit functions and two normal/AX app-flow cases, plus Release and signed
phone builds; normal and large-text screenshots were inspected. The full-suite
count above belongs to the preceding layout revision.
A fresh full pre-merge simulator gate at `99ad471e` also passed **442 tests,
3 established skips, 0 failures**, including the compact version-row follow-up.
The implementation is collected in [PR #1](https://github.com/lun3x/fuji-studio/pull/1).
The production integration review at
`86eacb7a` approved these five earlier corrections:

- Persisted failed, cancelled and unprocessed jobs remain visible after restart
  for explicit remaining-only Retry or Resume, preserving confirmed saves.
- Preview failures keep the matching image and version label with an actionable,
  accessible error, or resolve the current source's original without a camera retry.
- The former All action worked directly from Browse; it has since been replaced
  by the floating Select/X flow described above.
- Detected incompatible RAW models affect selection and export admission across
  same-revision reloads; changed originals are reassessed without eager downloads.
- Obsolete original preparation is cancelled and reports progress, while admitted
  native camera work retains ownership until completion and cleanup.

The floating-versions follow-up was reviewed with no findings.
The controller signed, verified, installed and normally launched
`2e45055b` on the phone. Simulator tests verify reclaimed photo space, menu
selection/dismissal, unavailable RAW recovery, wrapped saved-version labels at
the largest text size, and zoom/pan retention across version changes.
The user confirmed photo selection, opening the top-right versions menu,
switching versions and pinch-to-zoom on this build, with no bottom zoom buttons
or versions row.
The earlier `b0620450` phone observation verified the single action row, absent
title and retained partial second row without a covering band.
The preceding `0c008f73` phone observation also verified the scrolling cue with
unchanged overall collapsed height. The user
previously confirmed white light-mode portrait margins and smooth tray flicks on
`f823a1d3`; motion and theme regressions also pass on the current code. No camera
conversion or Photos export was performed for these UI corrections.

Earlier ordinary-app checks on `86eacb7a` completed a two-source C3 mixed
RAW/RAW+JPEG batch. A separate C4 job was interrupted with physical Home during
conversion, retained 0 saved / 2 remaining, then completed the same job after a
human camera power cycle, reconciliation and explicit Resume. Each job saved
exactly two distinct versions with frozen source/recipe/save-operation identity.
A normal restart preserved all three saved jobs and five versions, with no new
camera operation or saved association. The paired C4 version reopened without a
camera; its PhotoKit-origin JPEG bytes exactly matched the recorded native
output. See the [native validation record](docs/validation/native-batch-recovery.md)
for the power-cycle requirement, evidence bounds and remaining checks.

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

Final device acceptance remains **incomplete**: further physical validation,
active cancellation and recovery from uncertain Photos saves, limited/nonlocal
Photos, Photos chronology UI, nonnil
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
Scripts/test-ios.sh --fast # All unit tests; use during implementation.
Scripts/test-ios.sh FujiStudioTests/RawResourceSelectorTests
Scripts/test-ios.sh FujiStudioTests/WorkspaceStateTests FujiStudioTests/AppModelTests
Scripts/test-ios.sh FujiStudioUITests/LaunchTests
Scripts/test-ios.sh # Complete unit and UI suite; use for final validation.
```

`--fast` runs the entire `FujiStudioTests` target without UI tests. This keeps
coverage of the model, camera, library, rendering and export logic while avoiding
UI automation during each iteration. It still builds the app and needs an iOS
simulator or device; the first run in a fresh workspace includes compilation.
For a narrower check, supply one or more `Target/Suite` or `Target/Suite/Test`
selectors instead of `--fast`. When changing UI behavior, also run the affected
UI tests. Run the complete suite for final validation; a fast run does not
establish that UI tests pass. Use `Scripts/test-ios.sh --help` for usage.

The script generates the ignored `FujiStudio.xcodeproj` and shared `FujiStudio` scheme, uses `.build/DerivedData` and timestamped `.build/TestResults/*.xcresult`, and disables signing for simulator destinations. The observed simulator was iPhone Duo, iOS 27.1. Select an available destination on your machine:

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' Scripts/test-ios.sh
```

For an unsigned Release simulator build:

```sh
xcodegen generate
xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The test wrapper forwards each selector as a separate `-only-testing:` argument.
Native Home, hardware-keyboard and rotation tests are explicit, unverified opt-ins;
the shell must forward `TEST_RUNNER_FUJI_STUDIO_NATIVE_LIFECYCLE=1`,
`TEST_RUNNER_FUJI_STUDIO_NATIVE_KEYBOARD=1` or
`TEST_RUNNER_FUJI_STUDIO_NATIVE_ROTATION=1` to the XCTest runner. Default skips
are reported, never counted as device passes.

For a physical device, supply a locally authorized development team in ignored `Config/Signing.local.xcconfig` (`DEVELOPMENT_TEAM = YOUR_TEAM_ID`) and use Xcode's local signing workflow. Physical destinations do not disable signing. The bundle ID is `com.lun3x.FujiStudio`; no account or provisioning changes are performed by the test script.

## Original-resource boundary

`PhotoLibraryReading` passes Sendable records and local file URLs, never PhotoKit objects. Source discovery is metadata-only, ordered by effective Photos capture date descending and identifier ascending, and streams batches of up to 64 sources. Selection uses the discovered index and never starts a new discovery pass. Each original RAF+JPEG pair remains one source. JPEG-only assets remain inspectable by ID for saved-version viewing, but do not enter source discovery.

Only primary/alternate original roles qualify; content types distinguish RAF, JPEG and other RAW formats. A selected resource streams to a unique temporary file with iCloud progress, SHA-256 and cancellation/error cleanup. The caller owns and removes a successful local file. Missing originals and network failures remain preparation errors.

`RAFMetadataReader` verifies the file hash, RAF framing, X-T5 model, embedded JPEG model/orientation, and recorded RAF geometry without RAW pixel decoding. It keeps sensor/container dimensions separate from recorded crop dimensions and aspect. Synthetic metadata fixtures test parser branches; broader compression and geometry support still require device evidence.

## Camera and foreground operation

Connect the X-T5 by USB data cable and select **USB RAW CONV./BACKUP RESTORE**
on the camera. The observed support context is X-T5 firmware **4.31**. Import
reads the existing C1–C7 names/settings; the app has no saved-bank editor.
Fuji Studio starts camera discovery automatically while active; there is no
Connect button. USB attachment callbacks open a camera discovered during an
attempt. After an unsuccessful attempt, the app waits three seconds before
trying again. Ready sessions are left open, and automatic connection pauses
when the app becomes inactive or enters the background. Returning to the app
starts it again, including when no camera was previously connected. A camera
permission denial is shown in status; allow access in Settings and return to
Fuji Studio. Reconnecting imports recipes but never resumes a conversion or
export automatically. The explicit DEBUG acceptance route retains its own
controlled connection sequence.
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
