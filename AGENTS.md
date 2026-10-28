# Project instructions

- Always use Jujutsu (`jj`) for version control.
- Push project commits to the remote after each checkpoint, using the active development bookmark while implementation is in progress.
- Always use the project's `.venv` for Python rather than global Python.
- Create a new simulator for each task so that concurrently running agents do not interfere with one another. Shut down and delete that simulator when the task is finished.
- Do not maintain backwards compatibility unless explicitly requested.

## Test iteration

- Use `Scripts/test-ios.sh --fast` for implementation iterations. It runs all
  unit tests without UI automation. For a narrower check, supply one or more
  selectors, e.g. `Scripts/test-ios.sh FujiStudioTests/WorkspaceStateTests
  FujiStudioTests/AppModelTests`.
- Run affected UI suites explicitly when changing UI behavior. Run the complete
  `Scripts/test-ios.sh` suite for final validation; `--fast` does not verify UI
  behavior. Use `FUJI_STUDIO_DESTINATION` to select the task's isolated simulator.

## Installing on the physical iPhone

- Reuse the existing local signing credentials and development team `AZH3P824F3`.
  `Config/Base.xcconfig` uses automatic signing and optionally includes the
  ignored `Config/Signing.local.xcconfig`. That local file may be absent in a new
  Jujutsu workspace; pass the team on the build command instead.
- With automatic signing, use `CODE_SIGN_IDENTITY='Apple Development'`. Passing
  a certificate fingerprint as the identity causes Xcode's "conflicting
  provisioning settings" error. Let automatic signing select the valid local
  certificate; do not hard-code its fingerprint. Keep signing enabled for phone
  builds (`CODE_SIGNING_ALLOWED=NO` is only for simulator builds).
- Find the connected physical phone with `xcrun devicectl list devices`, then
  replace `<PHONE_UDID>` in this verified Release-build command:

  ```sh
  xcodegen generate
  xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio \
    -configuration Release -destination 'platform=iOS,id=<PHONE_UDID>' \
    -derivedDataPath .build/PhoneInstall \
    DEVELOPMENT_TEAM=AZH3P824F3 CODE_SIGN_IDENTITY='Apple Development' build
  ```

- Before installing, verify the resulting
  `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app` with
  `codesign --verify --deep --strict`. Install that exact bundle with
  `xcrun devicectl device install app`, then launch `com.lun3x.FujiStudio`
  normally, without fixture or test arguments.
