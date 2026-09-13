from pathlib import Path
import json, subprocess, sys, time
root=Path(__file__).resolve().parent
steps=[(['python3','generate.py'],'generate-run.log',20),(['node','verify.mjs'],'evidence-run.log',150),(['python3','audit.py'],'audit-run.log',20)]
results=[]
for command,log,timeout in steps:
 start=time.monotonic()
 with (root/log).open('w') as stream:
  try:
   result=subprocess.run(command,cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=timeout)
   code=result.returncode
  except subprocess.TimeoutExpired:
   code=124
 results.append(dict(command=command,raw_exit=code,duration_seconds=round(time.monotonic()-start,3),log=log))
 (root/'gate-exits.json').write_text(json.dumps(results,indent=2)+'\n')
 print(f'{" ".join(command)}: raw_exit={code}, log={log}')
 if code:sys.exit(code)
print('PASS lightweight reproduction. No native builds or heavy renders.')
