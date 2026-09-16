#!/usr/bin/env python3
"""Deterministically build the two candidates, gallery and alignment lab."""
from pathlib import Path
import json,html
R=Path(__file__).resolve().parents[1]
states=json.loads((R/'states.json').read_text())
assert len({s['id'] for s in states})==len(states)
(R/'fixture.js').write_text('window.FIXTURE='+json.dumps(json.loads((R/'fixture.json').read_text()),ensure_ascii=False)+';\n')
(R/'states.js').write_text('window.STATES='+json.dumps(states,ensure_ascii=False)+';\n')
for v in ['a','b']:(R/(v+'.html')).write_text((R/'src/prototype.html').read_text().replace('__VARIANT__',v))
head='''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Morsel #263 · Owner review</title><link rel="icon" href="data:,"><link rel="stylesheet" href="style.css"><style>
body{padding:28px 20px 50px}main{max-width:1100px;margin:auto}h1{font-size:44px;margin:8px 0 16px}h2{margin:24px 0 12px}p{max-width:760px;margin:8px 0 16px}a{display:inline-flex;align-items:center;min-height:44px;padding:4px 8px}select{min-height:44px;padding:8px;max-width:100%;background:var(--surface);border:1px solid var(--inkline)}.compare{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px}.compare figure{margin:0}.compare img{width:100%;height:auto;border:1px solid var(--line)}.compare figcaption{font-size:17px;padding:10px 0}.pair-links{display:flex;flex-wrap:wrap}.gate{padding:16px 0;border-block:1px solid var(--inkline)}details{border-bottom:1px solid var(--line);padding:12px 0}summary{min-height:44px;cursor:pointer;padding:10px 0}.state-links{display:flex;gap:12px;flex-wrap:wrap}.thumbs{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}.thumbs img{width:100%;height:auto}.thumbs a{display:block;padding:0}code{font:13px Plex} @media(max-width:650px){.compare,.thumbs{grid-template-columns:repeat(2,minmax(0,1fr))}.compare{gap:12px}h1{font-size:38px}body{padding:20px 16px}}
</style></head><body><main>'''
parts=[head,'''<p class="eyebrow">Morsel · Issue 263 · Half (a)</p><h1>One row. The rest in the sheet.</h1><p class="gate">PROTOTYPE — awaiting Guy’s review. Two compositions inside the approved A journal language. No product code changed. All records are fictional. The 300 kcal fixture represents a user-authored example, never a suggested amount.</p><h2>Recommendation: A · Open journal</h2><p>A puts the blank amount and its unit on one generous writing line, then keeps Confirm and Cancel together. It gives the caveats room without card stacks. B uses a compact two-column field and stacked actions; its denser reading pairs cost more vertical scanning. Both follow the same final decisions and P1 policy.</p><div class="compare">''']
for v,label in [('a','A · Open journal'),('b','B · Ruled form')]:
 for theme in ['paper','night']:
  parts.append(f'<figure><a href="{v}.html?theme={theme}"><img src="evidence/{v}-{theme}-usual.png" alt="{label}, {theme}, usual target row"></a><figcaption>{label} · {theme.title()}</figcaption><div class="pair-links"><a href="{v}.html?theme={theme}">Try the row</a><a href="{v}.html?theme={theme}&state=unconfirmed">Open sheet</a></div></figure>')
parts.append('</div><h2>The blank first entry</h2><div class="compare">')
for v in ['a','b']:
 for theme in ['paper','night']:
  parts.append(f'<figure><a href="{v}.html?theme={theme}&state=unconfirmed"><img src="evidence/{v}-{theme}-unconfirmed.png" alt="{v.upper()}, {theme}, blank amount sheet"></a><figcaption>{v.upper()} · {theme.title()} · no preset</figcaption></figure>')
parts.append('''</div><h2>Exercise the policy</h2><p>Open the row → type your own positive amount → confirm → edit → undo inside the sheet. Try a manual goal to see its fresh consent gate. Cancel or Escape leaves the target unchanged. Read Apple Health is simulated, never a real permission request.</p><div class="state-links"><a href="a.html?state=manual-consent">Manual consent</a><a href="a.html?save=failure">Fail → retry</a><a href="a.html?state=stale-health">Stale Health</a><a href="a.html?state=unavailable">Unavailable row</a></div><h2>Every state · both candidates · both themes</h2><p>Each link opens the exact state. PNGs are genuine 390 × 844 browser captures. Sheet “context” captures are scrolled to Readings and About; the sheet stays a single scroll, not another page.</p>''')
for s in states:
 sid=s['id'];parts.append(f'<details><summary>{html.escape(s["label"])}</summary><div class="state-links">')
 for v in ['a','b']:
  for theme in ['paper','night']:
   parts.append(f'<a href="{v}.html?theme={theme}&state={sid}">{v.upper()} · {theme.title()} · interactive</a>')
 parts.append('</div><div class="thumbs">')
 for v in ['a','b']:
  for theme in ['paper','night']:
   parts.append(f'<a href="evidence/{v}-{theme}-{sid}.png"><img loading="lazy" src="evidence/{v}-{theme}-{sid}.png" alt="{v.upper()} {theme} {html.escape(s["label"])}"></a>')
 parts.append('</div>')
 if s.get('sheet'):
  parts.append('<div class="state-links">'+''.join(f'<a href="evidence/{v}-{t}-{sid}-context.png">{v.upper()} · {t.title()} · context PNG</a>' for v in ['a','b'] for t in ['paper','night'])+'</div>')
 parts.append('</details>')
parts.append('''<h2>Separate numeric gate — not this round</h2><p>The app-wide before/after surface gallery remains deferred until after half (a) review. Existing hero, meal and macro figures here retain their current mono face; the new row and sheet use diary body type. This is not approval of the app-wide migration.</p><div class="state-links"><a href="alignment.html">Rendered tabular enabler proof</a><a href="SPEC.md">Implementation-ready specification</a><a href="STATE-MATRIX.md">State/decision matrix</a><a href="sources/copy-inventory.md">Source-copy inventory</a><a href="REPRODUCE.md">Reproduction</a><a href="README.md">Evidence and limitations</a></div><p>Native page flips, calendar, navigation, HealthKit and persistence are not implemented or certified by this HTML study. No P2/P3 policy change.</p></main></body></html>''')
(R/'index.html').write_text(''.join(parts))
proof=head.replace('Morsel #263 · Owner review','EB Garamond · tabular proof')+'''<p class="eyebrow">Enabler only · not the app-wide numeric gallery</p><h1>Diary type, aligned figures.</h1><p>Bundled EB Garamond. Real browser glyph widths are recorded by the verifier. First row: tabular lining figures. Second row: proportional control. Both use the same font file, not a mono fallback.</p><div id="alignment">'''
for size in [14,22,32]:
 proof+=f'<section style="margin:24px 0"><h2>{size}px · tabular vs proportional</h2>'
 for feature in ['tnum','pnum']:
  proof+=f'<div class="glyph-line" data-feature="{feature}" data-size="{size}" style="font-family:Garamond;font-size:{size}px;font-variant-numeric:normal;font-feature-settings:\'{feature}\' 1,\'lnum\' 1;white-space:nowrap">'
  proof+=''.join(f'<span class="digit" style="display:inline-block;border-bottom:1px solid var(--inkline)">{n}</span>' for n in range(10))
  proof+=f' <small>{feature}</small></div>'
 proof+='</section>'
proof+='''<div class="num" style="font-size:32px;display:inline-grid;text-align:right;border-left:1px solid var(--inkline);padding-left:20px"><span>1,111</span><span>2,126</span><span>2,426</span><span>8,888</span></div><p>Targets above are the owner’s example states plus digit-alignment specimens. They are not amount suggestions.</p></div><a href="index.html">Back to review</a><script>if(new URLSearchParams(location.search).get('theme')==='night')document.documentElement.classList.add('night')</script></main></body></html>'''
(R/'alignment.html').write_text(proof)
print(f'Built 2 candidates, gallery of {len(states)} states and font alignment lab')
