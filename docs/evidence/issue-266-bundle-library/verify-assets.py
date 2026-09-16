"""Recheck frozen source, old metadata, and all resource hashes from git."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
PROOF = json.loads(Path(__file__).with_name('asset-proof.json').read_text())
ART = ROOT / 'app/Resources/FoodArt'
SOURCE = 'docs/design/262-library-expansion/library/'


def blob(ref, path):
    return subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=ROOT, timeout=30)


def digest(data):
    return hashlib.sha256(data).hexdigest()


catalog = (ART / 'catalog.json').read_bytes()
assert catalog == blob(PROOF['source'], SOURCE + 'catalog.json')
assert digest(catalog) == PROOF['catalog_sha256']
old = json.loads(blob(PROOF['base'], 'app/Resources/FoodArt/catalog.json'))
new = json.loads(catalog)
old_assets = {asset['id']: asset for asset in old['assets']}
new_assets = {asset['id']: asset for asset in new['assets']}
for identity, asset in old_assets.items():
    for key in ('id', 'name', 'aliases', 'category', 'kind'):
        assert asset[key] == new_assets[identity][key], (identity, key)
expected = {f'{identity}-{theme}-64.png' for identity in new_assets for theme in ('paper', 'night')}
assert {path.name for path in ART.glob('*.png')} == expected
hashes = json.loads((ROOT / 'app/Scripts/food-art-sha256.json').read_text())
assert hashes['catalog.json'] == digest(catalog)
for name in sorted(expected):
    data = (ART / name).read_bytes()
    assert data == blob(PROOF['source'], SOURCE + 'exports/' + name), name
    assert digest(data) == hashes[name], name
for record in PROOF['original_assets']:
    before = blob(PROOF['base'], record['path'])
    after = (ROOT / record['path']).read_bytes()
    assert before == after
    assert digest(before) == record['before_sha256'] == record['after_sha256'] == record['approved_sha256']
base_bytes = sum(len(blob(PROOF['base'], record['path'])) for record in PROOF['original_assets'])
base_bytes += len(blob(PROOF['base'], 'app/Resources/FoodArt/catalog.json'))
head_bytes = len(catalog) + sum((ART / name).stat().st_size for name in expected)
assert base_bytes == PROOF['counts']['before_resource_bytes']
assert head_bytes == PROOF['counts']['after_resource_bytes']
print(json.dumps({'catalog_sha256': digest(catalog), 'before_identities': len(old_assets),
                  'after_identities': len(new_assets), 'frozen_pngs_identical': len(expected),
                  'original_pngs_identical': len(PROOF['original_assets']), 'old_metadata_unchanged': True,
                  'before_resource_bytes': base_bytes, 'after_resource_bytes': head_bytes,
                  'resource_bytes_added': head_bytes - base_bytes}, indent=2))
