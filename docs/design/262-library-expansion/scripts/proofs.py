#!/usr/bin/env python3
"""Deterministic contact, native-size, and labeled phone-context proofs."""
import argparse
import html
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from pipeline import ROOT, LIB, read, save, entries, COUNTS

CSS = '''@font-face{font-family:Hand;src:url('../library/fonts/Caveat[wght].ttf')}@font-face{font-family:Book;src:url('../library/fonts/EBGaramond[wght].ttf')}@font-face{font-family:Data;src:url('../library/fonts/IBMPlexMono-Regular.ttf')}*{box-sizing:border-box}body{margin:0;background:#FFF7E8;color:#2A261F;font:19px/1.35 Book,serif}body.night{background:#2A261F;color:#FFF7E8}main{max-width:1240px;margin:auto;padding:24px}h1{font:42px/1.05 Hand;margin:12px 0}h2{font:25px/1.15 Book;margin:4px 0}p{max-width:750px}.eyebrow,small{font:11px/1.5 Data,monospace}nav{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0}a{color:inherit}nav a,a.back{display:inline-flex;align-items:center;min-width:44px;min-height:44px;padding:8px 12px;border:1px solid #8B7355;text-decoration:none}a:focus-visible{outline:3px solid #E66A2C;outline-offset:3px}a:hover{background:#8B735522}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:0 20px}.study{padding:16px 0;border-bottom:1px solid #8B7355}.large{width:192px;height:192px;max-width:100%;object-fit:contain}.native{display:flex;gap:12px;align-items:center;height:76px}.native img{width:64px;height:64px}.native img.tiny{width:40px;height:40px}.phone main{max-width:390px;margin:0;padding:18px 22px 18px 30px;border-left:1px solid #8B7355}.phone h1{font-size:34px}.phone .notice{font-size:16px;margin:12px 0;border-block:1px solid #8B7355;padding:8px 0}.row{display:grid;grid-template-columns:64px minmax(0,1fr);gap:12px;align-items:center;padding:10px 0;min-height:86px;border-bottom:1px solid #8B7355}.row img{width:64px;height:64px}.row h2{font-size:22px}.row p{font-size:15px;margin:3px 0}.phone footer{font-size:15px;margin-top:14px}.sheet{max-width:100%;height:auto}.links{display:flex;gap:8px;flex-wrap:wrap}.links a{min-height:44px;min-width:44px;padding-inline:8px;display:inline-flex;align-items:center}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:0 14px}main{padding:20px}.study h2{font-size:21px}}'''
AUDIT = '''<script>addEventListener('load',async()=>{await document.fonts.ready;console.log('INK_QA='+JSON.stringify({viewport:[innerWidth,innerHeight],overflow:document.documentElement.scrollWidth>innerWidth,images:[...document.images].every(i=>i.complete&&i.naturalWidth>0),fonts:document.fonts.check('19px Book')&&document.fonts.check('34px Hand')&&document.fonts.check('11px Data'),ids:[...document.querySelectorAll('[data-id]')].map(e=>e.dataset.id),imageSizes:[...document.querySelectorAll('.row img')].map(e=>[e.getBoundingClientRect().width,e.getBoundingClientRect().height]),allRowsVisible:[...document.querySelectorAll('.row')].every(e=>{let r=e.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight}),minHitWidth:Math.min(...[...document.links].map(e=>e.getBoundingClientRect().width)),minHitHeight:Math.min(...[...document.links].map(e=>e.getBoundingClientRect().height)),links:[...document.links].map(a=>a.getAttribute('href'))}));});</script>'''


def page(path, body, theme='paper', phone=False):
    path.write_text(f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Morsel • Issue 262 • Candidate studies</title><link rel="stylesheet" href="proof.css"></head><body class="{theme}{" phone" if phone else ""}"><main>{body}</main>{AUDIT}</body></html>\n')


def art(im, iid, theme, size, x, y):
    source = Image.open(LIB / f'exports/{iid}-{theme}-{64 if size <= 64 else 192}.png')
    if source.size != (size,size):
        source = source.resize((size,size), Image.Resampling.LANCZOS)
    im.paste(source,(x,y),source)


def run(batch):
    assets = entries(batch)
    dest = ROOT / f'batch-{batch}'
    (dest / 'proof.css').write_text(CSS)
    fonts = LIB / 'fonts'
    hand = ImageFont.truetype(str(fonts / 'Caveat[wght].ttf'),44)
    book = ImageFont.truetype(str(fonts / 'EBGaramond[wght].ttf'),26)
    mono = ImageFont.truetype(str(fonts / 'IBMPlexMono-Regular.ttf'),11)
    cohorts = {f'{i//5+1:02}':[a['id'] for a in assets[i:i+5]] for i in range(0,len(assets),5)}
    colors={'paper':('#FFF7E8','#2A261F'),'night':('#2A261F','#FFF7E8')}
    for theme,(bg,fg) in colors.items():
        rows=math.ceil(len(assets)/4)
        im=Image.new('RGB',(1200,rows*270+140),bg)
        d=ImageDraw.Draw(im)
        d.text((24,10),f'An expanded pantry / batch {batch}',font=hand,fill=fg)
        note=f'{theme.upper()} / {COUNTS[batch]} NEW FOOD STUDIES' + (' + 5 LABELED CATEGORY SIGNS' if batch==1 else '')
        d.text((24,65),note+' / PIXELS AWAIT OWNER REVIEW',font=mono,fill=fg)
        if batch==5:
            d.text((24,83),'GENERAL COVERAGE ONLY / EVIDENCE-FREE FOR THIS ACCOUNT / 0 OBSERVED ROWS',font=mono,fill=fg)
        for i,a in enumerate(assets):
            x,y=(i%4)*300+16,105+(i//4)*270
            art(im,a['id'],theme,192,x,y)
            art(im,a['id'],theme,64,x+212,y+26)
            art(im,a['id'],theme,40,x+224,y+114)
            d.text((x+207,y+181),'64 / 40 px',font=mono,fill=fg)
            d.text((x+4,y+201),a['name'],font=book,fill=fg)
            tag='CATEGORY ONLY / NOT IDENTIFIED FOOD' if a['kind']=='fallback' else a['category'].upper()+' / GENERIC LABELED STUDY'
            d.text((x+4,y+235),tag,font=mono,fill=fg)
            d.line((x+4,y+258,x+280,y+258),fill='#8B7355' if theme=='paper' else '#9D917F')
        d.text((24,im.height-24),'ORIGINAL DIGITAL INK/WASH / NOT PHOTOS, PORTIONS, INGREDIENT OR NUTRITION EVIDENCE',font=mono,fill=fg)
        im.save(dest/f'contact-{theme}.png')
        rows_html=''
        for a in assets:
            iid=a['id']
            rows_html+=f'<article class="study" data-id="{iid}"><img class="large" src="../library/exports/{iid}-{theme}-192.png" alt="{html.escape(a["description"])}"><h2>{html.escape(a["name"])}</h2><small>{iid}</small><div class="native"><img src="../library/exports/{iid}-{theme}-64.png" alt="64px review"><img class="tiny" src="../library/exports/{iid}-{theme}-64.png" alt="40px diagnostic"><small>64 / 40</small></div><small>{a["category"]} · {a["kind"]}</small><div class="links"><a href="../library/masters/{iid}-{theme}.svg">SVG</a><a href="../library/exports/{iid}-{theme}-512.png">512 PNG</a></div></article>'
        other='night' if theme=='paper' else 'paper'
        nav=f'<nav><a href="gallery-{other}.html">{other.title()}</a><a href="index.html">Batch overview</a>'+''.join(f'<a href="phone-{cohort}-{theme}.html">Phone {cohort}</a>' for cohort in cohorts)+'</nav>'
        page(dest/f'gallery-{theme}.html',f'<small>MORSEL / BATCH {batch} / DESIGN ARTIFACTS ONLY</small><h1>An expanded pantry</h1><p>Original ink/wash studies. Subject list approved; these pixels await owner review. Generic illustrations, not meal photographs or portion evidence.</p>'+nav+'<section class="grid">'+rows_html+'</section>',theme)
        by_id={a['id']:a for a in assets}
        for cohort,ids in cohorts.items():
            rows_html=''
            for iid in ids:
                a=by_id[iid]
                detail='Category only · not identified food' if a['kind']=='fallback' else 'Illustration · not a meal photo'
                rows_html+=f'<section class="row" data-id="{iid}"><img src="../library/exports/{iid}-{theme}-64.png" alt="{html.escape(a["name"])}"><div><h2>{html.escape(a["name"])}</h2><p>{detail}</p></div></section>'
            page(dest/f'phone-{cohort}-{theme}.html',f'<small>{theme.upper()} / BATCH {batch} / SHEET {cohort}</small><h1>In the food journal</h1><p class="notice">Fictional layout · not deployed UI.<br>Native 64px placement; portion not shown.</p>'+rows_html+f'<footer>{"General coverage; 0 observed rows." if batch==5 else "Artwork awaiting owner review."}<br><a class="back" href="gallery-{theme}.html">Back to batch</a></footer>',theme,True)
    # Separate all-ID native 64 / diagnostic 40 proof, in both locked themes.
    im=Image.new('RGB',(1000,100+len(assets)*88),'#FFF7E8')
    d=ImageDraw.Draw(im)
    for col,(theme,(bg,fg)) in enumerate(colors.items()):
        x=col*500
        d.rectangle((x,0,x+499,im.height-1),fill=bg)
        d.text((x+18,10),theme.title()+' / 64px + 40px diagnostic',font=book,fill=fg)
        for i,a in enumerate(assets):
            y=65+i*88
            art(im,a['id'],theme,64,x+16,y)
            art(im,a['id'],theme,40,x+96,y+12)
            d.text((x+152,y+5),a['name'],font=book,fill=fg)
            d.text((x+152,y+42),a['id'],font=mono,fill=fg)
            d.line((x+16,y+79,x+478,y+79),fill='#8B7355' if theme=='paper' else '#9D917F')
    im.save(dest/'optical-both.png')
    body=f'<small>MORSEL / ISSUE 262 / BATCH {batch}</small><h1>An expanded pantry</h1><p>{COUNTS[batch]} new food identities'+(' plus five labeled category fallbacks' if batch==1 else '')+'. Design artifacts only; not bundled. Final artwork approval remains with the owner.</p>'
    if batch==5:
        body+='<p>All 12 are evidence-free for this account: 0 observed rows. General coverage for other users, not observed demand.</p>'
    body+='<nav><a href="gallery-paper.html">Paper</a><a href="gallery-night.html">Night</a><a href="optical-both.png">64 / 40px</a><a href="BATCH-REPORT.md">Batch report</a><a href="catalog-delta.json">Catalog delta</a><a href="coverage.json">Coverage</a></nav>'
    for theme in colors:
        body+=f'<h2>{theme.title()} contact sheet</h2><img class="sheet" src="contact-{theme}.png" alt="All batch {batch} studies on {theme}">'
        body+=f'<h2>{theme.title()} / phone contexts</h2><nav>'+''.join(f'<a href="phone-{c}-{theme}.html">Sheet {c}</a>' for c in cohorts)+'</nav>'
    page(dest/'index.html',body)
    save(dest/'proof-layout.json',{'batch':batch,'cohorts':cohorts,'ids':[a['id'] for a in assets],'contact_size':[1200,math.ceil(len(assets)/4)*270+140],'phone_viewport':[390,844],'native_art_size':64,'diagnostic_size':40,'fonts':['EB Garamond','Caveat','IBM Plex Mono']})
    # Update simple cumulative review index; no hero/cards composition.
    current=[b for b in range(1,6) if (ROOT/f'batch-{b}/catalog-delta.json').exists()]
    css=CSS.replace('../library/','library/')
    (ROOT/'proof.css').write_text(css)
    body='<small>MORSEL / ISSUE 262 / DESIGN HANDOFF</small><h1>An expanded pantry, in ink & wash</h1><p>Additive studies in the locked art language. Shipped 18 entries remain byte-identical. No app, Swift, database or schema changes; no bundling or deployment. Pixels await owner review.</p><nav>'+''.join(f'<a href="batch-{b}/index.html">Batch {b} · {COUNTS[b]} foods</a>' for b in current)+'</nav><p><a class="back" href="README.md">Reproduction and handoff</a></p>'
    page(ROOT/'index.html',body)
    print(f'PASS composed batch {batch}: {len(assets)} IDs, {len(cohorts)*2} phone contexts')


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--batch',type=int,choices=range(1,6),required=True)
    run(ap.parse_args().batch)
