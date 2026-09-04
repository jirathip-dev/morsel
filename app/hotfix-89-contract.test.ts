import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Hosted static contract probe for issue #89 (v0.4 hotfix): the app is
// LIGHT-ONLY until the night-ink theme (#90) — UIUserInterfaceStyle Light is
// injected via the Morsel target build setting; the Settings screen renders
// paper + ink (never the stock dark Form); the '+' toolbar control draws
// exactly ONE background (accent fill, ink label per DESIGN.md btn-confirm);
// HealthKit weight-import errors map through a human copy table so raw
// entitlement/domain strings can never reach the UI; and the goals editor
// keeps a bottom content inset clear of the floating tab bar.
//
// Native runtime truth for the copy mapping lives in app/Tests/MorselTests
// (HealthSyncCopyTests); the forced-light mechanism (root modifier — the
// plist route would require the fastlane INFOPLIST_FILE template, which is
// out of scope) is only observable on a rendered scene, so this probe plus
// the dark-appearance simulator screenshots in docs/evidence/hotfix-89/
// are its regression guard. Probe parses the real sources like
// warm-palette.test.ts.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string =>
  readFileSync(join(repoRoot, path), 'utf8')

const views = read('app/Sources/Morsel/Views.swift')
const morselApp = read('app/Sources/Morsel/MorselApp.swift')
const goalsEditor = read('app/Sources/Morsel/GoalsEditor.swift')
const importer = read('app/Sources/Morsel/HealthKitWeightImporter.swift')
const viewModel = read('app/Sources/Morsel/ViewModel.swift')

// r1 review: the token ban must cover EVERY shipped Morsel Swift source —
// enumerate the whole app/Sources/Morsel tree (the xcodegen target includes
// the whole directory), never a hardcoded subset. A banned token injected
// into any previously-unlisted file must RED.
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

// ── WCAG contrast helpers (same math as warm-palette.test.ts) ─────────────
function luminance(hex: string): number {
  const value = hex.replace('#', '')
  const channel = (i: number): number => {
    const c = parseInt(value.slice(i, i + 2), 16) / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4)
}

function contrastRatio(foreground: string, background: string): number {
  const l1 = luminance(foreground)
  const l2 = luminance(background)
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1]
  return (hi + 0.05) / (lo + 0.05)
}

describe('issue #89 hotfix: forced-light appearance contract', () => {
  it('forces the light scheme at the WindowGroup root through the appearance seam', () => {
    // r1 review: pin ROOT placement — the modifier must be attached to the
    // WindowGroup's root content (MorselRootView), not merely present
    // somewhere in the file (a root→Settings relocation must RED here).
    const appStart = morselApp.indexOf('struct MorselApp: App {')
    expect(appStart, 'MorselApp entry must exist').toBeGreaterThan(-1)
    const windowGroup = morselApp.indexOf('WindowGroup {', appStart)
    expect(windowGroup, 'MorselApp must own a WindowGroup').toBeGreaterThan(-1)
    const sliceEnd = morselApp.indexOf('struct MorselConfiguration', windowGroup)
    expect(sliceEnd, 'WindowGroup root slice must have an end anchor').toBeGreaterThan(windowGroup)
    const rootSlice = morselApp.slice(windowGroup, sliceEnd)
    expect(rootSlice, 'root content must consume the appearance seam').toMatch(
      /MorselRootView\([\s\S]*?\)\s*\.preferredColorScheme\(MorselAppearance\.scheme\)/
    )
    expect(rootSlice, 'root must never force dark').not.toContain('.preferredColorScheme(.dark)')
  })

  it('declares the MorselAppearance seam as light', () => {
    const appearance = read('app/Sources/Morsel/MorselAppearance.swift')
    expect(appearance, 'seam must declare the light scheme').toContain(
      'static let scheme: ColorScheme = .light'
    )
    expect(appearance, 'seam must never declare dark').not.toContain('= .dark')
  })

  it('renders the Settings screen on the paper token, never the stock Form background', () => {
    const settingsStart = morselApp.indexOf('private struct SettingsView: View')
    expect(settingsStart, 'SettingsView must exist').toBeGreaterThan(-1)
    const settings = morselApp.slice(settingsStart)
    expect(settings).toContain('.scrollContentBackground(.hidden)')
    expect(settings).toContain('.background(Color.morselBackground.ignoresSafeArea())')
    // Rows/labels carry ink palette foregrounds and morsel section labels.
    expect(settings).toContain('.foregroundStyle(Color.morselInk)')
    expect(settings).toContain('.foregroundStyle(Color.morselInkTwo)')
    const sectionLabels = [...settings.matchAll(/\.morselSectionLabel\(\)/g)].length
    expect(sectionLabels, 'Goals and Agent section headers use the morsel label').toBeGreaterThanOrEqual(2)
  })

  it('keeps the Today + control on accent with an ink label, one background, no toolbar glass', () => {
    // iOS 26 always draws its glass container around ToolbarItem content —
    // that is the white halo from Guy's screenshot — so the control lives in
    // the Today content header where it owns exactly one background.
    expect(views, 'no ToolbarItem may wrap the + control').not.toContain('ToolbarItem(placement: .topBarTrailing)')
    const match = /Button \{\s*isShowingAddMeal = true\s*\} label: \{([\s\S]*?)\.buttonStyle\(\.plain\)/.exec(views)
    expect(match, '+ control must exist as a plain-styled content button').toBeTruthy()
    const control = match![1]
    expect(control, 'label must be ink on the accent fill').toMatch(
      /\.font\(\.morselBodyStrong\)\.foregroundStyle\(Color\.morselInk\)/
    )
    expect(control, 'label must carry the accent fill').toContain(
      '.background(Color.morselAccent, in: RoundedRectangle(cornerRadius: 8))'
    )
    const backgrounds = [...control.matchAll(/\.background\(/g)].length
    expect(backgrounds, 'exactly one drawn background on the + control').toBe(1)
  })

  it('keeps a bottom content inset in the goals editor clear of the floating tab bar', () => {
    const start = goalsEditor.indexOf('struct GoalsEditorView: View')
    expect(start, 'GoalsEditorView must exist').toBeGreaterThan(-1)
    const editor = goalsEditor.slice(start)
    expect(editor).toContain('.padding(.bottom, 96)')
  })
})

describe('issue #89 hotfix: HealthKit error-to-copy mapping contract', () => {
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
    // r1 review: the enumeration above covers the WHOLE app/Sources/Morsel
    // target (all tracked/target .swift files), not a hardcoded subset —
    // an injected token in any file must RED.
    expect(shippedSwiftFiles.length, 'shipped Swift source enumeration must not be empty').toBeGreaterThanOrEqual(20)
    for (const [text, where] of shippedSwiftSources) {
      expect(text, `${where} must not contain an entitlement string`).not.toContain('com.apple.developer')
      expect(text, `${where} must not contain an HKError token`).not.toContain('HKError')
      expect(text, `${where} must not contain a background-delivery token`).not.toContain('background-delivery')
    }
  })

  it('keeps the toolbar label measurable: ink on accent and on bg both >= 3:1', () => {
    // V1 tokens (designSystem contract; same values pinned by warm-palette).
    const ink = '#2A261F'
    const accent = '#E66A2C'
    const bg = '#FFF7E8'
    const inkOnAccent = contrastRatio(ink, accent)
    const inkOnBg = contrastRatio(ink, bg)
    const accentOnBg = contrastRatio(accent, bg)
    // Recorded numbers for the evidence README: ink label on the accent
    // fill 4.63:1, ink against the page 14.13:1, and the accent pill against
    // the cream page 3.05:1 — all >= 3:1 (WCAG 1.4.11 non-text boundary).
    expect(inkOnAccent).toBeGreaterThanOrEqual(3)
    expect(inkOnBg).toBeGreaterThanOrEqual(3)
    expect(accentOnBg).toBeGreaterThanOrEqual(3)
  })
})
