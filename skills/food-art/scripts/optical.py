#!/usr/bin/env python3
"""All catalog entries at exact 64px and 40px display widths, both themes."""
from PIL import Image, ImageDraw, ImageFont
import json
from library import ART
entries=json.loads((ART/'catalog.json').read_text())['assets']
rows=(len(entries)+2)//3;panel=80+rows*110
sheet=Image.new('RGB',(1080,panel*2));font=ImageFont.truetype(str(ART/'fonts/EBGaramond[wght].ttf'),19)
for k,theme in enumerate(('paper','night')):
    bg='#FFF7E8' if k==0 else '#2A261F';ink='#2A261F' if k==0 else '#FFF7E8';d=ImageDraw.Draw(sheet);d.rectangle((0,k*panel,1080,(k+1)*panel),fill=bg)
    d.text((24,k*panel+18),theme.upper()+' / exact 64px and 40px studies / illustrations, not meal photographs',font=font,fill=ink)
    for i,a in enumerate(entries):
        x=24+(i%3)*352;y=k*panel+64+(i//3)*110
        im=Image.open(ART/f'exports/{a["id"]}-{theme}-64.png');sheet.paste(im,(x,y),im);small=im.resize((40,40),Image.Resampling.LANCZOS);sheet.paste(small,(x+75,y+12),small)
        d.text((x+130,y+20),a['name'],font=font,fill=ink)
sheet.save(ART/'proofs/optical-both.png')
print(f'All {len(entries)} entries at exact 64px and 40px in both themes')
