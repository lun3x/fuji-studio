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
