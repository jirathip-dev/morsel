#!/usr/bin/env python3
"""Pin delivered art, evidence and the exercised repository-owned skill."""
import argparse
import json
from ink_library import ROOT, OUT, digest, dump, require, verify

MANIFEST=OUT/'SHA256SUMS.json'


def files():
    paths=[p for base in (OUT,ROOT/'skills/food-art') for p in base.rglob('*')
           if p.is_file() and p!=MANIFEST and '__pycache__' not in p.parts and p.name!='.DS_Store']
    return sorted(paths)


def run(command):
    verify()
    gates=json.loads((OUT/'evidence/gates.json').read_text())
    require(gates['status']=='PASS' and all(s['raw_exit']==0 for s in gates['steps']),'gate incomplete or failed')
    current={str(p.relative_to(ROOT)):digest(p) for p in files()}
    if command=='write':
        dump(MANIFEST,{'schema_version':1,'meaning':'Current delivered bytes, not a claim that timing/logs reproduce byte-for-byte.',
                       'excluded':['this manifest','__pycache__','.DS_Store'], 'sha256':current})
    expected=json.loads(MANIFEST.read_text())['sha256']
    require(expected==current,'package file set or checksum mismatch; refresh only after intentional changes')
    print(json.dumps({'status':'PASS','files':len(current),'manifest':str(MANIFEST.relative_to(ROOT)),'raw_exit':0},indent=2))

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command',choices=('write','check'))
    run(ap.parse_args().command)
