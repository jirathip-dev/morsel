#!/usr/bin/env python3
"""Issue #195 — build the committed evidence excerpts from the lane logs.

Every excerpt carries the exact command and raw exit of the run it quotes; log
lines are trailing-whitespace-stripped so `git diff --check` stays clean (raw
xcodebuild lines end in a space).
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
LANE = ROOT / ".lane-logs"
OUT = ROOT / "docs" / "evidence" / "issue-195-render-derived" / "excerpts"
OUT.mkdir(parents=True, exist_ok=True)

KEEP = re.compile(
    r"ISSUE195|Test Case|Executed |error:|warning: .*File Length|RAW_EXIT|"
    r"Test Suite|Test Files|Tests  |passed|failed|MUTATION|mutated|restored|pristine sha256"
)


def raw_exit(text: str) -> str:
    matches = re.findall(r"RAW_EXIT=(\d+)", text)
    return matches[-1] if matches else "n/a"


def write(name: str, header: list[str], source: Path, keep_all: bool = False,
          pattern: re.Pattern | None = None) -> None:
    text = source.read_text(errors="replace") if source.exists() else ""
    lines = [line.rstrip() for line in text.splitlines()]
    if keep_all:
        body = lines
    else:
        matcher = pattern or KEEP
        body = [line for line in lines if matcher.search(line)]
    payload = "\n".join(header + ["RAW_EXIT=" + raw_exit(text), ""] + body)
    (OUT / name).write_text(payload.rstrip("\n") + "\n")
    print("wrote", name, len(body), "lines")


write("195-baseline-probe.txt", [
    "# Issue #195 baseline (pre-change) measurement probe.",
    "# command: HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj",
    "#          -scheme Morsel -destination 'platform=iOS Simulator,id=<lane>' -derivedDataPath /tmp/morsel-195-dd",
    "#          -only-testing:MorselTests/RenderDerivedProbeTests",
    "# worktree state: base sources (no production edit yet)",
], LANE / "195-baseline-probe2.log")

write("195-head-probe.txt", [
    "# Issue #195 head: measurement probe + durable reuse suite (fixed sources).",
    "# command: HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj",
    "#          -scheme Morsel -destination 'platform=iOS Simulator,id=<lane>' -derivedDataPath /tmp/morsel-195-dd",
    "#          -only-testing:MorselTests/RenderDerivedProbeTests -only-testing:MorselTests/RenderDerivedReuseTests",
], LANE / "195-head-focused3.log")

write("195-reuse-focused.txt", [
    "# Issue #195 head: the durable reuse suite alone (same invocation as 195-head-probe.txt).",
    "# suites: RenderDerivedReuseTests (count regression + AC3 parity) and RenderDerivedProbeTests (measurement).",
], LANE / "195-head-focused3.log")

write("195-mutation-battery.txt", [
    "# Issue #195 mutation battery: each mutation reverts one mechanism of the fix and the",
    "# durable suite must fail (raw exit 65). Driver: tools/mutation-battery.sh",
], LANE / "195-mutation-battery-summary.log")

write("195-base-durable.txt", [
    "# Issue #195 base leg: the durable reuse suite at the base commit (scratch worktree /tmp/m195-base-leg).",
    "# `derivedScanCount` does not exist at base: the suite cannot build (raw exit 65).",
    "# driver: tools/base-legs.sh",
], LANE / "195-base-durable.log")

write("195-base-probe.txt", [
    "# Issue #195 base leg: the same measurement probe against unmodified base sources.",
    "# driver: tools/base-legs.sh (scratch worktree at 1cf9ecc)",
], LANE / "195-base-probe.log")

write("195-base-known-reds.txt", [
    "# Issue #195 base leg: the suites that failed in the head full run, run at the BASE commit",
    "# (scratch worktree /tmp/m195-base-leg) to classify them as pre-existing.",
    "# command: HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj",
    "#          -scheme Morsel -destination 'platform=iOS Simulator,id=<lane>' -derivedDataPath /tmp/morsel-195-base-dd",
    "#          -only-testing:MorselTests/SharedButtonTargetTests -only-testing:MorselTests/ParallelReadsTests",
    "#          -only-testing:MorselTests/PageIdentityTests -only-testing:MorselTests/MealReliabilityTests",
], LANE / "195-base-known-reds.log")

write("195-tz-order-verify.txt", [
    "# Issue #195: zone-order regression check. HistoryCacheScopeTests pins NSTimeZone.default before",
    "# this lane's suite runs; that ordering made the zone switch ineffective in the first full run.",
    "# command: ... -only-testing:MorselTests/HistoryCacheScopeTests -only-testing:MorselTests/RenderDerivedReuseTests",
], LANE / "195-tz-order-verify.log")

write("195-full-native.txt", [
    "# Issue #195 head: ONE complete unfiltered native invocation (all suites).",
    "# command: HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj",
    "#          -scheme Morsel -destination 'platform=iOS Simulator,id=<lane>' -derivedDataPath /tmp/morsel-195-dd",
    "# excerpt: suite totals, failures, the lane's own measurement lines and the final result.",
], LANE / "195-full-native2.log", pattern=re.compile(
    r"Executed [0-9]+ tests, with|error: -\[|ISSUE195|RAW_EXIT|TEST (FAILED|SUCCEEDED)|Testing failed"))
