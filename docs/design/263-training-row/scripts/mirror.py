#!/usr/bin/env python3
"""Scoped evidence mirror: dry-run default; never deletes any file."""
from pathlib import Path
import argparse,hashlib,shutil,json,subprocess
R=Path(__file__).resolve().parents[1]
W=Path('/Users/jirathip/.herdr/worktrees/morsel/design-263-training-row').resolve()
D=W/'docs/design/263-training-row'
p=argparse.ArgumentParser();g=p.add_mutually_exclusive_group();g.add_argument('--apply',action='store_true');g.add_argument('--verify',action='store_true');a=p.parse_args()
assert R!=D.resolve() and D.resolve().is_relative_to(W/'docs/design')
def inventory(root):return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
src=inventory(R);dst=inventory(D)
extra=sorted(set(dst)-set(src));assert not extra,('Unexpected mirror files; no deletion authorized by this script',extra)
changed=sorted(k for k,v in src.items() if dst.get(k)!=v)
if a.apply:
 subprocess.run(['python3',str(R/'scripts/audit.py')],check=True)
 shutil.copytree(R,D,dirs_exist_ok=True)
 dst=inventory(D)
if a.apply or a.verify:
 assert set(src)==set(dst),'Relative-path set mismatch'
 assert src==dst,'Byte/hash mismatch'
 subprocess.run(['python3',str(D/'scripts/audit.py')],check=True)
 print(json.dumps({'status':'PASS','canonical':str(R),'mirror':str(D),'raw_files':len(src),'all_hashes_identical':True},indent=2))
else:print(json.dumps({'mode':'DRY RUN','source':str(R),'destination':str(D),'copy_count':len(changed),'extra_files':extra,'deletions':0},indent=2))
