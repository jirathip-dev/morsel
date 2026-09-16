#!/usr/bin/env python3
"""Rerun retained generators and verify exact emitted file sets/bytes."""
from pathlib import Path
import hashlib,json,subprocess,sys
R=Path(__file__).resolve().parents[1]
def tree():
    paths=list(R.glob('*.html'))+[R/'coverage.json',R/'COVERAGE.md',R/'evidence/counts.json',R/'evidence/review-plates.json',R/'evidence/alignment.raw.tsv']
    paths+=list((R/'evidence').glob('contact-*.png'))+list((R/'evidence').glob('review-*.png'))
    return {p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
before=tree()
subprocess.run([sys.executable,str(R/'scripts/build.py')],check=True)
subprocess.run([sys.executable,str(R/'scripts/package.py')],check=True)
after=tree()
assert before==after,'Generation drift: '+str(sorted(set(before)^set(after)))+' '+str([p for p in set(before)&set(after) if before[p]!=after[p]])
result=dict(status='PASS',files=len(after),sha256=after)
(R/'evidence/generation-rerun.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(status='PASS',byte_identical_generated_files=len(after))))
