# Automatic Camera Connection Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan inline. Steps use checkbox syntax for tracking.

**Goal:** Automatically connect and reconnect the camera without a Connect button.

**Architecture:** AppModel owns one foreground connection loop. Existing
ImageCaptureCore discovery handles attachment during an attempt; completed
failed attempts retry after three seconds. The production camera service keeps
ownership of verification, serialization and cleanup.

**Tech Stack:** Swift 6, SwiftUI, ImageCaptureCore, Swift Testing, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-28-auto-camera-connect-design.md`

## Global Constraints

- Use Jujutsu in `/tmp/fuji-auto-connect`; push checkpoints on `codex/auto-camera-connect`.
- Use the dedicated task simulator and delete it after verification.
- Retry delay is three seconds after completion; never overlap connection attempts.
- Never automatically replay conversion/export when reconnecting.

## Review Focus

- Launch and repeated start calls create only one connection attempt.
- Missing camera timeouts leave browsing usable without an error banner.
- Inactive/background transitions cancel discovery and stop retries.
- Foreground return reconnects even without a previous successful session.
- Ready/busy sessions and camera authorization denial do not trigger repeated opens.

### Task 1: Automatic connection and workspace UI

**Files:** AppModel.swift, ExportProgressView.swift, WorkspaceView.swift,
WorkspaceFixture.swift, FixtureEnvironment.swift, AppModelTests.swift,
AppFlowTests.swift, and a deterministic retry helper in test support.

**Interfaces:** AppModel initializer accepts a retry wait defaulting to
`Task.sleep(for:)`; start/sceneChanged own the loop. CameraServing is unchanged.

- [x] Add failing model tests for automatic startup, retry and lifecycle policy,
  with a manual retry wait and controllable fixture connection failures.
- [x] Run the new startup test against current product code and confirm failure.
- [x] Implement the foreground loop, single-attempt admission, quiet absent-camera
  failures, and authorization handling. Preserve manual internal connect callers.
- [x] Remove Connect from workspace composition and update fixture UI flows to
  wait for automatic readiness; keep disconnected tests explicitly disconnected.
- [x] Run focused model/UI checks, then the full simulator suite and Release build.
- [x] Review the complete diff, document validation, describe the Jujutsu change
  and push the active development bookmark.
