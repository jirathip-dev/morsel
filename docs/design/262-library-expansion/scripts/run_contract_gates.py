#!/usr/bin/env python3
"""Run the retained art-contract suite and a behavioral old-verifier RED witness."""
import os
import re
import shutil
import subprocess
import sys
from pipeline import ROOT, save, require


def main():
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',ART_CONTRACT_FIXTURE=str(ROOT))
    dest=ROOT/'evidence/verifier-audit';dest.mkdir(exist_ok=True)
    original=ROOT/'evidence/contract-tests.log'
    initial=dest/'initial-contract-tests.log'
    if original.is_file() and not initial.exists():shutil.copyfile(original,initial)
    results={}
    for label,script,args,log in (
        ('red','test_evidence_contract.py',['--baseline'],dest/'red.log'),
        ('green','test_evidence_contract.py',[],dest/'green.log'),
        ('library','test_contract.py',[],original)):
        cmd=[sys.executable,str(ROOT/'scripts'/script),*args]
        proc=subprocess.run(cmd,cwd=ROOT,env=env,text=True,capture_output=True,timeout=240)
        text=proc.stdout+proc.stderr
        log.write_text(text+'\nRAW_EXIT='+str(proc.returncode)+'\n')
        found=re.search(r'Ran (\d+) tests?',text)
        failures=re.findall(r'^FAIL: (\S+)',text,re.M)
        errors=re.findall(r'^ERROR: (\S+)',text,re.M)
        results[label]={'raw_exit':proc.returncode,'tests_run':int(found.group(1)) if found else 0,'assertion_failures':failures,'harness_errors':errors,'log':str(log.relative_to(ROOT)),'fixture':'current complete canonical bundle'}
    save(dest/'results.json',results)
    require(results['red']['raw_exit']==1 and results['red']['tests_run']==10 and len(results['red']['assertion_failures'])==8 and not results['red']['harness_errors'],'RED witness mismatch')
    require(results['green']['raw_exit']==0 and results['green']['tests_run']==10,'new evidence contracts failed')
    require(results['library']['raw_exit']==0 and results['library']['tests_run']==13,'library contracts failed')
    save(ROOT/'evidence/contract-tests.json',{'status':'PASS',**results['library']})
    verdict={'status':'PASS','green_tests':results['green']['tests_run']+results['library']['tests_run'],'expected_red_assertion_failures':len(results['red']['assertion_failures']),'harness_errors':0,'results':results}
    save(ROOT/'evidence/contract-suite.json',verdict)
    print(verdict)

if __name__=='__main__':main()
