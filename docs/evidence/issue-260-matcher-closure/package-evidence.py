#!/usr/bin/env python3
"""Package public issue fixtures and aggregate-only private coverage.

Uses existing Pillow for ICC-aware pixel checks; never loads the private corpus.
Raw private runs remain in .lane-logs/. Run after run-native.py completes.
"""
import collections
import hashlib
import io
import json
from pathlib import Path
import re
import shutil

from PIL import Image, ImageCms, ImageDraw

DEST = Path(__file__).resolve().parent
ROOT = DEST.parents[2]
LOGS = ROOT / ".lane-logs"
LABEL = "native-closure"


def save(name, value):
    (DEST / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def srgb(path):
    image = Image.open(path)
    profile = image.info.get("icc_profile")
    if profile:
        return ImageCms.profileToProfile(image.convert("RGB"), ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                                         ImageCms.createProfile("sRGB"), outputMode="RGB")
    return image.convert("RGB")


def main():
    receipt = json.loads((LOGS / (LABEL + ".json")).read_text())
    assert receipt["raw_exit"] == 0 and not receipt["timed_out"]
    text = (LOGS / (LABEL + ".log")).read_text()
    records = [json.loads(line.split("ISSUE266_RESOLVER ", 1)[1]) for line in text.splitlines()
               if line.startswith("ISSUE266_RESOLVER ")]
    assert len(records) == 48
    indexed = {(row["theme"], row["case"]): row for row in records}
    assert len(indexed) == 48
    cases = sorted({row["case"] for row in records})
    assert len(cases) == 24
    for case in cases:
        assert indexed["paper", case]["actual"] == indexed["night", case]["actual"]
    save("named-results.json", records)  # Public issue fixtures only, not private coverage rows.
    coverage = re.findall(r"^ISSUE260_COVERAGE (.+)$", text, re.MULTILINE)
    assert len(coverage) == 1
    coverage = json.loads(coverage[0])
    provenance = json.loads((LOGS / "coverage-provenance.json").read_text())
    assert provenance["distinct_names"] == coverage["distinct_names"]
    assert sum(coverage["counts"].values()) == coverage["distinct_names"]
    assert digest(ROOT / "app/Sources/Morsel/FoodArtwork.swift") == provenance["resolver_sha256"]
    assert digest(ROOT / "app/Resources/FoodArt/catalog.json") == provenance["catalog_sha256"]
    coverage["percentages"] = {key: round(100 * count / coverage["distinct_names"], 2)
                               for key, count in coverage["counts"].items()}
    coverage["provenance"] = provenance
    coverage["native_receipt"] = receipt
    save("coverage-aggregate.json", coverage)

    attachments = LOGS / (LABEL + "-attachments")
    exported = json.loads((attachments / "manifest.json").read_text())
    rendered = DEST / "rendered"
    rendered.mkdir(exist_ok=True)
    manifest = []
    for group in exported:
        for attachment in group["attachments"]:
            name = attachment["suggestedHumanReadableName"].split("_0_", 1)[0]
            if not (name.startswith("266-") or name in ["paper-kale-qualified-detail-art", "night-kale-qualified-detail-art"]):
                continue
            assert not attachment["isAssociatedWithFailure"]
            file = rendered / (name + ".png")
            shutil.copyfile(attachments / attachment["exportedFileName"], file)
            image = srgb(file)
            assert image.size == (1179, 2556)
            ground = collections.Counter(image.resize((100, 200), Image.Resampling.NEAREST).getdata()).most_common(1)[0][0]
            expected = (42, 38, 31) if "night" in name else (255, 247, 232)
            assert all(abs(actual - target) <= 2 for actual, target in zip(ground, expected)), (name, ground)
            manifest.append(dict(file=file.name, sha256=digest(file), dimensions=list(image.size), ground=list(ground),
                                 test=group["testIdentifier"], device=attachment["deviceName"], udid=attachment["deviceId"]))
    assert len(manifest) == len({row["file"] for row in manifest}) == 51
    assert len([row for row in manifest if row["file"].startswith("266-")]) == 49
    save("rendered-manifest.json", sorted(manifest, key=lambda row: row["file"]))
    box = (130, 640, 320, 790)

    def cell(theme, case):
        return srgb(rendered / f"266-{theme}-{case}.png").crop(box).tobytes()

    checks = {}
    same = [("half-rice", "white-rice"), ("rice-qualified", "white-rice"), ("qualified-pasta", "linguine"),
            ("kana", "chinese-kale"), ("iced-americano", "americano"), ("pork-gravy", "unknown"),
            ("shared-plate", "unknown"), ("generic-noodles", "unknown")]
    different = [("half-rice", "unknown"), ("qualified-pasta", "unknown"), ("brown-gravy", "unknown"),
                 ("chinese-kale", "unknown"), ("americano", "coffee-cake"), ("milk-tea", "boba-tea"),
                 ("pad-thai", "noodles")]
    for theme in ["paper", "night"]:
        for left, right in same:
            checks[f"{theme}:{left}={right}"] = cell(theme, left) == cell(theme, right)
        for left, right in different:
            checks[f"{theme}:{left}!={right}"] = cell(theme, left) != cell(theme, right)
        sheet = Image.new("RGB", (1575, 1320), "white")
        draw = ImageDraw.Draw(sheet)
        for index, case in enumerate(cases):
            x_pos, y_pos = (index % 3) * 525, (index // 3) * 165
            row = srgb(rendered / f"266-{theme}-{case}.png").crop((80, 590, 1130, 875)).resize((525, 143))
            sheet.paste(row, (x_pos, y_pos + 22))
            draw.text((x_pos + 4, y_pos + 4), case, fill="black")
        sheet.save(DEST / f"row-contact-{theme}.png")
    for case in cases:
        checks[f"themes-differ:{case}"] = cell("paper", case) != cell("night", case)
    assert all(checks.values()), [key for key, value in checks.items() if not value]
    save("rendered-audit.json", dict(cell_box=list(box), checks=checks, checks_passed=len(checks),
                                     captured_frames=51, named_case_and_today_frames=49,
                                     contacts={theme: digest(DEST / f"row-contact-{theme}.png") for theme in ["paper", "night"]}))
    print(json.dumps(dict(coverage=coverage["counts"], percentages=coverage["percentages"],
                          named_records=len(records), statuses=dict(collections.Counter(row["status"] for row in records)),
                          published_frames=len(manifest), named_and_today_frames=49, pixel_checks=len(checks)), indent=2))


if __name__ == "__main__":
    main()
