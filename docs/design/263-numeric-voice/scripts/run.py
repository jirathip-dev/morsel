#!/usr/bin/env python3
"""Retry only admission DEFER; every gate window remains bounded to 60s."""
from pathlib import Path
import subprocess,sys,time
R=Path(__file__).resolve().parents[1]
for attempt in range(1,11):
    print(f'Admission attempt {attempt}/10',flush=True)
    p=subprocess.run(['node',str(R/'scripts/verify.mjs'),*sys.argv[1:]],cwd=R)
    if p.returncode!=75:sys.exit(p.returncode)
    if attempt<10:time.sleep(10)
print('BLOCKED: ten bounded admission windows exhausted',flush=True)
sys.exit(75)
