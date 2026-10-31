# RAW-only exports become real RAW+JPEG pairs — 30 October 2026

With **Update original in Photos** enabled, a RAW-only source becomes a new
Photos asset whose original resources are the untouched RAF and the exported
JPEG. The previous RAW-only asset is removed only after read-back verification.
Existing RAW+JPEG assets continue to use reversible edits.

The setting remains red and defaults off. Its explanation describes both paths.
The version picker shows RAW and Paired JPEG for a created pair without a
duplicate saved-version row. A later export edits that same pair and retains the
paired JPEG as an original.

## Verification and recovery

- A durable operation intent precedes Photos creation. Both copied resources are
  read back and checked against their expected SHA-256 values; the JPEG must also
  decode with its expected geometry and orientation.
- Capture date, location, favorites, hidden state, caption, rating, keywords and
  writable regular albums are copied. Album placement is preserved and included
  in the snapshot guards, including the offset caused by inserting the new pair.
- Changed assets, metadata loss, denied removal or interruption retain the old
  RAW and leave the export unresolved. Passive recovery never changes Photos;
  explicit Finish replacement can finish removal using the existing verified pair.
- Confirmed removal is journaled separately. Otherwise an absent original counts
  as removed only with full access before and after the lookup.
- Verified aliases preserve checked/viewed selection and export history. Frozen
  jobs keep their original source snapshots. Own replacement notifications do not
  pause a mixed batch.

Apple's [resource-based creation API](https://developer.apple.com/documentation/photos/phassetcreationrequest)
creates a new asset; it does not append originals to an existing one. The JPEG
primary / RAW alternate layout follows Apple's
[RAW+JPEG resource model](https://developer.apple.com/videos/play/wwdc2021/10160/).

## Checks

- All fast unit checks: **586 Swift Testing tests and 20 XCTest cases passed**.
- Affected RAW pair, settings and export UI suites: **11 passed, 1 existing native
  Home-boundary test skipped**. Result:
  `.build/TestResults/20261030-162526-8348.xcresult`.
- Independent review found two P2 concurrency/recovery gaps. Both were reproduced
  with failing tests before fixing and covered by the passing checks above.
- Final failure-path checks also reproduced and corrected the classification of
  initial journal/RAW preparation failures. These are now retryable failures;
  uncertain prior Photos submissions remain protected from resubmission.
- Complete final suite: **686 total, 681 passed, 2 failed, 3 skipped**. Result:
  `.build/TestResults/20261030-164343-14198.xcresult`. Both failures were existing
  recipe-editor menu interactions: saving a name/film offline and choosing
  convertible X-T5 options. The complete run remains recorded as failed; the
  RAW pair, settings, export, selection and recovery checks passed.
- Both editor tests passed unchanged in the isolated serial retry (2 passed,
  0 failed): `.build/TestResults/20261030-165204-17475.xcresult`.

The task uses the isolated **Fuji RAW JPEG Pair** iPhone 15 Pro simulator
(`6EDC06ED-9750-44CA-B4E9-EA18FF712131`, iOS 27.0).
It was shut down and deleted after validation.

## Native validation boundary

Tests use real image decoding, filesystem journals, hashes, app state and UI,
with an injected Photos boundary. No real-library export or removal was executed
on the phone. Actual PhotoKit classification, metadata retention and album order
still require a user export; their runtime read-back checks must pass before the
app requests removal of the original asset.

## Phone build

Release for code checkpoint `4411d32c` built with development team `AZH3P824F3`
and the automatic `Apple Development` identity. The exact bundle at
`.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` passed
`codesign --verify --deep --strict`.

The first installation attempt could not reach Louisphone (CoreDevice error
4016; device listed unavailable). After reconnection, the exact verified bundle
installed successfully on the iPhone 15 Pro. `com.lun3x.FujiStudio` launched
normally with no fixture or test arguments.
