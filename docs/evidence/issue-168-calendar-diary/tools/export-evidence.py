#!/usr/bin/env python3
"""Export only a complete passing DiaryCapture run; verify source and PNG counts."""
import argparse
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("result", type=pathlib.Path)
parser.add_argument("capture", type=pathlib.Path, help="owned prepare-capture checkout")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[4]
out = pathlib.Path(__file__).resolve().parents[1]
summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(args.result)
], timeout=120))
assert summary["result"] == "Passed", summary
assert summary["passedTests"] == summary["totalTestCount"] == 2, summary
assert summary["failedTests"] == summary["skippedTests"] == summary["expectedFailures"] == 0
sources = json.loads((args.capture / "source-manifest.json").read_text())
for name, digest in sources.items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name

scratch = pathlib.Path(tempfile.mkdtemp(prefix="morsel168-export-"))
marker = scratch / ".issue168-owned"
marker.write_text(str(root))
subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.result),
                "--output-path", str(scratch)], check=True, timeout=180)
attachments = json.loads((scratch / "manifest.json").read_text())
expected = {f"{theme}-{state}" for theme in ("paper", "night") for state in (
    "month-grid", "past-day", "empty-boundary", "past-date-add-route", "mid-flip")}
expected.add("paper-gesture-scroll-proof")
selected = {}
for case in attachments:
    for item in case.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "").split("_", 1)[0]
        if name in expected:
            assert name not in selected, f"duplicate capture: {name}"
            selected[name] = item
assert set(selected) == expected, sorted(expected - set(selected))
shots = out / "screenshots"
shots.mkdir(exist_ok=True)
records = []
for name, item in sorted(selected.items()):
    data = (scratch / item["exportedFileName"]).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", name
    width, height = struct.unpack(">II", data[16:24])
    (shots / f"{name}.png").write_bytes(data)
    records.append({"name": name, "file": f"screenshots/{name}.png", "width": width,
                    "height": height, "sha256": hashlib.sha256(data).hexdigest(),
                    "attachment": item["exportedFileName"]})
(out / "source-manifest.json").write_text(json.dumps(sources, indent=2, sort_keys=True) + "\n")
(out / "capture-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
(out / "capture-manifest.json").write_text(json.dumps({
    "required_capture_count": len(expected) - 1, "capture_count": len(records),
    "result_bundle": str(args.result), "captures": records,
    "fixture_hashes": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in sorted(pathlib.Path(__file__).parent.glob("*.fixture"))}
}, indent=2, sort_keys=True) + "\n")
assert marker.read_text() == str(root)
shutil.rmtree(scratch)
print(f"Exported {len(records)} actual captures; all required states and source hashes verified")
