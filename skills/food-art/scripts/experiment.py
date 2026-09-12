#!/usr/bin/env python3
"""Actual incremental experiment timing; never invents design/render durations."""
import argparse, json, subprocess, sys, time
from library import ART, ROOT, dump, digest

def snapshot():
    return {str(p.relative_to(ART)):{'sha256':digest(p),'mtime_ns':p.stat().st_mtime_ns} for folder in ('masters','exports') for p in (ART/folder).glob('*')}
def main():
    ap=argparse.ArgumentParser();ap.add_argument('action',choices=['start','finish']);ap.add_argument('--spec');args=ap.parse_args()
    evidence=ART/'evidence';evidence.mkdir(exist_ok=True)
    start=evidence/'incremental-start.json'
    if args.action=='start':
        assert not start.exists(),'Do not overwrite an earlier timing trial'
        dump(start,{'wall_start_ns':time.time_ns(),'monotonic_start_ns':time.monotonic_ns(),'before':snapshot(),'starter_ids':[a['id'] for a in json.loads((ART/'catalog.json').read_text())['assets']]})
        print('Timing started. Author a further food using only saved skill and references.')
    else:
        before=json.loads(start.read_text());t=time.perf_counter()
        command=[sys.executable,str(ROOT/'skills/food-art/scripts/library.py'),'add',args.spec]
        result=subprocess.run(command,capture_output=True,text=True,timeout=120)
        elapsed=time.perf_counter()-t;(evidence/'incremental-add.log').write_text(result.stdout+result.stderr)
        after=snapshot();changed=[p for p,v in before['before'].items() if after.get(p)!=v];added=sorted(set(after)-set(before['before']))
        record={'raw_exit':result.returncode,'command':'PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/library.py add '+args.spec,'command_elapsed_seconds':elapsed,'elapsed_including_manual_authoring_seconds':(time.monotonic_ns()-before['monotonic_start_ns'])/1e9,'unchanged_existing_artifacts':len(before['before'])-len(changed),'changed_existing_artifacts':changed,'added_artifacts':added,'manual_steps':['Read saved SKILL.md and existing mango source','Author avocado JSON paths using saved layer vocabulary','Invoke saved add command via this timing wrapper'],'retries':0,'scope_note':'Timing includes this one further food and local pipeline. Not a benchmark of arbitrary foods, approval time or paid-service cost.'}
        dump(evidence/'incremental.json',record);print(json.dumps(record,indent=2))
        assert result.returncode==0 and not changed and len(added)==8
if __name__=='__main__':main()
