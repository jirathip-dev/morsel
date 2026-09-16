#!/usr/bin/env python3
"""Reproduce #262 fix-1 text correction without writing any source/master/export."""
import argparse
import json
import os
import subprocess
import sys
import pipeline as p

EVIDENCE = p.ROOT / 'evidence/fix-1'
METADATA = ('library/catalog.json', 'library/subjects.json',
            'batch-5/catalog-delta.json', 'batch-5/subjects.json')


def check():
    before = p.read(EVIDENCE / 'before.json')
    pinned = before['sha256']
    art = {rel: digest for rel, digest in pinned.items()
           if rel.startswith(('library/sources/', 'library/masters/', 'library/exports/'))}
    p.require(art and all(p.sha(p.ROOT / rel) == digest for rel, digest in art.items()),
              'fix-1 changed artwork bytes')
    proof_pixels = {rel: digest for rel, digest in pinned.items()
                    if rel.endswith('.png') and not rel.startswith('library/')}
    p.require(proof_pixels and all(p.sha(p.ROOT / rel) == digest for rel, digest in proof_pixels.items()),
              'fix-1 changed proof pixels')
    p.check_catalog(5)
    for batch in range(1, 6):
        p.check_batch_evidence(batch)
    p.check_index_evidence(5)
    preservation = p.preserve(p.DEFAULT_PRODUCT)
    v = p.read(p.ROOT / 'batch-5/verification.json')
    p.require((v['new_foods'], v['food_count'], v['asset_count']) == (107, 120, 130),
              'fix-1 changed identity counts')
    p.require((preservation['shipped_identities'], preservation['shipped_art_files'],
               preservation['protected_product_files']) == (18, 162, 534),
              'fix-1 preservation counts differ')
    pad = 'library/sources/pad-thai.svg'
    changed = [rel for rel, digest in pinned.items() if p.sha(p.ROOT / rel) != digest]
    result = {
        'status': 'PASS', 'raw_exit': 0,
        'description': p.PAD_THAI_DESCRIPTION,
        'pad_thai_svg': {'before_sha256': before['pad_thai_svg_sha256'],
                         'after_sha256': p.sha(p.ROOT / pad), 'equal': True},
        'unchanged_library_art_files': len(art),
        'unchanged_existing_proof_pngs': len(proof_pixels),
        'counts': {'new_foods': v['new_foods'], 'total_foods': v['food_count'], 'assets': v['asset_count']},
        'shipped_preservation': {key: preservation[key] for key in
                                ('status', 'shipped_identities', 'shipped_art_files', 'protected_product_files')},
        'batch5_browser_captures': p.read(p.ROOT / 'batch-5/browser.json')['capture_count'],
        'root_index_byte_identical': p.sha(p.ROOT / 'index.html') == pinned['index.html'],
        'existing_files_changed_before_packaging': sorted(changed),
        'scope': 'Text/evidence only; final pixel approval outstanding; no bundling.'
    }
    p.require(result['root_index_byte_identical'], 'unrelated index changed')
    return result


def run():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    p.require((EVIDENCE / 'before.json').is_file(), 'missing frozen before receipt')
    commands = []
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', ART_CONTRACT_FIXTURE=str(p.ROOT))

    def step(name, argv, expected=0, witness=None):
        result = subprocess.run(argv, cwd=p.ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        text = result.stdout
        log = EVIDENCE / f'{name}.log'
        log.write_text(text + '\nRAW_EXIT=' + str(result.returncode) + '\n')
        commands.append({'name': name, 'command': argv, 'raw_exit': result.returncode,
                         'expected_exit': expected, 'log': str(log.relative_to(p.ROOT))})
        p.save(EVIDENCE / 'commands.json', commands)
        print(name, 'raw_exit', result.returncode, flush=True)
        p.require(result.returncode == expected, f'{name} unexpected exit; see {log}')
        if witness:
            p.require(witness in text and 'ERROR:' not in text, f'{name} missing expected witness')

    for rel in METADATA:
        data = p.read(p.ROOT / rel)
        matches = [asset for asset in data['assets'] if asset['id'] == 'pad-thai']
        p.require(len(matches) == 1, 'Pad thai metadata identity missing/duplicate')
        matches[0]['description'] = p.PAD_THAI_DESCRIPTION
        p.save(p.ROOT / rel, data)
    print('Updated only Pad thai descriptions in four metadata files', flush=True)
    # No shared lock exists. Use the explicit coordinator native/render predicate.
    p.admission(EVIDENCE)
    step('proofs', [sys.executable, 'scripts/proofs.py', '--batch', '5'])
    # proofs.py emits a simple index; restore the canonical aggregate generator.
    step('aggregate-index', [sys.executable, 'scripts/gallery_index.py'])
    step('closed-set', [sys.executable, 'scripts/pipeline.py', 'verify', '--batch', '5',
                        '--product', str(p.DEFAULT_PRODUCT)])
    step('browser', [sys.executable, 'scripts/capture.py', '--batch', '5'])
    step('metadata-green', [sys.executable, 'scripts/test_pad_thai_metadata.py'], witness='Ran 6 tests')
    step('art-contract', [sys.executable, 'scripts/test_contract.py'], witness='Ran 13 tests')
    step('evidence-contract', [sys.executable, 'scripts/test_evidence_contract.py'], witness='Ran 10 tests')
    step('historical-verifier-red', [sys.executable, 'scripts/test_evidence_contract.py', '--baseline'],
         expected=1, witness='FAILED (failures=8)')
    step('preservation-and-evidence', [sys.executable, 'scripts/fix_pad_thai_metadata.py', '--check-only'])
    p.save(EVIDENCE / 'verification.json', check())
    print(json.dumps(p.read(EVIDENCE / 'verification.json'), indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if args.check_only:
        print(json.dumps(check(), indent=2))
    else:
        run()
