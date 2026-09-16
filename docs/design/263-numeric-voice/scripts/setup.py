#!/usr/bin/env python3
"""Retain immutable source provenance and discover every mono dependency."""
from pathlib import Path
import subprocess, json, re, hashlib, shutil
R=Path(__file__).resolve().parents[1]
W=Path('/Users/jirathip/.herdr/worktrees/morsel/design-263-numeric-voice')
BASE='2d87d61e73c6c3db7bd1420294ccf1551232405d'
A=Path('/Users/jirathip/design-output/morsel/263-training-row')
def put(path,data):
    p=R/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
def source(path):return subprocess.check_output(['git','show',f'{BASE}:{path}'],cwd=W)
paths=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'app/Sources/Morsel'],cwd=W,text=True).splitlines()
pattern=re.compile(r'\.font\(.*morsel(?:Data|DataMedium|Hero|Gauge|Mono)|font\(\.morselData|monospacedValue:\s*true|return prominent \? Font.morselMono')
hits=[];retained={};allhash={}
for path in paths:
    if not path.endswith('.swift'):continue
    data=source(path);allhash[path]=hashlib.sha256(data).hexdigest();lines=data.decode().splitlines()
    local=[]
    for i,line in enumerate(lines):
        if pattern.search(line):local.append(dict(id=f'{Path(path).stem}-{i+1}',file=Path(path).name,line=i+1,code=line.strip(),context='\n'.join(lines[max(0,i-5):i+4])))
    hits+=local
    if local or Path(path).name in ['WeightTrendView.swift','GoalsEditorModel.swift','HistoryView.swift','Formatters.swift','MenuModels.swift','JournalFoodRow.swift','TrainingFuelContext.swift']:
        put('sources/native/'+Path(path).name+'.txt',data);retained[path]=hashlib.sha256(data).hexdigest()
for path in ['docs/DESIGN.md','docs/DATA_MODEL.md','docs/MCP_TOOLS.md']:
    data=source(path);put('sources/'+Path(path).name+'.txt',data);retained[path]=hashlib.sha256(data).hexdigest()
fonts=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'app/Fonts'],cwd=W,text=True).splitlines()
for path in fonts:
    data=source(path);put('assets/fonts/'+Path(path).name,data);retained[path]=hashlib.sha256(data).hexdigest()
PIN='68be41d1f3e3fdabcfe28efab79e7c4a2879377b'
for name in ['a-paper-focaccia.svg','a-night-focaccia.svg','a-paper-mortadella.svg','a-night-mortadella.svg']:
    data=subprocess.check_output(['git','show',PIN+':docs/design/tactile-journal/assets/'+name],cwd=W)
    put('assets/'+name,data);retained['approved-A/'+name]=hashlib.sha256(data).hexdigest()
for name in ['a-paper.png','a-night.png']:
    data=subprocess.check_output(['git','show',PIN+':docs/design/tactile-journal/evidence/'+name],cwd=W)
    put('baseline/'+name,data);retained['baseline/'+name]=hashlib.sha256(data).hexdigest()
data=source('docs/art/food-library/ART-SPEC.md');put('sources/ART-SPEC.md.txt',data);retained['docs/art/food-library/ART-SPEC.md']=hashlib.sha256(data).hexdigest()
put('sources/source-sites.json',(json.dumps(hits,indent=2,ensure_ascii=False)+'\n').encode())
put('sources/provenance.json',(json.dumps(dict(base=BASE,approved_A='68be41d1f3e3fdabcfe28efab79e7c4a2879377b',retained=retained,all_native_source_hashes=allhash,scan_pattern=pattern.pattern),indent=2)+'\n').encode())
if not (R/'sources/issue-263.json').exists():
    put('sources/issue-263.json',subprocess.check_output(['gh','issue','view','263','--repo','jirathip-dev/morsel','--json','title,body,comments']))
print(json.dumps(dict(sites=len(hits),files=len(set(h['file'] for h in hits)),base=BASE)))
