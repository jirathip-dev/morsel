#!/usr/bin/env python3
"""Approved SVG ink/wash edition. Offline, incremental; never writes app assets.

Keeps the original JSON compiler and first delivery intact. Rich editable SVG
sources replace the old uniform-path layer vocabulary, not its cache contract.
"""
import argparse
import hashlib
import json
import re
import subprocess
import time
from pathlib import Path
from xml.etree import ElementTree as ET

from PIL import Image
from library import dump, digest
from sample_gate import PAL

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'docs/art/food-library-v2'
BASE = ROOT / 'docs/art/food-library'
CONTROL = ROOT / 'docs/art/food-refinement-197-r1'
THEMES = ('paper', 'night')
SIZES = (64, 192, 512)
APPROVED = ('mango', 'stir-fried-noodles', 'coffee')
APPROVAL = 'https://github.com/jirathip-dev/morsel/issues/197#issuecomment-5646485904'
TAGS = {'svg', 'title', 'desc', 'defs', 'g', 'path', 'circle', 'ellipse', 'line',
        'polyline', 'polygon', 'filter', 'feTurbulence', 'feDisplacementMap',
        'feColorMatrix', 'feComposite', 'clipPath'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def event(phase):
    p = OUT / 'evidence/timing-events.json'
    data = json.loads(p.read_text()) if p.exists() else []
    data.append({'phase': phase, 'wall_ns': time.time_ns(),
                 'monotonic_ns': time.monotonic_ns()})
    dump(p, data)


def subjects(out=OUT):
    values = json.loads((out / 'subjects.json').read_text())['assets']
    ids = [a['id'] for a in values]
    require(len(set(ids)) == len(ids), 'duplicate stable ID')
    for a in values:
        require(re.fullmatch(r'[a-z][a-z0-9-]{2,63}', a['id']), 'unsafe ID')
        require(a['kind'] in ('food', 'fallback'), 'invalid kind')
        require(a['category'] in ('produce', 'protein', 'grains', 'drinks', 'soup'), 'invalid category')
        require(all(isinstance(a[k], str) and a[k] for k in ('name', 'description')), 'missing metadata')
        require(isinstance(a['aliases'], list) and a['aliases'] and
                all(isinstance(s, str) and s for s in a['aliases']), 'missing aliases')
    require({p.stem for p in (out / 'sources').glob('*.svg')} == set(ids), 'source/catalog set mismatch')
    return sorted(values, key=lambda a: a['id'])


def compile_svg(source, defs, theme):
    require(theme in THEMES, 'unknown theme')
    require(source.count('<!-- WASH_DEFS -->') == 1, 'one shared wash insertion required')
    body = source.replace('<!-- WASH_DEFS -->', defs)
    palette = {**PAL, 'line': PAL['ink'] if theme == 'paper' else '#9D917F',
               'ground': PAL['paper'] if theme == 'paper' else PAL['dark']}
    for key, color in palette.items():
        body = body.replace('{{' + key + '}}', color)
    validate_svg(body)
    return body


def validate_svg(body):
    require('{{' not in body and '<!' not in re.sub(r'<!--.*?-->', '', body, flags=re.S), 'unresolved token or declaration')
    root = ET.fromstring(body)
    require(root.tag == '{http://www.w3.org/2000/svg}svg', 'not SVG')
    require(root.get('viewBox') == '0 0 256 256', 'invalid viewBox')
    require(root.get('width') == '256' and root.get('height') == '256', 'invalid master dimensions')
    require(set(re.findall(r'#[a-fA-F0-9]{6}\b', body)) <= set(PAL.values()) | {'#9D917F'}, 'unapproved palette')
    ids = [e.get('id') for e in root.iter() if e.get('id')]
    require(len(ids) == len(set(ids)), 'duplicate SVG identifier')
    for e in root.iter():
        tag = e.tag.rsplit('}', 1)[-1]
        require(tag in TAGS, 'unsafe SVG element: ' + tag)
        for key, value in e.attrib.items():
            require(not key.lower().startswith('on') and key not in ('style', 'href') and '}' not in key, 'unsafe SVG attribute')
            require(not re.search(r'(?i)https?:|data:|javascript:|file:', value), 'external SVG resource')
            for ref in re.findall(r'url\((.*?)\)', value):
                require(ref.startswith('#') and ref[1:] in ids, 'unresolved/local-only SVG reference')
        for key in ('fill', 'stroke'):
            value = e.get(key)
            if value:
                require(value in ('none', *PAL.values(), '#9D917F') or re.fullmatch(r'url\(#[\w-]+\)', value), 'unapproved paint')
    return root


def asset_paths(id):
    return [f'masters/{id}-{t}.svg' for t in THEMES] + [f'exports/{id}-{t}-{s}.png' for t in THEMES for s in SIZES]


def build(out=OUT):
    start = time.perf_counter()
    entries = subjects(out)
    renderer = subprocess.check_output(['rsvg-convert', '--version'], text=True).strip()
    deps = [Path(__file__), Path(__file__).with_name('library.py'), Path(__file__).with_name('sample_gate.py')]
    engine = ''.join(digest(p) for p in deps)
    defs = (out / 'wash-defs.svginc').read_text()
    cache_path = out / 'build-cache.json'
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    new_cache, catalog, rebuilt, skipped = {}, [], [], []
    render_seconds = 0.0
    for entry in entries:
        id = entry['id']
        src = out / f'sources/{id}.svg'
        identity = hashlib.sha256((digest(src) + defs + engine + renderer).encode()).hexdigest()
        paths = asset_paths(id)
        old = cache.get(id, {})
        intact = old.get('identity') == identity and all((out / p).is_file() and old.get('outputs', {}).get(p) == digest(out / p) for p in paths)
        # Always validate source, including on cache hits; cache is an optimization, not a trust boundary.
        bodies = {t: compile_svg(src.read_text(), defs, t) for t in THEMES}
        if not intact:
            for theme in THEMES:
                master = out / f'masters/{id}-{theme}.svg'
                write(master, bodies[theme])
                for size in SIZES:
                    target = out / f'exports/{id}-{theme}-{size}.png'
                    target.parent.mkdir(parents=True, exist_ok=True)
                    tick = time.perf_counter()
                    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), '-o', str(target), str(master)], check=True, timeout=45)
                    render_seconds += time.perf_counter() - tick
            rebuilt.append(id)
        else:
            skipped.append(id)
        new_cache[id] = {'identity': identity, 'outputs': {p: digest(out / p) for p in paths}}
        catalog.append({**entry, 'dimensions': [512, 512], 'master_dimensions': [256, 256],
                        'viewBox': [0, 0, 256, 256], 'source': f'sources/{id}.svg',
                        'masters': paths[:2], 'exports': paths[2:],
                        'provenance': {'type': 'original-agent-authored-svg-ink-wash',
                                       'direction_approval': APPROVAL,
                                       'rights': 'Original artwork for Morsel; no third-party food artwork',
                                       'meaning': 'Generic illustration; not a photo, portion, ingredient, cut, allergy or nutrition claim'}})
    dump(cache_path, new_cache)
    dump(out / 'catalog.json', {'schema_version': 2, 'library_version': '2.0.0',
                               'approval': 'direction-approved-full-set-awaiting-fleet-review',
                               'assets': catalog})
    result = {'raw_exit': 0, 'elapsed_seconds': round(time.perf_counter() - start, 6),
              'renderer_seconds': round(render_seconds, 6), 'renderer': renderer,
              'rebuilt': rebuilt, 'skipped': skipped, 'count': len(catalog),
              'scope': 'Compiler/cache/export only; excludes authoring, proof composition, captures and review.'}
    return result


def verify(out=OUT, allow_additions=False):
    entries = subjects(out)
    original = json.loads((BASE / 'catalog.json').read_text())['assets']
    original_by_id = {a['id']: a for a in original}
    current_ids = {a['id'] for a in entries}
    require(set(original_by_id) <= current_ids, 'existing stable ID removed')
    if not allow_additions:
        require(current_ids == set(original_by_id), 'issue-197 release is exactly the existing catalog')
        require(len(entries) == 17 and sum(a['kind'] == 'food' for a in entries) == 13, '17 entries / 13 foods required')
    catalog = json.loads((out / 'catalog.json').read_text())
    require(catalog['schema_version'] == 2 and catalog['library_version'] == '2.0.0', 'invalid catalog version')
    require(catalog['approval'] == 'direction-approved-full-set-awaiting-fleet-review', 'misleading approval state')
    require([a['id'] for a in catalog['assets']] == [a['id'] for a in entries], 'catalog/source parity')
    cache = json.loads((out / 'build-cache.json').read_text())
    expected = set()
    optical = []
    for a, published in zip(entries, catalog['assets']):
        id = a['id']
        if id in original_by_id:
            for key in ('id', 'name', 'aliases', 'category', 'kind'):
                require(a[key] == original_by_id[id][key], f'stable metadata changed: {id}/{key}')
        require(all(published[k] == a[k] for k in a), f'catalog metadata mismatch: {id}')
        require(published['source'] == f'sources/{id}.svg' and published['masters'] + published['exports'] == asset_paths(id), 'catalog path contract')
        require(published['dimensions'] == [512, 512] and published['master_dimensions'] == [256, 256] and published['viewBox'] == [0, 0, 256, 256], 'dimension metadata')
        require(published['provenance']['direction_approval'] == APPROVAL, 'missing provenance')
        for theme in THEMES:
            master = out / f'masters/{id}-{theme}.svg'
            body = compile_svg((out / f'sources/{id}.svg').read_text(), (out / 'wash-defs.svginc').read_text(), theme)
            require(master.read_text() == body, f'master does not reproduce source: {id}/{theme}')
            validate_svg(body)
            for size in SIZES:
                path = out / f'exports/{id}-{theme}-{size}.png'
                im = Image.open(path)
                require(im.mode == 'RGBA' and im.size == (size, size), f'RGBA dimensions: {path.name}')
                alpha = im.getchannel('A')
                box = alpha.getbbox()
                require(box and min(box[0], box[1], size-box[2], size-box[3]) >= size * .045, f'padding/clipping: {path.name}/{box}')
                require(all(alpha.getpixel(p) == 0 for p in ((0, 0), (size-1, 0), (0, size-1), (size-1, size-1))), 'opaque canvas')
                if size == 64:
                    require(sum(alpha.histogram()[65:]) > 140, f'too faint/nonblank: {path.name}')
                    optical.append({'id': id, 'theme': theme, 'alpha_bbox_64': list(box), 'alpha_gt64_pixels': sum(alpha.histogram()[65:])})
        for rel in asset_paths(id):
            require(cache[id]['outputs'][rel] == digest(out / rel), f'output checksum drift: {rel}')
            expected.add(rel)
    actual = {str(p.relative_to(out)) for d in ('masters', 'exports') for p in (out / d).iterdir() if p.is_file()}
    require(actual == expected, 'unexpected or missing export/master')
    lock = json.loads((out / 'evidence/control-lock.json').read_text())
    for rel, sha in lock['sha256'].items():
        require((ROOT / rel).is_file() and digest(ROOT / rel) == sha, 'historical control changed: ' + rel)
    for id in APPROVED:
        require(digest(out / f'sources/{id}.svg') == digest(CONTROL / f'sources/{id}.svg'), 'approved source changed')
        for t in THEMES:
            require(digest(out / f'masters/{id}-{t}.svg') == digest(CONTROL / f'renders/{id}-{t}.svg'), 'approved master changed')
            require(digest(out / f'exports/{id}-{t}-64.png') == digest(CONTROL / f'renders/{id}-{t}-64.png'), 'approved 64px changed')
    require(digest(out / 'wash-defs.svginc') == digest(CONTROL / 'wash-defs.svginc'), 'approved wash grammar changed')
    result = {'status': 'PASS', 'raw_exit': 0, 'catalog_ids': [a['id'] for a in entries],
              'foods': sum(a['kind'] == 'food' for a in entries), 'fallbacks': sum(a['kind'] == 'fallback' for a in entries), 'editable_source_svgs': len(entries),
              'theme_masters': len(entries)*len(THEMES), 'transparent_pngs': len(entries)*len(THEMES)*len(SIZES),
              'historical_control_files_unchanged': len(lock['sha256']),
              'approved_sources_masters_and_64px_identical': list(APPROVED),
              'optical_measurements_not_visual_approval': optical,
              'approval': catalog['approval']}
    return result


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=('build', 'verify', 'event'))
    ap.add_argument('--phase')
    args = ap.parse_args()
    if args.command == 'event':
        require(args.phase, '--phase required')
        event(args.phase)
    else:
        result = globals()[args.command]()
        dump(OUT / f'evidence/{args.command}.json', result)
        print(json.dumps(result, indent=2))
