# X-T5 replaceable starting settings

Date: 2026-10-29. Implementation: `4892916c`. Bookmark: `codex/flexible-processing-baseline`. Follow-up to the logging capture in PR #36; fix reviewed in PR #37.

## Failure and correction

The user's rejected profile had the supported 625-byte frame, matching header/padding, and identical immutable words. Four writable words differed from the original measured baseline. The adapter rejected those starting values before sending the requested recipe or triggering conversion.

The adapter now compares only structural and immutable bytes against that baseline. All 17 exempted words are fully overwritten from the frozen recipe or fixed output policy before camera submission; their incoming values cannot enter the candidate. Source/recipe admission, exact profile readback, JPEG assessment, and cleanup checks remain in place. Support provenance is `xt5-4.31-0200-structured-frame-v3`.

## Verification

- Before implementation, the new starting-settings regression and the service test using the observed differences failed with `unsupportedProfile` in the package and iOS runs.
- All 123 shared-package tests passed after implementation.
- `Scripts/test-ios.sh --fast`: all 517 iOS unit tests passed across 58 suites.
- Tests independently assert every requested output word for the four observed differences and full-width varying starting values. Every mutated immutable byte, malformed frame length, and unsupported source geometry still fails.
- Independent read-only review found no actionable issues. It verified 17 fully replaced words and 557 constrained bytes.
- Complete `Scripts/test-ios.sh` suite on the task's isolated iPhone 15 Pro simulator with the default two Xcode workers: 607 logical tests passed, three established native-device skips, zero failures; exit 0. The device-level count is 652 passing runs because parameterized cases execute separately. Runtime was 768.632 seconds. The xcresult reported no runtime warnings.

## Physical iPhone

The signed Release build passed using the project's development team and automatic Apple Development signing. `codesign --verify --deep --strict` passed for the exact `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` installed on the phone. Normal launch passed without fixture/test arguments; the running executable matched the installed bundle.

The user confirmed the previously failing photo now applies its recipe successfully. Read-only inspection of 17 subsequent operation journals found all 17 completed on the new support version, with valid output, recipe acceptance, acknowledged cleanup, and no failure. Four used the exact same starting-profile checksum as the previously rejected profile. These hardware results directly verify the corrected admission path while retaining final recipe/output checks.

Device profile bytes, checksums, source identifiers, and copied journals remain private ignored artifacts.
