#!/usr/bin/env python3
"""Bounded four-subject art gate; never writes the library or its catalog."""
import argparse, hashlib, html, json, re, shutil, subprocess, time
from pathlib import Path
from xml.etree import ElementTree as ET
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[3]
BASE=ROOT/'docs/art/food-library'
OUT=ROOT/'docs/art/food-refinement-197-r1'
IDS=('mango','grilled-chicken','stir-fried-noodles','coffee')
NAMES=dict(zip(IDS,('Mango','Grilled chicken','Stir-fried noodles','Coffee')))
PAL={'paper':'#FFF7E8','cream':'#F2E9D9','sage':'#5E7E57','leaf':'#E1E9D7','forest':'#2F654B','orange':'#E66A2C','peach':'#FBE1C9','red':'#B94738','gold':'#D6A62C','ochre':'#A5750B','brown':'#655A4B','ink':'#8B7355','dark':'#2A261F'}

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,data):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(data,indent=2)+'\n')
def now():return time.time_ns()
def event(phase):
    p=OUT/'timing-events.json';data=json.loads(p.read_text()) if p.exists() else []
    data.append({'phase':phase,'wall_ns':now(),'monotonic_ns':time.monotonic_ns()});save(p,data);print(phase)
def control():
    p=OUT/'control-state.json';assert not p.exists(),'Control already fixed; do not overwrite'
    paths=[p for p in BASE.rglob('*') if p.is_file()]+[p for p in (ROOT/'skills/food-art/scripts').glob('*.py') if p.name!='sample_gate.py']
    save(p,{'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'protected':{str(p.relative_to(ROOT)):{'sha256':sha(p),'mtime_ns':p.stat().st_mtime_ns} for p in paths}})
    (OUT/'control').mkdir(exist_ok=True);shutil.copy2(ROOT/'skills/food-art/SKILL.md',OUT/'control/food-art-SKILL.md')
    for subject in IDS:
        for theme in ('paper','night'):
            for size in (64,512):shutil.copy2(BASE/f'exports/{subject}-{theme}-{size}.png',OUT/f'control/{subject}-{theme}-{size}.png')
    event('authoring-start')

def render():
    start=time.perf_counter();event('export-start');(OUT/'renders').mkdir(exist_ok=True)
    assert {p.stem for p in (OUT/'sources').glob('*.svg')}==set(IDS)
    defs=(OUT/'wash-defs.svginc').read_text()
    for subject in IDS:
        source=(OUT/f'sources/{subject}.svg').read_text()
        for theme in ('paper','night'):
            palette={**PAL,'line':PAL['ink'] if theme=='paper' else '#9D917F','ground':PAL['paper'] if theme=='paper' else PAL['dark']}
            body=source.replace('<!-- WASH_DEFS -->',defs)
            for key,color in palette.items():body=body.replace('{{'+key+'}}',color)
            assert '{{' not in body
            ET.fromstring(body)
            master=OUT/f'renders/{subject}-{theme}.svg';master.write_text(body)
            for size in (64,256):
                subprocess.run(['rsvg-convert','-w',str(size),'-h',str(size),'-o',str(OUT/f'renders/{subject}-{theme}-{size}.png'),str(master)],check=True,timeout=30)
    event('export-end');save(OUT/'export-timing.json',{'seconds':time.perf_counter()-start,'subjects':list(IDS),'png_count':16,'sizes':[64,256],'command':'PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/sample_gate.py render','scope':'Export only; authoring, review and proof composition separate.'})
    proofs()

def proofs():
    start=time.perf_counter();event('proofs-start')
    book=ImageFont.truetype(str(BASE/'fonts/EBGaramond[wght].ttf'),26)
    hand=ImageFont.truetype(str(BASE/'fonts/Caveat[wght].ttf'),44)
    mono=ImageFont.truetype(str(BASE/'fonts/IBMPlexMono-Regular.ttf'),13)
    for theme in ('paper','night'):
        bg=PAL['paper'] if theme=='paper' else PAL['dark'];ink=PAL['dark'] if theme=='paper' else PAL['paper']
        im=Image.new('RGB',(1000,1320),bg);d=ImageDraw.Draw(im)
        d.text((28,15),'Four food studies / direction gate',font=hand,fill=ink)
        d.text((28,72),theme.upper()+' / FIRST DELIVERY IS CONTROL, NOT APPROVED ART',font=mono,fill=ink)
        d.text((30,106),'BEFORE · first delivery',font=book,fill=ink);d.text((510,106),'AFTER · one revised treatment',font=book,fill=ink)
        for i,subject in enumerate(IDS):
            y=153+i*285
            for col,version in enumerate(('before','after')):
                x=col*480+28
                path=OUT/(f'control/{subject}-{theme}-512.png' if version=='before' else f'renders/{subject}-{theme}-256.png')
                a=Image.open(path).resize((256,256),Image.Resampling.LANCZOS);im.paste(a,(x,y-17),a)
                for size,dx in ((64,285),(40,374)):
                    path=OUT/(f'control/{subject}-{theme}-64.png' if version=='before' else f'renders/{subject}-{theme}-64.png')
                    a=Image.open(path).resize((size,size),Image.Resampling.LANCZOS);im.paste(a,(x+dx,y+58),a)
                    d.text((x+dx,y+130),str(size)+'px',font=mono,fill=ink)
                d.text((x+10,y+224),NAMES[subject],font=book,fill=ink)
                d.line((x,y+264,x+438,y+264),fill=PAL['ink'],width=1)
        d.text((28,1290),'GENERIC ILLUSTRATIONS / NOT PHOTOS, PORTIONS OR NUTRITION EVIDENCE',font=mono,fill=ink)
        im.save(OUT/f'comparison-{theme}.png')
    css='''@font-face{font-family:Hand;src:url('../food-library/fonts/Caveat[wght].ttf')}@font-face{font-family:Book;src:url('../food-library/fonts/EBGaramond[wght].ttf')}@font-face{font-family:Data;src:url('../food-library/fonts/IBMPlexMono-Regular.ttf')}*{box-sizing:border-box}body{margin:0;background:#FFF7E8;color:#2A261F;font:18px/1.35 Book,serif}body.night{background:#2A261F;color:#FFF7E8}main{max-width:1060px;padding:24px;margin:auto}h1{font:40px/1.05 Hand;margin:12px 0}h2{font:24px Book}small{font:11px Data}a{color:inherit}nav{display:flex;gap:12px;flex-wrap:wrap}nav a{padding:10px 12px;border:1px solid #8B7355;min-height:44px}a:focus-visible{outline:3px solid #E66A2C}img.sheet{width:100%;height:auto}.phone main{max-width:390px;margin:0;padding:20px 22px 28px 34px;border-left:1px solid #8B7355}.row{display:grid;grid-template-columns:64px 1fr;gap:12px;align-items:center;padding:15px 0;border-bottom:1px solid #8B7355}.row img{width:64px;height:64px}.row h2{margin:0}.row p{margin:4px 0;font-size:16px}.notice{font-size:16px;padding:12px 0;border-block:1px solid #8B7355}footer{font-size:16px;margin-top:20px}'''
    (OUT/'sample.css').write_text(css)
    def page(name,body,cls):
        (OUT/name).write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Morsel four-food sample review</title><link rel="stylesheet" href="sample.css"><body class="'+cls+'"><main>'+body+'</main></body></html>')
    for theme in ('paper','night'):
        for version in ('before','after'):
            rows=''
            for subject in IDS:
                src=f'control/{subject}-{theme}-64.png' if version=='before' else f'renders/{subject}-{theme}-64.png'
                rows+=f'<section class="row"><img src="{src}" alt="Generic {NAMES[subject]} illustration"><div><h2>{NAMES[subject]}</h2><p>Illustration · not a meal photo</p><small>PORTION NOT REPRESENTED</small></div></section>'
            page(f'phone-{version}-{theme}.html',f'<small>{theme.upper()} / {version.upper()} / SAMPLE GATE</small><h1>In the meal journal</h1><p class="notice">Fictional art fixture · not deployed UI.<br>One treatment per subject. Awaiting approval.</p>'+rows+'<footer>No photo or nutrition evidence is implied.<br><a href="index.html">Back to comparison</a></footer>',theme+' phone')
    page('index.html','<small>MORSEL / ISSUE 197 / LOCAL SAMPLE REVIEW</small><h1>From icons toward ink & wash</h1><p>Exactly four subjects. First delivery retained as control, not approved artwork. Revised samples await owner review; these are digitally authored studies, not physical watercolor scans.</p><nav>'+''.join(f'<a href="phone-{v}-{t}.html">{v} · {t} phone</a>' for t in ('paper','night') for v in ('before','after'))+'</nav><h2>Paper</h2><img class="sheet" src="comparison-paper.png" alt="Four subject before and after comparison on Paper"><h2>Night ink</h2><img class="sheet" src="comparison-night.png" alt="Four subject before and after comparison on Night ink"><p>Generic illustrations—not meal photographs, portion sizes or nutrition evidence. STOP FOR SAMPLE APPROVAL.</p>','paper')
    event('proofs-end');save(OUT/'proof-timing.json',{'seconds':time.perf_counter()-start,'scope':'Comparison PNG and local HTML composition only; browser captures and review separate.'})

def verify():
    state=json.loads((OUT/'control-state.json').read_text());changed=[]
    for rel,v in state['protected'].items():
        p=ROOT/rel
        if not p.exists() or sha(p)!=v['sha256'] or p.stat().st_mtime_ns!=v['mtime_ns']:changed.append(rel)
    assert not changed,('control changed',changed)
    assert {p.stem for p in (OUT/'sources').glob('*.svg')}==set(IDS)
    for subject in IDS:
        for theme in ('paper','night'):
            master=OUT/f'renders/{subject}-{theme}.svg'
            text=master.read_text(); ET.fromstring(text)
            assert not re.search(r'<(?:script|image|foreignObject)\b|href=',text)
            assert set(re.findall(r'#[A-Fa-f0-9]{6}',text)) <= set(PAL.values())|{'#9D917F'}
            for size in (64,512):
                assert sha(OUT/f'control/{subject}-{theme}-{size}.png')==sha(BASE/f'exports/{subject}-{theme}-{size}.png')
            for size in (64,256):
                im=Image.open(OUT/f'renders/{subject}-{theme}-{size}.png');assert im.mode=='RGBA' and im.size==(size,size)
                box=im.getchannel('A').getbbox();assert box and min(box[0],box[1],size-box[2],size-box[3])>size*.06
    for theme in ('paper','night'):assert Image.open(OUT/f'comparison-{theme}.png').size==(1000,1320)
    for file in OUT.glob('*.html'):
        for path in re.findall(r'(?:href|src)="([^"]+)"',file.read_text()):assert (OUT/path).exists(),path
    report={'status':'PASS','subjects':list(IDS),'candidate_pngs':16,'candidate_svg_masters':8,'control_files_hash_and_mtime_unchanged':len(state['protected']),'catalog_unchanged':True,'raw_exit':0,'approval':'PENDING'}
    save(OUT/'verification.json',report);print(json.dumps(report,indent=2))

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('command',choices=['control','render','proofs','verify','event']);ap.add_argument('phase',nargs='?');args=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    if args.command=='event':event(args.phase)
    else:globals()[args.command]()
