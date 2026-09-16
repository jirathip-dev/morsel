"""Run under flock /tmp/n.lock + hermes-sim-task; never mutates the lane.

python3 docs/evidence/issue-182-today-refresh/prove.py
Logs and source bookends go to .lane-logs/proof/. The only test omitted at
base is the separate lifecycle suite using NEW APIs; the four base-compatible
production-ViewModel regressions are byte-identical in both legs.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
BASE = "2ddba7e0443c3d05f1345a4ce178738426144781"
OUTPUT = ROOT / ".lane-logs/proof"
OUTPUT.mkdir(parents=True, exist_ok=True)
SOURCES = ["app/Sources/Morsel/" + name for name in ("ViewModel.swift", "MorselApp.swift", "Views.swift")]
LIFECYCLE = "app/Tests/MorselTests/TodayRefreshLifecycleTests.swift"
WITNESSES = ["app/Tests/MorselTests/TodayRefreshRegressionTests.swift",
             "app/Tests/MorselTests/TodayRefreshTestSupport.swift",
             "app/Sources/Morsel/TodayRefreshOwner.swift", "app/Morsel.xcodeproj/project.pbxproj"]


def hashes(checkout):
    return {name: hashlib.sha256((checkout / name).read_bytes()).hexdigest()
            for name in SOURCES + [LIFECYCLE] + WITNESSES}


def run(name, checkout):
    command = ["xcodebuild", "test", "-project", "Morsel.xcodeproj", "-scheme", "Morsel",
               "-destination", "platform=iOS Simulator,id=" + os.environ["SIMULATOR_UDID"],
               "-derivedDataPath", "/tmp/morsel-182-dd",
               "-resultBundlePath", str(scratch / (name + ".xcresult")),
               "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
               "-jobs", "2", "CODE_SIGNING_ALLOWED=NO",
               "-only-testing:MorselTests/TodayRefreshRegressionTests"]
    started = time.monotonic()
    with (OUTPUT / (name + ".log")).open("w") as log:
        log.write("COMMAND " + json.dumps(command) + "\n")
        log.flush()
        process = subprocess.Popen(command, cwd=checkout / "app", stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=900)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
        receipt = dict(command=command, cwd=str(checkout / "app"), raw_exit=code,
                       duration_s=round(time.monotonic() - started, 2))
        log.write("\nRECEIPT " + json.dumps(receipt) + "\n")
    print(name, json.dumps(receipt), flush=True)
    totals = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", (OUTPUT / (name + ".log")).read_text())
    receipt["test_totals"] = [list(map(int, total)) for total in totals]
    return receipt


head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=10).strip()
scratch = Path(tempfile.mkdtemp(prefix="morsel-182-proof-", dir="/tmp"))
(scratch / ".issue-182-owned").touch()
checkout = scratch / ROOT.name
checkout.mkdir()
archive = subprocess.check_output(["git", "archive", "HEAD"], cwd=ROOT, timeout=90)
with tarfile.open(fileobj=io.BytesIO(archive)) as source:
    source.extractall(checkout, filter="data")
lane_before = hashes(ROOT)
original = {name: (checkout / name).read_bytes() for name in SOURCES + [LIFECYCLE]}
record = dict(head=head, base=BASE, scratch=str(scratch), lane_before=lane_before,
              archive_before=hashes(checkout))
try:
    for name in SOURCES:
        (checkout / name).write_bytes(subprocess.check_output(["git", "show", BASE + ":" + name],
                                                            cwd=ROOT, timeout=10))
    (checkout / LIFECYCLE).write_text("// New-API lifecycle cases run at HEAD, not in the base-compatible witness.\n")
    record["base_sources"] = hashes(checkout)
    record["red"] = run("base-red", checkout)
finally:
    for name, data in original.items():
        (checkout / name).write_bytes(data)
        os.utime(checkout / name, None)
    record["archive_restored"] = hashes(checkout)
    record["lane_after"] = hashes(ROOT)
    (OUTPUT / "proof.json").write_text(json.dumps(record, indent=2) + "\n")
assert record["archive_before"] == record["archive_restored"], "archive restore differs"
assert lane_before == record["lane_after"], "lane bytes changed"
record["green"] = run("head-green", checkout)
record["archive_after_green"] = hashes(checkout)
(OUTPUT / "proof.json").write_text(json.dumps(record, indent=2) + "\n")
assert record["red"]["raw_exit"] == 65, "base must fail XCTest assertions (inspect raw log)"
assert any(count == 4 and failed > 0 for count, failed in record["red"]["test_totals"])
assert record["green"]["raw_exit"] == 0, "restored HEAD must pass"
assert [4, 0] in record["green"]["test_totals"], "green must execute all four witnesses"
assert record["archive_after_green"] == record["archive_before"]
print("PROOF_COMPLETE " + str(OUTPUT / "proof.json"), flush=True)
