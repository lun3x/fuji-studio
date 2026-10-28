# Collapse the photo tray by pulling past the top

The user's requested interaction is a continuous handoff: in the expanded tray,
drag photos down to scroll toward the first row, then move the tray down once
the grid cannot scroll further. Release uses the divider's detent and spring.
Browse and Select behave alike and preserve the viewed photo and checked set.

## Approach

Observe the collection view's existing pan recognizer and pass only movement
beyond the top to the drawer. Share the drawer's drag-height and settling path
with the header. Measuring translation in the window avoids feedback as the
grid itself moves. Pin the grid at the top during a drawer pull and suppress
scroll deceleration on release. Horizontal selection keeps its existing
recognizer and does not participate in the handoff.

A second competing pan recognizer would complicate selection arbitration.
Triggering collapse from bounce offsets would lose direct finger tracking and
could collapse the tray from inertial scrolling. Neither fits the requested feel.

## Boundaries

Only an expanded tray can hand off an active user scroll. Ordinary scrolling,
programmatic reveals, deceleration and collapsed-tray bounce do not move the
drawer. A short pull settles back; reversal moves the tray back up, then returns
any remaining movement and momentum to native grid scrolling. Cancellation
restores the current detent. A completed collapse keeps the existing reveal of
the viewed source. No dependencies or layout changes are needed.
