#!/usr/bin/env python3
"""Issue #229 evidence composition: pair each approved Variant A reference
capture with the native capture of the same state.

    python3 docs/evidence/issue-229-native-parity-a/tools/compose-side-by-side.py <native-dir> <out-dir>

Native captures arrive from the UI-test run at @3x device pixels (1170×2532
for the 390×844 pt lane simulator); the approved A references are 390×844.
Both are scaled to a common height so the pair reads as one comparison.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

STATES = {
    "rows-top": ("a-{theme}.png", "{theme}-rows-top.png"),
    "rows-lower": (None, "{theme}-rows-lower.png"),
    "detail": ("a-{theme}-detail.png", "{theme}-detail.png"),
    "edit": ("a-{theme}-detail.png", "{theme}-edit.png"),
    "save-pending": ("a-{theme}-save-pending.png", "{theme}-save-pending.png"),
    "save-failure": ("a-{theme}-save-failure.png", "{theme}-save-failure.png"),
    "updated": ("a-{theme}-updated.png", "{theme}-updated.png"),
}
THEMES = {"paper": "paper", "night": "night"}
HEIGHT = 844


def load_scaled(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGB")
    ratio = HEIGHT / image.height
    return image.resize((round(image.width * ratio), HEIGHT), Image.LANCZOS)


def main() -> int:
    native_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    reference_dir = Path(__file__).resolve().parent.parent / "reference" / "evidence"
    composed = 0
    for theme in THEMES:
        for state, (reference_name, native_name) in STATES.items():
            native_path = native_dir / native_name.format(theme=theme)
            if not native_path.exists():
                print(f"missing native capture: {native_path}")
                continue
            native = load_scaled(native_path)
            if reference_name:
                reference = load_scaled(reference_dir / reference_name.format(theme=theme))
                canvas = Image.new("RGB", (reference.width + native.width + 12, HEIGHT + 26), (255, 255, 255))
                canvas.paste(reference, (0, 26))
                canvas.paste(native, (reference.width + 12, 26))
                label_left = "approved A reference"
            else:
                canvas = Image.new("RGB", (native.width, HEIGHT + 26), (255, 255, 255))
                canvas.paste(native, (0, 26))
                label_left = "native only (no A reference for this state)"
            draw = ImageDraw.Draw(canvas)
            draw.text((4, 6), f"issue #229 · {state} · {theme} — {label_left}  |  native (simulator)", fill=(0, 0, 0))
            out_path = out_dir / f"{state}-{theme}.png"
            canvas.save(out_path)
            composed += 1
            print(f"wrote {out_path}")
    print(f"composed={composed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
