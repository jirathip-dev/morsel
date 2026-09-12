#!/usr/bin/env python3
"""Deterministic labeled contact sheets and immutable approved-reference board."""
from library import ART, ROOT, page
from PIL import Image, ImageDraw, ImageFont
import json, shutil


def run():
    entries=json.loads((ART/'catalog.json').read_text())['assets']
    proofs=ART/'proofs'; proofs.mkdir(exist_ok=True)
    fonts=ART/'fonts'
    book=ImageFont.truetype(str(fonts/'EBGaramond[wght].ttf'),25)
    mono=ImageFont.truetype(str(fonts/'IBMPlexMono-Regular.ttf'),12)
    hand=ImageFont.truetype(str(fonts/'Caveat[wght].ttf'),52)
    for theme in ('paper','night'):
        bg='#FFF7E8' if theme=='paper' else '#2A261F'; ink='#2A261F' if theme=='paper' else '#FFF7E8'
        rows=(len(entries)+3)//4; im=Image.new('RGB',(1080,190+rows*265),bg); d=ImageDraw.Draw(im)
        d.text((30,18),'Morsel / food studies',font=hand,fill=ink)
        d.text((30,85),f'{theme.upper()} — ORIGINAL ART / APPROVED V1 DIRECTION / OWNER REVIEW PENDING',font=mono,fill=ink)
        d.text((30,113),'Generic illustrations, not meal photographs, portions or nutrition evidence.',font=book,fill=ink)
        for i,e in enumerate(entries):
            x=30+(i%4)*260;y=166+(i//4)*265
            art=Image.open(ART/f'exports/{e["id"]}-{theme}-192.png');im.paste(art,(x+25,y),art)
            d.text((x,y+182),e['name'],font=book,fill=ink)
            d.text((x,y+218),e['id'],font=mono,fill=ink)
            d.line((x,y+253,x+239,y+253),fill='#8B7355',width=1)
        im.save(proofs/f'contact-{theme}.png')
        src=ROOT/f'docs/evidence/issue-90/90-V1-today-default-{theme}.png'
        dest=ART/f'references/approved-v1-{theme}.png'; dest.parent.mkdir(exist_ok=True);shutil.copy2(src,dest)
    page(ART/'comparison.html','<main><div class="eyebrow">CONTROL / CANDIDATE — ART ONLY</div><h1>Alongside approved V1</h1><p>The original approved screenshots below are untouched. New food studies use the same restrained line-and-wash direction. Context previews are fictional art fixtures, not a UI redesign or deployment.</p><nav class="controls"><a class="control" href="gallery-paper.html">Paper art</a><a class="control" href="gallery-night.html">Night art</a></nav><section style="display:flex;flex-wrap:wrap;gap:24px"><figure style="margin:0"><h2>Approved V1 · Paper</h2><img style="width:100%;max-width:390px" src="references/approved-v1-paper.png" alt="Untouched approved Paper reference"></figure><figure style="margin:0"><h2>Approved V1 · Night ink</h2><img style="width:100%;max-width:390px" src="references/approved-v1-night.png" alt="Untouched approved Night reference"></figure></section><h2>Candidate contact sheets</h2><p><a href="proofs/optical-both.png">Every study at 64px and 40px · both themes</a></p><a href="proofs/contact-paper.png">Paper full contact sheet</a> · <a href="proofs/contact-night.png">Night full contact sheet</a><p>PROTOTYPE — awaiting Guy approval.</p></main>','paper')
    import runpy
    runpy.run_path(str(ROOT/'skills/food-art/scripts/optical.py'),run_name='__main__')
    print('Contact sheets and approved-reference comparison refreshed')
if __name__=='__main__':run()
