#!/usr/bin/env python3
"""Cheap adversarial probes for the issue-262 artifact boundary (no render jobs)."""
import copy
import tempfile
import unittest
from pathlib import Path
import pipeline as p


class ContractProbes(unittest.TestCase):
    def setUp(self):
        self.source=(p.LIB/'sources/mango.svg').read_text()
        self.defs=(p.LIB/'wash-defs.svginc').read_text()

    def reject(self, source):
        with self.assertRaises(ValueError):
            p.compile_svg(source,self.defs,'paper')

    def test_approved_control_compiles_both_themes(self):
        for theme in p.THEMES:
            body=p.compile_svg(self.source,self.defs,theme)
            self.assertEqual(body,(p.LIB/f'masters/mango-{theme}.svg').read_text())

    def test_new_palette_token_rejected(self):
        self.reject(self.source.replace('{{gold}}','#0000FF',1))

    def test_unresolved_token_rejected(self):
        self.reject(self.source.replace('{{gold}}','{{purple}}',1))

    def test_external_image_rejected(self):
        self.reject(self.source.replace('</svg>','<image href="https://example.invalid/art.png"/></svg>'))

    def test_script_and_event_rejected(self):
        self.reject(self.source.replace('</svg>','<script>alert(1)</script></svg>'))
        self.reject(self.source.replace('<svg ','<svg onload="alert(1)" ',1))

    def test_dimensions_rejected(self):
        self.reject(self.source.replace('width="256"','width="512"',1))

    def test_wash_insertion_cardinality(self):
        self.reject(self.source.replace('<!-- WASH_DEFS -->',''))
        self.reject(self.source.replace('<!-- WASH_DEFS -->','<!-- WASH_DEFS --><!-- WASH_DEFS -->'))

    def test_approved_batch_counts_and_uniqueness(self):
        groups=[p.entries(b) for b in range(1,6)]
        ids=[a['id'] for g in groups for a in g]
        self.assertEqual(len(ids),len(set(ids)))
        self.assertEqual([sum(a['kind']=='food' for a in g) for g in groups],[24,24,24,23,12])
        self.assertEqual(sum(a['kind']=='fallback' for g in groups for a in g),5)
        original={a['id'] for a in p.read(p.REF/'shipped-catalog.json')['assets']}
        self.assertFalse(original & set(ids))

    def test_batch_five_observation_honesty(self):
        observations=p.read(p.REF/'coverage.json')['rows_per_proposed_identity']
        self.assertTrue(all(observations.get(a['id'],0)==0 for a in p.entries(5)))

    def admission_fixture(self, rows, raw):
        from unittest.mock import patch
        from subprocess import CompletedProcess
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(p.subprocess, 'run', return_value=CompletedProcess([],0,raw,'')), patch.object(p.subprocess, 'check_output', return_value=rows), patch.object(p.time, 'sleep'):
                p._admission_window(Path(temp))
            return p.read(Path(temp)/'admission.json')

    def test_real_native_process_blocks_admission(self):
        with self.assertRaisesRegex(RuntimeError, 'admission blocked'):
            self.admission_fixture('999991 1 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild\n', '999991 xcodebuild test\n')

    def test_actual_sibling_render_blocks_admission(self):
        with self.assertRaisesRegex(RuntimeError, 'admission blocked'):
            self.admission_fixture('999991 1 /opt/homebrew/bin/rsvg-convert\n', '')

    def test_multiline_wrapper_and_rust_argv_are_not_render_jobs(self):
        result=self.admission_fixture('999991 1 /usr/bin/python3\n999992 1 /bin/rustc\n', '999991 python3 coordinator.py\nexport SCOPE=reference\n999992 rustc --error-format diagnostic-rendered-ansi\n')
        self.assertEqual(result['status'],'PASS')
        self.assertFalse(result['attempts'][-1]['busy'])

    def test_raw_manifest_set_and_hash_tamper(self):
        old=p.ROOT
        try:
            with tempfile.TemporaryDirectory() as temp:
                root=Path(temp)
                p.ROOT=root
                (root/'a.txt').write_text('original\n')
                p.save(root/'SHA256SUMS.json',{'excludes_itself':True,'file_count':1,'total_bytes_excluding_manifest':(root/'a.txt').stat().st_size,'sha256':{'a.txt':p.sha(root/'a.txt')}})
                p.check_package()
                (root/'extra.tmp').write_text('unexpected\n')
                with self.assertRaises(ValueError): p.check_package()
                (root/'extra.tmp').unlink()
                (root/'a.txt').write_text('tamper\n')
                with self.assertRaises(ValueError): p.check_package()
        finally:
            p.ROOT=old


if __name__=='__main__':
    unittest.main(verbosity=2)
