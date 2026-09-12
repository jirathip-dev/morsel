#!/usr/bin/env python3
"""Isolated contract/red probes. Never mutates canonical artwork."""
import hashlib, json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path
from PIL import Image
from library import ROOT, ART, dump

def main():
    started=time.perf_counter(); cases=[]
    with tempfile.TemporaryDirectory(prefix='food-art-contract-') as temp:
        root=Path(temp)
        for rel in ('skills/food-art','docs/art/food-library','app/Fonts','docs/evidence/issue-90'):
            shutil.copytree(ROOT/rel,root/rel)
        art=root/'docs/art/food-library';env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'}
        def run(script,*args,ok=True):
            r=subprocess.run([sys.executable,'skills/food-art/scripts/'+script,*args],cwd=root,env=env,capture_output=True,text=True,timeout=120)
            assert (r.returncode==0)==ok,(script,r.stdout,r.stderr)
            return r
        def snap():return {str(p.relative_to(art)):(hashlib.sha256(p.read_bytes()).hexdigest(),p.stat().st_mtime_ns) for folder in ('masters','exports') for p in (art/folder).glob('*')}
        before=snap();r=run('library.py','build');assert before==snap();cases.append({'name':'no-op preserves every asset byte and mtime','raw_exit':r.returncode})
        src=art/'sources/avocado.json';spec=json.loads(src.read_text());spec['layers'][0]['width']=1.3;src.write_text(json.dumps(spec))
        r=run('library.py','build');after=snap();changed=[p for p in before if before[p]!=after[p]]
        assert len(changed)==8 and all('/avocado-' in p for p in changed);cases.append({'name':'one source change rebuilds only that food','raw_exit':r.returncode,'changed':changed})
        target=art/'exports/avocado-paper-64.png';target.write_bytes(b'broken');before=snap();r=run('library.py','build');after=snap()
        assert all(before[p]==after[p] for p in before if '/avocado-' not in p);Image.open(target).verify();cases.append({'name':'tamper repair isolated to one food','raw_exit':r.returncode})
        catalog=art/'catalog.json';old=catalog.read_bytes();data=json.loads(old);data['assets'][0]['aliases']=['false alias'];catalog.write_text(json.dumps(data));r=run('verify.py',ok=False);catalog.write_bytes(old);cases.append({'name':'RED catalog drift rejected','raw_exit':r.returncode})
        old=target.read_bytes();Image.new('RGBA',(64,64)).save(target);r=run('verify.py',ok=False);target.write_bytes(old);cases.append({'name':'RED blank export rejected','raw_exit':r.returncode})
        r=run('library.py','add','skills/food-art/examples/avocado.json',ok=False);cases.append({'name':'RED duplicate ID rejected','raw_exit':r.returncode})
        spec=json.loads((root/'skills/food-art/examples/avocado.json').read_text());spec['id']='../../escape';bad=root/'invalid.json';bad.write_text(json.dumps(spec));r=run('library.py','add','invalid.json',ok=False);cases.append({'name':'RED unsafe ID rejected','raw_exit':r.returncode})
        spec['id']='invalid-color';spec['layers'][0]['fill']='#FF00FF';bad.write_text(json.dumps(spec));r=run('library.py','add','invalid.json',ok=False);cases.append({'name':'RED unapproved pigment rejected','raw_exit':r.returncode})
        spec['layers'][0]['fill']='sage';spec['layers'][0]['d']='<script>alert(1)</script>';bad.write_text(json.dumps(spec));r=run('library.py','add','invalid.json',ok=False);cases.append({'name':'RED XML injection rejected','raw_exit':r.returncode})
        r=run('verify.py');cases.append({'name':'restored fixture GREEN','raw_exit':r.returncode})
    skill=(ROOT/'skills/food-art/SKILL.md').read_text();assert skill.startswith('---\n') and '\n---\n' in skill
    front=skill.split('\n---\n',1)[0];description=next(l.split(': ',1)[1] for l in front.splitlines() if l.startswith('description:'))
    assert len(description)<=60 and description.endswith('.')
    for field in ('name:','version:','author:','license:','platforms:','metadata:','related_skills:'):assert field in front
    assert '/Users/' not in skill and '/home/' not in skill
    for section in ('When to Use','Prerequisites','How to Run','Pitfalls','Verification'):assert '## '+section in skill
    cases.append({'name':'repository skill authoring contract','status':'PASS'})
    report={'status':'PASS','elapsed_seconds':time.perf_counter()-started,'cases':cases,'raw_exit':0}
    dump(ART/'evidence/workflow-tests.json',report);print(json.dumps(report,indent=2))
if __name__=='__main__':main()
