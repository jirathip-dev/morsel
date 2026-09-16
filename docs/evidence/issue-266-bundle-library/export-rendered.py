"""Export the focused xcresult's rendered attachments into committed evidence."""
import hashlib
import json
from pathlib import Path
import shutil

EXPORT = Path('/tmp/morsel-266-attach')
DEST = Path(__file__).with_name('rendered')
DEST.mkdir(exist_ok=True)
manifest = json.loads((EXPORT / 'manifest.json').read_text())
records = []
for entry in manifest:
    for attachment in entry['attachments']:
        key = attachment['suggestedHumanReadableName'].split('_0_')[0]
        source = EXPORT / attachment['exportedFileName']
        target = DEST / f'{key}.png'
        shutil.copyfile(source, target)
        records.append({'file': target.name, 'test': entry['testIdentifier'], 'device': attachment['deviceName'],
                        'device_id': attachment['deviceId'],
                        'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
records.sort(key=lambda record: record['file'])
(DEST.with_name('rendered-manifest.json')).write_text(json.dumps(records, indent=2, sort_keys=True) + '\n')
print(json.dumps({'frames': len(records), 'unique_files': len({r['file'] for r in records}),
                  'device_id': records[0]['device_id'], 'device': records[0]['device']}, indent=2))
print(json.dumps([r['file'] for r in records], indent=0))
