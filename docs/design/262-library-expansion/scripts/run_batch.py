#!/usr/bin/env python3
"""One serial mechanical production pass; visual review and publishing stay separate."""
import argparse
import subprocess
import sys
from pathlib import Path
from pipeline import ROOT, save


def run(batch,product,names):
    commands=[
        ['pipeline.py','build','--batch',str(batch)],
        ['pipeline.py','coverage','--batch',str(batch),'--private-names',str(names)],
        ['pipeline.py','verify','--batch',str(batch),'--product',str(product)],
        ['pipeline.py','reproduce','--batch',str(batch)],
        ['proofs.py','--batch',str(batch)],
        ['reports.py','--batch',str(batch)],
        ['capture.py','--batch',str(batch)],
        ['reports.py','--batch',str(batch)],
    ]
    dest=ROOT/f'batch-{batch}'
    dest.mkdir(exist_ok=True)
    results=[]
    for i,args in enumerate(commands):
        command=[sys.executable,str(ROOT/'scripts'/args[0]),*args[1:]]
        result=subprocess.run(command,capture_output=True,text=True,timeout=1800)
        log=dest/f'gate-{i+1:02}-{args[0].removesuffix(".py")}.log'
        log.write_text(result.stdout+result.stderr)
        print(args,result.returncode,flush=True)
        if result.returncode:
            print(result.stdout+result.stderr,flush=True)
        results.append({'command':['python3','scripts/'+args[0],*args[1:]],'raw_exit':result.returncode,'log':log.name})
        save(dest/'gates.json',{'status':'PASS' if i==len(commands)-1 and result.returncode==0 else 'INCOMPLETE','commands':results})
        if result.returncode:
            return result.returncode
    return 0


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--batch',type=int,choices=range(1,6),required=True)
    ap.add_argument('--product',type=Path,required=True)
    ap.add_argument('--private-names',type=Path,required=True)
    args=ap.parse_args()
    raise SystemExit(run(args.batch,args.product,args.private_names))
