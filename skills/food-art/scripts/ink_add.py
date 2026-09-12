#!/usr/bin/env python3
"""Register one future refined study without repainting existing foods.

The issue-197 delivery remains closed at 17. This opt-in addition command is
exercised only in a temporary fixture for this round, not the delivered set.
"""
import argparse
import json
import re
from pathlib import Path
from ink_library import OUT, THEMES, subjects, compile_svg, build, verify, dump, write, require


def add(spec, svg_text, out=OUT):
    entries=subjects(out)
    require(set(spec)=={'id','name','aliases','kind','category','description'},'exact metadata fields required')
    require(isinstance(spec['id'],str) and re.fullmatch(r'[a-z][a-z0-9-]{2,63}',spec['id']),'invalid stable ID')
    require(spec['id'] not in {a['id'] for a in entries},'ID exists; edit source and build instead')
    require(spec['kind'] in ('food','fallback'),'invalid kind')
    require(spec['category'] in ('produce','protein','grains','drinks','soup'),'invalid category')
    require(all(isinstance(spec[k],str) and spec[k] for k in ('name','description')),'missing description/name')
    require(isinstance(spec['aliases'],list) and spec['aliases'] and all(isinstance(a,str) and a for a in spec['aliases']),'invalid aliases')
    dest=out/f'sources/{spec["id"]}.svg'
    require(not dest.exists(),'source collision')
    for theme in THEMES:
        compile_svg(svg_text,(out/'wash-defs.svginc').read_text(),theme)
    write(dest,svg_text)
    dump(out/'subjects.json',{'assets':sorted(entries+[spec],key=lambda a:a['id'])})
    result=build(out)
    verify(out,allow_additions=True)
    return result


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('metadata',type=Path)
    ap.add_argument('svg',type=Path)
    args=ap.parse_args()
    print(json.dumps(add(json.loads(args.metadata.read_text()),args.svg.read_text()),indent=2))
