# Rejected processing profile journal validation

Date: 2026-10-29. Implementation: `7de5cb5a`. Bookmark: `codex/rejected-profile-journal`.

## Automated checks

- The two new service regressions failed before implementation because the rejected baseline and mismatched readback files were absent.
- Focused iOS camera service suite: 24 tests passed.
- `Scripts/test-ios.sh --fast`: 516 tests passed across 58 suites.
- `swift test --package-path Packages/FujiCameraCore`: 122 tests passed across 18 suites.
- Independent read-only review: no actionable findings. Capture uses existing binary size limits and file protection; profile failures still stop before conversion/deletion.
- Complete `Scripts/test-ios.sh` suite on the isolated task simulator with the default two Xcode workers: 606 logical tests passed, three established native-device skips, zero failures; exit 0. The xcresult device-level count is 651 passing runs because parameterized cases execute separately. Runtime was 764.25 seconds.

The first cold simulator attempt failed to launch the app. Explicit simulator boot resolved it. An initial serial full-suite run was interrupted to restart with the project's default two-worker configuration; it is not counted as a completed validation run.

## Physical iPhone

The Release build passed with automatic signing and the project's development team. `codesign --verify --deep --strict` passed for the exact `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` installed with `devicectl`. Normal launch used no fixture/test arguments, and the running process matched the installed bundle.

The user reproduced the original unsupported-profile error on this build. The new journal retained `baseline.bin` with all 625 bytes, and its SHA-256 matched `journal.json`. The profile header and every non-writable byte matched a previous successful baseline. The only differences were four writable words: film at offset 541 (15 to 11), highlight at 573 (20 to -20), shadow at 577 (20 to -20), and color at 581 (0 to 40). These correspond to Classic Chrome, highlights -2, shadows -2, and color +4.

This confirms physical capture of the previously missing evidence. It also identifies why this conversion still fails: `XT5WorkingProfile.make` compares writable starting values against one fixed measured baseline before applying the requested recipe. This logging change deliberately leaves profile admission unchanged.

Raw device journals, binary profiles, checksums, and source identifiers remain in ignored `.build/phone-repro` artifacts. No private profile or image data is committed.
