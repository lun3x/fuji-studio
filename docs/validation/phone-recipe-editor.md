# Phone recipe editor

Date: 2026-10-28. Follow-up to the copy/save/delete increment in PR #16.
Validated implementation: `0b25afae`, including latest main at `c3826092`.

## Behavior

The pencil beside a phone recipe opens a native form with Name, Look, White
balance, and Tone and detail sections. Save applies changes; Cancel discards the
draft. Validation and storage errors retain the draft and show an inline message.
Edit and Delete work offline while recipe selection remains greyed out. Saving
the selected preset refreshes its preview, including when an earlier preview is
still pending. Editing another preset does not select it.

The editor offers the existing validated X-T5 renderer domains. It preserves
untouched unsupported raw values and permits name-only changes in unsupported
camera contexts. No new camera capability or conversion domain was added.

Stable phone identity uses the existing source-snapshot membership key. Saving
creates a new immutable snapshot and atomically replaces membership's current
revision. No SwiftData schema change is required. Camera imports, prior exports,
their names/settings, and active export jobs retain their frozen snapshots.
No-op saves retain the original revision, including padded imported names. Stale
drafts and edits after deletion/recreation are rejected.

## Verification

- Baseline: all 426 Swift Testing tests and 18 native XCTest unit cases passed.
- Editor unit gate: all 438 Swift Testing tests and 18 native XCTest unit cases
  passed on the final logic. Coverage includes every offered setting choice
  through the real renderer's normalization, raw-value preservation, validation,
  durable reopen, stable identity, stale/deleted drafts, failed update retention,
  immutable previous exports and superseding an in-flight preview.
- Seven affected UI cases passed on an isolated iPhone 15 Pro / iOS 27.0 simulator:
  name/film save and reopen, Cancel, invalid/corrected temperature, accessibility
  presentation, copying/selection offline, and deleting/cancelling/recopying.
- Screenshot inspection caught a missing environment value in the presented
  editor. An explicit text-height regression assertion demonstrated that the
  form had inherited normal text (22 pt height), and the sheet now receives its
  presenter's dynamic type size explicitly. All three editor UI cases passed
  again after this correction; screenshots confirm large text and reachable
  Save/Cancel controls, including while the form is scrolled.
- One independent read-only review identified unwanted trimming of unchanged
  camera names. A failing no-op/settings-only test captured both paths; the fix
  preserves an untouched name verbatim. No other substantive issues were found.
- Simulator Release and signed physical-iPhone Release builds passed after the
  final dynamic-type presentation correction.
- The exact signed Release bundle passed `codesign --verify --deep --strict`,
  was installed on the connected iPhone 15 Pro, and launched normally without
  fixture arguments. A device-process query confirmed the installed executable
  running. Existing on-device recipe data is retained.
- Complete `Scripts/test-ios.sh` run: **507 total, 503 passed, 1 failed,
  3 skipped**. All editor, recipe-management, preview, export, image-viewer and
  workspace-layout checks passed. Skips are the established native Home,
  physical rotation and hardware Escape gates. The unchanged
  `testInitiallyInactiveStartupWaitsForForegroundBeforeConnecting` failed its
  expected disconnected-prompt assertion before the injected foreground action.
  This is outside the editor path; the startup/lifecycle code is unchanged.
  It failed again in isolation. A separate temporary workspace at pre-editor
  `bd39e4ae` passed the same case on the same simulator. The current code then
  passed it without an application change, after adding the camera prompt to the
  assertion's failure message. This establishes a timing-sensitive test result,
  not a proven root cause or product fix. That diagnostic message is retained.
  The full suite is not recorded as green; this existing startup test needs
  further stabilization. No additional camera/startup behavior was changed.

An exploratory iPhone Duo / iOS 27.1 run exposed disappearing native navigation
buttons after scrolling. Explicit navigation visibility and fullscreen
presentation did not fix it and were reverted. The unchanged sheet's
temperature/save/reopen flow passes on iPhone 15 Pro / iOS 27.0, matching the
physical phone's iOS 27.0.1 family. Duo / iOS 27.1 remains unverified; no claim of
cross-runtime acceptance is made. An initial full run was stopped after its unit
gate to fix the dynamic-type issue found in screenshots.

Local diagnostics, result bundles and screenshots remain in ignored `.build`;
no real photo, camera profile, signing credential or device identifier is included
in this record.

## Reproduction

Use a new task-specific iPhone 15 Pro simulator with the installed iOS 27.0
runtime. The project wrapper regenerates the Xcode project:

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=<TASK_SIMULATOR_UDID>' Scripts/test-ios.sh --fast
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=<TASK_SIMULATOR_UDID>' Scripts/test-ios.sh
xcodebuild -project FujiStudio.xcodeproj -scheme FujiStudio \
  -configuration Release -destination 'platform=iOS Simulator,id=<TASK_SIMULATOR_UDID>' \
  -derivedDataPath .build/ReleaseValidation CODE_SIGNING_ALLOWED=NO build
```

Use the signing and verified-bundle installation commands in `AGENTS.md` for the
physical phone. Launch `com.lun3x.FujiStudio` normally without fixture arguments.
