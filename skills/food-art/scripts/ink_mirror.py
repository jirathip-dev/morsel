#!/usr/bin/env python3
"""Copy only this design bundle into the standing design-output archive.

No deletion, pruning, commits, pushes, app files or profile edits. Git archive
commit/push remains an explicit, scoped operator step after source-head review.
"""
import argparse
import json
import shutil
import subprocess
from pathlib import Path
from ink_library import ROOT, OUT, digest, require


def run(destination):
    destination=destination.expanduser().resolve()
    require(destination != ROOT and ROOT not in destination.parents,'mirror must not be inside source worktree')
    roots=['docs/art/food-library','docs/art/food-refinement-197-r1','docs/art/food-library-v2','skills/food-art']
    copied=[]
    for rel in roots:
        for source in sorted((ROOT/rel).rglob('*')):
            if not source.is_file() or '__pycache__' in source.parts or source.name=='.DS_Store':
                continue
            target=destination/source.relative_to(ROOT)
            target.parent.mkdir(parents=True,exist_ok=True)
            if not target.exists() or digest(target)!=digest(source):
                shutil.copy2(source,target)
                copied.append(str(source.relative_to(ROOT)))
            require(digest(target)==digest(source),'mirror checksum mismatch')
    head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    (destination/'SOURCE_HEAD.txt').write_text(head+'\n')
    (destination/'README.md').write_text('# Morsel #197 · approved ink/wash extension\n\nFull existing catalog:13 foods +4 fallbacks. Direction approved; independent fleet review/staging pending. No app integration.\n\nSource branch: `design-197-food-library`\n\nExact Morsel head: `'+head+'`\n\n[Refined gallery](docs/art/food-library-v2/index.html) · [Paper sheet](docs/art/food-library-v2/contact-paper.png) · [Night sheet](docs/art/food-library-v2/contact-night.png)\n\n[Handoff, commands and caveats](docs/art/food-library-v2/README.md). First delivery and R1 controls remain in their original folders.\n\nThe source and this mirror retain the generators, verifiers, historical controls, editable masters and proof assets. This archive is a design review surface, not deployed app UI.\n')
    print(json.dumps({'source_head':head,'destination':str(destination),'copied_files':len(copied),'raw_exit':0},indent=2))

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('destination',type=Path)
    run(ap.parse_args().destination)
