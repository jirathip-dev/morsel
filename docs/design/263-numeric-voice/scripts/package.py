#!/usr/bin/env python3
"""Package raw captures into unscaled contacts; generate evidence docs."""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json,subprocess,hashlib
R=Path(__file__).resolve().parents[1]
C=json.loads((R/'coverage.json').read_text());V=json.loads((R/'evidence/verification.json').read_text())
assert V['status']=='PASS'
subprocess.run(['python3',str(R/'scripts/admit.py')],check=True)
f=ImageFont.truetype(str(R/'assets/fonts/IBMPlexMono-Regular.ttf'),14)
# Native-size, two-column group contact sheets. Labels are external to captures.
for group,label in C['groups'].items():
    pages=[p for p in C['pages'] if p['group']==group]
    for theme in ['paper','night']:
        sheet=Image.new('RGB',(800,68+len(pages)*882),'#FFF7E8');d=ImageDraw.Draw(sheet)
        d.text((10,10),label+' / '+theme,fill='#2A261F',font=f)
        d.text((10,34),'BEFORE / AFTER — source-derived browser excerpts',fill='#2A261F',font=f)
        for i,p in enumerate(pages):
            y=68+i*882;d.text((10,y),p['id'],fill='#2A261F',font=f)
            for j,version in enumerate(['before','after']):
                im=Image.open(R/f'evidence/{p["id"]}-{theme}-{version}.png');assert im.size==(390,844)
                sheet.paste(im,(10+j*390,y+24))
        sheet.save(R/f'evidence/contact-{group}-{theme}.png')
# Two pages per review plate; all four actual before/after/theme captures at 1:1.
plates=[]
for offset in range(0,len(C['pages']),2):
    batch=C['pages'][offset:offset+2];im=Image.new('RGB',(1580,len(batch)*884+30),'#FFF7E8');d=ImageDraw.Draw(im)
    for i,p in enumerate(batch):
        y=30+i*884;d.text((10,y-22),p['id']+' | Paper BEFORE · Paper AFTER · Night BEFORE · Night AFTER',fill='#2A261F',font=f)
        for j,(theme,version) in enumerate([(t,v) for t in ['paper','night'] for v in ['before','after']]):
            im.paste(Image.open(R/f'evidence/{p["id"]}-{theme}-{version}.png'),(10+j*390,y))
    name=f'evidence/review-{offset//2+1:02}.png';im.save(R/name);plates.append(dict(file=name,pages=[p['id'] for p in batch]))
(R/'evidence/review-plates.json').write_text(json.dumps(plates,indent=2)+'\n')
# Raw text widths alongside the JSON, no fabricated aggregates.
A=json.loads((R/'evidence/alignment.json').read_text());lines=['renderer\ttheme\tweight\tsize_px\tfeature\tdigit_0_to_9_advance_px\tspread_px']
for a in A:
    for x in a['lines']:lines.append('\t'.join(['Chromium DOM Range',a['theme'],str(a['weight']),str(x['size']),x['feature'],','.join(map(str,x['widths'])),str(x['spread'])]))
(R/'evidence/alignment.raw.tsv').write_text('\n'.join(lines)+'\n')
# Source coverage includes every discovered site, explicitly counted exclusions, and reuse.
audit=json.loads((R/'sources/independent-audit.json').read_text());mapped={s['id']:s for s in C['sites']}
text=['# Exhaustive source coverage','',f'Pinned base: `{audit["observed_head"]}`.','',f'{len(C["pages"])} source-derived specimen pages × Paper/Night × before/after. {len(C["sites"])} discovered font-use/field-binding lines across {len(set(s["file"] for s in C["sites"]))} files; {sum(bool(s["pages"]) for s in C["sites"])} mapped to visible excerpts; {len(C["exclusions"])} structural/non-text exclusions. These are not counts of native screenshots.','', 'The issue lists five affected bullets despite saying six. Weight/chart labels are split out from rows/columns; technical strings are separate. Shared sites overlap groups; never add group site counts as unique totals.','']
for group,label in C['groups'].items():
    pp=[p for p in C['pages'] if p['group']==group];ss={s for p in pp for s in p['sites']}
    text += ['## '+label,'',f'{len(pp)} pages; {len(ss)} unique source IDs in this group.','']
    for p in pp:text += [f'- [{p["title"]}]({p["id"]}.html?theme=paper&version=after): '+', '.join('`'+s+'`' for s in p['sites'])+'. '+p['note']]
    text+=['']
text+=['## Every matching line','', '| Source | Status | Rendered page(s) / reason |','|---|---|---|']
for s in C['sites']:text.append(f'| {s["file"]}:{s["line"]} | {s["disposition"]} | '+(', '.join(s['pages']) or s['reason'])+' |')
text+=['','## Expanded reuse inventory','', 'Every static helper host from the independent read-only source audit is listed below. A shared specimen demonstrates its font role once; reuse mapping does not claim an in-situ native screenshot of every host.','']
for s in audit['font_sites']:
    instances=s.get('reuse_instances',[])
    if not instances:continue
    sid=Path(s['file']).stem+'-'+str(s['line']);m=mapped.get(sid)
    text += ['### '+s['id'],'',s['visible_purpose'], 'Specimen(s): '+(', '.join(m['pages']) if m and m['pages'] else 'not a visible text instance; see exclusions')+'.','']
    for i in instances:text.append('- `'+i['location']+'` — '+i['purpose']+'; '+i.get('repeat','')+('. Host: '+i['surface'] if 'surface' in i else ''))
    text+=['']
(R/'COVERAGE.md').write_text('\n'.join(line.rstrip() for line in text).rstrip()+'\n')
summary={g:dict(pages=sum(p['group']==g for p in C['pages']),captures=sum(p['group']==g for p in C['pages'])*4) for g in C['groups']}
(R/'evidence/counts.json').write_text(json.dumps(dict(groups=summary,pages=len(C['pages']),phone_captures=len(C['pages'])*4,alignment_captures=8,gallery_captures=2,contact_sheets=len(C['groups'])*2,review_plates=len(plates),source_sites=len(C['sites']),rendered_sites=sum(bool(s['pages']) for s in C['sites']),exclusions=len(C['exclusions'])),indent=2)+'\n')
print(json.dumps(dict(contact_sheets=len(C['groups'])*2,review_plates=len(plates),captures=len(V['captures']))))
