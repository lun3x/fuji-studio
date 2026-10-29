# Stable Photo Loading Ring Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan in the current session. Steps use checkbox syntax for tracking.

**Goal:** Show download progress using a clockwise ring without a visible percentage, and keep its position fixed throughout photo loading.

**Architecture:** Replace the conditional spinner/text stack with a fixed-size SwiftUI progress ring. Reuse `ImageLoadingState` and the existing photo overlay; change no loading or image lifecycle behavior.

**Tech Stack:** SwiftUI, XCTest UI automation, Jujutsu.

**Spec:** `docs/superpowers/specs/2026-10-28-photo-loading-indicator-design.md`

## Global Constraints

- Use a 48-point circular track with a thin, round-ended stroke.
- No number or text inside or below the ring.
- Reduce Motion disables continuous rotation.
- No dependencies or loading state transition changes.
- Use the isolated Jujutsu workspace and task-specific simulator.

## Review Focus

- Unknown → download → processing: the indicator's frame and center stay fixed.
- Download progress remains accessible without visible percentage text.
- Reduce Motion keeps a readable static processing indicator.
- Loading without an existing image uses the same centered indicator.
- The existing image frame and zoom survive loading transitions.

### Task 1: Replace the photo spinner with a stable ring

**Files:**
- Create: `FujiStudio/Workspace/PhotoLoadingRing.swift`
- Modify: `FujiStudio/Workspace/PhotoViewer.swift`
- Test: `FujiStudioUITests/PhotoViewerTests.swift`

**Interfaces:**
- Consumes: `ImageLoadingState.loading` and `.downloading(Double)`.
- Produces: `PhotoLoadingRing(loading: ImageLoadingState)` with accessible loading and download status.

- [x] Extend `testLoadingOverlayPreservesPhotoFrameAndZoom` to measure the actual indicator frame across download and processing, and assert no visible percentage.
- [x] Run the focused regression against the old spinner and observe the position failure.
- [x] Implement the fixed-frame ring with clockwise download fill and a rotating processing arc; preserve accessibility labels and percent values for assistive technology. Pause animation for Reduce Motion.
- [x] Run the focused viewer suite, including no-image loading; inspect screenshot attachments and check the Reduce Motion branch during review.
- [x] Run `Scripts/test-ios.sh` on the task's simulator and inspect the final result.
- [x] Review the change, record validation, and push the active bookmark with `jj`.

Validation: 517 passed, 3 established native-gate skips, 0 failures. See
`docs/validation/photo-loading-ring.md` for evidence and remaining device limits.
