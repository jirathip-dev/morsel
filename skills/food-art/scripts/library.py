#!/usr/bin/env python3
"""Offline ink/wash asset compiler. Run from any directory; no app writes."""
import argparse, hashlib, html, json, re, shutil, subprocess, time
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
ART = ROOT / 'docs/art/food-library'
PALETTE = {'paper':'#FFF7E8','cream':'#F2E9D9','sage':'#5E7E57','leaf':'#E1E9D7','forest':'#2F654B','orange':'#E66A2C','peach':'#FBE1C9','red':'#B94738','gold':'#D6A62C','ochre':'#A5750B','brown':'#655A4B','ink':'#8B7355'}
NIGHT = {**PALETTE, 'sage':'#E1E9D7','forest':'#5E7E57','red':'#FBE1C9','brown':'#E3D2BA','ink':'#9D917F'}
SIZES = (64,192,512)

def dump(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, ensure_ascii=False, indent=2) + '\n'
    if not path.exists() or path.read_text() != text: path.write_text(text)

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def valid(spec):
    assert re.fullmatch(r'[a-z][a-z0-9-]{2,63}',spec['id']), 'invalid stable ID'
    assert spec['kind'] in ('food','fallback')
    assert spec['category'] in ('grains','protein','produce','drinks','soup')
    assert spec['name'] and spec['aliases'] and spec['description']
    assert len(spec['layers']) >= 2
    for p in spec['layers']:
        assert set(p) <= {'d','fill','width','opacity'}, 'unknown layer field'
        assert re.fullmatch(r'[MmLlHhVvCcSsQqTtAaZz0-9., eE+\-]+',p['d']), 'unsafe path'
        assert p['fill'] in (*PALETTE,'none')
        assert 0 < p.get('width',1.1) <= 4
        assert 0 < p.get('opacity',1) <= 1

def svg(spec, theme):
    pal = PALETTE if theme == 'paper' else NIGHT
    defs = ['<pattern id="grain" width="37" height="43" patternUnits="userSpaceOnUse"><path d="M3 8l2 .5 M21 17l1 -.7 M11 32l3 .3 M30 39l2 -.5" stroke="'+pal['paper']+'" stroke-width=".7" opacity=".22"/><circle cx="28" cy="5" r=".5" fill="'+pal['brown']+'" opacity=".11"/></pattern>']
    for key, color in pal.items():
        defs.append(f'<radialGradient id="w-{key}" cx=".36" cy=".28" r=".78"><stop stop-color="{color}" stop-opacity=".42"/><stop offset=".67" stop-color="{color}" stop-opacity=".64"/><stop offset="1" stop-color="{color}" stop-opacity=".91"/></radialGradient>')
    body=[]
    for i,p in enumerate(spec['layers']):
        d=p['d']; ink=pal['ink']; fill=p['fill']; width=p.get('width',1.1)
        body.append(f'<g id="layer-{i}" opacity="{p.get("opacity",1)}">')
        if fill != 'none':
            # Opaque pale underpainting is confined to food; there is no tile or canvas fill.
            body.append(f'<path d="{d}" fill="{pal["paper"]}" fill-opacity=".68" stroke="none"/><path d="{d}" fill="url(#w-{fill})" stroke="none"/><path d="{d}" fill="url(#grain)" stroke="none"/>')
        body.append(f'<path d="{d}" fill="none" stroke="{ink}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/></g>')
    return '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 256 256" role="img"><title>'+html.escape(spec['name'])+' — generic illustration</title><desc>'+html.escape(spec['description'])+'</desc><defs>'+''.join(defs)+'</defs>'+''.join(body)+'</svg>\n'

def build():
    started=time.perf_counter(); ART.mkdir(parents=True,exist_ok=True)
    cache_path=ART/'build-cache.json'; cache=json.loads(cache_path.read_text()) if cache_path.exists() else {}
    engine=digest(Path(__file__)); renderer=subprocess.check_output(['rsvg-convert','--version'],text=True).strip()
    entries=[]; rebuilt=[]; skipped=[]
    for src in sorted((ART/'sources').glob('*.json')):
        spec=json.loads(src.read_text()); valid(spec); assert src.stem==spec['id']
        identity=hashlib.sha256((digest(src)+engine+renderer).encode()).hexdigest()
        paths=[f'masters/{spec["id"]}-{t}.svg' for t in ('paper','night')]+[f'exports/{spec["id"]}-{t}-{s}.png' for t in ('paper','night') for s in SIZES]
        old=cache.get(spec['id'],{})
        intact=old.get('identity')==identity and all((ART/p).is_file() and old.get('outputs',{}).get(p)==digest(ART/p) for p in paths)
        if not intact:
            for theme in ('paper','night'):
                master=ART/f'masters/{spec["id"]}-{theme}.svg'; master.parent.mkdir(exist_ok=True); master.write_text(svg(spec,theme)); ET.parse(master)
                for size in SIZES:
                    out=ART/f'exports/{spec["id"]}-{theme}-{size}.png'; out.parent.mkdir(exist_ok=True)
                    subprocess.run(['rsvg-convert','-w',str(size),'-h',str(size),'-o',str(out),str(master)],check=True,timeout=30)
            rebuilt.append(spec['id'])
        else: skipped.append(spec['id'])
        cache[spec['id']]={'identity':identity,'outputs':{p:digest(ART/p) for p in paths}}
        entries.append({k:spec[k] for k in ('id','name','aliases','category','kind','description')} | {'dimensions':[512,512],'viewBox':[0,0,256,256],'source':str(src.relative_to(ART)),'masters':paths[:2],'exports':paths[2:],'provenance':{'type':'original-agent-authored-vector','direction':'Morsel #90 approved V1','rights':'Original work for Morsel; no third-party food artwork','meaning':'Generic illustration; not a meal photo, portion or nutrition evidence'}})
    dump(cache_path,cache)
    dump(ART/'catalog.json',{'schema_version':1,'library_version':'1.1.0' if len(entries)>16 else '1.0.0','approval':'prototype-awaiting-owner-art-review','assets':entries})
    gallery(entries)
    result={'elapsed_seconds':round(time.perf_counter()-started,4),'rebuilt':rebuilt,'skipped':skipped,'count':len(entries),'renderer':renderer}
    print(json.dumps(result,indent=2)); return result

def gallery(entries):
    for name in ('Caveat[wght].ttf','EBGaramond[wght].ttf','IBMPlexMono-Regular.ttf','OFL-Caveat.txt','OFL-EBGaramond.txt','OFL-IBMPlexMono.txt'):
        dest=ART/'fonts'/name; dest.parent.mkdir(exist_ok=True)
        if not dest.exists(): shutil.copy2(ROOT/'app/Fonts'/name,dest)
    css='''@font-face{font-family:Hand;src:url("fonts/Caveat[wght].ttf")}@font-face{font-family:Book;src:url("fonts/EBGaramond[wght].ttf")}@font-face{font-family:Data;src:url("fonts/IBMPlexMono-Regular.ttf")}*{box-sizing:border-box}body{margin:0;background:#FFF7E8;color:#2A261F;font:19px/1.4 Book,serif}body.night{background:#2A261F;color:#FFF7E8}main{max-width:1080px;margin:auto;padding:32px 24px 64px;border-left:1px solid #8B7355}h1,h2{font-family:Hand;font-weight:400;line-height:1.05}h1{font-size:48px;margin:16px 0}h2{font-size:30px}p{max-width:640px}.eyebrow,small,.id{font:11px/1.6 Data,monospace}.controls{display:flex;flex-wrap:wrap;gap:12px;padding:16px 0;border-block:1px solid #8B7355}a,button{color:inherit}button,a.control{font:17px Book;background:none;border:1px solid #8B7355;min-height:44px;padding:8px 16px;text-decoration:none}button:focus-visible,a:focus-visible{outline:3px solid #E66A2C;outline-offset:3px}button:hover,a.control:hover{background:#8B735522}.sheet{display:grid;grid-template-columns:repeat(4,1fr);gap:0 22px}.specimen{margin:0;padding:24px 0 18px;border-bottom:1px solid #8B7355}.specimen .art{width:100%;height:150px;object-fit:contain}.specimen h2{font:23px Book;margin:0}.sizes{display:flex;align-items:center;gap:8px;height:70px}.sizes img{width:64px;height:64px}.sizes .tiny{width:40px;height:40px}.id{overflow-wrap:anywhere}.fallback{font-style:italic}.phone main{max-width:390px;padding:24px 20px 28px 36px;min-height:844px;margin:0;border-left:1px solid #8B7355}.phone h1{font-size:38px}.meal{display:grid;grid-template-columns:64px 1fr;gap:14px;align-items:center;border-bottom:1px solid #8B7355;padding:20px 0}.meal img{width:64px;height:64px}.meal h2{font:23px Book;margin:0}.meal p{margin:3px 0;font-size:16px}.note{font:24px Hand;margin:24px 0}.phone .notice{font-size:16px;border-block:1px solid #8B7355;padding:14px 0}.phone footer{font-size:16px;margin-top:24px}@media(max-width:600px){.sheet{grid-template-columns:repeat(2,1fr);gap:0 16px}main{padding:24px 16px}.specimen .art{height:130px}h1{font-size:40px}}'''
    (ART/'gallery.css').write_text(css)
    for theme in ('paper','night'):
        figures=''
        for e in entries:
            prefix=f'exports/{e["id"]}-{theme}'
            figures+=f'<figure class="specimen"><img class="art" src="{prefix}-192.png" alt="{html.escape(e["description"])}"><figcaption><h2>{html.escape(e["name"])}</h2><div class="id">{e["id"]}</div><div class="sizes"><img src="{prefix}-64.png" alt="64 pixel preview"><img class="tiny" src="{prefix}-64.png" alt="40 pixel preview"><small>64 / 40 px</small></div><small>{e["category"]} · {e["kind"]}</small><br><a href="masters/{e["id"]}-{theme}.svg">Editable SVG</a> · <a href="{prefix}-512.png">PNG</a></figcaption></figure>'
        other='night' if theme=='paper' else 'paper'
        body=f'<main><div class="eyebrow">MORSEL / FOOD STUDIES / V1 DIRECTION</div><h1>A small pantry, in ink & wash</h1><p>Original food illustrations for the field journal. Generic illustrations—not meal photos, portion sizes or nutrition evidence. Artwork awaits Guy’s review.</p><nav class="controls"><a class="control" href="gallery-{other}.html">View {other}</a><a class="control" href="phone-{theme}.html">Phone context</a><a class="control" href="comparison.html">Approved V1 comparison</a><a class="control" href="catalog.json">Catalog</a></nav><p class="eyebrow">{len(entries)} STUDIES · {sum(e["kind"]=="food" for e in entries)} FOODS / {sum(e["kind"]=="fallback" for e in entries)} FALLBACKS · {theme.upper()}</p><section class="sheet">{figures}</section><p>PROTOTYPE — awaiting Guy approval. No app integration.</p></main>'
        page(ART/f'gallery-{theme}.html',body,theme)
        rows=''
        chosen=['jasmine-rice','grilled-chicken','mango','coffee']
        for id in chosen:
            e=next(e for e in entries if e['id']==id)
            rows+=f'<section class="meal"><img src="exports/{id}-{theme}-64.png" alt="Generic {e["name"]} illustration"><div><h2>{e["name"]}</h2><p>Illustration · no meal photo</p><small>PORTION NOT REPRESENTED</small></div></section>'
        body='<main><div class="eyebrow">MORSEL / ART REVIEW</div><h1>In the meal journal</h1><p class="notice">Fictional layout fixture · not deployed UI.<br>Illustrations identify food only. No nutrition or portion is implied.</p>'+rows+'<p class="note">A drawing, never a substitute for your photo.</p><footer>Real meal photographs stay photographs.<br><a href="gallery-'+theme+'.html">Back to food studies</a></footer></main>'
        page(ART/f'phone-{theme}.html',body,theme+' phone')
    page(ART/'index.html','<main><h1>Morsel food studies</h1><p>PROTOTYPE — awaiting Guy approval.</p><nav class="controls"><a class="control" href="gallery-paper.html">Paper gallery</a><a class="control" href="gallery-night.html">Night ink gallery</a><a class="control" href="comparison.html">Approved reference comparison</a></nav><p>Generic illustrations, not meal photos or nutrition evidence.</p></main>','paper')

def page(path,body,cls):
    audit='''<script>addEventListener('load',async()=>{await document.fonts.ready;console.log('FOOD_QA='+JSON.stringify({title:document.title,viewport:[innerWidth,innerHeight],overflow:document.documentElement.scrollWidth>innerWidth,images:[...document.images].every(i=>i.complete&&i.naturalWidth>0),fonts:document.fonts.check('19px Book')&&document.fonts.check('38px Hand'),links:[...document.links].map(a=>a.getAttribute('href'))}));});</script>'''
    path.write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Morsel · Food studies</title><link rel="stylesheet" href="gallery.css"></head><body class="'+cls+'">'+body+audit+'</body></html>\n')

def main():
    parser=argparse.ArgumentParser(); sub=parser.add_subparsers(dest='command',required=True)
    sub.add_parser('build'); add=sub.add_parser('add'); add.add_argument('spec',type=Path)
    args=parser.parse_args()
    if args.command=='add':
        spec=json.loads(args.spec.read_text()); valid(spec); dest=ART/'sources'/f'{spec["id"]}.json'
        assert not dest.exists(), 'ID already exists; edit existing source, then build'
        dump(dest,spec)
    build()
    from proofs import run
    run()
    from verify import verify
    print(json.dumps(verify(),indent=2))
if __name__=='__main__': main()
