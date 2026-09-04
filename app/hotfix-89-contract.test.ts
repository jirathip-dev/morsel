import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #89 → #94 contract probe. The v0.4 forced-LIGHT mechanism was
// superseded by the V1 appearance seam (Paper / Night ink / Follow system —
// pinned in v1-journal-contract.test.ts). What survives from #89 and remains
// normative here: the root modifier chain through the appearance seam, the
// '+' control living in content (never a toolbar glass item, exactly one
// drawn background), the goals editor keeping a bottom inset clear of the
// floating bar, the Settings page rendering on the paper token (never the
// stock Form background), and the HealthKit human-copy mapping so raw
// entitlement/domain text can never reach the UI.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string =>
  readFileSync(join(repoRoot, path), 'utf8')

const views = read('app/Sources/Morsel/Views.swift')
const morselApp = read('app/Sources/Morsel/MorselApp.swift')
const journalUI = read('app/Sources/Morsel/JournalUI.swift')
const goalsEditor = read('app/Sources/Morsel/GoalsEditor.swift')
const settings = read('app/Sources/Morsel/SettingsView.swift')
const appearance = read('app/Sources/Morsel/MorselAppearance.swift')
const importer = read('app/Sources/Morsel/HealthKitWeightImporter.swift')
const viewModel = read('app/Sources/Morsel/ViewModel.swift')

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

describe('V1 root appearance chain (supersedes the #89 forced light)', () => {
  it('consumes the theme seam at the WindowGroup root through scheme(for:)', () => {
    const appStart = morselApp.indexOf('struct MorselApp: App {')
    expect(appStart, 'MorselApp entry must exist').toBeGreaterThan(-1)
    const windowGroup = morselApp.indexOf('WindowGroup {', appStart)
    expect(windowGroup, 'MorselApp must own a WindowGroup').toBeGreaterThan(-1)
    const sliceEnd = morselApp.indexOf('struct MorselConfiguration', windowGroup)
    expect(sliceEnd, 'WindowGroup root slice must have an end anchor').toBeGreaterThan(windowGroup)
    const rootSlice = morselApp.slice(windowGroup, sliceEnd)
    expect(rootSlice, 'root must consume the appearance seam').toMatch(
      /MorselRootView\([\s\S]*?\)\s*\.preferredColorScheme\(\s*MorselAppearance\.scheme\(for:/
    )
    // No unconditional force-light (or force-dark) may survive the seam.
    expect(rootSlice, 'root must never force light unconditionally').not.toContain('.preferredColorScheme(.light)')
    expect(rootSlice, 'root must never force dark').not.toContain('.preferredColorScheme(.dark)')
  })

  it('declares the V1 preference mapping with Paper the default', () => {
    expect(appearance).toContain('static let defaultThemePreference: MorselThemePreference = .paper')
    expect(appearance, 'Paper must map to light').toMatch(/case \.paper: return \.light/)
    expect(appearance, 'Night ink must map to dark').toMatch(/case \.nightInk: return \.dark/)
    expect(appearance, 'Follow system must not force a scheme').toMatch(/case \.followSystem: return nil/)
    expect(appearance, 'the old single .light seam is gone').not.toContain('scheme: ColorScheme = .light')
  })
})

describe('V1 shell chrome (supersedes #89 item 3/5 chrome fixes)', () => {
  it('keeps the Today + control in content — paper tab with one background, no toolbar glass', () => {
    expect(views, 'no ToolbarItem may wrap the + control').not.toContain('ToolbarItem(placement: .topBarTrailing)')
    expect(views, 'Today must use the V1 torn-paper AddMealTab').toContain('AddMealTab()')
    const tabStart = journalUI.indexOf('struct AddMealTab: View')
    expect(tabStart, 'AddMealTab must be defined in the journal chrome').toBeGreaterThan(-1)
    const tab = journalUI.slice(tabStart)
    const backgrounds = [...tab.matchAll(/\.background\(/g)].length
    expect(backgrounds, 'exactly one drawn background on the add tab').toBe(1)
    expect(tab, 'the plus glyph is a hand-drawn mark').toContain('InkPlus()')
  })

  it('keeps a bottom content inset in the goals editor clear of the floating tab bar', () => {
    const start = goalsEditor.indexOf('struct GoalsView: View')
    expect(start, 'GoalsView must exist').toBeGreaterThan(-1)
    const editor = goalsEditor.slice(start)
    expect(editor).toContain('bottomInset: 56')
  })

  it('renders the Settings page on the paper token, never a stock Form ground', () => {
    const start = settings.indexOf('struct SettingsJournalView: View')
    expect(start, 'SettingsJournalView must exist').toBeGreaterThan(-1)
    const page = settings.slice(start)
    expect(page).toContain('.background(Color.morselBackground.ignoresSafeArea())')
    expect(page).toContain('JournalPageFurniture(date: Date())')
    const sectionLabels = [...page.matchAll(/\.morselSectionLabel\(\)/g)].length
    expect(sectionLabels, 'Appearance/MCP/Health sections use the journal label').toBeGreaterThanOrEqual(3)
  })

  it('offers Paper / Night ink / Follow system in Settings Appearance', () => {
    expect(settings).toMatch(/ForEach\(MorselThemePreference\.allCases, id: \\.self\)/)
    expect(settings).toContain('themePreferenceRaw = preference.rawValue')
  })
})

describe('issue #89 HealthKit error-to-copy mapping contract (unchanged)', () => {
  it('maps every weightImportError assignment through the human copy table', () => {
    expect(viewModel).not.toContain('weightImportError = error.localizedDescription')
    const mapped = [...viewModel.matchAll(/weightImportError = HealthSyncUserMessage\.userMessage\(for: error\)/g)].length
    expect(mapped, 'both observer-callback and catch paths must map').toBe(2)
  })

  it('declares the human background-sync copy table in the importer', () => {
    expect(importer).toContain(
      'static let backgroundSyncUnavailable =\n        "Background Health sync is unavailable — open the app to refresh."'
    )
    expect(importer).toContain('static func userMessage(for error: Error) -> String')
  })

  it('bans raw entitlement/domain tokens from every shipped Swift source', () => {
    expect(shippedSwiftFiles.length, 'shipped Swift source enumeration must not be empty').toBeGreaterThanOrEqual(20)
    for (const [text, where] of shippedSwiftSources) {
      expect(text, `${where} must not contain an entitlement string`).not.toContain('com.apple.developer')
      expect(text, `${where} must not contain an HKError token`).not.toContain('HKError')
      expect(text, `${where} must not contain a background-delivery token`).not.toContain('background-delivery')
    }
  })
})
