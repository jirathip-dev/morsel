#!/usr/bin/env python3
"""Confirm author completion receipts against actual SVG bytes before rendering."""
import argparse
import json
import re
from pipeline import ROOT, LIB, DEFAULT_PRODUCT, entries, read, sha, save


def main(batch):
    ids=[e['id'] for e in entries(batch)]
    receipts=sorted((DEFAULT_PRODUCT/'.lane-logs').glob(f'author-b{batch}-*.json'))
    reported=set()
    for path in receipts:
        reported.update(re.findall(r'(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])',json.dumps(read(path))))
    actual={i:sha(LIB/f'sources/{i}.svg') for i in ids if (LIB/f'sources/{i}.svg').is_file()}
    missing=[i for i in ids if i not in actual or actual[i] not in reported]
    result={'batch':batch,'status':'WAITING' if missing else 'PASS','receipt_count':len(receipts),'expected_id_count':len(ids),'frozen_id_count':len(ids)-len(missing),'missing_or_changed_ids':missing,'initial_source_sha256':actual,'meaning':'Initial author freeze only; any later parent visual correction has separate revision evidence.'}
    if not missing:
        save(ROOT/f'batch-{batch}/author-freeze.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='initial_source_sha256'}))
    return 75 if missing else 0


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--batch',type=int,choices=(4,5),required=True)
    raise SystemExit(main(ap.parse_args().batch))
