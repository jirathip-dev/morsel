#!/usr/bin/env python3
"""Rebuild the #266 attachment run; optional private, name-only coverage.

Run from the repo root. All raw logs/receipts stay in ignored .lane-logs/.
Own simulator admission is hermes-sim-task, under the shared /tmp/n.lock.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
LOGS = ROOT / ".lane-logs"
MARKER = Path("/tmp/morsel-260-coverage-path")
BASE = "05e6314f2ebd107149c5be22f2b09f003e697948"
SOURCE = ROOT / "app/Sources/Morsel/FoodArtwork.swift"


def run(label, command, timeout=900, cwd=ROOT):
    started = time.monotonic()
    with (LOGS / f"{label}.log").open("w") as log:
        log.write("command=" + json.dumps(command) + "\n")
        log.flush()
        proc = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            raw = proc.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                raw = proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                raw = proc.wait(timeout=20)
            timed_out = True
        receipt = dict(command=command, cwd=str(cwd), raw_exit=raw, timed_out=timed_out,
                       duration_seconds=round(time.monotonic() - started, 3))
        log.write("\nreceipt=" + json.dumps(receipt) + "\n")
    (LOGS / f"{label}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(label, json.dumps(receipt), flush=True)
    return 124 if timed_out else raw


def native(label, suites):
    command = ["xcodebuild", "test", "-project", "Morsel.xcodeproj", "-scheme", "Morsel",
               "-destination", "platform=iOS Simulator,id=" + os.environ["SIMULATOR_UDID"],
               "-derivedDataPath", "/tmp/morsel-260-derived", "-resultBundlePath", f"/tmp/morsel-260-{label}.xcresult",
               "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
               "-jobs", "2", "CODE_SIGNING_ALLOWED=NO"]
    command += ["-only-testing:MorselTests/" + suite for suite in suites]
    return run(label, command, cwd=ROOT / "app")


def inside(args):
    (LOGS / "simulator.json").write_text(json.dumps({"udid": os.environ["SIMULATOR_UDID"],
                                                   "name": "Morsel260-Matcher-iPhone16"}) + "\n")
    suites = ["FoodArtworkMatcherClosureTests", "FoodArtworkFallbackTests", "FoodArtworkQualifierTests",
              "ArtworkIdentityTests", "ArtworkIdentitySurfaceTests", "FoodArtworkQualifierSurfaceTests",
              "RowArtworkRendererTests", "FoodLibraryIntegrationTests", "FoodLibraryCostTests"]
    if args.corpus:
        MARKER.write_text(str(Path(args.corpus).resolve()))
        suites.append("FoodArtworkPrivateCoverageTests")
    try:
        result = native(args.label, suites)
        if result != 0:
            return result
        result = run("export-attachments", ["xcrun", "xcresulttool", "export", "attachments", "--path",
                     f"/tmp/morsel-260-{args.label}.xcresult", "--output-path", str(LOGS / "attachments")], 120)
        if result != 0 or not args.mutation:
            return result
        fixed = SOURCE.read_bytes()
        digest = hashlib.sha256(fixed).hexdigest()
        (LOGS / "FoodArtwork.fixed.swift").write_bytes(fixed)
        try:
            old = subprocess.check_output(["git", "show", BASE + ":app/Sources/Morsel/FoodArtwork.swift"], cwd=ROOT)
            SOURCE.write_bytes(old)
            red = native("base-grammar-red", ["FoodArtworkMatcherClosureTests"])
        finally:
            SOURCE.write_bytes(fixed)
            os.utime(SOURCE, None)
            assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == digest
            (LOGS / "restored-source.sha256").write_text(digest + "\n")
        green = native("restored-green", ["FoodArtworkMatcherClosureTests"])
        return 0 if red == 65 and green == 0 else 1
    finally:
        if args.corpus:
            MARKER.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus")
    parser.add_argument("--mutation", action="store_true")
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--label", default="native-focused")
    args = parser.parse_args()
    LOGS.mkdir(exist_ok=True)
    if args.inside:
        return inside(args)
    run(args.label + "-process-preflight", ["pgrep", "-fl", "xcodebuild|xctest"], 20)
    run(args.label + "-disk-preflight", ["df", "-h", "/"], 20)
    lock = Path("/tmp/n.lock")
    deadline = time.monotonic() + 900
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                print("ADMISSION_TIMEOUT: /tmp/n.lock; no native command launched", flush=True)
                return 124
            time.sleep(10)
    owner = lock / "owner.pid"
    owner.write_text(str(os.getpid()) + "\n")
    print("ADMITTED /tmp/n.lock owner=" + str(os.getpid()), flush=True)
    try:
        if args.corpus:
            corpus = Path(args.corpus).resolve()
            rows = json.loads(corpus.read_bytes())
            provenance = dict(path=str(corpus), mtime_ns=corpus.stat().st_mtime_ns,
                              sha256=hashlib.sha256(corpus.read_bytes()).hexdigest(),
                              rows=len(rows), distinct_names=len({row["name"] for row in rows}),
                              resolver_sha256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                              catalog_sha256=hashlib.sha256((ROOT / "app/Resources/FoodArt/catalog.json").read_bytes()).hexdigest())
            (LOGS / "coverage-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        command = ["hermes-sim-task", "--name", "Morsel260-Matcher-iPhone16", "--device-type",
                   "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "--", "python3", str(Path(__file__).resolve()),
                   "--inside", "--label", args.label]
        if args.corpus:
            command += ["--corpus", args.corpus]
        if args.mutation:
            command.append("--mutation")
        return run(args.label + "-wrapper", command, 3000)
    finally:
        if owner.read_text().strip() == str(os.getpid()):
            owner.unlink()
            lock.rmdir()


if __name__ == "__main__":
    sys.exit(main())
