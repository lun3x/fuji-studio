# Fujifilm USB adapters — validation record

Implementation bookmark: `codex/fujifilm-usb-adapters`. The approved
[design](../superpowers/specs/2026-10-28-fujifilm-usb-adapters-design.md) and
[plan](../superpowers/plans/2026-10-28-fujifilm-usb-adapters.md) define the measured
support boundaries. This record separates native Mac hardware, software transport
fixtures and physical iPhone acceptance.

## Implemented boundaries

`Packages/FujiCameraCore` owns the adapter registry, semantic settings and passive
native snapshots, RAF admission, fresh-session imports, conversion, qualified JPEG
validation, durable operation intents and proven owned-output cleanup. Platform
ImageCaptureCore drivers deliver correlated callbacks and attachment continuity.
`Tools/FujiCameraLaptop` calls the same service. Python only analyzes evidence.

X-E3 admission requires FUJIFILM/X-E3/1.30, USB mode6 and FF129505/601-byte profiles.
All seven supplied RAFs are14-bit/version0130, recorded6000×4000: lossless containers
6048×4038 with crop21/16 and uncompressed6160×4032 with crop16/16, orientations1/8.
Unknown classes are refused. Conversion admission is independent of Apple RAW
viewing availability. Custom measured-WB gains remain unsupported.

Snapshots preserve model-scoped native bytes and frozen shared WB dependencies.
Offline edits preserve unknown fields; incompatible models cannot execute each
other's recipes or sources. Catalog upgrades preserve IDs, saved versions and
unresolved camera/Photos intents without replaying actions. The service rejects
unknown effective settings; a well-formed owned mismatch is cleaned up with the
normal ownership checks but never published. Unsafe ownership remains uncertain.

## Native Mac X-E3 acceptance

Measured on2026-10-28, firmware1.30. The initial disconnected import timed out and
closed. After the user reconnected, import passed with seven complete renderable
snapshots, exactly one backup read and a final verified native generation5.
No persistent camera setting or saved bank was written.

Seven bank/seven source conversions passed, covering both encodings/orientations
and C7's calibrated Underwater shifts. Each output was6000×4000 FINE, with exact
profile readback, qualified setting evidence, one trigger/delete, verified empty
view and confirmed session close. All original RAF checksums remained unchanged.
C3's explicitDR200 reference diagnostic, a C4 repeat and frozen C4 edits to10000K
and2500K also passed. Normal C3 remainsDR400. Public sanitized results and reference
statistics are under the core's `Fixtures/XE3/1.30/shared-core-*.json`; full photos,
backups, hashes, native diagnostics and journals stay in ignored private storage.

All31 native Kelvin choices independently matched qualified JPEG temperature.
5310K read back unchanged but rendered2500K and is rejected before upload.
See [the protocol record](xe3-laptop-protocol.md) for full measurements.

## Software gates

Latest implementation iteration: core99 tests/16 suites; native Mac CLI6/3;
iOS unit465/57, zero failures. The full simulator suite, Release builds and final
independent review are in progress. Existing opt-in native Home/background and
hardware Escape tests do not count as physical lifecycle proof.

## Physical iPhone gates

Louisphone, iPhone15Pro/iOS27.0.1, is paired and available. The final signed Release
bundle has not yet been installed for this adapter checkpoint.

X-E3/iPhone: USB mode/admission, seven-bank import/final context, real original-RAW
decoding for both source encodings, offline editing, preview/FINE Photos export,
saved-version viewing, reconnect/background/cancellation and interruption recovery
remain unverified on the physical phone. Mac compressed-RAW decoding failure does
not establish the phone's decoder result.

X-T5/iPhone: no X-T5 body is currently attached. Firmware4.31 admission, selector
restoration, preview/export, model switching and strict LMO output admission need
physical regression. Existing simulated-transport results do not replace it.

This branch is under validation; physical acceptance is not claimed complete.
