#!/usr/bin/env python3
"""Real-browser all-ID phone proof; fresh profiles, deterministic static HTML."""
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from PIL import Image
from pipeline import ROOT, read, save, require, admission, sha


def run(batch):
    dest=ROOT/f'batch-{batch}'
    admission(dest)
    layout=read(dest/'proof-layout.json')
    engines=sorted(Path.home().glob('Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell'))
    engine=os.environ.get('CHROME_HEADLESS_SHELL') or shutil.which('chrome-headless-shell') or (str(engines[-1]) if engines else None)
    require(engine,'existing headless Chromium required')
    cases=[(f'phone-{c}-{t}',390,844) for t in ('paper','night') for c in layout['cohorts']]
    cases += [(f'gallery-{t}',w,h) for t in ('paper','night') for w,h in ((1440,1000),(390,844))]
    proofs=dest/'proofs'
    proofs.mkdir(exist_ok=True)
    evidence=dest/'browser-logs'
    evidence.mkdir(exist_ok=True)
    scratch=ROOT.parent/'.262-scratch'
    scratch.mkdir(exist_ok=True)
    results=[]
    for index,(page,w,h) in enumerate(cases):
        if index and index % 4 == 0:
            admission(dest)
        name=page if page.startswith('phone') else f'{page}-{w}'
        target=proofs/f'{name}.png'
        with tempfile.TemporaryDirectory(dir=scratch,prefix='chrome-') as profile:
            command=[engine,'--no-sandbox','--disable-gpu','--hide-scrollbars','--no-first-run','--no-default-browser-check',f'--user-data-dir={profile}',f'--window-size={w},{h}','--force-device-scale-factor=1','--virtual-time-budget=2500',f'--screenshot={target}',(dest/f'{page}.html').as_uri()]
            p=subprocess.run(command,capture_output=True,text=True,timeout=60)
        log=p.stdout+p.stderr
        # Preserve useful console facts without host-specific process noise/paths.
        facts_lines=[line for line in log.splitlines() if 'INK_QA=' in line or re.search(r'Uncaught|CONSOLE.*(?:Error|error)|Failed to load resource',line)]
        (evidence/f'{name}.log').write_text('\n'.join(facts_lines).replace(str(ROOT),'ARTIFACT_ROOT')+'\n')
        require(p.returncode==0,'browser exit: '+str(p.returncode))
        matches=re.findall(r'INK_QA=(\{.*?\})"',log)
        require(matches,'DOM facts missing: '+name)
        facts=json.loads(matches[-1])
        require(facts['images'] and facts['fonts'] and not facts['overflow'],'DOM assets/overflow: '+name)
        require(not re.search(r'Uncaught|CONSOLE.*(?:Error|error)|Failed to load resource',log),'console error: '+name)
        require(facts['viewport']==[w,h] and Image.open(target).size==(w,h),'viewport/dimension mismatch')
        require(facts['minHitWidth']>=44 and facts['minHitHeight']>=44,'small link target')
        require(all((dest/href).is_file() for href in facts['links']),'broken local proof link')
        if page.startswith('phone'):
            cohort=page.split('-')[1]
            require(facts['ids']==layout['cohorts'][cohort],'phone cohort differs')
            require(facts['allRowsVisible'],'phone rows clipped')
            require(all(v==[64,64] for v in facts['imageSizes']),'not native 64px')
        else:
            require(facts['ids']==layout['ids'],'gallery closed set differs')
        results.append({'page':page,'capture':str(target.relative_to(ROOT)),'raw_exit':p.returncode,'sha256':sha(target),'dom':facts})
        save(dest/'browser.json',{'status':'INCOMPLETE','captures':results})
    scratch.rmdir()
    coverage={}
    for theme in ('paper','night'):
        coverage[theme]=[iid for r in results if r['page'].startswith('phone-') and r['page'].endswith('-'+theme) for iid in r['dom']['ids']]
        require(coverage[theme]==layout['ids'],'all-ID theme coverage differs')
        strip=Image.new('RGB',(390*len(layout['cohorts']),844))
        for i,c in enumerate(layout['cohorts']):
            strip.paste(Image.open(proofs/f'phone-{c}-{theme}.png'),(390*i,0))
        strip.save(proofs/f'phone-all-{theme}.png')
    result={'status':'PASS','raw_exit':0,'engine':subprocess.check_output([engine,'--version'],text=True).strip(),'capture_count':len(results),'phone_catalog_coverage':coverage,'captures':results,'scope':'Real browser + DOM checks of fictional labeled contexts, not actual app UI. Visual judgment and owner approval are separate.'}
    save(dest/'browser.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='captures'}))


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--batch',type=int,choices=range(1,6),required=True)
    run(ap.parse_args().batch)
