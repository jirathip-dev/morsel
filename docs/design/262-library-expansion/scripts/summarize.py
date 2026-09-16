#!/usr/bin/env python3
"""Aggregate completed batch evidence without inventing account demand or runtime coverage."""
import argparse
from pipeline import ROOT, LIB, read, save, require, entries, COUNTS, sha


def main(through):
    batches=[]
    all_ids=[]
    identities=[]
    for b in range(1, through+1):
        d=ROOT/f'batch-{b}'
        v=read(d/'verification.json')
        c=read(d/'coverage.json')
        r=read(d/'reproducibility.json')
        browser=read(d/'browser.json')
        gates=read(d/'gates.json')
        require(all(x['status']=='PASS' for x in (v,r,browser,gates)), 'unfinished mechanical evidence')
        require('ready for owner review' in (d/'VISUAL-REVIEW.md').read_text().lower(), 'missing visual review')
        foods=[e for e in entries(b) if e['kind']=='food']
        require(len(foods)==COUNTS[b], 'batch food total mismatch')
        for e in foods:
            iid=e['id']
            all_ids.append(iid)
            identities.append({'id':iid,'batch':b,'observed_rows':c['observed_rows_by_added_identity'][iid], 'source_sha256':sha(LIB/f'sources/{iid}.svg'), 'demand':'general-coverage-only; evidence-free for this account' if b==5 else ('observed in frozen aggregate' if c['observed_rows_by_added_identity'][iid] else 'general coverage; zero observed rows'), 'pixel_approval':'pending owner review'})
        batches.append({'batch':b,'new_foods':len(foods),'new_fallbacks':len(entries(b))-len(foods),'cumulative_foods':v['food_count'],'specific_estimate':c['specific'],'specific_delta_rows':c['specific_delta_rows'],'category_fallback_estimate':c['category_fallback'],'browser_captures':len(browser['captures']),'clean_rebuild_files':r['files_compared'],'observed_rows_for_added_ids':sum(c['observed_rows_by_added_identity'].values()),'mechanical_status':'PASS','visual_review':str((d/'VISUAL-REVIEW.md').relative_to(ROOT))})
    require(len(set(all_ids))==len(all_ids)==sum(COUNTS[b] for b in range(1,through+1)), 'duplicate/missing identity')
    final=read(ROOT/f'batch-{through}/verification.json')
    cov=read(ROOT/f'batch-{through}/coverage.json')
    preservation=read(ROOT/f'batch-{through}/shipped-18-before-after.json')
    if through==5:
        reserve=[x for x in identities if x['batch']==5]
        require(len(reserve)==12 and all(x['observed_rows']==0 for x in reserve),'batch5 demand must be evidence-free')
    result={'through_batch':through,'approval':'subject list approved; pixels pending owner review; not integrated', 'new_food_identities':len(all_ids),'total_food_identities':final['food_count'],'total_fallbacks':final['fallback_count'],'total_assets':final['asset_count'],'theme_masters':final['theme_masters'],'png_exports':final['png_exports'],'protected_product_files':preservation['protected_product_files'],'shipped_art_files_byte_identical':preservation['shipped_art_files'],'browser_captures':sum(b['browser_captures'] for b in batches),'clean_rebuild_files':sum(b['clean_rebuild_files'] for b in batches),'coverage_method':cov['method'],'specific_estimate':cov['specific'],'category_fallback_estimate':cov['category_fallback'],'neutral_estimate':cov['neutral'],'batches':batches,'identities':identities}
    save(ROOT/'ROLLUP.json',result)
    lines=['# Cumulative artwork evidence', '', f'Completed through batch {through}. Subject list approved; pixels await owner review. No app/Swift/DB/schema/matcher/catalog integration or bundling.', '', '## Counts', '', f"{result['new_food_identities']} new food identities; {result['total_food_identities']} food identities including the shipped 13; {result['total_fallbacks']} category/neutral fallbacks; {result['total_assets']} assets overall.", f"{result['theme_masters']} themed SVG masters and {result['png_exports']} RGBA PNG exports. {result['clean_rebuild_files']} newly generated files independently rebuilt without cache and SHA-matched. {result['browser_captures']} real-browser captures across the completed batches.", f"The original 18 assets ({result['shipped_art_files_byte_identical']} art files) and {result['protected_product_files']} protected product files remain byte-identical; palette, wash definitions and bundled fonts remain locked.", '', '## Batch coverage estimates', '', 'Frozen qualifier-tolerant design estimator only; NOT the shipped matcher or live application coverage. Private raw names remain outside this package.', '', '| Batch | New foods | Cumulative foods | Estimated specific rows | Added specific rows | Browser captures |', '|---|---:|---:|---:|---:|---:|']
    for b in batches:
        lines.append(f"| [{b['batch']}](batch-{b['batch']}/index.html) | {b['new_foods']} | {b['cumulative_foods']} | {b['specific_estimate']['rows']} | {b['specific_delta_rows']} | {b['browser_captures']} |")
    lines += ['', f"Final estimate: {cov['specific']['distinct']}/{cov['distinct_names']} distinct names and {cov['specific']['rows']}/{cov['total_rows']} rows have a specific study; {cov['category_fallback']['rows']} rows retain a category fallback; {cov['neutral']['rows']} retain neutral. Pending later-study rows: {cov['pending_later_studies']['rows']}.", '', '## Honesty and approval', '', 'Batch 5, when included, is evidence-free for this account (0 observed rows), for general coverage only. Dedicated pad-thai/boba decisions and depiction limits are documented in its report, not inferred from demand.', '', 'Visual review is separate from mechanical validation. Each batch retains actual Paper/Night sheets, 64px phone contexts, 40px diagnostics, original sources, gates and clean-rebuild hashes. All studies remain generic labeled illustrations, not meal photos, portions, ingredient/allergy or nutrition evidence.', '', 'Repository gate caveat: see [HOST-GATES.md](HOST-GATES.md). The one npm test invocation exited 1, with 583 passed / 2 timeout failures and two worker timeouts. No retry, timeout relaxation, or green-suite claim. Typecheck, lint and diff-check exited 0.', '', 'Reproduce with [README.md](README.md); integration boundaries are in [INTEGRATION-HANDOFF.md](INTEGRATION-HANDOFF.md). Per-identity observations and source hashes are in ROLLUP.json. NOT MERGED; no TestFlight dispatch; no live acceptance.', '']
    (ROOT/'ROLLUP.md').write_text('\n'.join(lines))
    print({k:v for k,v in result.items() if k not in ('identities','batches')})


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--through',type=int,choices=range(1,6),required=True)
    main(ap.parse_args().through)
