#!/usr/bin/env python3
"""Retain a measured capture failure; default is a read-only dry run."""
from pathlib import Path
import hashlib,json,shutil,sys
from PIL import Image,ImageChops
R=Path(__file__).resolve().parents[1]/'evidence'
D=R/'repro-failure-scrollbar'
a=R/'a-paper-unconfirmed-context.png'
b=R/'a-paper-unconfirmed-context-mismatch.png'
if D.exists():
 a=D/'expected.png';b=D/'actual.png'
x,y=Image.open(a).convert('RGB'),Image.open(b).convert('RGB')
diff=ImageChops.difference(x,y);bbox=diff.getbbox()
assert x.size==y.size==(390,844)
assert bbox and bbox[0]>=386 and bbox[2]<=390,bbox
assert ImageChops.difference(x.crop((0,0,386,844)),y.crop((0,0,386,844))).getbbox() is None
report={'classification':'Browser overlay-scrollbar fade, not app-content drift','bbox':bbox,'changed_pixels':sum(any(v) for v in diff.getdata()),'outside_rightmost_4px_identical':True,'expected_sha256':hashlib.sha256(a.read_bytes()).hexdigest(),'actual_sha256':hashlib.sha256(b.read_bytes()).hexdigest(),'scope':'Pre-normalization rejected capture; not final evidence'}
print(json.dumps(report,indent=2))
if '--apply' in sys.argv and not D.exists():
 D.mkdir();shutil.copy2(a,D/'expected.png');b.rename(D/'actual.png')
 diff.save(D/'difference.png')
 if (R/'rerender-difference.png').exists():(R/'rerender-difference.png').rename(D/'first-diagnostic.png')
 (D/'measurement.json').write_text(json.dumps(report,indent=2)+'\n')
else:print('READ ONLY; --apply retains the failure once without changing the canonical capture.')
if '--verify-normalized' in sys.argv or '--seal-normalized' in sys.argv:
 final=R/'a-paper-unconfirmed-context.png'
 z=Image.open(final).convert('RGB');normalized_diff=ImageChops.difference(x,z);box=normalized_diff.getbbox()
 assert box and box[0]>=385,box
 assert ImageChops.difference(x.crop((0,0,385,844)),z.crop((0,0,385,844))).getbbox() is None
 normalized={'status':'PASS','difference_bbox':box,'content_identical_outside_rightmost_5px':True,'note':'Scrollbar and antialiased edge removed only; app layout unchanged.','expected_sha256':hashlib.sha256(a.read_bytes()).hexdigest(),'normalized_sha256':hashlib.sha256(final.read_bytes()).hexdigest()}
 print(json.dumps(normalized,indent=2))
 if '--seal-normalized' in sys.argv:(D/'normalization.json').write_text(json.dumps(normalized,indent=2)+'\n')
