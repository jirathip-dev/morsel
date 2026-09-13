#!/bin/sh
# No package resolution, browser install, native build or parallel rendering.
set -eu
cd "$(dirname "$0")"
python3 run_gates.py
