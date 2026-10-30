# RAW-only export to a real RAW+JPEG pair

With **Update original in Photos** enabled, RAW-only sources become a new
Photos asset containing the untouched RAW and the exported JPEG as originals.
The user chose to remove the previous RAW-only asset after verifying the pair.
Existing RAW+JPEG sources continue to use reversible edits. The setting stays
off by default and red.

## Approaches

- A reversible rendition preserves asset identity, but leaves the asset RAW-only.
- A paired copy can keep the old RAW, at the cost of a duplicate photo.
- **Chosen:** create and verify a paired copy, then remove the old RAW-only asset.
  Public PhotoKit resource creation cannot add an original to an existing asset.

## Safety and behavior

- Journal the source snapshot, metadata version, expected RAW/JPEG checksums,
  and operation ID before creating the pair. Use an operation-specific JPEG
  filename for recovery. Never resubmit an uncertain creation.
- Copy the original RAW bytes and pinned JPEG. Preserve capture date, location,
  favorite/hidden state, caption, rating, keywords, and writable regular albums.
  The new Photos asset has a different identifier; system analysis and shared
  album history cannot be transferred by these APIs.
- Read back both original resources and compare checksums. Decode the JPEG and
  check its geometry. Only then permit removal of the old RAW-only asset.
- Refuse removal if either asset changed during verification. Failed verification,
  lost access, denied removal, or interruption retain the original and leave an
  unresolved export. Passive recovery never changes Photos. Explicit Resume
  finishes an existing verified replacement without another creation.
- Persist verified replacement identity before removal. Remap current selection
  and catalog associations to the new asset, without altering frozen export jobs.
  A batch's own replacement notifications must not pause the batch.
- The picker shows RAW and Paired JPEG for the new pair, with no duplicate saved
  row for the same original JPEG. Later exports are reversible edits on that pair.

## Builder decisions

Use a dedicated durable JSON intent journal and a PhotoKit gateway with value
DTOs. Store source aliases in the catalog so confirmation and selection remain
correct regardless of whether a Photos change arrives before export completion.
Never export/delete real user photos as part of automated validation.
