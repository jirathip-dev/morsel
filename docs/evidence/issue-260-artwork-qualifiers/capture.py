#!/usr/bin/env python3
"""Capture the real XCTest-mounted app windows with simctl, never render substitutes.

Run from the lane root:

  python3 docs/evidence/issue-260-artwork-qualifiers/capture.py <simulator-UDID> [derived-data-path]

It owns the handshake directory, runs the focused native surface test itself,
and after every frame saves an unmodified `xcrun simctl io <udid> screenshot`
PNG plus a durable `captures.json` inventory entry (path, fixture, dimensions,
raw screenshot exit, SHA-256). A frame is acknowledged only after simctl returns
zero, so a screenshot can never be attributed to a later UI state.
"""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time

EXPECTED_FRAMES = 42
root = Path(__file__).resolve().parents[3]
evidence = Path(__file__).resolve().parent
handshake = Path('/tmp/m260-capture')
udid = sys.argv[1]
derived = sys.argv[2] if len(sys.argv) > 2 else '/tmp/morsel-260-dd'
log = root / '.lane-logs' / 'issue-260-capture-native.log'
log.parent.mkdir(exist_ok=True)
assert not handshake.exists(), 'retire the handshake of an earlier run first'
handshake.mkdir()
(handshake / 'enabled').touch()
output = evidence / 'captures'
output.mkdir(exist_ok=True)
frames = []
child = None
try:
    environment = dict(os.environ, HERDR_XCODEBUILD_DIRECT='1')
    command = [
        'xcodebuild', 'test', '-project', 'app/Morsel.xcodeproj', '-scheme', 'Morsel',
        '-destination', 'platform=iOS Simulator,id=' + udid, '-derivedDataPath', derived,
        '-only-testing:MorselTests/FoodArtworkQualifierSurfaceTests'
    ]
    print('NATIVE_COMMAND=' + repr(command), flush=True)
    child = subprocess.Popen(command, cwd=root, env=environment, stdout=log.open('w'), stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 1800
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
        assert all(character.isalnum() or character == '-' for character in name)
        path = output / (name + '.png')
        shot = ['xcrun', 'simctl', 'io', udid, 'screenshot', str(path)]
        result = subprocess.run(shot, capture_output=True, text=True, timeout=30)
        print(f'COMMAND={shot!r} RAW_EXIT={result.returncode}', flush=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        data = path.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', data[16:24])
        entry.update(file='captures/' + path.name, udid=udid, width=width, height=height,
                     sha256=hashlib.sha256(data).hexdigest(), raw_exit=result.returncode)
        frames.append(entry)
        (evidence / 'captures.json').write_text(json.dumps(frames, indent=2, ensure_ascii=False) + '\n')
        ack.touch()
    print('NATIVE_RUNNER_EXIT=' + str(child.returncode), flush=True)
    assert child.returncode == 0, 'native test run failed; retained captures are partial evidence only'
    assert len(frames) == EXPECTED_FRAMES, f'incomplete capture inventory: {len(frames)}'
    assert len({frame['name'] for frame in frames}) == EXPECTED_FRAMES, 'duplicate frame names'
finally:
    (handshake / 'enabled').unlink(missing_ok=True)
    if child is not None and child.poll() is None:
        child.terminate()
    for path in handshake.iterdir():
        path.unlink()
    handshake.rmdir()
