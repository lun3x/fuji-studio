# Export progress before original cleanup — 1 November 2026

Verified RAW+JPEG pairs remain pending until the batch removes their original
RAW assets. The progress numerator counted only fully confirmed saves, failures
and cancellations, so it stayed at zero throughout a successful RAW-only batch.

Count verified pairs awaiting original cleanup as exported for presentation.
Keep the total based on distinct job items so pending pairs are not counted
twice. Genuinely unknown saves remain excluded. Preserve the durable save state,
verification, cleanup admission and single deletion transaction.

Both the camera status bar and status-sheet progress should advance per verified
export, reach full export progress while cleanup is pending, and identify final
original cleanup separately from an unknown Photos save. Confirmed saved counts
remain distinct from exports awaiting cleanup.

Regression coverage includes partial progress, mixed failure/unknown outcomes,
and an owned two-RAW export held at final cleanup. UI coverage checks both bars
and the pending-cleanup count before release of the cleanup transaction.

The first regression invocation could not launch the simulator test app
(NSPOSIXErrorDomain 3). It ran no tests; the isolated simulator was booted to
completion before retrying.

Task simulator: **Fuji Export Progress** iPhone 15 Pro,
`40C3AD5B-F502-45EF-A1E5-6CB8F3E12C54`.

## Verification

- Warm regression run reproduced zero progress at one and two verified exports,
  wrong mixed-outcome progress and the misleading cleanup status
  (`/tmp/fuji-export-progress-red-2.log`).
- `Scripts/test-ios.sh --fast`: **607 Swift Testing tests and 25 XCTest cases
  passed** (`/tmp/fuji-export-progress-unit.log`). Durable save completion stays
  pending while the owned two-RAW job reports 50%, then 100% export progress.
- Affected batch/recovery UI suites: **2 passed**
  (`.build/ExportProgressUI.xcresult`). Both progress indicators report 3 of 3
  before cleanup completion, with 3 awaiting cleanup and no unknown saves.

The user also reported no deletion prompt and 16 unconfirmed items in the
installed version, then clarified that they manually deleted the originals.
The copied recovery journal contains 16 verified pair intents and no recorded
removal event for that batch. Deleted originals cannot be compared with their
pre-cleanup snapshots; no cause for the earlier blocked cleanup is inferred and
no safety check is relaxed. Native diagnostic inspection changes no Photos.

Complete UI-inclusive validation and the signed Release build are in progress.

## Final checks

- Complete suite: **720 total, 717 passed, 0 failed, 3 skipped**
  (`20261101-105057-9338.xcresult`).
- Inspected the rendered held-cleanup status screenshot: full export progress,
  3 awaiting cleanup, 0 unconfirmed and a separate final-cleanup status.
- The physical destination Release command timed out because Louisphone became
  unavailable. The same Release configuration built successfully for generic
  iOS with team `AZH3P824F3` and automatic `Apple Development` signing.
- The exact `.build/PhoneInstall/Build/Products/Release-iphoneos/FujiStudio.app`
  passed `codesign --verify --deep --strict`; its provisioning profile includes
  Louisphone. Installation was attempted and rejected by CoreDevice 4016 because
  the phone is unavailable. Installation and normal launch remain pending.
- The first native metadata inspection encountered the manually deleted
  original. Its absence is expected from the user's clarification. The corrected
  read-only probe could not launch while the phone was locked/unavailable and
  was stopped. Its temporary test source was removed; no Photos changes ran.
- Task simulator shutdown/deletion and worker-clone cleanup were verified.

Code checkpoint: `771033e2` on `codex/export-progress`. The ready signed bundle
is retained in this task workspace for installation after reconnection.

## Completion after unlock

The corrected metadata probe passed on Louisphone
(`.build/BatchMetadataProbe-3.xcresult`). Full Photos access was observed. All 16
pairs from the reported batch are present, with the expected RAW/JPEG resource
roles and matching preserved metadata. All 16 old originals are absent, matching
the user's manual deletion. This inspection made no Photos changes and did not
repeat the earlier byte-hash verification.

The exact signed Release bundle was reverified, installed successfully and
launched normally without fixture or test arguments. Its temporary diagnostic
test source was removed. Phone installation is complete.
