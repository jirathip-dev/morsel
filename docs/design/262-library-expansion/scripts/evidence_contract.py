"""Closed-set capture/rebuild evidence checks; no vacuous success on empty lists."""

def browser_cases(p, batch):
    ids=[e['id'] for e in p.entries(batch)]
    cases=[]
    for theme in p.THEMES:
        for n,start in enumerate(range(0,len(ids),5),1):
            page=f'phone-{n:02d}-{theme}'
            cases.append((page,390,844,ids[start:start+5],f'batch-{batch}/proofs/{page}.png'))
        for w,h in ((1440,1000),(390,844)):
            page=f'gallery-{theme}'
            cases.append((page,w,h,ids,f'batch-{batch}/proofs/{page}-{w}.png'))
    return cases


def check_batch(p, batch):
    d=p.ROOT/f'batch-{batch}'
    ids=[e['id'] for e in p.entries(batch)]
    cases=browser_cases(p,batch)
    expected={rel:(page,w,h,want) for page,w,h,want,rel in cases}
    b=p.read(d/'browser.json')
    p.require(b['status']=='PASS' and b['raw_exit']==0,'browser did not pass')
    p.require(b['capture_count']==len(cases)==len(b['captures']),'browser capture count differs')
    p.require({c['capture'] for c in b['captures']}==set(expected),'browser viewport/page matrix differs')
    inputs={d/f'{page}.html' for page,_,_,_,_ in cases}|{d/'proof.css'}
    inputs.update((p.LIB/'fonts').glob('*.ttf'))
    inputs.update(p.LIB/f'exports/{iid}-{theme}-{size}.png' for iid in ids for theme in p.THEMES for size in (64,192))
    pins=b.get('inputs_sha256',{})
    p.require(set(pins)=={str(f.relative_to(p.ROOT)) for f in inputs},'browser input pin set differs')
    p.require(all(p.sha(p.ROOT/rel)==h for rel,h in pins.items()),'stale browser input')
    p.require(b['phone_catalog_coverage']=={theme:ids for theme in p.THEMES},'phone coverage differs')
    for c in b['captures']:
        page,w,h,want=expected[c['capture']]
        dom=c['dom']
        p.require(c['page']==page and c['raw_exit']==0,'capture page/exit differs')
        p.require(dom['viewport']==[w,h] and dom['ids']==want,'capture viewport/identities differ')
        p.require(not dom['overflow'] and dom['images'] and dom['fonts'],'capture DOM checks failed')
        p.require(dom['minHitWidth']>=44 and dom['minHitHeight']>=44,'capture hit targets fail')
        if page.startswith('phone-'):
            p.require(dom['allRowsVisible'] and dom['imageSizes']==[[64,64]]*len(want),'native phone rows fail')
        elif batch == 5:
            p.require(dom.get('padThaiAlt') == p.PAD_THAI_DESCRIPTION, 'Pad thai browser alt misdescribes art')
        image=p.ROOT/c['capture']
        p.require(p.sha(image)==c['sha256'] and p.Image.open(image).size==(w,h),'capture bytes/dimensions differ')
    r=p.read(d/'reproducibility.json')
    outputs={rel for iid in ids for rel in p.asset_paths(iid)}
    p.require(r['status']=='PASS' and r['raw_exit']==0 and r['batch']==batch,'rebuild status/batch differs')
    p.require(r['files_compared']==len(outputs)==len(r['sha256']),'rebuild count differs')
    p.require(set(r['sha256'])==outputs,'rebuild output set differs')
    for rel,pair in r['sha256'].items():
        p.require(pair['equal'] is True and p.sha(p.LIB/rel)==pair['committed']==pair['clean'],'stale clean rebuild: '+rel)


def check_index(p, through):
    v=p.read(p.ROOT/'evidence/index/verification.json')
    expected={f'evidence/index/index-{w}.png':(w,h) for w,h in ((390,844),(1440,1000))}
    pins={p.ROOT/'index.html',*(p.LIB/'fonts').glob('*.ttf')}
    p.require(v['status']=='PASS' and v['capture_count']==2==len(v['captures']),'index capture count/status differs')
    p.require({c['capture'] for c in v['captures']}==set(expected),'index viewport set differs')
    p.require(set(v['inputs_sha256'])=={str(f.relative_to(p.ROOT)) for f in pins},'index input pin set differs')
    p.require(all(p.sha(p.ROOT/rel)==h for rel,h in v['inputs_sha256'].items()),'stale index inputs')
    for c in v['captures']:
        w,h=expected[c['capture']]
        dom=c['dom']
        p.require(dom['viewport']==[w,h] and dom['ids']==[f'batch-{b}' for b in range(1,through+1)],'index viewport/batches differ')
        p.require(c['raw_exit']==0 and not dom['overflow'] and dom['fonts'] and dom['minHitWidth']>=44 and dom['minHitHeight']>=44,'index DOM checks fail')
        image=p.ROOT/c['capture']
        p.require(p.sha(image)==c['sha256'] and p.Image.open(image).size==(w,h),'index capture hash/dimensions differ')
