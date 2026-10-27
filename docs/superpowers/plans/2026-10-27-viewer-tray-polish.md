# Viewer and photo tray polish implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Apply the five UI corrections requested on 2026-10-27.
**Architecture:** Keep the persistent SwiftUI workspace, native image scroll view and collection grid. Fix theme color at the image-view boundary; give the drawer one explicit drag height and a single release transaction; use background-matched Home clearance below the exact one-row collapsed viewport and scrolling bottom padding when expanded.
**Tech Stack:** Swift 6, SwiftUI, UIKit, XCTest and Swift Testing; existing iOS 27 target.
**Spec:** ../specs/2026-10-26-fuji-studio-design.md, as amended by the user's 2026-10-27 UI request.

## Global Constraints
- Jujutsu only; push every checkpoint to the existing development bookmark.
- Python, if needed, uses project .venv. No compatibility layer.
- No changes to camera conversion, profiles, Photos writing, or source/version identity.
- Collapsed tray shows exactly one square row with no next-row fragment; Select and Browse share layout and scrolling.
- Keep tap, accessible expand/collapse, Reduce Motion and Reduce Transparency behavior.

## Review Focus
- Releasing at a detent or returning to the same detent must not jump or strand a drag offset.
- Short fast flicks must project to a detent even before crossing the midpoint.
- Bottom safe area must not create a persistent strip over the photos or hide the final row.
- Theme changes must update an existing viewer without resetting its zoom.
- Large text, smaller viewports, selection and drawer changes must preserve persistent grid/viewer identity.

### Task 1: Viewer and tray corrections
**Files:** ZoomPhotoView.swift; DrawerGeometry.swift; PhotoDrawer.swift; WorkspaceView.swift; PhotoGrid.swift; PhotoGridController.swift; workspace geometry/hosting/UI tests and synthetic fixture.
**Interfaces:** Existing WorkspaceAction.drawerMoved and GridScrollRequest retain their meaning; the expanded grid receives bottom content padding, and collapsedGridHeight always describes its actual viewport.
- [x] Run existing geometry and workspace UI baseline; inspect actual layout.
- [x] Update collapsed-row assertions, add live-theme and bottom-edge hosting regressions, and add a native-frame trace for real drawer gestures; run to observe the failures.
- [x] Use dynamic system background, a grabber-only header, one-row measured detent, persistent drag height with velocity-projected release, and scrolling bottom padding instead of a material spacer.
- [x] Run focused geometry/hosting/gesture UI coverage, including release at full expansion, same-detent return and upward/downward flicks.
- [x] Run the complete simulator suite and universal Release build; inspect light/dark screenshots.
- [x] Commit and push using jj; obtain one fresh review of this change range and address substantive findings.
- [x] Install the reviewed build on the paired phone when reachable and record exactly what was verified.
