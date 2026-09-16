#!/usr/bin/env python3
"""Independent manifest, PNG dimensions, links, locked assets and contrast."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit,unquote
import hashlib,json,re,struct,sys
R=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def lum(color):
 c=[int(color[i:i+2],16)/255 for i in [1,3,5]]
 c=[v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in c]
 return sum(x*y for x,y in zip(c,[.2126,.7152,.0722]))
def contrast(a,b):
 x,y=sorted([lum(a),lum(b)]);return (y+.05)/(x+.05)
css=(R/'style.css').read_text();baseline=(R/'baseline/style.css').read_text();new=set(re.findall(r'#[0-9A-Fa-f]{6}',css));old={x.upper() for x in re.findall(r'#[0-9A-Fa-f]{6}',baseline)}
assert all(c.upper() in old for c in new),'Unapproved color'
colors={}
for name,pattern in [('paper',r':root\{([^}]+)'),('night',r':root.night\{([^}]+)')]:
 colors[name]=dict(re.findall(r'--([\w-]+):(#[0-9A-Fa-f]{6})',re.search(pattern,css)[1]))
 if name=='night':colors[name]={**colors['paper'],**colors[name]}
measurements=[]
for theme,c in colors.items():
 for fg,bg,minimum in [('ink','bg',4.5),('secondary','bg',4.5),('secondary','field',4.5),('positive','bg',4.5),('positive','field',4.5),('error','bg',4.5),('inkline','bg',3),('inkline','field',3)]:
  value=contrast(c[fg],c[bg]);assert value>=minimum,(theme,fg,bg,value)
  measurements.append(dict(theme=theme,foreground=c[fg],background=c[bg],role=fg+'/'+bg,ratio=value,minimum=minimum))
value=contrast('#2A261F','#E66A2C');assert value>=4.5;measurements.append(dict(role='primary action ink/orange',ratio=value,minimum=4.5))
(R/'evidence/contrast.json').write_text(json.dumps(measurements,indent=2)+'\n')
for a in json.loads((R/'references/asset-lock.json').read_text()):assert sha(R/a['path'])==a['sha256'],a
class Links(HTMLParser):
 def handle_starttag(self,tag,attrs):
  for key,value in attrs:
   if key not in ['src','href'] or not value:continue
   u=urlsplit(value)
   if u.scheme or not u.path:continue
   dest=(self.file.parent/unquote(u.path)).resolve();assert dest.is_relative_to(R.resolve()),str(dest)
   assert dest.exists(),f'{self.file.name}: missing {value}'
links=Links()
for p in R.glob('*.html'):links.file=p;links.feed(p.read_text())
for source,generated,prefix in [('states.json','states.js','window.STATES='),('fixture.json','fixture.js','window.FIXTURE=')]:
 text=(R/generated).read_text().strip();assert text.startswith(prefix)
 assert json.loads(text[len(prefix):].removesuffix(';'))==json.loads((R/source).read_text()),generated+' is not derived from pinned JSON'
report=json.loads((R/'evidence/verification.json').read_text());assert report['status']=='PASS'
pins=['prototype.js','style.css','states.json','fixture.json','a.html','b.html','alignment.html','index.html','scripts/verify.mjs']+sorted(str(p.relative_to(R)) for p in (R/'assets').rglob('*') if p.is_file())
source_digest=hashlib.sha256('\0'.join(p+'\0'+sha(R/p) for p in pins).encode()).hexdigest()
assert report['sourceDigest']==source_digest,'Browser report no longer matches render source/assets'
assert all(c['pass'] for c in report['checks'])
states=json.loads((R/'states.json').read_text());expected={f'evidence/{v}-{t}-{s["id"]}{suffix}.png' for s in states for v in ['a','b'] for t in ['paper','night'] for suffix in (['','-context'] if s.get('sheet') else [''])}|{'evidence/alignment-paper.png','evidence/alignment-night.png','evidence/gallery-desktop.png','evidence/gallery-phone.png'}
assert {c['file'] for c in report['captures']}==expected
for c in report['captures']:
 p=R/c['file'];assert sha(p)==c['sha256'],c['file'];w,h=struct.unpack('>II',p.read_bytes()[16:24]);assert [w,h]==[c['width'],c['height']]
 if re.match('evidence/[ab]-',c['file']):assert [w,h]==[390,844]
rerender=json.loads((R/'evidence/rerender.json').read_text());assert rerender['status']=='PASS';assert rerender['sourceDigest']==source_digest;assert all(c['pass'] for c in rerender['checks']);assert {c['file']:c['sha256'] for c in rerender['captures']}=={c['file']:c['sha256'] for c in report['captures']}
from PIL import Image,ImageChops
contacts=json.loads((R/'evidence/contact-index.json').read_text());members=[m for c in contacts for m in c['members']]
assert len(members)==len(set(members))==len(expected)-4
assert set(members)=={p for p in expected if re.match('evidence/[ab]-',p)}
for c in contacts:
 im=Image.open(R/c['file']).convert('RGB');assert im.size==(c['width'],c['height'])
 for i,member in enumerate(c['members']):
  x,y=(i%4)*390,(i//4)*884+40
  assert ImageChops.difference(im.crop((x,y,x+390,y+844)),Image.open(R/member).convert('RGB')).getbbox() is None,member+' contact pixels differ'
for p in R.rglob('*'):
 assert p.name not in ['__pycache__','.DS_Store','.uv-cache','.tmp'],str(p)
 assert p.suffix not in ['.pyc','.pyo','.swp','.bak'],str(p)
 assert not p.name.endswith('-mismatch.png'),'Unclassified capture mismatch: '+str(p)
paths=sorted(p for p in R.rglob('*') if p.is_file() and p.name!='manifest.json')
# The only excluded file is the root manifest; nested filenames are included.
paths=sorted(p for p in R.rglob('*') if p.is_file() and p!=R/'manifest.json')
manifest={'self_included':False,'files':[dict(path=str(p.relative_to(R)),bytes=p.stat().st_size,sha256=sha(p)) for p in paths]}
manifest['count_excluding_self']=len(paths);manifest['total_bytes_excluding_self']=sum(r['bytes'] for r in manifest['files'])
if '--seal' in sys.argv:(R/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
else:assert json.loads((R/'manifest.json').read_text())==manifest,'Manifest drift'
print(json.dumps({'status':'PASS','states':len(states),'phone_and_lab_captures':len(expected),'browser_checks':len(report['checks']),'independent_rerender_checks':len(rerender['checks']),'files_excluding_manifest':len(paths),'raw_files_including_manifest':len(paths)+1,'bytes_excluding_manifest':manifest['total_bytes_excluding_self'],'min_text_contrast':min(m['ratio'] for m in measurements if m['minimum']==4.5)},indent=2))
