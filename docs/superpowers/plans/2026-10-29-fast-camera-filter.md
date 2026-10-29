# Faster Camera Filter Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Avoid repeat original retrievals and full-file preparation when filtering compatible photos.

**Architecture:** Share structural RAF metadata parsing between verified full preparation and bounded streaming inspection. Cache parsed metadata per exact resource token; recompute current camera admission from it.

**Tech Stack:** Swift 6, PhotoKit, Foundation, ImageIO, Swift Testing, Jujutsu.

**Spec:** docs/superpowers/specs/2026-10-29-fast-camera-filter-design.md

## Global Constraints

- Jujutsu only; isolated /tmp workspace; push each checkpoint to codex/fast-camera-filter.
- Keep current camera admission rules and full conversion checksum verification.
- Cache IO failures are disposable misses. Never persist transient check failures.
- Use task simulator F7E75315-1188-404C-AD78-CBAEFD828EDF and delete it on completion.

## Review Focus

- Source revision/token changes invalidate disk metadata.
- Malformed cache records and unwritable cache directories cannot prevent checks.
- Cancellation before/during request registration completes exactly once.
- X-E3 sensor TIFF fields and geometry remain as strict as full preparation.
- Unknown resource sizes and out-of-bounds metadata cannot gain admission.

### Task 1: Shared metadata-only parser and PhotoKit stream

**Files:** RAFMetadataReader.swift, RAFSensorMetadata.swift in FujiCameraCore; new FujiStudio/Library/ResourceMetadataTransfer.swift; PhotoLibraryReader.swift; fixture readers and metadata tests.

**Interfaces:** Produce `RAFMetadataReader.metadata(in:fileByteCount:) throws -> RAWMetadata?` and `PhotoLibraryReading.rawMetadata(_:) async throws -> RAWMetadata`.

- [ ] Write failing parser and transfer tests: large undelivered sensor payload, chunking, matching metadata, malformed bounds, cancellation and unknown-size EOF.
- [ ] Run focused tests; expect missing API failures before implementation.
- [ ] Extract shared structural parsing, implement bounded stream with early cancellation, and wire native/fixture readers.
- [ ] Run package and affected unit tests; expect all passing and full-preparation mutation checks preserved.
- [ ] Commit and push checkpoint with Jujutsu.

### Task 2: Persistent metadata cache and pool integration

**Files:** new FujiStudio/Rendering/RAWMetadataCache.swift; OriginalResourcePool.swift; AppEnvironment.swift; OriginalResourcePoolTests.swift; AppModelTests.swift.

**Interfaces:** Consume `rawMetadata(_:)`; produce optional persistent metadata caching in OriginalResourcePool, wired for the live app.

- [ ] Write failing integration tests for cache reuse in a recreated pool, token/revision invalidation, different camera rules, corrupt/missing/unwritable cache, and retry after retrieval failure.
- [ ] Run focused tests; expect missing persistence/lightweight-path assertions to fail.
- [ ] Make RAWMetadata value types Codable, implement atomic versioned per-source records and use the lightweight reader in assess. Full preparation also seeds the cache.
- [ ] Update fixture expectations to distinguish metadata reads from full materializations; run all unit tests.
- [ ] Commit and push checkpoint with Jujutsu.

### Task 3: Final validation and review

- [ ] Run package tests, affected camera-filter UI suites and the full Scripts/test-ios.sh suite; expect no new failures.
- [ ] Obtain independent whole-change review; address material findings with failing regression tests.
- [ ] Record validation evidence, commit/push final checkpoint and delete task simulator.
