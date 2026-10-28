#!/usr/bin/env python3
"""Render decoded X-E3 banks via working profiles only. Never writes C1-C7."""
import argparse
import json
from pathlib import Path
import subprocess

from analyze import backup

FILMS={"Provia":1,"Velvia":2,"Astia":3,"Pro Neg. Hi":4,"Pro Neg. Std":5,"Monochrome":6,
       "Monochrome Yellow":7,"Monochrome Red":8,"Monochrome Green":9,"Sepia":10,
       "Classic Chrome":11,"Acros":12,"Acros Yellow":13,"Acros Red":14,"Acros Green":15}
WB={"Auto":2,"Daylight":4,"Shade":0x8006,"Fluorescent1":0x8001,"Fluorescent2":0x8002,
    "Fluorescent3":0x8003,"Incandescent":6,"Underwater":8,"Temperature":0x8007}
NOISE={-4:0x8000,-3:0x7000,-2:0x4000,-1:0x3000,0:0x2000,1:0x1000,2:0,3:0x6000,4:0x5000}


def bank_patches(bank, dynamic_range=None):
    dr=bank['dynamicRange'] if dynamic_range is None else dynamic_range
    if dr not in [100,200,400]:
        raise ValueError('Unvalidated bank dynamic-range setting')
    shifts=bank['whiteBalanceShift']
    values={533:dr,541:FILMS[bank['film']],545:{'Off':1,'Weak':2,'Strong':3}[bank['grain']],
            553:2,557:WB[bank['whiteBalance']],561:shifts['red'],565:shifts['blue'],
            573:bank['highlight']*10,577:bank['shadow']*10,581:bank['color']*10,
            585:bank['sharpness']*10,589:NOISE[bank['noiseReduction']]}
    if bank['whiteBalance']=='Temperature':values[569]=bank['kelvin']
    return values


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--backup',required=True,type=Path)
    parser.add_argument('--raw',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--slots',type=int,nargs='+',default=list(range(1,8)))
    parser.add_argument('--dynamic-range',type=int,choices=[100,200,400])
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True,exist_ok=False,mode=0o700)
    rows=[]
    for bank in backup(args.backup)['banks']:
        if bank['slot'] not in args.slots:continue
        directory=(args.output/f"C{bank['slot']}").resolve()
        patches=bank_patches(bank,args.dynamic_range)
        command=[str(root/'.build/CameraProbe/probe'),'--raw',str(args.raw),'--output',str(directory),'--trigger','1','--cleanup']
        for offset,value in sorted(patches.items()):command+=['--set',f'{offset}:{value}']
        with (args.output/f"C{bank['slot']}.log").open('w') as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
        evidence=json.loads((directory/'evidence-private.json').read_text())
        row={'slot':bank['slot'],'bank':bank,'patches':patches,'exitCode':result.returncode,
             'readbackMatches':evidence.get('profileReadbackMatches'),'cleanupVerified':evidence.get('cleanupVerified'),
             'closeConfirmed':evidence.get('closeConfirmed'),'failure':evidence.get('failure')}
        if (directory/'output.JPG').exists():
            row['metadata']=json.loads(subprocess.check_output(['exiftool','-json','-FujiFilm:FilmMode','-FujiFilm:Saturation','-FujiFilm:WhiteBalance','-FujiFilm:WhiteBalanceFineTune','-FujiFilm:ColorTemperature','-FujiFilm:DevelopmentDynamicRange','-FujiFilm:HighlightTone','-FujiFilm:ShadowTone','-FujiFilm:GrainEffectRoughness','-FujiFilm:Sharpness','-FujiFilm:NoiseReduction',str(directory/'output.JPG')]))[0]
            row['metadata'].pop('SourceFile',None)
        rows.append(row);(args.output/'summary-private.json').write_text(json.dumps(rows,indent=2)+'\n')
        print(f"C{bank['slot']}: exit={result.returncode}, readback={row['readbackMatches']}, cleanup={row['cleanupVerified']}, close={row['closeConfirmed']}",flush=True)
        if result.returncode or not all(row.get(k) for k in ['readbackMatches','cleanupVerified','closeConfirmed']):
            raise SystemExit('Stopped; inspect evidence before another camera operation')


if __name__=='__main__':main()
