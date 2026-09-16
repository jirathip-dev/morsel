#!/usr/bin/env python3
"""F1–F4 regression: wording, exact metadata scope, unchanged art/proof bytes."""
import hashlib
import json
import unittest
from html.parser import HTMLParser
import pipeline as p

EXPECTED = ('Broad folded flat noodles on a shallow plate with sprouts and a lime wedge; '
            'no particular protein or nut garnish is specified.')


def normalized(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':')).encode()).hexdigest()


class GalleryAlts(HTMLParser):
    def __init__(self):
        super().__init__()
        self.current = None
        self.alts = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'article':
            self.current = attrs.get('data-id')
        if tag == 'img' and self.current and attrs.get('class') == 'large':
            if self.current in self.alts:
                raise ValueError('duplicate study image')
            self.alts[self.current] = attrs.get('alt')

    def handle_endtag(self, tag):
        if tag == 'article':
            self.current = None


class PadThaiMetadata(unittest.TestCase):
    def setUp(self):
        self.before = p.read(p.ROOT / 'evidence/fix-1/before.json')

    def test_generator_matches_source_description(self):
        item = next(e for e in p.entries(5) if e['id'] == 'pad-thai')
        self.assertEqual(item['description'], EXPECTED, 'Pad thai generator wording')
        for retired in ('shrimp', 'crushed peanut'):
            self.assertNotIn(retired, item['description'].lower())

    def test_metadata_changes_only_pad_thai_description(self):
        for rel, baseline in self.before['metadata'].items():
            with self.subTest(path=rel):
                data = p.read(p.ROOT / rel)
                assets = data['assets']
                self.assertEqual(len(assets), baseline['asset_count'])
                self.assertEqual(len({a['id'] for a in assets}), len(assets))
                others = [a for a in assets if a['id'] != 'pad-thai']
                self.assertEqual(normalized(others), baseline['other_assets_sha256'])
                pad = [a for a in assets if a['id'] == 'pad-thai']
                self.assertEqual(len(pad), 1)
                self.assertEqual(pad[0]['description'], EXPECTED, 'Pad thai metadata wording')
                self.assertEqual(normalized({k: v for k, v in pad[0].items() if k != 'description'}),
                                 baseline['pad_non_description_sha256'])
                self.assertEqual(normalized({k: v for k, v in data.items() if k != 'assets'}),
                                 baseline['envelope_sha256'])

    def test_svg_and_all_library_art_byte_identical(self):
        pinned = {rel: digest for rel, digest in self.before['sha256'].items()
                  if rel.startswith(('library/sources/', 'library/masters/', 'library/exports/'))}
        actual = {str(f.relative_to(p.ROOT)) for directory in ('sources', 'masters', 'exports')
                  for f in (p.LIB / directory).iterdir() if f.is_file()}
        self.assertTrue(pinned)
        self.assertEqual(actual, set(pinned))
        for rel, digest in pinned.items():
            self.assertEqual(p.sha(p.ROOT / rel), digest, rel)
        self.assertEqual(p.sha(p.LIB / 'sources/pad-thai.svg'), self.before['pad_thai_svg_sha256'])

    def test_gallery_alt_matches_art_and_other_subjects(self):
        expected = {e['id']: e['description'] for e in p.entries(5)}
        expected['pad-thai'] = EXPECTED
        for theme in p.THEMES:
            parser = GalleryAlts()
            parser.feed((p.ROOT / f'batch-5/gallery-{theme}.html').read_text())
            self.assertEqual(parser.alts, expected, 'Pad thai gallery alt wording')

    def test_real_browser_reports_correct_alt_at_both_widths(self):
        browser = p.read(p.ROOT / 'batch-5/browser.json')
        self.assertEqual(browser['status'], 'PASS')
        records = [c for c in browser['captures'] if c['page'].startswith('gallery-')]
        self.assertEqual({(c['page'], tuple(c['dom']['viewport'])) for c in records},
                         {(f'gallery-{theme}', size) for theme in p.THEMES
                          for size in ((390, 844), (1440, 1000))})
        self.assertEqual(len(records), 4)
        for case in records:
            self.assertEqual(case['dom'].get('padThaiAlt'), EXPECTED,
                             'Pad thai browser DOM alt wording')
            self.assertEqual(case['raw_exit'], 0)

    def test_all_existing_proof_pixels_unchanged(self):
        pinned = {rel: digest for rel, digest in self.before['sha256'].items()
                  if rel.endswith('.png') and not rel.startswith('library/')}
        self.assertTrue(pinned)
        for rel, digest in pinned.items():
            self.assertEqual(p.sha(p.ROOT / rel), digest, rel)


if __name__ == '__main__':
    unittest.main(verbosity=2)
