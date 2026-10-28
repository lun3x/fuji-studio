# Phone recipe copy/save validation

## Delivered increment

Camera and Phone collections share the existing recipe popover. Each imported
camera row has a separate accessible copy control, usable with a cached import
offline. A successful save reveals Phone without selecting another recipe;
selecting the saved row explicitly chooses it. Repeated copies of the same
import reuse the durable copy. Editing and creation from scratch are deferred.

Copies preserve every imported name/settings byte, digest, camera context,
observation and timestamp, with new immutable snapshot identity and source
snapshot provenance. Camera refreshes and app restarts preserve the separate
phone collection. Phone selection survives disconnection and renders/exports
through the existing compatible-camera pipeline.

## Verification

- Baseline: 424 unit tests passed, zero failures.
- Feature unit run: 415 Swift Testing functions plus 18 XCTest cases passed.
  Coverage includes actual durable catalog reopen, fresh-model loading,
  unsupported lossless copies, repeat-save reuse, camera-refresh isolation,
  offline/reconnect selection, forced save failure, and frozen phone export
  history. No real camera or Photos writes are involved in these fixtures.
- New normal-size UI flow passed: empty Phone state, offline cached copy,
  unchanged current selection, repeat-copy reuse, explicit phone selection,
  default collection on reopening, and camera reconnect with enabled export.
- New largest-text UI flow passed: accessible copy target, visible top row after
  collection switch, wrapped recipe name and phone selection. Native screenshot
  attachments were inspected at normal size and accessibility5.
- Selection-padding and copy-padding checks pass independently. The previous
  popover-edge selection assertion was updated because that edge now belongs to
  the copy control; the new check verifies copying leaves selection unchanged.
- Unsigned Release build for the generic iOS Simulator destination passed.
- Full simulator suite: **475 passed, 3 established native-gate skips, 0 failures**
  (478 total). The complete two-worker run exited 0 and its `.xcresult` summary
  reports `Passed`; logs/results are `.build/phone-final.log` and
  `.build/phone-final.xcresult`.
- Independent whole-change review found no confirmed Critical, Important or
  Minor issues in persistence, selection identity, camera admission or frozen
  export provenance.

The test simulator is task-owned: `737F0FCC-51B4-4C81-A18F-A8FB0612B9F1`.
It was shut down and deleted after validation; Xcode removed its two task-owned
worker clones automatically.
All test logs, `.xcresult` bundles and exported synthetic screenshots are under
ignored `.build/` in the task workspace.

## Commands

```sh
xcodebuild test -project FujiStudio.xcodeproj -scheme FujiStudio \
  -destination 'platform=iOS Simulator,id=737F0FCC-51B4-4C81-A18F-A8FB0612B9F1' \
  -derivedDataPath .build/DerivedData -resultBundlePath .build/phone-final.xcresult \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled YES \
  -parallel-testing-worker-count 2 -maximum-concurrent-test-simulator-destinations 2
xcodebuild build -project FujiStudio.xcodeproj -scheme FujiStudio \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ReleaseVerification CODE_SIGNING_ALLOWED=NO
```

## Evidence bounds

These checks verify the copy/save increment and its integration with the
established renderer using deterministic fixtures. They do not add new physical
camera/firmware/settings acceptance evidence. The local-copy implementation does
not modify camera custom banks.

## Physical installation follow-up — 28 October 2026

At the user's request, the phone recipe code at `5f9d2d76` was built in Release
for the connected iPhone 15 Pro using the project's existing automatic signing
credentials. The signed `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app`
passed `codesign --verify --deep --strict`, and that exact bundle was installed.
The normal `com.lun3x.FujiStudio` launch succeeded with no fixture/test arguments;
a subsequent device process listing confirmed the app was running. Build,
installation and launch results are retained under ignored `.build/`.

This confirms installation and normal launch, without adding physical recipe
conversion or Photos-export acceptance evidence.
