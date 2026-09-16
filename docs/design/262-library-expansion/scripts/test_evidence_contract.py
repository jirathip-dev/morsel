#!/usr/bin/env python3
"""Behavioral RED/GREEN probes against real settled art; never mutate source/mirror."""
import copy
import importlib.util
import io
import json
import os
import sys
import tempfile
import types
import unittest
from contextlib import contextmanager, redirect_stdout
from pathlib import Path
from unittest.mock import patch
import pipeline as current

BASELINE='--baseline' in sys.argv
if BASELINE:
    sys.argv.remove('--baseline')
    p=types.ModuleType('pipeline_before_audit')
    p.__file__=current.__file__
    sys.modules[p.__name__]=p
    exec(compile((current.REF/'verifier-before-audit.py.txt').read_text(),str(current.REF/'verifier-before-audit.py.txt'),'exec'),p.__dict__)
else:
    p=current
FIXTURE=Path(os.environ.get('ART_CONTRACT_FIXTURE',str(current.DEFAULT_PRODUCT/'docs/design/262-library-expansion')))


class EvidenceContract(unittest.TestCase):
    @contextmanager
    def fixture(self, mutate=None, fast=False):
        read=p.read
        def altered(path):
            data=copy.deepcopy(read(path))
            rel=str(Path(path).relative_to(FIXTURE))
            # Legacy B1 fixture: explicit test-only dependency pins, not a capture claim.
            if rel=='batch-1/browser.json' and not data.get('inputs_sha256'):
                from evidence_contract import browser_cases
                cases=browser_cases(p,1)
                inputs={FIXTURE/f'batch-1/{page}.html' for page,_,_,_,_ in cases}|{FIXTURE/'batch-1/proof.css'}
                inputs.update((p.LIB/'fonts').glob('*.ttf'))
                inputs.update(p.LIB/f'exports/{e["id"]}-{t}-{s}.png' for e in p.entries(1) for t in p.THEMES for s in (64,192))
                data['inputs_sha256']={str(f.relative_to(FIXTURE)):p.sha(f) for f in inputs}
            return mutate(rel,data) if mutate else data
        with patch.object(p,'ROOT',FIXTURE),patch.object(p,'LIB',FIXTURE/'library'),patch.object(p,'REF',FIXTURE/'references'),patch.object(p,'read',side_effect=altered),patch.object(p,'save'),patch.object(p,'privacy',return_value={'status':'TEST_FIXTURE'}),redirect_stdout(io.StringIO()):
            n=int(read(FIXTURE/'library/catalog.json')['library_version'].rsplit('b',1)[1])
            if fast:
                with patch.object(p,'verify'):
                    yield n
            else:
                yield n

    def test_valid_catalog(self):
        with self.fixture() as n:p.verify(n,p.DEFAULT_PRODUCT)

    def test_missing_catalog_additions_rejected(self):
        def mutate(rel,d):
            if rel=='library/catalog.json':d['assets']=d['assets'][:18]
            return d
        with self.fixture(mutate) as n:
            with self.assertRaisesRegex(ValueError,'catalog'):p.verify(n,p.DEFAULT_PRODUCT)

    def test_wrong_catalog_path_rejected(self):
        def mutate(rel,d):
            if rel=='library/catalog.json':d['assets'][18]['source']='sources/mango.svg'
            return d
        with self.fixture(mutate) as n:
            with self.assertRaisesRegex(ValueError,'catalog'):p.verify(n,p.DEFAULT_PRODUCT)

    def test_valid_evidence(self):
        with self.fixture(fast=True) as n:p.package(n,Path('unused-private-fixture'))

    def reject_evidence(self,edit,reason):
        n=int(p.read(FIXTURE/'library/catalog.json')['library_version'].rsplit('b',1)[1])
        def mutate(rel,d):return edit(rel,d,n)
        with self.fixture(mutate,fast=True):
            with self.assertRaisesRegex(ValueError,reason):p.package(n,Path('unused-private-fixture'))

    def test_empty_browser_rejected(self):
        def edit(rel,d,n):
            if rel==f'batch-{n}/browser.json':d.update(captures=[],capture_count=0,inputs_sha256={})
            return d
        self.reject_evidence(edit,'browser capture')

    def test_missing_browser_pins_rejected(self):
        def edit(rel,d,n):
            if rel==f'batch-{n}/browser.json':d.pop('inputs_sha256',None)
            return d
        self.reject_evidence(edit,'input pin')

    def test_empty_rebuild_rejected(self):
        def edit(rel,d,n):
            if rel==f'batch-{n}/reproducibility.json':d.update(sha256={},files_compared=0)
            return d
        self.reject_evidence(edit,'rebuild count')

    def test_empty_index_rejected(self):
        def edit(rel,d,n):
            if rel=='evidence/index/verification.json':d.update(captures=[],capture_count=0,inputs_sha256={})
            return d
        self.reject_evidence(edit,'index capture')

    def manifest(self,field,value):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'a.txt').write_text('x')
            m={'excludes_itself':True,'file_count':1,'total_bytes_excluding_manifest':1,'sha256':{'a.txt':p.sha(root/'a.txt')}}
            m[field]=value
            (root/'SHA256SUMS.json').write_text(json.dumps(m))
            with patch.object(p,'ROOT',root):
                with self.assertRaisesRegex(ValueError,'manifest declared'):p.check_package()

    def test_false_manifest_count_rejected(self):self.manifest('file_count',0)
    def test_false_manifest_bytes_rejected(self):self.manifest('total_bytes_excluding_manifest',0)


if __name__=='__main__':
    print('BASELINE_RED_PROBE' if BASELINE else 'CORRECTED_GREEN_PROBE')
    unittest.main(verbosity=2)
