import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Warm-palette design-system alignment (Guy-approved 2026-08-31; Refs #32).
// The locked palette is normative: accent/energy #F08A2E, accentSoft
// #F6E8D8, protein/coral/over #C0483F, carbs #F0A63C, fat #D46A2E, low
// confidence #8A5514, neutrals unchanged, warm-only gradient stops. The old
// cobalt/blue/teal/cyan/purple/green role values are forbidden across the
// design-system sources and docs. This probe parses the three surfaces
// (DesignSystem.swift, docs/DESIGN.md, docs/prototype.html) and asserts the
// locked tokens are present and the forbidden cool values are gone, so the
// warm alignment cannot silently regress.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const designSystem = readFileSync(join(repoRoot, 'app', 'Sources', 'Morsel', 'DesignSystem.swift'), 'utf8')
const designMd = readFileSync(join(repoRoot, 'docs', 'DESIGN.md'), 'utf8')
const prototype = readFileSync(join(repoRoot, 'docs', 'prototype.html'), 'utf8')

// Old cool role values (forbidden anywhere in the design system).
const FORBIDDEN_COOL_HEXES = [
  '#3E63E8', // old cobalt accent
  '#E9EEFC', // old cobalt soft
  '#6C5CE7', // old violet protein
  '#0FA6A0', // old teal fat
  '#9C8BF5', // old violet gradient start
  '#37D5C2', // old teal gradient start
  '#5BD8E6', // old cyan under start
  '#1FA3C4', // old cyan under end
  '#3BC8A8', // old emerald on start
  '#12A98E', // old emerald on end
  '#E0765F', // old copper-rose over end
]

// Stale old-palette values that are not on the cool list but belonged to the
// retired palette; a second stale palette must not survive in the prototype.
const STALE_SECOND_PALETTE_HEXES = [
  '#3354C7', // old confirm hover cobalt
  '#6FA7C6', // old blue water fill
  '#1AA3B8', // old cyan under-delta text
  '#D9715D', // old rose over text (replaced by locked #C0483F roles)
  '#F0762E', // old deep-copper energy gradient end
  '#EBE8DF', // old ghost hover neutral (replaced by locked line)
  '#F0EDE3', // old row hairline neutral (replaced by locked line)
  '#3ED6BE', // old ring on-gradient light stop
  '#0E9F8A', // old ring on-gradient dark stop
  '#FFB9A8', // old ring over-gradient light stop
  '#FFCF5E', // old ring near-gradient light stop
]

const COOL_GUIDANCE_WORDS = ['cobalt', 'blue', 'teal', 'cyan', 'violet', 'emerald', 'purple', 'green']

// Case-insensitive so lowercase CSS hex cannot dodge the contract while the
// Swift assertions pin the exact declaration spelling.
function countCI(haystack: string, needle: string): number {
  return haystack.toLowerCase().split(needle.toLowerCase()).length - 1
}

function requireAbsent(text: string, hex: string, where: string) {
  expect(countCI(text, hex), `${hex} must be gone from ${where}`).toBe(0)
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

describe('warm-palette token consistency (Refs #32)', () => {
  it('declares the locked warm interaction accent in DesignSystem.swift', () => {
    requireSwiftToken('morselAccent', '#F08A2E')
    requireSwiftToken('morselAccentSoft', '#F6E8D8')
    requireSwiftToken('morselEnergy', '#F08A2E')
    requireSwiftToken('morselEnergySoft', '#F6E8D8')
  })

  it('declares the locked warm macro data roles in DesignSystem.swift', () => {
    requireSwiftToken('morselProtein', '#C0483F')
    requireSwiftToken('morselCarbs', '#F0A63C')
    requireSwiftToken('morselFat', '#D46A2E')
    requireSwiftToken('morselOver', '#C0483F')
    requireSwiftToken('morselLow', '#8A5514')
  })

  it('declares the locked warm-only gradient stops in DesignSystem.swift', () => {
    requireSwiftToken('morselProteinStart', '#C0483F')
    requireSwiftToken('morselCarbsStart', '#FFC24B')
    requireSwiftToken('morselFatStart', '#F0A63C')
    requireSwiftToken('morselUnderStart', '#FFC24B')
    requireSwiftToken('morselUnder', '#F08A2E')
    requireSwiftToken('morselOnStart', '#F0A63C')
    requireSwiftToken('morselOn', '#D46A2E')
    requireSwiftToken('morselOverStart', '#F7A98C')
    requireSwiftToken('morselOverEnd', '#C0483F')
  })

  it('keeps the unchanged neutrals byte-for-byte in DesignSystem.swift', () => {
    requireSwiftToken('morselInk', '#20231E')
    requireSwiftToken('morselInkTwo', '#666A60')
    requireSwiftToken('morselInkThree', '#9BA095')
    requireSwiftToken('morselBackground', '#FBFAF6')
    requireSwiftToken('morselSurface', '#FFFFFF')
    requireSwiftToken('morselSurfaceTwo', '#F3F1EA')
    requireSwiftToken('morselLine', '#E7E3D8')
    requireSwiftToken('morselCardEnd', '#FBF9F2')
  })

  it('defines the locked warm colors as scalar tokens in DESIGN.md', () => {
    const expected: Array<[string, string]> = [
      ['accent', '#F08A2E'],
      ['accentSoft', '#F6E8D8'],
      ['energy', '#F08A2E'],
      ['energySoft', '#F6E8D8'],
      ['protein', '#C0483F'],
      ['carbs', '#F0A63C'],
      ['fat', '#D46A2E'],
      ['over', '#C0483F'],
      ['low', '#8A5514'],
    ]
    colorsBlockTokens()
    for (const [name, hex] of expected) {
      expect(designMd, `DESIGN.md colors.${name} must be ${hex}`).toContain(`${name}: "${hex}"`)
    }
  })

  it('documents only warm gradient stops in the DESIGN.md gradient CSS', () => {
    const squash = designMd.replace(/\s+/g, '')
    const gradients: Array<[string, string, string]> = [
      ['--grad-protein', '#C0483F', '#C0483F'],
      ['--grad-carbs', '#FFC24B', '#F0A63C'],
      ['--grad-fat', '#F0A63C', '#D46A2E'],
      ['--grad-under', '#FFC24B', '#F08A2E'],
      ['--grad-on', '#F0A63C', '#D46A2E'],
      ['--grad-over', '#F7A98C', '#C0483F'],
    ]
    for (const [name, from, to] of gradients) {
      expect(squash, `DESIGN.md must document ${name}:${from}->${to}`).toContain(`${name}:linear-gradient(180deg,${from},${to})`)
    }
  })

  it('aligns the prototype tokens to the same locked warm values', () => {
    expect(prototype).toContain('--accent:#F08A2E')
    expect(prototype).toContain('--accent-soft:#F6E8D8')
    expect(prototype).toContain('--protein:#C0483F')
    expect(prototype).toContain('--carbs:#F0A63C')
    expect(prototype).toContain('--fat:#D46A2E')
    expect(prototype.toLowerCase()).toContain('--grad-protein:linear-gradient(180deg,#c0483f,#c0483f)')
  })

  it('carries no forbidden cool hex in any design-system source', () => {
    for (const hex of FORBIDDEN_COOL_HEXES) {
      requireAbsent(designSystem, hex, 'DesignSystem.swift')
      requireAbsent(designMd, hex, 'docs/DESIGN.md')
      requireAbsent(prototype, hex, 'docs/prototype.html')
    }
  })

  it('leaves no stale second palette in the prototype', () => {
    for (const hex of STALE_SECOND_PALETTE_HEXES) {
      requireAbsent(prototype, hex, 'docs/prototype.html')
    }
  })

  it('removes cool-palette guidance wording from the docs and prototype', () => {
    for (const word of COOL_GUIDANCE_WORDS) {
      expect(countCI(designMd, word), `"${word}" must be gone from docs/DESIGN.md`).toBe(0)
      expect(countCI(prototype, word), `"${word}" must be gone from docs/prototype.html`).toBe(0)
    }
  })
})
