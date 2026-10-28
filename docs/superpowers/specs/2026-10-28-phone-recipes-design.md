# Phone recipes: copy and save

## Intent and agreed scope

The user chose independent recipes saved on the phone, rendered by the connected
camera. They then narrowed this first increment to copying and saving camera
recipes so the UX can be refined step by step. Editing, creating from scratch,
renaming and deleting are deferred.

## Approaches

- **Independent phone copies with the existing camera renderer — selected.**
  Copies survive camera refreshes and app restarts and use the established
  preview/export pipeline.
- **Phone RAW processing — not selected.** This would require a separate renderer.

## Interaction

The existing recipe popover gains a segmented **Camera / Phone** selector.
Opening the menu shows the selected recipe's collection, defaulting to Camera.
Both collections offer **No recipe**.

Each imported C1–C7 row has a separate copy-to-phone icon with an accessible
label. Copy saves the exact name and settings immediately, then shows the Phone
tab. It does not select another recipe or change the photo. Tapping a phone row
selects it and closes the menu. Repeated copies of the same imported snapshot
reuse its saved copy. Saving failure keeps the current tab and shows an inline
error with retry possible through the same copy action.

The Phone tab lists saved copies by name. An empty state explains the camera-row
copy action. Phone copies have a phone indicator, including in the floating
trigger and saved image versions; camera recipes keep their C-slot badges.

Cached camera recipes can be copied without a camera. Phone recipes can be
selected offline; preview/export requires a compatible connected camera. Camera
recipe selection keeps its existing connection requirement. Phone selection
survives disconnect/reconnect and camera recipe refreshes.

## Data and constraints

Use SwiftUI and the existing durable SwiftData catalog. A copied recipe gets a
new immutable snapshot ID and records the original snapshot ID as provenance;
all imported bytes, name, settings digest, support observations and camera
context are preserved. Store the phone collection independently of the camera
collection. Preview and export continue to use frozen recipe snapshots.
Unsupported imports remain copyable and clearly marked, but cannot render.
Copying never changes camera banks or writes Photos assets.

Exact spacing and icon choice are builder decisions. No edit screen, blank
recipe creation, deletion, syncing, sharing, or new camera/setting support is
included in this increment.

## Verification

Test lossless copy, repeat-copy idempotence, durable restart, camera-refresh
isolation, independent selection, offline/reconnect behavior, unsupported-copy
handling, save failure, phone export provenance, tabs and accessible controls.
Use a fresh task-specific simulator, relevant unit/UI tests and a Release build;
shut down and delete the simulator when finished. Use Jujutsu in the temporary
workspace and push the development bookmark at each checkpoint.

## Approval

Approved direction: the user's instruction to start with copying and saving,
with editing deferred. Implementation follows that reduced scope.

## Follow-up: deletion and disconnected selection

The user subsequently requested phone recipe deletion and greyed-out phone rows
when disconnected, matching camera recipes. This follow-up supersedes the earlier
offline-selection behavior and the deletion exclusion.

Each phone row has a separate, accessible trash icon. Deletion is available
offline and requires an in-app confirmation identifying the recipe. It removes
only local chooser membership; immutable snapshots, saved photos and frozen
export history are retained. Deleting the selected recipe clears selection and
invalidates its pending preview. Deleting another recipe preserves the selection;
failed persistence leaves the row/selection intact with a retryable error.

The phone selection button is greyed out and disabled under the same connection
rule as camera rows. Disconnecting clears either kind of selected recipe; a new
connection does not automatically reselect it. Copying cached recipes and
deleting phone recipes remain possible offline. Editing remains deferred.

## Follow-up: name and settings editor

The user subsequently requested the edit screen, superseding the earlier editing
exclusion. An accessible pencil beside each phone recipe opens a native form
with Save and Cancel. Name, Look, White balance, and Tone and detail sections
expose the settings already supported by the current X-T5 conversion profile.
Editing and saving work offline; selecting a recipe for rendering still requires
a connected camera. Cancel discards changes, and validation/persistence failures
keep the draft open with a visible error.

Phone membership has a stable identity based on its original source snapshot,
while every saved name/settings revision is an immutable recipe snapshot. Saving
the selected preset supersedes its pending preview with the new revision. Editing
an unselected preset does not select it. Camera banks, prior exports and their
names/settings remain frozen. Stale drafts and updates after deletion are rejected.
This reuses existing catalog fields without a model-schema migration.

Controls offer the currently validated conversion domains, including film,
dynamic range, grain, Color Chrome/Blue, white balance/temperature/shifts,
highlights, shadows, colour, sharpness, noise reduction and clarity. An existing
unsupported value remains visible and unchanged until explicitly replaced.
Unsupported camera contexts permit name-only edits. Opening/saving an unchanged
recipe does not normalize opaque settings or create a new snapshot. This step
does not add camera capabilities, renderer domains or blank-recipe creation.

## Follow-up: independent grain controls

The user requested separate Grain effect (Off/Weak/Strong) and Grain size
(Small/Large) pickers. Off disables and greys out the size picker while retaining
the last size in the phone snapshot, including across Save/reopen. Effect changes
preserve size and size changes preserve effect. All six combinations can now be
saved; untouched legacy/unknown raw values remain unchanged. The existing camera
renderer still accepts only the measured Off/Small, Off/Large and Strong/Small
combinations. The user subsequently requested removal of the explanatory grain
and unsupported-value footer; the form contains the controls without that text.
No camera bank or new working-profile mapping is written by this UX change.
