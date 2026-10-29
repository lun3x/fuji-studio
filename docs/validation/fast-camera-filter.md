# Faster camera compatibility filter validation

Date: 2026-10-29. Development bookmark: `codex/fast-camera-filter`.
Workspace: `/tmp/fuji-studio-fast-camera-filter.LDOD8U`.
Base: `434b9d84` (latest origin/main at implementation and final fetch).

## Behavior

Filtering reads structural RAF metadata through a bounded PhotoKit stream. It
creates no temporary RAW and performs no whole-file checksum. When PhotoKit
provides the original byte count, receiving all required metadata completes the
check and cancels the remainder of the request. With an unknown size, the stream
retains the metadata prefix and waits for completion to validate actual bounds.

The live app persists metadata as atomic disposable records in its caches/raw-metadata
directory. Records match the exact original token and parser version, replacing
previous revisions per asset. Missing/corrupt/unwritable caches trigger normal
inspection. Failures are not cached. Each camera's current admission rules are
reapplied, including X-E3 encoding, bit-depth, orientation and recorded geometry.
Original viewing/conversion retains complete-file checksum verification.

## Evidence

- Fresh isolated iPhone 15 Pro / iOS 27.0 simulator:
  `F7E75315-1188-404C-AD78-CBAEFD828EDF`.
- Baseline `Scripts/test-ios.sh --fast`: 532 Swift Testing cases and 19 XCTest
  cases passed.
- Parser and transfer tests failed for the missing APIs before implementation.
  Focused shared parser/source tests passed: 14 cases. Initial app parser/transfer
  tests passed: 11 cases.
- An 80 MiB declared sensor payload is never delivered to the transfer test;
  metadata completes from chunked prefix bytes and the request is cancelled,
  including when completion races request registration.
- Persistent-cache tests failed for the missing initializer, then passed for
  recreated pools, changed resource tokens/revisions, cross-camera assessment,
  missing/corrupt cache files, unavailable cache storage, retry after offline
  failure, and full preparation seeding the cache.
- Integrated unit run: 545 Swift Testing cases and 19 XCTest cases passed.
  Filter worker tests now require zero full RAW materializations and verify
  metadata reads and cache reuse instead.
- Additional registered-task-cancellation and 32 MiB prefix-limit tests passed;
  all eight transfer tests passed.
- Independent read-only review found no actionable issue. It checked cache
  matching and error recovery, shared X-E3 parsing, bounds, request cancellation
  races, native PhotoKit revalidation, and unchanged conversion checksums.

## Limits

PhotoKit/iCloud can download more internally than the prefix requested by the
application. Actual phone/iCloud latency has not been measured. Unknown sizes
require transfer completion, though they avoid RAW disk copies and hashing.
The parser retains at most a 32 MiB prefix during inspection; unusual or malformed
layouts needing metadata beyond that limit report an unavailable check.

## Native UI validation

Explicit affected-suite run passed all seven tests in CameraFilterTests and
RecipePhotoCompatibilityTests, with zero failures. This includes connected X-T5
and X-E3 filtering, selection pruning with viewer preservation, restoring All
Photos, empty results, landscape layout/failure status, and recipe eligibility
for mixed photo selections. Result bundle:
`.build/TestResults/20261029-200237-11986.xcresult`.

## Complete suite result

The required unfiltered `Scripts/test-ios.sh` run completed with **638 passed,
three established native-device skips, and one failure** (642 logical tests;
parameterized runs are reported separately by Xcode). Exit 65. Result bundle:
`.build/TestResults/20261029-200601-13087.xcresult`. Parsed summary:
`.build/fast-filter-final-summary.json`.

The failure is
`PhoneRecipeEditorTests.testXT5EditorOffersOnlyConvertibleFilmRangeAndBalance`,
at PhoneRecipeEditorTests.swift:176: XCTest could not tap the `Colour temperature`
button, reporting `Not hittable` and a computed hit point of {-1, -1}. This test
never enables the compatibility filter, and its editor/menu/test code is unchanged
by this work. The failed full result is retained; a focused rerun does not turn it
into a passing full-suite result.

The single failed editor case passed in an isolated serial rerun with no source
changes (32.722 seconds for the case, exit 0). The full-suite result above remains
reported as failed. No recipe-editor changes were added to this performance task.
The task simulator was shut down and deleted, and its absence was verified.

## Physical iPhone installation

On 2026-10-29, built source revision `f869e6b7` in Release for the connected
physical iPhone 15 Pro, Louisphone (`00008130-001825E90204001C`), from the isolated
workspace `/tmp/fuji-studio-filter-phone.HuYm5A`. Automatic signing used team
`AZH3P824F3` and `Apple Development`. The build passed, and the exact resulting
`.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` passed
`codesign --verify --deep --strict`; its bundle ID and team matched expectations.

`devicectl device install app` installed that bundle successfully. A normal launch
of `com.lun3x.FujiStudio`, without fixture/test arguments, succeeded. A subsequent
physical-device process query confirmed `FujiStudio` running as PID 4234 from the
same installed bundle path. Device installation and launch JSON receipts are
under `.build/phone-install.json` and `.build/phone-launch.json` in that workspace.
No physical-camera filtering latency measurement was performed. The install
task's unused isolated simulator was deleted and its absence verified.
