#!/usr/bin/env python3
"""Visible render-owner entrypoint for sibling pgrep coordination (not a lock)."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).with_name('run_batch.py')), run_name='__main__')
