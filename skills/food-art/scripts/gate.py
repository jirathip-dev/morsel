#!/usr/bin/env python3
"""One complete design gate; raw subprocess exits and logs are retained."""
import json, os, subprocess, sys, time
from library import ART, ROOT, dump

def main():
    steps=[('build','library.py','build'),('assets','verify.py'),('workflow','test_workflow.py'),('browser','capture.py'),('reproduction','package.py','--reproduce')]
    results=[];evidence=ART/'evidence';evidence.mkdir(exist_ok=True)
    for label,*args in steps:
        command=[sys.executable,str(ROOT/'skills/food-art/scripts'/args[0]),*args[1:]];start=time.perf_counter()
        result=subprocess.run(command,cwd=ROOT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},capture_output=True,text=True,timeout=300)
        (evidence/f'gate-{label}.log').write_text(result.stdout+result.stderr)
        results.append({'step':label,'command':'PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/'+' '.join(args),'raw_exit':result.returncode,'elapsed_seconds':time.perf_counter()-start,'log':f'evidence/gate-{label}.log'})
        dump(evidence/'gates.json',{'status':'PASS' if all(r['raw_exit']==0 for r in results) and len(results)==len(steps) else 'INCOMPLETE_OR_FAIL','steps':results})
        if result.returncode:raise SystemExit(result.returncode)
    print(json.dumps(results,indent=2))
if __name__=='__main__':main()
