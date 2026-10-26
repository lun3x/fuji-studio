# Fuji Studio

An iOS app for developing Fujifilm RAW photos with a connected camera's own
conversion engine and saved profiles.

The initial target is a Fujifilm X-T5 connected over USB-C to an iPhone 15 Pro.

## Design specification

Read the [initial product and technical specification](docs/superpowers/specs/2026-10-26-fuji-studio-design.md)
for the approved interaction model, source/version handling, export behavior,
recommended architecture, and device acceptance criteria.

The [self-contained interaction prototype](docs/superpowers/specs/assets/fuji-studio-prototype.html)
can be opened locally in a browser. Camera operations, recipe effects, and exports
in the prototype are simulated.

The [implementation plan](docs/superpowers/plans/2026-10-26-fuji-studio-implementation.md)
sets out the hardware feasibility gates, native app tasks, and acceptance checks.

## Initial scope

- Import existing conversion profiles from the connected camera.
- Access photos already imported into the iPhone's Photos library using an SD
  card reader.
- Support both standalone RAW photos and paired RAW+JPEG library items.
- Use the original RAW component of a paired RAW+JPEG item for camera conversion,
  without requiring the user to separate or re-import the pair.
- Select multiple photos, including a mix of standalone RAW and paired RAW+JPEG
  items, and apply the same camera profile to the entire selection in one batch.
- Apply an imported profile through the connected camera's conversion engine.
- Preview recipes, compare original and saved versions, and export the viewed
  photo or a batch as new Photos assets with the original capture dates.
- Browse through a vertically scrolling, expandable photo drawer and choose
  recipes from a floating menu using Apple's Liquid Glass design language.

## Outside the initial scope

- Editing profile settings.
- Creating new profiles.

## Status

The design specification and interaction prototype are approved. The
implementation plan is ready for review. The native app has not yet been
implemented or tested on hardware.

## Development

Use Jujutsu (`jj`) for version control. If Python tooling is needed, use the
project's `.venv` rather than a global Python environment.
