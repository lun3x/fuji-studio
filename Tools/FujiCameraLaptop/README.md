# Native Fujifilm laptop runner

This executable uses `FujiCameraCore` and macOS ImageCaptureCore. The core owns
verification, session transitions, bank decoding, conversion, JPEG admission and
output cleanup. The native bridge owns only browser/session callbacks and PTP
command delivery. It retains discovery across logical closes and uses an ephemeral
attachment token to reject physical replacement during an owned import.

```sh
swift test --package-path Tools/FujiCameraLaptop
swift run --package-path Tools/FujiCameraLaptop FujiCameraLaptop import-recipes \
  --output /absolute/path/to/new-private-directory
swift run --package-path Tools/FujiCameraLaptop FujiCameraLaptop render \
  --raw /absolute/path/to/source.RAF --slot 4 \
  --output /absolute/path/to/another-new-private-directory
```

For an immutable offline snapshot, replace `--slot 4` with
`--recipe-file /absolute/path/to/snapshot.json`. Exactly one selection is required.
`recipes-private.json` contains an array of imported snapshots; the recipe-file
input is one snapshot, retaining its native fields and core-generated digest.
Use `RecipeCodecRegistry.encodeEditedValues(_:preserving:)` for deliberate edits.

The output directory must not exist. Its parent must exist. Directories use
POSIX0700 and files0600. Private evidence contains recipe names, source hashes,
profile hashes, native command counts and operation records; keep the whole
output directory private. `output.JPG` is copied only after core validation and
confirmed owned-output cleanup. `evidence-private.json` independently records
native closure confirmation. Failed/uncertain journals remain available for
inspection; the runner never retries a trigger or deletion. SIGINT/SIGTERM cancel
the operation and let the core drain and close before exiting.

`Scripts/CameraProbe/run.sh` invokes this runner. The historical
`run-diagnostic.sh` and Python sweep scripts are protocol research tools, not
shipping-core acceptance. Python analyzes existing evidence and image differences;
it does not provide a second production recipe or conversion implementation.

To create a public summary without names, IDs, source hashes or native diagnostics:

```sh
.venv/bin/python Scripts/CameraProbe/analyze.py core-evidence \
  /absolute/path/to/private-run/evidence-private.json
```

The X-E3 must be powered on in **USB RAW CONV./BACKUP RESTORE** mode. Import uses
one backup download between two verified fresh sessions. Its final context has
a new native generation and session UUID. No saved camera bank, shared WB table,
shooting setting or card image is written.
