# Rejected Processing Profile Journal

**Goal:** Preserve the camera's processing settings when conversion preparation or profile readback fails, so a future failure can be investigated from the operation journal.

**Design:** Reuse the existing per-operation `baseline.bin`, `candidate.bin`, and `readback.bin` artifacts. Persist each received profile before validating it. Record the baseline checksum before adapter preparation. Existing failure, recipe identity, source identity, and camera context remain in `journal.json`. Do not relax profile validation or change camera commands. Keeping binary artifacts beside the journal preserves exact malformed and empty responses without expanding the JSON payload or introducing a schema migration.

## Implementation

- [x] Add regression cases in both the iOS service suite and the shared package suite: rejected baseline bytes (empty, truncated, and unexpected settings) survive reopening the journal; mismatched readback retains baseline, candidate, and actual returned bytes. Confirm errors still prevent conversion and deletion.
- [x] Run the focused iOS service suite and observe the new evidence assertions fail.
- [x] Persist the baseline and checksum immediately after receipt, before adapter validation. Persist readback immediately after receipt, before comparison.
- [ ] Run the focused suite, `Scripts/test-ios.sh --fast`, the shared package suite, and the complete `Scripts/test-ios.sh` suite on the task's isolated simulator.
- [ ] Review the small diff, push the checkpoint with Jujutsu on `codex/rejected-profile-journal`, and open a reviewable pull request.

## Review focus

Ensure rejected bytes survive exactly, including zero-length data; candidate bytes survive camera refusal; no conversion trigger follows any profile failure; storage failures remain fatal; existing successful profiles retain their original checksums and artifacts.

## Implementation checkpoint

Both new regression tests failed before the change because `baseline.bin` and `readback.bin` were missing. After the change, the focused iOS service suite passed 24 tests, `Scripts/test-ios.sh --fast` passed 516 tests, and the shared package suite passed 122 tests. An independent read-only review found no actionable issues. Complete iOS/UI validation is pending.

The change captures camera processing-profile responses for admitted conversions. Recipe validation before admission, existing journal retention policy, and payloads rejected by the transport's size limit remain outside this change. README documents the diagnostic directory and each artifact.
