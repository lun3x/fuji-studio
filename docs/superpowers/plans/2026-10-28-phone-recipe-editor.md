# Phone Recipe Editor Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development inline.

**Goal:** Edit phone recipe names and the settings supported by the current camera renderer.
**Architecture:** A stable phone-preset identity references an immutable recipe snapshot. Draft edits preserve untouched raw values, validate changed fields, and atomically replace the current snapshot while retaining export history. A native form opens from a pencil button beside each phone row, works offline, and applies changes only on Save.
**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing and XCTest.
**Spec:** This document follows the user's explicit request for the previously deferred editor and the existing phone-recipe design.

## UX and constraints

Use a native sheet with a navigation title, Save, Cancel, a Name field and grouped look/white-balance/tone controls. Expose the validated renderer domain: film, dynamic range, grain, Color Chrome/Blue, white balance/temperature/shifts, highlights, shadows, colour, sharpness, noise reduction and clarity. Preserve existing unsupported values visibly; never substitute defaults on opening. Unsupported or missing fields do not prevent a name-only edit. Save validates changed values and shows failure inline without losing the draft. Cancel discards edits. Phone selection stays disabled offline; Edit and Delete remain enabled. Saving a selected preset requests its updated preview; unselected editing does not select it. No camera banks or saved versions are rewritten.

Use Jujutsu in this fresh temporary workspace and push checkpoints to the active development bookmark. Use the project's fast test wrapper for iteration, affected UI cases, the complete final wrapper, one independent review, Release builds and the existing signed-phone install workflow. Clean up the task simulator. No new camera/settings support or blank-recipe creation is included.

## Review focus

Retain stable preset identity across snapshot changes; reject stale drafts and edits after deletion; preserve unknown settings and frozen export history; reject invalid names/temperature; keep selection/preview intent consistent with edits, deletion and disconnect. Tests below exercise each.

## Task 1 — editable values and immutable persistence

- [x] Verify baseline on a new task simulator.
- [x] Add failing tests for supported/raw setting edits, name-only/unsupported preservation, validation, no-op saves, stable identity, durable restart, history and stale drafts/deleted targets.
- [x] Introduce PhoneRecipe (stable identity + snapshot), PhoneRecipeSetting and PhoneRecipeDraft. Update the existing phone APIs/consumers to stable identity. Atomically save a new snapshot; preserve membership, camera imports and export snapshots.
- [x] Run all unit tests and push a checkpoint.

## Task 2 — native editor and state integration

- [x] Add failing reducer/model and UI checks for selected/unselected updates, offline edit/save, cancel, invalid input, settings changes, persistence failure and largest text.
- [x] Add PhoneRecipeEditor and accessible pencil controls; preserve drafts on failure and prevent dismissal during saving. Forward through the real model and synthetic workspace fixture.
- [x] Run affected UI cases and unit tests, inspect screenshots, and push a checkpoint.

## Task 3 — completion

- [ ] Run the complete Scripts/test-ios.sh gate, Release build and independent review; fix substantive findings with tests.
- [ ] Update PR #16/validation documentation, install the verified signed build on the phone, and remove the task simulator.
