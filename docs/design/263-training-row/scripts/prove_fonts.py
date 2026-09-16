#!/usr/bin/env python3
"""Artifact-only font/source proofs. No rendering, source edits, or network writes.

Run with fontTools 4.65.0; see sources/README.md for the bounded-cache command.
This is a direct OpenType table probe, NOT a browser/CoreText shaping test.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import subprocess
from pathlib import Path

BASE = "2d87d61e73c6c3db7bd1420294ccf1551232405d"
REPO = Path("/Users/jirathip/.herdr/worktrees/morsel/design-263-training-row")
PROJECT = Path(__file__).resolve().parents[1]
OUT = PROJECT / "sources"
FONT = "app/Fonts/EBGaramond[wght].ttf"
REQUIRED_TAGS = ("tnum", "onum", "lnum", "pnum")
REFERENCE_FILES = [
    "TrainingFuelViews.swift", "TrainingFuelModel.swift", "TrainingFuelContext.swift",
    "TrainingFuelHealthReader.swift", "TrainingFuelHost.swift", "DesignSystem.swift",
    "Views.swift", "DatedTargets.swift",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(REPO), *args])


def blob(path: str) -> bytes:
    return git("show", f"{BASE}:{path}")


def write_json(name: str, value: object) -> None:
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def source_proofs() -> dict:
    assert subprocess.run(["git", "-C", str(REPO), "merge-base", "--is-ancestor", BASE, "HEAD"]).returncode == 0, "Base not retained"
    entries = []
    for record in git("ls-tree", "-r", "-z", "--full-tree", BASE).split(b"\0"):
        if not record:
            continue
        header, path = record.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        entries.append({"path": path.decode(), "mode": mode, "type": kind, "object": oid})
    write_json("tracked-tree.json", {"base": BASE, "entries": entries})
    tracked = {entry["path"]: entry for entry in entries}
    # git grep searches the complete immutable tree, not an app-only glob or
    # working-directory walk. --text includes even binary blobs as candidates.
    grep_args = ["grep", "-l", "-z", "--text", "-F", "monospacedDigit", BASE, "--"]
    result = subprocess.run(["git", "-C", str(REPO), *grep_args], capture_output=True, check=False)
    assert result.returncode in (0, 1), result.stderr.decode()
    candidates = sorted(record.decode().removeprefix(BASE + ":")
                        for record in result.stdout.split(b"\0") if record)
    hits = []
    mentions = []
    expression = re.compile(r"\.\s*monospacedDigit\s*\(\s*\)")
    for path in candidates:
        assert path in tracked
        text = blob(path).decode("utf-8")
        lines = text.splitlines()
        for mention in re.finditer("monospacedDigit", text):
            mentions.append({"path": path, "line": text.count("\n", 0, mention.start()) + 1})
        for match in expression.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            start, end = max(1, line - 6), min(len(lines), line + 6)
            hits.append({"path": path, "line": line, "expression": match.group(),
                         "source_sha256": digest(blob(path)),
                         "context": [{"line": n, "text": lines[n - 1]} for n in range(start, end + 1)]})
    unique_hits = {(hit["path"], hit["line"], hit["expression"]) for hit in hits}
    assert len(unique_hits) == len(hits), "Duplicate site identity"
    # Context at this base was manually reviewed: all mentions are actual Swift
    # call sites. A future unexpected mention fails closed instead of disappearing.
    assert len(mentions) == len(hits), "Non-call mention requires manual classification"
    assert all(hit["path"].endswith(".swift") for hit in hits)
    report = {"base": BASE, "scan": "all git-tracked blobs at immutable base; no path filter",
              "tracked_path_count": len(entries), "candidate_paths": candidates,
              "mention_count": len(mentions), "call_site_count": len(hits),
              "call_site_file_count": len({hit['path'] for hit in hits}), "sites": hits}
    write_json("monospaced-digit-sites.json", report)
    raw = git("grep", "-n", "-C", "6", "--text", "-F", "monospacedDigit", BASE, "--")
    (OUT / "monospaced-digit-sites.raw.txt").write_bytes(raw)
    md = ["# Every existing `.monospacedDigit()` call site", "",
          f"Base: `{BASE}`. All {len(entries)} tracked paths considered by unfiltered git-tree search.",
          f"{len(mentions)} identifier mentions; {len(hits)} actual Swift call sites in {report['call_site_file_count']} files.",
          "No assumed count, untracked design outputs, or working-tree-only files are used.", "",
          "This is the existing modifier inventory, NOT the deferred app-wide numeric-surface inventory.", ""]
    for hit in hits:
        md.extend([f"## `{hit['path']}:{hit['line']}`", "", "```swift"])
        md.extend(f"{row['line']:4d} {row['text']}".rstrip() for row in hit["context"])
        md.extend(["```", ""])
    (OUT / "monospaced-digit-sites.md").write_text("\n".join(md))
    paths = set(candidates)
    paths.update(f"app/Sources/Morsel/{name}" for name in REFERENCE_FILES)
    paths.update(entry["path"] for entry in entries if entry["path"].startswith("app/Fonts/"))
    paths.update(("docs/DATA_MODEL.md", "docs/MCP_TOOLS.md", "docs/DATED_TARGETS.md"))
    hashes = []
    for path in sorted(paths):
        data = blob(path)
        current = (REPO / path).read_bytes()
        assert current == data, f"Working copy differs from base: {path}"
        copy_name = None
        if path.startswith("app/Sources/Morsel/") and Path(path).name in REFERENCE_FILES:
            copy_name = Path(path).name + ".txt"
        if path.startswith("app/Fonts/OFL-"):
            copy_name = Path(path).name
        if path.startswith("docs/"):
            copy_name = Path(path).name + ".txt"
        if copy_name:
            (OUT / copy_name).write_bytes(current)
            assert (OUT / copy_name).read_bytes() == data
        hashes.append({"path": path, "git_blob": tracked[path]["object"], "bytes": len(data),
                       "sha256": digest(data), "working_copy_equals_base": True, "reference_copy": copy_name})
    write_json("source-hashes.json", {"base": BASE, "files": hashes})
    return report


def feature_map(font: TTFont, tag: str) -> list[dict]:
    table = font["GSUB"].table
    result = []
    for index, record in enumerate(table.FeatureList.FeatureRecord):
        if record.FeatureTag != tag:
            continue
        for lookup_index in record.Feature.LookupListIndex:
            lookup = table.LookupList.Lookup[lookup_index]
            for sub_index, subtable in enumerate(lookup.SubTable):
                lookup_type = lookup.LookupType
                if lookup_type == 7:
                    lookup_type = subtable.ExtensionLookupType
                    subtable = subtable.ExtSubTable
                assert lookup_type == 1, f"Unsupported non-single substitution for {tag}"
                result.append({"feature_index": index, "lookup_index": lookup_index,
                               "subtable_index": sub_index, "lookup_type": lookup_type,
                               "lookup_flag": lookup.LookupFlag,
                               "mapping": dict(sorted(subtable.mapping.items()))})
    assert result, f"Missing feature {tag}"
    return result


def inspect_font() -> dict:
    import fontTools
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    data = blob(FONT)
    assert (REPO / FONT).read_bytes() == data
    font = TTFont(io.BytesIO(data), recalcTimestamp=False)
    table = font["GSUB"].table
    records = table.FeatureList.FeatureRecord
    mappings = {tag: feature_map(font, tag) for tag in REQUIRED_TAGS}
    script_systems = []
    for script_record in table.ScriptList.ScriptRecord:
        script = script_record.Script
        languages = [("default", script.DefaultLangSys)]
        languages += [(lang.LangSysTag, lang.LangSys) for lang in script.LangSysRecord]
        for lang, system in languages:
            if system is None:
                continue
            indices = list(system.FeatureIndex)
            script_systems.append({"script": script_record.ScriptTag, "language": lang,
                                   "feature_indices": indices,
                                   "tags": [records[i].FeatureTag for i in indices]})
    assert any(s["script"] == "latn" and s["language"] == "default"
               and set(REQUIRED_TAGS) <= set(s["tags"]) for s in script_systems)
    name_rows = [{"name_id": n.nameID, "platform_id": n.platformID,
                  "encoding_id": n.platEncID, "language_id": n.langID, "value": n.toUnicode()}
                 for n in font["name"].names]
    metadata = {"base": BASE, "source_font": FONT, "sha256": digest(data), "bytes": len(data),
                "fonttools_version": fontTools.__version__, "units_per_em": font["head"].unitsPerEm,
                "tables": list(font.keys()), "name_records": name_rows,
                "axes": [{"tag": a.axisTag, "min": a.minValue, "default": a.defaultValue, "max": a.maxValue}
                         for a in font["fvar"].axes],
                "all_gsub_features": [{"index": i, "tag": r.FeatureTag,
                                       "lookup_indices": list(r.Feature.LookupListIndex)}
                                      for i, r in enumerate(records)],
                "script_language_systems": script_systems,
                "required_feature_lookups": mappings,
                "proof_layer": "fontTools raw GSUB/hmtx tables and in-memory variable instances; not native/browser rendering"}
    write_json("font-features.raw.json", metadata)
    font.saveXML(str(OUT / "EBGaramond-GSUB-fvar.ttx"), tables=["GSUB", "fvar"])
    digits = [font.getBestCmap()[ord(digit)] for digit in "0123456789"]
    variants = {"default": [], "lnum": ["lnum"], "tnum": ["tnum"], "onum": ["onum"],
                "pnum": ["pnum"], "lnum+tnum": ["lnum", "tnum"],
                "onum+tnum": ["onum", "tnum"], "lnum+pnum": ["lnum", "pnum"],
                "onum+pnum": ["onum", "pnum"]}
    rows, direct_rows, summaries = [], [], []
    weights = sorted(set([a.defaultValue for a in font["fvar"].axes] + [400, 500, 600, 700, 800]))
    for weight in weights:
        instance = instantiateVariableFont(font, {"wght": weight}, inplace=False)
        for tag in REQUIRED_TAGS:
            for lookup in mappings[tag]:
                for before, after in lookup["mapping"].items():
                    source_metrics, target_metrics = instance["hmtx"][before], instance["hmtx"][after]
                    direct_rows.append({"weight": weight, "feature": tag, "lookup": lookup["lookup_index"],
                                        "input_glyph": before, "output_glyph": after,
                                        "input_advance": source_metrics[0], "output_advance": target_metrics[0]})
        for name, tags in variants.items():
            glyphs = list(digits)
            # OpenType lookups are evaluated in lookup-list order, not the
            # arbitrary tag order of CSS declarations. Only the requested
            # simple GSUB substitutions are evaluated; GPOS is not evaluated.
            lookups = sorted((lookup for tag in tags for lookup in mappings[tag]),
                             key=lambda value: (value["lookup_index"], value["subtable_index"]))
            for lookup in lookups:
                glyphs = [lookup["mapping"].get(glyph, glyph) for glyph in glyphs]
            advances = []
            for digit, glyph in zip("0123456789", glyphs):
                advance, lsb = instance["hmtx"][glyph]
                outline = instance["glyf"][glyph]
                advances.append(advance)
                rows.append({"weight": weight, "variant": name, "digit": digit, "glyph": glyph,
                             "advance": advance, "lsb": lsb, "y_min": outline.yMin, "y_max": outline.yMax})
            unique = sorted(set(advances))
            if "tnum" in tags or name in ("default", "lnum", "onum"):
                assert len(unique) == 1, (weight, name, advances)
            if "pnum" in tags:
                assert len(unique) > 1, (weight, name, advances)
            summaries.append({"weight": weight, "variant": name, "glyphs": glyphs,
                              "advances": advances, "unique_advances": unique,
                              "equal_digit_advances": len(unique) == 1})
    write_json("digit-advances.raw.json", {"units": "font units", "units_per_em": font["head"].unitsPerEm,
                                          "method": "hmtx after requested single-substitution GSUB lookup order; no shaping/GPOS or rasterization",
                                          "weights_tested": weights, "summaries": summaries, "rows": rows,
                                          "direct_feature_mapping_probes": direct_rows})
    for filename, values in (("digit-advances.raw.tsv", rows), ("feature-mapping-advances.raw.tsv", direct_rows)):
        keys = list(values[0])
        (OUT / filename).write_text("\t".join(keys) + "\n" + "".join(
            "\t".join(str(value[key]) for key in keys) + "\n" for value in values))
    raw_text = [f"BASE {BASE}", f"FONT {FONT}", f"SHA256 {digest(data)}",
                f"FONTTOOLS {fontTools.__version__}", f"UNITS_PER_EM {font['head'].unitsPerEm}",
                "FEATURES " + json.dumps(metadata["all_gsub_features"]),
                "AXES " + json.dumps(metadata["axes"]),
                "RAW METRICS ONLY: no browser/CoreText shaping, GPOS, or visual alignment claim."]
    for tag in REQUIRED_TAGS:
        raw_text.append("FEATURE " + tag + " " + json.dumps(mappings[tag], sort_keys=True))
    for summary in summaries:
        raw_text.append("DIGITS " + json.dumps(summary, sort_keys=True))
    (OUT / "font-proof.raw.txt").write_text("\n".join(raw_text) + "\n")
    return metadata


def verify_artifacts() -> dict:
    sources = json.loads((OUT / "source-hashes.json").read_text())
    for source in sources["files"]:
        assert digest(blob(source["path"])) == source["sha256"]
        assert digest((REPO / source["path"]).read_bytes()) == source["sha256"]
        if source["reference_copy"]:
            assert digest((OUT / source["reference_copy"]).read_bytes()) == source["sha256"]
    assert subprocess.run(["git", "-C", str(REPO), "diff", "--quiet", BASE, "--", ".", ":(exclude)docs/design/263-training-row/**"]).returncode == 0
    issue = json.loads((OUT / "issue-263.json").read_text())
    assert issue["number"] == 263 and issue["body"] and isinstance(issue["comments"], list)
    api = json.loads((OUT / "issue-263-api.raw.json").read_text())
    assert issue["body"] == api["body"] and len(issue["comments"]) == api["comments"]
    assert issue["updatedAt"] == api["updated_at"], "Issue snapshot metadata drift"
    calls = json.loads((OUT / "monospaced-digit-sites.json").read_text())
    assert calls["call_site_count"] == len(calls["sites"])
    return {"base": BASE, "source_hashes_verified": len(sources["files"]),
            "reference_copies_verified": sum(bool(f["reference_copy"]) for f in sources["files"]),
            "call_site_count": calls["call_site_count"], "issue_comment_count_captured": len(issue["comments"]),
            "product_diff_against_base_empty_excluding_own_evidence": True,
            "font_features_verified": list(REQUIRED_TAGS),
            "rendering_claim": "none; table/advance evidence only", "source_fonts_copied": False}


def seal_artifacts() -> dict:
    manifest_path = OUT / "artifact-manifest.json"
    for path in OUT.rglob("*"):
        assert path.name not in {".uv-cache", ".tmp", "__pycache__", ".DS_Store"}, str(path)
        assert path.suffix not in {".pyc", ".pyo", ".swp"}, str(path)
    paths = sorted(path for path in OUT.rglob("*") if path.is_file() and path != manifest_path)
    paths.append(Path(__file__).resolve())
    manifest = {"base": BASE, "self_included": False,
                "scope": "sources/** plus scripts/prove_fonts.py only; not the parent design bundle",
                "files": [{"path": str(path.relative_to(PROJECT)), "bytes": path.stat().st_size,
                           "sha256": digest(path.read_bytes())} for path in paths]}
    manifest["file_count_excluding_manifest"] = len(paths)
    manifest["total_bytes_excluding_manifest"] = sum(row["bytes"] for row in manifest["files"])
    write_json("artifact-manifest.json", manifest)
    saved = json.loads(manifest_path.read_text())
    actual = {str(path.relative_to(PROJECT)) for path in OUT.rglob("*")
              if path.is_file() and path != manifest_path} | {"scripts/prove_fonts.py"}
    assert actual == {row["path"] for row in saved["files"]}
    for row in saved["files"]:
        assert digest((PROJECT / row["path"]).read_bytes()) == row["sha256"]
    return {"manifest_file_count_excluding_manifest": len(paths),
            "raw_file_count_including_manifest": len(actual) + 1,
            "manifest_hashes_verified": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--seal", action="store_true", help="Verify and seal after removing owned uv/temp caches")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if not (args.verify_only or args.seal):
        source_proofs()
        inspect_font()
    verification = verify_artifacts()
    write_json("verification.json", verification)
    if args.seal:
        verification.update(seal_artifacts())
    print(json.dumps(verification, indent=2))


if __name__ == "__main__":
    main()
