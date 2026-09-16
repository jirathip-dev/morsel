#!/usr/bin/env python3
"""Produce the exhaustive state matrix and lossless labeled contact sheets."""
from pathlib import Path
import json
from PIL import Image,ImageDraw,ImageFont
R=Path(__file__).resolve().parents[1]
states=json.loads((R/'states.json').read_text());report=json.loads((R/'evidence/verification.json').read_text())
assert report['status']=='PASS'
shots={x['file']:x for x in report['captures']}
font=ImageFont.truetype(str(R/'assets/fonts/EBGaramond[wght].ttf'),22)
rows=['# #263 — State / decision matrix','',f'{len(states)} distinct named states × 2 variants × 2 themes. Phone captures are 390×844. Every sheet also has a scrolled context capture. Exact paths/hashes and observed runtime state are in `evidence/verification.json`.','', 'Seeded specimens prove presentation; real CDP pointer/keyboard transition probes independently cover first open, invalid/valid input, confirmation, edit, undo, renewed manual consent, cancel, Escape, failure/retry, Health retry, date rollover, focus and narrow geometry. No live app/server/Health writes.','','| State | Today row | Sheet / draft / decision | Paper & Night evidence |','|---|---|---|---|']
for s in states:
 target='Usual target · unavailable' if s.get('unavailable') else f"{'Training day' if s.get('addition') is not None else 'Usual day'} · {2126+s.get('addition',0):,} kcal"
 detail=s['label']+'; '+('sheet open' if s.get('sheet') else 'Today')
 if s.get('sheet') and (s.get('addition') is None or s.get('editing')):detail+='; amount '+('blank' if not s.get('draft') else f'`{s["draft"]}` (user-authored fixture)')
 links=[]
 for v in ['a','b']:
  for t in ['paper','night']:
   key=f'evidence/{v}-{t}-{s["id"]}.png';assert key in shots and (R/key).exists();links.append(f'[{v.upper()}/{t}]({key})')
   if s.get('sheet'):assert f'evidence/{v}-{t}-{s["id"]}-context.png' in shots
 rows.append(f'| `{s["id"]}` | {target} | {detail} | '+ ' · '.join(links)+' |')
rows+=['','## Invariants across the matrix','', '- One Today target row; no duplicate calorie-target receipt, Movement/Workout, provenance, caveat, toggle or Undo on Today.','- Blank/invalid/pending/unavailable/unchecked-manual consent blocks confirmation; valid explicit entry remains unconfirmed until completion.','- No Health state changes the food target. Missing and denied are honestly indistinguishable in the source reader; true zero is a separate readable value.','- Actual stale sample dates remain earlier than checked time. Movement-only and Workout-only cover both directions of partial Health.','- Empty food intake is zero; missing/partial nutrition is unavailable. Multi-meal rendering partitions the retained approved fictional fixture, not additional invented intake.','- Undo/cancel never mutate meals or saved goals. Native gestures/calendar and the exhaustive numeric gallery are separate gates.']
(R/'STATE-MATRIX.md').write_text('\n'.join(rows)+'\n')
# 3 state rows × 4 candidates; no rescaling of screenshots. Each original
# phone capture is a 390x844 cell, labeled on a separate 40px header strip.
records=[]
for mode,selection in [('states',states),('context',[s for s in states if s.get('sheet')])]:
 for page,start in enumerate(range(0,len(selection),3),1):
  chunk=selection[start:start+3];im=Image.new('RGB',(1560,len(chunk)*884),'#FFF7E8');d=ImageDraw.Draw(im)
  cells=[]
  for row,s in enumerate(chunk):
   for col,(v,t) in enumerate([(v,t) for v in ['a','b'] for t in ['paper','night']]):
    suffix='-context' if mode=='context' else '';file=f'evidence/{v}-{t}-{s["id"]}{suffix}.png';img=Image.open(R/file);assert img.size==(390,844)
    x,y=col*390,row*884;d.text((x+10,y+8),f'{v.upper()} / {t} / {s["id"]}',fill='#2A261F',font=font);im.paste(img,(x,y+40));cells.append(file)
  filename=f'evidence/contact-{mode}-{page:02}.png';im.save(R/filename,optimize=False);records.append({'file':filename,'members':cells,'width':im.width,'height':im.height})
(R/'evidence/contact-index.json').write_text(json.dumps(records,indent=2)+'\n')
print('Matrix states',len(states),'contact sheets',len(records),'original capture cells',sum(len(x['members']) for x in records))
