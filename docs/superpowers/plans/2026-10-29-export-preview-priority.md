# Responsive exports implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Let the newest temporary preview run before queued exports, and show batch progress on the status button.

**Architecture:** Keep one admitted camera operation at a time. Drain active work, coalesce waiting previews, then admit the latest preview before the next export item. Derive status progress from export events already published by the coordinator.

**Tech stack:** Swift actors, SwiftUI, Swift Testing, XCTest UI tests.

**Spec:** The user's request: browsing with a recipe must stay responsive during batch export, and the status button must show a progress bar.

## Constraints

- Use Jujutsu in `/tmp/fuji-studio-export-preview-priority`; push checkpoints to `codex/export-preview-priority`.
- Keep active native camera operations and Photos saves owned until completion.
- Run tests with task simulator `4D5C7567-8083-4101-B855-51A038D4B96C`; delete it when finished.
- Progress counts saved, failed, and cancelled items as processed; unconfirmed saves stay unfinished. Hide the bar for terminal runs.

## Review focus

- Repeated photo changes must discard obsolete queued previews.
- Cancelling a preview must allow exports to continue.
- Ending an export while a preview waits must release that preview.
- Pending Photos saves must not appear complete.
- A paused or completed export must remove active progress from the button.

## Task 1: Prioritize previews

Files: `FujiStudio/Rendering/CameraWorkScheduler.swift`, `CameraWorkScheduling.swift`, `PreviewCoordinator.swift`, `FileRenderCache.swift`, `FujiStudio/Workspace/WorkspaceState.swift`, `FujiStudio/App/AppModel.swift`, and their unit tests.

- [x] Add regression tests for newest-preview-before-export ordering, active-export admission, cancellation, and an AppModel preview during a held Photos save.
- [x] Run focused tests and confirm the old scheduler blocks previews.
- [x] Allow previews during an export job; dispatch the latest preview before queued export items without overlapping operations.
- [x] Run focused tests and the fast unit suite.
- [x] Checkpoint and push with Jujutsu.

## Task 2: Status progress

Files: `FujiStudio/Export/ExportCoordinator.swift`, `FujiStudio/Workspace/CameraStatusControl.swift`, `FujiStudio/Workspace/ExportProgressView.swift`, `FujiStudioTests/Export/ExportProgressTests.swift`, `FujiStudioUITests/ExportFlowTests.swift`.

- [x] Add tests for progress across saved, failed, cancelled, pending, and terminal states; add UI coverage for preview navigation during a held batch and progress visibility.
- [x] Run tests and confirm missing progress fails.
- [x] Add a compact linear progress bar inside the existing status button, preserving its hit area and camera indicator. Include processed/total in its accessibility value.
- [x] Run affected UI suites and the complete `Scripts/test-ios.sh` suite.
- [x] Review the final diff, checkpoint and push, and shut down/delete the task simulator.

## Execution record

- Fresh origin fetched; workspace starts at `main@origin` (`0b9a367f`).
- Root cause: `withPreview` waits whenever `exportJobID` is present, and dispatch withholds previews until `endExport`.
- Pre-flight: the two tasks share existing `ExportEvent` only; no new scheduler protocol is needed.
- Baseline: 517 unit tests passed. Regression run failed on the three expected preview-priority cases. After the scheduler fix, 520 unit tests passed (`20261029-165526-66985.xcresult`).
- The affected export and camera UI suites passed (8 tests passed, 1 existing opt-in native lifecycle test skipped); screenshots verified progress at 0/3, 2/3, and after completion (`20261029-165833-68629.xcresult`).
- Review identified two admission/handoff races. Regression tests reproduced both: busy photo/recipe changes had no queued preview, and export unpin could remove a cache hit before display ownership. Preview admission now returns an owned display copy, and the reducer queues against its verified busy session. A parallel paired-JPEG fallback preserves immediate original browsing.
- Final unit iteration: 526 Swift Testing tests plus 19 XCTest unit tests passed (`20261029-171037-73574.xcresult`). Independent review found no remaining concrete issues.
- Complete `Scripts/test-ios.sh` validation passed: 617 tests passed, 0 failed, 3 existing opt-in tests skipped (`20261029-171137-75093.xcresult`). Skips: native Home background boundary, hardware Escape dismissal, and native device rotation. Task simulator was already shut down by Xcode and has been deleted; its temporary Xcode test workers were automatically removed.
- Changes are pushed to `codex/export-preview-priority` and available in draft PR #38.
