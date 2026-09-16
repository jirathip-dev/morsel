#!/usr/bin/env python3
"""Verify closed-set art, frozen batches, exact mirror and optional remote Git subtrees."""
import argparse
import contextlib
import io
import json
import subprocess
from pathlib import Path
from urllib.parse import urlencode
import pipeline as p


def git(repo,*args):
    return subprocess.check_output(['git',*args],cwd=repo,text=True).strip()


def main(through,remote):
    with contextlib.redirect_stdout(io.StringIO()):
        p.verify(through,p.DEFAULT_PRODUCT)
        p.check_package()
    root=p.ROOT
    mirror=p.DEFAULT_PRODUCT/'docs/design/262-library-expansion'
    actual={str(x.relative_to(root)) for x in root.rglob('*') if x.is_file()}
    mirrored={str(x.relative_to(mirror)) for x in mirror.rglob('*') if x.is_file()}
    p.require(root.resolve()!=mirror.resolve(),'mirror aliases canonical')
    p.require(actual==mirrored,'mirror path set differs')
    p.require(all(p.sha(root/x)==p.sha(mirror/x) for x in actual),'mirror bytes differ')
    rollup=p.read(root/'ROLLUP.json')
    p.require(rollup['through_batch']==through,'stale cumulative summary')
    ids=[x['id'] for x in rollup['identities']]
    expected=[e['id'] for b in range(1,through+1) for e in p.entries(b) if e['kind']=='food']
    p.require(ids==expected and len(set(ids))==len(ids),'rollup identity set differs')
    p.require(all(x['source_sha256']==p.sha(p.LIB/f"sources/{x['id']}.svg") for x in rollup['identities']),'stale per-identity source hashes')
    browser_total=0
    p.check_index_evidence(through)
    for b in range(1,through+1):
        p.check_batch_evidence(b)
        d=root/f'batch-{b}'
        data=p.read(d/'browser.json')
        p.require(data['status']=='PASS','incomplete batch browser evidence')
        for rel,h in data.get('inputs_sha256',{}).items():
            p.require(p.sha(root/rel)==h,'stale batch browser input')
        p.require(all(p.sha(root/c['capture'])==c['sha256'] for c in data['captures']),'batch screenshot drift')
        r=p.read(d/'reproducibility.json')
        p.require(r['status']=='PASS' and all(p.sha(p.LIB/rel)==v['committed']==v['clean'] for rel,v in r['sha256'].items()),'stale clean-rebuild evidence')
        browser_total+=len(data['captures'])
    p.require(browser_total==rollup['browser_captures'],'capture count mismatch')
    index=p.read(root/'evidence/index/verification.json')
    p.require(index['status']=='PASS' and all(p.sha(root/rel)==h for rel,h in index['inputs_sha256'].items()),'index input drift')
    p.require(all(p.sha(root/c['capture'])==c['sha256'] for c in index['captures']),'index screenshot drift')
    p.require(all(c['dom']['ids']==[f'batch-{b}' for b in range(1,through+1)] for c in index['captures']),'index batch set mismatch')
    p.require(not git(p.DEFAULT_PRODUCT,'diff','88b8d4df7978254d2f0fb0297b8b60bc67153e57','--','app','db','server','packages','skills','docs/art'),'product source changed')
    scopes=[(p.DEFAULT_PRODUCT,'jirathip-dev/morsel','docs/design/262-library-expansion','design/262-library-expansion'),(root.parents[1],'jirathip-dev/design-output','morsel/262-library-expansion','main')]
    refs=[]
    for repo,gh,scope,branch in scopes:
        tracked=set(git(repo,'ls-files','--',scope).splitlines())
        p.require(tracked=={scope+'/'+x for x in actual},'tracked evidence path set differs')
        p.require(not git(repo,'status','--porcelain','--',scope),'owned scope has uncommitted files')
        head=git(repo,'rev-parse','HEAD')
        local_tree=git(repo,'rev-parse',f'HEAD:{scope}')
        item={'repo':gh,'local_head':head,'scope':scope,'local_tree':local_tree}
        if remote:
            remote_head=git(repo,'ls-remote','origin',f'refs/heads/{branch}').split()[0]
            parent=str(Path(scope).parent)
            endpoint=f'repos/{gh}/contents/{parent}?'+urlencode({'ref':remote_head})
            data=json.loads(subprocess.check_output(['gh','api',endpoint],text=True,timeout=60))
            match=[x for x in data if x['path']==scope and x['type']=='dir']
            p.require(len(match)==1 and match[0]['sha']==local_tree,'remote target subtree differs')
            item.update(remote_head=remote_head,remote_tree=match[0]['sha'],remote_target_verified=True)
        refs.append(item)
    m=p.read(root/'SHA256SUMS.json')
    result={'status':'PASS','scope':'design artifacts only; not owner pixel approval or repository-suite green','through_batch':through,'new_food_identities':len(ids),'total_food_identities':rollup['total_food_identities'],'total_assets':rollup['total_assets'],'batch_browser_captures':browser_total,'index_browser_captures':len(index['captures']),'clean_rebuild_files':rollup['clean_rebuild_files'],'raw_files':len(actual),'manifest_files':m['file_count'],'manifest_excludes_itself':m['excludes_itself'],'raw_total_bytes':sum((root/x).stat().st_size for x in actual),'mirror_hash_identical':True,'protected_product_files':rollup['protected_product_files'],'shipped_art_files_byte_identical':rollup['shipped_art_files_byte_identical'],'refs':refs}
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--through',type=int,choices=range(1,6),default=5)
    ap.add_argument('--remote',action='store_true')
    args=ap.parse_args()
    main(args.through,args.remote)
