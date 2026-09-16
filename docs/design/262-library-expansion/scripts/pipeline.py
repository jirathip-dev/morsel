#!/usr/bin/env python3
"""Issue-262 candidate pipeline: additive, offline, closed-set, no production writes."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'library'
REF = ROOT / 'references'
sys.path.insert(0, str(ROOT / 'scripts/vendor'))
from ink_library import compile_svg, validate_svg, asset_paths, THEMES, SIZES
from ink_expansion_plan import coverage as estimate, PUBLISHED_NAMES

AUTHORITY = 'https://github.com/jirathip-dev/morsel/issues/262#issuecomment-5690697676'
AMENDMENT = 'https://github.com/jirathip-dev/morsel/issues/262#issuecomment-5690755910'
COUNTS = {1: 24, 2: 24, 3: 24, 4: 23, 5: 12}
DEFAULT_PRODUCT = Path('/Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion')
FALLBACKS = {
    'soup': 'A softly irregular broth bowl and spoon; a category sign, not an identified soup.',
    'dairy': 'A small milk vessel and soft-curd form; a category sign, not specific dairy ingredients.',
    'sweets': 'A modest assortment of sweet forms; a category sign, not an identified dessert.',
    'prepared': 'A divided plate of deliberately non-specific food masses; a category sign, not an identified meal.',
    'condiments': 'Small sauce vessels and an oil cruet; a category sign, not identified condiments.',
}


def read(p):
    return json.loads(p.read_text())


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def save(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(obj, ensure_ascii=False, indent=2) + '\n'
    if not p.exists() or p.read_text() != text:
        p.write_text(text)


def require(ok, message):
    if not ok:
        raise ValueError(message)


def _admission_window(logdir):
    """Coordination ruling: native/render predicate; bounded 60s cycles, no host-idle gate."""
    from datetime import datetime, timezone
    logdir.mkdir(parents=True, exist_ok=True)
    attempts = []
    for attempt in range(13):
        probe = subprocess.run(['pgrep', '-fl', 'chrome|blender|render|xcodebuild'], text=True, capture_output=True)
        require(probe.returncode in (0, 1), 'pgrep failed; admission unknown')
        # Use actual executables, not Rust diagnostic-rendered argv or a queued
        # wrapper's textual command. Never signal any process.
        rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True).splitlines()
        procs = {}
        for line in rows:
            parts = line.strip().split(None, 2)
            if len(parts) == 3 and parts[0].isdigit():
                procs[int(parts[0])] = (int(parts[1]), parts[2])
        require(procs, 'process discovery failed')
        ancestry = {os.getpid()}
        parent = os.getppid()
        while parent in procs and parent not in ancestry:
            ancestry.add(parent)
            parent = procs[parent][0]
        args = {}
        for line in probe.stdout.splitlines():
            match = re.match(r'^(\d+)\s+(.*)$', line)
            if match:
                args[int(match.group(1))] = match.group(2)
        daemon_roots = {pid for pid, cmd in args.items() if 'chrome-headless-shell' in cmd and 'isolated-profile' in cmd}
        def under_daemon(pid):
            seen = set()
            while pid in procs and pid not in seen:
                if pid in daemon_roots:
                    return True
                seen.add(pid)
                pid = procs[pid][0]
            return False
        busy, idle = [], []
        for pid, (ppid, comm) in procs.items():
            if pid in ancestry:
                continue
            name = Path(comm).name.lower().strip('()')
            if name in ('xcodebuild', 'xctest', 'blender', 'rsvg-convert'):
                busy.append({'pid':pid, 'program':name})
            elif 'chrome-headless' in name:
                sample = subprocess.run(['ps','-p',str(pid),'-o','%cpu='],text=True,capture_output=True)
                if sample.returncode:
                    continue # process exited during read-only sampling
                cpu = float(sample.stdout.strip() or 0)
                if under_daemon(pid) and cpu < 2:
                    idle.append({'pid':pid,'cpu':cpu,'classification':'persistent-browser-idle'})
                else:
                    busy.append({'pid':pid,'program':name,'cpu':cpu})
        item = {'at_utc':datetime.now(timezone.utc).isoformat(), 'raw_pgrep_exit':probe.returncode, 'busy':busy, 'idle_browser':idle}
        attempts.append(item)
        if not busy:
            result = {'status':'PASS','attempts':attempts,'wait_limit_seconds':60,'probe_interval_seconds':5,'authority':'owner coordination ruling: native/render predicate; no load-idle gate'}
            save(logdir/'admission.json', result)
            with (logdir/'admission.jsonl').open('a') as log:
                log.write(json.dumps(result)+'\n')
            return
        if attempt < 12:
            time.sleep(5)
    result = {'status':'BLOCKED','attempts':attempts,'wait_limit_seconds':60}
    save(logdir/'admission.json', result)
    with (logdir/'admission.jsonl').open('a') as log:
        log.write(json.dumps(result)+'\n')
    raise RuntimeError('Heavy-work admission blocked after bounded 60s wait')


def admission(logdir):
    # Each observation cycle is bounded to 60s; owner explicitly asked to keep
    # polling between probe windows, without backing off or stopping the batch.
    while True:
        try:
            return _admission_window(logdir)
        except RuntimeError as error:
            if str(error) != 'Heavy-work admission blocked after bounded 60s wait':
                raise
            print('Render deferred for one 60s cycle; continuing predicate polling', flush=True)


def proposal():
    obj = read(REF / 'subjects-proposed.json')
    require(len(obj['identities']) == 107, 'approved list count changed')
    require({b: sum(i['batch'] == b for i in obj['identities']) for b in COUNTS} == COUNTS, 'approved batches drift')
    return obj


def entries(batch):
    result = []
    for i in proposal()['identities']:
        if i['batch'] != batch:
            continue
        item = {k: i[k] for k in ('id', 'name', 'aliases', 'category', 'description')}
        item['kind'] = 'food'
        # Hue words in the historical proposal are subordinate to ART-SPEC.
        item['description'] = item['description'].replace('dark-blue and black', 'dark warm-pigment').replace('purple-brown', 'brown-red').replace('silver-grey', 'muted warm-grey')
        result.append(item)
    if batch == 1:
        for f in proposal()['fallbacks_proposed']:
            c = f['category']
            result.append({'id': f['id'], 'name': c.capitalize() + ' · fallback', 'aliases': [c], 'category': c, 'kind': 'fallback', 'description': FALLBACKS[c]})
    return result


def build(batch):
    dest = ROOT / f'batch-{batch}'
    dest.mkdir(exist_ok=True)
    old = read(LIB / 'build-cache.json') if (LIB / 'build-cache.json').exists() else read(REF / 'shipped-build-cache.json')
    renderer = subprocess.check_output(['rsvg-convert', '--version'], text=True).strip()
    defs = (LIB / 'wash-defs.svginc').read_text()
    engine = ''.join(sha(ROOT / 'scripts/vendor' / p) for p in ('ink_library.py', 'sample_gate.py', 'library.py'))
    rebuilt, skipped, catalog = [], [], []
    for e in entries(batch):
        iid = e['id']
        src = LIB / f'sources/{iid}.svg'
        bodies = {t: compile_svg(src.read_text(), defs, t) for t in THEMES}
        key = hashlib.sha256((sha(src) + defs + engine + renderer).encode()).hexdigest()
        paths = asset_paths(iid)
        intact = old.get(iid, {}).get('identity') == key and all((LIB / p).is_file() and sha(LIB / p) == old[iid]['outputs'].get(p) for p in paths)
        if not intact:
            if len(rebuilt) % 4 == 0:
                admission(dest)
            for theme in THEMES:
                master = LIB / f'masters/{iid}-{theme}.svg'
                master.write_text(bodies[theme])
                for size in SIZES:
                    out = LIB / f'exports/{iid}-{theme}-{size}.png'
                    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), '-o', str(out), str(master)], check=True, timeout=45)
            rebuilt.append(iid)
        else:
            skipped.append(iid)
        old[iid] = {'identity': key, 'outputs': {p: sha(LIB / p) for p in paths}}
        save(LIB / 'build-cache.json', old) # checkpoint completed identity before the next admission window
        catalog.append({**e, 'dimensions': [512, 512], 'master_dimensions': [256, 256], 'viewBox': [0, 0, 256, 256], 'source': f'sources/{iid}.svg', 'masters': paths[:2], 'exports': paths[2:], 'provenance': {'type': 'original-agent-authored-svg-ink-wash', 'direction_approval': 'https://github.com/jirathip-dev/morsel/issues/197#issuecomment-5646485904', 'addition_authority': AMENDMENT if batch == 5 else AUTHORITY, 'model': 'gpt-6-astra', 'rights': 'Original artwork for Morsel; no third-party food artwork', 'approval': 'subject-list-approved-pixels-awaiting-owner-review', 'meaning': 'Generic labeled illustration; not a photo, portion, ingredient, cut, allergy or nutrition claim', 'demand': 'general-coverage-only; evidence-free for this account; 0 observed rows' if batch == 5 else 'approved-list; per-identity estimator rows in coverage.json', 'batch': batch}})
    save(dest / 'catalog-delta.json', {'schema_version': 2, 'batch': batch, 'assets': catalog})
    save(dest / 'subjects.json', {'assets': entries(batch)})
    save(dest / 'build-cache.json', {a['id']: old[a['id']] for a in catalog})
    save(LIB / 'build-cache.json', old)
    combined = list(read(REF / 'shipped-catalog.json')['assets'])
    metadata = list(read(REF / 'shipped-subjects.json')['assets'])
    for b in range(1, batch + 1):
        combined += read(ROOT / f'batch-{b}/catalog-delta.json')['assets']
        metadata += entries(b)
    require(len({a['id'] for a in combined}) == len(combined), 'duplicate catalog ID')
    save(LIB / 'catalog.json', {'schema_version': 2, 'library_version': f'2.2.0-candidate-b{batch}', 'approval': 'subject-list-approved-pixels-awaiting-owner-review-not-bundled', 'assets': combined})
    save(LIB / 'subjects.json', {'assets': metadata})
    result = {'status': 'PASS', 'raw_exit': 0, 'renderer': renderer, 'batch': batch, 'rebuilt': rebuilt, 'skipped': skipped, 'new_foods': COUNTS[batch], 'new_fallbacks': 5 if batch == 1 else 0}
    save(dest / 'build.json', result)
    print(json.dumps(result))


def coverage(batch, names):
    p = proposal()
    stored = read(REF / 'coverage.json')
    live = names is not None and names.is_file()
    if live:
        computed, _private_mapping = estimate(p, read(names))
        require(computed == stored, 'private dataset / reference estimate drift; do not publish stale coverage')
    current = stored['cumulative'][f'through_batch_{batch}']
    previous = stored['today_shipped_catalog']['specific'] if batch == 1 else stored['cumulative'][f'through_batch_{batch-1}']['specific']
    per_id = {i['id']: stored['rows_per_proposed_identity'].get(i['id'], 0) for i in p['identities'] if i['batch'] == batch}
    if batch == 5:
        require(all(v == 0 for v in per_id.values()), 'batch 5 must remain evidence-free')
    out = {'batch': batch, 'method': 'Frozen round-1 qualifier-tolerant estimator applied to delivered studies; NOT the shipped #260 matcher or live application coverage.', 'evidence_window': p['evidence_window'], 'reference_recomputed_against_private_input': live, 'distinct_names': stored['distinct_names'], 'total_rows': stored['total_rows'], 'specific': current['specific'], 'category_fallback': current['category_fallback'], 'neutral': current['neutral'], 'pending_later_studies': current['specific_pending_later_batch'], 'specific_delta_distinct': current['specific']['distinct'] - previous['distinct'], 'specific_delta_rows': current['specific']['rows'] - previous['rows'], 'new_foods': COUNTS[batch], 'cumulative_foods': 13 + sum(COUNTS[b] for b in range(1, batch + 1)), 'observed_rows_by_added_identity': per_id, 'coverage_driven_zero_observed_ids': [k for k, v in per_id.items() if v == 0], 'demand_note': 'All 12 subjects are evidence-free for this account (0 observed rows); general coverage only, not observed demand.' if batch == 5 else 'Observed and zero-observed general-coverage additions are distinguished above.', 'public_issue_examples_estimated_targets': stored['published_names']}
    totals = [out[k] for k in ('specific', 'category_fallback', 'neutral', 'pending_later_studies')]
    require(sum(v['distinct'] for v in totals) == out['distinct_names'] and sum(v['rows'] for v in totals) == out['total_rows'], 'coverage partition does not close')
    save(ROOT / f'batch-{batch}/coverage.json', out)
    print(json.dumps({'coverage': 'PASS', 'batch': batch, 'specific': out['specific'], 'foods': out['cumulative_foods'], 'private_recomputed': live}))


def preserve(product, dest=None):
    baseline = read(REF / 'shipped-baseline.json')
    changes = [p for p, h in baseline['sha256'].items() if not (product / p).is_file() or sha(product / p) != h]
    require(not changes, 'protected product bytes changed: ' + str(changes))
    original = read(REF / 'shipped-catalog.json')['assets']
    candidate = {a['id']: a for a in read(LIB / 'catalog.json')['assets']} if (LIB / 'catalog.json').exists() else {}
    rows = []
    for a in original:
        if candidate:
            require(candidate[a['id']] == a, 'shipped catalog entry changed')
        for p in [a['source']] + a['masters'] + a['exports']:
            before = baseline['sha256']['docs/art/food-library-v2/' + p]
            after = sha(LIB / p)
            require(before == after, 'shipped candidate bytes differ: ' + p)
            rows.append({'path': p, 'before_sha256': before, 'after_sha256': after, 'equal': True})
    require(sha(LIB / 'wash-defs.svginc') == sha(REF / 'shipped-wash-defs.svginc'), 'wash changed')
    for p in (LIB / 'fonts').iterdir():
        require(sha(p) == baseline['sha256']['docs/art/food-library-v2/fonts/' + p.name], 'font bytes changed')
    result = {'status': 'PASS', 'protected_product_files': len(baseline['sha256']), 'shipped_identities': len(original), 'shipped_foods': sum(a['kind'] == 'food' for a in original), 'shipped_art_files': len(rows), 'before_after': rows, 'unchanged_palette_wash_fonts': True}
    if dest:
        save(dest, result)
    return result


def verify(batch, product):
    metadata = read(LIB / 'subjects.json')['assets']
    expected = read(REF / 'shipped-subjects.json')['assets'] + [e for b in range(1, batch + 1) for e in entries(b)]
    require(metadata == expected, 'metadata/closed set mismatch')
    ids = {e['id'] for e in expected}
    require({p.stem for p in (LIB / 'sources').glob('*.svg')} == ids, 'missing/extra/unstarted source')
    require(len(ids) == 18 + 5 + sum(COUNTS[b] for b in range(1, batch + 1)), 'declared asset total differs')
    expected_paths = {p for e in expected for p in asset_paths(e['id'])}
    require({str(p.relative_to(LIB)) for d in ('masters', 'exports') for p in (LIB / d).iterdir()} == expected_paths, 'extra/missing export')
    cache = read(LIB / 'build-cache.json')
    require(set(cache) == ids, 'cache closed set differs')
    measurements = []
    for e in [e for b in range(1, batch + 1) for e in entries(b)]:
        src = (LIB / f'sources/{e["id"]}.svg').read_text()
        for theme in THEMES:
            body = compile_svg(src, (LIB / 'wash-defs.svginc').read_text(), theme)
            require(body == (LIB / f'masters/{e["id"]}-{theme}.svg').read_text(), 'master compiler parity')
            for size in SIZES:
                rel = f'exports/{e["id"]}-{theme}-{size}.png'
                im = Image.open(LIB / rel)
                require(im.mode == 'RGBA' and im.size == (size, size), 'RGBA dimensions: ' + rel)
                alpha = im.getchannel('A')
                box = alpha.getbbox()
                require(box and min(box[0], box[1], size-box[2], size-box[3]) >= size * .045, 'clipping: ' + rel + str(box))
                require(all(alpha.getpixel(p) == 0 for p in ((0,0),(size-1,0),(0,size-1),(size-1,size-1))), 'opaque corner')
                if size == 64:
                    strong = sum(alpha.histogram()[65:])
                    require(strong > 140, 'too faint: ' + rel)
                    measurements.append({'id': e['id'], 'theme': theme, 'bbox': box, 'alpha_gt64_pixels': strong})
        for rel in asset_paths(e['id']):
            require(cache[e['id']]['outputs'][rel] == sha(LIB / rel), 'cache drift: ' + rel)
    lock = preserve(product, ROOT / f'batch-{batch}/shipped-18-before-after.json')
    result = {'status': 'PASS', 'raw_exit': 0, 'batch': batch, 'asset_count': len(ids), 'food_count': sum(e['kind'] == 'food' for e in expected), 'new_foods': sum(COUNTS[b] for b in range(1, batch+1)), 'fallback_count': sum(e['kind'] == 'fallback' for e in expected), 'theme_masters': len(ids)*2, 'png_exports': len(ids)*6, 'protected_product_files': lock['protected_product_files'], 'optical_measurements_not_visual_approval': measurements}
    save(ROOT / f'batch-{batch}/verification.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'optical_measurements_not_visual_approval'}))


def reproduce(batch):
    dest = ROOT / f'batch-{batch}'
    admission(dest)
    scratch = ROOT.parent / '.262-scratch'
    scratch.mkdir(exist_ok=True)
    hashes = {}
    with tempfile.TemporaryDirectory(dir=scratch, prefix=f'batch-{batch}-clean-') as td:
        tmp = Path(td)
        for index, e in enumerate(entries(batch)):
            if index and index % 4 == 0:
                admission(dest)
            for theme in THEMES:
                body = compile_svg((LIB / f'sources/{e["id"]}.svg').read_text(), (LIB / 'wash-defs.svginc').read_text(), theme)
                master = tmp / 'master.svg'
                master.write_text(body)
                rel = f'masters/{e["id"]}-{theme}.svg'
                require(sha(master) == sha(LIB / rel), 'clean master differs')
                hashes[rel] = {'committed': sha(LIB/rel), 'clean': sha(master), 'equal': True}
                for size in SIZES:
                    target = tmp / 'export.png'
                    subprocess.run(['rsvg-convert','-w',str(size),'-h',str(size),'-o',str(target),str(master)], check=True, timeout=45)
                    rel = f'exports/{e["id"]}-{theme}-{size}.png'
                    require(sha(target) == sha(LIB / rel), 'clean export differs: ' + rel)
                    hashes[rel] = {'committed': sha(LIB/rel), 'clean': sha(target), 'equal': True}
    scratch.rmdir()
    result = {'status':'PASS', 'raw_exit':0, 'batch':batch, 'method':'Fresh scratch; no build-cache; recompile every new master and rerender every new 64/192/512 RGBA export in both themes; compare SHA-256; remove owned scratch.', 'files_compared':len(hashes), 'sha256':hashes}
    save(dest / 'reproducibility.json', result)
    print(json.dumps({k:v for k,v in result.items() if k!='sha256'}))


def privacy(names):
    require(names is not None and names.is_file(), 'private input required for leak check; do not claim a scan without it')
    p = proposal()
    approved = {s.lower() for i in p['identities'] for s in [i['name']] + i['aliases']}
    approved |= {s.lower() for i in read(REF/'shipped-subjects.json')['assets'] for s in [i['name']] + i['aliases']}
    raw = [r['name'] for r in read(names) if len(r['name']) > 12 and r['name'].lower() not in approved and not any(r['name'] in public for public in PUBLISHED_NAMES)]
    leaked = []
    checked = []
    for f in ROOT.rglob('*'):
        if not f.is_file() or f.suffix in ('.png','.ttf'):
            continue
        text = f.read_text()
        if any(n in text for n in raw):
            leaked.append(str(f.relative_to(ROOT)))
        checked.append(str(f.relative_to(ROOT)))
    require(not leaked, 'private raw name found in public package files (names redacted): ' + str(leaked))
    return {'status':'PASS','private_names_checked':len(raw),'text_files_checked':len(checked),'raw_names_tracked':False,'method':'Exact private row-name exclusion, allowing approved generic aliases and the already public issue examples; names never emitted.'}


def package(batch, names):
    gate = privacy(names)
    save(ROOT / f'batch-{batch}/privacy.json', gate)
    for p in ROOT.rglob('*'):
        require(not (p.name == '__pycache__' or p.name == '.DS_Store' or p.suffix in ('.pyc','.pyo','.bak','.tmp','.swp')), 'transient package artifact: '+str(p))
    bdir = ROOT / f'batch-{batch}'
    paths = [p for p in bdir.rglob('*') if p.is_file() and p.name != 'SHA256SUMS.json']
    paths += [LIB / p for e in entries(batch) for p in [f'sources/{e["id"]}.svg'] + asset_paths(e['id'])]
    save(bdir / 'SHA256SUMS.json', {str(p.relative_to(ROOT)):sha(p) for p in sorted(paths)})
    paths = sorted(p for p in ROOT.rglob('*') if p.is_file() and p != ROOT/'SHA256SUMS.json')
    save(ROOT/'SHA256SUMS.json', {'excludes_itself':True,'file_count':len(paths),'total_bytes_excluding_manifest':sum(p.stat().st_size for p in paths),'sha256':{str(p.relative_to(ROOT)):sha(p) for p in paths}})
    print(json.dumps({'package':'PASS','batch':batch,'manifest_files':len(paths),'raw_files':len(paths)+1,'privacy':gate}))


def check_package():
    m = read(ROOT / 'SHA256SUMS.json')
    actual = {str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file() and p != ROOT/'SHA256SUMS.json'}
    require(actual == set(m['sha256']), 'raw file-set differs from manifest')
    require(all(sha(ROOT/p) == h for p,h in m['sha256'].items()), 'manifest hash mismatch')
    for manifest in ROOT.glob('batch-*/SHA256SUMS.json'):
        require(all(sha(ROOT/p) == h for p,h in read(manifest).items()), 'batch manifest mismatch: '+str(manifest))
    print(json.dumps({'package_check':'PASS','manifest_files':len(actual),'raw_files':len(actual)+1}))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=['build','coverage','verify','reproduce','pack','check-package','privacy','preserve'])
    ap.add_argument('--batch', type=int, choices=range(1,6), default=1)
    ap.add_argument('--product', type=Path, default=DEFAULT_PRODUCT)
    ap.add_argument('--private-names', type=Path)
    args = ap.parse_args()
    if args.command in ('build','reproduce'):
        globals()[args.command](args.batch)
    elif args.command == 'coverage': coverage(args.batch,args.private_names)
    elif args.command == 'verify': verify(args.batch,args.product)
    elif args.command == 'pack': package(args.batch,args.private_names)
    elif args.command == 'check-package': check_package()
    elif args.command == 'privacy': print(json.dumps(privacy(args.private_names)))
    elif args.command == 'preserve': print(json.dumps({k:v for k,v in preserve(args.product).items() if k!='before_after'}))
