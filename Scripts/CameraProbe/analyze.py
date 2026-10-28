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


def backup(path):
    data = path.read_bytes()
    if len(data) != 5660 or data[:8] != b"FUJIFILM" or data[20:52].split(b"\0")[0] != b"X-E3":
        raise ValueError("Unmeasured backup framing")
    films = {0:"Provia",1:"Astia",3:"Velvia",5:"Sepia",7:"Monochrome",8:"Monochrome Red",
             9:"Monochrome Yellow",10:"Monochrome Green",11:"Pro Neg. Std",12:"Pro Neg. Hi",
             13:"Classic Chrome",14:"Acros",15:"Acros Red",16:"Acros Yellow",17:"Acros Green"}
    colors = {3:4,4:3,5:2,6:1,0:0,8:-1,7:-2,9:-3,10:-4}
    wb = ["Auto","Daylight","Shade","Fluorescent1","Fluorescent2","Fluorescent3","Incandescent","Underwater","Temperature"]
    kelvin = [10000,9100,8300,7700,7100,6700,6300,5900,5600,5300,5000,4800,4500,4300,4200,4000,
              3800,3700,3600,3400,3300,3200,3100,3000,2950,2850,2800,2700,2650,2550,2500]
    shift_indices = {"Auto":0,"Temperature":4,"Daylight":5,"Shade":6,"Fluorescent1":7,
                     "Fluorescent2":8,"Fluorescent3":9,"Incandescent":10,"Underwater":11}
    banks = []
    for slot in range(7):
        base = 3909+256*slot
        name_bytes = data[base+69:base+69+16]
        if b"\0" not in name_bytes:
            raise ValueError("Name exceeds measured bound")
        bank = {"slot":slot+1,"name":name_bytes.split(b"\0")[0].decode("ascii"),
                "film":films[data[base]], "dynamicRange":["Auto",100,200,400][data[base+3]],
                "color":colors[data[base+7]], "sharpness":4-data[base+9],
                "highlight":4-data[base+10], "shadow":4-data[base+11],
                "noiseReduction":data[base-7]-4, "grain":["Strong","Weak","Off"][data[base+12]],
                "whiteBalance":wb[data[base-33]], "kelvinIndex":data[base-32]}
        shift_offset = 433+2*shift_indices[bank["whiteBalance"]]
        red, blue = 9-data[shift_offset], 9-data[shift_offset+1]
        if not (-9 <= red <= 9 and -9 <= blue <= 9):
            raise ValueError("WB shift outside native grid")
        bank["whiteBalanceShift"] = {"red":red,"blue":blue,"offset":shift_offset,
                                    "dependency":"shared by all banks using this WB mode"}
        if bank["whiteBalance"] == "Temperature":
            bank["kelvin"] = kelvin[bank["kelvinIndex"]]
        banks.append(bank)
    return {"status":"candidate bank layout; controlled WB diff verified; camera-screen validation required", "bytes":len(data),
            "bankCount":len(banks), "banks":banks,
            "unresolved":"Custom WB gains and unused WB-mode table positions remain unvalidated"}


def metadata(path):
    groups = {"Model":"IFD0", "ImageWidth":"File", "ImageHeight":"File",
              "Orientation":"IFD0", "ColorSpace":"ExifIFD"}
    args = ["exiftool", "-json", "-n"] + ["-"+groups.get(tag,"FujiFilm")+":"+tag for tag in TAGS] + [str(path)]
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
    parser.add_argument("mode", choices=["profile", "raf", "backup", "compare"])
    parser.add_argument("paths", type=Path, nargs="+")
    args = parser.parse_args()
    if args.mode == "compare":
        if len(args.paths) != 2:
            parser.error("compare needs reference and candidate")
        result = compare(*args.paths)
    else:
        method = {"profile":profile,"raf":raf,"backup":backup}[args.mode]
        result = [dict(file=str(path), **method(path)) for path in args.paths]
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
