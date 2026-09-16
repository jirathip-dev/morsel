"""Run the shipped validator against a scratch copy of a real built bundle."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'app/Resources/FoodArt'
BUNDLE = Path(sys.argv[1]).resolve()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(path):
    return {str(file.relative_to(path)): sha(file) for file in path.rglob('*') if file.is_file()}


before = inventory(BUNDLE)
with tempfile.TemporaryDirectory(prefix='morsel266-built-mutation-') as temp:
    scratch = Path(temp) / 'Morsel.app'
    shutil.copytree(BUNDLE, scratch)

    def invoke(label, expected):
        command = ['xcrun', '--sdk', 'macosx', 'swift', str(ROOT / 'app/Scripts/validate-food-art.swift'),
                   str(SOURCE), str(scratch)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        print(json.dumps({'case': label, 'command': command, 'raw_exit': result.returncode}), flush=True)
        print(result.stdout + result.stderr, flush=True)
        assert result.returncode == expected

    invoke('built-green', 0)
    for theme in ('paper', 'night'):
        path = scratch / f'boba-tea-{theme}-64.png'
        data = path.read_bytes()
        bookend = sha(path)
        for operation in ('missing', 'truncated'):
            try:
                if operation == 'missing':
                    path.unlink()
                else:
                    path.write_bytes(data[:64])
                invoke(f'{theme}-{operation}', 1)
            finally:
                path.write_bytes(data)
            assert sha(path) == bookend
            print(json.dumps({'file': path.name, 'mutation': operation,
                              'before_sha256': bookend, 'restored_sha256': sha(path)}), flush=True)
    invoke('built-restored-green', 0)
    assert inventory(scratch) == before
assert inventory(BUNDLE) == before
print('Scratch bundle fully restored; real built bundle never mutated; all SHA-256 bookends equal.')
