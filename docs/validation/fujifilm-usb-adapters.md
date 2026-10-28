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

X-E3 admission requires FUJIFILM/X-E3/1.30, USB mode 6 and FF129505/601-byte profiles.
All seven supplied RAFs are 14-bit/version0130, recorded 6000×4000: lossless containers
6048×4038 with crop 21/16 and uncompressed 6160×4032 with crop 16/16, orientations 1/8.
Unknown classes are refused. Conversion admission is independent of Apple RAW
viewing availability. Custom measured-WB gains remain unsupported.

Snapshots preserve model-scoped native bytes and frozen shared WB dependencies.
Offline edits preserve unknown fields; incompatible models cannot execute each
other's recipes or sources. Catalog upgrades preserve IDs, saved versions and
unresolved camera/Photos intents without replaying actions. The service rejects
unknown effective settings; a well-formed owned mismatch is cleaned up with the
normal ownership checks but never published. Unsafe ownership remains uncertain.

## Native Mac X-E3 acceptance

Measured on 2026-10-28, firmware 1.30. The initial disconnected import timed out and
closed. After the user reconnected, import passed with seven complete renderable
snapshots, exactly one backup read and a final verified native generation 5.
No persistent camera setting or saved bank was written.

Seven bank and seven source conversions passed, covering both encodings/orientations
and C7's calibrated Underwater shifts. Each output was 6000×4000 FINE, with exact
profile readback, qualified setting evidence, one trigger/delete, verified empty
view and confirmed session close. All original RAF checksums remained unchanged.
C3's explicit DR200 reference diagnostic, a C4 repeat and frozen C4 edits to 10000 K
and 2500 K also passed. Normal C3 remains DR400. Public sanitized results and reference
statistics are under the core's `Fixtures/XE3/1.30/shared-core-*.json`; full photos,
backups, hashes, native diagnostics and journals stay in ignored private storage.

All 31 native Kelvin choices independently matched qualified JPEG temperature.
5310K read back unchanged but rendered 2500 K and is rejected before upload.
See [the protocol record](xe3-laptop-protocol.md) for full measurements.

## Software gates

Validated implementation revision: **`5f2192b5d38c`**. Later documentation
checkpoints do not change production code. Simulator: task-isolated iPhone 15 Pro,
iOS 27.0. Latest signed phone artifact: version 0.1/build 1, iPhoneOS 27.1 SDK.

The first complete simulator run passed **543 tests, three established skips,
zero failures** (546 total), result `20261028-201726-2333.xcresult`. The skips are
native Home/background, native rotation and hardware Escape, each opt-in.
Core 99 tests/16 suites and native Mac CLI 6/3 also passed; the core run explicitly
included all seven private RAFs, the camera JPEG and the restored backup.

The independent whole-branch review found no Critical issues and two Important
issues: recipe persistence failure stranded a live camera context, and commit
interruption was not actually covered. The app now closes the live context on
failed import/commit so Connect can retry without a cable reconnect. The new
regression failed with four assertions before that fix, then passed. Catalog
upgrade tests now interrupt immediately before durable commit and verify rollback
of payloads/format, frozen version/phone IDs and unresolved Photos intent on
restart. A multi-record journal test interrupts its second durable replacement,
then verifies mixed-format restart, history and exclusive delete markers. The
catalog boundary hook first failed to compile before implementation; the journal
needed coverage only and passed its new injected failure test unchanged.

After these fixes, the complete suite passed **545 tests, three established
skips, zero failures** (548 total), result `20261028-204103-7919.xcresult`.
That includes 467 Swift tests/57 suites, 19 XCTest unit tests and 62 UI cases
(59 passing, three skipped). Both final simulator Release and signed phone
Release builds passed. Core 99/16 and native Mac CLI 6/3 remain green; those modules
were unchanged by the app recovery fix.

Two review minors are deferred: persist known JPEG mismatch diagnostics before
cleanup so an interruption retains them, and distinguish the five pending WB
preset dependencies in renderable capability choices. Snapshot admission already
blocks unverified dependency execution; the current seven imported banks pass.

## Physical iPhone gates

Louisphone, iPhone 15 Pro / iOS 27.0.1, is paired and available. The Release build
from `5f2192b5d38c` (version 0.1/build 1, iPhoneOS 27.1 SDK)
passed `codesign --verify --deep --strict` and was installed successfully using
automatic signing, team `AZH3P824F3`, Apple Development identity. The initial
pre-fix build launched normally after the user unlocked the phone. The
updated build installed after a transient RSD channel failure; its launch was
refused because the phone had relocked. It is ready to open manually.
The independent unsigned simulator Release build also passed.

X-E3/iPhone: USB mode/admission, seven-bank import/final context, real original-RAW
decoding for both source encodings, offline editing, preview/FINE Photos export,
saved-version viewing, reconnect/background/cancellation and interruption recovery
remain unverified on the physical phone. Mac compressed-RAW decoding failure does
not establish the phone's decoder result.

X-T5/iPhone: no X-T5 body is currently attached. Firmware4.31 admission, selector
restoration, preview/export, model switching and strict LMO output admission need
physical regression. Existing simulated-transport results do not replace it.

The latest Release is installed and ready to open manually. Its two launch
attempts were refused solely by the iOS lock screen; the earlier build's normal
launch succeeded after user unlock. The camera remains idle with every Mac
session confirmed closed. The five-preset controlled WB question is still pending;
the last measured WB table and all bank records were unchanged after conversion.

Software implementation, review fixes and laptop acceptance for the current seven
banks are verified. The five additional WB dependencies and physical iPhone/X-T5
acceptance remain outstanding. The workbench and private evidence are retained at
`/tmp/fuji-usb-adapters-20261028` for that continuation; only this task's simulator
is removed after final verification.
