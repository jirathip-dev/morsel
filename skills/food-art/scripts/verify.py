#!/usr/bin/env python3
"""Asset contract verification, independent of successful build exit."""
import json, re, hashlib
from pathlib import Path
from xml.etree import ElementTree as ET
from PIL import Image
from library import ART, SIZES, valid, PALETTE, NIGHT

def verify():
    catalog=json.loads((ART/'catalog.json').read_text()); assets=catalog['assets']
    assert catalog['schema_version']==1
    ids=[a['id'] for a in assets]; assert len(ids)==len(set(ids))
    assert len(assets)>=16 and sum(a['kind']=='food' for a in assets)>=12
    assert sum(a['kind']=='fallback' for a in assets)==4
    assert {'grains','protein','produce','drinks','soup'} <= {a['category'] for a in assets}
    assert set(ids)=={p.stem for p in (ART/'sources').glob('*.json')}
    aliases=[]; pngs=[]; svgs=[]
    for a in assets:
        src=ART/a['source']; spec=json.loads(src.read_text());valid(spec)
        for field in ('id','name','aliases','category','kind','description'):assert a[field]==spec[field],field
        aliases += [v.casefold() for v in a['aliases']]
        assert a['dimensions']==[512,512] and 'not a meal photo' in a['provenance']['meaning']
        assert len(a['masters'])==2 and len(a['exports'])==6
        for rel in [a['source']]+a['masters']+a['exports']:
            assert (ART/rel).resolve().is_relative_to(ART.resolve()), 'path escape'
        for theme in ('paper','night'):
            rel=f'masters/{a["id"]}-{theme}.svg'; assert rel in a['masters'];svgs.append(rel)
            text=(ART/rel).read_text(); root=ET.fromstring(text)
            assert root.attrib['viewBox']=='0 0 256 256'
            assert not re.search(r'<(?:script|image|foreignObject|rect)\b|(?:href=)|https?://(?!www.w3.org)',text)
            assert set(re.findall(r'#[A-Fa-f0-9]{6}',text)) <= set((PALETTE if theme=='paper' else NIGHT).values())
            for size in SIZES:
                rel=f'exports/{a["id"]}-{theme}-{size}.png'; assert rel in a['exports'];pngs.append(rel)
                im=Image.open(ART/rel); assert im.mode=='RGBA' and im.size==(size,size)
                alpha=im.getchannel('A'); box=alpha.getbbox(); assert box, 'blank'
                assert all(alpha.getpixel(pt)==0 for pt in [(0,0),(size-1,0),(0,size-1),(size-1,size-1)])
                assert min(box[0],box[1],size-box[2],size-box[3])>=size*.07, ('padding',rel,box)
                assert .07 < sum(1 for v in alpha.get_flattened_data() if v>20)/(size*size)<.65, ('coverage',rel)
        assert len({hashlib.sha256((ART/p).read_bytes()).hexdigest() for p in a['masters']})==2
    assert len(aliases)==len(set(aliases)), 'duplicate aliases'
    assert set(pngs)=={str(p.relative_to(ART)) for p in (ART/'exports').glob('*')}
    assert set(svgs)=={str(p.relative_to(ART)) for p in (ART/'masters').glob('*')}
    for p in ART.rglob('*'):
        assert p.name!='.DS_Store' and p.suffix not in ('.pyc','.pyo','.tmp','.bak') and p.name!='__pycache__'
    for name in ('gallery-paper.html','gallery-night.html','phone-paper.html','phone-night.html','index.html'):
        text=(ART/name).read_text()
        for rel in re.findall(r'(?:src|href)="([^"]+)"',text): assert (ART/rel).exists(),(name,rel)
        assert 'photo' in text.lower()
    return {'status':'PASS','assets':len(assets),'foods':sum(a['kind']=='food' for a in assets),'fallbacks':4,'editable_masters':len(svgs),'transparent_pngs':len(pngs),'sizes':list(SIZES),'checks':['IDs, aliases, required categories','catalog/source parity and provenance','complete unique paths and no unexpected exports','XML, restricted palette, no embedded images/scripts','RGBA, dimensions, nonblank silhouettes, alpha padding','gallery local links and honest fixture labeling','no transient files']}
if __name__=='__main__':print(json.dumps(verify(),indent=2))
