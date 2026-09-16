#!/usr/bin/env python3
"""Capture and verify the aggregate Compare index at real viewport dimensions."""
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from PIL import Image
from pipeline import ROOT, read, save, sha, require, admission


def main():
    dest=ROOT/'evidence/index'
    dest.mkdir(parents=True,exist_ok=True)
    admission(dest)
    engines=sorted(Path.home().glob('Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell'))
    engine=os.environ.get('CHROME_HEADLESS_SHELL') or shutil.which('chrome-headless-shell') or (str(engines[-1]) if engines else None)
    require(engine,'headless Chromium missing')
    inputs={ROOT/'index.html',*list((ROOT/'library/fonts').glob('*.ttf'))}
    pins={str(p.relative_to(ROOT)):sha(p) for p in inputs}
    expected=['batch-'+str(b['batch']) for b in read(ROOT/'ROLLUP.json')['batches']]
    results=[]
    for w,h in ((1440,1000),(390,844)):
        target=dest/f'index-{w}.png'
        with tempfile.TemporaryDirectory(prefix='morsel262-index-') as profile:
            cmd=[engine,'--no-sandbox','--disable-gpu','--hide-scrollbars','--no-first-run','--no-default-browser-check',f'--user-data-dir={profile}',f'--window-size={w},{h}','--force-device-scale-factor=1','--virtual-time-budget=2500',f'--screenshot={target}',(ROOT/'index.html').as_uri()]
            p=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
        log=p.stdout+p.stderr
        facts_lines=[line for line in log.splitlines() if 'INK_QA=' in line or re.search(r'Uncaught|CONSOLE.*(?:Error|error)|Failed to load resource',line)]
        (dest/f'index-{w}.log').write_text('\n'.join(facts_lines).replace(str(ROOT),'ARTIFACT_ROOT')+'\n')
        matches=re.findall(r'INK_QA=(\{.*?\})"',log)
        require(p.returncode==0 and matches,'browser failed or missing DOM facts')
        facts=json.loads(matches[-1])
        require(not re.search(r'Uncaught|CONSOLE.*(?:Error|error)|Failed to load resource',log),'console error')
        require(facts['fonts'] and facts['images'] and not facts['overflow'],'font/asset/overflow')
        require(facts['viewport']==[w,h] and Image.open(target).size==(w,h),'viewport mismatch')
        require(facts['minHitWidth']>=44 and facts['minHitHeight']>=44,'small target')
        require(facts['ids']==expected,'missing batch row')
        require(all((ROOT/x).is_file() for x in facts['links']),'broken index link')
        results.append({'capture':str(target.relative_to(ROOT)),'sha256':sha(target),'raw_exit':p.returncode,'dom':facts})
    require(all(sha(ROOT/p)==h for p,h in pins.items()),'inputs changed mid-capture')
    result={'status':'PASS','inputs_sha256':pins,'capture_count':len(results),'captures':results,'vertical_scroll':'expected on the mobile index; no fixed footer or clipped scroll container'}
    save(dest/'verification.json',result)
    print({'index_browser':'PASS','capture_count':len(results),'linked_batches':len(expected)})


if __name__=='__main__':
    main()
