import json
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[3]
label, checkout, *filters = sys.argv[1:]
log = root / '.lane-logs' / (label + '.log')
result = '/tmp/morsel-263-' + label + '.xcresult'
cmd = ['xcodebuild', 'test', '-project', 'Morsel.xcodeproj', '-scheme', 'Morsel',
       '-destination', 'platform=iOS Simulator,id=' + os.environ['SIMULATOR_UDID'],
       '-derivedDataPath', '/tmp/morsel-263-dd', '-resultBundlePath', result,
       '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO', *filters]
start = time.monotonic()
with log.open('w') as out:
    out.write('COMMAND=' + repr(cmd) + '\n')
    out.flush()
    try:
        rc = subprocess.run(cmd, cwd=Path(checkout) / 'app', stdout=out, stderr=subprocess.STDOUT,
                            timeout=900).returncode
    except subprocess.TimeoutExpired:
        rc = 124
    out.write(f'\nRAW_EXIT={rc}\n')
receipt = dict(command=cmd, cwd=str(Path(checkout) / 'app'), raw_exit=rc,
               seconds=round(time.monotonic()-start, 2), simulator=os.environ['SIMULATOR_UDID'], result=result)
(root / '.lane-logs' / (label + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt), flush=True)
if rc == 0:
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', result,
                    '--output-path', str(root / '.lane-logs' / (label + '-attachments'))], timeout=60, check=True)
sys.exit(rc)
