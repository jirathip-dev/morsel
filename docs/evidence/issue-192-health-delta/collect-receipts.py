#!/usr/bin/env python3
"""Build native/run.json from the lane's raw logs (issue #192).

Every number in the receipts is parsed from the raw xcodebuild log or the raw
exit file written by the runner — nothing is transcribed by hand.

    python3 docs/evidence/issue-192-health-delta/collect-receipts.py
"""
from __future__ import annotations

import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[3]
LANE_LOGS = ROOT / ".lane-logs"
OUT = pathlib.Path(__file__).resolve().parent / "native/run.json"

CASES = [
    ("base-probe-red", "base-probe-red.log", "base-probe-red.exit"),
    ("base-known-reds", "base-known-reds.log", "base-known-reds.exit"),
    ("head-focused", "head-focused5.log", "head-focused5.exit"),
    ("head-full-native", "head-full-native2.log", "head-full-native2.exit"),
]


def parse(name: str, log_name: str, exit_name: str) -> dict:
    log = (LANE_LOGS / log_name).read_text(errors="replace")
    lines = log.splitlines()
    raw_exit = int(re.search(r"RAW_EXIT=(\d+)", (LANE_LOGS / exit_name).read_text()).group(1))
    # Overall summaries only: the lines that follow a whole-run suite header
    # (never a per-class sub-suite line).
    summaries = []
    for index, line in enumerate(lines):
        if line.startswith(("Test Suite 'Selected tests'", "Test Suite 'MorselTests.xctest'")):
            match = re.search(
                r"Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures",
                lines[index + 1]
            ) if index + 1 < len(lines) else None
            if match:
                summaries.append(
                    {"tests": int(match.group(1)), "failures": int(match.group(2))}
                )
    failing = sorted({
        line.split("'")[1]
        for line in lines
        if line.startswith("Test Case") and " failed (" in line
    })
    argv = re.search(r"Command line invocation:\s*\n\s*(.*)", log)
    return {
        "name": name,
        "log": f".lane-logs/{log_name}",
        "raw_exit": raw_exit,
        "main_launch_summary": summaries[0] if summaries else None,
        "last_summary": summaries[-1] if summaries else None,
        "assertion_failures": sum(1 for line in lines if " error: -[MorselTests" in line),
        "timeout_restarts": sum(1 for line in lines if "Restarting after" in line),
        "allowance_exceeded": sorted({
            line.split("Test Case '-[MorselTests.")[1].split("]'")[0]
            for line in lines if "exceeded execution time allowance" in line
        }),
        "failing_test_cases": failing,
        "invocation": (argv.group(1) if argv else "").strip(),
    }


def main() -> None:
    receipts = [parse(*case) for case in CASES]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(receipts, indent=2) + "\n")
    print(OUT.read_text())


if __name__ == "__main__":
    main()
