"""Assert the rendered rows paint the artwork the resolver reported (pixel identity).

The 64pt leading artwork cell lives at x 130..320 px (3x) of the phone frame; the
item name text starts to its right, so a crop of that cell isolates the artwork.
Cases that resolve to the same asset (or the same neutral sign) must be
byte-identical there; different resolutions must differ in both themes.
"""
import hashlib
import json
from pathlib import Path
from PIL import Image

DEST = Path(__file__).with_name('rendered')
BOX = (130, 640, 320, 790)


def cell(name):
    with Image.open(DEST / f'266-{name}.png') as image:
        return hashlib.sha256(image.convert('RGB').crop(BOX).tobytes()).hexdigest()


neutral = ['pork-gravy', 'unknown', 'shared-plate', 'half-rice', 'qualified-pasta', 'generic-noodles']
checks = {
    'resolver-neutral-cases-share-one-neutral-sign': all(
        cell(f'paper-{case}') == cell('paper-unknown') for case in neutral),
    'resolver-neutral-cases-share-one-neutral-sign-night': all(
        cell(f'night-{case}') == cell('night-unknown') for case in neutral),
    'same-asset-cases-are-pixel-identical': cell('paper-kana') == cell('paper-chinese-kale'),
    'same-asset-cases-are-pixel-identical-night': cell('night-kana') == cell('night-chinese-kale'),
    'identified-food-differs-from-the-neutral-sign': cell('paper-white-rice') != cell('paper-unknown'),
    'identified-food-differs-from-the-neutral-sign-night': cell('night-white-rice') != cell('night-unknown'),
    'new-category-marks-are-distinct-from-the-neutral-sign': all(
        cell(f'paper-{category}') != cell('paper-unknown') for category in ['dairy', 'sweets', 'prepared', 'condiments']),
    'new-category-marks-are-distinct-from-each-other': len(
        {cell(f'paper-{category}') for category in ['dairy', 'sweets', 'prepared', 'condiments']}) == 4,
    'paper-and-night-cells-differ': all(
        cell(f'paper-{case}') != cell(f'night-{case}')
        for case in ['white-rice', 'unknown', 'kana', 'coffee-cake', 'dairy']),
}
for label, ok in checks.items():
    assert ok, label
Path(__file__).with_name('rendered-artwork-groups.json').write_text(json.dumps(checks, indent=2, sort_keys=True) + '\n')
print(json.dumps({'cell_box_px': BOX, 'checks_passed': len(checks), 'checks': checks}, indent=2, sort_keys=True))
