#!/usr/bin/env python3
"""Package the issue #288 evidence from the lane's raw legs.

Reads this lane's raw logs (/tmp/rev288-logs) plus the worktree's source and
catalog bytes, and writes the committed aggregate JSONs next to this file:

  coverage-aggregate.json  corpora aggregates + provenance (counts/hashes only)
  gates.json               every gate: command, raw exit, log path + log hash
  mutation-battery.json    the bite proof: per-mutation raw exit + failing tests
  named-results.json       the case inventory measured by probe/CaseProbe.swift

No logged name is ever written: corpus handling is count/hash only. Re-running
against a different /tmp/rev288-logs packages that run's numbers.

    python3 package-evidence.py [--logs /tmp/rev288-logs]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKTREE = HERE.parents[2]
RESOLVER = WORKTREE / "app" / "Sources" / "Morsel" / "FoodArtwork.swift"
POLICY = WORKTREE / "app" / "Sources" / "Morsel" / "FoodArtworkSecondary.swift"
CATALOG = WORKTREE / "app" / "Resources" / "FoodArt" / "catalog.json"
CORPUS_PRIMARY = Path(
    "/Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion/.lane-logs/logged-names.json"
)
CORPUS_SNAPSHOT = Path("/tmp/m260/recent.json")

BASE_RESOLVER_SHA = "1e3517b4c588ad0c2196e168f98986040caced4efffe760c5eb82a7ec5481639"  # #260 evidence pin
PRISTINE_POLICY_SHA = "e62ddad4f43f7a244e034be331166a683a9e0b793823f949e79869a2da4d6752"


def sha256(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def corpus_facts(path: Path) -> dict:
    facts: dict = {"path": str(path), "exists": path.exists()}
    if not path.exists():
        return facts
    rows = json.loads(path.read_text())
    facts.update(
        {
            "sha256": sha256(path),
            "mtime_ns": path.stat().st_mtime_ns,
            "rows": len(rows),
            "distinct_names": len({row["name"] for row in rows}),
        }
    )
    return facts


def log_facts(logs: Path, leg: str) -> dict:
    path = logs / f"{leg}.log"
    facts: dict = {"log": str(path), "exists": path.exists()}
    if not path.exists():
        return facts
    text = path.read_text(errors="replace")
    facts["log_sha256"] = sha256(path)
    facts["log_bytes"] = path.stat().st_size
    raw_exit = re.findall(r"raw_exit=(\d+)", text)
    if raw_exit:
        facts["raw_exit"] = int(raw_exit[-1])
    duration = re.findall(r"duration_s=(\d+)", text)
    if duration:
        facts["duration_s"] = int(duration[-1])
    summary = re.findall(r"Executed (\d+) tests?, with (?:\d+ tests skipped and )?(\d+) failures?", text)
    if summary:
        executed, failures = summary[-1]
        facts["executed_tests"] = int(executed)
        facts["failures"] = int(failures)
    facts["failing_tests"] = sorted(
        {m.group(1) for m in re.finditer(r"^Test Case '([^']+)' failed", text, re.M)}
    )
    lint = re.findall(r"Done linting!.*", text)
    if lint:
        facts["summary_line"] = lint[-1]
    tail = [line for line in text.splitlines() if "raw_exit=" in line]
    if tail:
        facts["summary_line"] = tail[-1]
    coverage = re.findall(r"ISSUE\d+_COVERAGE (\{.*\})", text)
    if coverage:
        facts["coverage_line"] = coverage[-1]
    return facts


def coverage_of(line: str) -> dict:
    payload = json.loads(line)
    counts = payload["counts"]
    total = sum(counts.values())
    return {
        "counts": counts,
        "distinct_names": payload["distinct_names"],
        "percentages": {key: round(value * 100 / total, 1) for key, value in counts.items()},
    }


def package_probe(probe_log: Path) -> dict:
    sections = {"positives": [], "vetoes": [], "shipped": []}
    summaries: dict[str, str] = {}
    if not probe_log.exists():
        return {"cases": sections, "summaries": summaries, "probe_log": str(probe_log)}
    current = "positives"
    for line in probe_log.read_text().splitlines():
        header = re.match(r"^(POSITIVES|VETOES|SHIPPED) ", line)
        if header:
            summaries[header.group(1).lower()] = line
            current = {"POSITIVES": "vetoes", "VETOES": "shipped", "SHIPPED": "done"}[header.group(1)]
            if current == "done":
                break
            continue
        match = re.match(r"^\s*(PASS|FAIL|NEUTRAL|RESOLVED) \| (.+?) -> (.+?)(?: want=(.+))?$", line)
        if not match or current == "done":
            continue
        status, name, resolved, want = match.groups()
        entry = {"name": name, "resolved": resolved, "status": status}
        if want:
            entry["want"] = want
        sections[current].append(entry)
    return {
        "command": (
            "swiftc -O -o /tmp/rev288-probe CaseProbe.swift "
            "../../../../app/Sources/Morsel/FoodArtwork.swift "
            "../../../../app/Sources/Morsel/FoodArtworkSecondary.swift && "
            "/tmp/rev288-probe ../../../../app/Resources/FoodArt/catalog.json"
        ),
        "probe_log": {"path": str(probe_log), "sha256": sha256(probe_log), "exists": probe_log.exists()},
        "catalog_assets": 130,
        "summaries": summaries,
        "cases": sections,
        "note": (
            "Simulator-free inventory of the same cases the app-hosted XCTest asserts; "
            "the durable assertions are the XCTest suites."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", default="/tmp/rev288-logs")
    args = parser.parse_args()
    logs = Path(args.logs)

    legs = {name: log_facts(logs, name) for name in (
        "red-288-focused", "green-288-focused", "cov151-288-secondary", "cov151-base-288",
        "full-288", "mut-m1", "mut-m2", "mut-m3",
        "swiftlint-final", "pbxproj.idempotence", "git-diff-check", "typecheck", "npm-test",
        "base-verify-288",
    )}

    def aggregate(leg: str) -> dict | None:
        line = legs[leg].get("coverage_line")
        return coverage_of(line) if line else None

    primary = {
        "label": "owner corpus — the same snapshot the #260 evidence measured",
        "corpus": corpus_facts(CORPUS_PRIMARY),
        "base": {"resolver_sha256": BASE_RESOLVER_SHA, "leg": legs["red-288-focused"], "aggregate": aggregate("red-288-focused")},
        "head": {"resolver_sha256": sha256(RESOLVER), "leg": legs["green-288-focused"], "aggregate": aggregate("green-288-focused")},
    }
    secondary = {
        "label": "newer owner snapshot (ephemeral /tmp pull, hashed not committed; contains both issue rows)",
        "corpus": corpus_facts(CORPUS_SNAPSHOT),
        "base": {"leg": legs["cov151-base-288"], "aggregate": aggregate("cov151-base-288")},
        "head": {"resolver_sha256": sha256(RESOLVER), "leg": legs["cov151-288-secondary"], "aggregate": aggregate("cov151-288-secondary")},
    }
    if primary["base"]["aggregate"] and primary["head"]["aggregate"]:
        primary["delta_counts"] = {
            key: primary["head"]["aggregate"]["counts"][key] - primary["base"]["aggregate"]["counts"][key]
            for key in primary["head"]["aggregate"]["counts"]
        }
    if secondary["base"]["aggregate"] and secondary["head"]["aggregate"]:
        secondary["delta_counts"] = {
            key: secondary["head"]["aggregate"]["counts"][key] - secondary["base"]["aggregate"]["counts"][key]
            for key in secondary["head"]["aggregate"]["counts"]
        }
    coverage = {
        "harness": "app-hosted XCTest FoodArtworkPrivateCoverageTests (FoodArtworkCatalog.bundled + FoodArtworkResolver.resolve(name:in:))",
        "primary": primary,
        "secondary": secondary,
        "resolver_sha256": sha256(RESOLVER),
        "policy_sha256": sha256(POLICY),
        "catalog_sha256": sha256(CATALOG),
        "notes": [
            "Aggregates only: no logged name is committed and the harness prints none.",
            "The primary corpus is the same snapshot the delivered head's published numbers used, so the comparison is apples-to-apples in one harness.",
            "Each distinct name counts once; frequency is not used.",
        ],
    }
    (HERE / "coverage-aggregate.json").write_text(json.dumps(coverage, indent=2, sort_keys=True) + "\n")

    named = {"harness": "probe/CaseProbe.swift compiled by swiftc against the same sources + bundled catalog", **package_probe(logs / "probe-cases.log")}
    (HERE / "named-results.json").write_text(json.dumps(named, indent=2, sort_keys=True) + "\n")

    mutation_text = [
        ("m1", "whole-name/qualifier-only matching again — FoodArtworkSecondary.head returns nil"),
        ("m2", "unbounded tail — accept any non-empty phrase, i.e. remove the closed vocabulary"),
        ("m3", "remove the catalog-derived veto — a tolerated phrase may name a second identity"),
    ]
    battery = {
        "pristine_policy_sha256": PRISTINE_POLICY_SHA,
        "battery_log": {"path": str(logs / "battery-run.log"), "sha256": sha256(logs / "battery-run.log")},
        "mutations": [{"id": key, "mutation": text, **legs[f"mut-{key}"]} for key, text in mutation_text],
        "note": "Each leg is the same focused 5-class set on the mutated source; the source is restored byte-identically afterwards.",
    }
    (HERE / "mutation-battery.json").write_text(json.dumps(battery, indent=2, sort_keys=True) + "\n")

    gates = [
        {"gate": "swiftlint --strict", "command": "cd app && swiftlint lint --strict", **legs["swiftlint-final"]},
        {"gate": "xcodegen generate — regeneration is byte-identical (project is generated, not hand-edited)", "command": "cd app && xcodegen generate  # cmp before/after", **legs["pbxproj.idempotence"]},
        {"gate": "git diff --check (staged)", "command": "git diff --cached --check", **legs["git-diff-check"]},
        {"gate": "npm run typecheck", "command": "npm run typecheck", **legs["typecheck"]},
        {"gate": "npm test (full JS suite)", "command": "npm test", **legs["npm-test"]},
        {"gate": "native focused matcher set — base resolver (RED)", "command": "see README 'Repro/prove first'", **legs["red-288-focused"]},
        {"gate": "native focused matcher set — head (GREEN)", "command": "see README 'Repro/prove first'", **legs["green-288-focused"]},
        {"gate": "native coverage leg — newer snapshot, head", "command": "hermes-sim-task --name Morsel288-iPhone16 -- bash /tmp/rev288-native-gate.sh cov151-288-secondary -only-testing:MorselTests/FoodArtworkPrivateCoverageTests", **legs["cov151-288-secondary"]},
        {"gate": "native coverage leg — newer snapshot, base resolver", "command": "hermes-sim-task --name Morsel288-iPhone16 -- bash /tmp/rev288-native-gate.sh cov151-base-288 -only-testing:MorselTests/FoodArtworkPrivateCoverageTests", **legs["cov151-base-288"]},
        {"gate": "native full suite (unfiltered)", "command": "hermes-sim-task --name Morsel288-iPhone16 -- bash /tmp/rev288-native-gate.sh full-288", **legs["full-288"]},
        {"gate": "native baseline check for the full-suite failures (base b5e64f3)", "command": "hermes-sim-task --name Morsel288-iPhone16 -- bash /tmp/rev288-native-gate-base.sh base-verify-288 -only-testing:MorselTests/PageIdentityTests -only-testing:MorselTests/ParallelReadsTests -only-testing:MorselTests/SharedButtonTargetTests", **legs["base-verify-288"]},
    ]
    (HERE / "gates.json").write_text(json.dumps({"generated_at_ns": time.time_ns(), "gates": gates}, indent=2, sort_keys=True) + "\n")
    for name in ("coverage-aggregate.json", "named-results.json", "mutation-battery.json", "gates.json"):
        print(f"wrote {HERE / name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
