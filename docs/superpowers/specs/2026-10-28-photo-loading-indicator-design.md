# Stable photo loading ring

## Intent

Keep the photo-loading indicator in one position throughout loading, and replace
the segmented system spinner with a thin circular ring.

## Approaches

- Keep the system spinner and reserve its percentage space: the smallest fix,
  but retains the appearance the user wants to replace.
- Pulse three dots with a percentage below: a contemporary alternative, but
  communicates download completion less directly.
- Use a circular progress ring: the user selected this approach and explicitly
  requested no visible percentage. The clockwise fill communicates download
  progress, and its fixed frame keeps download and processing states aligned.

## Design

Use a 48-point circular track with a thin, round-ended stroke, centered in the
existing photo overlay. Download progress fills clockwise from the top with no
number or text inside or below the ring. When downloading completes, the same
ring becomes a rotating arc while processing continues.
The frame and center remain unchanged. With Reduce Motion enabled, show a static
arc instead of continuous rotation. Preserve accessible loading/download labels
and values, the existing dimmed photo, zoom, and error behavior.

## Scope and validation

Implement with the project's existing SwiftUI APIs, without dependencies or
changes to loading state transitions. Extend the UI regression to measure the
indicator itself before, during, and after downloading. Verify
the photo frame and zoom remain unchanged, run the affected UI tests, and run
the complete project test suite. The exact stroke styling is the implementer's
choice. Physical camera conversion and export are outside this UI change.
