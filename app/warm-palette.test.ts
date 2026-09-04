import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// V1 palette — "Orange Hearth + Sage" (issue #32) with the Night-ink roles and
// the inkline line token approved for #90 and implemented by #94.
// Authority: docs/evidence/issue-90/tokens.md (promoted contract) and the
// design-output artifacts it was copied from. DesignSystem.swift carries each
// native token as a Paper + Night pair (Color.morselJournal(paper:night:));
// DESIGN.md front matter keeps the scalar colors block (plus inkline); the
// web prototype and the server renderer stay on the scalar V1 set.
//
// This probe parses the real surfaces and asserts: the exact dual hex pairs,
// the DESIGN.md scalar block, the measured gradient documentation, AA for
// strict text pairs in BOTH themes, ≥3:1 for strict marks in both themes, and
// the V1 semantic call-site wiring (journal ring/wash/verify/tab markers).

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const designSystem = read('app/Sources/Morsel/DesignSystem.swift')
const journalUI = read('app/Sources/Morsel/JournalUI.swift')
const views = read('app/Sources/Morsel/Views.swift')
const todayLogViews = read('app/Sources/Morsel/TodayLogViews.swift')
const historyView = read('app/Sources/Morsel/HistoryView.swift')
const goalsEditor = read('app/Sources/Morsel/GoalsEditor.swift')
const morselApp = read('app/Sources/Morsel/MorselApp.swift')
const designMd = read('docs/DESIGN.md')
const prototype = read('docs/prototype.html')
const renderer = read('server/render.ts')
const tokensDoc = read('docs/evidence/issue-90/tokens.md')

// Exact approved V1 scalar contract (paper variants).
const V1: Record<string, string> = {
  ink: '#2A261F',
  ink2: '#655A4B',
  ink3: '#756955',
  bg: '#FFF7E8',
  surface: '#FFFCF5',
  surface2: '#F2E9D9',
  line: '#E3D2BA',
  accent: '#E66A2C',
  accentSoft: '#FBE1C9',
  leaf: '#5E7E57',
  leafSoft: '#E1E9D7',
  forest: '#2F654B',
  coral: '#B94738',
  mustard: '#D6A62C',
  mustardDeep: '#A5750B',
  review: '#7A3D2B',
  over: '#9C3A2F',
}

// The single new line token (#90/#94): warm sepia hand rules/contours.
const INKLINE = '#8B7355'

// Night-ink resolved pairs (same table DesignSystem.swift ships; the
// normative copy is docs/evidence/issue-90/tokens.md — kept in lockstep).
const DUAL: Record<string, { paper: string; night: string }> = {
  morselInk: { paper: V1.ink, night: V1.bg },
  morselInkTwo: { paper: V1.ink2, night: V1.surface2 },
  morselInkThree: { paper: V1.ink3, night: V1.line },
  morselBackground: { paper: V1.bg, night: V1.ink },
  morselSurface: { paper: V1.surface, night: '#373129' },
  morselSurfaceTwo: { paper: V1.surface2, night: '#423B31' },
  morselLine: { paper: V1.line, night: V1.ink3 },
  morselAccent: { paper: V1.accent, night: V1.accent },
  morselAccentSoft: { paper: V1.accentSoft, night: V1.review },
  morselLeaf: { paper: V1.leaf, night: V1.leafSoft },
  morselLeafSoft: { paper: V1.leafSoft, night: V1.forest },
  morselForest: { paper: V1.forest, night: V1.leafSoft },
  morselCoral: { paper: V1.coral, night: V1.accentSoft },
  morselMustard: { paper: V1.mustard, night: V1.mustard },
  morselMustardDeep: { paper: V1.mustardDeep, night: V1.mustardDeep },
  morselReview: { paper: V1.review, night: V1.accentSoft },
  morselOver: { paper: V1.over, night: V1.bg },
  morselInkLine: { paper: INKLINE, night: '#9D917F' },
  morselLabelOnAccent: { paper: V1.ink, night: V1.ink },
  morselProteinWash: { paper: '#BF5546', night: V1.accentSoft },
  morselCarbsWash: { paper: '#AC7F1D', night: V1.mustard },
  morselFatWash: { paper: '#6B8863', night: V1.leafSoft },
  morselTodayWash: { paper: '#E8753B', night: V1.accent },
  morselExcessWash: { paper: '#A4493E', night: V1.over },
}

const RETIRED_PALETTE_HEXES = [
  '#3E63E8', '#E9EEFC', '#6C5CE7', '#0FA6A0', '#9C8BF5', '#37D5C2',
  '#5BD8E6', '#1FA3C4', '#3BC8A8', '#12A98E', '#E0765F', '#3354C7',
  '#6FA7C6', '#1AA3B8', '#D9715D', '#3ED6BE', '#0E9F8A', '#FFB9A8',
  '#FFCF5E',
  '#F08A2E', '#F6E8D8', '#C0483F', '#F0A63C', '#D46A2E', '#FFC24B',
  '#F7A98C', '#FBF9F2', '#FBFAF6', '#F3F1EA', '#E7E3D8', '#20231E',
  '#666A60', '#9BA095',
]

const COOL_COLOR_WORDS = ['cobalt', 'blue', 'teal', 'cyan', 'violet', 'purple']

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

function expectAA(foreground: string, background: string, label: string): number {
  const ratio = contrastRatio(foreground, background)
  expect(
    ratio,
    `${label}: ${foreground} on ${background} is ${ratio.toFixed(2)}:1, below WCAG AA 4.5:1`
  ).toBeGreaterThanOrEqual(4.5)
  return ratio
}

function expectMark(foreground: string, background: string, label: string): number {
  const ratio = contrastRatio(foreground, background)
  expect(
    ratio,
    `${label}: ${foreground} on ${background} is ${ratio.toFixed(2)}:1, below 3:1`
  ).toBeGreaterThanOrEqual(3.0)
  return ratio
}

function countMatches(text: string, re: RegExp): number {
  return [...text.matchAll(re)].length
}

function requireAbsent(text: string, hex: string, where: string) {
  expect(countMatches(text, new RegExp(hex, 'gi')), `${hex} must be gone from ${where}`).toBe(0)
}

/** Parse DESIGN.md front-matter colors block (skipping blank lines). */
function colorsBlockEntries(): string[] {
  const start = designMd.indexOf('colors:\n')
  const stop = designMd.indexOf('typography:\n', start)
  expect(start, 'DESIGN.md front matter must define colors:').toBeGreaterThan(-1)
  expect(stop, 'DESIGN.md front matter must continue past colors:').toBeGreaterThan(start)
  const lines = designMd.slice(start + 'colors:\n'.length, stop).split('\n')
  const entries: string[] = []
  for (const line of lines) {
    if (line.trim() === '') continue
    expect(line, `colors: entries must be quoted scalar colors, got "${line}"`).toMatch(/^  \w+: "#[0-9A-F]{6}"$/)
    entries.push(line)
  }
  return entries
}

/** Parse the MorselPalette table `static let x: Pair = ("#…", "#…")`. */
function palettePairs(): Map<string, { paper: string; night: string }> {
  const map = new Map<string, { paper: string; night: string }>()
  for (const m of designSystem.matchAll(
    /static let (\w+): Pair = \("#([0-9A-F]{6})", "#([0-9A-F]{6})"\)/g
  )) {
    map.set(m[1], { paper: `#${m[2]}`, night: `#${m[3]}` })
  }
  return map
}

/** Token-name → palette-table-name pairing declared via morselJournal(). */
const TOKEN_TABLE: Record<string, string> = {
  morselInk: 'ink',
  morselInkTwo: 'inkTwo',
  morselInkThree: 'inkThree',
  morselBackground: 'background',
  morselSurface: 'surface',
  morselSurfaceTwo: 'surfaceTwo',
  morselLine: 'line',
  morselAccent: 'accent',
  morselAccentSoft: 'accentSoft',
  morselLeaf: 'leaf',
  morselLeafSoft: 'leafSoft',
  morselForest: 'forest',
  morselCoral: 'coral',
  morselMustard: 'mustard',
  morselMustardDeep: 'mustardDeep',
  morselReview: 'review',
  morselOver: 'over',
  morselInkLine: 'inkline',
  morselLabelOnAccent: 'labelOnAccent',
  morselProteinWash: 'proteinWash',
  morselCarbsWash: 'carbsWash',
  morselFatWash: 'fatWash',
  morselTodayWash: 'todayWash',
  morselExcessWash: 'excessWash',
}

describe('V1 dual palette token consistency (Orange Hearth + Sage + inkline, Refs #32/#90/#94)', () => {
  it('declares every V1 scalar + inkline with its exact Paper/Night pair in DesignSystem.swift', () => {
    const parsed = palettePairs()
    expect(parsed.size, 'MorselPalette pairs must exist').toBeGreaterThanOrEqual(24)
    const table = {
      ink: DUAL.morselInk,
      inkTwo: DUAL.morselInkTwo,
      inkThree: DUAL.morselInkThree,
      background: DUAL.morselBackground,
      surface: DUAL.morselSurface,
      surfaceTwo: DUAL.morselSurfaceTwo,
      line: DUAL.morselLine,
      accent: DUAL.morselAccent,
      accentSoft: DUAL.morselAccentSoft,
      leaf: DUAL.morselLeaf,
      leafSoft: DUAL.morselLeafSoft,
      forest: DUAL.morselForest,
      coral: DUAL.morselCoral,
      mustard: DUAL.morselMustard,
      mustardDeep: DUAL.morselMustardDeep,
      review: DUAL.morselReview,
      over: DUAL.morselOver,
      inkline: DUAL.morselInkLine,
      labelOnAccent: DUAL.morselLabelOnAccent,
      proteinWash: DUAL.morselProteinWash,
      carbsWash: DUAL.morselCarbsWash,
      fatWash: DUAL.morselFatWash,
      todayWash: DUAL.morselTodayWash,
      excessWash: DUAL.morselExcessWash,
    }
    for (const [tableName, pair] of Object.entries(table)) {
      expect(parsed.get(tableName), `MorselPalette.${tableName} must match the contract`).toEqual(pair)
    }
    // Every native token declaration reads its pair from that table.
    const decls = [...designSystem.matchAll(
      /static let (morsel\w+) = Color\.morselJournal\(paper: MorselPalette\.(\w+)\.paper, night: MorselPalette\.\2\.night\)/g
    )]
    expect(decls.length, 'every color token must be declared from its palette pair').toBeGreaterThanOrEqual(24)
    const declared = new Set(decls.map((d) => d[1]))
    for (const token of Object.keys(TOKEN_TABLE)) {
      expect(declared.has(token), `${token} must be declared via Color.morselJournal`).toBe(true)
    }
  })

  it('keeps the semantic aliases pointing at the locked tokens', () => {
    // energy = calorie accent; energySoft = review/action wash; low = review text.
    expect(designSystem).toContain('static let morselEnergy = Color.morselAccent')
    expect(designSystem).toContain('static let morselEnergySoft = Color.morselAccentSoft')
    expect(designSystem).toContain('static let morselLow = Color.morselReview')
  })

  it('defines the exact approved V1 scalar tokens + inkline in DESIGN.md', () => {
    const entries = colorsBlockEntries()
    const names = new Set(entries.map((line) => /^  (\w+):/.exec(line)?.[1]))
    for (const [name, hex] of Object.entries(V1)) {
      expect(designMd, `DESIGN.md colors.${name} must be ${hex}`).toContain(`${name}: "${hex}"`)
    }
    expect(designMd, 'DESIGN.md colors.inkline must be the warm sepia line token').toContain(
      `inkline: "${INKLINE}"`
    )
    expect(names.size, 'the colors block carries no invented tokens').toBe(Object.keys(V1).length + 1)
  })

  it('documents only the measured-data gradient stops in the DESIGN.md gradient CSS', () => {
    const squash = designMd.replace(/\s+/g, '')
    const gradients: Array<[string, string, string]> = [
      ['--grad-protein', '#C9513D', '#A63A32'],
      ['--grad-carbs', '#B07A13', '#875A02'],
      ['--grad-fat', '#6B8B60', '#3F6745'],
      ['--grad-gauge', '#6B8B60', '#2F654B'],
      ['--grad-card', '#FFFCF5', '#FFF5E5'],
    ]
    for (const [name, from, to] of gradients) {
      const needle = `${name}:linear-gradient(90deg,${from},${to})`
      const alt = `${name}:linear-gradient(135deg,${from},${to})`
      const alt180 = `${name}:linear-gradient(180deg,${from},${to})`
      expect(
        squash.includes(needle) || squash.includes(alt) || squash.includes(alt180),
        `DESIGN.md must document ${name} with approved measured stops ${from}->${to}`
      ).toBe(true)
    }
  })

  it('keeps the promoted tokens.md role table in lockstep with DesignSystem', () => {
    // Every resolved pair hex (paper AND night) is documented in tokens.md.
    const doc = tokensDoc.toUpperCase()
    for (const pair of Object.values(DUAL)) {
      expect(doc, `tokens.md must document ${pair.paper}`).toContain(pair.paper)
      expect(doc, `tokens.md must document ${pair.night}`).toContain(pair.night)
    }
    expect(tokensDoc).toContain(INKLINE)
    expect(tokensDoc).toContain('#9D917F')
    expect(tokensDoc, 'tokens.md documents the wash pigment bases').toContain('#BF5546')
  })

  it('aligns the prototype tokens to the same approved V1 scalar values', () => {
    expect(prototype).toContain('--bg:#FFF7E8')
    expect(prototype).toContain('--surface:#FFFCF5')
    expect(prototype).toContain('--surface-2:#F2E9D9')
    expect(prototype).toContain('--line:#E3D2BA')
    expect(prototype).toContain('--ink:#2A261F')
    expect(prototype).toContain('--ink-2:#655A4B')
    expect(prototype).toContain('--ink-3:#756955')
    expect(prototype).toContain('--accent:#E66A2C')
    expect(prototype).toContain('--accent-soft:#FBE1C9')
    expect(prototype).toContain('--leaf:#5E7E57')
    expect(prototype).toContain('--leaf-soft:#E1E9D7')
    expect(prototype).toContain('--forest:#2F654B')
    expect(prototype).toContain('--coral:#B94738')
    expect(prototype).toContain('--mustard:#D6A62C')
    expect(prototype).toContain('--mustard-deep:#A5750B')
    expect(prototype).toContain('--review:#7A3D2B')
    expect(prototype).toContain('--over:#9C3A2F')
  })

  it('keeps the server renderer palette subset aligned to V1', () => {
    for (const hex of Object.values(V1)) {
      expect(renderer, `server/render.ts palette must include V1 ${hex}`).toContain(hex)
    }
  })

  it('carries no retired palette hex in any design-system source', () => {
    const surfaces: Array<[string, string]> = [
      [designSystem, 'DesignSystem.swift'],
      [journalUI, 'JournalUI.swift'],
      [views, 'Views.swift'],
      [historyView, 'HistoryView.swift'],
      [goalsEditor, 'GoalsEditor.swift'],
      [designMd, 'docs/DESIGN.md'],
      [prototype, 'docs/prototype.html'],
      [renderer, 'server/render.ts'],
    ]
    for (const hex of RETIRED_PALETTE_HEXES) {
      for (const [text, where] of surfaces) {
        requireAbsent(text, hex, where)
      }
    }
  })

  it('removes cool-palette color wording from the docs and prototype', () => {
    for (const word of COOL_COLOR_WORDS) {
      const re = new RegExp(`\\b${word}\\b`, 'i')
      expect(re.test(designMd), `"${word}" must be gone from docs/DESIGN.md`).toBe(false)
      expect(re.test(prototype), `"${word}" must be gone from docs/prototype.html`).toBe(false)
    }
    expect(/\bblue\b/i.test('evergreen blueprint')).toBe(false)
  })
})

describe('V1 semantic contracts (Refs #90 approval comment)', () => {
  it('keeps every strict text pair at or above 4.5:1 in BOTH themes', () => {
    const textPairs: Array<[string, string, string]> = [
      ['morselInk', 'morselBackground', 'body/data text on page'],
      ['morselInkTwo', 'morselBackground', 'secondary text on page'],
      ['morselInkThree', 'morselBackground', 'metadata/captions on page'],
      ['morselForest', 'morselBackground', 'active/positive word on page'],
      ['morselReview', 'morselAccentSoft', 'verify/low-confidence tag'],
      ['morselLabelOnAccent', 'morselAccent', 'confirm label on accent (never white)'],
      ['morselInk', 'morselSurface', 'copy on surface'],
      ['morselInk', 'morselSurfaceTwo', 'copy on fields'],
    ]
    for (const [fg, bg, label] of textPairs) {
      const pair = DUAL[fg]
      const ground = DUAL[bg]
      expect(pair, `${fg} must be declared`).toBeTruthy()
      expectAA(pair!.paper, ground!.paper, `${label} (paper)`)
      expectAA(pair!.night, ground!.night, `${label} (night)`)
    }
  })

  it('keeps every strict mark pair at or above 3:1 in BOTH themes', () => {
    const markPairs: Array<[string, string, string]> = [
      ['morselInkLine', 'morselBackground', 'hand rule/contour on page'],
      ['morselMustardDeep', 'morselBackground', 'near-goal ring stroke'],
      ['morselAccent', 'morselSurface', 'accent control on surface'],
    ]
    for (const [fg, bg, label] of markPairs) {
      const pair = DUAL[fg]
      const ground = DUAL[bg]
      expect(pair, `${fg} must be declared`).toBeTruthy()
      expectMark(pair!.paper, ground!.paper, `${label} (paper)`)
      expectMark(pair!.night, ground!.night, `${label} (night)`)
    }
  })

  it('renders the verify affordance with review on accentSoft (both themes)', () => {
    const verifySlice = todayLogViews.slice(todayLogViews.indexOf('Text("verify")'))
    expect(verifySlice).toMatch(/foregroundStyle\(Color\.morselReview\)/)
    expect(verifySlice).toContain('.background(Color.morselAccentSoft, in: RoundedRectangle(cornerRadius: 4))')
  })

  it('renders the primary button with ink on accent (never white)', () => {
    const start = designSystem.indexOf('struct MorselPrimaryButtonStyle')
    const end = designSystem.indexOf('struct MorselGhostButtonStyle')
    expect(start, 'MorselPrimaryButtonStyle must exist').toBeGreaterThan(-1)
    expect(end, 'MorselGhostButtonStyle must follow').toBeGreaterThan(start)
    const style = designSystem.slice(start, end)
    expect(style).toContain('.foregroundStyle(Color.morselLabelOnAccent)')
    expect(style).toContain('.background(Color.morselAccent')
    expect(style, 'primary button must not use a white label').not.toContain('foregroundStyle(Color.morselSurface)')
    expect(style, 'primary button must not hard-code white').not.toMatch(/\.white|#FFFFFF|#fff/i)
  })

  it('wires the active tab word to forest and the shell to three primary tabs', () => {
    const barStart = morselApp.indexOf('private struct JournalTabBar')
    expect(barStart, 'JournalTabBar must exist').toBeGreaterThan(-1)
    const bar = morselApp.slice(barStart)
    expect(bar).toContain('Color.morselForest')
    expect(bar).toContain('Color.morselInkTwo')
    expect(morselApp).toMatch(/enum JournalTab: String, CaseIterable, Hashable/)
    const enumSlice = morselApp.slice(morselApp.indexOf('enum JournalTab'), morselApp.indexOf('private struct AuthenticatedDashboardView'))
    expect(enumSlice).toContain('case today')
    expect(enumSlice).toContain('case history')
    expect(enumSlice).toContain('case goals')
    expect(enumSlice, 'Settings must not be a fourth tab').not.toMatch(/case (settings|more)/)
  })
})
