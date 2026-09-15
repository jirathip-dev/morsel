#!/usr/bin/env python3
"""Prepare a disposable behavioral mutation probe from the delivered sources.

Run JournalCalendarTests and JournalDiaryGestureTests in its Morsel scheme.
Two independently observed faults: remove the empty boundary day, and reverse
adjacency in the SHARED state machine (breaks both day and horizontal turns).
"""
import io
import pathlib
import shutil
import subprocess
import tarfile
import tempfile

root = pathlib.Path(__file__).resolve().parents[4]
scratch = pathlib.Path(tempfile.mkdtemp(prefix="morsel168-mutation-"))
(scratch / ".issue168-owned").touch()
archive = subprocess.check_output(["git", "archive", "HEAD"], cwd=root)
with tarfile.open(fileobj=io.BytesIO(archive)) as source:
    source.extractall(scratch, filter="data")
changed = subprocess.check_output(["git", "ls-files", "-m", "-o", "--exclude-standard"], cwd=root, text=True)
for name in changed.splitlines():
    if name.startswith("app/") and (root / name).is_file():
        (scratch / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, scratch / name)
for file, old, new in [
    ("JournalCalendarModel.swift", "value: -1, to: firstLoggedDay ?? today", "value: 0, to: firstLoggedDay ?? today"),
    ("JournalPageTurner.swift", "adjacent(baseTab, direction)",
     "adjacent(baseTab, direction == .forward ? .backward : .forward)"),
]:
    path = scratch / "app/Sources/Morsel" / file
    content = path.read_text()
    assert content.count(old) == 1, (file, old)
    path.write_text(content.replace(old, new))
subprocess.run(["xcodegen", "generate"], cwd=scratch / "app", check=True)
print(scratch)
