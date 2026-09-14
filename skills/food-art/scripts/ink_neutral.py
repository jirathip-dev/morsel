#!/usr/bin/env python3
"""Issue 223: offline bundle, two fresh renders, identity gates and optical proof."""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from ink_library import ROOT, OUT, THEMES, SIZES, NEUTRAL_ID, digest, dump, verify, require, subjects


def run(bundle=False):
    verify()
    target = ROOT / 'app/Resources/FoodArt'
    if bundle:
        for theme in THEMES:
            name = f'{NEUTRAL_ID}-{theme}-64.png'
            shutil.copy2(OUT / 'exports' / name, target / name)
        shutil.copy2(OUT / 'catalog.json', target / 'catalog.json')
    catalog = json.loads((target / 'catalog.json').read_text())
    require(digest(target / 'catalog.json') == digest(OUT / 'catalog.json'), 'catalog copies differ')
    neutral = [a for a in catalog['assets'] if a['id'] == NEUTRAL_ID]
    require(len(catalog['assets']) == 18 and len(neutral) == 1, 'bundled catalog count')
    require(neutral[0]['kind'] == 'fallback' and neutral[0]['category'] == 'neutral', 'neutral identity')
    require((OUT / 'sources/fallback-neutral.svg').read_bytes() == (ROOT / 'skills/food-art/templates/ink-neutral.svg').read_bytes(), 'template/source drift')
    baseline = json.loads((OUT / 'evidence/neutral-baseline.json').read_text())
    for rel, sha in baseline['sha256'].items():
        require(digest(ROOT / rel) == sha, 'original art bytes changed: ' + rel)
    renders, copies = {}, []
    with tempfile.TemporaryDirectory(prefix='morsel-neutral-') as td:
        for theme in THEMES:
            for size in SIZES:
                name = f'{NEUTRAL_ID}-{theme}-{size}.png'
                hashes = []
                for attempt in (1, 2):
                    fresh = Path(td) / f'{attempt}-{name}'
                    result = subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), '-o', str(fresh), str(OUT / f'masters/{NEUTRAL_ID}-{theme}.svg')], check=True, timeout=45)
                    hashes.append(digest(fresh))
                committed = digest(OUT / 'exports' / name)
                require(hashes[0] == hashes[1] == committed, 'fresh render differs: ' + name)
                renders[name] = {'first': hashes[0], 'second': hashes[1], 'export': committed, 'raw_exit': result.returncode}
                if size == 64:
                    bundled = digest(target / name)
                    require(committed == bundled, 'bundled PNG differs: ' + name)
                    copies.append({'export': 'docs/art/food-library-v2/exports/' + name, 'export_sha256': committed, 'bundle': 'app/Resources/FoodArt/' + name, 'bundle_sha256': bundled})
        # Exact-set and neutral identity rejection probes in an isolated fixture.
        fixture = Path(td) / 'fixture'
        shutil.copytree(OUT / 'sources', fixture / 'sources')
        data = json.loads((OUT / 'subjects.json').read_text())
        changed = json.loads(json.dumps(data))
        next(a for a in changed['assets'] if a['id'] == NEUTRAL_ID)['kind'] = 'food'
        dump(fixture / 'subjects.json', changed)
        try:
            subjects(fixture)
        except ValueError as error:
            require('neutral identity' in str(error), 'wrong rejection boundary')
            kind_rejection = str(error)
        else:
            raise AssertionError('neutral food-kind mutation accepted')
        data['assets'] = [a for a in data['assets'] if a['id'] != NEUTRAL_ID]
        dump(fixture / 'subjects.json', data)
        (fixture / 'sources/fallback-neutral.svg').unlink()
        try:
            verify(fixture)
        except ValueError as error:
            require('issue-223 release' in str(error), 'wrong missing-neutral rejection boundary')
            missing_rejection = str(error)
        else:
            raise AssertionError('missing neutral accepted')
    # Native 64px, nearest-neighbor enlargement, 192px; labeled comparison.
    proof = Image.new('RGB', (1000, 550))
    font = ImageFont.truetype(str(OUT / 'fonts/EBGaramond[wght].ttf'), 24)
    mono = ImageFont.truetype(str(OUT / 'fonts/IBMPlexMono-Regular.ttf'), 12)
    d = ImageDraw.Draw(proof)
    for col, theme in enumerate(THEMES):
        x = col * 500
        bg, fg = ('#FFF7E8', '#2A261F') if theme == 'paper' else ('#2A261F', '#FFF7E8')
        d.rectangle((x, 0, x + 499, 549), fill=bg)
        d.text((x+22, 15), f'{theme.title()} / Food · fallback', font=font, fill=fg)
        d.text((x+22, 49), 'NEUTRAL EATING SIGN / NOT IDENTIFIED FOOD', font=mono, fill=fg)
        small = Image.open(OUT / f'exports/{NEUTRAL_ID}-{theme}-64.png')
        large = Image.open(OUT / f'exports/{NEUTRAL_ID}-{theme}-192.png')
        proof.paste(small, (x+24, 95), small)
        enlarged = small.resize((192, 192), Image.Resampling.NEAREST)
        proof.paste(enlarged, (x+110, 78), enlarged)
        proof.paste(large, (x+298, 78), large)
        d.text((x+24, 278), '64px      64px enlarged       192px', font=mono, fill=fg)
        d.text((x+22, 327), 'Approved-family controls / native 64px', font=font, fill=fg)
        for i, id in enumerate(('coffee', 'fallback-grains', 'fallback-protein')):
            im = Image.open(OUT / f'exports/{id}-{theme}-64.png')
            proof.paste(im, (x+25+i*155, 376), im)
            d.text((x+22+i*155, 455), id.removeprefix('fallback-'), font=mono, fill=fg)
        d.text((x+22, 503), 'Category art keeps its category label.', font=mono, fill=fg)
    proof.save(OUT / 'neutral-both.png')
    report = {'status': 'PASS', 'raw_exit': 0, 'catalog_total': len(catalog['assets']), 'catalog_entry': neutral[0], 'determinism': renders, 'byte_identity': copies, 'baseline_files_unchanged': len(baseline['sha256']), 'negative_probes': {'neutral_kind_food_rejected': kind_rejection, 'missing_neutral_rejected': missing_rejection}, 'scope': 'Asset bytes/catalog only; no Swift build or runtime integration claim.'}
    dump(OUT / 'evidence/neutral-verification.json', report)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--bundle', action='store_true', help='Copy neutral 64px PNGs and catalog into the app resources')
    run(ap.parse_args().bundle)
