#!/usr/bin/env python3
"""Retain exact, locally available approved controls and bundled assets."""
from pathlib import Path
import subprocess, shutil, hashlib, json
ROOT=Path(__file__).resolve().parents[1]
REPO=Path('/Users/jirathip/.herdr/worktrees/morsel/design-263-training-row')
PIN='68be41d1f3e3fdabcfe28efab79e7c4a2879377b'
BASE='2d87d61e73c6c3db7bd1420294ccf1551232405d'
assert subprocess.run(['git','merge-base','--is-ancestor',BASE,'HEAD'],cwd=REPO).returncode==0
records=[]
def store(rel, data, source, revision):
    p=ROOT/rel;p.parent.mkdir(parents=True,exist_ok=True)
    if p.exists(): assert p.read_bytes()==data, f'Existing asset differs: {p}'
    else: p.write_bytes(data)
    records.append(dict(path=rel,source=source,revision=revision,sha256=hashlib.sha256(data).hexdigest()))
for f in sorted((REPO/'app/Fonts').iterdir()):
    if f.is_file():
        assert f.read_bytes()==subprocess.check_output(['git','show',BASE+':'+str(f.relative_to(REPO))],cwd=REPO)
        store('assets/fonts/'+f.name,f.read_bytes(),str(f.relative_to(REPO)),BASE)
for name in ['style.css','app.js','a.html','fixture.json','README.md','evidence/a-paper.png','evidence/a-night.png']:
    source='docs/design/tactile-journal/'+name
    data=subprocess.check_output(['git','show',PIN+':'+source],cwd=REPO)
    store('baseline/'+name,data,source,PIN)
for theme in ['paper','night']:
    for food in ['focaccia','mortadella','stracciatella','vegetables','unknown']:
        name=f'a-{theme}-{food}.svg';source='docs/design/tactile-journal/assets/'+name
        store('assets/'+name,subprocess.check_output(['git','show',PIN+':'+source],cwd=REPO),source,PIN)
for source in ['docs/DESIGN.md','docs/art/food-library/ART-SPEC.md','app/Sources/Morsel/DesignSystem.swift','app/Sources/Morsel/TrainingFuelContext.swift']:
    store('references/'+Path(source).name+'.txt',(REPO/source).read_bytes(),source,BASE)
(ROOT/'references/asset-lock.json').write_text(json.dumps(records,indent=2)+'\n')
(ROOT/'fixture.json').write_bytes((ROOT/'baseline/fixture.json').read_bytes())
print('Retained',len(records),'byte-exact assets/references')
