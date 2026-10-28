# X-E3 laptop protocol investigation — 2026-10-28

This is a laptop-only protocol spike on X-E3 firmware **1.30**, using the public
macOS ImageCaptureCore API. The iPhone application has not been changed. Camera
settings and C1–C7 are not written. Original RAF/JPEG files stay untouched.
Private images, complete backups, names, source hashes and operation journals
remain under the isolated workspace's ignored `.build/xe3-wire/` directory.

## Reproduction tools

`Scripts/CameraProbe/run.sh` compiles the native probe with the application's
actual `PTPTypes.swift` and `PTPCodec.swift`. The selector callback validates the
original command echo and context before decoding the framework-managed reply.
ImageCaptureCore owns the wire transaction ID; it must not be compared with the
caller's logical ID. Errors/deadlines stop the run without retrying a mutation.

```sh
Scripts/CameraProbe/run.sh --raw /path/to/source.RAF \
  --output /absolute/path/to/new-private-run --trigger 1 --cleanup

# A measured film-only candidate, patching a fresh per-source baseline:
Scripts/CameraProbe/run.sh --raw /path/to/source.RAF \
  --output /absolute/path/to/new-private-film-run \
  --trigger 1 --set 541:1 --cleanup

uv venv .venv
uv pip install --python .venv/bin/python -r Scripts/CameraProbe/requirements.txt
.venv/bin/python Scripts/CameraProbe/analyze.py profile \
  Tests/Fixtures/Protocol/XE3/1.30/baseline-601.bin
.venv/bin/python Scripts/CameraProbe/analyze.py compare reference.JPG output.JPG
```

Output directories must not exist. To inspect without uploading, omit `--raw`.
To upload and retain only the profile, omit `--trigger`. Such an upload does not
prove the private input buffer was erased when the session closed.

The probe requires the observed model/firmware, USB mode 6 and an initially empty
object view. `--cleanup` deletes only the newly created JPEG after checking its
exact handle, unchanged ObjectInfo/StorageInfo, a second full download's hash,
and a virtual-storage signature (storage type 3, filesystem 2, access 2). It
then verifies an empty view. It never deletes a preexisting object, accesses
card image contents or restores a whole-camera backup.

## Observed upload / conversion / download sequence

1. Standard `GetDeviceInfo` (`0x1001`) returns FUJIFILM / X-E3 / 1.30.
2. `GetDevicePropValue` (`0x1015`, `0xD16E`) returns the two bytes `06 00`.
   This property works despite being absent from the advertised property list.
3. `GetObjectHandles` (`0x1007`, `FFFFFFFF,0,0`) must return zero handles.
4. Vendor `SendObjectInfo` (`0x900C`, `0,0,0`) uploads an 82-byte standard
   ObjectInfo dataset: format `0xF802`, actual RAF byte count, `FUP_FILE.dat`,
   other fixed fields zero and three empty trailing PTP strings.
5. Vendor `SendObject` (`0x900D`, no parameters) uploads the original RAF bytes.
6. `GetDevicePropValue(0xD185)` returns a **601-byte** per-RAF working profile.
7. Optionally `SetDevicePropValue` (`0x1016`, `0xD185`) writes a candidate of
   the same length. Exact readback is required before conversion.
8. `SetDevicePropValue(0xD183)` with the two-byte value `01 00` produces a
   full-size JPEG. Poll `GetObjectHandles` until exactly one new handle exists.
9. Read its ObjectInfo (`0x1008`), StorageInfo (`0x1005`) and object (`0x1009`).
   Observed ObjectInfo is 114 bytes, StorageInfo 104 bytes, virtual storage ID
   `0x10000001`. These observations do not authorize guessing future handles.
10. Validate/download, perform the exact cleanup described above, and await
    confirmed session closure.

Unlike the X-T5, direct reads of capability strings D186/D187 and bank
properties D18C–D1A4 return `0x200A` (DevicePropNotSupported). The X-T5
advertised-property handshake must not gate the X-E3's conversion path.

## Working profile framing and fields

All three initial sources returned exactly the same 601-byte baseline because
their development settings matched. The retained public fixture contains only
processor/profile settings, with no image, serial, bank name or source identity.

- Little-endian header word at byte 0: **23** (`17 00`).
- Byte 2: **8**; bytes 3–18: eight UTF-16LE characters **FF129505**.
- Bytes 19–512: zero in these observations.
- Bytes 513–600: **22 little-endian 32-bit words**, signed where indicated.
- The header count is one more than the observed trailing word count. Preserve
  this framing; do not use a guessed generic count/length grammar.
- Always patch a fresh per-source baseline. The X-T5's 625-byte frame and
  processor FF179502 are a distinct support class.

| Offset | Candidate meaning | Initial value | Encoding / verification |
| --- | --- | --- | --- |
| 513 | Shooting condition | 2 | Preserve |
| 517 | File type | 7 | Observed JPEG; preserve |
| 521 | Image size | 7 | Observed full 3:2; preserve |
| 525 | JPEG quality | 2 | FINE output; preserve |
| 529 | Exposure bias | 0 | Candidate signed thousandths of EV |
| 533 | Dynamic range | 200 | Literal percentage |
| 537 | Wide dynamic range | 0 | Preserve; unvalidated |
| 541 | Film simulation | 11 | Native film code; 11 = Classic Chrome |
| 545 | Grain | 1 | 1 Off, 2 Weak, 3 Strong |
| 549 | Opaque / unused on X-E3 | 1 | Preserve; do not expose Color Chrome |
| 553 | White-balance shooting condition | 1 | 1 source WB; candidate 2 explicit WB |
| 557 | White-balance mode | 0 | Source WB placeholder; explicit modes measured separately |
| 561 | WB red shift | 3 | Signed grid steps; JPEG reports +60 |
| 565 | WB blue shift | -4 | Signed grid steps; JPEG reports -80 |
| 569 | Kelvin | 0 | Dormant under source WB |
| 573 | Highlights | -10 | Signed tone ×10 |
| 577 | Shadows | -10 | Signed tone ×10 |
| 581 | Colour | 40 | Signed colour ×10 |
| 585 | Sharpness | 0 | Signed sharpness ×10 |
| 589 | Noise reduction | 32768 | Lookup encoding; 0x8000 = -4 |
| 593 | Lens modulation optimizer | 1 | Candidate 1 On / 2 Off |
| 597 | Colour space | 1 | Observed sRGB; preserve |

Fields described as candidates/preserve are not generally validated solely by
matching the initial source. Later controlled trials and effective JPEG
metadata must establish which requests the camera actually honors.

## Initial source / output evidence

The three supplied sources are lossless-compressed, 14-bit RAFs. Container size
is **6048×4038**, recorded crop **6000×4000**, crop origin **top 21 / left 16**,
and recorded aspect **3:2**. RAF directory tags are 0100 (full), 0110 (origin),
0111 (crop) and 0115 (aspect), each storing height/width order. Orientations
are 1, 8 and 1. The embedded JPEG is only 1920×1280 and marked NORMAL; it must
not be mistaken for full-resolution RAW pixels or the separate FINE JPEG.

All three unchanged conversions returned **6000×4000 FINE JPEGs**, preserving
source orientation. The 18 checked metadata fields and JPEG quantization tables
match each paired camera JPEG. Decoded pixels are not equal:

| Source | Mean absolute RGB error (0–255) | Maximum error |
| --- | ---: | ---: |
| First | 1.204450875 | 12 |
| Second / portrait | 1.311792514 | 13 |
| Third | 1.173272403 | 12 |

An independent same-source repeat differs from the first laptop conversion by
MAE **1.204784167**, maximum **12**, with no checked metadata differences.
At 750×500, camera-JPEG/laptop MAE is **0.222148**, versus **0.222138** for the
laptop repeat. This supports repeat-scale rendering variation for this sample;
it is not a proof of pixel equality or a universal fidelity claim.

A film-only change at byte 541 to code 1 read back exactly and returned PROVIA
metadata. Its 750×500 difference from unchanged Classic Chrome is MAE **4.621228**,
well above the measured repeat residual. Every initial conversion and this trial
verified cleanup and native closure.

## RAW viewing boundary

On the laptop's macOS 27.0.1, `CIRAWFilter(imageURL:)` creates an object for all
three files, but reports native size 0×0, supported decoder versions `[None]`,
and no output image. Both full and reduced scale fail. ExifTool validates all
three RAFs and the camera converts them successfully. Apple's model list alone
therefore does not establish support for these exact compressed files. An
uncompressed source and physical-iPhone tests remain useful independent gates.
Do not quietly display the embedded JPEG as the application's original RAW view.

## Settings backup / future bank import

The preceding read-only investigation downloaded a 5660-byte backup through
`GetObjectInfo(0)` / `GetObject(0)` with format 0x5000. Its model header identifies
X-E3. Candidate bank film offsets are `3909 + 256×slotIndex`. Candidate ASCII
names start **69 bytes after the film byte**; six nonempty names and one empty
name are recognizable. The generic upstream generation-3 layout assumes unnamed
banks; this X-E3 observation differs.

Backup field encodings differ from D185. Candidate relative offsets are WB mode
-33, Kelvin index -32, NR -7, DR +3, colour +7, sharpness +9, highlights +10,
shadows +11 and grain +12. These need camera-screen / controlled-diff validation;
no persistent bank writes have been attempted. WB shift and measured custom WB
must not be invented as independent per-bank values. A repeated backup read in
one earlier session stalled; closure was confirmed.

## References and implementation boundary

- [Fujifilm X-E3 connection modes](https://app.fujifilm-dsc.com/en/manual/x-e3/menu_setup/connection_setting/index.html)
- [Fujifilm X-E3 image-quality settings](https://app.fujifilm-dsc.com/en/manual/x-e3/menu_shooting/image_quality_setting/index.html)
- [libfuji D185 research](https://github.com/petabyt/libfuji/blob/master/fp/src/d185.c),
  [field constants](https://github.com/petabyt/libfuji/blob/master/fp/src/fp.h),
  MIT; format reference, no upstream implementation copied.
- [grawji backup-layout research](https://github.com/p5k369/grawji/blob/main/src/grawji/camera/backup_recipe.py),
  GPL-3.0; candidate layout reference only, no upstream implementation copied.

Transfer to the app should use a model-specific profile codec and capability
assessment, general RAW admission/geometry, a separate backup-based bank importer,
and model-aware phone-recipe editing. Reuse the existing serial operation gate,
transport, journal, scheduler, cache and export machinery. Physical iPhone USB,
source RAW display, interruption/recovery and broader source classes are not
established by these laptop runs.
