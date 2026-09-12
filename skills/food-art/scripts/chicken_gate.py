#!/usr/bin/env python3
"""Cheap chicken silhouette check before full-catalog export."""
import json
import subprocess
import time
from PIL import Image, ImageDraw, ImageFont
from ink_library import OUT, BASE, CONTROL, PAL, THEMES, compile_svg, dump, event, write


def run():
    event('chicken-gate-export-start')
    start = time.perf_counter()
    dest = OUT / 'evidence/chicken-gate'
    dest.mkdir(parents=True, exist_ok=True)
    for theme in THEMES:
        master = dest / f'chicken-{theme}.svg'
        write(master, compile_svg((OUT / 'sources/grilled-chicken.svg').read_text(), (OUT / 'wash-defs.svginc').read_text(), theme))
        for size in (64, 256):
            subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), '-o', str(dest / f'chicken-{theme}-{size}.png'), str(master)], check=True)
    export_seconds = time.perf_counter() - start
    start = time.perf_counter()
    book = ImageFont.truetype(str(BASE / 'fonts/EBGaramond[wght].ttf'), 26)
    mono = ImageFont.truetype(str(BASE / 'fonts/IBMPlexMono-Regular.ttf'), 13)
    im = Image.new('RGB', (1000, 760), PAL['paper'])
    d = ImageDraw.Draw(im)
    for row, theme in enumerate(THEMES):
        y = row * 380
        bg, fg = (PAL['paper'], PAL['dark']) if theme == 'paper' else (PAL['dark'], PAL['paper'])
        d.rectangle((0, y, 1000, y+380), fill=bg)
        d.text((24, y+12), f'{theme.upper()} / Grilled chicken / R1 control → silhouette correction', font=book, fill=fg)
        for col, label in enumerate(('BEFORE · R1 / bread ambiguity', 'AFTER · bone-in chicken silhouette')):
            x = col * 490 + 20
            d.text((x, y+53), label, font=mono, fill=fg)
            p = CONTROL / f'renders/grilled-chicken-{theme}-256.png' if col == 0 else dest / f'chicken-{theme}-256.png'
            a = Image.open(p)
            im.paste(a, (x, y+78), a)
            p = CONTROL / f'renders/grilled-chicken-{theme}-64.png' if col == 0 else dest / f'chicken-{theme}-64.png'
            for size, dx in ((64, 276), (40, 372)):
                a = Image.open(p).resize((size, size), Image.Resampling.LANCZOS)
                im.paste(a, (x+dx, y+144), a)
                d.text((x+dx, y+222), f'{size}px', font=mono, fill=fg)
            d.text((x, y+333), 'Grilled chicken · generic illustration', font=book, fill=fg)
    im.save(dest / 'comparison.png')
    result = {'export_seconds': export_seconds, 'proof_seconds': time.perf_counter()-start,
              'scope': 'Chicken gate only, excludes manual authoring and visual review', 'raw_exit': 0}
    dump(dest / 'timing.json', result)
    print(json.dumps(result, indent=2))

if __name__ == '__main__':
    run()
