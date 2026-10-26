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

The design specification and interaction prototype are approved. Task 1 now
supplies a runnable native app, Photos original-resource access, and a DEBUG
hardware probe. Actual iPhone resource validation remains pending; this is not
yet a conversion app.

## Development

Use Jujutsu (`jj`) for version control. If Python tooling is needed, use the
project's `.venv` rather than a global Python environment.

## Build and test

Requires Xcode 27+ and XcodeGen 2.46.0 (`brew install xcodegen`). No runtime packages are used.

```sh
Scripts/test-ios.sh
Scripts/test-ios.sh FujiStudioTests/RawResourceSelectorTests
```

The script generates the ignored `FujiStudio.xcodeproj` and shared `FujiStudio` scheme, uses `.build/DerivedData` and timestamped `.build/TestResults/*.xcresult`, and disables signing for simulator destinations. Its default simulator was inspected locally: iPhone Duo, iOS 27.1, UUID `5277B203-F40D-4AEF-98E9-164D7C653887`. Override it on other machines:

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' Scripts/test-ios.sh
```

For a physical device, supply a locally authorized development team in ignored `Config/Signing.local.xcconfig` (`DEVELOPMENT_TEAM = YOUR_TEAM_ID`) and use Xcode's local signing workflow. Physical destinations do not disable signing. The bundle ID is `com.lun3x.FujiStudio`; no account or provisioning changes are performed by the test script.

## Original-resource boundary

`PhotoLibraryReading` passes Sendable records and local file URLs, never PhotoKit objects. Source discovery is metadata-only, ordered by effective Photos capture date descending and identifier ascending, and streams batches of up to 64 sources. `allEligibleSources()` completes that discovery without downloading originals. Each original RAF+JPEG pair remains one source. JPEG-only assets remain inspectable by ID for saved-version viewing, but do not enter source discovery.

Only primary/alternate original roles qualify; content types distinguish RAF, JPEG and other RAW formats. A selected resource streams to a unique temporary file with iCloud progress, SHA-256 and cancellation/error cleanup. The caller owns and removes a successful local file. Missing originals and network failures remain preparation errors.

`RAFMetadataReader` verifies the file hash, RAF framing, X-T5 model, embedded JPEG model/orientation, and recorded RAF geometry without RAW pixel decoding. It keeps sensor/container dimensions separate from recorded crop dimensions and aspect. Synthetic metadata fixtures test parser branches; actual compression and geometry support require the pending device gate.

## Hardware probe

A DEBUG launch exposes **Hardware probe**. It requests Photos access only when its explicit button is tapped; app launch requests no camera access. Request full or limited Photos access, choose an eligible source to list descriptors, then tap **Retrieve and inspect selected originals**. Descriptors alone cause no download. The probe retrieves original RAF and JPEG sequentially, reports byte counts/checksums and metadata, and removes successful temporary files after inspection. **Cancel retrieval** exercises cancellable cloud requests. A known Photos local ID can also be inspected directly, including JPEG-only exports. Limited access has a system management action; tap the discovery button again after changing the allowed set.

Probe output stays in the current session and is selectable. Record only redacted observations in [device-gates.md](docs/validation/device-gates.md). Keep real RAFs, personal captures and their identifiers in ignored `Tests/Fixtures/Private/`; never commit them.

API references: [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [Apple ImageCaptureCore authorization requirements](https://developer.apple.com/documentation/imagecapturecore), and the installed iOS 27.1 Photos/PhotosUI headers. RAF tag/layout research was checked against [ExifTool's FujiFilm parser](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/FujiFilm.pm); no third-party code or runtime dependency is included.
