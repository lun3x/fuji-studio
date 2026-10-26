# Fuji Studio

An iOS app for developing Fujifilm RAW photos with a connected camera's own
conversion engine and saved profiles.

The initial target is a Fujifilm X-T5 connected over USB-C to an iPhone 15 Pro.

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

## Outside the initial scope

- Editing profile settings.
- Creating new profiles.

## Status

Repository initialized with the agreed initial requirements. The app has not yet
been implemented or tested on hardware.

## Development

Use Jujutsu (`jj`) for version control. If Python tooling is needed, use the
project's `.venv` rather than a global Python environment.
