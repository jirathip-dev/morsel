"""Run via flock /tmp/n.lock hermes-sim-task -- python3 <this file>.

Only an owned git-archive copy is mutated. The original checkout is hash-pinned.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[4]
LOGS = ROOT / '.lane-logs'
RELATIVE = Path('app/Sources/Morsel/Views.swift')
FILTER = '-only-testing:MorselTests/HeroDatedTargetTests/testPastUsesSavedCaloriesAndMacrosNotTodaysGoal'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(name, command, cwd, timeout=900):
    with (LOGS / (name + '.log')).open('w') as log:
        log.write('COMMAND=' + json.dumps(command) + '\n'); log.flush()
        process = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            status = process.wait(timeout=30)
            log.write('DEADLINE_EXCEEDED=true\n')
        log.write(f'\nRAW_EXIT={status}\n')
    print(f'{name}: RAW_EXIT={status}', flush=True)
    return status


def main():
    udid = os.environ['SIMULATOR_UDID']  # admission/ownership wrapper is mandatory
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    original = (ROOT / RELATIVE).read_bytes()
    archive = subprocess.check_output(['git', 'archive', head], cwd=ROOT)
    directory = Path(tempfile.mkdtemp(prefix='morsel-286-mutation-', dir='/tmp'))
    (directory / '.lane-owned').touch()
    tree = directory / ROOT.name
    tree.mkdir()
    tarfile.open(fileobj=io.BytesIO(archive)).extractall(tree, filter='data')
    victim = tree / RELATIVE
    backup = victim.read_bytes()
    assert backup == original, 'commit production changes before probing'
    receipt = {'head': head, 'tree': str(tree), 'udid': udid, 'before_sha256': digest(backup)}
    old = b'isToday ? trainingFuel.baseline : viewModel.snapshot?.datedTarget?.attributableGoal(on: viewModel.selectedDate)'
    assert backup.count(old) == 1
    try:
        assert run('mutation-xcodegen', ['xcodegen', 'generate'], tree / 'app', 60) == 0
        victim.write_bytes(backup.replace(old, b'trainingFuel.baseline'))
        receipt['mutated_sha256'] = digest(victim.read_bytes())
        command = ['xcodebuild', 'test', '-project', 'Morsel.xcodeproj', '-scheme', 'Morsel',
                   '-destination', 'platform=iOS Simulator,id=' + udid,
                   '-derivedDataPath', '/tmp/morsel-286-dd', '-parallel-testing-enabled', 'NO',
                   'CODE_SIGNING_ALLOWED=NO', FILTER]
        receipt['red_exit'] = run('mutation-red', command + [
            '-resultBundlePath', str(LOGS / 'mutation-red.xcresult')], tree / 'app')
    finally:
        victim.write_bytes(backup)
        os.utime(victim, None)  # never reuse a mutated incremental build
        receipt['restored_sha256'] = digest(victim.read_bytes())
        receipt['original_checkout_sha256'] = digest((ROOT / RELATIVE).read_bytes())
        (LOGS / 'mutation-bookends.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['restored_sha256'] == receipt['before_sha256'] == receipt['original_checkout_sha256']
    receipt['green_exit'] = run('mutation-green', command + [
        '-resultBundlePath', str(LOGS / 'mutation-green.xcresult')], tree / 'app')
    (LOGS / 'mutation-bookends.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['red_exit'] == 65, receipt
    assert receipt['green_exit'] == 0, receipt
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
