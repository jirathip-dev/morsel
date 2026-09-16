#!/usr/bin/env python3
"""Generate a restrained Compare index from completed-batch evidence."""
from html import escape
from pipeline import ROOT, read, require
from proofs import CSS, AUDIT


def main():
    data=read(ROOT/'ROLLUP.json')
    rows=[]
    for b in data['batches']:
        n=b['batch']
        targets=[(f'batch-{n}/index.html','Open batch'),(f'batch-{n}/contact-paper.png','Paper sheet'),(f'batch-{n}/contact-night.png','Night sheet'),(f'batch-{n}/optical-both.png','Native-size proof')]
        require(all((ROOT/p).is_file() for p,_ in targets),'index target missing')
        note='General coverage only · 0 observed rows' if n==5 else 'Observation counts and limits in the batch report'
        links=''.join(f'<a href="{escape(p)}">{label}</a>' for p,label in targets)
        rows.append(f'<section class="batchline" data-id="batch-{n}"><div><span class="eyebrow">BATCH {n:02}</span><h2>{b["new_foods"]} food studies</h2><p>{note}</p></div><nav aria-label="Batch {n} evidence">{links}</nav></section>')
    css=CSS.replace('../library/','library/')+'''main{max-width:1100px;padding:36px 28px}header{padding-bottom:22px;border-bottom:1px solid #8B7355}header p{margin:12px 0;max-width:660px}h1{font-size:46px}.batchline{display:grid;grid-template-columns:1fr 1fr;gap:24px;padding:24px 0;border-bottom:1px solid #8B7355}.batchline p{font-size:16px;margin:8px 0}.batchline nav{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;align-content:center;margin:0}.batchline nav a{justify-content:center;text-align:center;font-size:18px}footer{margin-top:24px;font-size:16px}footer a{display:inline-flex;min-width:44px;min-height:44px;align-items:center;margin-right:20px}@media(max-width:650px){main{padding:24px 22px}h1{font-size:39px}.batchline{grid-template-columns:1fr;gap:10px;padding:20px 0}}'''
    body=f'''<header><span class="eyebrow">MORSEL / INK &amp; WASH / COMPARE</span><h1>A larger food library</h1><p>{data['new_food_identities']} new food studies across {len(data['batches'])} completed batches. Same ink, wash and warm palette as the shipped collection.</p><p>Subject list approved. Pixels await owner review.<br>Illustrations—not meal photos, portions or ingredient evidence.</p></header><div class="batchlist">{''.join(rows)}</div><footer><p>Original shipped art is unchanged. No app integration or bundling.</p><a href="ROLLUP.md">Evidence &amp; limits</a><a href="README.md">Reproduce</a><a href="INTEGRATION-HANDOFF.md">Integration boundary</a></footer>'''
    (ROOT/'index.html').write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Morsel — ink/wash study library</title><style>'+css+'</style></head><body><main>'+body+'</main>'+AUDIT+'</body></html>\n')
    print({'index':'generated','through_batch':data['through_batch'],'linked_batches':len(rows)})


if __name__=='__main__':
    main()
