# Phone recipe deletion and disconnected selection

## Behavior

Phone rows now have a separate trash control. An in-app confirmation identifies
the recipe before deletion. Deletion stays available offline, while the recipe
selection button is greyed out and disabled under the same connection rule as
camera recipes. Disconnecting clears either selection; reconnecting does not
select a recipe automatically. Cached camera recipes remain copyable offline.

Deletion removes only phone-list membership. Immutable recipe snapshots,
original/camera recipes, active export submissions and saved versions remain
intact. A deleted recipe can be copied again. Deleting the selected recipe
invalidates pending preview work and restores the originals/versions control.
Deleting another recipe leaves the current selection intact. Persistence failure
keeps the recipe and reports a retryable error.

## Integration and evidence

The follow-up continues PR #16 and merges origin/main at `fb0d5d82`, preserving
its automatic connection behavior and fast-test wrapper. Offline fixtures use
`--fixture-disconnected-camera` or `start(automaticallyConnect: false)` explicitly.

- Merged baseline: 421 Swift Testing cases plus native unit cases passed.
- Unit implementation gate: 426 Swift Testing cases plus native unit cases
  passed, including real durable reopen/recopy, failed deletion, stale preview
  rejection, and completion of a frozen pending export after recipe deletion.
- Four affected UI cases passed: offline greyed selection until connection,
  cancellation/confirmation/recopy, selected deletion, and largest-text controls.
  Normal and accessibility5 screenshots were inspected; delete remains usable
  beside the disabled selection button, and the native confirmation fits.
- Unsigned generic simulator Release build passed.
- Signed Release build for the iPhone 15 Pro passed and its exact app bundle
  passed `codesign --verify --deep --strict`.
- Independent read-only review found no confirmed Critical, Important or Minor
  issues, with no behaviors declined as outside scope.
- Complete `Scripts/test-ios.sh` gate: **489 passed, 3 established native-gate
  skips, 0 failures / 492 total**, exit 0. The result bundle is
  `.build/TestResults/20261028-113535-81209.xcresult` and the full log is
  `.build/delete-full-suite.log`.
- The exact signed app from implementation checkpoint `f13b4a94` was installed
  on the iPhone 15 Pro, launched normally without fixture/test arguments, and
  confirmed running by a subsequent process listing. Results are retained as
  `.build/delete-install-result.json`, `.build/delete-launch-result.json` and
  `.build/delete-processes-result.json`.

Logs, result bundles and synthetic screenshots are under ignored `.build/` in
`/tmp/fuji-studio-phone-recipe-delete-20261028`. The task-owned simulator is
`8F7D02AD-4CAD-40DB-A035-9DE014BE961C`.
It was shut down and deleted after validation.

## Commands

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=8F7D02AD-4CAD-40DB-A035-9DE014BE961C' Scripts/test-ios.sh --fast
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=8F7D02AD-4CAD-40DB-A035-9DE014BE961C' Scripts/test-ios.sh
xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio \
  -configuration Release -destination 'platform=iOS,id=<PHONE_UDID>' \
  -derivedDataPath .build/PhoneInstall DEVELOPMENT_TEAM=AZH3P824F3 \
  CODE_SIGN_IDENTITY='Apple Development' build
```

These simulator fixtures do not add new physical camera-conversion or
Photos-export acceptance evidence. The actual-device follow-up covers the
signed build, installation and normal app launch.
