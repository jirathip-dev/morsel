#!/usr/bin/env python3
"""Execute the brief's non-native repo gates once, retaining raw exits."""
import argparse
import subprocess
import time
from pathlib import Path
from pipeline import ROOT, save


def run(repo):
    dest=ROOT/'evidence/repo-gates'
    dest.mkdir(parents=True,exist_ok=True)
    results=[]
    commands=[('npm-ci',['npm','ci','--no-audit','--no-fund']),('typecheck',['npm','run','typecheck']),('lint',['npm','run','lint']),('npm-test',['npm','test']),('diff-check',['git','diff','--check'])]
    for name,command in commands:
        # Owner coordination ruling: TS gates do not require the render window.
        with (dest/f'{name}.log').open('w') as log:
            result=subprocess.run(command,cwd=repo,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        results.append({'name':name,'argv':command,'raw_exit':result.returncode,'status':'PASS' if result.returncode==0 else 'FAIL'})
        save(dest/'gates.json',results)
        print(name,result.returncode,flush=True)
        if name=='npm-ci' and result.returncode:
            return result.returncode
    return 1 if any(r['raw_exit']!=0 for r in results) else 0


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--repo',type=Path,required=True)
    raise SystemExit(run(ap.parse_args().repo))
