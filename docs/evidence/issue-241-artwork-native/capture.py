#!/usr/bin/env python3
"""Capture the real XCTest-mounted app windows with simctl, never render substitutes.

Run from the lane after configuring .lane-tools/head-green.json and run-native.py:
  python3 docs/evidence/issue-241-artwork-native/capture.py <simulator-UDID>
The native runner owns arbitration/deadlines; this driver acknowledges each frame
only after simctl returns zero and saves a durable JSON inventory after each shot.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[3]
evidence = Path(__file__).resolve().parent
handshake = Path('/tmp/m241-capture')
handshake.mkdir(exist_ok=False)
(handshake / 'enabled').touch()
output = evidence / 'captures'
output.mkdir(exist_ok=True)
frames = []
child = None
try:
    child = subprocess.Popen([sys.executable, str(root / '.lane-tools/run-native.py'), 'head-green'], cwd=root)
    deadline = time.monotonic() + 3000
    while child.poll() is None:
        if time.monotonic() >= deadline:
            raise TimeoutError('capture deadline exceeded')
        request = handshake / 'request.json'
        if not request.exists():
            time.sleep(0.2)
            continue
        entry = json.loads(request.read_text())
        name = entry['name']
        ack = handshake / (name + '.ack')
        if ack.exists():
            time.sleep(0.2)
            continue
        assert all(c.isalnum() or c == '-' for c in name)
        path = output / (name + '.png')
        command = ['xcrun', 'simctl', 'io', sys.argv[1], 'screenshot', str(path)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        print(f'COMMAND={command!r} RAW_EXIT={result.returncode}', flush=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        data = path.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', data[16:24])
        entry.update(file='captures/' + path.name, udid=sys.argv[1], width=width, height=height,
                     sha256=hashlib.sha256(data).hexdigest(), raw_exit=result.returncode)
        frames.append(entry)
        (evidence / 'captures.json').write_text(json.dumps(frames, indent=2, ensure_ascii=False) + '\n')
        ack.touch()
    print('NATIVE_RUNNER_EXIT=' + str(child.returncode), flush=True)
    assert child.returncode == 0, 'native test run failed; retained captures are partial evidence only'
    assert len(frames) == 66 and len({f['name'] for f in frames}) == 66, 'incomplete capture inventory'
finally:
    # Only this run-created handshake is retired; capture evidence is retained.
    (handshake / 'enabled').unlink(missing_ok=True)
    if child is not None and child.poll() is None:
        child.terminate()
    for path in handshake.iterdir():
        path.unlink()
    handshake.rmdir()
