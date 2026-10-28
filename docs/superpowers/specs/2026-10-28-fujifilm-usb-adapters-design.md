# Fujifilm USB camera adapters

Status: approved by the user on 2026-10-28. Scope: additional **Fujifilm cameras
over USB**. The user approved this document and requested the next step.

## Intent

Add the measured X-E3 to Fuji Studio while making later Fujifilm USB RAW bodies
an adapter addition. Continue using the connected camera's rendering engine.
Use the same Swift protocol, codecs and conversion service on the laptop and
phone, so laptop experiments exercise the implementation that ships.

The existing `CameraServing` is the correct boundary for the application,
preview scheduler and export coordinator. Keep that boundary and extract the
common operation owner from `XT5CameraService`. Model adapters implement the
camera-specific behavior underneath it.

## Approaches

1. Separate complete services for each model would fit `CameraServing`, but
   would duplicate operation ownership, cancellation, journaling and cleanup.
   Fixes would have to be carried across services.
2. A shared Fujifilm service plus model adapters centralizes those invariants
   and accommodates different bank/profile codecs. This is the recommended
   approach, consistent with the interface the user described.
3. A general multi-brand driver/plugin framework would add unrelated transport,
   device-discovery and deployment concerns. The confirmed Fujifilm USB scope
   does not require it.

The user approved approach 2: a shared Fujifilm service plus model adapters.

## Scope and boundaries

Initial adapters: X-T5 firmware 4.31 / observed FF179502 625-byte profile, and
X-E3 firmware 1.30 / observed FF129505 601-byte profile. Their evidence boundaries
remain explicit; adding the X-E3 must not silently widen the X-T5's accepted
settings or source classes.

Include automatic model selection, recipe import, phone copies/offline editing,
camera previews, full-size FINE export, model-aware setting choices and existing
saved-version behavior. Keep one connected camera active at a time.

No Wi-Fi/Bluetooth, other brands, downloadable plugins, camera shooting/live
view, persistent camera-bank editing, cross-model RAF conversion, automatic
cross-model recipe translation or new RAW-decoder dependency. The measured
X-E3 trigger-0 preview remains a later optimization; this release uses trigger 1
and full-size FINE for preview and export.

## Structure

```text
App / Photos / catalog / preview / export
                  |
             CameraServing
                  |
         FujiCameraService actor
          /         |          \
   session I/O   journal/gate   adapter registry
       |                           /       \
ImageCaptureCore               XT5Adapter  XE3Adapter
                                  |           |
                             model codecs / capabilities
```

Use one local Swift package, `Packages/FujiCameraCore`, for the protocols,
model-neutral runtime values, PTP datasets, codecs, adapters and shared service.
It targets iOS/macOS and has no UIKit, SwiftUI, PhotoKit or ImageCaptureCore
lifecycle dependencies. Foundation/CryptoKit and shared Apple image-validation
facilities are acceptable. Native session drivers remain platform wrappers;
iOS authorization and Mac discovery differences stay there.

The existing operation journal is retained as the authoritative durable policy.
The core takes a journal/storage abstraction so the phone's file protection and
the laptop's private output directory are storage details. Reuse common atomic
write/synchronization code where possible rather than copying the journal state
machine. Exact package targets, access levels and file placement are builder
choices; extracting many separate packages is unnecessary.

The native laptop runner imports this package. The Python image-comparison
utilities can remain analysis tools, but the bank/profile implementation used
by the app must be Swift code shared with the laptop runner.

## Interfaces

These are contract sketches; concrete type names may change during planning.

```swift
protocol FujiCameraAdapter: Sendable {
    var id: CameraAdapterID { get }
    var conversionDialect: FujiRAWConversionDialect { get }
    var recipeImportSessionPolicy: RecipeImportSessionPolicy { get }

    func verifyDevice(
        _ device: FujiDeviceInfo,
        io: CameraOperationIO
    ) async throws -> VerifiedCameraSupport

    func importRecipes(
        io: CameraOperationIO,
        support: VerifiedCameraSupport
    ) async throws -> DecodedRecipeCollection

    func decodeRecipe(_ snapshot: RecipeSnapshot) throws -> RecipeAssessment

    func encodeEditedRecipe(
        _ settings: RecipeSettings,
        preserving snapshot: RecipeSnapshot
    ) throws -> RecipeSnapshot

    func prepareConversion(
        baseline: Data,
        source: RAWMetadata,
        recipe: RecipeSettings,
        support: VerifiedCameraSupport,
        policy: OutputPolicy
    ) throws -> PreparedConversion

    func validateOutput(
        _ jpeg: Data,
        conversion: PreparedConversion
    ) throws -> ValidatedCameraOutput
}
```

`VerifiedCameraSupport` contains the actual model/firmware, adapter support
version, capabilities, source constraints and required protocol checks.
The service adds fresh session identity/generation; an adapter cannot invent a
camera-reported capability string. The X-E3's capability/support identifier is
explicitly an application identifier, unlike the X-T5's returned D186/D187 text.

`PreparedConversion` binds the generated profile bytes, requested settings,
source context, output policy and model-specific validation expectations.
It is not an arbitrary list of PTP commands. Header/opaque baseline bytes and
fresh-source requirements are enforced by the codec.

`FujiRAWConversionDialect` describes the supported Fuji upload/profile/trigger
operations and ObjectInfo encoding for the common conversion state machine.
The first two models share the measured 900C/900D/D185/D183 sequence. Future
models can provide a different supported dialect or composed family codec;
model checks must not spread through the application.

`CameraOperationIO` is scoped to a service-owned exclusive operation and its
current native session generation. It exposes the reads and declared temporary
bank-selection access required for importing. It cannot initiate independent
connections, delete arbitrary objects, write persistent bank contents, or let
an importer start a conversion. Cleanup/selector restoration remains bounded
and owned after cancellation; borrowed access expires when its owner finishes.

## Shared service ownership

The service exclusively owns discovery/open/close, context creation and
revocation, command correlation, one-wire-command ownership and one whole-
operation FIFO gate. Preserve these current behaviors:

- Validate original bytes/checksum and source/recipe compatibility before upload.
- Refuse a nonempty/unknown object view before starting conversion.
- Journal mutation intent before upload/profile/trigger/delete operations.
- Read back the exact generated profile before triggering once.
- Identify one new output and independently verify JPEG identity/geometry,
  stable handle/ObjectInfo/StorageInfo and exact downloaded bytes.
- Permit deletion only of that owned output, after a durable one-shot delete
  intent, revalidation and content hash check; verify empty view afterward.
- Preserve uncertainty across timeouts, disconnect, cancellation and restart.
  Never replay a trigger or deletion or resume an export automatically.
- Keep the operation permit until active work and mandatory cleanup terminate.

An adapter supplies stricter model-specific checks; it cannot turn off the
shared ownership checks. Preserve actual session affinity even for two physical
bodies of the same model. Firmware/model identify compatibility, not a body.

## Session boundaries and import receipts

X-T5 import temporarily selects banks, reads names/settings twice, restores the
original selector and verifies restoration. Preserve that verified importer
behavior. A failed/unconfirmed restoration closes/quarantines the session.

The X-E3's measured backup path reads format-5000 handle 0 once in a fresh
session. A repeated read previously stalled. Conservatively give its importer a
fresh session before and after the backup read; do not assume a backup read and
later RAW upload can share one session until measured. These transitions belong
to the service, selected through adapter import-session policy.

`RecipeImportSessionPolicy` declares either use of the current verified session
(X-T5) or a fresh session before and after import (X-E3). It is a declarative
service instruction, not permission for an adapter to own native connections.

Enrich `CameraServing.importRecipes()` to return `ImportedRecipeCollection` with
recipes, declared slots and the final verified `CameraExecutionContext`.
An owned reopen changes native generation/context honestly. Do not keep a fake
stable generation to make caller checks pass.

`AppModel.refreshRecipes` must validate its client request/lifecycle token and
revalidate the returned context against the service before committing the
collection. Its current equality check against the context captured before
import would wrongly reject a legitimate owned reopen. Publish the final
context/collection together, preventing a race with asynchronous state delivery.

During an owned transition the service reports opening/busy and retires the old
context. It distinguishes its planned close callbacks from physical removal;
physical detach still revokes admission. Queued work from an old context is
rejected/reprepared rather than crossing generations. Imports are prohibited
during active exports, as today. A reconnect never resumes an export.

## Registry and capability assessment

`FujiCameraRegistry` contains explicit statically registered adapters. Read
standard device identity, select by manufacturer/model and verify the candidate
against actual firmware, mode and required operations. Unknown models/firmware
receive a clear unsupported result. A shared processor name alone is not proof
that an unregistered body is safe to control.

Capabilities declare stable model IDs; bank slot IDs/counts/labels; film choices;
WB modes and valid Kelvin values; grain strength and optional size; tone ranges
and steps; supported effects; output/source constraints; and import availability.
Represent absent, present-but-unimplemented and supported separately. Menus and
render admission use the supported set, not everything the hardware advertises.
Model/source compatibility and native original-RAW display availability are
separate assessments.

Remove seven-bank assumptions from catalog collection validation, phone-copy
admission, slot badges and model-specific status messages. Validate a complete
import against the declared slots and one returned context. A declared no-bank
capability is different from a partial/failed import; partial imports must never
replace a complete collection. The first two adapters still declare C1–C7.

Conversion readiness is independent of recipe import availability. A genuine
import/restoration/session failure can revoke readiness, but an unsupported
optional feature is not evidence of a wrong USB mode.

## Recipe domain, persistence and caches

`RecipeSettings` uses semantic film/WB identities, signed user-facing values and
`GrainSettings(strength, size: optional)`. A missing Color Chrome/Clarity field
means unavailable; it is not synthesized as a requested Off setting. Adapters
alone translate semantic settings to native codes, scales and profile offsets.
The UI and draft types no longer use D190/D192/etc. as setting identities.

A snapshot retains its model/firmware/support provenance, exact imported name
bytes and model-scoped native payload. Reuse the existing opaque field-array
storage where practical: X-T5 tags can remain their PTP addresses; X-E3 tags
identify backup fields/dependencies in its own namespace, not invented X-T5
properties. The snapshot is a passive durable value, not a call to
`XT5WorkingProfile.normalize` or a global adapter singleton.

A pure recipe-assessment/codec registry resolves stored provenance for offline
editing and compatibility checks. The active USB connection is not needed to
edit a phone recipe. Encode an edit into a new immutable snapshot while keeping
unchanged/unknown native values; preserve stable phone membership and frozen
older jobs/versions. Names/slot/import time do not enter the settings digest.
The canonical digest is adapter-domain/version scoped and covers all actual
rendering settings and dependencies, including X-E3 shared WB shifts.

Camera recipes are active-session collections. Phone recipes remain a mixed
persistent library with model provenance. Show incompatible phone recipes with
a clear reason and prevent selection/rendering on another model; retain offline
editing and deletion. No cross-model translation or silent effect removal.
RAW source model must also match the connected camera.

Keep current durable data safe. Avoid unrelated persisted-DTO format changes;
semantic runtime projections can differ from storage DTOs. Any unavoidable
forward conversion of the current data is transactional, verified on a copied
store, and preserves IDs, frozen digests, source/save-operation associations,
Photos asset references and uncertainty records. Never delete/reset the user's
catalog or camera journals to make the refactor pass. Do not add legacy service
interfaces or historical-version compatibility layers. Exact storage mapping is
a builder decision subject to these invariants.

Render/cache/job identity includes source revision/hash, semantic/native settings
digest, adapter support version, actual model/firmware, output policy and live
execution context. Camera switching cannot reuse another model's preview or
reroute a frozen job. Previously saved JPEG versions remain viewable without a
camera; unsupported recipe rendering does not invalidate saved assets.

## Initial model behavior

X-T5 keeps its measured five-film/rendering domain, grain restrictions,
capability strings, 625-byte baseline validation and existing source class.
Phone editing may preserve unsupported imports, as today; a UI-editable value
does not automatically gain camera-rendering support through the X-E3 adapter.

X-E3 uses the measured 601-byte framing/FF129505 processor, the 5660-byte backup,
seven bank records/names, shared WB table and signed/lookup encodings documented
in `docs/validation/xe3-laptop-protocol.md`. Import freezes mode-specific shared
WB shifts into snapshots/phone copies. Do not persist the complete private
backup or serial in the recipe catalog; keep only required native fields and
bounded dependencies. Whole backups remain optional private diagnostics.

Its supported editor has 15 films, Off/Weak/Strong grain without a size control,
DR100/200/400, verified WB presets/shifts, whole-step highlights/shadows and
colour/sharpness/NR. No Color Chrome/FX Blue or Clarity controls. Kelvin is a
picker over verified native presets: 5000/6300/7100 are already measured. Enumerate
additional candidate native presets on the laptop before widening that set;
5310 must be rejected because it reads back but renders as 2500. Exposure wire
support does not introduce a new editor feature in this integration.

Validate the remaining shared-WB mode positions before claiming their general
non-neutral-bank support. Auto/Temperature/Daylight have independent evidence;
other imports remain lossless but report unsupported/unvalidated dependencies
until that gate is satisfied. Require the intended seven current banks to meet
this gate before marking full X-E3 recipe support complete.

Use both observed RAF geometry classes and orientations 1/8 initially. JPEG
ObjectInfo dimensions may be zero; verify actual JPEG dimensions. Accept measured
association 7/2055 through the model output rules. Do not infer other orientation
or compression classes from these samples.

Keep requested and effective settings distinct. Apply the selected recipe's
requested DR through the camera; do not silently clamp it to capture DR. The C3
reference run's DR200 override was diagnostic. Any later camera-reported
adjustment is recorded in the effective report, not relabelled as exact execution.

Reject a result before publishing a preview or saved version if a validated JPEG
field contradicts a requested setting. Keep the observed adjustment in failure
diagnostics, and perform the same owned-output cleanup. The initial adapters
declare no permitted rendering adjustments; accepting an adjustment later needs
an explicit product policy and adapter evidence.

JPEG metadata need not expose every field. For each supported setting, declare
whether validation uses qualified JPEG metadata or verified profile readback
backed by independent laptop/reference evidence. A missing required JPEG field
fails validation; a field declared to use protocol evidence does not. Effective
reports distinguish observed values from protocol-confirmed values and never
invent camera metadata. Unverified mappings remain unsupported. Preserve the
X-T5's measured domain without claiming new metadata coverage from extraction.

For original RAW viewing, keep the existing real-sensor decoder path and report
an actionable unavailable result if it fails. The Mac decodes the uncompressed
X-E3 sources but not the compressed ones. Continue admitting the compressed
sources for camera conversion; keep separately labelled paired camera-JPEG and
saved-version choices. No hidden embedded-JPEG fallback. Actual phone decoder
availability is a physical validation item, not inferred from the Mac.

## Validation and delivery

First extract the existing X-T5 behavior behind the shared service/adapter with
its current tests and measured outputs. Then add X-E3 using the committed laptop
fixtures. Keep checkpoints pushed through the active Jujutsu bookmark.

- Core package tests run on the Mac without a simulator/camera. Cover routing,
  unknown identities, capability restrictions, independent recipe normalization,
  codec framing/bounds, preservation of opaque bytes, digests, WB dependencies,
  invalid Kelvin rejection, source compatibility and qualified Fuji metadata.
- Shared-service contract tests cover both adapters: exclusive operation scope,
  fresh-session import receipts, cancellation/late callbacks, restoration,
  preexisting objects, output identity, one-shot cleanup and uncertainty recovery.
- Retain X-T5 regressions and add catalog/UI tests for model switching, mixed
  phone recipes, non-seven slot declarations, offline edits and RAW-view failure
  independent of conversion eligibility. Do not count unsupported hardware as
  a simulator pass.
- The Mac runner uses the same Swift adapters/service to reproduce all seven
  supplied sources, core control cases, Kelvin negatives and backup-to-profile
  renders. Compare against camera JPEGs and measured grain-dependent repeats;
  never require pixel equality for stochastic grain.
- Run affected unit/UI suites, the complete iOS test gate and Release build in
  an isolated task simulator. Physical iPhone validation checks USB admission,
  seven-bank import, preview/export, source orientation, model switching and
  interruption/recovery. Do not claim those gates from laptop results.

Implementation planning should choose precise type/file boundaries, fixture
organization and commit-sized steps within this design. It may settle routine
choices without further user questions. A materially new product behavior,
destructive data policy, unmeasured support expansion or changed safety invariant
requires revisiting the design.
