#!/usr/bin/env python3
"""Audit captured hardware evidence against independently decoded JPEG settings."""
import argparse
import json
from pathlib import Path

from PIL import Image
import numpy as np

FILMS = {
    "provia":("FilmMode","F0/Standard (Provia)"),
    "velvia":("FilmMode","F2/Fujichrome (Velvia)"),
    "astia":("FilmMode","F1b/Studio Portrait Smooth Skin Tone (Astia)"),
    "pro-neg-hi":("FilmMode","Pro Neg. Hi"), "pro-neg-std":("FilmMode","Pro Neg. Std"),
    "mono":("Saturation","None (B&W)"), "mono-yellow":("Saturation","B&W Yellow Filter"),
    "mono-red":("Saturation","B&W Red Filter"), "mono-green":("Saturation","B&W Green Filter"),
    "sepia":("Saturation","B&W Sepia"), "classic-chrome":("FilmMode","Classic Chrome"),
    "acros":("Saturation","Acros"), "acros-yellow":("Saturation","Acros Yellow Filter"),
    "acros-red":("Saturation","Acros Red Filter"), "acros-green":("Saturation","Acros Green Filter"),
}
EXPECTED = {
    "grain-weak":("GrainEffectRoughness","Weak"), "grain-strong":("GrainEffectRoughness","Strong"),
    "dr100":("DevelopmentDynamicRange",100), "dr400-request":("DevelopmentDynamicRange",400),
    "highlight-minus2":("HighlightTone","-2 (soft)"), "highlight-plus4":("HighlightTone","+4 (hardest)"),
    "shadow-minus2":("ShadowTone","-2 (soft)"), "shadow-plus4":("ShadowTone","+4 (hardest)"),
    "color-minus4":("Saturation","-4 (lowest)"),
    "sharpness-minus4":("Sharpness","-4 (softest)"), "sharpness-plus4":("Sharpness","+4 (hardest)"),
    "noise-plus4":("NoiseReduction","+4 (strongest)"),
    "wb-red-minus9":("WhiteBalanceFineTune","Red -180, Blue -80"),
    "wb-blue-plus9":("WhiteBalanceFineTune","Red +60, Blue +180"),
    "wb-auto":("WhiteBalance","Auto"), "wb-daylight":("WhiteBalance","Daylight"),
    "wb-shade":("WhiteBalance","Cloudy"), "wb-fluorescent1":("WhiteBalance","Daylight Fluorescent"),
    "wb-fluorescent2":("WhiteBalance","Day White Fluorescent"), "wb-fluorescent3":("WhiteBalance","White Fluorescent"),
    "wb-incandescent":("WhiteBalance","Incandescent"), "wb-underwater":("WhiteBalance","Underwater"),
    "wb-5000k":("ColorTemperature",5000), "lmo-off":("LensModulationOptimizer","Off"),
}


def luma(path):
    image=Image.open(path).convert("RGB").resize((750,500),Image.Resampling.LANCZOS)
    return float((np.asarray(image).astype(float) @ np.array([.2126,.7152,.0722])).mean())


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("directory",type=Path)
    parser.add_argument("--baseline",type=Path)
    args=parser.parse_args()
    rows=json.loads((args.directory/"summary.json").read_text())
    errors=[]
    checks=0
    seen=set()
    for row in rows:
        name=row["trial"]
        assert name not in seen, "Duplicate trial"
        seen.add(name)
        checks += 8
        for key in ["readbackMatches","cleanupVerified","closeConfirmed"]:
            if row[key] is not True:
                errors.append(f"{name}: {key}")
        if row["exitCode"] != 0 or row["failure"] is not None:
            errors.append(f"{name}: incomplete")
        if (row["width"],row["height"]) != (6000,4000) or row["metadata"]["Quality"].strip() != "FINE":
            errors.append(f"{name}: output class")
        directory=args.directory/name
        baseline=(directory/"baseline.bin").read_bytes()
        candidate=bytearray(baseline)
        for offset,value in row["patches"]:
            candidate[offset:offset+4]=(value & 0xffffffff).to_bytes(4,"little")
        if bytes(candidate) != (directory/"candidate.bin").read_bytes() or bytes(candidate) != (directory/"readback.bin").read_bytes():
            errors.append(f"{name}: actual profile bytes differ")
        expected=FILMS.get(name.removeprefix("film-")) if name.startswith("film-") else EXPECTED.get(name)
        if expected:
            checks += 1
            field,want=expected
            if row["metadata"].get(field) != want:
                errors.append(f"{name}: expected {field}={want!r}, observed {row['metadata'].get(field)!r}")
    expected_names={"film-"+name for name in FILMS}|set(EXPECTED)|{"exposure-plus-two-thirds","exposure-minus-two-thirds"}
    if seen != expected_names:
        errors.append(f"Trial set differs: {seen ^ expected_names}")
    brightness=None
    if args.baseline:
        base=luma(args.baseline)
        plus=luma(args.directory/"exposure-plus-two-thirds/output.JPG")
        minus=luma(args.directory/"exposure-minus-two-thirds/output.JPG")
        checks += 2
        brightness={"minusTwoThirds":minus,"unchanged":base,"plusTwoThirds":plus}
        if not minus < base < plus or min(base-minus,plus-base) < 10:
            errors.append("Exposure brightness response is missing")
    result={"trials":len(rows),"checks":checks,"errors":errors,"exposureMeanLuma":brightness}
    print(json.dumps(result,indent=2))
    if errors:
        raise SystemExit(1)


if __name__=="__main__":
    main()
