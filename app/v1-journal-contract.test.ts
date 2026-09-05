import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #94 — V1 field-journal native UI contract probe (source-level, hosted
// so npm test bites Swift edits on ubuntu): Today · History · Goals are the
// primary tabs (Settings behind the toothed cog, never a tab), the Today hero
// is the hand-inked ring + macro wash strips over warm paper, Paper and
// Night ink ship through the dual DesignSystem tokens, and the eaten-vs-goal
// semantics hold: activity is a margin note that is NEVER subtracted — the
// legacy net-energy display path is gone from every shipped Swift source.
// Native runtime truth lives in app/Tests/MorselTests (AppearanceThemeTests,
// JournalSemanticsTests); this probe pins the shipped UI wiring.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const morselApp = read('app/Sources/Morsel/MorselApp.swift')
const appearance = read('app/Sources/Morsel/MorselAppearance.swift')
const views = read('app/Sources/Morsel/Views.swift')
const marginNote = read('app/Sources/Morsel/MorselStamp.swift')
const todayLogViews = read('app/Sources/Morsel/TodayLogViews.swift')
const journalUI = read('app/Sources/Morsel/JournalUI.swift')
const history = read('app/Sources/Morsel/HistoryView.swift')
const historyLedger = read('app/Sources/Morsel/HistoryLedgerViews.swift')
const historyModels = read('app/Sources/Morsel/HistoryModels.swift')
const goals = read('app/Sources/Morsel/GoalsEditor.swift')
const settings = read('app/Sources/Morsel/SettingsView.swift')
const designSystem = read('app/Sources/Morsel/DesignSystem.swift')
const designMd = read('docs/DESIGN.md')
const tokensDoc = read('docs/evidence/issue-90/tokens.md')

function swiftFilesUnder(relativeDir: string): string[] {
  const absoluteDir = join(repoRoot, relativeDir)
  const files: string[] = []
  for (const entry of readdirSync(absoluteDir, { withFileTypes: true })) {
    const relative = join(relativeDir, entry.name)
    if (entry.isDirectory()) {
      files.push(...swiftFilesUnder(relative))
    } else if (entry.name.endsWith('.swift')) {
      files.push(relative)
    }
  }
  return files.sort()
}

const shippedSwiftFiles = swiftFilesUnder('app/Sources/Morsel')
const shippedSwiftSources: Array<[string, string]> = shippedSwiftFiles.map((file) => [
  read(file),
  file.replace('app/Sources/Morsel/', ''),
])

describe('issue #94: primary navigation is Today · History · Goals', () => {
  it('declares exactly the three primary tabs and renders each in the shell', () => {
    const enumStart = morselApp.indexOf('enum JournalTab: String, CaseIterable, Hashable')
    expect(enumStart, 'JournalTab enum must exist').toBeGreaterThan(-1)
    const enumEnd = morselApp.indexOf('private struct AuthenticatedDashboardView', enumStart)
    const tabEnum = morselApp.slice(enumStart, enumEnd)
    expect(tabEnum).toContain('case today')
    expect(tabEnum).toContain('case history')
    expect(tabEnum).toContain('case goals')
    expect(tabEnum, 'no secondary settings tab may exist').not.toMatch(/case (settings|more)\b/)
    expect(tabEnum, 'goals must not hide behind a route').not.toMatch(/route|secondary/i)

    const shellStart = morselApp.indexOf('private struct AuthenticatedDashboardView: View')
    expect(shellStart).toBeGreaterThan(-1)
    const shell = morselApp.slice(shellStart)
    // pageContent switch renders the real views per tab, in order.
    const switchStart = shell.indexOf('private var pageContent: some View')
    expect(switchStart, 'shell must own a pageContent switch').toBeGreaterThan(-1)
    const switchBody = shell.slice(switchStart, shell.indexOf('/// Scoped orange action tint'))
    expect(switchBody).toMatch(/case \.today:[\s\S]*?TodayView\(/)
    expect(switchBody).toMatch(/case \.history:[\s\S]*?HistoryView\(/)
    expect(switchBody).toMatch(/case \.goals:[\s\S]*?GoalsView\(/)
    // Settings is a full-screen cover behind the cog, not tab content.
    expect(shell).toContain('.fullScreenCover(isPresented: $showingSettings)')
    expect(shell).toContain('SettingsJournalView(')
    expect(shell, 'goals editor must be presented as a primary tab root, not a NavigationLink').not.toContain(
      'NavigationLink("Daily goals")'
    )
  })

  it('keeps History and Goals screens journaled with the ledger semantics', () => {
    expect(history).toContain('struct HistoryView: View')
    expect(history).toContain('"Days vs goal"')
    expect(history).toContain('tap a day to open it')
    expect(history).toContain('Text("see all")')
    expect(historyLedger).toContain('"today · partial"')
    expect(goals).toContain('struct GoalsView: View')
    expect(goals).toContain('"Use these goals"')
    expect(goals).toContain('"What changes"')
  })
})

describe('issue #94: eaten-vs-goal semantics — net-energy display paths are gone', () => {
  // Banned double-count/net forms (mirrors the issue #93 banned inventory,
  // scoped to display/instruction forms with word boundaries).
  const bannedForms = [
    /\bn[e]t[- ]?intake\b/i,
    /\bn[e]t\s+en[e]rgy\b/i,
    /n[e]tEn[e]rgy/,
    /n[e]tIntake/,
    /\bminus\s+(?:activ[e]?|burned?|energy)\b/i,
    /\b(?:subtract|deduct)\w*\s+(?:activ[e]?|burned?|energy)\b/i,
    /intake\s*-\s*activeBurn/,
    /\bdouble-?count\b/i,
  ]

  it('bans every net-energy/double-count form from every shipped Swift source', () => {
    expect(shippedSwiftFiles.length, 'shipped Swift source enumeration must not be empty').toBeGreaterThanOrEqual(20)
    for (const [text, where] of shippedSwiftSources) {
      for (const banned of bannedForms) {
        expect(banned.test(text), `${where} must not contain ${banned}`).toBe(false)
      }
    }
  })

  it('bans the net framing from the normative DESIGN.md too', () => {
    for (const banned of bannedForms) {
      expect(banned.test(designMd), `DESIGN.md must not contain ${banned}`).toBe(false)
    }
    // Required locked semantics present (whitespace-tolerant for wraps).
    expect(designMd).toMatch(/never\s+subtracted/i)
    expect(designMd).toMatch(/eaten\s+vs\s+goal/i)
    expect(designMd).toMatch(/under\s*\/\s*on\s+target\s*\/\s*over/i)
    expect(tokensDoc).toMatch(/never\s+subtracted/i)
  })

  it('shows the activity margin note that is never an operand', () => {
    const hero = views.slice(views.indexOf('private struct JournalHeroView'))
    // Issue #113 C: the hero renders the note through the shared builder
    // (moved X kcal [· Apple Health · HH:mm from the #112 stamp]).
    expect(hero).toMatch(/ActiveEnergyMarginNote\.line\(/)
    expect(hero).toContain('lastImport: viewModel.lastHealthImportDate')
    expect(marginNote).toMatch(/moved\b[\s\S]{0,80}?\bkcal/)
    expect(marginNote, 'the margin note must never be subtracted').not.toMatch(/subtract|minus|intake/i)
    expect(hero, 'the hero must render left/over words against the goal').toMatch(/kcal left/)
    expect(hero).toMatch(/kcal over/)
    expect(hero).toContain('activeEnergyBurned')
    expect(hero, 'the hero must never compose the margin copy inline').not.toMatch(/kcal today/)
  })

  it('keeps the one-delta math: eaten minus goal with the ±50 state words', () => {
    const models = shippedSwiftSources.find(([, where]) => where === 'Models.swift')?.[0] ?? ''
    expect(models).toContain('eatenMinusGoal')
    expect(models).toContain('onTargetToleranceKcal = 50.0')
    expect(historyModels).toMatch(/return "under"/)
    expect(historyModels).toMatch(/return "on target"/)
    expect(historyModels).toMatch(/return "over"/)
  })
})

describe('issue #94: V1 journal hierarchy is implemented natively', () => {
  it('builds the Today hero from the journal chrome (ring + wash strips)', () => {
    expect(views).toContain('JournalCalorieRing(')
    expect(views).toContain('MacroWashStrip(')
    expect(views).toMatch(/\.morselProteinWash/)
    expect(views).toMatch(/\.morselCarbsWash/)
    expect(views).toMatch(/\.morselFatWash/)
    expect(journalUI, 'ring contour must be inkline').toMatch(/struct JournalCalorieRing[\s\S]*?Color\.morselInkLine/)
    expect(journalUI).toContain('.trim(from: 0')
    expect(journalUI, 'macro strips carry the inkline goal tick').toContain('Color.morselInkLine')
    expect(journalUI).toContain('WashEdgeShape')
  })

  it('ships the dual-token system and registered journal fonts', () => {
    expect(designSystem).toContain('Color.morselJournal(paper:')
    expect(designSystem).toContain('MorselPalette.inkline')
    expect(designSystem).toMatch(/bundledFontFileNames = \[/)
    expect(designSystem).toContain('Caveat[wght]')
    expect(designSystem).toContain('EBGaramond[wght]')
    expect(designSystem).toContain('IBMPlexMono-Regular')
    expect(designSystem).toMatch(/Font\.custom\("Caveat", size:/)
    expect(designSystem).toMatch(/Font\.custom\("EB Garamond", size:/)
    expect(designSystem).toMatch(/Font\.custom\("IBM Plex Mono", size:/)
  })

  it('keeps the journal pages warm-paper in both themes and Settings V1', () => {
    expect(views).toContain('JournalPage(')
    expect(history).toContain('JournalPage(')
    expect(goals).toContain('JournalPage(')
    expect(journalUI).toContain('struct JournalPage<Content: View>')
    expect(journalUI).toContain('struct JournalPageFurniture')
    expect(settings).toContain('active energy is a margin note, never subtracted')
    expect(settings).toContain('Replay onboarding')
    expect(settings).toContain('Sign out')
    expect(appearance).toContain('MorselThemePreference: String, CaseIterable, Sendable')
  })

  it('keeps honest states (no invented values, friendly copy only)', () => {
    const todayLog = todayLogViews
    expect(todayLog).toContain('No meals logged for this date.')
    const hero = views.slice(views.indexOf('private struct JournalHeroView'))
    expect(hero).toContain('Goal unavailable')
    // Friendly-boundary copy: never raw Supabase text in UI. Issue #106:
    // MealRepository.swift classifies the SDK's PostgrestError SQLSTATE
    // codes into retry categories (permanent auth/validation vs transient)
    // — the type name is backend plumbing, never user-facing copy.
    const rawTokenAllowlist = new Set(['MealRepository.swift'])
    for (const [text, where] of shippedSwiftSources) {
      const banned = rawTokenAllowlist.has(where)
        ? /status_code|connection refused|Network request failed/i
        : /PostgREST|status_code|connection refused|Network request failed/i
      expect(text, `${where} must not embed raw backend error copy`).not.toMatch(banned)
      expect(text, `${where} must not embed raw URL errors`).not.toMatch(/supabase\.co\/rest/i)
    }
  })
})
