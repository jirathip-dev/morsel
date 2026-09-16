import { describe, expect, it } from 'vitest'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'

const read = (path: string): string => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
const doc = read('docs/NATIVE_JOURNAL_PROVENANCE.md')
const normalized = (text: string): string => text.replace(/\s+/g, ' ').trim()

function section(heading: string): string {
  const matches = doc.split(/^## /m).filter(part => part.startsWith(`${heading}\n`))
  expect(matches, `one ${heading} section`).toHaveLength(1)
  return matches[0]?.slice(heading.length).trim() ?? ''
}

// These pins preserve the recorded decision, not assertions about today's UI.
// Prose may be rewrapped; changing its meaning requires reviewing the pins too.
describe('native journal provenance (#249)', () => {
  it('records the compression decision and historical limits', () => {
    const decision = normalized(section('Decision'))
    expect(decision).toContain(normalized(`Keep the short in-source comments introduced by #168 / PR #246, but retain
      all removed comment lines here rather than letting the 400-line file budget
      silently erase their rationale. No further provenance is removed from
      \`MorselApp.swift\` or \`ViewModel.swift\` for this fix; only pointers to this note
      are added there, without changing behavior or exceeding the line budget.`))
    expect(decision).toContain(normalized(`This note is the repository entry point for #110, #112, #121, #153, #173,
      #175 and #176. The excerpts below are historical rationale, not a claim that
      every original UI placement remains current (for example, row artwork now
      uses illustrations rather than the older thumbnail presentation).`))
    const source = '6f87585d2a8c1bac49237a7a4ac6654297619dbb'
    for (const file of ['MorselApp.swift', 'ViewModel.swift']) {
      expect(decision).toContain(`git show ${source}^:app/Sources/Morsel/${file}`)
    }
    expect(decision).toContain(`git show ${source} -- app/Sources/Morsel/MorselApp.swift app/Sources/Morsel/ViewModel.swift`)
  })

  it.each([
    ['#110', '`coverColorScheme` reasserts the chosen theme on presented covers, not just the root window.'],
    ['#112 and #173', '`updateCalmStatus` and `syncedKinds` must not confuse an unanswered read-permission prompt with permission granted or denied. HealthKit share status cannot prove read permission. Only matching per-type upload timestamps can name the kinds that actually synced; async checks keep the MainActor responsive. See also the import-pass excerpts below.'],
    ['#121', '`timezoneSync` mirrors the device zone on launch/foreground so app and server bucket the same local days. Calendar arithmetic, not fixed 86,400-second offsets, remains authoritative. See [local days](DATA_MODEL.md#local-days-and-timezones-issue-121).'],
    ['#153', 'the edit sheet inherits the view model from the shell and attaches photos through the existing outbox/image path; queued rows remain pending until authoritative readback.'],
    ['#175', '`JournalPageStage` retains each visited page/model/scroll for the session; accepted navigation, not a transient turn, changes activation.'],
    ['#176', 'pager selection owns interaction; previews/outgoing pages own none. Overlays supersede page interaction. Shell-owned presentations survive turns and inherit the model because the environment wraps their anchor.'],
  ])('retains the %s why-index entry', (issue, rationale) => {
    const entries = section('Where to look for the why').split(/\n(?=- )/).map(normalized)
    expect(entries).toContain(`- ${issue}: ${rationale}`)
  })

  // SHA-256 of the removed // lines, in order with original indentation and
  // LF separators (no final LF), from git show --format= --unified=0 at
  // 6f87585d2a8c1bac49237a7a4ac6654297619dbb, per file. No Git history needed in CI.
  it.each([
    { index: 0, file: 'MorselApp.swift', lines: 28, sha256: '8fafe065c9f4751f58b257edf0bf52e7cee0329d6b60dcc0ea8f3077fb8b2aaf' },
    { index: 1, file: 'ViewModel.swift', lines: 45, sha256: '6d265afe877f832e5cb239a9a6e307ff6e4ea10eb4d6555b65daadb12d54a868' },
  ])('preserves $file archived comment bytes', ({ index, file, lines, sha256 }) => {
    const archive = section('Archived comment lines')
    const blocks = [...archive.matchAll(/```swift\n([\s\S]*?)\n```/g)]
    expect(blocks).toHaveLength(2)
    expect(archive).toContain(`### \`${file}\` (${String(lines)} removed comment lines)`)
    const block = blocks[index]?.[1] ?? ''
    expect(block.split('\n')).toHaveLength(lines)
    expect(createHash('sha256').update(block).digest('hex'), file).toBe(sha256)
  })

  it('keeps the month-span contract and its non-goals', () => {
    expect(normalized(section('Month-span read contract (#249)'))).toBe(normalized(`
      The calendar requests one overview for day 1 through the selected month's
      last elapsed local day. \`HistoryRepository.loadHistory\` admits 1–31 days,
      so a completed 31-day month no longer needs a second first-day overview.
      That second read previously failed before publishing *any* of the loaded
      colours, even though the independent presence index had already published.

      This is one overview operation and one bounded meal-log query, not one HTTP
      request for the entire calendar: the index and the overview's existing
      logs/items/goals/profile/weight/dated-target reads remain separate. No read
      batching, cache policy, target comparison or timezone contract is redesigned.
      \`LocalFirstDashboardRepository\` forwards the requested day count and keys the
      cache by end date plus count, so 30- and 31-day overviews do not collide.
      The History ledger's explicit 7/30-day presets and its fixed 30-day weight
      trend are independent contracts and remain unchanged.

      \`JournalMonthSpanTests\` drives the model through the real Supabase history
      adapter with controlled transport, then makes any second overview's goal
      read fail. Both edge days retain their over-target comparison inputs.
      It also checks short/leap months, partial months and local range boundaries
      across US daylight-saving transitions. Existing calendar/diary tests cover
      presence, navigation, cached-day publication and superseded reads.
    `))
  })

  it('is reachable from the docs index and compressed source comments', () => {
    expect(read('README.md')).toContain('[NATIVE_JOURNAL_PROVENANCE](docs/NATIVE_JOURNAL_PROVENANCE.md)')
    for (const file of ['MorselApp.swift', 'ViewModel.swift']) {
      const source = read(`app/Sources/Morsel/${file}`)
      expect(source).toContain('// see docs/NATIVE_JOURNAL_PROVENANCE.md')
      expect(source.trimEnd().split('\n').length).toBeLessThanOrEqual(400)
    }
  })
})
