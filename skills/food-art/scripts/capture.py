#!/usr/bin/env python3
"""Bounded real-browser evidence; uses an existing engine, never installs."""
import json, os, re, shutil, subprocess, tempfile, time
from pathlib import Path
from PIL import Image
from library import ART, dump


def main():
    candidates=sorted(Path.home().glob('Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell'))
    chrome=os.environ.get('CHROME_HEADLESS_SHELL') or shutil.which('chrome-headless-shell') or (str(candidates[-1]) if candidates else None)
    assert chrome, 'Existing headless engine unavailable; escalate, never install'
    evidence=ART/'evidence';evidence.mkdir(exist_ok=True);results=[]
    for name,width,height in [('phone-paper',390,844),('phone-night',390,844),('gallery-paper',390,844),('gallery-night',390,844)]:
        started=time.perf_counter()
        with tempfile.TemporaryDirectory(prefix='food-art-browser-') as profile:
            args=[chrome,'--no-sandbox','--hide-scrollbars','--no-first-run','--no-default-browser-check','--disable-gpu',f'--user-data-dir={profile}',f'--window-size={width},{height}','--force-device-scale-factor=1','--virtual-time-budget=4000',f'--screenshot={ART}/proofs/{name}-390.png',(ART/f'{name}.html').as_uri()]
            result=subprocess.run(args,capture_output=True,text=True,timeout=60)
        log=result.stdout+result.stderr;(evidence/f'browser-{name}.log').write_text(log)
        assert result.returncode==0,(name,result.returncode)
        matches=re.findall(r'FOOD_QA=(\{.*?\})"',log); assert matches,('no DOM proof',log)
        facts=json.loads(matches[-1]);assert facts['images'] and facts['fonts'] and not facts['overflow'],facts
        assert not re.search(r'Uncaught|CONSOLE.*(?:Error|error)|Failed to load resource',log),log
        image=Image.open(ART/f'proofs/{name}-390.png');assert image.size==(width,height)
        results.append({'page':name,'raw_exit':result.returncode,'elapsed_seconds':round(time.perf_counter()-started,3),'dom':facts,'dimensions':list(image.size)})
    dump(evidence/'browser.json',{'status':'PASS','engine':subprocess.check_output([chrome,'--version'],text=True).strip(),'captures':results})
    print(json.dumps(results,indent=2))
if __name__=='__main__':main()
