# Exercising gallery theme and phone navigation
# Run through browser_exec with ROOT=Path(repository_root) prebound.
import json
import time
from pathlib import Path

art=ROOT/'docs/art/food-library-v2'
results=[]
new_tab((art/'gallery-paper.html').as_uri())
cdp('Page.addScriptToEvaluateOnNewDocument',source="window.__inkErrors=[];addEventListener('error',e=>__inkErrors.push(String(e.message)));addEventListener('unhandledrejection',e=>__inkErrors.push(String(e.reason)))")
cdp('Emulation.setDeviceMetricsOverride',width=1440,height=1000,deviceScaleFactor=1,mobile=False)
goto_url((art/'gallery-paper.html').as_uri())


def inspect(expected,expected_ids,theme):
    for attempt in range(30):
        value=json.loads(js("JSON.stringify({page:location.pathname.split('/').pop(),ready:document.readyState,body:!!document.body,theme:document.body?.className,ids:[...document.querySelectorAll('[data-id]')].map(e=>e.dataset.id),errors:window.__inkErrors||[],fonts:document.fonts?.status,images:[...document.images].every(i=>i.complete&&i.naturalWidth>0),overflow:(document.documentElement?.scrollWidth||0)>innerWidth})"))
        if value['page']==expected and value['body'] and value['ready']=='complete' and value['fonts']=='loaded':
            break
        time.sleep(.15)
    assert value['page']==expected and value['ready']=='complete',value
    assert value['ids']==expected_ids and value['theme']==theme,value
    assert not value['errors'] and value['images'] and not value['overflow'],value
    results.append(value)


ids=[a['id'] for a in json.loads((art/'catalog.json').read_text())['assets']]
inspect('gallery-paper.html',ids,'paper')
js("document.querySelector('a[href=\"gallery-night.html\"]').click()")
inspect('gallery-night.html',ids,'night')
js("document.querySelector('a[href=\"phone-fallbacks-night.html\"]').click()")
cdp('Emulation.setDeviceMetricsOverride',width=390,height=844,deviceScaleFactor=1,mobile=False)
inspect('phone-fallbacks-night.html',['fallback-drinks','fallback-grains','fallback-produce','fallback-protein'],'night phone')
js("document.querySelector('a.back').click()")
inspect('gallery-night.html',ids,'night')
report={'status':'PASS','raw_exit':0,'transitions':['Paper → Night','Night → Fallback phone','Fallback phone → Night gallery'],'observations':results,
        'harness_note':'Initial ad-hoc read raced navigation and saw body=null; retained driver waits for the expected URL/body/load/fonts before asserting. No artifact change was needed.'}
(art/'evidence/interaction.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
