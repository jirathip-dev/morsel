#!/usr/bin/env python3
"""Deterministic full-set contact, native-size and phone proof composition."""
import html
import json
import shutil
import time
from PIL import Image, ImageDraw, ImageFont
from ink_library import OUT, BASE, THEMES, PAL, APPROVED, subjects, dump, write

COHORTS = {
    'journal': ['jasmine-rice', 'grilled-chicken', 'mango', 'coffee'],
    'produce': ['avocado', 'banana', 'broccoli', 'orange'],
    'meals': ['fried-egg', 'salmon', 'toast', 'vegetable-soup', 'stir-fried-noodles'],
    'fallbacks': ['fallback-drinks', 'fallback-grains', 'fallback-produce', 'fallback-protein'],
}
FONTS = ['Caveat[wght].ttf', 'EBGaramond[wght].ttf', 'IBMPlexMono-Regular.ttf',
         'OFL-Caveat.txt', 'OFL-EBGaramond.txt', 'OFL-IBMPlexMono.txt']
CSS = '''@font-face{font-family:Hand;src:url('fonts/Caveat[wght].ttf')}@font-face{font-family:Book;src:url('fonts/EBGaramond[wght].ttf')}@font-face{font-family:Data;src:url('fonts/IBMPlexMono-Regular.ttf')}*{box-sizing:border-box}body{margin:0;background:#FFF7E8;color:#2A261F;font:19px/1.35 Book,serif}body.night{background:#2A261F;color:#FFF7E8}main{max-width:1240px;margin:auto;padding:26px 24px 50px}h1{font:44px/1.05 Hand;margin:12px 0}h2{font:25px/1.2 Book;margin:6px 0}p{max-width:730px}.eyebrow,small{font:11px/1.5 Data,monospace}nav{display:flex;flex-wrap:wrap;gap:10px;margin:18px 0}a{color:inherit}nav a,a.back{display:inline-flex;align-items:center;min-height:44px;padding:8px 12px;border:1px solid #8B7355;text-decoration:none}a:focus-visible{outline:3px solid #E66A2C;outline-offset:3px}a:hover{background:#8B735522}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:0 22px}.study{padding:18px 0;border-bottom:1px solid #8B7355}.large{display:block;width:192px;height:192px;max-width:100%;object-fit:contain}.native{display:flex;gap:14px;align-items:center;height:76px}.native img{width:64px;height:64px}.native img.tiny{width:40px;height:40px}.phone main{max-width:390px;margin:0;padding:20px 22px 22px 32px;border-left:1px solid #8B7355}.phone h1{font-size:36px}.phone .notice{font-size:16px;margin:12px 0;border-block:1px solid #8B7355;padding:10px 0}.row{display:grid;grid-template-columns:64px minmax(0,1fr);gap:12px;align-items:center;padding:11px 0;min-height:86px;border-bottom:1px solid #8B7355}.row img{width:64px;height:64px}.row h2{font-size:22px}.row p{font-size:15px;margin:3px 0}.phone footer{font-size:15px;margin-top:15px}.sheet{max-width:100%;height:auto}.links{display:flex;gap:14px;flex-wrap:wrap}.links a{min-height:44px;min-width:44px;padding-inline:8px;display:inline-flex;align-items:center}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:0 16px}main{padding:20px}.study h2{font-size:22px}}'''
AUDIT = '''<script>addEventListener('load',async()=>{await document.fonts.ready;console.log('INK_QA='+JSON.stringify({title:document.title,viewport:[innerWidth,innerHeight],overflow:document.documentElement.scrollWidth>innerWidth,images:[...document.images].every(i=>i.complete&&i.naturalWidth>0),fonts:document.fonts.check('19px Book')&&document.fonts.check('36px Hand'),ids:[...document.querySelectorAll('[data-id]')].map(e=>e.dataset.id),imageSizes:[...document.querySelectorAll('.row img')].map(e=>[e.getBoundingClientRect().width,e.getBoundingClientRect().height]),allRowsVisible:[...document.querySelectorAll('.row')].every(e=>{let r=e.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight}),minHitWidth:Math.min(...[...document.links].map(e=>e.getBoundingClientRect().width)),minHitHeight:Math.min(...[...document.links].map(e=>e.getBoundingClientRect().height)),links:[...document.links].map(a=>a.getAttribute('href')),bodyHeight:document.body.scrollHeight}));});</script>'''


def page(path, body, theme, phone=False):
    title = 'Morsel · Refined food library'
    write(path, f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title><link rel="stylesheet" href="gallery.css"></head><body class="{theme}{" phone" if phone else ""}"><main>{body}</main>{AUDIT}</body></html>\n')


def run():
    start = time.perf_counter()
    entries = subjects()
    by_id = {a['id']: a for a in entries}
    for name in FONTS:
        target = OUT / 'fonts' / name
        target.parent.mkdir(exist_ok=True)
        if not target.exists():
            shutil.copy2(BASE / 'fonts' / name, target)
    book = ImageFont.truetype(str(OUT / 'fonts/EBGaramond[wght].ttf'), 26)
    hand = ImageFont.truetype(str(OUT / 'fonts/Caveat[wght].ttf'), 44)
    mono = ImageFont.truetype(str(OUT / 'fonts/IBMPlexMono-Regular.ttf'), 12)

    def art(im, id, theme, size, x, y):
        source_size = 64 if size <= 64 else 192
        a = Image.open(OUT / f'exports/{id}-{theme}-{source_size}.png')
        if a.size != (size, size):
            a = a.resize((size, size), Image.Resampling.LANCZOS)
        im.paste(a, (x, y), a)

    for theme in THEMES:
        bg, fg = (PAL['paper'], PAL['dark']) if theme == 'paper' else (PAL['dark'], PAL['paper'])
        im = Image.new('RGB', (1200, 1640), bg)
        d = ImageDraw.Draw(im)
        d.text((24, 14), 'A small pantry, in ink & wash', font=hand, fill=fg)
        d.text((24, 71), f'{theme.upper()} / 13 FOODS + 4 CATEGORY FALLBACKS / DIRECTION APPROVED; FULL SET FOR FLEET REVIEW', font=mono, fill=fg)
        for i, a in enumerate(entries):
            x, y = (i % 4)*300+16, 115+(i//4)*288
            art(im, a['id'], theme, 192, x, y)
            art(im, a['id'], theme, 64, x+211, y+39)
            art(im, a['id'], theme, 40, x+223, y+116)
            d.text((x+208, y+187), '64 / 40', font=mono, fill=fg)
            d.text((x+4, y+207), a['name'], font=book, fill=fg)
            tag = 'APPROVED R1 · UNCHANGED' if a['id'] in APPROVED else ('CORRECTED SILHOUETTE' if a['id']=='grilled-chicken' else ('CATEGORY FALLBACK' if a['kind']=='fallback' else 'EXTENDED TREATMENT'))
            d.text((x+4, y+242), tag, font=mono, fill=fg)
            d.line((x+4, y+273, x+280, y+273), fill=PAL['ink'])
        d.text((24, 1598), 'DIGITALLY AUTHORED GENERIC ILLUSTRATIONS / NOT PHOTOS, PORTIONS, INGREDIENT OR NUTRITION EVIDENCE', font=mono, fill=fg)
        im.save(OUT / f'contact-{theme}.png')

    im = Image.new('RGB', (1000, 1550), PAL['paper'])
    d = ImageDraw.Draw(im)
    for col, theme in enumerate(THEMES):
        x = col*500
        bg, fg = (PAL['paper'], PAL['dark']) if theme=='paper' else (PAL['dark'], PAL['paper'])
        d.rectangle((x, 0, x+499, 1549), fill=bg)
        d.text((x+20, 14), f'{theme.title()} · labeled optical checks', font=book, fill=fg)
        d.text((x+20, 49), 'NATIVE 64px + 40px / NO ZOOM CLAIM', font=mono, fill=fg)
        for i, a in enumerate(entries):
            y = 87+i*83
            art(im, a['id'], theme, 64, x+16, y)
            art(im, a['id'], theme, 40, x+97, y+12)
            d.text((x+158, y+8), a['name'], font=book, fill=fg)
            d.text((x+158, y+43), a['id'], font=mono, fill=fg)
            d.line((x+20, y+77, x+478, y+77), fill=PAL['ink'])
        d.text((x+20, 1520), 'Generic illustrations; labels remain required.', font=mono, fill=fg)
    im.save(OUT / 'optical-both.png')

    im = Image.new('RGB', (1000, 1200), PAL['paper'])
    d = ImageDraw.Draw(im)
    for col, theme in enumerate(THEMES):
        x=col*500
        bg, fg=(PAL['paper'], PAL['dark']) if theme=='paper' else (PAL['dark'], PAL['paper'])
        d.rectangle((x, 0, x+499, 1199), fill=bg)
        d.text((x+20, 18), f'{theme.title()} · category fallbacks', font=book, fill=fg)
        d.text((x+20, 58), 'CATEGORY ONLY / NOT IDENTIFIED FOOD', font=mono, fill=fg)
        for i, id in enumerate(COHORTS['fallbacks']):
            y=105+i*265
            art(im,id,theme,192,x+20,y)
            art(im,id,theme,64,x+266,y+55)
            art(im,id,theme,40,x+377,y+67)
            d.text((x+266,y+139),'64px',font=mono,fill=fg)
            d.text((x+377,y+139),'40px',font=mono,fill=fg)
            d.text((x+26,y+204),by_id[id]['name'],font=book,fill=fg)
            d.line((x+26,y+247,x+474,y+247),fill=PAL['ink'])
    im.save(OUT / 'fallbacks-both.png')
    write(OUT / 'gallery.css', CSS)
    for theme in THEMES:
        other = 'night' if theme == 'paper' else 'paper'
        nav = f'<nav><a href="gallery-{other}.html">View {other}</a>'+''.join(f'<a href="phone-{cohort}-{theme}.html">{cohort.title()} · phone</a>' for cohort in COHORTS)+'<a href="catalog.json">Catalog</a><a href="optical-both.png">64 / 40px proof</a></nav>'
        cards = ''
        for a in entries:
            id = a['id']
            cards += f'<article class="study" data-id="{id}"><img class="large" src="exports/{id}-{theme}-192.png" alt="{html.escape(a["description"])}"><h2>{html.escape(a["name"])}</h2><small>{id}</small><div class="native"><img src="exports/{id}-{theme}-64.png" alt="64 pixel study"><img class="tiny" src="exports/{id}-{theme}-64.png" alt="40 pixel study"><small>64 / 40</small></div><small>{a["category"]} · {a["kind"]}</small><div class="links"><a href="masters/{id}-{theme}.svg">SVG</a><a href="exports/{id}-{theme}-512.png">512 PNG</a></div></article>'
        page(OUT / f'gallery-{theme}.html', '<small>MORSEL / ISSUE 197 / REFINED LIBRARY</small><h1>A small pantry, in ink & wash</h1><p>Direction approved. Full-set extension for fleet review. Generic illustrations—not meal photographs, portions, ingredient or nutrition evidence. No app integration.</p>'+nav+'<section class="grid">'+cards+'</section>', theme)
        for cohort, ids in COHORTS.items():
            rows=''
            for id in ids:
                a=by_id[id]
                detail='Category fallback · not identified food' if a['kind']=='fallback' else 'Illustration · not a meal photo'
                rows+=f'<section class="row" data-id="{id}"><img src="exports/{id}-{theme}-64.png" alt="Generic {html.escape(a["name"])} illustration"><div><h2>{html.escape(a["name"])}</h2><p>{detail}</p></div></section>'
            page(OUT / f'phone-{cohort}-{theme}.html', f'<small>{theme.upper()} / {cohort.upper()} / ART FIXTURE</small><h1>In the food journal</h1><p class="notice">Fictional layout · not deployed UI.<br>Generic artwork; portion not represented.</p>'+rows+f'<footer>Real meal photographs stay photographs.<br><a class="back" href="gallery-{theme}.html">Back to library</a></footer>', theme, True)
    page(OUT / 'index.html', '<small>MORSEL / ISSUE 197 / FULL-SET DESIGN HANDOFF</small><h1>Refined food library</h1><p>13 foods and 4 category fallbacks. Approved mango, noodles and coffee preserved. Chicken silhouette corrected. The remaining catalog extends that direction; fleet review is pending.</p><nav><a href="gallery-paper.html">Paper gallery</a><a href="gallery-night.html">Night gallery</a><a href="fallbacks-both.png">Category fallbacks</a><a href="optical-both.png">Native 64 / 40px</a><a href="evidence/chicken-gate/comparison.png">Chicken correction</a><a href="README.md">Handoff and commands</a></nav><h2>Paper contact sheet</h2><img class="sheet" src="contact-paper.png" alt="All 17 food and fallback studies on Paper"><h2>Night contact sheet</h2><img class="sheet" src="contact-night.png" alt="All 17 food and fallback studies on Night"><p>Offline editable SVG sources and bundled transparent PNGs. Not meal photos, portion, ingredient or nutrition evidence. No app wiring.</p>', 'paper')
    result={'raw_exit':0,'seconds':time.perf_counter()-start,'scope':'Contact/native proof and HTML composition only; excludes exports, authoring, browser captures and review.', 'ids':[a['id'] for a in entries], 'phone_cohorts':COHORTS}
    dump(OUT / 'evidence/proofs.json',result)
    print(json.dumps(result,indent=2))

if __name__ == '__main__':
    run()
