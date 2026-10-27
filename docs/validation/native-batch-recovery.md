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
durability check. The later normal restart below separately checks persistence.
No user asset was deleted.

## C4 Home interruption and explicit recovery

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

Connect alone did not restore readiness. The user switched the camera off/on,
then connected again. The controller observed Camera ready and enabled Resume,
with the same 0 saved / 2 remaining counts. The copied catalog still has exactly
the same three jobs and three saved versions; the complete frozen C4 job is
unchanged. All seven newly imported banks match their previous names, imported
bytes, settings digests and support assessment; all old snapshots remain intact.

The one uncertain native record changed to `reconciledMissing` following the
service's fresh-session empty-output check. Its original trigger acknowledgement,
confirmed close and lack of capture/deletion remain preserved. No new camera
record, Photos submission or deletion was replayed during this reconnection.
This establishes observed output absence, not the old conversion's success or
opaque uploaded-RAW buffer release.

The user then tapped Resume once, observed export success with 2 saved and 0
remaining, and disconnected the camera to charge the phone. The controller
subsequently observed **2 saved, 0 failed, 0 cancelled, 0 remaining, 0
unconfirmed** on the ordinary status screen while the camera was disconnected.

Offline comparison of the copied native records verifies:

- The same C4 job completed, with its original submission date, recipe snapshot,
  ordered sources and Photos operation IDs. No replacement job was created.
- Exactly two new saved versions belong to those two operations and sources.
  The previous saved jobs and versions remain unchanged; all five catalogued
  versions have distinct Photos asset IDs and operation IDs.
- Both resumed outputs bind the exact retained source hashes and frozen C4
  settings, with full FINE 7728 × 5152 / orientation 8 geometry. Each has a new
  completed camera attempt, matching candidate/readback bytes, acknowledged
  owned deletion and an empty output view.
- All earlier native journal files remain byte-identical to the recovered
  checkpoint. The old uncertain trigger or deletion was not replayed. The two
  fresh camera attempts belong to the two explicitly resumed items.

**Bounded pass:** Home interruption, truthful paused state, camera-uncertainty
quarantine, human camera power cycle, fresh empty-output reconciliation, then
explicit completion of the same two-item job. Connect alone was insufficient;
this is not seamless recovery. No item had saved before this interruption, so
skipping an already saved item during this physical Resume remains unproved.
Camera uncertainty is separate from an uncertain PhotoKit save: this run never
entered that Photos failure window. Unplugging after completion does not prove
active-disconnect recovery.

## Read-only normal restart after completion

With the camera disconnected and all three jobs saved, the controller terminated
and launched the ordinary app without diagnostic/export flags. Launch succeeded
and the native Photos workspace loaded. The reopened catalog retains the same
three jobs, five saved versions and 42 imported recipe snapshots. All 79 native
journal files are byte-identical, with zero new camera operation or saved
association across this restart interval. This is a restart after completion,
not termination during a PhotoKit transaction.

### Saved paired C4 image after restart

The user selected the paired source's exported C4 version and confirmed that it
opened. The controller observed the correct source, highlighted exported-C4
version and upright image with the camera disconnected, no recipe selected and
Export disabled. The normal saved-version resolver retrieves the saved asset's
original JPEG through PhotoKit and copies it to the held viewer file without
reencoding; it does not resolve a saved version from the render cache.

The controller copied that held viewer file privately and independently hashed
its complete bytes. Exactly one copied file matched the saved version's recorded
native camera-output hash. Full JPEG decoding succeeded; Exif reports X-T5,
FINE, 7728 × 5152 and orientation 8. The original padded FINE metadata value and
the unmodified 22,699,525-byte image are retained in private evidence. A helper's
initial literal-FINE assertion rejected its trailing spaces; the corrected
assertion accepts only FINE plus padding, without changing image bytes.

After this read-only view, the three jobs, five versions, 42 recipe snapshots and
79 native journal files remain unchanged. This adds an independent bytes check
for **one paired C4 saved original**, not all four newly saved outputs. No new
capture-date/location query, Photos chronological UI comparison, broader visual
fidelity or precise image-region measurement is claimed.

## Evidence and remaining scope

Private root intent, catalog/journal copies and offline inspection remain under
ignored `.build/native-device-validation-20261027/`. Exact source, job, operation,
asset and run identifiers, filenames, hashes, profile names/settings and media
are not committed. The diagnostic text file copied from Documents contains old
timestamps and is not used as a current-run transport trace.

This native sequence added four saved versions through two deliberately
submitted jobs; the earlier single export makes five catalogued saved versions
in total. No user asset was deleted. The camera is disconnected while the phone
charges; no further physical camera test is running.

See the [acceptance matrix](acceptance.md) for remaining device gates. A distinct
mixed set of at least 50 sources with Instruments, active cancellation/retry,
disconnect recovery, uncertain PhotoKit completion, precise image detail,
chronology/GPS and accessibility coverage remain unproved.
