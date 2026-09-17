"""Verify every native evidence image and the complete before/after matrix."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent
STATES = ['today', 'day-drill-down', 'history-ledger-gauge', 'weight-chart', 'calendar',
          'goals-filled', 'goals-invalid', 'meal-capture', 'meal-capture-bottom',
          'meal-edit', 'meal-edit-bottom', 'photo-metadata', 'menu-editor']
EXPECTED = {f'263-b-{theme}-{state}.png' for theme in ['paper', 'night'] for state in STATES}


def verify():
    provenance = json.loads((ROOT / 'source-provenance.json').read_text())
    repo = ROOT.parents[2]
    for row in provenance['production_sources']:
        assert hashlib.sha256((repo / row['path']).read_bytes()).hexdigest() == row['after_sha256'], row['path']
    driver = provenance['capture_driver']
    assert hashlib.sha256((repo / driver['path']).read_bytes()).hexdigest() == driver['sha256']
    count = 0
    for group in ['before', 'after', 'alignment']:
        manifest = json.loads((ROOT / group / 'manifest.json').read_text())
        files = [Path(row['file']).name for row in manifest]
        assert len(files) == len(set(files)), 'Duplicate capture'
        expected = (EXPECTED if group != 'alignment' else
                    {f'263-alignment-{theme}-{size}-{weight}.png'
                     for theme in ['paper', 'night'] for size in [14, 22, 32] for weight in [400, 500]})
        assert set(files) == expected, (group, expected.symmetric_difference(files))
        assert {p.name for p in (ROOT / group).glob('*.png')} == expected
        assert json.loads((ROOT / group / 'run.json').read_text())['raw_exit'] == 0
        for row in manifest:
            data = (ROOT / row['file']).read_bytes()
            assert hashlib.sha256(data).hexdigest() == row['sha256'], row['file']
            pixels = list(struct.unpack('>II', data[16:24]))
            assert pixels == row['pixels'], row['file']
            if group != 'alignment':
                assert pixels == [1179, 2556], row['file']
            count += 1
    for theme in ['paper', 'night']:
        for size in [14, 22, 32]:
            assert (ROOT / 'alignment' / f'263-alignment-{theme}-{size}-400.png').read_bytes() != (
                ROOT / 'alignment' / f'263-alignment-{theme}-{size}-500.png').read_bytes()
    for name in sorted(EXPECTED):
        assert (ROOT / 'before' / name).read_bytes() != (ROOT / 'after' / name).read_bytes(), name
    print(f'PASS: {count} original PNG hashes/dimensions; {len(EXPECTED)} complete before/after pairs')
    print(f'Surfaces per theme: {len([x for x in STATES if not x.endswith("-bottom")])}; '
          f'scroll frames per theme: {len([x for x in STATES if x.endswith("-bottom")])}')


if __name__ == '__main__':
    verify()
