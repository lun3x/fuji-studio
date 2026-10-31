# Batched RAW replacement cleanup

1. Reproduce repeated per-photo removal and inactive idle-timer restoration in
   coordinator/native pairer and app-model tests. Keep conversion and deletion
   ownership separate, retaining original assets and pinned JPEGs while staging.
2. Add one batch deletion API with all original/pair checks before PhotoKit
   submission. Journal job insertion/removal sequence for album placement during
   normal and split cleanup/retry. Keep passive checks read-only.
3. Finish queued conversions before deletion on Resume. Test cancellation and
   backgrounding before and after removal admission, and keep awake during a
   transient system presentation. Exercise multi-RAW and existing recovery UI.
4. Perform one independent final review; reproduce/fix Important findings and run
   fast, affected UI and complete validation. Build/sign/install the Release on
   Louisphone. Update PR #46 and merge once validation is resolved.

Review focus: asynchronous revalidation versus lifecycle admission, native
transaction ownership, crash boundaries around journal writes, exact resource
identity/hashes, metadata/album safety, and unknown Photos outcomes remaining
protected from resubmission.
