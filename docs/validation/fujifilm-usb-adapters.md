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

Full-suite baseline implementation: **`5f2192b5d38c`**. The measured WB
follow-up implementation is **`3ea81052d5a3`**, with its targeted checks below. Simulator: task-isolated iPhone 15 Pro,
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

One review minor remains deferred: persist known JPEG mismatch diagnostics before
cleanup so an interruption retains them. The WB capability discrepancy is resolved
by the completed controlled calibration and shared-core conversions below.

## Physical iPhone gates

Louisphone, iPhone 15 Pro / iOS 27.0.1, is paired and available. The Release build
from `5f2192b5d38c` (version 0.1/build 1, iPhoneOS 27.1 SDK)
passed `codesign --verify --deep --strict` and was installed successfully using
automatic signing, team `AZH3P824F3`, Apple Development identity. The initial
pre-fix build launched normally after the user unlocked the phone. The
updated build installed after a transient RSD channel failure; its launch was
refused because the phone had relocked. It is ready to open manually.
The independent unsigned simulator Release build also passed.

X-E3/iPhone: physical USB admission and seven-bank import/final context now pass
as recorded below. C4 portrait preview now passes as recorded below. Original-RAW decoding for both
encodings, offline editing, Photos export, saved-version viewing,
reconnect/background/cancellation and interruption recovery remain unverified. Mac RAW-decoding
results do not establish the phone's decoder result.

X-T5/iPhone: no X-T5 body is currently attached. Firmware4.31 admission, selector
restoration, preview/export, model switching and strict LMO output admission need
physical regression. Existing simulated-transport results do not replace it.

The earlier Release was installed and its launch attempts were refused solely
by the iOS lock screen; the pre-fix build's normal launch succeeded after unlock.
The current WB follow-up installation is recorded below. The camera remains idle with every Mac
session confirmed closed. The five-preset controlled WB calibration and restoration are complete;
the WB selector, complete table and all bank bytes are unchanged after conversion.

Software implementation, review fixes and laptop acceptance for the current seven
banks are verified. All nine known WB modes and physical X-E3/iPhone bank import are verified. Custom
measured-WB gains, phone image/lifecycle acceptance and physical X-T5 regression
remain outside the completed gates. The workbench and private evidence are retained at
`/tmp/fuji-usb-adapters-20261028` for that continuation; only this task's simulator
is removed after final verification.

## Completed preset WB follow-up

The user tagged Shade/Fluorescent1/2/3/Incandescent with distinct R/B values.
Exactly five pairs 445/447/449/451/453 matched. User restoration returned the full
WB table and every bank byte to baseline; Temperature 6300 K remained −4/−2.
Five frozen phone snapshots rendered through the shipping service after restoration,
with independently matching Fuji WB/fine-tune metadata, exact readback,
6000×4000 FINE/orientation 8, one trigger/delete, empty view and confirmed close.
The final backup again proved WB selector/table/banks unchanged. Four unclassified
bytes outside those regions differ from baseline; full-backup equality is not
claimed. Private images/backups are retained only in ignored storage.

The production change only adds the five measured dependency offsets to the
explicit verified set. Custom measured WB and substituted mode/pair combinations
remain rejected. Core 101/16, laptop CLI 6/3, iOS 468 Swift tests/57 suites plus 19
XCTest unit tests, and two affected UI cases pass. The earlier 545-pass full suite
is the baseline before this bounded mapping change. Both follow-up simulator and signed phone Release builds passed.
The public controlled/restored and conversion proofs are in
`Fixtures/XE3/1.30/preset-wb-*.json`. The active follow-up workbench is
`/tmp/fuji-xe3-wb-presets-20261028`.

The signed `3ea81052d5a3` Release (version 0.1/build 1, iPhoneOS 27.1 SDK) passed
`codesign --verify --deep --strict` and installed on Louisphone. Its normal launch
was refused solely by the iOS lock screen. The user subsequently connected the X-E3 and confirmed seven-bank import; the
persisted physical receipt is recorded below. No new camera operation is scheduled on the Mac. Only this follow-up's
simulator `BE837DC6-2B5F-4A3B-AE4A-C9973FD9B654` was shut down/deleted.

## Physical X-E3/iPhone seven-bank import

On 2026-10-28 the user connected the X-E3 in USB RAW CONV./BACKUP RESTORE mode,
opened the installed 3ea81052 Release normally and confirmed all seven recipes
imported. This establishes normal launch, physical USB admission and actual bank
import on iPhone 15 Pro / iOS 27.0.1.

A read-only copy of the app's catalog independently confirmed X-E3/1.30,
support `xe3-1.30-FF129505-v1`, slots 1–7, seven distinct snapshots with no recorded
rendering issues, and a shared final execution context/native generation 11.
All snapshot session identities/generations match the collection declaration.
Two consecutive database/WAL captures were byte-identical; SQLite integrity was
`ok`. The catalog uses format 3. Full catalogs, IDs, names and photo metadata stay
in private ignored storage. The sanitized proof is `phone-import-acceptance.json`
in the canonical XE3/1.30 fixture directory. Native command counts were not
captured on the physical phone and are not inferred from the catalog.

The app's source catalog does not yet contain the supplied DSCF0080–0086 files.
The user subsequently completed C4 preview on another X-E3 photograph, recorded
below. Exact source-encoding coverage, Photos export, original-RAW decoding,
saved-version and lifecycle gates remain pending. No camera session is opened by the Mac for this check.

## Physical X-E3/iPhone C4 preview

On 2026-10-28 the user confirmed a completed portrait C4 preview, then clarified
that they selected another photograph from this X-E3 instead of DSCF0085.
The app's completed operation journal independently confirms model X-E3/1.30,
recipe slot 4, 6000×4000 FINE/orientation 8, validated output, acknowledged trigger,
exclusive delete-intent marker, acknowledged cleanup and a verified empty camera
object view. There is no operation failure. A successful preview retains the
phone's camera session (`closure = notRequested`). Native command counts are not
captured and are not inferred from these acknowledgements.

The actual 601-byte FF129505 candidate and camera readback are byte-identical;
their checksum matches the journal. Result source/settings/context provenance
also matches the journal. Catalog/WAL copies became byte-identical after the
initial capture overlapped a catalog write, and SQLite integrity is `ok`.
The app still has the same 8 export jobs and 10 saved-version IDs as before the
image check: preview added neither an export job nor a saved version.

The original-transfer cache was empty when inspected, so this photo's compression
class and native original-RAW display outcome are not independently recorded.
The full JPEG was handed from the journal to the render cache as designed;
reading that cached file was blocked by iOS file protection while the phone was
locked. Independent JPEG-file inspection is pending. The public, sanitized proof
is `phone-preview-acceptance.json` in the canonical XE3/1.30 fixtures. Full journals,
catalogs and any image data remain private in ignored storage.

The next requested check is one deliberate C4 export and opening the resulting
saved portrait, with the phone kept unlocked for readback. Export/history and
saved-version acceptance are not claimed until that check completes.
