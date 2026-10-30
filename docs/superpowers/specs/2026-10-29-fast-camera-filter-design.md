# Faster camera compatibility filtering

The user approved both improvements from the code investigation: persist metadata across app launches and replace full RAW preparation during filtering with a metadata-only read. Existing camera admission rules, UI behavior, original viewing and conversion integrity remain intact.

## Approach

Store parsed `RAWMetadata` in atomic, disposable per-asset files in the app's caches directory. Records include the exact original resource token and a parser format version. A changed resource, invalid record, missing cache, or parser version change triggers a fresh check. Reapply the current `SourceCompatibility` rules on every assessment rather than persisting a camera-specific boolean. Cache failures must never prevent a successful assessment; transient retrieval failures are not cached.

Add a shared metadata parser accepting a bounded prefix and optional known total file length. It parses the same header, embedded JPEG properties, RAF geometry directory and required sensor TIFF scalars as conversion preparation. Incomplete prefixes request more bytes; malformed metadata fails. The PhotoKit reader accumulates only a bounded prefix, creates no temporary RAW file and computes no checksum. With a known original size it cancels the request as soon as metadata is available. Without a known size it retains the parsed prefix while allowing transfer completion to establish file bounds. Full preparation still verifies the complete SHA-256 and actual file bounds.

A 32 MiB prefix limit bounds malformed or unusually laid out metadata; exceeding it yields an unavailable assessment. This implementation choice prevents a filter scan from retaining entire large RAW files. PhotoKit/iCloud can still incur remote download cost before delivering the needed bytes.

Alternatives considered: persist yes/no results (requires invalidation for each camera rule change); use only camera name (weakens current geometry and encoding checks); retain full preparation (preserves avoidable copying and hashing). Parsed metadata plus the shared parser preserves semantics and removes the work identified in the investigation.

## Validation

Cover restart reuse, resource changes, malformed/deleted cache records, cross-camera reassessment, transient failures, stream completion/cancellation races, chunked/truncated metadata and a large payload that is never delivered to the filter. Keep checksum mutation tests for full preparation. Run package tests, affected unit and camera-filter UI tests, then the complete iOS suite on the task simulator. No physical-phone speed claim without a phone measurement.
