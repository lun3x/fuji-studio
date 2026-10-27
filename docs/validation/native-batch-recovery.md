# Native mixed-batch and interruption validation

Recorded 2026-10-27 on the physical iPhone 15 Pro / iOS 27.0.1 and USB-connected
X-T5 / firmware 4.31. Runtime revision: `86eacb7a`. These checks use the ordinary
app, actual Photos services, production coordinators and native camera service.
No fixture services, injected scene events or automatic validation export driver
are used. The controller observes Device Hub; the user performs the physical
taps because remote recipe taps and the native Home control produced no visible
transition. No cause is assigned to that input limitation.

## Uninterrupted C3 mixed batch

**Bounded pass:** one standalone RAW and one RAW+JPEG source, one selected C3
recipe, one deliberate Export action, one two-item job.

- The controller observed Select mode, exactly the two intended checked square
  thumbnails, C3 and enabled Export before submission.
- Both the visible native status and the user's report showed **2 saved, 0
  failed, 0 cancelled, 0 remaining, 0 unconfirmed**.
- The copied catalog has one additional job and two additional saved versions,
  with distinct Photos asset IDs and operation IDs. Each saved version belongs
  to its intended source and the job's unchanged frozen recipe.
- Native records bind both outputs to the exact retained RAF hashes, source
  revisions, settings digest and recipe provenance. Both are full FINE
  7728 × 5152, orientation 8. Candidate/readback bytes match; owned deletion and
  an empty output view are acknowledged for each completed camera operation.
- The paired source's C3 preview had already rendered before submission. The
  batch added one native camera operation for the standalone source and reused
  the paired cached result. This is not two fresh in-batch conversion timings.
- Original resource descriptors and the previous single-export job/version
  remain unchanged. Both sources are now classified as X-T5; that expected
  compatibility update is distinct from an original-resource change. All 35
  existing local imported recipe snapshots remain unchanged.

These native saved associations and completion callbacks do not constitute a
separate offline rehash of the two new PhotoKit originals, a chronology UI check,
or a measured performance result. Live catalog copies pass SQLite integrity
checks, but are observations, not a replacement for a same-job process-reopen
durability check. No user asset was deleted.

## C4 Home interruption — recovery in progress

The user selected C4, submitted the same two sources once, followed the request
to swipe Home during “Converting on camera,” then reopened the app. The user and
controller observed **0 saved, 0 failed, 0 cancelled, 2 remaining, 0 unconfirmed**
with Export paused and Resume disabled while the camera was unavailable.

The native record shows an acknowledged conversion trigger, followed by timeout
without a captured/validated JPEG or deletion attempt. Native close was confirmed;
the operation remains uncertain. The original C4 job remains paused with both
Photos operations queued, and the saved-version count remains three, including
the earlier single export and the two C3 outputs. No automatic replacement
submission or claimed Photos save occurred.

Explicit reconnect/recovery of this existing job is pending. Camera-operation
uncertainty is separate from an uncertain PhotoKit save: this run has not entered
that Photos failure window. No completed interruption-recovery pass is claimed.

## Evidence and remaining scope

Private root intent, catalog/journal copies and offline inspection remain under
ignored `.build/native-device-validation-20261027/`. Exact source, job, operation,
asset and run identifiers, filenames, hashes, profile names/settings and media
are not committed. The diagnostic text file copied from Documents contains old
timestamps and is not used as a current-run transport trace.

See the [acceptance matrix](acceptance.md) for remaining device gates. A distinct
mixed set of at least 50 sources with Instruments, active cancellation/retry,
disconnect recovery, uncertain PhotoKit completion, precise image detail,
chronology/GPS and accessibility coverage remain unproved.
