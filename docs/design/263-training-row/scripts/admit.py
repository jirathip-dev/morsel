#!/usr/bin/env python3
"""Brief's bounded render admission; no sibling process is changed."""
from pathlib import Path
import os,sys,subprocess,time,json,shlex
ROOT=Path(__file__).resolve().parents[1]
log=ROOT/'evidence/admission.jsonl';log.parent.mkdir(exist_ok=True)
# Persistent browser harness is the renderer used by this lane, not a competing batch.
# Any other Chrome tree, Xcode, Blender, or explicit render/capture script blocks.
end=time.monotonic()+60
while True:
    raw=subprocess.run(['pgrep','-fl','chrome|blender|render|xcodebuild|xctest'],capture_output=True,text=True).stdout
    ps=subprocess.check_output(['ps','-axo','pid,ppid,pcpu,args'],text=True)
    rows=[]
    for line in ps.splitlines()[1:]:
        cols=line.strip().split(None,3)
        if len(cols)==4 and cols[0].isdigit() and cols[1].isdigit():rows.append((int(cols[0]),int(cols[1]),float(cols[2]),cols[3]))
    ancestors={os.getpid()};p=os.getpid()
    while p>1:
        parent=next((r[1] for r in rows if r[0]==p),1)
        ancestors.add(parent);p=parent
    browser_roots={r[0] for r in rows if '--remote-debugging-port=9333' in r[3] and '--type=' not in r[3]}
    harness=set(browser_roots)
    for _ in range(8):harness.update(r[0] for r in rows if r[1] in harness)
    blocked=[]
    for pid,ppid,cpu,args in rows:
        if pid in ancestors or pid in harness:continue
        # Ignore inspection shell text; classify actual executable/script tokens.
        try: argv=shlex.split(args)
        except ValueError: continue
        if not argv: continue
        executable=Path(argv[0]).name.lower()
        if executable in ['bash','zsh','sh','pgrep']: continue
        names=[Path(a).name.lower() for a in argv[:3]]
        heavy=any(n in ['xcodebuild','xctest','blender','chrome-headless-shell','hermes-sim-task','capture.py','verify.mjs','render.py','ink_capture.py','bounded-run.py'] or n.startswith(('render_','capture_')) for n in names)
        heavy=heavy or any(n in ['pipeline.py','proofs.py','run_batch.py'] for n in names) and '/262-library-expansion/' in args
        if heavy: blocked.append(dict(pid=pid,cpu=cpu,args=args))
    rec=dict(timestamp=time.strftime('%Y-%m-%dT%H:%M:%S%z'),pgrep_raw=raw,blocked=blocked,harness_pids=sorted(harness),free_bytes=__import__('shutil').disk_usage(ROOT).free)
    priority=ROOT/'evidence/priority-262.json'
    held=False
    if priority.exists():
        policy=json.loads(priority.read_text());held=policy.get('hold',False)
        witness=Path(policy.get('release_file','/nonexistent'))
        if held and witness.is_file():
            try: released=json.loads(witness.read_text()).get('status')=='PASS'
            except (ValueError,OSError): released=False
            if released:
                policy.update(hold=False,released_at=rec['timestamp'],witness_status='PASS')
                priority.write_text(json.dumps(policy,indent=2)+'\n');held=False
        rec['priority_262_hold']=held
    rec['decision']='ADMIT' if not blocked and not held and rec['free_bytes']>1024**3 else 'WAIT'
    with log.open('a') as f:f.write(json.dumps(rec)+'\n')
    if rec['decision']=='ADMIT':
        print('ADMIT: no competing heavy render/build; existing CDP harness only.');sys.exit(0)
    if time.monotonic()>=end:
        print('DEFER: 60-second admission window ended; no render started.',[(b['pid'],b['args'][:110]) for b in blocked], 'priority_262_hold='+str(held));sys.exit(75)
    time.sleep(min(10,max(0,end-time.monotonic())))
