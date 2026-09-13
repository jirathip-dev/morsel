#!/usr/bin/env python3
"""Full design gate with retained raw exits; no app tests or app writes."""
import json
import os
import re
import subprocess
import sys
import time
from html.parser import HTMLParser
from pathlib import Path
from ink_library import ROOT, OUT, dump, require


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths=[]
    def handle_starttag(self,tag,attrs):
        for key,value in attrs:
            if key in ('href','src'):
                self.paths.append(value)


def local_checks():
    checked=0
    for p in OUT.glob('*.html'):
        parser=Links()
        parser.feed(p.read_text())
        for rel in parser.paths:
            require(not re.match(r'\w+:',rel),'nonlocal HTML resource')
            require((p.parent/rel).is_file(),'missing local link: '+rel)
            checked+=1
    text=(ROOT/'skills/food-art/SKILL.md').read_text()
    require(text.startswith('---\n') and '\n---\n' in text,'frontmatter boundaries')
    front,body=text[4:].split('\n---\n',1)
    for field in ('name','description','version','author','license','platforms','metadata'):
        require(re.search(r'^'+field+r':',front,re.M),'missing skill field: '+field)
    desc=re.search(r'^description: (.*)$',front,re.M).group(1).strip('"')
    require(len(desc)<=60 and desc.endswith('.'),'skill description contract')
    require('Guy (jirathip-k), Hermes Agent' in front,'human author credit')
    require(not re.search(r'/Users/|/home/',text),'machine-local skill path')
    for heading in ('When to Use','Prerequisites','How to Run','Quick Reference','Pitfalls','Verification'):
        require('## '+heading in body,'missing skill section')
    required=['skills/food-art/references/approved-expansion.md','skills/food-art/references/sample-first-refinement.md',
              'skills/food-art/templates/ink-food.json','docs/art/food-library-v2/ART-SPEC.md']
    require(all((ROOT/p).is_file() for p in required),'missing skill linked file')
    scripts=list((ROOT/'skills/food-art/scripts').glob('ink_*.py'))+list((ROOT/'skills/food-art/scripts').glob('chicken_gate.py'))
    for p in scripts:
        compile(p.read_text(),str(p),'exec')
    result={'status':'PASS','raw_exit':0,'local_html_links':checked,'compiled_scripts':len(scripts),
            'skill_frontmatter_and_required_links':'PASS','note':'Repository-local checks, not the absent Brain validator/docs generator.'}
    dump(OUT/'evidence/local-checks.json',result)
    return result


def main():
    if len(sys.argv)>1 and sys.argv[1]=='local':
        print(json.dumps(local_checks(),indent=2))
        return
    steps=[('build','ink_library.py','build'),('proofs','ink_proofs.py'),
           ('chicken','chicken_gate.py'),('browser','ink_capture.py'),
           ('assets','ink_library.py','verify'),('workflow','ink_tests.py'),
           ('local','ink_gate.py','local')]
    results=[]
    started=time.perf_counter()
    for name,*args in steps:
        tick=time.perf_counter()
        command=[sys.executable,str(ROOT/'skills/food-art/scripts'/args[0]),*args[1:]]
        result=subprocess.run(command,cwd=ROOT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},capture_output=True,text=True,timeout=300)
        log=f'evidence/gate-{name}.log'
        (OUT/log).write_text((result.stdout+result.stderr).replace(str(ROOT),'REPOSITORY_ROOT'))
        results.append({'step':name,'command':'PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/'+' '.join(args),
                        'raw_exit':result.returncode,'seconds':time.perf_counter()-tick,'log':log})
        status='PASS' if len(results)==len(steps) and all(r['raw_exit']==0 for r in results) else 'INCOMPLETE_OR_FAIL'
        dump(OUT/'evidence/gates.json',{'status':status,'steps':results,'seconds':time.perf_counter()-started,
                                       'scope':'Design gate only. Does not test, build, wire or approve the native app.'})
        print(name,result.returncode,flush=True)
        if result.returncode:
            print(result.stdout+result.stderr)
            raise SystemExit(result.returncode)
    print('PASS: all design gate steps exited 0')

if __name__=='__main__':
    main()
