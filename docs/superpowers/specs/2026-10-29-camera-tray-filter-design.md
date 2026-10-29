# Connected-camera photo tray filter

Status: approved by the user on 2026-10-29. The filter is enabled only from its menu.

## Intent

Add a Photos-style floating filter button to the photo selection tray so users
can browse and select only RAW photos the currently connected camera can edit.
An X-E3 connection filters for the supported X-E3 source class; X-T5 follows
its own existing source rules. Use the existing native SwiftUI glass controls,
UIKit grid and shared `FujiCameraCore` compatibility assessment.

## Approaches

An optional menu preserves full-library browsing and lets the user explicitly
choose when to narrow the tray. Automatically enabling the filter on connection
would save a tap but unexpectedly hide photos. The user chose the optional menu.

Within that approach, reusing only the existing model-recognition flag would be
quick but incomplete: undiscovered RAW models are unknown, and a matching model
does not prove the RAW's geometry/compression is supported. Use progressive
metadata assessment against the connected camera's existing source rules.

## Proposed interaction

- Float a circular glass button with the system filter symbol immediately left
  of Select in portrait and below Select in either landscape orientation.
  The user requested this placement refinement after the first phone install.
  Keep the selection count in its original leading corner, independently of the
  filter/Select group. Keep the filter available in browse and selection mode,
  collapsed and expanded, with upright controls in either landscape orientation.
- Its native menu contains **All Photos** and **Compatible with X-E3** or
  **Compatible with X-T5**, following the verified connected model. Show the current choice with a checkmark and
  tint the button blue while filtering.
- Start with All Photos. Connecting a camera does not enable the filter.
  Disable the camera option until a supported connection is verified.
- An enabled filter follows a replacement camera. Disconnecting returns to All
  Photos and cancels pending checks; reconnecting does not enable it again.
- Keep the current viewer image when narrowing the tray, but remove hidden
  photos from batch selection. Starting selection includes the viewed photo
  only if it is visible. Taps and range sweeps operate on visible thumbnails.
- Show a compact checking status as compatible photos appear. Show an explicit
  empty state when no matching photos are found, with All Photos still reachable.
  Photos whose compatibility is unknown or could not be checked stay hidden
  under the filter, with an indication when some photos could not be checked.

## Assessment and boundaries

Only the filtered tray starts compatibility checks. Assess RAW metadata locally
using `SourceCompatibility.assess`; do not send RAWs to the camera or perform a
conversion to test them. Reuse the existing resource preparation and cleanup
boundary, cache assessments by original revision and verified support version,
and cancel obsolete work on filter, library, camera or foreground changes.
Process checks incrementally so the tray remains usable. Original retrieval may
need iCloud; expose checking progress rather than treating unknown items as
compatible. Checking must yield between sources to interactive preview/export
work. A filter assessment must not overwrite model recognition with a
camera-specific rejection that could block another camera later.

Filtering changes the grid's presented index, not Photos discovery or the
underlying library. Preserve existing viewer, export admission and saved-version
behavior. No Photos writes, new dependencies, source-rule expansion or automatic
filter persistence are part of this change. Cache storage and worker structure
are implementation choices.

## Verification

Cover strict X-E3/X-T5 matching, unknown/unsupported RAWs, revision invalidation,
camera replacement/disconnection, hidden selection pruning and cancellation.
Exercise the native menu and tray in UI tests, including selection mode and an
empty result. Inspect light/dark and landscape screenshots. Run the complete
project test suite on a newly created task simulator, then shut it down and
delete it. Use Jujutsu checkpoints and push the development bookmark after each.
