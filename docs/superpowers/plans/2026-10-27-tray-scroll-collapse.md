# Tray scroll collapse implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this single task inline.

**Goal:** Pulling down past the top of the expanded photo grid drags and collapses its tray.

**Architecture:** Bridge the native collection pan to the existing drawer drag.
Use window coordinates, consume only translation beyond the grid's top, and
reuse the divider's height, detents, spring and manual-collapse callback.

**Tech stack:** Swift 6, SwiftUI, UIKit, XCTest and XCUITest.

**Spec:** `docs/superpowers/specs/2026-10-27-tray-scroll-collapse-design.md`.

## Constraints and review focus

- Use Jujutsu in `/tmp/fuji-studio-tray-scroll-collapse`; push the task bookmark.
- Use a dedicated simulator, then shut down and delete it.
- No changes to viewed source, selection membership or persistent grid identity.
- Test top crossing during one pan, short pulls, reversal, cancellation,
  inertial scrolling and collapsed-tray scrolling.
- Keep header gestures and horizontal range selection working.

## Task 1: Native scroll handoff

**Files:** `PhotoGridController.swift` owns pan admission and grid pinning;
`PhotoGrid.swift` bridges events; `PhotoDrawer.swift` shares drag handling;
`WorkspaceView.swift` wires expanded state and callbacks.

- [x] Add a UI regression in `WorkspaceLayoutTests.swift` using a slow downward
  pull from the first row in Browse and Select; assert collapsed detent,
  continuous native frames and unchanged viewed source/checks.
- [x] Run that test against the original implementation and observe failure.
- [x] Add the pan bridge and reuse the divider's drag and release handling.
- [x] Cover boundary admission/cancellation in `PhotoGridControllerTests.swift`
  and short-pull/top-crossing behavior with UI tests.
- [ ] Run focused tests, then `Scripts/test-ios.sh` on the task simulator;
  inspect the result and gesture evidence.
- [ ] Review the diff, commit with `jj`, push `codex/tray-scroll-collapse`,
  and remove the task simulator.

Review caught grid ownership persisting after reversing beyond the expanded
height. The added reversal test failed at the expected offset and deceleration
assertions, then passed with the ownership handoff fixed. All 13 controller
tests pass. Final simulator validation is recorded separately when complete.
