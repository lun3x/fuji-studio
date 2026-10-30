# Landscape selection controls and date footer

The selected-photo counter stays physically to the left of clear selection in portrait and both landscape orientations. Select occupies exactly that horizontal pair's footprint and keeps the same native width and height when rotating. Filter retains its position between browse and selection modes.

Latest steering: in both landscape directions, place the date at the bottom, eight points above the day checkbox. Restore Select and Filter to the tray's top corner by removing the day-header inset. Portrait day layout stays unchanged.

The previous `TraySelectionControlLayout` converts child sizes to portrait canvas coordinates, sums their heights in landscape, then rotates the combined span back into a tall button. Lay out this subgroup directly in window coordinates. Its parent continues positioning the subgroup and Filter on the tray.

The landscape detent reserves at least the measured control width plus its 24-point padding across the entire grid. At AX5, widen the date column enough to wrap the date between the top controls and bottom checkbox without overlap.

- [x] Verify the updated landscape UI assertions fail on the old layout.
- [x] Remove orientation conversion from the selection subgroup.
- [ ] Run focused portrait/landscape UI checks, unit tests, and the complete suite.
- [ ] Review and push the change, refresh the signed phone app, and delete the isolated simulator.

Isolated simulator: `C483CDFB-660A-4CCA-9BCF-593FDAF70393`.
Regression log: `/tmp/fuji-horizontal-selection-red.log`.
Focused checks after the AX5 clearance fix: `/tmp/fuji-horizontal-selection-green.log`.
Footer regression log: `/tmp/fuji-landscape-footer-red.log` (old date-to-checkbox gap was 288 points instead of 8).
Latest focused checks: `/tmp/fuji-landscape-footer-focused.log`.
