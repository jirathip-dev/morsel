#!/usr/bin/env python3
"""Issue #192 mutation battery.

One mutation per defended mechanism, a focused native run each, every file
restored byte-identically (sha256 verified before and after). Prints one
`MUTATION <name> raw_exit=<code> failing=<n>` line per case immediately so a
kill mid-battery still leaves the receipts.

Run from the lane checkout, one heavy native gate at a time:

    flock /tmp/n.lock python3 docs/evidence/issue-192-health-delta/mutation-battery.py

Mutations are structural (no test edits, no suppressions): each one reverts the
mechanism a specific acceptance criterion depends on.
"""
from __future__ import annotations

import hashlib
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
DELTA = ROOT / "app/Sources/Morsel/LocalHealthStore+Delta.swift"
IMPORTER = ROOT / "app/Sources/Morsel/HealthKitWeightImporter.swift"
LOGS = ROOT / ".lane-logs/mutation"
BACKUP = pathlib.Path("/tmp/morsel-192-mutation-orig")

FOCUSED = [
    "-only-testing:MorselTests/HealthDeltaImportTests",
    "-only-testing:MorselTests/HealthEnergyDeltaTests",
]

# (name, file, exact source text, mutated text)
MUTATIONS = [
    (
        "body-cursor-never-advances",
        DELTA,
        "            try writeAnchor(window.anchor, Self.bodyMassAnchorKey)\n        }\n        return valid",
        "            // MUTATED: the body-mass cursor never advances.\n        }\n        return valid",
    ),
    (
        "energy-legacy-baseline-skipped",
        DELTA,
        "            guard try ledgerIsEmpty(day), let prior = try storedEnergyTotal(day) else { continue }\n"
        '            try insertContribution(key: "baseline:\\(Self.dayKey(day))", day: day, kcal: prior)',
        "            // MUTATED: a pre-ledger day total is dropped instead of kept.\n"
        "            continue",
    ),
    (
        "energy-removals-ignored",
        DELTA,
        "        for id in removedSampleIDs {\n"
        '            try runUnsafe(\n'
        '                "DELETE FROM energy_sample_ledger WHERE sample_key = ?", .text(id.uuidString)\n'
        "            )\n"
        "        }",
        "        // MUTATED: removals are ignored.",
    ),
    (
        "energy-key-is-timestamp-only",
        ROOT / "app/Sources/Morsel/HealthLogStores.swift",
        '    if let sampleID = log.sampleID { return sampleID.uuidString }\n'
        '    return "t:\\(log.burnedAt.timeIntervalSince1970):\\(log.activeKilocalories)"',
        '    // MUTATED: identity dedupe collapsed onto the timestamp.\n'
        '    return "t:\\(log.burnedAt.timeIntervalSince1970)"',
    ),
]


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_focused(name: str) -> tuple[int, int]:
    log = LOGS / f"{name}.log"
    command = [
        "xcodebuild", "test", "-project", "Morsel.xcodeproj", "-scheme", "Morsel",
        "-derivedDataPath", "/tmp/morsel-192-dd", "-parallel-testing-enabled", "NO",
        "-jobs", "2", "-test-timeouts-enabled", "YES",
        "-maximum-test-execution-time-allowance", "60", "CODE_SIGNING_ALLOWED=NO",
        *FOCUSED, "-resultBundlePath", f"/tmp/morsel-192-mutation-{name}.xcresult",
    ]
    with log.open("w") as handle:
        status = subprocess.run(command, cwd=ROOT / "app", stdout=handle,
                                stderr=subprocess.STDOUT).returncode
    failing = sum(
        1 for line in log.read_text(errors="replace").splitlines()
        if line.startswith("Test Case") and " failed (" in line
    )
    print(f"MUTATION {name} raw_exit={status} failing={failing} log={log}", flush=True)
    return status, failing


def main() -> int:
    LOGS.mkdir(parents=True, exist_ok=True)
    BACKUP.mkdir(parents=True, exist_ok=True)
    originals = {}
    for path in {DELTA, IMPORTER, MUTATIONS[3][1]}:
        target = BACKUP / path.name
        shutil.copy2(path, target)
        originals[path] = sha256(path)
    failures = 0
    for name, path, old, new in MUTATIONS:
        text = path.read_text()
        if old not in text:
            print(f"MUTATION {name} SKIPPED: anchor text not found", flush=True)
            failures += 1
            continue
        path.write_text(text.replace(old, new, 1))
        status, failing = run_focused(name)
        if status == 0 or failing == 0:
            failures += 1
            print(f"MUTATION {name} DID NOT BITE", flush=True)
        shutil.copy2(BACKUP / path.name, path)
        restored = sha256(path)
        if restored != originals[path]:
            failures += 1
            print(f"MUTATION {name} RESTORE MISMATCH {restored} != {originals[path]}",
                  flush=True)
        else:
            print(f"MUTATION {name} restored sha256={restored}", flush=True)
    print(f"MUTATION-BATTERY done failures={failures}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
