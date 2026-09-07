#!/usr/bin/env python3
"""Build the #168 canonical evidence from the design-output generator.

The canonical copies under docs/design/evidence/issue-168/ are produced by the
deterministic generator in ~/design-output/morsel/168-calendar-diary/ — never
edit files here directly.

Run:  PYTHONDONTWRITEBYTECODE=1 python3 tools/build_evidence.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

GEN = Path.home() / "design-output" / "morsel" / "168-calendar-diary"
HERE = Path(__file__).resolve().parent          # .../docs/design/tools
DESIGN = HERE.parent                            # .../docs/design
EVIDENCE = DESIGN / "evidence" / "issue-168"


def sh(cmd: list[str], cwd: Path) -> None:
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"{' '.join(cmd)} failed:\n{r.stdout}\n{r.stderr}")


def main() -> None:
    if not GEN.exists():
        raise SystemExit(f"generator not found: {GEN}")
    sh(["python3", "tools/build168.py"], GEN)
    sh(["python3", "tools/render168.py"], GEN)
    sh(["python3", "tools/verify168.py"], GEN)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    for png in GEN.glob("*.png"):
        shutil.copy2(png, EVIDENCE / png.name)
    for extra in ("README.md", "manifest.sha256"):
        shutil.copy2(GEN / extra, EVIDENCE / extra)
    print(f"evidence package refreshed: {EVIDENCE}")
    print(f"files: {len(list(EVIDENCE.iterdir()))}")


if __name__ == "__main__":
    main()
