#!/usr/bin/env python3
"""Project-only mirror with explicit dry-run, no deletion, exact readback."""
from pathlib import Path
import json,hashlib,shutil,sys
R=Path(__file__).resolve().parents[1]
D=Path('/Users/jirathip/.herdr/worktrees/morsel/design-263-numeric-voice/docs/design/263-numeric-voice')
assert R.resolve()!=D.resolve()
def tree(root):return {p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()} if root.exists() else {}
s=tree(R);d=tree(D);extra=set(d)-set(s)
assert not extra,('Unexpected mirror files; refuse silent deletion',sorted(extra))
changes=[p for p in sorted(s) if d.get(p)!=s[p]]
if '--verify' in sys.argv:
    assert s==d,changes
    print(json.dumps(dict(status='PASS',files=len(s),canonical=str(R.resolve()),mirror=str(D.resolve()),hash_identical=True)));sys.exit()
print(json.dumps(dict(mode='APPLY' if '--apply' in sys.argv else 'DRY-RUN',changed=len(changes),paths=changes),indent=2))
if '--apply' in sys.argv:
    for p in changes:
        target=D/p;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(R/p,target)
    assert tree(D)==s
    print('PASS: exact mirror readback')
