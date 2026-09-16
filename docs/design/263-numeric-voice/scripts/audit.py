#!/usr/bin/env python3
"""Fail-closed exact file-set, SHA, source and render evidence gate."""
from pathlib import Path
import json,hashlib,sys,struct,re,subprocess
R=Path(__file__).resolve().parents[1]
checks=[]
def ck(name,test):
    assert test,name
    checks.append(name)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads((R/p).read_text())
C=load('coverage.json');V=load('evidence/verification.json');T=load('evidence/rerender.json');P=load('sources/provenance.json');A=load('sources/independent-audit.json')
ck('Both real render runs passed',V['status']==T['status']=='PASS')
ck('Same render inputs',V['inputDigest']==T['inputDigest'])
inputfiles=sorted(['style.css','specimen.js','gallery.js','scripts/verify.mjs','coverage.json']+[p.name for p in R.glob('*.html')])
current=hashlib.sha256('\0'.join(f+'\0'+sha(R/f) for f in inputfiles).encode()).hexdigest()
ck('No stale render input',current==V['inputDigest'])
expected={f'evidence/{p["id"]}-{t}-{v}.png' for p in C['pages'] for t in ['paper','night'] for v in ['before','after']}
expected|={f'evidence/alignment-{s}-{t}-{w}.png' for s in ['small','large'] for t in ['paper','night'] for w in [400,500]}
expected|={'evidence/gallery-390.png','evidence/gallery-1100.png'}
for run in [V,T]:
    ck('Exact rendered capture set '+run['mode'],{c['file'] for c in run['captures']}==expected)
    ck('Unique capture records '+run['mode'],len(run['captures'])==len(expected))
    ck('No console/network errors '+run['mode'],not run['errors'] and not run['network'])
    for c in run['captures']:
        p=R/c['file'];data=p.read_bytes();ck('Hash '+c['file'],sha(p)==c['sha256'])
        ck('PNG dimensions '+c['file'],data[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',data[16:24])==(c['width'],c['height']))
        if c['observed'].get('page'):
            o=c['observed'];ck('Capture label '+c['file'],c['file']==f'evidence/{o["page"]}-{o["theme"]}-{o["version"]}.png' and (c['width'],c['height'])==(390,844))
fontids={Path(s['file']).stem+'-'+str(s['line']) for s in A['font_sites']}
ours={s['id'] for s in C['sites'] if 'monospacedValue: true' not in s['code']}
ck('Independent font-site sweep matches',fontids==ours)
ck('Every discovered binding accounted',all(s['pages'] or s['id'] in C['exclusions'] for s in C['sites']))
ck('No invented mapped source',{s for p in C['pages'] for s in p['sites']}|set(C['exclusions'])=={s['id'] for s in C['sites']})
for source,digest in P['retained'].items():
    if source.startswith('approved-A/'):local=R/'assets'/Path(source).name
    elif source.startswith('baseline/'):local=R/source
    elif source.startswith('app/Fonts/'):local=R/'assets/fonts'/Path(source).name
    elif source.startswith('app/Sources/'):local=R/'sources/native'/(Path(source).name+'.txt')
    else:local=R/'sources'/(Path(source).name+'.txt')
    ck('Locked source '+source,sha(local)==digest)
# Proportional control must fail equal-width condition; shape proof is not table metadata.
for a in load('evidence/alignment.json'):
    for line in a['lines']:
        spread=max(line['widths'])-min(line['widths'])
        ck('Measured feature '+str((a['theme'],a['weight'],line['size'],line['feature'])),spread<=.016 if line['feature']=='tnum' else spread>.5)
    ck('Actual browser face',all(f['isCustomFont'] and 'Garamond' in f['familyName'] for f in a['fonts']))
ck('Native limit stays explicit',V['native_alignment'].startswith('UNVERIFIED') and 'UNVERIFIED' in (R/'LIMITS.md').read_text())
# Kept-mono surfaces must have pixel-identical excerpt region (header labels differ).
from PIL import Image,ImageChops
for p in C['pages']:
    if p['group']!='technical':continue
    for theme in ['paper','night']:
        b=Image.open(R/f'evidence/{p["id"]}-{theme}-before.png').convert('RGB').crop((0,49,390,844))
        a=Image.open(R/f'evidence/{p["id"]}-{theme}-after.png').convert('RGB').crop((0,49,390,844))
        ck('Unchanged mono pixels '+p['id']+theme,ImageChops.difference(a,b).getbbox() is None)
# Exact retained local-link closure; URLs in escaped prompt strings are not links.
from urllib.parse import unquote,urlsplit
for p in R.glob('*.html'):
    for url in re.findall(r'(?:href|src)="([^"]+)"',p.read_text()):
        if url.startswith(('data:','http:','https:','#')):continue
        u=unquote(urlsplit(url).path)
        if '__THEME__' in u:continue
        ck('Local link '+url,(p.parent/u).exists())
# Palette pair measurements from the rendered CSS values.
def lum(h):
    rgb=[int(h[i:i+2],16)/255 for i in (1,3,5)];v=[c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4 for c in rgb]
    return sum(x*y for x,y in zip(v,[.2126,.7152,.0722]))
contrast=[]
css=(R/'style.css').read_text()
for theme,selector in [('paper',r':root\{([^}]+)\}'),('night',r':root\[data-theme=night\]\{([^}]+)\}')]:
    palette=dict(re.findall(r'--([a-z]+):(#[0-9A-Fa-f]{6})',re.search(selector,css)[1]))
    observed={x['color'] for c in V['captures'] if c['observed'].get('theme')==theme for x in c['observed'].get('voices',[])}
    observed_hex={'#'+''.join(f'{int(n):02X}' for n in re.findall(r'\d+',color)) for color in observed}
    ck('Rendered numeric colors are declared '+theme,observed_hex <= set(palette.values()))
    for background in ['bg','surface','field']:
        bg=palette[background]
        for foreground in ['ink','secondary','positive','error']+(['tertiary'] if background=='bg' else []):
            fg=palette[foreground]
            ls=sorted([lum(bg),lum(fg)]);ratio=(ls[1]+.05)/(ls[0]+.05)
            contrast.append(dict(theme=theme,foreground_role=foreground,foreground=fg,background_role=background,background=bg,ratio=ratio))
            ck('Important text contrast '+theme+foreground+background,ratio>=4.5)
G=load('evidence/generation-rerun.json')
ck('Generation rerun passed',G['status']=='PASS' and G['files']==len(G['sha256']))
for path,digest in G['sha256'].items():ck('Reproduced generator output '+path,sha(R/path)==digest)
# Store measurements only during seal; read-only audit stays read-only.
if '--seal' in sys.argv:(R/'evidence/contrast.json').write_text(json.dumps(contrast,indent=2)+'\n')
raw=sorted(p.relative_to(R).as_posix() for p in R.rglob('*') if p.is_file())
ck('No transient artifacts',not any(re.search(r'(__pycache__|\.py[co]$|\.DS_Store|\.blend\d|\.tmp$|\.bak$|\.swp$|\.brief|\.report)',p) for p in raw))
ck('No Swift authored',not any(p.endswith('.swift') for p in raw))
files=[p for p in raw if p!='manifest.json']
manifest=dict(schema=1,excludes=['manifest.json'],files={p:dict(sha256=sha(R/p),bytes=(R/p).stat().st_size) for p in files})
if '--seal' in sys.argv:(R/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
ck('Manifest exact raw set and hashes',load('manifest.json')==manifest)
print(json.dumps(dict(status='PASS',checks=len(checks),raw_files=len(files)+1,manifest_entries=len(files),manifest_self_excluded=True,total_bytes=sum((R/p).stat().st_size for p in files)+(R/'manifest.json').stat().st_size,captures=len(expected),native_alignment='UNVERIFIED',manifest_sha256=sha(R/'manifest.json')),indent=2))
