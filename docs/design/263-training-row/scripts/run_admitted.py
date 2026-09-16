#!/usr/bin/env python3
"""Retry only DEFER (75), at most ten bounded 60s admission windows."""
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[1]
for attempt in range(1,11):
    print(f'Admission window {attempt}/10',flush=True)
    result=subprocess.run(['node',str(root/'scripts/verify.mjs'),*sys.argv[1:],'--resume'],cwd=root)
    if result.returncode!=75:sys.exit(result.returncode)
print('Render still blocked. No bypass; request a quiet host window.',flush=True)
sys.exit(75)
