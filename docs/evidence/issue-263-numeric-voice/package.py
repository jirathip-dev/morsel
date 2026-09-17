"""Package real XCTest attachments and raw receipts, without altering PNG bytes."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
label, group = sys.argv[1:]
receipt = json.loads((ROOT / '.lane-logs' / (label + '.json')).read_text())
assert receipt['raw_exit'] == 0, receipt
source = ROOT / '.lane-logs' / (label + '-attachments')
export = json.loads((source / 'manifest.json').read_text())
folder = OUT / group
folder.mkdir(exist_ok=True)
rows = []
for test in export:
    for attachment in test['attachments']:
        human = attachment['suggestedHumanReadableName']
        if not human.startswith(('263-alignment-', '263-b-')):
            continue
        name = human.split('_0_')[0] + '.png'
        data = (source / attachment['exportedFileName']).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', data[16:24])
        shutil.copyfile(source / attachment['exportedFileName'], folder / name)
        rows.append(dict(file=f'{group}/{name}', sha256=hashlib.sha256(data).hexdigest(),
                         pixels=[width, height], device=attachment['deviceId'],
                         exported=attachment['exportedFileName']))
assert rows
assert len(rows) == len({r['file'] for r in rows})
(folder / 'manifest.json').write_text(json.dumps(sorted(rows, key=lambda r: r['file']), indent=2) + '\n')
(folder / 'run.json').write_text(json.dumps(receipt, indent=2) + '\n')
log = (ROOT / '.lane-logs' / (label + '.log')).read_text()
lines = [line for line in log.splitlines() if re.search(
    r'^(COMMAND=|NUMERIC_|RAW_EXIT=)|Executed \d+ test|\*\* TEST ', line)]
(folder / 'raw-output.txt').write_text('\n'.join(lines) + '\n')
print(f'Packaged {len(rows)} verified original attachments to {folder}')
