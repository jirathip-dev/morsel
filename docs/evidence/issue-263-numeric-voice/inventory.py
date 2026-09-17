"""Emit every remaining mono face/use as TSV; reject any unclassified site."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
SOURCES = ROOT / 'app/Sources/Morsel'
PATTERN = re.compile(r'morselMono(?:Medium)?\b|\.morsel(?:Data(?:Medium)?|Hero|Gauge)\b|'
                     r'Font\.custom\("(?:IBM Plex|IBMPlex)|\.monospaced\(|design:\s*\.monospaced')
EXPECTED = {'AuthView.swift': 1, 'Onboarding.swift': 3, 'SettingsView.swift': 4,
            'EndpointCopyPill.swift': 1, 'DesignSystem.swift': 7}


def inventory():
    rows = []
    counts = {}
    for path in sorted(SOURCES.glob('*.swift')):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            text = line.strip()
            if text.startswith('//') or 'LinearGradient(' in text or not PATTERN.search(text):
                continue
            counts[path.name] = counts.get(path.name, 0) + 1
            kind = 'kept technical string'
            if path.name == 'AuthView.swift' or (path.name == 'Onboarding.swift' and 'Text("morsel")' in text):
                reason = 'Explicitly retained wordmark exception (brand, not technical)'
            elif path.name == 'Onboarding.swift':
                reason = 'MCP endpoint URL' if 'Text(value)' in text else 'Copy-paste setup prompt'
            elif path.name == 'SettingsView.swift':
                reason = 'Retained settings endpoint/configuration block or settings-row SF Symbol'
            elif path.name == 'EndpointCopyPill.swift':
                reason = 'Retained copy pill'
            elif path.name == 'DesignSystem.swift':
                kind = 'deliberate documented exception'
                reason = ('Unused morselTag helper; no production caller' if 'font(.morselData)' in text
                          else 'Preserved mono factory/token, not a rendered number-bearing call site')
            else:
                raise ValueError(f'Unclassified mono site: {path.name}:{number}: {text}')
            rows.append((str(path.relative_to(ROOT)), str(number), kind, reason, text))
    if counts != EXPECTED:
        raise ValueError(f'Mono coverage changed: actual={counts}, approved={EXPECTED}')
    scope_note = ('# deliberate documented exception: app/Sources/Morsel/TrainingFuelViews.swift; '
                  '0 mono-face sites after half-(a); local TrainingDayType is outside the approved surface list.\n')
    return ('path\tline\tclassification\treason\tsource\n'
            + ''.join('\t'.join(row) + '\n' for row in rows) + scope_note)


if __name__ == '__main__':
    output = inventory()
    target = Path(__file__).with_name('remaining-mono.tsv')
    if sys.argv[1:] == ['--check']:
        if not target.exists() or target.read_text() != output:
            raise SystemExit('Remaining mono inventory drift; regenerate and review')
        print('Remaining mono inventory matches: 9 kept sites; 7 deliberate declaration/helper exceptions')
    elif not sys.argv[1:]:
        print(output, end='')
    else:
        raise SystemExit('Usage: inventory.py [--check]')
