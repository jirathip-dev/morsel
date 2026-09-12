#!/usr/bin/env python3
"""Copy a review-only mini-repository; never deletes or runs Git/network."""
import argparse, json, shutil
from pathlib import Path
from library import ROOT, ART, digest

def main():
    ap=argparse.ArgumentParser();ap.add_argument('destination',type=Path);args=ap.parse_args();dest=args.destination.resolve()
    assert dest!=ROOT.resolve() and not ROOT.resolve().is_relative_to(dest)
    scoped=('docs/art/food-library','skills/food-art')
    support=['app/Fonts/'+p.name for p in (ART/'fonts').iterdir()]
    support += [f'docs/evidence/issue-90/90-V1-today-default-{t}.png' for t in ('paper','night')]
    for rel in scoped:
        target=dest/rel
        if target.exists():
            expected={str(p.relative_to(ROOT/rel)) for p in (ROOT/rel).rglob('*') if p.is_file()}
            actual={str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()}
            assert actual<=expected,('unexpected mirror files; no deletion authorized',sorted(actual-expected))
        shutil.copytree(ROOT/rel,target,dirs_exist_ok=True)
    for rel in support:
        (dest/rel).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/rel,dest/rel)
    checked=[]
    for rel in scoped:
        left={str(p.relative_to(ROOT/rel)):digest(p) for p in (ROOT/rel).rglob('*') if p.is_file()}
        right={str(p.relative_to(dest/rel)):digest(p) for p in (dest/rel).rglob('*') if p.is_file()}
        assert left==right;checked+=list(left)
    print(json.dumps({'status':'PASS','canonical_mirror_files_identical':len(checked),'support_files':len(support),'destination':str(dest)},indent=2))
if __name__=='__main__':main()
