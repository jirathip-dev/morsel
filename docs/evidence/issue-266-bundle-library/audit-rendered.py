"""Pixel audit of the committed rendered evidence: sizes, theme grounds, artwork presence."""
import io
import json
from pathlib import Path
from PIL import Image, ImageChops, ImageCms

DEST = Path(__file__).with_name('rendered')
GROUNDS = {'paper': (255, 247, 232), 'night': (42, 38, 31)}
OUT = Path(__file__).with_name('rendered-audit.json')
SRGB = ImageCms.createProfile('sRGB')


def rgb(path):
    with Image.open(path) as raw:
        image = raw.convert('RGB')
        icc = raw.info.get('icc_profile')
    if icc:
        image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(icc)), SRGB)
        assert image.mode == 'RGB'
    return image


def off_ground(image, corner):
    solid = Image.new('RGB', image.size, corner)
    mask = ImageChops.difference(image, solid).convert('L').point(lambda value: 255 if value > 24 else 0)
    return {'count': sum(mask.histogram()[128:]), 'bbox': list(mask.getbbox() or [])}


results = []
for path in sorted(DEST.glob('266-*.png')):
    image = rgb(path)
    theme = 'paper' if 'paper' in path.name else ('night' if 'night' in path.name else None)
    corner = image.getpixel((4, 4))
    ground = GROUNDS[theme] if theme else None
    content = off_ground(image, corner)
    results.append({'file': path.name, 'size': list(image.size), 'corner_rgb': list(corner),
                    'theme_ground_ok': None if ground is None else all(abs(corner[i] - ground[i]) <= 2 for i in range(3)),
                    'off_ground_pixels': content['count'], 'content_bbox': content['bbox'],
                    'icc_profile_bytes': len(Image.open(path).info.get('icc_profile') or b'')})

by_name = {result['file']: result for result in results}
pairs = {}
for name in sorted(by_name):
    if 'today' in name:
        continue
    key = name.split('-', 2)[2]
    paper_bytes = DEST.joinpath(f'266-paper-{key}').read_bytes()
    night_bytes = DEST.joinpath(f'266-night-{key}').read_bytes()
    pairs[key] = {'corner_differs': by_name[f'266-paper-{key}']['corner_rgb'] != by_name[f'266-night-{key}']['corner_rgb'],
                  'bytes_identical': paper_bytes == night_bytes}

summary = {
    'frames': len(results),
    'all_sizes_1179x2556': all(result['size'] == [1179, 2556] for result in results),
    'theme_grounds_ok': [result['file'] for result in results if result['theme_ground_ok'] is False],
    'frames_without_content': [result['file'] for result in results if result['off_ground_pixels'] < 5_000],
    'theme_pairs_corner_differs': [key for key, value in pairs.items() if not value['corner_differs']],
    'theme_pairs_bytes_identical': [key for key, value in pairs.items() if value['bytes_identical']],
    'per_frame': results,
}
OUT.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print(json.dumps({key: value for key, value in summary.items() if key != 'per_frame'}, indent=2))
