import os
from pathlib import Path
import subprocess
import sys
import time

lock = Path('/tmp/n.lock')
deadline = time.monotonic() + 60
while True:
    try:
        lock.mkdir()
        break
    except FileExistsError:
        if time.monotonic() >= deadline:
            print('ADMISSION_TIMEOUT=60s; no native command launched', flush=True)
            sys.exit(124)
        time.sleep(2)
owner = lock / 'owner.pid'
owner.write_text(str(os.getpid()) + '\n')
print(f'ADMITTED lock={lock} owner={os.getpid()}', flush=True)
try:
    rc = subprocess.run(sys.argv[1:], timeout=1100).returncode
finally:
    if owner.read_text().strip() == str(os.getpid()):
        owner.unlink()
        lock.rmdir()
sys.exit(rc)
