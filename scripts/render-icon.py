#!/usr/bin/env python3
"""Render and validate the pinned Morsel AppIcon artwork."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

SOURCE_SHA256 = "2cd6c86c5c77cbba33b5aeefa1a7751d9d9b7cd2d696c36625db4241fda653b4"
SOURCE_COMMIT = "7de30e9"
SIZES = {"Icon-20@2x.png": 40, "Icon-20@3x.png": 60,
         "Icon-29@2x.png": 58, "Icon-29@3x.png": 87,
         "Icon-40@2x.png": 80, "Icon-40@3x.png": 120,
         "Icon-60@2x.png": 120, "Icon-60@3x.png": 180, "Icon-1024.png": 1024}
PALETTE = {"#FBFAF6", "#20231E", "#F08A2E", "#F0A63C", "#C0483F"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"not a PNG: {path}")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def validate(source: Path, output: Path) -> None:
    if sha256(source) != SOURCE_SHA256:
        raise SystemExit(f"source checksum mismatch (expected design-output {SOURCE_COMMIT})")
    text = source.read_text(encoding="utf-8")
    if "data-bite=\"top-right\"" not in text or text.count('data-role="eye"') != 2:
        raise SystemExit("V1 face/bite contract failed")
    if "gradient" in text.lower() or "opacity=" in text.lower():
        raise SystemExit("gradient/opacity is not allowed")
    used = {c.upper() for c in re.findall(r"#[0-9a-fA-F]{6}", text)}
    if not used.issubset(PALETTE):
        raise SystemExit(f"off-palette colors: {sorted(used - PALETTE)}")
    for name, size in SIZES.items():
        path = output / name
        if not path.is_file() or png_size(path) != (size, size):
            raise SystemExit(f"wrong or missing dimensions: {path}")
    print(f"ICON PASS: source {SOURCE_COMMIT} sha256={SOURCE_SHA256}")
    for name in SIZES:
        print(f"{name}: {sha256(output / name)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(__file__).parents[1] / "app/IconSource/v1-wrapped-classic.svg")
    parser.add_argument("--output", type=Path, default=Path(__file__).parents[1] / "app/Assets.xcassets/AppIcon.appiconset")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check:
        if shutil.which("rsvg-convert") is None:
            raise SystemExit("rsvg-convert is required")
        args.output.mkdir(parents=True, exist_ok=True)
        for name, size in SIZES.items():
            subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(args.output / name), str(args.source)], check=True)
    validate(args.source, args.output)


if __name__ == "__main__":
    main()
