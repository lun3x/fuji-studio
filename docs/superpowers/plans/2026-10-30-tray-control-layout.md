# Tray control layout revision

The user specified the layout directly: float Select/Filter over the tray, keep Filter fixed between modes, put the selected count between Filter and clear selection, and make Select occupy exactly the count-plus-clear span. Put the circular day check before the date in portrait, below the date in both landscape directions. Use a grey circle with a light check, turning blue for a fully selected day.

Use a measured selection-control layout containing unstyled sizing labels at all times, with conditional overlays creating only the active glass controls. Reserve count width for the library's largest possible count so changes in digit count cannot shift Filter. Follow the tray's existing orientation-aware placement. Reserve the floating controls' footprint in portrait day headers, wrapping the date below that footprint at accessibility sizes when necessary. Keep landscape dates upright and at the top; inset top controls past the day-header column so they cannot obscure its date.

- [x] Fetch origin and create `/tmp/fuji-studio-tray-control-layout` from the active day-divider bookmark.
- [x] Prove existing positions fail the new controller and UI assertions.
- [x] Implement stable control layout, header placement, and circular check appearance.
- [x] Verify normal/large text, changing count digits, and both landscape orientations.
- [ ] Run unit tests, affected UI suites, and the complete iOS suite; review and push checkpoints.
- [ ] Refresh the signed phone build and remove the task simulator.

Task simulator: `BA2B3E78-4B84-4693-BBE5-A33170849558`.

Validation so far: all unit tests passed (555 Swift Testing cases and 24 XCTest cases). Focused UI tests passed for fixed Filter placement across modes and changing digit counts, inactive control removal, portrait date/check separation, and dated photos in both landscape directions with normal and AX5 text. Native screenshots verified the circular grey/blue checks and separate browse/selection controls. Independent review found the opacity-based glass visibility issue; conditional controls fixed it, and new inactive-button assertions plus screenshots verify the fix. No remaining source-level review findings. Full suite and phone build are in progress.
