#!/usr/bin/env python3
"""Run under flock /tmp/n.lock + hermes-sim-task; mutate ONLY an archive.

Usage: hermes-sim-task --name Morsel185 -- python3 <this-file>
Raw logs/receipts go to the checkout's .lane-logs. No live service calls.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
BASE = "2ddba7e0443c3d05f1345a4ce178738426144781"
LOGS = ROOT / ".lane-logs"
LOGS.mkdir(exist_ok=True)
SCRATCH = Path(tempfile.mkdtemp(prefix="morsel-185-"))
(SCRATCH / ".issue-185-owned").touch()
RESULTS = []


def run(name, command, cwd=ROOT, timeout=900):
    log = LOGS / f"{name}.log"
    started = time.monotonic()
    with log.open("w") as output:
        output.write(f"cwd={cwd}\ncommand={shlex.join(command)}\n")
        output.flush()
        child = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        timed_out = False
        try:
            raw_exit = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                raw_exit = child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                raw_exit = child.wait()
        receipt = dict(name=name, command=command, cwd=str(cwd), raw_exit=raw_exit,
                       timed_out=timed_out, seconds=round(time.monotonic() - started, 3), log=str(log))
        output.write(f"\nRECEIPT {json.dumps(receipt)}\n")
    RESULTS.append(receipt)
    (LOGS / "native-receipts.json").write_text(json.dumps(RESULTS, indent=2) + "\n")
    print(json.dumps(receipt), flush=True)
    return raw_exit


def native(name, root, suites):
    binary = subprocess.check_output(["xcrun", "--find", "xcodebuild"], text=True).strip()
    command = [binary, "test", "-project", "Morsel.xcodeproj", "-scheme", "Morsel",
               "-destination", f"platform=iOS Simulator,id={os.environ['SIMULATOR_UDID']}",
               "-derivedDataPath", str(SCRATCH / "DerivedData"),
               "-resultBundlePath", str(SCRATCH / f"{name}.xcresult"),
               "-parallel-testing-enabled", "NO", "-jobs", "2",
               "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "30",
               "CODE_SIGNING_ALLOWED=NO"]
    command += [f"-only-testing:MorselTests/{suite}" for suite in suites]
    return run(name, command, cwd=root / "app")


def hashes(root, paths):
    return {path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in paths}


def main():
    assert os.environ.get("HERMES_SIM_TASK_ACTIVE") == "1", "Use the owned-simulator wrapper"
    assert (Path("/tmp/n.lock") / "owner.pid").is_file(), "Use the shared native admission lock"
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    (LOGS / "native-environment.json").write_text(json.dumps(dict(
        head=head, base=BASE, scratch=str(SCRATCH), simulator=os.environ["SIMULATOR_UDID"]
    ), indent=2) + "\n")
    run("native-disk", ["df", "-h", "/"], timeout=30)
    suites = ["GoalsContextLazyLoadTests", "GoalsDirectionProfileTests", "GoalsEditorTests",
              "GoalsEditorPrecisionTests", "GoalsPageTests", "GoalsPolishTests", "GoalsRestoreTests",
              "GoalsRestoreRenderingTests", "GoalsDirectionRaceTests", "GoalsDirectionOwnershipTests"]
    if native("native-focused", ROOT, suites) != 0:
        return 1

    archive = SCRATCH / ROOT.name
    archive.mkdir()
    data = subprocess.check_output(["git", "archive", "HEAD"], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(data)) as source:
        source.extractall(archive, filter="data")
    (archive / "node_modules").symlink_to(ROOT / "node_modules", target_is_directory=True)
    model = "app/Sources/Morsel/GoalsEditorModel.swift"
    editor = "app/Sources/Morsel/GoalsEditor.swift"
    ownership = "app/Tests/MorselTests/GoalsDirectionOwnershipTests.swift"
    project = "app/Morsel.xcodeproj/project.pbxproj"
    race = "app/Tests/MorselTests/GoalsDirectionRaceTests.swift"
    spy = "app/Tests/MorselTests/GoalsPageRequestSpy.swift"
    paths = [model, editor, ownership, project, race, spy]
    originals = {path: (archive / path).read_bytes() for path in paths}
    bookends = dict(head=head, base=BASE, before=hashes(archive, paths))
    try:
        # Whole base production files, not a hand-recreated bug. The separate
        # new-API suite is omitted; all six base-compatible race cases remain.
        for path in [model, editor]:
            (archive / path).write_bytes(subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT))
        (archive / ownership).unlink()
        bookends["base_sources"] = hashes(archive, [model, editor])
        assert run("base-xcodegen", ["xcodegen", "generate"], cwd=archive / "app", timeout=60) == 0
        red = native("base-red", archive, ["GoalsDirectionRaceTests"])
        text = (LOGS / "base-red.log").read_text()
        assert red == 65 and "XCTAssertEqual failed" in text and "Executed 6 tests" in text, text[-4000:]
    finally:
        for path, content in originals.items():
            (archive / path).write_bytes(content)
        bookends["after"] = hashes(archive, paths)
        bookends["restored_byte_exact"] = bookends["before"] == bookends["after"]
        (LOGS / "restore-bookends.json").write_text(json.dumps(bookends, indent=2) + "\n")
        assert bookends["restored_byte_exact"]
    assert native("archive-green", archive, ["GoalsDirectionRaceTests", "GoalsDirectionOwnershipTests"]) == 0

    # Hosted lifecycle/pending wiring guards must fail on the old view too.
    try:
        (archive / editor).write_bytes(subprocess.check_output(["git", "show", f"{BASE}:{editor}"], cwd=ROOT))
        command = ["npx", "vitest", "run", "app/issue-185-goals-direction-contract.test.ts"]
        assert run("wiring-red", command, cwd=archive, timeout=120) == 1
    finally:
        (archive / editor).write_bytes(originals[editor])
        assert hashes(archive, paths) == bookends["before"]
    assert run("wiring-green", command, cwd=archive, timeout=120) == 0
    print(f"PROOF_COMPLETE scratch={SCRATCH}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
