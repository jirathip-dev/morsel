"""Offline source-guard RED/GREEN proof in a disposable git archive tree."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[3]
TEST = Path('app/issue-164-goals-restore-contract.test.ts')
SOURCES = [Path('app/Sources/Morsel') / (name + '.swift') for name in
           ('GoalsEditor', 'GoalsEditorModel', 'SupabaseMealMutations')]
LOGS = ROOT / '.lane-logs'
LOGS.mkdir(exist_ok=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(tree, label):
    command = ['npx', 'vitest', 'run', str(TEST)]
    with (LOGS / (label + '.log')).open('w') as output:
        result = subprocess.run(command, cwd=tree, stdout=output, stderr=subprocess.STDOUT, timeout=60)
    print(label, 'RAW_EXIT=' + str(result.returncode), flush=True)
    return result.returncode


fixed = {path: (ROOT / path).read_bytes() for path in SOURCES}
bookends = {'lane_before': {str(path): digest(data) for path, data in fixed.items()}}
# At implementation time HEAD is the pre-fix commit. Subsequent replays accept
# the pinned pre-fix commit through argv without modifying any worktree.
import sys
base = sys.argv[1] if len(sys.argv) > 1 else 'HEAD'
bookends['base'] = subprocess.check_output(['git', 'rev-parse', base], cwd=ROOT, text=True).strip()
with tempfile.TemporaryDirectory(prefix='morsel-164-proof-') as directory:
    tree = Path(directory)
    archive = subprocess.check_output(['git', 'archive', base], cwd=ROOT, timeout=60)
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        bundle.extractall(tree, filter='data')
    (tree / 'node_modules').symlink_to(ROOT / 'node_modules', target_is_directory=True)
    shutil.copyfile(ROOT / TEST, tree / TEST)
    original = {path: (tree / path).read_bytes() for path in SOURCES}
    bookends['scratch_before'] = {str(path): digest(data) for path, data in original.items()}
    try:
        bookends['red_exit'] = run(tree, 'restore-base-red')
        for path, data in fixed.items():
            (tree / path).write_bytes(data)
        bookends['green_exit'] = run(tree, 'restore-fixed-green')
    finally:
        for path, data in original.items():
            (tree / path).write_bytes(data)
        bookends['scratch_restored'] = {str(path): digest((tree / path).read_bytes()) for path in SOURCES}
        bookends['lane_after'] = {str(path): digest((ROOT / path).read_bytes()) for path in SOURCES}
        (LOGS / 'restore-bookends.json').write_text(json.dumps(bookends, indent=2) + '\n')
    assert bookends['red_exit'] == 1, bookends
    assert bookends['green_exit'] == 0, bookends
    assert bookends['scratch_before'] == bookends['scratch_restored'], bookends
    assert bookends['lane_before'] == bookends['lane_after'], bookends
print('byte-exact scratch restore and untouched-lane SHA256 bookends: PASS')
