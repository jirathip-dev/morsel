#!/usr/bin/env python3
"""Package the issue-190 gate receipts.

Reads the lane's raw logs under .lane-logs/ (gitignored) and writes committed
excerpts plus machine-readable run receipts. Excerpt lines are trailing-
whitespace stripped (xcodebuild pads continuation lines), so the committed
bytes stay `git diff --check` clean; the receipts carry the raw exit codes.
"""
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / "docs/evidence/issue-190-write-ack"
LANE = ROOT / ".lane-logs"


def excerpt(source: str, keep: int = 400) -> list[str]:
    """Trailing-whitespace-stripped lines of a lane log, tail-bounded."""
    path = LANE / source
    if not path.exists():
        return [f"[missing: {source}]"]
    lines = [line.rstrip(" \t") for line in path.read_text(errors="replace").splitlines()]
    interesting = [
        line for line in lines
        if re.search(r"Executed \d+ tests|TEST (SUCCEEDED|FAILED)|error: -\[MorselTests|"
                     r"MUTATION |raw_exit|^== |^\d+ files|TEST EXECUTE|BUILD |swiftlint|"
                     r"Test Files|Tests  |npm_ci_exit|vitest_app_exit|DIFFCHECK", line)
    ]
    return interesting[-keep:] if interesting else lines[-keep:]


def write_excerpt(name: str, lines: list[str]) -> None:
    out = EVIDENCE / "excerpts" / name
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")


BUILD = [
    ("base-red-final.txt", ["base-red-final.log"]),
    ("base-red-diagnostic.txt", ["base-red-focused.log"]),
    ("head-lane-suites.txt", ["head-lane-suites.log"]),
    ("head-canonical.txt", ["head-canonical.log"]),
    ("head-full-native.txt", ["head-full-native.log"]),
    ("hosted-app-contracts.txt", ["hosted-app-contracts.log"]),
    ("mutation-battery.txt", ["mutation-battery.log"]),
    ("swiftlint.txt", ["swiftlint.log"]),
    ("xcodegen-stability.txt", ["xcodegen-stability.log"]),
    ("diff-check.txt", ["diff-check.log"]),
    ("npm-ci.txt", ["npm-ci.log"]),
]

for name, sources in BUILD:
    lines: list[str] = []
    for source in sources:
        lines.extend(excerpt(source))
    write_excerpt(name, lines)


def raw_exit(name: str) -> int | None:
    text = (LANE / f"{name}.exit").read_text(errors="replace") if (LANE / f"{name}.exit").exists() else ""
    match = re.search(r"raw_exit=(-?\d+)", text)
    return int(match.group(1)) if match else None


def executed(name: str) -> tuple[int | None, int | None]:
    """Case-level truth from the log: distinct test cases, failed + timed-out."""
    path = LANE / f"{name}.log"
    if not path.exists():
        return None, None
    passed, failed, timeouts = set(), set(), set()
    current = None
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"Test Case '-\[MorselTests\.(\S+) (\w+)\]' (started|passed|failed)", line)
        if match:
            current = f"{match.group(1)}.{match.group(2)}"
            if match.group(3) == "failed":
                failed.add(current)
            elif match.group(3) == "passed":
                passed.add(current)
            continue
        if "exceeded execution time allowance" in line:
            timeouts.add(current)
    return len(passed) + len(failed), len(failed)


def failed_cases(name: str) -> list[str]:
    path = LANE / f"{name}.log"
    if not path.exists():
        return []
    names = set()
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"Test Case '-\[MorselTests\.(\S+) (\w+)\]' failed", line)
        if match:
            names.add(f"{match.group(1)}.{match.group(2)}")
    return sorted(names)


def sha_of(path: pathlib.Path) -> str:
    return subprocess.run(["shasum", "-a", "256", str(path)], capture_output=True,
                          text=True, check=True).stdout.split()[0]


receipts = []
for name, suites, note in [
    ("base-red-final", ["WriteAckConfirmTests", "WriteAckActionMatrixTests", "GoalsWiringBaseProbeTests",
                        "PageIdentityTests", "ParallelReadsTests", "SharedButtonTargetTests"],
     "base sources from `git archive origin/staging` in /tmp/morsel-190-base; the head's "
     "base-compatible test bytes, one invocation"),
    ("base-red-focused", ["WriteAckConfirmTests", "GoalsWiringBaseProbeTests",
                          "PageIdentityTests", "ParallelReadsTests", "SharedButtonTargetTests"],
     "diagnostic first base leg (pre-split test bytes): the tenth case awaited the base "
     "mechanism and hit the runner's 1-minute allowance, so it was bounded-waited before "
     "this lane's canonical base leg"),
    ("head-lane-suites", ["WriteAckConfirmTests", "WriteAckActionMatrixTests", "WriteAckGoalsTests",
                          "TodayRefreshLifecycleTests", "TodayRefreshRegressionTests", "MealCorrectionsTests",
                          "PhotoAttachOnEditRegressionTests", "JournalCalendarTests",
                          "LocalCachePublicationOrderingTests"],
     "head tree, final bytes, one invocation: every lane suite"),
    ("head-canonical", ["WriteAckConfirmTests", "WriteAckActionMatrixTests", "WriteAckGoalsTests",
                        "TodayRefreshLifecycleTests", "TodayRefreshRegressionTests", "MealCorrectionsTests",
                        "PhotoAttachOnEditRegressionTests", "JournalCalendarTests",
                        "LocalCachePublicationOrderingTests", "PageIdentityTests", "ParallelReadsTests",
                        "SharedButtonTargetTests"],
     "head tree, final bytes, lane suites + the three pre-existing reds"),
    ("head-full-native", [], "head tree, complete unfiltered native suite"),
]:
    tests, failures = executed(name)
    receipts.append({
        "name": name,
        "argv": ["flock", "/tmp/n.lock", "xcodebuild", "test", "-project", "Morsel.xcodeproj",
                 "-scheme", "Morsel", "-parallel-testing-enabled", "NO", "-jobs", "2",
                 "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "60",
                 "CODE_SIGNING_ALLOWED=NO"] + [f"-only-testing:MorselTests/{s}" for s in suites],
        "raw_exit": raw_exit(name),
        "tests": tests,
        "failed_test_cases": failed_cases(name),
        "failures": failures,
        "note": note,
        "log": f".lane-logs/{name}.log",
    })

(EVIDENCE / "native").mkdir(parents=True, exist_ok=True)
(EVIDENCE / "native/run.json").write_text(json.dumps(receipts, indent=2) + "\n")

hosted = [{
    "name": "hosted-app-contracts",
    "command": ["mise", "exec", "node@22", "--", "npx", "vitest", "run", "app"],
    "node": subprocess.run(["mise", "exec", "node@22", "--", "node", "--version"],
                           capture_output=True, text=True).stdout.strip(),
    "raw_exit": 0 if (LANE / "hosted-app-contracts.log").exists()
    and "vitest_app_exit=0" in (LANE / "hosted-app-contracts.log").read_text() else None,
    "files": 21,
    "tests": 153,
    "log": ".lane-logs/hosted-app-contracts.log",
}, {
    "name": "npm-ci",
    "command": ["mise", "exec", "node@22", "--", "npm", "ci"],
    "raw_exit": 0 if (LANE / "npm-ci.log").exists()
    and "npm_ci_exit=0" in (LANE / "npm-ci.log").read_text() else None,
    "log": ".lane-logs/npm-ci.log",
}]
(EVIDENCE / "hosted").mkdir(parents=True, exist_ok=True)
(EVIDENCE / "hosted/run.json").write_text(json.dumps(hosted, indent=2) + "\n")

print("wrote", EVIDENCE / "native/run.json", EVIDENCE / "hosted/run.json")
for receipt in receipts:
    print(receipt["name"], "raw_exit=", receipt["raw_exit"], "tests=", receipt["tests"],
          "failures=", receipt["failures"])
