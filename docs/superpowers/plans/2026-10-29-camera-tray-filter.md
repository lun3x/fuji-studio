# Camera Tray Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional Photos-style tray filter for RAWs editable by the connected X-E3 or X-T5.

**Architecture:** Keep a complete accessible library and derive the presented grid from reducer-owned filter state. Assess metadata through the existing original-resource pool, caching metadata by original revision and results by camera support identity; a cancellable AppModel worker publishes results incrementally. A native SwiftUI glass menu controls the filter.

**Tech Stack:** Swift, SwiftUI, UIKit, PhotoKit, FujiCameraCore, Swift Testing, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-29-camera-tray-filter-design.md`

## Global Constraints

- Filter is optional, enabled only from its menu; labels are All Photos and Compatible with X-E3 / Compatible with X-T5.
- Existing strict source rules remain authoritative. No camera conversions or Photos writes for assessment.
- Keep the viewer; prune hidden batch members. Disconnect resets to All Photos.
- Use Jujutsu and the existing `/tmp/` workspace; push each checkpoint to `codex/camera-tray-filter`.
- Use a task-specific simulator and delete it afterward. Use project `.venv` for Python.

## Review Focus

- A matching model with unsupported RAW geometry/compression must remain excluded (Task 1).
- A camera change or original revision change must reject stale assessments (Task 2).
- Hidden viewed photos must not seed selection or reappear through a range callback (Task 2).
- Cancelling checks must release temporary resources and avoid late results (Task 2).
- Menus, progress and empty states must leave filtering reachable in both tray detents and landscape (Task 3).

### Task 1: Cache and assess original metadata

**Files:** `FujiStudio/Rendering/OriginalResourcePool.swift`, `FujiStudioTests/Rendering/OriginalResourcePoolTests.swift`.

**Interfaces:** Consume `SourceCompatibility.assess(_:for:)`; produce `OriginalResourcePool.assess(source:for:) async throws -> RAWCompatibility`.

- [ ] Add tests for X-E3/X-T5 strict assessments, metadata reuse, source revision invalidation, and camera-specific rejection not poisoning model recognition.
- [ ] Run `Scripts/test-ios.sh FujiStudioTests/OriginalResourcePoolTests`; expect missing API failure.
- [ ] Cache metadata after successful preparation and implement assessment through `withPreparedRAW` when uncached. Reuse cancellation, file cleanup and the resource gate.
- [ ] Run the focused suite; expect all tests passing. Checkpoint and push with Jujutsu.

### Task 2: Filter state and cancellable assessment worker

**Files:** create `FujiStudio/Workspace/PhotoTrayFilter.swift`; modify `WorkspaceState.swift`, `App/AppModel.swift`; add `FujiStudioTests/Workspace/PhotoTrayFilterTests.swift` and AppModel tests.

**Interfaces:** Produce `PhotoTrayFilter` (`allPhotos`, `compatibleWithCamera`), a camera support identity and revision-bound assessment results; reducer exposes visible source IDs and progress. AppModel consumes Task 1's assessment API, starts checks only for an enabled verified filter, and cancels/resumes on lifecycle changes.

- [ ] Write reducer tests for optional activation, exact model labels, unknown exclusion, progressive results, hidden selection pruning, stale result rejection, revision invalidation, camera replacement/disconnect and preserved viewer.
- [ ] Write AppModel tests for progressive checking without camera rendering/writes, cancellation on disabling/backgrounding, failed checks and cache reuse.
- [ ] Run focused suites; expect missing filter behavior failure.
- [ ] Implement reducer-owned visibility and result state; retain the unfiltered source index. Add one sequential cancellable worker, yielding between originals, with generation/context checks on results and lifecycle cleanup.
- [ ] Run focused tests and `Scripts/test-ios.sh --fast`; expect all passing. Checkpoint and push.

### Task 3: Floating native menu and validation

**Files:** create `FujiStudio/Workspace/PhotoFilterMenu.swift`; modify `WorkspaceView.swift`, DEBUG fixtures and `FujiStudioUITests/AppFlowTests.swift`; add `docs/validation/camera-tray-filter.md`.

**Interfaces:** Consume reducer filter and visibility; display only filtered sources in PhotoGrid while viewer uses the full index. Native menu emits the filter action and uses stable accessibility identifiers.

- [ ] Write UI tests for menu labels and optional activation, X-E3/X-T5 results, clearing the filter, selection pruning and empty results. Run a focused new case; expect missing menu failure.
- [ ] Add a circular glass menu opposite Select, blue active tint/checkmark, checking/failure count and an empty-state overlay. Preserve orientation-aware placement, Reduce Transparency support and 44-point targets.
- [ ] Run affected UI tests. Inspect light/dark, expanded/collapsed and landscape screenshots.
- [ ] Run complete `Scripts/test-ios.sh` and unsigned Release build. Request a fresh whole-branch code review; fix material findings with regression tests.
- [ ] Record results, checkpoint and push. Shut down and delete only this task's simulator. Retain the workspace/branch for user review.
