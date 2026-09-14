#!/usr/bin/env python3
"""Fresh-profile real Chromium captures for all catalog phone cohorts."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from PIL import Image
from ink_library import OUT, THEMES, require, dump, subjects
from ink_proofs import COHORTS


def run():
    candidates=sorted(Path.home().glob('Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell'))
    engine=os.environ.get('CHROME_HEADLESS_SHELL') or shutil.which('chrome-headless-shell') or (str(candidates[-1]) if candidates else None)
    require(engine,'Existing headless engine unavailable; no installation allowed')
    dest=OUT/'proofs'
    dest.mkdir(exist_ok=True)
    entries=subjects()
    ids={a['id'] for a in entries}
    cases=[(f'phone-{c}-{t}',390,844,f'phone-{c}-{t}') for t in THEMES for c in COHORTS]
    cases += [(f'gallery-{t}',w,h,f'gallery-{t}-{w}') for t in THEMES for w,h in ((1440,1000),(390,844))]
    results=[]
    started=time.perf_counter()
    for page,w,h,name in cases:
        tick=time.perf_counter()
        with tempfile.TemporaryDirectory(prefix='morsel-ink-browser-') as profile:
            args=[engine,'--no-sandbox','--disable-gpu','--hide-scrollbars','--no-first-run','--no-default-browser-check',f'--user-data-dir={profile}',f'--window-size={w},{h}','--force-device-scale-factor=1','--virtual-time-budget=3000',f'--screenshot={dest}/{name}.png',(OUT/f'{page}.html').as_uri()]
            result=subprocess.run(args,capture_output=True,text=True,timeout=60)
        log=result.stdout+result.stderr
        # Keep readable logs without machine-specific absolute file URLs.
        (OUT/f'evidence/browser-{name}.log').write_text(log.replace(str(OUT),'ARTIFACT_ROOT'))
        require(result.returncode==0,f'Browser exit {result.returncode}: {name}')
        match=re.findall(r'INK_QA=(\{.*?\})"',log)
        require(match,f'Missing DOM facts: {name}')
        facts=json.loads(match[-1])
        require(facts['images'] and facts['fonts'] and not facts['overflow'],f'DOM failure: {name}/{facts}')
        require(not re.search(r'Uncaught|CONSOLE.*(?:Error|error)|Failed to load resource',log),f'Console error: {name}')
        require(facts['viewport']==[w,h],f'Viewport mismatch: {name}')
        require(Image.open(dest/f'{name}.png').size==(w,h),'Screenshot dimensions')
        if page.startswith('phone-'):
            cohort=page.removeprefix('phone-').rsplit('-',1)[0]
            require(facts['ids']==COHORTS[cohort],f'Phone cohort mismatch: {name}')
            require(all(s==[64,64] for s in facts['imageSizes']),'Not native 64px')
            require(facts['allRowsVisible'],'Phone rows clipped below viewport')
        else:
            require(set(facts['ids'])==ids and len(facts['ids'])==len(ids),'Gallery omitted or duplicated ID')
        require(facts['minHitWidth']>=44 and facts['minHitHeight']>=44,'Undersized interactive target')
        for link in facts['links']:
            require((OUT/link).is_file(),f'Broken proof link: {link}')
        results.append({'page':page,'capture':f'proofs/{name}.png','raw_exit':result.returncode,'seconds':time.perf_counter()-tick,'dom':facts})
        dump(OUT/'evidence/browser.json',{'status':'INCOMPLETE','captures':results})
    for theme in THEMES:
        strip=Image.new('RGB',(390*len(COHORTS),844))
        for col,cohort in enumerate(COHORTS):
            strip.paste(Image.open(dest/f'phone-{cohort}-{theme}.png'),(390*col,0))
        strip.save(dest/f'phone-all-{theme}.png')
    coverage={t:sorted({id for r in results if r['page'].startswith('phone-') and r['page'].endswith('-'+t) for id in r['dom']['ids']}) for t in THEMES}
    require(all(set(v)==ids for v in coverage.values()),'Not all catalog IDs captured in each theme')
    report={'status':'PASS','raw_exit':0,'engine':subprocess.check_output([engine,'--version'],text=True).strip(),
            'seconds':time.perf_counter()-started,'captures':results,'phone_catalog_coverage':coverage,
            'scope':'Real-browser capture and DOM validation only; no visual-review or authoring-time claim.'}
    dump(OUT/'evidence/browser.json',report)
    print(json.dumps({'status':'PASS','capture_count':len(results),'seconds':report['seconds'],'phone_catalog_coverage':coverage},indent=2))

if __name__=='__main__':
    run()
