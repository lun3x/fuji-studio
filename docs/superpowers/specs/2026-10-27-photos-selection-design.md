# Photos-style tray selection

The user's requested replacement for the slow All action is a Photos-style
selection tray: remove All and None, float Select at the tray's top right,
replace Select with an X that cancels selection, and dim selected photos with
a small blue checkmark at the bottom right.

Use the existing SwiftUI tray and UIKit collection view. Keep the selected
count, individual taps, range sweeps, scrolling, and the existing viewed-photo
behavior. Entering Select still includes the viewed photo; X clears batch
membership and returns to browsing that photo. Selection must not start a
Photos discovery pass.

## Approach

Overlay native glass controls on the grid below its drag handle, removing the
old controls row. This lets the button float above scrolling photos and keeps
the handle's drag gesture separate from selection. Retaining a fixed controls
row would not deliver the requested floating layout; rebuilding the grid would
unnecessarily replace working scrolling and range-selection behavior.

Use a neutral grey thumbnail overlay and a white checkmark in a system-blue
circle for checked cells. Hide the viewed-photo border during selection so it
does not compete with checked membership. Retain accessibility selection traits
and give the X the spoken label “Cancel selection.”

Remove the unused All/None actions, select-all task and full-index collector;
update fixtures and tests to select through taps or range membership. Preserve
the streaming discovery used to load the gallery. No new dependencies, Photos
writes, or camera operations are needed.

Verify selection/cancellation, stable grid positioning, range sweeps, scrolling,
collapsed/expanded tray geometry, light/dark appearance and large text. Use
Jujutsu for checkpoints and push the development bookmark after each one.
