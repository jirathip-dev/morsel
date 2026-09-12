#!/usr/bin/env python3
"""Four local phone captures only; existing headless shell, no installation."""
import json, os, shutil, subprocess, tempfile, time
from pathlib import Path
from PIL import Image
from sample_gate import OUT, save, event

def main():
    found=sorted(Path.home().glob('Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell'))
    engine=os.environ.get('CHROME_HEADLESS_SHELL') or shutil.which('chrome-headless-shell') or (str(found[-1]) if found else None)
    assert engine,'Existing engine unavailable; escalate, no install'
    event('phone-capture-start');results=[]
    for theme in ('paper','night'):
        for version in ('before','after'):
            name=f'phone-{version}-{theme}';start=time.perf_counter()
            with tempfile.TemporaryDirectory(prefix='food-sample-') as profile:
                r=subprocess.run([engine,'--no-sandbox','--disable-gpu',f'--user-data-dir={profile}','--hide-scrollbars','--force-device-scale-factor=1','--window-size=390,844','--virtual-time-budget=2500',f'--screenshot={OUT}/{name}.png',(OUT/f'{name}.html').as_uri()],capture_output=True,text=True,timeout=60)
            (OUT/f'{name}.log').write_text(r.stdout+r.stderr)
            assert r.returncode==0,(name,r.stderr)
            assert Image.open(OUT/f'{name}.png').size==(390,844)
            results.append({'page':name,'raw_exit':r.returncode,'seconds':time.perf_counter()-start,'dimensions':[390,844]})
    event('phone-capture-end');save(OUT/'phone-capture.json',{'status':'PASS','captures':results});print(json.dumps(results,indent=2))
if __name__=='__main__':main()
