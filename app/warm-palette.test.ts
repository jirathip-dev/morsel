import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Approved V1 palette — "Orange Hearth + Sage" (issue #32, Guy-approved).
// Authority: design-output/morsel/32-palette-botanical-reference (TOKENS.md,
// palette-data.json V1, CONTRAST.md, DESIGN-CANDIDATE.md) and the bounded
// implementation brief. V1 supersedes the older warm-orange locked palette.
//
// This probe parses the real surfaces (DesignSystem.swift, Views.swift,
// docs/DESIGN.md, docs/prototype.html, server/render.ts), asserts the exact
// V1 scalar tokens are present, the older-palette values are gone, the
// semantic usage contracts hold (forest=stable/high-confidence text on
// leafSoft, review on accentSoft for needs-review, ink on accent for the
// primary confirm button — never white, never cool), and every normative
// component text pair measurably passes WCAG AA (>= 4.5:1).

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const designSystem = readFileSync(join(repoRoot, 'app', 'Sources', 'Morsel', 'DesignSystem.swift'), 'utf8')
const views = readFileSync(join(repoRoot, 'app', 'Sources', 'Morsel', 'Views.swift'), 'utf8')
const designMd = readFileSync(join(repoRoot, 'docs', 'DESIGN.md'), 'utf8')
const prototype = readFileSync(join(repoRoot, 'docs', 'prototype.html'), 'utf8')
const renderer = readFileSync(join(repoRoot, 'server', 'render.ts'), 'utf8')

// Exact approved V1 scalar contract (brief; palette-data.json V1).
const V1: Record<string, string> = {
  bg: '#FFF7E8',
  surface: '#FFFCF5',
  surface2: '#F2E9D9',
  line: '#E3D2BA',
  ink: '#2A261F',
  ink2: '#655A4B',
  ink3: '#756955',
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

// Any previous palette value that must not survive in any design surface.
const RETIRED_PALETTE_HEXES = [
  '#3E63E8', '#E9EEFC', '#6C5CE7', '#0FA6A0', '#9C8BF5', '#37D5C2',
  '#5BD8E6', '#1FA3C4', '#3BC8A8', '#12A98E', '#E0765F', '#3354C7',
  '#6FA7C6', '#1AA3B8', '#D9715D', '#3ED6BE', '#0E9F8A', '#FFB9A8',
  '#FFCF5E', // original cobalt/teal/violet/cyan palette (rounds 0)
  '#F08A2E', '#F6E8D8', '#C0483F', '#F0A63C', '#D46A2E', '#FFC24B',
  '#F7A98C', '#FBF9F2', '#FBFAF6', '#F3F1EA', '#E7E3D8', '#20231E',
  '#666A60', '#9BA095', // r1 warm-orange palette (superseded by V1)
]

// V1 forbids cool families as app accents/status colors. Matching is
// word-boundary based so compound words (evergreen, blueprint) cannot
// false-positive, while the exact banned color words still fail.
const COOL_COLOR_WORDS = ['cobalt', 'blue', 'teal', 'cyan', 'violet', 'purple']

// ── Executable WCAG contrast helpers (normative-pair enforcement) ─────────
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

// Resolve `var(--x)` references (and bare hexes) against the prototype :root
// block so component-state assertions measure real rendered pairs.
function prototypeVarMap(): Map<string, string> {
  const rootMatch = /:root\{([^}]*)\}/.exec(prototype)
  expect(rootMatch, 'prototype must keep a :root token block').toBeTruthy()
  const map = new Map<string, string>()
  for (const m of rootMatch![1].matchAll(/--([a-z0-9-]+):([^;}]+)/gi)) {
    map.set(m[1].toLowerCase(), m[2].trim().toLowerCase())
  }
  return map
}

function resolveColor(raw: string, vars: Map<string, string>): string {
  const value = raw.trim().toLowerCase()
  if (value.startsWith('var(--')) {
    const name = value.slice(6, -1)
    const resolved = vars.get(name)
    expect(resolved, `prototype var --${name} must be defined`).toBeTruthy()
    return resolved!
  }
  return value
}

/** Extract a rule body like `.btn.confirm:hover{...}` and resolve fg/bg. */
function prototypeRule(selector: string): { color: string; background: string } {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = new RegExp(`${escaped}\\{([^}]*)\\}`).exec(prototype)
  expect(match, `prototype rule ${selector} must exist`).toBeTruthy()
  const vars = prototypeVarMap()
  const body = match![1]
  const fg = /(?:^|;)\s*color:([^;}]+)/.exec(body)?.[1] ?? 'var(--ink)'
  const bg = /background:([^;}]+)/.exec(body)?.[1] ?? 'var(--surface)'
  return { color: resolveColor(fg, vars), background: resolveColor(bg, vars) }
}

// ── Shared helpers ────────────────────────────────────────────────────────
function countMatches(text: string, re: RegExp): number {
  return [...text.matchAll(re)].length
}

function requireAbsent(text: string, hex: string, where: string) {
  expect(countMatches(text, new RegExp(hex, 'gi')), `${hex} must be gone from ${where}`).toBe(0)
}

function requireSwiftToken(token: string, hex: string) {
  const decl = `static let ${token} = Color(paletteHex: "${hex}")`
  expect(designSystem, `DesignSystem.swift must declare ${decl}`).toContain(decl)
}

// The DESIGN.md colors: block must stay quoted scalar colors only — gradients
// are documented in prose/CSS, never as token values.
function colorsBlockTokens(): string[] {
  const start = designMd.indexOf('colors:\n')
  const stop = designMd.indexOf('typography:\n', start)
  expect(start, 'DESIGN.md front matter must define colors:').toBeGreaterThan(-1)
  expect(stop, 'DESIGN.md front matter must continue past colors:').toBeGreaterThan(start)
  const lines = designMd.slice(start + 'colors:\n'.length, stop).split('\n')
  for (const line of lines) {
    if (line.trim() === '') continue
    expect(line, `colors: entries must be quoted scalar colors, got "${line}"`).toMatch(/^  \w+: "#[0-9A-F]{6}"$/)
  }
  return lines
}

describe('V1 palette token consistency (Orange Hearth + Sage, Refs #32)', () => {
  it('declares every approved V1 neutral/scalar token in DesignSystem.swift', () => {
    requireSwiftToken('morselBackground', V1.bg)
    requireSwiftToken('morselSurface', V1.surface)
    requireSwiftToken('morselSurfaceTwo', V1.surface2)
    requireSwiftToken('morselLine', V1.line)
    requireSwiftToken('morselInk', V1.ink)
    requireSwiftToken('morselInkTwo', V1.ink2)
    requireSwiftToken('morselInkThree', V1.ink3)
    requireSwiftToken('morselAccent', V1.accent)
    requireSwiftToken('morselAccentSoft', V1.accentSoft)
    requireSwiftToken('morselLeaf', V1.leaf)
    requireSwiftToken('morselLeafSoft', V1.leafSoft)
    requireSwiftToken('morselForest', V1.forest)
    requireSwiftToken('morselCoral', V1.coral)
    requireSwiftToken('morselMustard', V1.mustard)
    requireSwiftToken('morselMustardDeep', V1.mustardDeep)
    requireSwiftToken('morselReview', V1.review)
    requireSwiftToken('morselOver', V1.over)
  })

  it('maps V1 semantic aliases for the existing call sites in DesignSystem.swift', () => {
    // energy = calorie accent (V1 keeps accent as the calorie anchor);
    // energySoft = warm action wash; low-confidence review text = V1 review.
    requireSwiftToken('morselEnergy', V1.accent)
    requireSwiftToken('morselEnergySoft', V1.accentSoft)
    requireSwiftToken('morselLow', V1.review)
  })

  it('declares the measured-data gradient stops from the approved TOKENS.md table', () => {
    // Measured-data gradient values are the documented measured-data
    // treatment (never new scalar/background decoration).
    requireSwiftToken('morselProtein', V1.coral)
    requireSwiftToken('morselProteinStart', '#C9513D')
    requireSwiftToken('morselProteinEnd', '#A63A32')
    requireSwiftToken('morselCarbs', V1.mustardDeep)
    requireSwiftToken('morselCarbsStart', '#B07A13')
    requireSwiftToken('morselCarbsEnd', '#875A02')
    requireSwiftToken('morselFat', V1.leaf)
    requireSwiftToken('morselFatStart', '#6B8B60')
    requireSwiftToken('morselFatEnd', '#3F6745')
    requireSwiftToken('morselGaugeStart', '#6B8B60')
    requireSwiftToken('morselGaugeEnd', V1.forest)
    requireSwiftToken('morselCardEnd', '#FFF5E5')
  })

  it('defines the exact approved V1 colors as scalar tokens in DESIGN.md', () => {
    colorsBlockTokens()
    for (const [name, hex] of Object.entries(V1)) {
      expect(designMd, `DESIGN.md colors.${name} must be ${hex}`).toContain(`${name}: "${hex}"`)
    }
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

  it('aligns the prototype tokens to the same approved V1 values', () => {
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

  it('keeps the server renderer palette subset aligned to V1 for its DESIGN.md contract', () => {
    for (const hex of Object.values(V1)) {
      expect(renderer, `server/render.ts palette must include V1 ${hex}`).toContain(hex)
    }
  })

  it('carries no retired palette hex in any design-system source', () => {
    const surfaces: Array<[string, string]> = [
      [designSystem, 'DesignSystem.swift'],
      [views, 'Views.swift'],
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
    // evergreen/blueprint must NOT false-positive the word matcher
    expect(/\bblue\b/i.test('evergreen blueprint')).toBe(false)
  })
})

describe('V1 semantic contracts (Refs #32 approval comment)', () => {
  it('keeps every normative component text pair at or above 4.5:1', () => {
    expectAA(V1.forest, V1.leafSoft, 'high-confidence/stable tag (forest on leafSoft)')
    expectAA(V1.review, V1.accentSoft, 'needs-review/low-confidence tag (review on accentSoft)')
    expectAA(V1.ink, V1.accent, 'btn-confirm label (ink on accent, never white)')
    expectAA(V1.ink, V1.accentSoft, 'btn-confirm hover (ink on accentSoft)')
    expectAA(V1.ink, V1.bg, 'primary text on bg')
    expectAA(V1.over, V1.bg, 'over-goal status text')
  })

  it('renders the SwiftUI high-confidence tag with forest on leafSoft', () => {
    const highCase = views.slice(views.indexOf('case .high:'), views.indexOf('case .low:'))
    expect(highCase).toContain('morselTag(foreground: Color.morselForest, background: Color.morselLeafSoft)')
    expect(highCase, 'high-confidence tag must not use ink as its text color anymore')
      .not.toContain('foreground: Color.morselInk')
    expectAA(V1.forest, V1.leafSoft, 'SwiftUI high-confidence tag resolved pair')
  })

  it('renders the SwiftUI low-confidence/review tag with review on accentSoft', () => {
    const lowCase = views.slice(views.indexOf('case .low:'), views.indexOf('case .missing:'))
    expect(lowCase).toContain('morselTag(foreground: Color.morselReview, background: Color.morselAccentSoft)')
    expectAA(V1.review, V1.accentSoft, 'SwiftUI low-confidence tag resolved pair')
  })

  it('renders the SwiftUI primary button with ink on accent (never white)', () => {
    const start = designSystem.indexOf('struct MorselPrimaryButtonStyle')
    const end = designSystem.indexOf('struct MorselGhostButtonStyle')
    expect(start, 'MorselPrimaryButtonStyle must exist').toBeGreaterThan(-1)
    expect(end, 'MorselGhostButtonStyle must follow').toBeGreaterThan(start)
    const style = designSystem.slice(start, end)
    expect(style).toContain('.foregroundStyle(Color.morselInk)')
    expect(style).toContain('.background(Color.morselAccent')
    expect(style, 'primary button must not use a white label').not.toContain('foregroundStyle(Color.morselSurface)')
    expect(style, 'primary button must not hard-code white').not.toMatch(/\.white|#FFFFFF|#fff/i)
    expectAA(V1.ink, V1.accent, 'SwiftUI primary button resolved pair')
  })

  it('specifies the accessible confirm and tag components in DESIGN.md', () => {
    const block = designMd.slice(designMd.indexOf('  btn-confirm:'), designMd.indexOf('  btn-ghost:'))
    expect(block).toContain('backgroundColor: "{colors.accent}"')
    expect(block).toContain('textColor: "{colors.ink}"')
    expect(block, 'btn-confirm must not use a white label').not.toMatch(/#FFFFFF|#fff/i)
    expect(designMd).toContain('`tag-conf-high` (forest on leafSoft)')
    expect(designMd).toContain('`tag-conf-low` (review on accentSoft)')
  })

  it('renders prototype high/low tags and confirm states with V1 AA pairs', () => {
    const hi = prototypeRule('.tag.conf.hi')
    expect(hi.color).toBe('#2f654b')
    expect(hi.background).toBe('#e1e9d7')
    expectAA(hi.color, hi.background, 'prototype tag.conf.hi')

    const lo = prototypeRule('.tag.conf.lo')
    expect(lo.color).toBe('#7a3d2b')
    expect(lo.background).toBe('#fbe1c9')
    expectAA(lo.color, lo.background, 'prototype tag.conf.lo')

    const confirm = prototypeRule('.btn.confirm')
    expect(confirm.color).toBe('#2a261f')
    expect(confirm.background).toBe('#e66a2c')
    expectAA(confirm.color, confirm.background, 'prototype .btn.confirm')

    const hover = prototypeRule('.btn.confirm:hover')
    expect(hover.background).toBe('#fbe1c9')
    expect(hover.color, 'hover must not keep a white label on cream').not.toMatch(/#fff/i)
    expectAA(hover.color, hover.background, 'prototype .btn.confirm:hover')
  })
})

// ── Review round 1 (V1) fixes: small-text AA + gauge spec truthfulness ────
// V1 accent #E66A2C on warm ground is ~3:1 — below AA for 11pt text. These
// tests parse the REAL Swift call sites and resolve them through the
// DesignSystem token table to hexes, then compute WCAG — a call-site revert
// in any covered file turns them RED.

const swiftCallSites: Array<{ file: string; text: string }> = [
  'Views.swift',
  'Onboarding.swift',
  'AuthView.swift',
  'GoalsEditor.swift',
  'MealCaptureView.swift',
].map((file) => ({
  file,
  text: readFileSync(join(repoRoot, 'app', 'Sources', 'Morsel', file), 'utf8'),
}))
const gaugeViews = readFileSync(join(repoRoot, 'app', 'Sources', 'Morsel', 'GaugeViews.swift'), 'utf8')

/** Parse `static let morselX = Color(paletteHex: "#…")` from DesignSystem.swift. */
function swiftTokenHex(token: string): string {
  const match = new RegExp(`static let ${token} = Color\\(paletteHex: "#([0-9A-Fa-f]{6})"\\)`).exec(designSystem)
  expect(match, `DesignSystem.swift must declare token ${token}`).toBeTruthy()
  return `#${match![1].toUpperCase()}`
}

/**
 * Resolve a color expression used at a call site to its hex through the
 * parsed DesignSystem token table (supports `Color.morselX` and `.morselX`).
 */
function resolveSwiftColor(expression: string): string {
  const match = /(?:Color\.)?morsel(\w+)/.exec(expression.trim())
  expect(match, `cannot resolve Swift color expression "${expression}"`).toBeTruthy()
  const name = match![1]
  const hex = swiftTokenHex(`morsel${name}`)
  expect(hex, `token morsel${name} must resolve to a hex`).toMatch(/^#[0-9A-F]{6}$/)
  return hex
}

/** Find `.foregroundStyle(<expr>)` immediately after a given anchor line. */
function foregroundAfter(source: string, anchor: string, label: string): string {
  const at = source.indexOf(anchor)
  expect(at, `${label}: anchor must exist`).toBeGreaterThan(-1)
  const match = /\.foregroundStyle\(([^\n]+)\)/.exec(source.slice(at, at + anchor.length + 400))
  expect(match, `${label}: foregroundStyle must follow the anchor`).toBeTruthy()
  return match![1]
}

describe('V1 review-r1: small warm-ground text uses AA-compliant forest (Refs #32)', () => {
  const smallWordmarkSites: Array<{ file: string; source: string; anchor: string; label: string }> = [
    {
      file: 'Views.swift',
      source: swiftCallSites[0].text,
      anchor: 'Text("morsel")',
      label: 'Today morsel wordmark',
    },
    {
      file: 'Onboarding.swift',
      source: swiftCallSites[1].text,
      anchor: 'Text("morsel")',
      label: 'onboarding morsel wordmark',
    },
    {
      file: 'AuthView.swift',
      source: swiftCallSites[2].text,
      anchor: 'Text("morsel")\n                            .font(.morselData)',
      label: 'auth morsel wordmark (sign-in step)',
    },
    {
      file: 'AuthView.swift',
      source: swiftCallSites[2].text,
      anchor: 'Button("Use a different email")',
      label: 'auth use-a-different-email link',
    },
    {
      file: 'GoalsEditor.swift',
      source: swiftCallSites[3].text,
      anchor: 'Text("morsel · agent voice")',
      label: 'goals agent-voice label',
    },
    {
      file: 'MealCaptureView.swift',
      source: swiftCallSites[4].text,
      anchor: 'Button("Remove")',
      label: 'capture remove label',
    },
  ]

  it('renders the six small product-text call sites in forest, measurably AA on bg', () => {
    const forestHex = swiftTokenHex('morselForest')
    expect(forestHex).toBe(V1.forest)
    const bgHex = swiftTokenHex('morselBackground')
    expect(bgHex).toBe(V1.bg)
    for (const site of smallWordmarkSites) {
      const expression = foregroundAfter(site.source, site.anchor, `${site.file} ${site.label}`)
      expect(expression, `${site.label} (${site.file}) must use Color.morselForest`).toContain('Color.morselForest')
      const resolved = resolveSwiftColor(expression)
      expect(resolved, `${site.label} must resolve to forest ${V1.forest}`).toBe(V1.forest)
      const ratio = contrastRatio(resolved, bgHex)
      expect(
        ratio,
        `${site.label}: forest on bg is ${ratio.toFixed(2)}:1, below WCAG AA 4.5:1`
      ).toBeGreaterThanOrEqual(4.5)
    }
  })

  it('keeps accent off the six small-text sites entirely (no accent foreground at those anchors)', () => {
    for (const site of smallWordmarkSites) {
      const expression = foregroundAfter(site.source, site.anchor, `${site.file} ${site.label}`)
      expect(expression, `${site.label} (${site.file}) must not use accent text`).not.toContain('morselAccent')
    }
  })

  it('renders the gauge ring on-track fill via the measured gauge gradient, not accent', () => {
    const ringStart = gaugeViews.indexOf('private struct CalorieRing: View')
    const ringEnd = gaugeViews.indexOf('private struct GoalSummary: View')
    expect(ringStart, 'CalorieRing must exist').toBeGreaterThan(-1)
    expect(ringEnd, 'GoalSummary must follow CalorieRing').toBeGreaterThan(ringStart)
    const ring = gaugeViews.slice(ringStart, ringEnd)
    expect(ring).toContain('LinearGradient.morselGauge')
    // The gauge gradient itself must be composed of the measured leaf→forest stops.
    const gaugeStart = swiftTokenHex('morselGaugeStart')
    const gaugeEnd = swiftTokenHex('morselGaugeEnd')
    expect(gaugeStart).toBe('#6B8B60')
    expect(gaugeEnd).toBe(V1.forest)
    // status.tint onTrack must resolve to forest (5.65:1 on surface2 track),
    // never accent (2.70:1).
    const tintBlock = gaugeViews.slice(gaugeViews.indexOf('extension GoalStatus'))
    const onTrack = /case \.onTrack:\s*\n\s*return \.morsel(\w+)/.exec(tintBlock)
    expect(onTrack, 'GoalStatus.tint must have an .onTrack case').toBeTruthy()
    expect(onTrack![1], 'onTrack tint must be Forest').toBe('Forest')
    expectAA(resolveSwiftColor('.morselForest'), swiftTokenHex('morselSurfaceTwo'), 'onTrack ring on surface2 track')
    const nearGoal = /case \.nearGoal:\s*\n\s*return \.morsel(\w+)/.exec(tintBlock)
    expect(nearGoal, 'GoalStatus.tint must have a .nearGoal case').toBeTruthy()
    expect(nearGoal![1], 'nearGoal tint must be MustardDeep (accessible data stroke)').toBe('MustardDeep')
  })

  it('makes the normative gauge-ring frontmatter truthful (forest fallback, measured prose)', () => {
    const gaugeBlock = designMd.slice(
      designMd.indexOf('  gauge-ring:'),
      designMd.indexOf('  macro-track:')
    )
    expect(gaugeBlock, 'gauge-ring component must exist in DESIGN.md').toBeTruthy()
    expect(gaugeBlock).toContain('fillColor: "{colors.forest}"')
    expect(gaugeBlock, 'gauge fill fallback must not be accent').not.toContain('fillColor: "{colors.accent}"')
    // Prose keeps the measured treatment explicit: the rendered ring is the
    // measured leaf→forest gradient; forest is only the scalar fallback.
    expect(designMd).toContain('gradGauge')
    expect(designMd).toMatch(/measured leaf→forest/i)
  })
})
