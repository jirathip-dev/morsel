#!/usr/bin/env python3
"""Explicit-scope evidence mirroring + authorized branch/archive delivery."""
import argparse
import json
import shutil
import subprocess
from pathlib import Path
from pipeline import ROOT, sha, read, require, check_package, preserve


def git(repo,*args):
    return subprocess.check_output(['git',*args],cwd=repo,text=True).strip()


def commit_push(repo,path,message,branch):
    require(not git(repo,'diff','--cached','--name-only'),'pre-existing staged files; stop instead of committing them')
    subprocess.run(['git','diff','--check','--',path],cwd=repo,check=True)
    subprocess.run(['git','add','--',path],cwd=repo,check=True)
    staged=git(repo,'diff','--cached','--name-only').splitlines()
    require(staged and all(p.startswith(path.rstrip('/')+'/') for p in staged),'staged path fence failed')
    subprocess.run(['git','diff','--cached','--check'],cwd=repo,check=True)
    subprocess.run(['git','commit','-m',message],cwd=repo,check=True,stdout=subprocess.DEVNULL)
    head=git(repo,'rev-parse','HEAD')
    subprocess.run(['git','push','origin',f'HEAD:refs/heads/{branch}'],cwd=repo,check=True)
    remote=git(repo,'ls-remote','origin',f'refs/heads/{branch}').split()[0]
    require(head==remote,'remote exact-head readback differs')
    return {'sha':head,'remote_sha':remote,'changed_files':len(staged),'scope':path,'branch':branch}


def main(batch,product):
    require(git(product,'branch','--show-current')=='design/262-library-expansion','wrong product branch')
    check_package()
    preserve(product)
    target=product/'docs/design/262-library-expansion'
    if target.exists():
        require(target.resolve()!=ROOT.resolve(),'mirror unexpectedly aliases canonical')
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copytree(ROOT,target,dirs_exist_ok=True)
    source_paths={str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file()}
    target_paths={str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()}
    require(source_paths==target_paths,'mirror raw-path set mismatch; no automatic destructive sync')
    require(all(sha(ROOT/p)==sha(target/p) for p in source_paths),'mirror bytes differ')
    changes=git(product,'diff','--name-only','88b8d4df7978254d2f0fb0297b8b60bc67153e57').splitlines()
    require(all(p.startswith('docs/design/262-library-expansion/') for p in changes),'product source diff outside evidence fence')
    product_result=commit_push(product,'docs/design/262-library-expansion',f'design: issue 262 batch {batch} ink/wash studies and proofs (Refs #262)','design/262-library-expansion')
    archive=ROOT.parents[1]
    require(git(archive,'branch','--show-current')=='main','unexpected design-output branch')
    archive_result=commit_push(archive,'morsel/262-library-expansion',f'morsel: #262 batch {batch} artwork and evidence (pixels pending approval)','main')
    gallery=f'https://jirathips-macbook-air.tail8c3301.ts.net:8444/morsel/262-library-expansion/batch-{batch}/index.html'
    status=subprocess.check_output(['curl','-sS','-o','/dev/null','-w','%{http_code}',gallery],text=True).strip()
    require(status=='200','gallery not reachable: '+status)
    result={'batch':batch,'product':product_result,'archive':archive_result,'mirror_files':len(source_paths),'mirror_hash_identical':True,'gallery':gallery,'gallery_http':status,'no_issue_or_pr_writes':True}
    local=product/f'.report-batch-{batch}.md'
    local.write_text('# Batch delivery receipt\n\n```json\n'+json.dumps(result,indent=2)+'\n```\n\nDESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--batch',type=int,choices=range(1,6),required=True)
    ap.add_argument('--product',type=Path,required=True)
    args=ap.parse_args()
    main(args.batch,args.product)
