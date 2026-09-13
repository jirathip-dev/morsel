#!/usr/bin/env python3
"""Report observed, separated timing; never infer unmeasured active art time."""
import json
from ink_library import OUT, dump, write


def run():
    ev=OUT/'evidence'
    events=json.loads((ev/'timing-events.json').read_text())
    by_phase={v['phase']:v for v in events}
    def window(a,b):
        return (by_phase[b]['monotonic_ns']-by_phase[a]['monotonic_ns'])/1e9
    a=json.loads((ev/'authoring-produce-protein.json').read_text())
    b=json.loads((ev/'authoring-vessels-fallbacks.json').read_text())
    build=json.loads((ev/'build.json').read_text())
    tests=json.loads((ev/'workflow-tests.json').read_text())
    cases={c['name']:c['detail'] for c in tests['checks']}
    values={
        'six_source_initial_window':a['wall_clock_elapsed_seconds'],
        'seven_source_initial_window':b['elapsed_seconds'],
        'chicken_initial_authoring_window':window('chicken-authoring-start','chicken-authoring-end'),
        'chicken_export_review_correction_window':window('chicken-authoring-end','chicken-correction-end'),
        'session_through_final_visual_review_window':window('full-set-session-start','final-visual-review-end'),
        'final_full_build':build['elapsed_seconds'],
        'renderer_subprocesses_within_build':build['renderer_seconds'],
        'proof_composition':json.loads((ev/'proofs.json').read_text())['seconds'],
        'browser_captures_and_dom_checks':json.loads((ev/'browser.json').read_text())['seconds'],
        'workflow_fixture_suite':tests['seconds'],
        'no_op_build':cases['no-op-preserves-every-export-hash-and-mtime']['elapsed_seconds'],
        'single_source_mutation_build':cases['single-source-real-pixel-change-rebuilds-one-id']['elapsed_seconds'],
        'synthetic_single_addition_build':cases['add-one-study-keeps-existing-136-outputs-untouched']['elapsed_seconds'],
    }
    report={'seconds':values,
            'not_measured_separately':['active uninterrupted drawing time','fallback corrective drawing alone','skill/tooling authoring alone','final documentation and Git handoff'],
            'caveats':['Two source-batch windows overlap; do not sum as project duration.',
                       'Initial source windows include prerequisite reads and tool waits, not final parent correction or review.',
                       'Chicken correction window includes initial render/review and subsequent edits; not pure drawing.',
                       'Session window includes tooling, reads, waits, review and corrections but ends before final documentation/packaging/Git handoff.',
                       'Compiler and synthetic addition timings are machine work only, not creating finished art.']}
    dump(ev/'timing-summary.json',report)
    rows='\n'.join(f'| {key.replace("_"," ")} | {value:.3f} |' for key,value in values.items())
    text='# Timing · measured work, separated\n\n| Observed phase/window | Seconds |\n|---|---:|\n'+rows+'\n\n'
    text+='\n'.join('- '+c for c in report['caveats'])+'\n\n'
    text+='Not separately instrumented: '+', '.join(report['not_measured_separately'])+'. No retroactive estimate is substituted.\n\n'
    text+='The source-batch JSONs preserve initial-stage timestamps/structural reports. Their Grains/Protein hashes predate parent corrections; final bytes are pinned by SHA256SUMS.json. Gate wrappers also record elapsed process time, which includes interpreter overhead and may exceed the inner phase timing. Host conditions varied between runs; this is evidence of this execution, not a throughput benchmark.\n'
    write(ev/'TIMING.md',text)
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    run()
