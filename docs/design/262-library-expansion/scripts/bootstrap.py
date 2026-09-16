#!/usr/bin/env python3
"""One-time read-only snapshot of approved controls. Never updates the product library."""
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = Path('/Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion')
BASE = PRODUCT / 'docs/art/food-library-v2'
EXPECTED = '88b8d4df7978254d2f0fb0297b8b60bc67153e57'

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=PRODUCT, text=True).strip() == EXPECTED
    refs = ROOT / 'references'
    assert not (refs / 'shipped-baseline.json').exists(), 'baseline already locked'
    refs.mkdir(exist_ok=True)
    files = subprocess.check_output(['git', 'ls-files', 'docs/art/food-library-v2', 'app', 'db', 'packages/schema'], cwd=PRODUCT, text=True).splitlines()
    hashes = {p: sha(PRODUCT / p) for p in files}
    (refs / 'shipped-baseline.json').write_text(json.dumps({'base_commit': EXPECTED, 'sha256': hashes}, indent=2) + '\n')
    for name in ('subjects-proposed.json', 'coverage.json', 'alias-proposals-260.json', 'SUBJECT-LIST.md', 'SHA256SUMS.json'):
        shutil.copy2(BASE / 'expansion-262' / name, refs / name)
    for name in ('catalog.json', 'subjects.json', 'build-cache.json', 'ART-SPEC.md', 'wash-defs.svginc'):
        shutil.copy2(BASE / name, refs / ('shipped-' + name))
    library = ROOT / 'library'
    library.mkdir(exist_ok=True)
    for directory in ('sources', 'masters', 'exports', 'fonts'):
        shutil.copytree(BASE / directory, library / directory, dirs_exist_ok=False)
    shutil.copy2(BASE / 'wash-defs.svginc', library / 'wash-defs.svginc')
    vendor = ROOT / 'scripts/vendor'
    vendor.mkdir(parents=True, exist_ok=True)
    for name in ('ink_library.py', 'sample_gate.py', 'library.py', 'ink_expansion_plan.py'):
        shutil.copy2(PRODUCT / 'skills/food-art/scripts' / name, vendor / name)
    (refs / 'vendor-provenance.json').write_text(json.dumps({'base_commit': EXPECTED, 'files': {p.name: sha(p) for p in vendor.iterdir()}}, indent=2) + '\n')
    print(json.dumps({'base': EXPECTED, 'protected_files': len(hashes), 'copied_shipped_assets': 18, 'raw_names_copied': False}))

if __name__ == '__main__':
    main()
