#!/usr/bin/env python3
# Historical diagnostic-only sweep; shipping-core acceptance uses Tools/FujiCameraLaptop.
"""Sequential hardware experiments. Stops after any incomplete operation; never retries it."""
import argparse
import json
from pathlib import Path
import subprocess
import time

FILMS = {1:"provia",2:"velvia",3:"astia",4:"pro-neg-hi",5:"pro-neg-std",6:"mono",7:"mono-yellow",8:"mono-red",9:"mono-green",10:"sepia",11:"classic-chrome",12:"acros",13:"acros-yellow",14:"acros-red",15:"acros-green"}
CASES = [(f"film-{name}", [(541, code)]) for code, name in FILMS.items()]
CASES += [
    ("grain-weak", [(545,2)]), ("grain-strong", [(545,3)]),
    ("dr100", [(533,100)]), ("dr400-request", [(533,400)]),
    ("highlight-minus2", [(573,-20)]), ("highlight-plus4", [(573,40)]),
    ("shadow-minus2", [(577,-20)]), ("shadow-plus4", [(577,40)]),
    ("color-minus4", [(581,-40)]),
    ("sharpness-minus4", [(585,-40)]), ("sharpness-plus4", [(585,40)]),
    ("noise-plus4", [(589,0x5000)]),
    ("wb-red-minus9", [(561,-9)]), ("wb-blue-plus9", [(565,9)]),
    ("wb-auto", [(553,2),(557,2)]), ("wb-daylight", [(553,2),(557,4)]),
    ("wb-shade", [(553,2),(557,0x8006)]),
    ("wb-fluorescent1", [(553,2),(557,0x8001)]),
    ("wb-fluorescent2", [(553,2),(557,0x8002)]),
    ("wb-fluorescent3", [(553,2),(557,0x8003)]),
    ("wb-incandescent", [(553,2),(557,6)]),
    ("wb-underwater", [(553,2),(557,8)]),
    ("wb-5000k", [(553,2),(557,0x8007),(569,5000)]),
    ("exposure-plus-two-thirds", [(529,667)]),
    ("exposure-minus-two-thirds", [(529,-667)]),
    ("lmo-off", [(593,2)]),
]
TAGS = ["FilmMode","Saturation","WhiteBalance","WhiteBalanceFineTune","ColorTemperature",
        "HighlightTone","ShadowTone","Sharpness","NoiseReduction","GrainEffectRoughness",
        "DevelopmentDynamicRange","LensModulationOptimizer","RawExposureBias","Quality"]


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--raw",required=True,type=Path)
    parser.add_argument("--output",required=True,type=Path)
    parser.add_argument("--only",nargs="*")
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    executable=root/".build/CameraProbe/diagnostic-probe"
    args.output.mkdir(parents=True,exist_ok=False,mode=0o700)
    summary=[]
    for name,patches in CASES:
        if args.only and name not in args.only:
            continue
        directory=args.output/name
        command=[str(executable),"--raw",str(args.raw),"--output",str(directory),"--trigger","1","--cleanup"]
        for offset,value in patches:
            command += ["--set",f"{offset}:{value}"]
        started=time.monotonic()
        with (args.output/f"{name}.log").open("w") as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
        evidence=json.loads((directory/"evidence-private.json").read_text())
        row={"trial":name,"patches":patches,"seconds":round(time.monotonic()-started,3),
             "exitCode":result.returncode,"readbackMatches":evidence.get("profileReadbackMatches"),
             "cleanupVerified":evidence.get("cleanupVerified"),"closeConfirmed":evidence.get("closeConfirmed"),
             "width":evidence.get("outputWidth"),"height":evidence.get("outputHeight"),"failure":evidence.get("failure")}
        if (directory/"output.JPG").exists():
            metadata=json.loads(subprocess.check_output(["exiftool","-json"]+["-FujiFilm:"+tag for tag in TAGS]+[str(directory/"output.JPG")]))[0]
            metadata.pop("SourceFile",None)
            row["metadata"]=metadata
        summary.append(row)
        (args.output/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
        print(f"{name}: exit={result.returncode}, readback={row['readbackMatches']}, cleanup={row['cleanupVerified']}, close={row['closeConfirmed']}, {row['seconds']}s",flush=True)
        if result.returncode or not all(row.get(key) for key in ["readbackMatches","cleanupVerified","closeConfirmed"]):
            raise SystemExit("Sweep stopped; inspect evidence before another camera operation")


if __name__=="__main__":
    main()
