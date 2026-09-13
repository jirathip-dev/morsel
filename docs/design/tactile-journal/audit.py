"""Lightweight static/contrast/generator/PNG verification and SHA-256 manifest."""
from pathlib import Path
import hashlib, json, re, struct, subprocess, sys
root=Path(__file__).resolve().parent

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def luminance(h):
 rgb=[int(h[i:i+2],16)/255 for i in (1,3,5)]
 linear=[x/12.92 if x<=.04045 else ((x+.055)/1.055)**2.4 for x in rgb]
 return sum(x*y for x,y in zip(linear,(.2126,.7152,.0722)))
def contrast(a,b):
 x,y=sorted([luminance(a),luminance(b)])
 return (y+.05)/(x+.05)
checks=[]
def check(name,ok,data=None):
 checks.append(dict(name=name,pass_=bool(ok),data=data))
 if not ok: raise AssertionError(name)
if '--check-manifest' in sys.argv:
 data=json.loads((root/'evidence/manifest.json').read_text())
 for f,digest in data.items():check(f,sha(root/f)==digest)
 print(f'PASS manifest: {len(checks)} files');sys.exit(0)
assets=list((root/'assets').glob('*.svg'))
check('20 representative SVGs',len(assets)==20)
for p in assets: check(p.name+' original source bounds','viewBox="0 0 256 256"' in p.read_text() and '<image' not in p.read_text())
generated=assets+[root/f for f in ['a.html','b.html','fixture.json','fixture.js']]
before={str(p):sha(p) for p in generated}
r=subprocess.run([sys.executable,str(root/'generate.py')],capture_output=True,text=True,timeout=15)
check('Generator raw exit 0',r.returncode==0,r.stdout)
check('Generator byte reproducibility',before=={str(p):sha(p) for p in generated})
css=(root/'style.css').read_text()
colors={m.group(1):m.group(2) for m in re.finditer(r'--([\w-]+):(#[0-9A-Fa-f]{6})',css.split(':root.night')[0])}
night={**colors,**{m.group(1):m.group(2) for m in re.finditer(r'--([\w-]+):(#[0-9A-Fa-f]{6})',css.split(':root.night')[1].split('}')[0])}}
ratios={}
for theme,c in [('paper',colors),('night',night)]:
 for fg,bg in [('ink','bg'),('secondary','bg'),('positive','bg'),('error','bg'),('ink','field')]:
  ratio=contrast(c[fg],c[bg]);ratios[f'{theme}:{fg}/{bg}']=round(ratio,3);check(f'{theme} text {fg}/{bg}',ratio>=4.5,ratio)
 for fg in ['inkline','protein','carbs','fat']:
  ratio=contrast(c[fg],c['bg']);ratios[f'{theme}:{fg}/bg']=round(ratio,3);check(f'{theme} mark {fg}',ratio>=3,ratio)
ratio=contrast('#2A261F','#E66A2C');ratios['button']=round(ratio,3);check('Orange ink label >=4.5',ratio>=4.5,ratio)
proof=json.loads((root/'evidence/verification.json').read_text());check('Browser verdict and all checks',proof['status']=='PASS' and all(c['pass'] for c in proof['checks']),len(proof['checks']))
pngs=list((root/'evidence').glob('*.png'));dimensions={}
for p in pngs:
 data=p.read_bytes();check(p.name+' PNG',data[:8]==b'\x89PNG\r\n\x1a\n');wh=struct.unpack('>II',data[16:24]);dimensions[p.name]=wh
 check(p.name+' viewport',wh[0]==860 if p.name.startswith('comparison-') else wh==(390,844),wh)
check('Required comparison proofs',all((root/'evidence'/f'comparison-{t}.png').is_file() for t in ['paper','night']))
check('No prototype persistence or fetch',not re.search(r'\b(localStorage|sessionStorage|indexedDB|fetch|XMLHttpRequest)\b',(root/'app.js').read_text()))
result=dict(status='PASS',checks=checks,contrast=ratios,png_count=len(pngs),dimensions=dimensions,browser_check_count=len(proof['checks']))
(root/'evidence/audit.json').write_text(json.dumps(result,indent=2)+'\n')
manifest={str(p.relative_to(root)):sha(p) for p in sorted(root.rglob('*')) if p.is_file() and p.name not in ['manifest.json','gate-exits.json'] and p.suffix!='.log' and '__pycache__' not in p.parts}
(root/'evidence/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'PASS static checks: {len(checks)}; browser checks: {len(proof["checks"])}; PNGs: {len(pngs)}; manifest: {len(manifest)} files')
print(json.dumps(ratios,sort_keys=True))
