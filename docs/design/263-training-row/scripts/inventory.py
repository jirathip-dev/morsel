#!/usr/bin/env python3
"""Exhaustive reviewable path index; hashes live in the root manifest."""
from pathlib import Path
R=Path(__file__).resolve().parents[1]
paths=sorted({str(p.relative_to(R)) for p in R.rglob('*') if p.is_file()}|{'ARTIFACTS.md','manifest.json'})
lines=['# Complete artifact path index','', 'Canonical root: `/Users/jirathip/design-output/morsel/263-training-row/`.','Mirror root: `/Users/jirathip/.herdr/worktrees/morsel/design-263-training-row/docs/design/263-training-row/`.','',f'{len(paths)} files including this index and the root manifest. Each relative path below exists under both roots after mirror verification. Exact byte sizes and SHA-256 values are in `manifest.json` (which excludes only itself).','','| Relative path |','|---|']
lines.extend('| `'+p+'` |' for p in paths)
(R/'ARTIFACTS.md').write_text('\n'.join(lines)+'\n')
print('Indexed',len(paths),'artifact paths')
