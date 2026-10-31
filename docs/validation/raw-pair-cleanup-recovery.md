# RAW pair cleanup recovery — 30 October 2026

The user's exported pair already contained byte-identical RAW and JPEG resources,
the expected JPEG geometry/orientation, and all captured user metadata. Native
read-only diagnostics identified three recovery obstacles:

- Photos renamed the paired RAF to the exported JPEG's stem. Verification had
  incorrectly required the old RAF filename despite matching bytes.
- Application Support enumerated `/private/var/mobile` URLs while the journal
  constructed `/var/mobile` URLs. Whole-URL equality rejected valid intents.
- The old asset's modification date differed, with unchanged source resources
  and user metadata. The user reported an earlier reversible export. Passive
  recovery must classify the verified pair without treating this timestamp as
  permission to delete the old asset.

Journal enumeration validates operation filenames inside its directory. Pair
verification retains exact hashes, resource roles, JPEG decode and geometry,
metadata and source stability checks. Automatic removal still requires the
original timestamp to match. Explicit **Finish replacement** accepts a prior
timestamp difference only after rechecking the old RAW's hash, metadata and
stable before/after snapshots. The native transaction checks that accepted
snapshot again before removal.

Status distinguishes **RAW+JPEG saved — removal pending** from an unknown save.
**Check Photos again** remains read-only. **Finish replacement** removes the old
asset and its previous Photos edits, retaining its unchanged RAW and exported
JPEG in the pair. Its owned worker requires no camera and starts no conversion
or new Photos asset.

## Evidence

- Symlinked journal URL, Photos-renamed RAF and prior edit regressions were
  observed failing, then passing. A corrupted original RAW regression exposed
  missing old-RAW read-back; it now blocks removal. A modification during
  verification also blocks removal.
- Initial full fast suite: **593 Swift Testing tests and 20 XCTest cases passed**
  (`/tmp/fuji-pair-recovery-unit-green.log`). Includes explicit disconnected
  cleanup, preserved old asset during passive recovery, one Photos save and no
  additional render during cleanup.
- Independent final read-only review found one cancellation classification
  issue during in-flight verification. The gated lookup regression reproduced
  it (`/tmp/fuji-pair-cleanup-cancel-red.log`). Final-state classification now runs
  even when cancellation stops verification before cleanup submission.
- Final fast suite after that fix: **594 Swift Testing tests and 20 XCTest cases
  passed** (`/tmp/fuji-pair-recovery-final-unit.log`). Both cancellation and
  lifecycle suspension wait for the worker, preserve the pending Photos intent,
  start no cleanup or next conversion, and classify remaining items correctly.
- New recovery UI test passed (`20261030-183631-35136.xcresult`): passive check
  retains the pending state; explicit completion confirms the existing pair.

Final review: the only Important finding is fixed with RED→GREEN coverage. No
Critical or Minor findings, declined judgments, or deferred findings.

The complete four-worker run stalled in simulator UI runners and was interrupted
(`20261030-183918-36895.xcresult`: 645 recorded, 631 passed, 14 failed). This is
not a passing validation result. Its cleanup UI test and unit checks passed. A
complete two-worker retry with idle sleep inhibited was started afterward.
That retry also stalled in simulator screenshot/event synthesis and was
interrupted (`20261030-211921-39128.xcresult`: 631 recorded, 623 passed, 8 failed).
The complete suite remains unverified; neither interrupted run is reported as
passing. The isolated recovery UI check, final fast suite and corrected native
read-only verification passed as recorded above. Both runs' worker clones were
removed by Xcode; task simulator shutdown/deletion was verified.

The task uses the isolated **Fuji Pair Cleanup Recovery** iPhone 15 Pro simulator
(`2C7BE0E1-B50E-40C7-A80E-FFD03E8E79A3`). Native diagnostics only inspect existing
Photos assets; they do not create or delete photos.

## Physical verification and installation

The corrected read-only diagnostic passed on Louisphone
(`.build/PhoneDiagnostics-5.xcresult`). Journal enumeration now succeeds and the
user's existing pair is classified as `needsReplacementCleanup`, with matching
RAW/JPEG hashes, no pair metadata differences, and only the old asset's
modification date differing. No Photos assets were created or removed.

Code checkpoint `3bcbc195` built in Release using development team `AZH3P824F3`
and automatic `Apple Development` signing. The exact bundle under
`.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` passed
`codesign --verify --deep --strict` and installed successfully on Louisphone.
The first normal launch attempt lost its remote service connection (CoreDevice
4000); the device then became unavailable (4016). No fixture or test launch
arguments were supplied. Installation had already completed successfully.
After reconnection, a normal launch was attempted again and Photos' host phone
was locked (CoreDevice 10002 / FBSOpenApplicationErrorDomain 7). The installed
Release app must be opened manually after unlocking; no successful remote
normal launch is claimed.
