# Photos-style Selection Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this small change inline. Steps use checkbox syntax for tracking.

**Goal:** Replace All/None with floating Select/X controls and Photos-style checked thumbnails.

**Architecture:** Keep the existing reducer, SwiftUI drawer, UIKit grid and thumbnail provider. Move selection controls into an overlay, remove the full-library selection path, and update existing integration coverage.

**Tech Stack:** Swift 6, SwiftUI, UIKit, PhotoKit, XCTest/Swift Testing; iOS 27+.

**Spec:** `docs/superpowers/specs/2026-10-27-photos-selection-design.md`

## Global Constraints

- Use Jujutsu and push checkpoints to the active development bookmark.
- Use the project `.venv` if Python is needed.
- Do not keep obsolete selection APIs for compatibility.
- Do not write to Photos or operate the camera during validation.

## Review Focus

- Floating controls must not steal the drawer handle's gesture or move cells when selection toggles.
- X must clear membership while retaining the viewed source and drawer position.
- Grey overlays and blue checks must reset when cells are reused or selection ends.
- Overlay controls must remain usable at large text sizes and over both light and dark images.
- Replacing All in test setup must preserve batch, compatibility and export regression coverage.

### Task 1: Replace tray selection

**Files:** `WorkspaceView.swift`, `PhotoDrawer.swift`, `PhotoGridController.swift`, `WorkspaceState.swift`, `AppModel.swift`, `PhotoLibraryReader.swift`, `ExportProgressView.swift`, related fixtures and existing tests.

**Interfaces:** Keep `PhotoGrid` and range membership callbacks unchanged. `WorkspaceAction.select` and `.done` remain the enter/cancel transitions; remove `.all` and `.none`.

- [x] Update the existing app-flow selection test to require absent All/None, floating Select, an accessible Cancel selection X, stable cells and cleared checks on cancel.
- [x] Run that UI test against the current implementation and confirm the expected failure.
- [x] Implement the overlay, cell styling and removal of the select-all path; migrate existing test setup to taps/range membership.
- [x] Run focused app, library, reducer, grid and layout checks; inspect simulator screenshots in browse and selection states, light/dark and large text.
- [ ] Run the complete simulator test gate and a Release simulator build, then obtain one fresh code review.
- [ ] Record validation, checkpoint with Jujutsu, and push `codex/photos-style-selection`.

### Phone follow-up: Show the count only in Select mode

- [x] Render the count only while selecting, using checked membership directly.
- [x] Update existing selection/cancellation and layout snapshots for absent browse count.
- [x] Verify the selection flow, large-text layout and manual collapse, build Release and phone packages, then install the updated phone package.
