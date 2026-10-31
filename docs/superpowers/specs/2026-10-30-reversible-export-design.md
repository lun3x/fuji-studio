# Reversible export and app settings

## Intent

Add app settings to the existing status sheet. The first setting lets an export
update the source photo's appearance in Photos without creating another library
item or destroying its originals.

The user selected a reversible Photos edit after considering destructive JPEG
replacement. This is a contained feature; this short design records the behavior
and the correctness requirements for implementation.

## Approaches

- **Separate JPEG:** the current behavior; preserves every export as a separate
  Photos item, but adds items to the library. Keep this when the setting is off.
- **Replace original JPEG resources:** the initial request. This would sacrifice
  original content and does not fit the user's subsequent preference.
- **Reversible Photos edit (selected):** save a rendered JPEG and adjustment data
  on the existing asset through PhotoKit's content-editing API. Photos preserves
  original RAW and JPEG resources and supports Revert to Original. This updates
  the current appearance, rather than creating an original RAW+JPEG pair or an
  independent Photos item for each export.

## User-facing behavior

- Rename the sheet to **Status & settings**, retaining its status information,
  camera recovery controls, and export progress.
- Add a Settings section with **Update original in Photos**, off by default.
  The setting label is red, as requested. Supporting text explains that exports
  update the existing photo, preserve originals, and can be reverted in Photos.
- Persist the setting across app launches. Capture its value when an export job
  starts; changing it never redirects an already queued or interrupted job.
- When enabled, both RAW-only and RAW+JPEG source assets receive a reversible
  current JPEG rendition. The RAW and any original camera JPEG remain intact.
- Each asset has one current Photos appearance. A subsequent export replaces
  that appearance; this feature does not promise a permanent history of every
  rendition. Revert to Original restores the original, rather than the preceding
  Fuji Studio export.
- The user confirmed that losing earlier edited renditions is acceptable, with
  the requirement that those earlier renditions disappear from the version picker.
  Show only the latest matching current edit; hide superseded or reverted edits.
- If Photos cannot edit an asset or the write fails, report the failure. Never
  silently create a separate JPEG or delete/recreate the source asset.

## Implementation constraints

- Reuse the app's existing SwiftUI, PhotoKit writer boundary, durable export
  journal, and catalog. Store preferences separately from photo/recipe data.
- Persist the export destination in jobs and saved versions. Retain operation
  identity in Fuji Studio adjustment data, along with the frozen recipe.
- Recovery verifies the exact adjustment operation on the exact source asset.
  An inaccessible, reverted, or superseded edit cannot confirm an earlier export.
  An uncertain write is never automatically resubmitted.
- Saved-version display must resolve the matching edited rendition, never the
  original JPEG or a later edit. Superseded/reverted results are unavailable;
  their historical records must not label the latest pixels as an older recipe.
- Original-resource identity remains stable across reversible appearance edits,
  so our own edits do not invalidate an interrupted batch or source RAW cache.
  Actual original resource changes must still invalidate stale work.
- Normalize JPEG orientation for PhotoKit's editing-output contract. Keep render
  files alive through actual PhotoKit completion, including cancellation.
- Use only Jujutsu, a task workspace under /tmp, a task-specific simulator, and
  the project's test script. Do not add compatibility shims for historical data.

## Verification

Cover preference persistence/defaults, frozen job destination, both export modes,
original preservation, edit-operation recovery, authorization/failure paths,
orientation, and detection of replaced/reverted edits. Add a focused UI check for
the status/settings sheet and toggle. Run fast unit iterations, affected UI
tests, and the complete iOS suite before reporting completion. Simulator fixtures
cannot prove PhotoKit support for every real Fujifilm RAW; report any remaining
physical-device validation limit explicitly.

## References

- https://developer.apple.com/documentation/photos/phcontenteditingoutput
- https://developer.apple.com/documentation/photokit/editing-asset-content
- https://support.apple.com/en-ph/guide/iphone/iph2413db0ab/26/ios/26
