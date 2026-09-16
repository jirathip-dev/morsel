#!/usr/bin/env python3
"""Resolve visual-review claims with exact retained pixels."""
from pathlib import Path
from PIL import Image,ImageChops
import json,hashlib,sys
R=Path(__file__).resolve().parents[1]
rows=[]
for v in ['a','b']:
 for t in ['paper','night']:
  a=Image.open(R/f'evidence/{v}-{t}-usual.png').convert('RGB')
  b=Image.open(R/f'evidence/{v}-{t}-unavailable.png').convert('RGB')
  diff=ImageChops.difference(a,b)
  assert diff.crop((0,300,390,844)).getbbox() is None,'Macro/food pixels drift'
  ys=[y for y in range(844) if diff.crop((0,y,390,y+1)).getbbox()]
  rows.append({'variant':v,'theme':t,'unchanged_y_300_through_843':True,'last_changed_y':max(ys),'disposition':'App target row/ring change; macro and food pixels do not change.'})
before=json.loads((R/'evidence/pre-label-fix-captures.json').read_text())
after={p:hashlib.sha256((R/p).read_bytes()).hexdigest() for p in before}
changed=sorted(p for p in before if before[p]!=after[p])
assert changed==['evidence/alignment-night.png','evidence/alignment-paper.png'],changed
report={'status':'PASS','macro_claim_disposition':rows,'label_fix_changed_only':changed,'unchanged_reviewed_captures':len(before)-len(changed),'all_app_and_gallery_captures_remain_byte_identical':True}
print(json.dumps(report,indent=2))
if '--seal' in sys.argv:(R/'evidence/visual-dispositions.json').write_text(json.dumps(report,indent=2)+'\n')
