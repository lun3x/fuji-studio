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

## Follow-up: collapsed scrolling cue

The user clarified that the collapsed tray should show the top of the next row.
This supersedes the exact-one-row/no-fragment criterion above. Keep the overall
collapsed height; remove external bottom padding, put Home clearance inside the
scrolling content in both positions, and preserve viewed-item reveal.

- [x] Update native/window/next-row visibility expectations and observe RED.
- [x] Remove reserved band; verify visible partial row, final-row clearance and unchanged motion/theme behavior.
- [x] Run the full software gate, inspect the screenshot, commit/push and install the signed update.

## Follow-up: single workspace header

Use generic status/connect view-builder slots in WorkspaceView so one measured
row owns status, Export, Connect. AppWorkspaceView keeps the status sheet and
service actions, without an outer accessory row. Remove the title and its
reserved height. Preserve recipe/version access, AX icon adaptations, image/grid
identity, and the partial-row cue.

- [x] Observe RED for one-row ordering/no title/photo-space/status action checks.
- [x] Implement and verify normal/AX/compact layout and existing actions.
- [x] Complete full simulator/Release/signed builds and fresh scoped review.
- [x] Commit/push, install and record bounded phone verification.

## Follow-up: floating versions and gesture-only zoom

The user's explicit layout request replaces the bottom versions strip with a
top-right glass popover trigger, opposite the existing recipe button, and removes
the zoom button row. Reuse VersionList's identity/label generation in a vertical
menu; factor a VersionMenu trigger for workspace and generated viewer fixture.
Keep pinch/pan, double-tap, native accessibility actions, inspection retention,
image-status details, the single header and drawer behavior. No camera/Photos
service changes or compatibility mode.

**Files:** WorkspaceView.swift (measured overlays/photo area); PhotoViewer.swift
(status only beneath image); ZoomPhotoView.swift (remove unused button callbacks);
VersionList.swift / VersionMenu.swift (scrolling menu/trigger); ViewerFixture.swift;
PhotoViewerTests.swift, AppFlowTests.swift and WorkspaceLayoutTests.swift.

**Review focus:** unavailable RAW can switch back; long saved labels scroll at
AX5; dismiss never changes selection; same-source inspection survives menu
selection; gestures cannot activate recipe/Export; both overlays remain in the
photo bounds and above the expanded drawer; no reserved bottom control rows.

- [x] Observe the new layout/menu regression fail on the existing workspace.
- [x] Implement vertical versions popover and remove zoom/strip reservations.
- [x] Verify menu selection/dismissal, pinch/pan/fit, status details, compact/AX
  layout and persistent image/grid behavior; adapt existing button-driven tests.
- [x] Complete simulator/Release/signed builds and one fresh scoped review.
- [x] Commit and push using jj; install and record bounded phone verification.

Phone launch and live library loading are confirmed. Device Hub's remote tap did
not select a source. The user subsequently confirmed photo selection, the
top-right versions menu, switching versions and pinch-to-zoom on `2e45055b`, with
the bottom zoom buttons and versions row removed. This human confirmation is
separate from the software gate above.
