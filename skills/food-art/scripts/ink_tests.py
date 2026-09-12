#!/usr/bin/env python3
"""Isolated, exercised cache and fail-closed tests for refined SVG edition."""
import json
import shutil
import tempfile
import time
from pathlib import Path
from PIL import Image
from ink_library import OUT, APPROVED, build, verify, subjects, compile_svg, digest, dump, require


def snapshot(out):
    return {str(p.relative_to(out)): {'sha256': digest(p), 'mtime_ns': p.stat().st_mtime_ns}
            for d in ('masters', 'exports') for p in (out/d).iterdir() if p.is_file()}


def run():
    started=time.perf_counter()
    checks=[]
    def checked(name, fn):
        tick=time.perf_counter()
        detail=fn()
        checks.append({'name':name,'status':'PASS','raw_exit':0,'seconds':time.perf_counter()-tick,'detail':detail})
    with tempfile.TemporaryDirectory(prefix='morsel-ink-test-') as td:
        out=Path(td)/'art'
        shutil.copytree(OUT/'sources',out/'sources')
        for name in ('subjects.json','wash-defs.svginc'):
            shutil.copy2(OUT/name,out/name)
        (out/'evidence').mkdir()
        shutil.copy2(OUT/'evidence/control-lock.json',out/'evidence/control-lock.json')
        initial=build(out)
        checked('clean-room-byte-reproduction',lambda: reproduce(out,initial))
        before=snapshot(out)
        no_op=build(out)
        checked('no-op-preserves-every-export-hash-and-mtime',lambda: no_op_check(out,before,no_op))
        banana=out/'sources/banana.svg'
        original=banana.read_text()
        banana.write_text(original.replace('</svg>','<path d="M120 120 l12 0 l0 12 l-12 0Z" fill="{{red}}" opacity=".8"/></svg>'))
        delta=build(out)
        after=snapshot(out)
        checked('single-source-real-pixel-change-rebuilds-one-id',lambda: delta_check(before,after,delta))
        # Restore fixture bytes and confirm deterministic regeneration.
        banana.write_text(original)
        build(out)
        checked('restored-source-restores-original-bytes',lambda: reproduce(out,{'rebuilt':['banana']}))
        before=snapshot(out)
        missing=out/'exports/banana-paper-64.png'
        missing.unlink()
        repair=build(out)
        checked('missing-png-rebuilds-only-owner',lambda: repair_check(out,before,repair))
        before=snapshot(out)
        tamper=out/'exports/banana-night-192.png'
        im=Image.open(tamper)
        im.putpixel((0,0),(255,0,0,255))
        im.save(tamper)
        checked('tampered-png-rejected-before-repair',lambda: rejects(lambda: verify(out)))
        repair=build(out)
        checked('tampered-png-repaired-with-peer-mtimes-intact',lambda: repair_check(out,before,repair))
        defs=(out/'wash-defs.svginc').read_text()
        sample=banana.read_text()
        for name,content in (
            ('external-image',sample.replace('</svg>','<image href="https://invalid.example/a.png"/></svg>')),
            ('unapproved-fill',sample.replace('</svg>','<path d="M80 80 l30 30" fill="#123456"/></svg>')),
            ('unresolved-token',sample.replace('</svg>','<path d="M80 80 l30 30" fill="{{missing}}"/></svg>')),
            ('external-url',sample.replace('</svg>','<path d="M80 80 l30 30" fill="url(https://invalid.example/x)"/></svg>')),
            ('script-element',sample.replace('</svg>','<script>alert(1)</script></svg>')),
            ('event-handler',sample.replace('<svg ','<svg onload="alert(1)" ',1)),
        ):
            checked('reject-'+name,lambda c=content: rejects(lambda: compile_svg(c,defs,'paper')))
        metadata=out/'subjects.json'
        original_metadata=metadata.read_text()
        data=json.loads(original_metadata)
        data['assets'][0]['id']='../escape'
        metadata.write_text(json.dumps(data))
        checked('reject-traversal-id',lambda: rejects(lambda: subjects(out)))
        metadata.write_text(original_metadata)
        extra=out/'sources/extra.svg'
        extra.write_text(sample)
        checked('reject-unregistered-source',lambda: rejects(lambda: subjects(out)))
        extra.unlink()
        checked('final-fixture-verification',lambda: verify(out)['status'])
        from ink_add import add
        before=snapshot(out)
        spec={'id':'fixture-food','name':'Synthetic workflow fixture','aliases':['test fixture only'],
              'kind':'food','category':'produce','description':'Synthetic copied geometry for additive-cache testing, not delivered artwork.'}
        addition=add(spec,sample,out)
        checked('add-one-study-keeps-existing-136-outputs-untouched',lambda: addition_check(out,before,addition))
        checked('reject-duplicate-add-without-overwrite',lambda: rejects(lambda: add(spec,sample,out)))
        checked('release-gate-rejects-18th-fixture-entry',lambda: rejects(lambda: verify(out)))
    result={'status':'PASS','raw_exit':0,'checks':checks,'count':len(checks),'seconds':time.perf_counter()-started,
            'scope':'Isolated executable reproduction/incremental/negative tests; not food authoring speed or visual approval.'}
    dump(OUT/'evidence/workflow-tests.json',result)
    print(json.dumps(result,indent=2))
    return result


def reproduce(out,result):
    expected=snapshot(OUT)
    got=snapshot(out)
    require(set(expected)==set(got),'reproduction output set')
    require(all(expected[p]['sha256']==got[p]['sha256'] for p in expected),'clean-room byte mismatch')
    return {'identical_outputs':len(expected),'rebuilt':result['rebuilt']}


def no_op_check(out,before,result):
    require(result['rebuilt']==[] and len(result['skipped'])==17,'no-op cache miss')
    require(snapshot(out)==before,'no-op changed bytes or mtimes')
    return {'untouched_outputs':len(before),'elapsed_seconds':result['elapsed_seconds']}


def delta_check(before,after,result):
    require(result['rebuilt']==['banana'] and len(result['skipped'])==16,'not a single-id rebuild')
    peers=[p for p in before if not Path(p).name.startswith('banana-')]
    require(all(before[p]==after[p] for p in peers),'unrelated asset rewritten')
    own=[p for p in before if p not in peers]
    require(all(before[p]['sha256']!=after[p]['sha256'] for p in own),'mutation did not change real output pixels/masters')
    return {'untouched_peer_outputs':len(peers),'changed_owner_outputs':len(own),'elapsed_seconds':result['elapsed_seconds']}


def repair_check(out,before,result):
    require(result['rebuilt']==['banana'],'repair rebuilt unrelated ID')
    after=snapshot(out)
    require(all(before[p]['sha256']==after[p]['sha256'] for p in before),'repair did not restore bytes')
    peers=[p for p in before if not Path(p).name.startswith('banana-')]
    require(all(before[p]==after[p] for p in peers),'repair rewrote peer')
    return {'restored_outputs':len(before),'untouched_peer_outputs':len(peers),'elapsed_seconds':result['elapsed_seconds']}


def addition_check(out,before,result):
    require(result['rebuilt']==['fixture-food'] and len(result['skipped'])==17,'addition rebuilt existing IDs')
    after=snapshot(out)
    require(all(before[p]==after[p] for p in before),'addition touched existing output')
    report=verify(out,allow_additions=True)
    require(len(report['catalog_ids'])==18,'addition not registered')
    return {'new_outputs':len(after)-len(before),'untouched_existing_outputs':len(before),'elapsed_seconds':result['elapsed_seconds'],
            'fixture_only':True,'not_authoring_speed':True}


def rejects(fn):
    try:
        fn()
    except (ValueError, AssertionError) as error:
        return {'rejected':True,'reason':str(error)}
    raise AssertionError('negative fixture passed unexpectedly')


if __name__=='__main__':
    run()
