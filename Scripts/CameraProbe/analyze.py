#!/usr/bin/env python3
"""Offline analysis for the laptop spike; run with the project's .venv."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess

import numpy as np
from PIL import Image

FIELDS = [
    "shootingCondition", "fileType", "imageSize", "imageQuality", "exposureBias",
    "dynamicRange", "wideDynamicRange", "filmSimulation", "grain", "opaque9",
    "wbShootingCondition", "whiteBalance", "wbRed", "wbBlue", "kelvin",
    "highlightTenths", "shadowTenths", "colorTenths", "sharpnessTenths",
    "noiseReductionCode", "lensOptimizer", "colorSpace",
]
TAGS = ["Model", "ImageWidth", "ImageHeight", "Orientation", "Quality", "FilmMode",
        "WhiteBalance", "WhiteBalanceFineTune", "ColorTemperature", "HighlightTone",
        "ShadowTone", "Saturation", "Sharpness", "NoiseReduction", "GrainEffectRoughness",
        "DevelopmentDynamicRange", "LensModulationOptimizer", "ColorSpace"]


def profile(path):
    data = path.read_bytes()
    if len(data) != 601 or data[:3] != bytes([23, 0, 8]):
        raise ValueError("Unmeasured profile framing")
    processor = data[3:19].decode("utf-16-le")
    if processor != "FF129505" or any(data[19:513]):
        raise ValueError("Unmeasured processor/padding")
    words = struct.unpack_from("<22i", data, 513)
    return {"bytes": len(data), "headerCount": 23, "processor": processor,
            "fields": {name: {"offset": 513+index*4, "value": value}
                       for index, (name, value) in enumerate(zip(FIELDS, words))}}


def raf(path):
    data = path.read_bytes()
    if data[:16] != b"FUJIFILMCCD-RAW ":
        raise ValueError("Invalid RAF magic")
    directory_offset, directory_size = struct.unpack_from(">II", data, 92)
    block = data[directory_offset:directory_offset+directory_size]
    count, = struct.unpack_from(">I", block)
    cursor = 4
    fields = {}
    for _ in range(count):
        tag, size = struct.unpack_from(">HH", block, cursor)
        cursor += 4
        content = block[cursor:cursor+size]
        cursor += size
        if tag in (0x100, 0x110, 0x111, 0x115):
            fields[f"0x{tag:04x}"] = list(struct.unpack(">HH", content))
    return {"model": data[28:60].split(b"\0")[0].decode(), "bytes": len(data),
            "geometryTags": fields, "sha256": hashlib.sha256(data).hexdigest()}


def metadata(path):
    args = ["exiftool", "-json", "-n"] + ["-"+tag for tag in TAGS] + [str(path)]
    data = json.loads(subprocess.check_output(args))[0]
    return {tag: data.get(tag) for tag in TAGS}


def compare(reference, candidate):
    a, b = Image.open(reference), Image.open(candidate)
    if a.size != b.size:
        raise ValueError(f"Size mismatch: {a.size} vs {b.size}")
    quantization_equal = a.quantization == b.quantization
    a, b = a.convert("RGB"), b.convert("RGB")
    absolute_sum = square_sum = changed_pixels = maximum = 0
    for y in range(0, a.height, 128):
        box = (0, y, a.width, min(y+128, a.height))
        difference = np.asarray(a.crop(box)).astype(np.int16) - np.asarray(b.crop(box)).astype(np.int16)
        absolute = np.abs(difference)
        absolute_sum += int(absolute.sum())
        square_sum += int(np.square(difference.astype(np.int32)).sum())
        changed_pixels += int(np.any(difference != 0, axis=2).sum())
        maximum = max(maximum, int(absolute.max()))
    samples = a.width*a.height*3
    mse = square_sum/samples
    am, bm = metadata(reference), metadata(candidate)
    mismatches = {tag: [am[tag], bm[tag]] for tag in TAGS if am[tag] != bm[tag]}
    return {"reference": str(reference), "candidate": str(candidate), "width": a.width, "height": a.height,
            "decodedPixelsEqual": changed_pixels == 0, "meanAbsoluteError": absolute_sum/samples,
            "rootMeanSquareError": math.sqrt(mse), "maximumAbsoluteError": maximum,
            "psnrDB": 10*math.log10(255**2/mse) if mse else None,
            "changedPixelFraction": changed_pixels/(a.width*a.height),
            "quantizationTablesEqual": quantization_equal, "metadataMismatches": mismatches,
            "referenceMetadata": am, "candidateMetadata": bm}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["profile", "raf", "compare"])
    parser.add_argument("paths", type=Path, nargs="+")
    args = parser.parse_args()
    if args.mode == "compare":
        if len(args.paths) != 2:
            parser.error("compare needs reference and candidate")
        result = compare(*args.paths)
    else:
        method = profile if args.mode == "profile" else raf
        result = [dict(file=str(path), **method(path)) for path in args.paths]
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
