#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  printf 'error: rsvg-convert is required (brew install librsvg)\n' >&2
  exit 1
fi

variants=(v1-spec-exact v2-bolder-bite v3-night-field-stamp)
sizes=(1024 180 120 60)

for variant in "${variants[@]}"; do
  for size in "${sizes[@]}"; do
    rsvg-convert -w "$size" -h "$size" -o "${variant}-${size}.png" "${variant}.svg"
  done
done

rsvg-convert -w 2048 -h 980 -o "issue-147-comparison-2048.png" "issue-147-comparison.svg"
python3 verify.py --write-manifest
